# How to Create / Modify / Delete a libcloud REST Principal (Scopes + allowed_providers)

This guide covers **principals** in `../libcloud.rest`: the stable slugs
(`superadmin`, `*-owner`, `*-admin`, `*-viewer`, `cloud-denied`) that
OpenFGA tuples reference and that the REST API maps to JWT scopes and
`allowed_providers`. It covers adding a new principal, changing its scopes,
and removing one.

> **What a principal is here.** A principal is **not** a user account —
> user accounts live in LLDAP. A principal is the **authorization identity**
> the REST API resolves a JWT into. The resolution: Dex JWT `sub`/`email` →
> `data/principal_map.json` (or the known-principal fallback) →
> `TokenClaims.sub = <principal slug>` → `identity.py` grants scopes +
> `allowed_providers` → OpenFGA checks `user:<slug>`.

---

## 0. The two scope tables

`../libcloud.rest/app/auth/identity.py`:

| Constant | Who gets it | Effect |
|----------|-------------|--------|
| `PROVISIONER_SCOPES` | `superadmin`, `*-owner`, `*-admin` | write + read scopes |
| `READER_SCOPES` | `*-viewer` | read-only scopes |

**Role-suffix logic** (`_role_suffix` / `principal_scopes`): any
`<tenant>-owner` / `<tenant>-admin` / `<tenant>-viewer` is recognized
automatically from the suffix — you do **not** edit per-principal tables for
the standard tenant roles. `PRINCIPAL_SCOPES` / `PRINCIPAL_PROVIDERS` only
need an entry for **non-suffix** principal names (e.g. `superadmin`,
`cloud-denied`, a custom platform principal).

---

## 1. Prerequisites

- `../libcloud.rest` is checked out and `app/auth/identity.py` is editable.
- You can recreate the REST API container.
- The principal slug is also a subject you will write OpenFGA tuples against
  (`user:<slug>`) — see
  [how_to_create_openfga_tuple.md](how_to_create_openfga_tuple.md).

---

## 2. ADD a principal

### 2a. Standard tenant role (`<tenant>-owner` / `-admin` / `-viewer`)

**No `identity.py` edit needed** — the suffix logic grants scopes/providers
automatically. Just:
1. Create the LLDAP user with that `uid` (see
   [how_to_create_lldap_user.md](how_to_create_lldap_user.md)).
2. Write the OpenFGA tuples (`user:<tenant>-admin admin tenant:<tenant>`,
   etc.) — see [how_to_add_new_tenant.md](how_to_add_new_tenant.md) Case A
   or run `scripts/create_tenant.sh`.

### 2b. Non-suffix principal (e.g. `cloud-auditor`)

1. **Grant scopes + providers** in `app/auth/identity.py`:

   ```python
   PRINCIPAL_SCOPES = {
       "superadmin":   PROVISIONER_SCOPES,
       "cloud-denied": READER_SCOPES,
       "cloud-auditor": {"audit:read", "compute:read", "compute:network:read"},  # new
   }
   PRINCIPAL_PROVIDERS = {
       "superadmin":    ["*"],
       "cloud-denied":  ["aws", "nutanix"],
       "cloud-auditor": ["aws", "nutanix"],  # new
   }
   ```

   (Or, if the new scopes are write scopes, add them to `PROVISIONER_SCOPES`
   too — see [how_to_create_libcloud_rest_endpoint.md](how_to_create_libcloud_rest_endpoint.md)
   §1 step 3.)

2. **Make the JWT resolve to the slug.** Either:
   - make the LLDAP `uid` equal to the slug (`cloud-auditor`) so the
     known-principal fallback resolves it, **or**
   - add a `by_sub` / `by_email` entry in
     `../libcloud.rest/data/principal_map.json` — see
     [how_to_create_openfga_principal_mapping.md](how_to_create_openfga_principal_mapping.md).

3. **Write OpenFGA tuples** so `user:cloud-auditor` has the relations it
   needs (`can_connect libcloud_api:main`, `can_use provider:...`,
   `can_read <backend>`) — see
   [how_to_create_openfga_tuple.md](how_to_create_openfga_tuple.md).

4. **Recreate the REST API**:
   ```bash
   docker compose -f ../libcloud.rest/docker-compose.yml up -d --force-recreate libcloud-rest
   ```

---

## 3. MODIFY a principal

### 3.1 Change a principal's scopes / providers

Edit `PRINCIPAL_SCOPES` / `PRINCIPAL_PROVIDERS` (for non-suffix principals)
or `PROVISIONER_SCOPES` / `READER_SCOPES` (for the suffix classes — affects
**all** tenants' roles of that suffix). Recreate the REST API.

### 3.2 Rename a principal slug

1. Add the new slug per §2.
2. Repoint the JWT → new slug via `principal_map.json` (or rename the LLDAP
   `uid`, which means creating a new user — see
   [how_to_create_lldap_user.md](how_to_create_lldap_user.md)).
3. Rewrite the OpenFGA tuples from `user:<old>` to `user:<new>`
   (`openfga-tuple-delete.sh` + `openfga-tuple-write.sh`).
4. Remove the old principal (§4).

### 3.3 Change a principal's email

Update `principal_map.json` `by_email` — see
[how_to_create_openfga_principal_mapping.md](how_to_create_openfga_principal_mapping.md)
§3.1.

---

## 4. DELETE a principal

1. Remove the OpenFGA tuples for `user:<slug>` — see
   [how_to_create_openfga_tuple.md](how_to_create_openfga_tuple.md) §3, or
   use `scripts/chain-offboard-user.sh --username <uid>`.
2. Remove the `principal_map.json` entry (if any) — see
   [how_to_create_openfga_principal_mapping.md](how_to_create_openfga_principal_mapping.md)
   §4.
3. Remove the `PRINCIPAL_SCOPES` / `PRINCIPAL_PROVIDERS` entry (non-suffix
   principals only).
4. Offboard the LLDAP user whose `uid` matched the slug — see
   [how_to_create_lldap_user.md](how_to_create_lldap_user.md) §4.
5. Recreate the REST API.

> Never delete `superadmin` — it is the break-glass identity that gates
> Vault / OpenFGA / LLDAP admin operations.

---

## 5. VERIFY

```bash
# import check
python3 -c "import app.main"   # from ../libcloud.rest

# resolved principal + scopes for a logged-in user:
curl -s -H "Authorization: Bearer <jwt>" http://localhost:8765/v1/auth/me | jq

# OpenFGA decision for the principal:
scripts/openfga-check.sh user:<slug> can_connect libcloud_api:main

# End-to-end per role:
./system_validate.sh
```

Confirm: owner/admin get write scopes; viewer gets read-only; `cloud-denied`
passes authentication but fails `can_connect`; cross-cloud users fail
`can_use`.

---

## 6. Files touched

| File | What changes |
|------|--------------|
| `../libcloud.rest/app/auth/identity.py` | `PRINCIPAL_SCOPES` / `PRINCIPAL_PROVIDERS` (non-suffix only) or `PROVISIONER_SCOPES` / `READER_SCOPES` |
| `../libcloud.rest/data/principal_map.json` | `by_sub` / `by_email` entry (if JWT sub ≠ slug) |
| OpenFGA tuple store | `user:<slug>` tuples |
| LLDAP directory | the `uid` matching the slug |

---

## 7. Quick reference

| Action | Command |
|--------|---------|
| Recreate REST API | `docker compose -f ../libcloud.rest/docker-compose.yml up -d --force-recreate libcloud-rest` |
| Verify resolution | `GET /v1/auth/me` with the user's JWT |
| Verify authz | `scripts/openfga-check.sh user:<slug> <rel> <obj>` |
| Full validation | `./system_validate.sh` |
| Standard tenant role | no edit — use `scripts/create_tenant.sh` |
