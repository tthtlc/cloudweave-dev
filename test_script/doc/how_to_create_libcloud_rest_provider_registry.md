# How to Create / Modify / Delete a libcloud REST Provider Registry Entry

This guide covers the **provider registry** in `../libcloud.rest`: the small
set of data tables that teach the gateway about a cloud provider — its
OpenFGA object type, its capability surface, and how to build its driver. It
is the libcloud.rest-side companion to
[how_to_add_new_tenant.md](how_to_add_new_tenant.md) Case B (which is the
full cross-project procedure for a new cloud).

> **What a registry entry is here.** Three things, all in
> `../libcloud.rest`:
> 1. `app/connections/models.py::PROVIDER_OBJECT_TYPES` — `provider id →
>    OpenFGA object type` (e.g. `"aws": "aws_region"`). `policy.py::_backend_object`
>    looks the type up here, so no per-provider branch is needed in the auth
>    path.
> 2. `app/providers/routes.py::PROVIDERS` — the public capability catalog
>    (`GET /v1/providers`) entries with `fga_object_type` and
>    `supported_operations`.
> 3. `app/providers/factory.py::build_driver` — the `if connection.provider
>    == "<id>": return create_<id>_driver(...)` branch, plus the
>    `app/providers/<id>.py` module that constructs the libcloud driver.
>
> Plus optional: `app/connections/credentials.py` `_PROVIDER_TO_DEFAULT_BINDING`
> and a `_env_credentials` branch (dev fallback only — Vault is preferred).

---

## 0. The current registry

| `connection.provider` | OpenFGA object type | Driver builder | Backend |
|-----------------------|---------------------|----------------|---------|
| `aws`     | `aws_region`       | `app/providers/aws.py::create_aws_driver`     | `EC2NodeDriver` → EC2 Query API |
| `nutanix` | `nutanix_cluster`  | `app/providers/nutanix.py::create_nutanix_driver` | `NutanixNodeDriver` → Prism Central v4 REST |

`ProviderConnection.provider` is validated against `PROVIDER_OBJECT_TYPES`
keys (no `Literal` enum to edit).

---

## 1. Prerequisites

- `../libcloud.rest` and `../libcloud` are checked out.
- The OpenFGA model already has (or will have) the new backend object type —
  see [how_to_create_openfga_authorization_model.md](how_to_create_openfga_authorization_model.md).
- The libcloud driver for the new cloud exists (or you will add it) — see
  [how_to_create_libcloud_cloud_driver.md](how_to_create_libcloud_cloud_driver.md).
- You can recreate the REST API.

---

## 2. ADD a provider (e.g. `gcp`, object type `gcp_region`)

### Step 1 — `app/connections/models.py`

```python
PROVIDER_OBJECT_TYPES = {
    "aws":     "aws_region",
    "nutanix": "nutanix_cluster",
    "gcp":     "gcp_region",   # new
}
```

This single line makes `ProviderConnection(provider="gcp")` valid **and**
makes `policy.py::_backend_object` derive `gcp_region:<auth_binding>`. No
other change in the auth path.

### Step 2 — `app/providers/routes.py`

Add a `gcp` entry to `PROVIDERS` with `"fga_object_type":
PROVIDER_OBJECT_TYPES["gcp"]` and its `supported_operations`:

```python
PROVIDERS = {
  "aws":     {"fga_object_type": "aws_region",     "supported_operations": [...]},
  "nutanix": {"fga_object_type": "nutanix_cluster","supported_operations": [...]},
  "gcp":     {"fga_object_type": "gcp_region",     "supported_operations": [...]},  # new
}
```

### Step 3 — `app/providers/gcp.py` (NEW)

```python
from libcloud.compute.providers import get_driver, Provider

def create_gcp_driver(key: str, secret: str, config: dict):
    # build the GCP libcloud driver from key/secret/config
    ...
    return driver
```

Mirror `app/providers/aws.py` / `nutanix.py`.

### Step 4 — `app/providers/factory.py`

```python
def build_driver(connection):
    creds = effective_credentials(connection)
    if connection.provider == "aws":     return create_aws_driver(...)
    if connection.provider == "nutanix": return create_nutanix_driver(...)
    if connection.provider == "gcp":     return create_gcp_driver(creds.key, creds.secret, connection.config)  # new
    raise ValueError(f"Unsupported provider: {connection.provider}")
```

### Step 5 — (Optional) dev-fallback credentials

`app/connections/credentials.py`:

- add `"gcp": "gcp"` to `_PROVIDER_TO_DEFAULT_BINDING` (so
  `default_auth_binding` falls back to the provider id).
- optionally add a `gcp` branch to `_env_credentials` (dev fallback only —
  Vault is the preferred credential broker).

### Step 6 — Recreate + validate

```bash
python3 -c "import app.main"   # from ../libcloud.rest
docker compose -f ../libcloud.rest/docker-compose.yml up -d --force-recreate libcloud-rest

# Confirm the registry + capability endpoint:
curl -s -H "Authorization: Bearer <jwt>" http://localhost:8765/v1/providers | jq
```

For the full cross-project steps (LLDAP users, OpenFGA tuples, Dex bootstrap,
scripts) see [how_to_add_new_tenant.md](how_to_add_new_tenant.md) Case B.

---

## 3. MODIFY a provider

| Change | Where |
|--------|-------|
| Change `supported_operations` / capability surface | `app/providers/routes.py::PROVIDERS` |
| Change the driver builder (e.g. new libcloud driver version) | `app/providers/<id>.py` and/or `factory.py` |
| Change the OpenFGA object type for a provider | `PROVIDER_OBJECT_TYPES` (rare — also requires OpenFGA model + tuple migration) |
| Change default `auth_binding` | `app/connections/credentials.py::_PROVIDER_TO_DEFAULT_BINDING` |

Recreate the REST API after editing.

---

## 4. DELETE a provider

> Destructive — every tenant on that provider stops working. Offboard
> tenants first (revoke Vault leases, remove OpenFGA tuples, offboard users —
> see [how_to_add_new_tenant.md](how_to_add_new_tenant.md) for the inverse
> of Case B).

1. Remove the `PROVIDER_OBJECT_TYPES` entry, the `PROVIDERS` entry, the
   `factory.py` branch, and `app/providers/<id>.py`.
2. Remove the OpenFGA model type + tuples for `<object_type>` — see
   [how_to_create_openfga_authorization_model.md](how_to_create_openfga_authorization_model.md) §5.
3. Remove any `_PROVIDER_TO_DEFAULT_BINDING` / `_env_credentials` branch.
4. Remove the LLDAP users / Dex bootstrap entries / scripts for that cloud
   (see [how_to_add_new_tenant.md](how_to_add_new_tenant.md) Case B inverted).
5. Recreate the REST API and run `./system_validate.sh`.

---

## 5. VERIFY

```bash
# Registry knows the provider:
python3 -c "from app.connections.models import PROVIDER_OBJECT_TYPES; \
  assert 'gcp' in PROVIDER_OBJECT_TYPES"

# Capability endpoint lists it:
curl -s -H "Authorization: Bearer <jwt>" http://localhost:8765/v1/providers | jq

# Backend object derivation:
python3 -c "from app.auth.policy import PolicyEngine; from app.connections.models import ProviderConnection; \
  print(PolicyEngine()._backend_object(ProviderConnection(provider='gcp', auth_binding='gcp')))"
# → gcp_region:gcp

# End-to-end provision:
LIBCLOUD_GCP_AUTH_BINDING=gcp LIBCLOUD_USER=gcp-admin ./scripts/provision_gcp.sh
```

---

## 6. Files touched

| File | What changes |
|------|--------------|
| `app/connections/models.py` | `PROVIDER_OBJECT_TYPES` entry |
| `app/providers/routes.py` | `PROVIDERS` entry |
| `app/providers/factory.py` | `build_driver` branch |
| `app/providers/<id>.py` | NEW (driver builder) |
| `app/connections/credentials.py` | (optional) `_PROVIDER_TO_DEFAULT_BINDING` + `_env_credentials` |
| `REST_API_REFERENCE.md` | backend-objects list + example tuples |

`app/auth/policy.py` and `app/auth/identity.py` are **not** touched for a
new suffix-shaped provider — the registry is what makes it work.

---

## 7. Quick reference

| Action | Command |
|--------|---------|
| Recreate REST API | `docker compose -f ../libcloud.rest/docker-compose.yml up -d --force-recreate libcloud-rest` |
| Capability endpoint | `GET /v1/providers` |
| Full validation | `./system_validate.sh` |
| Cross-project guide | [how_to_add_new_tenant.md](how_to_add_new_tenant.md) Case B |
| New driver (libcloud side) | [how_to_create_libcloud_cloud_driver.md](how_to_create_libcloud_cloud_driver.md) |
