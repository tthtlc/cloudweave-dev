# Where Administrator / Tenant Information Is Stored

Analysis of the present system, based on: `dex/ARCHITECTURE.md`, `libcloud.rest/ARCHITECTURE.md`, `libcloud/ARCHITECTURE.md`, `lldap/ARCHITECTURE.md`, `system_design/ARCHITECTURE.md`, `openfga_rules_architecture.md`.

Short answer: there is no single store — "who the admins are" is split across four different systems, each holding a different facet of it.

## 1. Who the admins *are* (identity + passwords) → LLDAP

- The user directory is the only place admin *people* exist: `superadmin`, `aws-owner`, `aws-admin`, `aws-viewer`, `ntnx-owner`, `ntnx-admin`, `ntnx-viewer` live under `ou=people,dc=libcloud,dc=local` with `uid`, `mail`, `cn` plus custom attrs `department`, `role`, `jobtitle` (`lldap/ARCHITECTURE.md` §Field mapping).
- Persisted in the `lldap_data` Docker volume (embedded DB). The LLDAP directory-admin itself is the built-in `uid=admin,ou=people,...` account, whose password is `LLDAP_LDAP_USER_PASS` in `lldap/.env`.
- **Dex stores no users at all** — `storage.type: memory`, no `staticPasswords`; it just binds to LLDAP over LDAP on every login (`dex/ARCHITECTURE.md` §3). A Dex restart loses only in-flight OAuth state, never identities.

## 2. Who is admin/owner/viewer *of which tenant* → OpenFGA tuples

This is the actual "administrator of cloud/tenant X" mapping, stored as relationship tuples in the OpenFGA datastore (Postgres-backed via `openfga_postgres`, seeded by `openfga_bootstrap.py`'s `INITIAL_TUPLES`, per `openfga_rules_architecture.md`):

- `user:aws-admin admin tenant:aws`, `user:aws-owner owner tenant:aws`
- `user:ntnx-admin admin tenant:nutanix`, `user:ntnx-owner owner tenant:nutanix`
- `user:superadmin superadmin platform:main` + owner on both tenants (break-glass)
- Backend objects tie tenants to clouds: `tenant:aws tenant aws_region:aws`, `tenant:nutanix tenant nutanix_cluster:nutanix`

Runtime role changes (portal "superadmin tuples" screen) are written as more tuples via `identity_service/app/fga.py` (`assign_role`/`write_tuples`) — data, not model changes. Note the deliberate design point (`system_design/ARCHITECTURE.md:161`, `dex/ARCHITECTURE.md:161`): **no group/role claims in the Dex JWT** — all role membership lives only in OpenFGA.

## 3. Principal → scopes/providers mapping → libcloud REST files

- `libcloud.rest/data/principal_map.json` — maps OIDC `sub`/`email` to stable principal slugs (`aws-admin`, …).
- `libcloud.rest/app/auth/identity.py` (`PRINCIPAL_SCOPES`) — each principal's API scopes and `allowed_providers` (`libcloud.rest/ARCHITECTURE.md:463-468`).
- Local-auth fallback (non-OIDC mode): a separate `admin` user with `ALL_SCOPES` in `libcloud.rest/data/users.json`, argon2id-hashed (`libcloud.rest/ARCHITECTURE.md:127-128, 436`).

## 4. The tenant's actual cloud credentials → Vault (not admin *identity*, but the keys admins operate under)

- Per-tenant KV v2 secrets: `secret/libcloud/aws`, `secret/libcloud/nutanix` (`system_design/ARCHITECTURE.md` §5.5).
- Writable **only by the tenant owner** via `scripts/set_tenant_credentials.py`, gated on the OpenFGA `can_manage_credentials` relation; new tenants minted by `scripts/create_tenant.sh` (superadmin-gated). libcloud REST reads them at runtime; clients never see them.

## Bootstrap copies (derived, not authoritative)

- `dex/generated/dex.env` — per-user LLDAP passwords (`LIBCLOUD_USER_*` / `LIBCLOUD_PASSWORD_*`) used to seed LLDAP and log in through Dex, plus the OAuth client secret.
- `generated/fga.env` — OpenFGA store/model IDs.

## Summary chain

**LLDAP** says the person exists and proves their password → **Dex** turns that into a JWT (storing nothing) → **principal_map.json / identity.py** resolves the JWT to a principal → **OpenFGA** says that principal is admin/owner/viewer of `tenant:aws` / `tenant:nutanix` → **Vault** holds that tenant's cloud credentials, which only the owner (per OpenFGA) can set.
