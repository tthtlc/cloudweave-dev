# How to Add a New URL (GET / POST) Authorized by Role

This guide lists **every step** (and every file) involved when you add a new
REST endpoint to `../libcloud.rest` and want it authorized by user role —
`superadmin` / `owner` / `admin` / `viewer`.

> **Read this first — the model in one paragraph.**
> Roles do **not** bind directly to URLs. The chain is:
>
> `role (owner/admin/viewer)` → **JWT scopes** (`identity.py`) → **OpenFGA relation** (`policy.py`) → **URL** (`routes.py`)
>
> So when you add a URL you (a) **pick or define a scope** for it,
> (b) **declare that scope on the route** via `require_scopes(...)` /
> `require_any_scopes(...)`, and (c) **make sure each role that should reach the
> URL is granted that scope** in `identity.py`. OpenFGA's `can_provision` /
> `can_read` relations already exist — you almost never touch the OpenFGA model
> for a new URL on an **existing** resource type. You only extend the model when
> the URL acts on a **brand-new kind of object**.

---

## 0. The four authorization layers (recap)

```
Dex JWT  →  Principal map  →  JWT scopes  →  OpenFGA  →  Cloud API
  (who)        (sub→slug)      (may call?)   (may use?)  (how)
```

| Layer | Question | File | Per-role behavior |
|-------|----------|------|-------------------|
| 1 | Who is calling? | Dex OIDC → `app/auth/oidc_service.py` | All authenticated users pass. |
| 2 | May they call this *operation*? | `app/auth/identity.py` (`PROVISIONER_SCOPES` / `READER_SCOPES`) + `app/auth/dependencies.py` (`require_scopes`) | `owner`/`admin`/`superadmin` → `PROVISIONER_SCOPES`; `viewer` → `READER_SCOPES`. |
| 3 | May they use this *provider/backend*? | `app/auth/policy.py::_enforce_openfga` | write scope → `can_provision`; read scope → `can_read` (fallback `can_provision`). |
| 4 | How do we reach the cloud? | `app/connections/credentials.py` → Vault → driver | Server-side identity; client never sends creds. |

Layer 2 is the one you touch when adding a URL. Layer 3 is automatic **if**
the URL is on an existing resource type (`aws_region` / `nutanix_cluster`).

---

## 1. Decide what the URL does and pick its scope

Answer three questions; the answers determine every later step.

1. **Read or write?** (GET vs POST/PATCH/DELETE)
   - **Read** → map to a `*:read` scope → OpenFGA `can_read` (viewer allowed).
   - **Write** → map to a `*:manage` / `*:create` / `*:delete` scope → OpenFGA `can_provision` (viewer **denied**).
2. **Does the URL act on a provider backend** (needs a `ProviderConnection`,
   hits a cloud), **or is it control-plane only** (jobs, auth, providers list)?
   - Provider URL → must call `policy_engine.authorize_connection(...)` so
     layers 3 (OpenFGA `can_use` / `can_provision` / `can_read`) run.
   - Non-provider URL → scope check alone is enough (Layer 2 only).
3. **Is the resource type already in OpenFGA** (`aws_region` / `nutanix_cluster`
   / `tenant` / `provider` / `libcloud_api` / `platform`)? If **yes**, no model
   change. If **no**, see §6 — you must extend the OpenFGA model.

**Pick the scope name.** Follow the existing convention:

| Verb | Scope pattern | Example |
|------|---------------|---------|
| `GET` list/get | `<resource>:read` (or alias of `compute:read`) | `compute:network:read` |
| `POST`/`PATCH`/`DELETE` mutate | `<resource>:manage` (or `<resource>:create`/`:delete`) | `compute:network:manage`, `compute:node:create` |

Reusing an existing scope means **zero role-table edits** (every role already
has or lacks it). Introducing a new scope means the role tables in §4 must be
updated.

---

## 2. Add the route (`app/<domain>/routes.py`)

Register the URL on the domain router with the scope dependency. Two shapes:

### 2a. Provider URL (GET, connection from query string)

```python
@router.get("/volumes")  # GET example — read
def list_volumes(
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    claims: TokenClaims = Depends(require_any_scopes("compute:volume:manage", "compute:read")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:read")
    data = [v.model_dump() for v in compute_service.list_volumes(connection)]
    return success_response(data, request)
```

### 2b. Provider URL (POST, connection in body)

```python
@router.post("/volumes")  # POST example — write
def create_volume(
    body: VolumeCreateRequest,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("compute:volume:manage")),
):
    connection = policy_engine.authorize_connection(claims, body.connection, "compute:volume:manage")
    policy_engine.check_driver_capability(connection, "volumes")  # optional
    ...
    return success_response(result, request)
```

The two mandatory pieces on a provider URL:

- `Depends(require_scopes("<scope>"))` or `Depends(require_any_scopes(...))`
  → enforces **Layer 2** (JWT scope). Returns `403 auth_insufficient_scope`
  if the role's scopes don't include it.
- `policy_engine.authorize_connection(claims, connection, "<scope>")`
  → enforces **Layers 3** (`can_connect` → `can_use` → `can_provision` /
  `can_read`). This is what actually distinguishes `aws-admin` from
  `ntnx-viewer` at the backend object.

### 2c. Non-provider URL (e.g. jobs, providers list)

```python
@router.get("/{job_id}")
def get_job(
    job_id: str,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("jobs:read")),
):
    ...
```

No `authorize_connection` call — OpenFGA is not consulted. Add an
`admin:connections:read`-style override only if you want a platform-admin
escape hatch (see `app/jobs/routes.py`).

> **If the router file is new**, also register it in `app/main.py`:
> `app.include_router(<domain>_router)`. Existing domains (`compute`,
> `network`, `connections`, `providers`, `jobs`, `auth`) are already wired.

---

## 3. If you introduced a NEW scope name — register it

Only skip this if you reused an existing scope (`compute:read`,
`compute:node:create`, etc.).

| File | Change |
|------|--------|
| `app/connections/models.py` → `ALL_SCOPES` | Add the new scope string so local-auth `admin` and the OpenAPI scope catalog know about it. |
| `app/auth/policy.py` → `WRITE_SCOPES` (for write URLs) **or** `READ_SCOPE_ALIASES` (for read URLs) | Add the scope so `_enforce_openfga` routes write scopes to `can_provision` and read scopes to `can_read`. A scope **not** in either set still works for the scope gate, but OpenFGA will fall back to `can_read`→`can_provision` — be deliberate. |

`WRITE_SCOPES` membership → `fga.require(user, "can_provision", backend)`.
Anything else → `can_read` first, then `can_provision` fallback.

---

## 4. Grant the scope to each role that should reach the URL

`app/auth/identity.py`:

| Constant | Who gets it | Effect |
|----------|-------------|--------|
| `PROVISIONER_SCOPES` | `superadmin`, `*-owner`, `*-admin` | Write **and** read access. Add new write/read scopes here to let owner/admin use the URL. |
| `READER_SCOPES` | `*-viewer` | Read access only. Add new **read** scopes here so viewers can call the URL; **never** add write scopes here. |

The role-suffix logic (`_role_suffix` / `principal_scopes`) means any
`<tenant>-owner` / `<tenant>-admin` / `<tenant>-viewer` is recognized
automatically — you only edit the two scope lists, not the per-principal
tables. `PRINCIPAL_SCOPES` only needs an entry for non-suffix principal names.

**Decision table for a new scope `X`:**

| URL type | `PROVISIONER_SCOPES` | `READER_SCOPES` | Result |
|----------|----------------------|-----------------|--------|
| Write (`*:manage`/`:create`/`:delete`) | add `X` | — | owner/admin ✓, viewer ✗ (scope 403) |
| Read (`*:read`) | add `X` | add `X` | owner/admin ✓, viewer ✓ (OpenFGA `can_read`) |
| Admin-only (neither viewer nor default tenant admins) | add `X` | — | only owner/admin/superadmin ✓ |

---

## 5. (Optional) Per-object authorization on non-provider URLs

If the URL is **not** provider-backed but still needs per-tenant or per-object
checks (e.g. "view this job only if you own it"), do it inline in the handler —
see `app/jobs/routes.py`:

```python
if job.requested_by != claims.sub and "admin:connections:read" not in claims.scope.split():
    raise APIError(code="auth_connection_denied", ..., status_code=403)
```

This is Layer-2 logic; OpenFGA is not involved.

---

## 6. Only if the URL acts on a NEW kind of object — extend OpenFGA

Skip entirely for URLs on `aws_region` / `nutanix_cluster` / `tenant` /
`provider` / `libcloud_api` / `platform` — the relations `can_read` /
`can_provision` / `can_use` / `can_connect` already exist.

If the URL introduces a new protected object type (e.g. `billing_account:*`,
`image_registry:*`), also do:

| File | Change |
|------|--------|
| `openfga_bootstrap.py` → `LIBCLOUD_MODEL` | Add the type with relations mirroring `aws_region` (`provider`, `tenant`, `operator`, `viewer`, `tenant_admin`/`tenant_owner`/`tenant_viewer`, `can_read`, `can_provision`). Add a computed relation if the URL needs a finer-grained one (e.g. `can_audit`). |
| `openfga_bootstrap.py` → `INITIAL_TUPLES` | Seed `provider:<cloud> provider <type>:<id>` and `tenant:<id> tenant <type>:<id>` so tenant roles propagate. |
| `openfga_bootstrap.py` → `VALIDATION_CHECKS` | Add allow/deny checks for each role on the new object. |
| `app/auth/policy.py::_enforce_openfga` | If you added a new **relation** (not just a type), branch on the scope to call `fga.require(user, "<new relation>", backend)`. |
| `app/connections/models.py` → `PROVIDER_OBJECT_TYPES` | Only if the new object is the backend for a whole new **cloud provider** (that's Case B in `how_to_add_new_tenant.md`, not this guide). |
| `authorization.md` / `ARCHITECTURE.md` | Add the new type to the object/relation table and the permissions matrix. |

Re-run the superadmin-gated bootstrap to push the new model + tuples:
`SUPERADMIN_JWT=… python openfga_bootstrap.py`.

---

## 7. Validate

```bash
# Syntax / import checks
python3 -m py_compile ../libcloud.rest/app/<domain>/routes.py
python3 -c "import app.main"  # run from ../libcloud.rest

# Boot the API and exercise the URL as each role
# owner/admin → expect success; viewer → expect 403 on write, 200 on read;
# cloud-denied → expect 401/403; cross-cloud user → expect 403 from OpenFGA.
./system_validate.sh
```

Manual smoke test per role (example for a new write URL):

```bash
# owner — should succeed
LIBCLOUD_USER=aws-owner LIBCLOUD_PASSWORD='<pw>' ./scripts/provision_aws.sh
# admin — should succeed
LIBCLOUD_USER=aws-admin LIBCLOUD_PASSWORD='<pw>' ./scripts/provision_aws.sh
# viewer — should get 403 auth_insufficient_scope (no write scope) or
#          403 from OpenFGA can_provision (scope present but relation denied)
LIBCLOUD_USER=aws-viewer LIBCLOUD_PASSWORD='<pw>' ./scripts/provision_aws.sh
# cross-cloud — should get 403 auth_provider_denied / OpenFGA can_use denied
LIBCLOUD_USER=ntnx-admin LIBCLOUD_PASSWORD='<pw>' ./scripts/provision_aws.sh
```

---

## 8. Quick file-change matrix

| Case | `routes.py` | `models.py` (`ALL_SCOPES`) | `policy.py` (`WRITE_SCOPES`/`READ_SCOPE_ALIASES`) | `identity.py` (`PROVISIONER_SCOPES`/`READER_SCOPES`) | `openfga_bootstrap.py` | `main.py` |
|------|-------------|----------------------------|---------------------------------------------------|------------------------------------------------------|------------------------|-----------|
| Reuse existing scope, existing object type (e.g. another `GET` on compute) | ✓ | — | — | — | — | (only if new router) |
| New scope, existing object type | ✓ | ✓ | ✓ | ✓ | — | (only if new router) |
| New object type / new relation | ✓ | ✓ | ✓ (if new relation) | ✓ | ✓ (model + tuples + checks) | (only if new router) |
| New cloud provider backend object | see `how_to_add_new_tenant.md` Case B instead | | | | | |

---

## 9. Worked example — add `GET /v1/compute/networks/{id}/audit`

A read-only audit endpoint on an existing resource (networks), granted to
owners/admins **and** viewers.

1. **Scope**: reuse `compute:network:read` (already exists, aliased to
   `compute:read`). No `ALL_SCOPES` / `WRITE_SCOPES` / `READ_SCOPE_ALIASES`
   edits.
2. **Route** in `app/network/routes.py`:

   ```python
   @router.get("/networks/{network_id}/audit")
   def audit_network(
       network_id: str,
       request: Request,
       connection: ProviderConnection = Depends(parse_connection_query),
       claims: TokenClaims = Depends(require_any_scopes("compute:network:read", "compute:read")),
   ):
       connection = policy_engine.authorize_connection(claims, connection, "compute:network:read")
       data = network_service.audit_network(connection, network_id)
       return success_response(data, request)
   ```

3. **Role tables**: no change — `compute:network:read` is already in both
   `PROVISIONER_SCOPES` and `READER_SCOPES`.
4. **OpenFGA**: no change — `can_read` on `aws_region`/`nutanix_cluster`
   already covers it.
5. **Validate**: viewer gets 200 (read allowed); cross-cloud user gets 403
   from `can_use`; `cloud-denied` gets 403 from `can_connect`.

Total files touched: **one** (`app/network/routes.py`).

### Worked example — add `POST /v1/compute/networks/{id}:lock` (write, viewer-denied)

1. **Scope**: reuse existing write scope `compute:network:manage`.
2. **Route** (POST, connection in body):

   ```python
   @router.post("/networks/{network_id}:lock")
   def lock_network(
       network_id: str,
       body: NetworkUpdateRequest,
       request: Request,
       claims: TokenClaims = Depends(require_scopes("compute:network:manage")),
   ):
       connection = policy_engine.authorize_connection(claims, body.connection, "compute:network:manage")
       result = network_service.lock_network(connection, network_id, body)
       return success_response(result, request)
   ```

3. **Role tables**: no change — `compute:network:manage` is in
   `PROVISIONER_SCOPES` only. Viewers fail Layer 2 (`403
   auth_insufficient_scope`).
4. **OpenFGA**: `compute:network:manage` ∈ `WRITE_SCOPES` already →
   `can_provision` enforced on the backend object. No model change.

Total files touched: **one**.

---

## Related documents

| Document | Focus |
|----------|-------|
| [authorization.md](authorization.md) | OpenFGA model, relations, permissions matrix |
| [how_to_add_new_tenant.md](how_to_add_new_tenant.md) | Adding tenants / cloud providers |
| `../libcloud.rest/app/auth/policy.py` | Runtime enforcement (`_enforce_openfga`) |
| `../libcloud.rest/app/auth/identity.py` | Role → scope mapping |
| `../libcloud.rest/app/auth/dependencies.py` | `require_scopes` / `require_any_scopes` |
