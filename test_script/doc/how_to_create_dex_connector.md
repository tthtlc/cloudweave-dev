# How to Create / Modify / Delete a Dex Connector

This guide covers **Dex connectors** (`../dex`): the LDAP connector that
federates authentication to LLDAP today, and the optional Phase-2 upstream
OIDC connector (Entra ID / Authentik / AD) that lets you swap the user
directory without changing the issuer.

> **What a connector is here.** A Dex connector is an upstream authentication
> provider. Dex stays the **stable OIDC issuer**; connectors are where the
> user directory actually lives. Today there is exactly one connector —
> `type: ldap` pointing at `lldap:3890`. The principal identity (`uid`) is
> stable across connector changes, so OpenFGA tuples and Vault bindings
> survive a connector swap.

---

## 0. The seeded LDAP connector

```yaml
connectors:
  - type: ldap
    id: lldap
    name: LLDAP
    config:
      host: lldap:3890
      insecureNoSSL: true
      bindDN: uid=admin,ou=people,dc=libcloud,dc=local
      bindPW: <rendered from LLDAP_BIND_PW>
      userSearch:
        baseDN: ou=people,dc=libcloud,dc=local
        filter: "(objectClass=person)"
        username: uid
        idAttr: uid
        emailAttr: mail
        nameAttr: cn
```

- `host: lldap:3890` — LLDAP on `libcloud_net`, resolved by container DNS.
- `insecureNoSSL: true` — fine for the isolated single-host dev network; use
  LDAPS for production.
- The service-account bind (`uid=admin,…`) is used **only** for user lookups;
  the user's own password is verified by Dex binding as that user at login.
- **No group search** is configured — group/membership enforcement is done by
  OpenFGA tuples, not by Dex claims.

Attribute mapping that keeps principals stable:

| LLDAP attr | Dex claim | Used by |
|------------|-----------|---------|
| `uid` | OIDC `sub` | OpenFGA tuples (`user:cloud-admin`), `principal_map` `by_sub` |
| `mail` | OIDC `email` | libcloud REST `principal_map` `by_email` |
| `cn` | OIDC `name` | display only |

---

## 1. Prerequisites

- `../dex` and `../openfga_my` are checked out; `setup.sh` has run.
- For an upstream OIDC connector: client id + secret + issuer URL from the
  upstream IdP, and a redirect URI registered there
  (`http://localhost:5556/dex/callback` for host, or the in-cluster URL).

---

## 2. ADD a connector

### 2a. Add a second upstream OIDC connector (Phase 2)

Edit `../dex/config.template.yaml` and append under `connectors`:

```yaml
connectors:
  - type: ldap
    id: lldap
    name: LLDAP
    config: { ... as above ... }
  - type: oidc
    id: entra
    name: Entra ID
    config:
      issuer: https://login.microsoftonline.com/<tenant>/v2.0
      clientID: <entra-client-id>
      clientSecret: __ENTRA_CLIENT_SECRET__
      redirectURI: http://localhost:5556/dex/callback
      insecureEnableGroups: true
      emailAsUserID: true     # or map object IDs in principal_map.json
```

An example snippet is in `../dex/config.phase2.example.yaml` — merge it into
`config.yaml` on cutover.

Teach `../openfga_my/dex_bootstrap.py` how to resolve any new placeholder
(e.g. `__ENTRA_CLIENT_SECRET__`) and to write it into `generated/dex.env`.

### 2b. Re-render and recreate Dex

```bash
cd ../openfga_my
SUPERADMIN_JWT=<...> python3 dex_bootstrap.py
docker compose -f ../dex/docker-compose.yml up -d --force-recreate dex
```

### 2c. Add `principal_map` entries for the new subject form

If the upstream IdP issues an opaque GUID as `sub` (instead of the LLDAP
`uid`), add `by_sub` entries to `../libcloud.rest/data/principal_map.json`
mapping each upstream object ID → the stable principal slug
(`cloud-admin`, `aws-admin`, …). See
[how_to_create_openfga_principal_mapping.md](how_to_create_openfga_principal_mapping.md).

OpenFGA tuples stay unchanged (still `user:cloud-admin`, etc.).

---

## 3. MODIFY a connector

Edit `config.template.yaml` (e.g. switch `insecureNoSSL: true` → LDAPS,
change `host`, rotate `bindPW`), re-run `dex_bootstrap.py`, and recreate Dex.

For the LDAP connector's `bindPW`, the value comes from `LLDAP_BIND_PW`
(sourced from `../lldap/.env` by `setup.sh`). If you rotate the LLDAP admin
password, re-run `setup.sh` (or `dex_bootstrap.py` after re-exporting
`LLDAP_BIND_PW`) so `config.yaml` picks up the new bind password.

---

## 4. DELETE / replace a connector

The cutover from LLDAP to an upstream IdP is the typical "delete" path:

1. Bring the new connector up **alongside** the LDAP connector (§2a) and
   verify users can log in through it.
2. Add `principal_map.json` entries for every upstream subject (§2c).
3. Disable any password DB (none here — `enablePasswordDB` is already off).
4. Remove the `type: ldap` block from `config.template.yaml`.
5. Re-run `dex_bootstrap.py` and recreate Dex.
6. Leave OpenFGA tuples unchanged — they reference stable principal slugs.

Existing Dex-issued refresh tokens are lost on recreate
(`storage.type: memory`); users must re-login.

---

## 5. VERIFY

```bash
# Discovery still served:
curl -s http://localhost:5556/dex/.well-known/openid-configuration | jq .issuer
# "http://dex:5556/dex"

# Login through the new connector (browser or idp_login.py with the
# connector id) and confirm the resulting JWT has the expected sub/email:
scripts/idp_login.py   # prints the JWT; decode with verify_superadmin_jwt.py

# Confirm the JWT still validates at OpenFGA:
scripts/openfga-check.sh user:<uid> can_connect libcloud_api:main
```

---

## 6. Files touched

| File | What changes |
|------|--------------|
| `../dex/config.template.yaml` | `connectors` entry added / changed / removed |
| `../dex/config.yaml` | re-rendered (do not hand-edit) |
| `../dex/config.phase2.example.yaml` | reference snippet for the upstream connector |
| `../openfga_my/dex_bootstrap.py` | new placeholder resolver + `generated/dex.env` writer |
| `generated/dex.env` | new connector secret (if any) |
| `../libcloud.rest/data/principal_map.json` | `by_sub` entries for new subject form (Phase 2) |
| OpenFGA tuples | **unchanged** (principals are stable slugs) |

---

## 7. Quick reference

| Action | Command |
|--------|---------|
| Re-render config | `python3 ../openfga_my/dex_bootstrap.py` |
| Recreate Dex | `docker compose -f ../dex/docker-compose.yml up -d --force-recreate dex` |
| Reload after config edit | `docker compose -f ../dex/docker-compose.yml restart dex` |
| Phase-2 reference | `../dex/config.phase2.example.yaml` |
