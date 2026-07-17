# How to Create / Modify / Delete a libcloud REST Connection (auth_binding + Vault Binding)

This guide covers the **connection object** in `../libcloud.rest`: the
per-request payload that selects the cloud backend (`provider` + `config` +
`credentials`) and the **`auth_binding`** that selects which per-tenant
backend object + Vault secret the REST API uses at runtime.

> **What a connection is here.** Every compute/network call carries a
> `connection`:
>
> ```json
> { "provider": "aws",
>   "config": { "region": "ap-southeast-1", "secure": true },
>   "credentials": { "key": "AKIA...", "secret": "..." },
>   "auth_binding": "aws-dev" }
> ```
>
> - `provider` → routes to `build_driver()` (see
>   [how_to_create_libcloud_rest_provider_registry.md](how_to_create_libcloud_rest_provider_registry.md)).
> - `credentials` → optional; if absent, the REST API reads them from Vault
>   using `auth_binding`.
> - `auth_binding` → the tenant id used to derive the OpenFGA backend object
>   (`aws_region:<auth_binding>`) and the Vault secret path
>   (`secret/libcloud/<auth_binding>`).
>
> Transport: `GET`/`DELETE` carry `connection` as a query param
> (`?connection=<url-encoded-json>`); `POST`/`PATCH` carry it in the JSON
> body. Client scripts also send `auth_binding` in the `X-Provider-Connection`
> header.

---

## 0. How `auth_binding` becomes a backend object + secret

```
client sends connection { provider, auth_binding, ... }
  → policy.py::_backend_object  → aws_region:<auth_binding>      (OpenFGA object)
  → credentials.py::effective_credentials
       → if connection.credentials present: use them (dev/test only)
       → else: Vault GET secret/data/libcloud/<auth_binding>     (per-tenant)
  → build_driver(provider, creds) → libcloud driver → cloud API
```

So a **per-tenant binding** is two things that must agree:
1. An OpenFGA backend object `aws_region:<auth_binding>` (or
   `nutanix_cluster:<auth_binding>`) with the right `tenant` relation — see
   [how_to_add_new_tenant.md](how_to_add_new_tenant.md) Case A.
2. A Vault secret at `secret/libcloud/<auth_binding>` written by the tenant
   owner — see [how_to_create_vault_secret.md](how_to_create_vault_secret.md) §2b.

---

## 1. Prerequisites

- `../libcloud.rest` is up and the provider registry knows `provider` (see
  [how_to_create_libcloud_rest_provider_registry.md](how_to_create_libcloud_rest_provider_registry.md)).
- The tenant `<auth_binding>` exists in OpenFGA (or you are about to create
  it — see [how_to_add_new_tenant.md](how_to_add_new_tenant.md) Case A).
- The tenant owner has written `secret/libcloud/<auth_binding>` to Vault.

---

## 2. ADD a per-tenant binding (new tenant on an existing cloud)

This is **Case A** in [how_to_add_new_tenant.md](how_to_add_new_tenant.md).
No source edits — all runtime state:

```bash
# 1. superadmin mints the tenant (LLDAP users + OpenFGA tuples + dex.env lines):
TENANT=aws-dev CLOUD=aws ./scripts/create_tenant.sh

# 2. owner writes the backend creds to Vault (OpenFGA can_manage_credentials gate):
TENANT=aws-dev CLOUD=aws \
  LIBCLOUD_USER=aws-dev-owner LIBCLOUD_PASSWORD='<owner-pw>' \
  LIBCLOUD_AWS_KEY=AKIA... LIBCLOUD_AWS_SECRET=... \
  python3 scripts/set_tenant_credentials.py

# 3. admin provisions against the new tenant:
LIBCLOUD_AWS_AUTH_BINDING=aws-dev LIBCLOUD_USER=aws-dev-admin \
  LIBCLOUD_PASSWORD='<admin-pw>' ./scripts/provision_aws.sh
```

`create_tenant.sh` writes the OpenFGA tuples that create
`aws_region:aws-dev` and wire `tenant:aws-dev` → `aws_region:aws-dev`.
`set_tenant_credentials.py` writes `secret/libcloud/aws-dev` to Vault. The
REST API derives the same `aws_region:aws-dev` from `auth_binding=aws-dev`
and reads the same Vault path — end-to-end isolation holds with **no code
edits**.

---

## 3. MODIFY a binding

### 3.1 Change the backend credentials for a tenant

Owner re-runs `set_tenant_credentials.py` with the new values — see
[how_to_create_vault_secret.md](how_to_create_vault_secret.md) §3. KV v2
creates a new version; the REST API reads the latest version on the next
request.

### 3.2 Change the `auth_binding` a client uses

This is a client-side change — set `LIBCLOUD_AWS_AUTH_BINDING=<new>` (or the
equivalent for the cloud). The new binding must already exist in OpenFGA +
Vault (§2).

### 3.3 Change the default `auth_binding` for a provider

`app/connections/credentials.py::_PROVIDER_TO_DEFAULT_BINDING` and the
settings overrides in `app/config/settings.py` / `.env`. `default_auth_binding`
already falls back to the provider id for any provider not in the overrides.

### 3.4 Rotate a tenant's cloud creds + revoke old leases

1. Owner runs `set_tenant_credentials.py` (new Vault version).
2. Revoke any dynamic leases issued under the old creds — see
   [how_to_create_vault_secrets_engine.md](how_to_create_vault_secrets_engine.md) §6.

---

## 4. DELETE a binding (offboard a tenant)

1. Revoke any Vault leases for the tenant's creds — see
   [how_to_create_vault_secrets_engine.md](how_to_create_vault_secrets_engine.md) §6.
2. Destroy / delete the Vault secret at `secret/libcloud/<auth_binding>` —
   see [how_to_create_vault_secret.md](how_to_create_vault_secret.md) §5.
3. Remove the OpenFGA tuples for the tenant and its backend object — see
   [how_to_create_openfga_tuple.md](how_to_create_openfga_tuple.md) §3
   (`--confirm` for the structural `parent`/`provider`/`tenant` triples).
4. Offboard the tenant's LLDAP users — see
   [how_to_create_lldap_user.md](how_to_create_lldap_user.md) §4 (or
   `scripts/chain-offboard-user.sh` per user).
5. Remove the `LIBCLOUD_PASSWORD_<TENANT>_*` lines from `generated/dex.env`.

> Do **not** just delete the Vault secret and stop — the OpenFGA backend
> object `aws_region:<auth_binding>` would still grant `can_provision` /
> `can_read` to the tenant's users, who would then 500 at request time
> because the Vault read fails. Always remove the tuples too.

---

## 5. VERIFY

```bash
# The tenant tuple graph is correct:
scripts/openfga-check.sh user:aws-dev-admin can_provision aws_region:aws-dev   # True
scripts/openfga-check.sh user:aws-dev-viewer can_provision aws_region:aws-dev  # False
scripts/openfga-check.sh user:aws-admin       can_use provider:aws             # True
scripts/openfga-check.sh user:aws-admin       can_provision aws_region:aws-dev # False (cross-tenant)

# The Vault secret is readable by the REST API token:
VAULT_TOKEN="$VAULT_TOKEN" curl -s \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  http://localhost:8200/v1/secret/data/libcloud/aws-dev | jq .data.data

# End-to-end targeted provision:
LIBCLOUD_AWS_AUTH_BINDING=aws-dev LIBCLOUD_USER=aws-dev-admin \
  LIBCLOUD_PASSWORD='<admin-pw>' ./scripts/provision_aws.sh

# Full regression:
./system_validate.sh
```

---

## 6. Files touched

| File / store | What changes |
|--------------|--------------|
| OpenFGA tuple store | new / removed `tenant:<binding>` + `aws_region:<binding>` triples |
| Vault KV (`secret/libcloud/<binding>`) | new version / destroyed / deleted |
| LLDAP directory | tenant users created / offboarded |
| `generated/dex.env` | new / removed per-tenant user+password lines |
| `../libcloud.rest/.env` | (only if you change the default binding for a provider) |
| `app/connections/credentials.py` | (only if you change `_PROVIDER_TO_DEFAULT_BINDING`) |

**No `policy.py` / `identity.py` / `models.py` edits** for a per-tenant
binding — that is the whole point of the registry-driven design.

---

## 7. Quick reference

| Action | Command |
|--------|---------|
| Create tenant binding | `TENANT=<t> CLOUD=<c> ./scripts/create_tenant.sh` |
| Owner sets creds | `TENANT=<t> CLOUD=<c> LIBCLOUD_USER=<owner> ... python3 scripts/set_tenant_credentials.py` |
| Provision against tenant | `LIBCLOUD_<CLOUD>_AUTH_BINDING=<t> LIBCLOUD_USER=<admin> ./scripts/provision_<cloud>.sh` |
| Check | `scripts/openfga-check.sh user:<u> <rel> <obj>` |
| Full validation | `./system_validate.sh` |
| Long-form guide | [how_to_add_new_tenant.md](how_to_add_new_tenant.md) |
