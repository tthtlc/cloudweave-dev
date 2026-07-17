# How to Create / Modify / Delete an OpenFGA Principal Mapping

This guide covers the **principal map** in
`../libcloud.rest/data/principal_map.json`: the file that translates a Dex
JWT's `sub` / `email` claims into the **stable application principal slug**
that OpenFGA tuples and libcloud REST scopes are keyed on.

> **What a principal mapping is here.** OpenFGA tuples and libcloud REST
> `PRINCIPAL_SCOPES` reference stable slugs like `aws-admin`, `ntnx-viewer`,
> `superadmin`. In Phase 1 the Dex JWT `sub` **is** that slug (because Dex
> authenticates LLDAP `uid`s directly). In Phase 2 — when Dex federates to
> an upstream IdP (Entra ID / Authentik / AD) — the JWT `sub` becomes an
> opaque upstream object ID, and `principal_map.json` is what maps it back to
> the stable slug. This is the file you edit on Phase-2 cutover (or when a
> user's email changes).

---

## 0. The resolution flow

```
Dex access_token
  → verify signature (JWKS at /dex/keys)
  → resolve_principal(sub, email)   [data/principal_map.json]
  → TokenClaims.sub = superadmin | aws-admin | aws-viewer | ntnx-admin | ntnx-viewer | cloud-denied
  → OpenFGA checks user:{TokenClaims.sub}
```

Implemented in `../libcloud.rest/app/auth/oidc_service.py` →
`app/auth/identity.py::resolve_principal`.

`principal_map.json` has two lookup tables:

- `by_sub`   — keyed by the JWT `sub` (the LLDAP `uid` in Phase 1, or the
  upstream object ID in Phase 2).
- `by_email` — keyed by the JWT `email` (secondary mapping key).

There is also a **known-principal fallback** in `identity.py`: a `sub` that
already matches a known principal slug (e.g. `aws-admin`) resolves to itself
without a map entry. This is why most Phase-1 users need **no** entry in
`principal_map.json` — `uid == slug`.

---

## 1. Prerequisites

- `../libcloud.rest` is checked out; `data/principal_map.json` exists.
- You know the upstream subject ID (Phase 2) or the new email (email change).
- You can recreate the libcloud REST API container after editing.

---

## 2. ADD a mapping (Phase 2 cutover)

For each upstream user, add a `by_sub` entry mapping the upstream object ID
to the stable slug. Optionally add a `by_email` entry as a secondary key.

```json
{
  "by_sub": {
    "11111111-2222-3333-4444-555555555555": "aws-admin",
    "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee": "ntnx-viewer"
  },
  "by_email": {
    "aws-admin@libcloud.local": "aws-admin",
    "alice@enantaid.example":   "aws-admin"
  }
}
```

Rules:
- The slug on the right must be one the system knows:
  `superadmin`, `*-owner`, `*-admin`, `*-viewer`, `cloud-denied`, or a
  custom principal with explicit `PRINCIPAL_SCOPES` (see
  [how_to_create_libcloud_rest_principal.md](how_to_create_libcloud_rest_principal.md)).
- The OpenFGA tuples stay `user:aws-admin`, `user:ntnx-viewer`, etc. — they
  do **not** reference the upstream object ID. The map is the only place the
  upstream identity appears.
- Add one entry per upstream user. The map is the source of truth for "who
  is this JWT bearer, in libcloud terms?"

After editing:

```bash
# Validate JSON:
python3 -c "import json; json.load(open('../libcloud.rest/data/principal_map.json'))"

# Recreate the REST API so the file is re-read:
docker compose -f ../libcloud.rest/docker-compose.yml up -d --force-recreate libcloud-rest
```

---

## 3. MODIFY a mapping

### 3.1 A user's email changed

Update the `by_email` entry to the new address (and remove the old one if
no longer used). The `by_sub` entry (if any) is unaffected.

### 3.2 A user should resolve to a different principal

Change the slug on the right-hand side of the affected `by_sub` / `by_email`
entry. Make sure the target slug has the right OpenFGA tuples (use
[how_to_create_openfga_tuple.md](how_to_create_openfga_tuple.md) to grant /
revoke) and the right `PRINCIPAL_SCOPES` (see
[how_to_create_libcloud_rest_principal.md](how_to_create_libcloud_rest_principal.md)).

Recreate the REST API after editing.

---

## 4. DELETE a mapping

Remove the entry from `by_sub` / `by_email`. If the user's `sub` no longer
matches a known-principal slug and has no `by_email` fallback, their JWT will
fail to resolve (`auth_user_unknown`) and the REST API will 403. Combine
this with offboarding the user — see
[how_to_create_lldap_user.md](how_to_create_lldap_user.md) §4 — and removing
their OpenFGA tuples — see
[how_to_create_openfga_tuple.md](how_to_create_openfga_tuple.md) §3.

Recreate the REST API after editing.

---

## 5. VERIFY

```bash
# Decode a Dex JWT for the user and confirm sub/email:
scripts/idp_login.py   # prints the JWT
python3 scripts/verify_superadmin_jwt.py   # for superadmin

# Hit /v1/auth/me with that JWT and confirm the resolved principal:
curl -s -H "Authorization: Bearer <jwt>" http://localhost:8765/v1/auth/me | jq

# OpenFGA decision for the resolved principal:
scripts/openfga-check.sh user:<resolved-slug> can_connect libcloud_api:main
```

---

## 6. Files touched

| File | What changes |
|------|--------------|
| `../libcloud.rest/data/principal_map.json` | `by_sub` / `by_email` entry |
| `../libcloud.rest/app/auth/identity.py` | (only if you add a new non-suffix principal — see principal guide) |
| OpenFGA tuples | **unchanged** (still keyed on the stable slug) |

---

## 7. Quick reference

| Action | Command |
|--------|---------|
| Edit the map | edit `../libcloud.rest/data/principal_map.json` |
| Validate | `python3 -c "import json; json.load(open('.../principal_map.json'))"` |
| Reload REST API | `docker compose -f ../libcloud.rest/docker-compose.yml up -d --force-recreate libcloud-rest` |
| Verify resolution | `GET /v1/auth/me` with the user's JWT |
| Related | [how_to_create_dex_connector.md](how_to_create_dex_connector.md) (Phase 2 connector) |
