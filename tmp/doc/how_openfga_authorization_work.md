# How OpenFGA Authorization Works in `./libcloud.rest`

## Architecture Overview

The authorization is a **multi-layer enforcement pipeline** that runs automatically on every request **before** the route handler executes. There are four key files:

---

### 1. Entry Point: `AuthorizedAPIRoute` — `app/auth/authorized_route.py`

Every provisioning router (compute, network, storage, connections, jobs, admin) is built via:

```python
router = make_authorized_router(prefix="/v1/compute", tags=["compute"])
```

This returns a FastAPI `APIRouter` whose `route_class=AuthorizedAPIRoute`. On every request, `AuthorizedAPIRoute.get_route_handler()` (line 84) runs **before** the actual handler:

1. **Policy table lookup** (line 86): Looks up `"{METHOD} {path}"` in the hot-reloadable `policies.json`. Missing entry → **500 fail-closed** (never silently allows).

2. **Token resolution** (line 88): Extracts `TokenClaims` from the bearer token.

3. **Connection resolution** (line 92): Extracts `ProviderConnection` from the `X-Provider-Connection` header.

4. **Authorization call** (line 114):
   ```python
   policy_engine.authorize_connection(claims, connection, authz_scope)
   ```

5. **Stashes** `request.state.connection` and `request.state.authorized_claims` for the handler. The handler itself contains **zero authorization logic**.

---

### 2. Policy Engine: `PolicyEngine.authorize_connection()` — `app/auth/policy.py:115-148`

This is the core authorization method. It runs **three sequential gates**:

**Gate 1 — Scope check** (line 121-128): Verifies the token's `scope` claim includes the required scope (with `READ_SCOPE_ALIASES` expansion — e.g., `compute:read` implies `compute:image:read`).

**Gate 2 — Provider allow-list** (line 130-140): Checks `claims.allowed_providers` includes the requested provider (or `*` wildcard).

**Gate 3 — OpenFGA enforcement** (line 147): Calls `_enforce_openfga()`:

```python
# app/auth/policy.py:73-96
def _enforce_openfga(self, claims, connection, required_scope):
    fga = get_fga_client()
    if not fga.enabled:
        return                          # <-- bypass if FGA is disabled

    user = self._fga_user(claims)       # "user:<principal>"
    bearer = claims.access_token        # Dex JWT forwarded to OpenFGA

    fga.require(user, "can_connect", settings.fga_api_object, bearer=bearer)     # ①
    fga.require(user, "can_use", f"provider:{connection.provider}", bearer=bearer) # ②

    backend = self._backend_object(connection)  # e.g. "aws_region:<tenant>"

    if required_scope in WRITE_SCOPES or required_scope.endswith(":manage"):
        fga.require(user, "can_provision", backend, bearer=bearer)  # ③ write
    else:
        if not fga.check(user, "can_read", backend, bearer=bearer):
            fga.require(user, "can_provision", backend, bearer=bearer)  # ④ read, fallback to provision
```

So for every request, OpenFGA checks up to **three relations**:

| # | Relation | Object | Meaning |
|---|----------|--------|---------|
| ① | `can_connect` | API-level object (e.g., `rest_api:main`) | Can the user talk to this API at all? |
| ② | `can_use` | `provider:<cloud>` (e.g., `provider:aws`) | Can the user use this cloud provider? |
| ③/④ | `can_provision` / `can_read` | `<type>:<tenant>` (e.g., `aws_region:acme-corp`) | Can the user read/provision on this tenant's backend? |

---

### 3. FGA Client: `FgaClient` — `app/auth/fga_client.py`

Makes the actual HTTP call to the OpenFGA server:

- **`check()`** (line 27-51): POSTs to `{FGA_API_URL}/stores/{store_id}/check` with the tuple `{user, relation, object}`. Returns `bool`. On HTTP error → `APIError(503, "authz_fga_error")`. On network error → `APIError(503, "authz_fga_unavailable")`.

- **`require()`** (line 68-75): Calls `check()` and raises `APIError(403, "authz_fga_denied")` if not allowed.

- The caller's Dex-issued JWT is forwarded as a Bearer token so OpenFGA can validate it when running with OIDC authn (line 40-41).

---

### 4. Policy Table: `policies.json` — `app/auth/policies.json`

A hot-reloadable JSON file mapping every route to:
- `scopes_any_of` — required token scopes
- `authz_scope` — the specific scope passed to `authorize_connection` (determines read vs. write OpenFGA check)
- `capability` — optional driver capability check (e.g., `create_node`)
- `connection_required` — `false` for routes like `GET /v1/jobs/{job_id}` that skip OpenFGA entirely

---

### 5. Policy Table Loader: `PolicyTable` — `app/auth/policy_table.py`

Loads `policies.json` into memory at startup. Auto-reloads on mtime change (no restart needed). Raises `policy_unknown_operation` (500 fail-closed) if a route has no entry — never silently allows.

---

## Full Request Flow (summary)

```
Request → AuthorizedAPIRoute.get_route_handler()
  ├─ policy_table.get("GET /v1/compute/nodes")    ← policies.json
  ├─ claims_from_request(request)                  ← Dex JWT
  ├─ connection_from_request(request)              ← X-Provider-Connection header
  └─ policy_engine.authorize_connection()
       ├─ _token_has_scope()          → 403 if scope missing
       ├─ allowed_providers check     → 403 if provider denied
       └─ _enforce_openfga()
            ├─ FGA: can_connect(rest_api:main)      → 403 if denied
            ├─ FGA: can_use(provider:aws)            → 403 if denied
            └─ FGA: can_read/can_provision(aws_region:<tenant>) → 403 if denied
                   ↓
            Route handler (zero auth logic — just reads request.state.connection)
```

---

## Key Files Summary

| File | Role |
|------|------|
| `app/auth/authorized_route.py` | FastAPI route subclass — intercepts every request before the handler |
| `app/auth/policy.py` | Policy engine — combines scope, provider allowlist, and OpenFGA checks |
| `app/auth/fga_client.py` | Low-level HTTP client to OpenFGA's `/check` API |
| `app/auth/policies.json` | Hot-reloadable table mapping every route to required scopes |
| `app/auth/policy_table.py` | In-memory loader for `policies.json` with auto-reload on mtime change |

---

## Configuration (from `app/config/settings.py`)

```python
fga_enabled: bool = False
fga_api_url: str = "http://localhost:8080"
fga_store_id: str = ""
fga_model_id: str = ""
fga_api_object: str = "libcloud_api:main"
fga_nutanix_cluster: str = "nutanix"
fga_aws_region_object: str = "aws"
```

## Provider Object Types Registry (from `app/connections/models.py`)

```python
PROVIDER_OBJECT_TYPES: dict[str, str] = {
    "aws": "aws_region",
    "nutanix": "nutanix_cluster",
}
```

This is the single registry used by `_backend_object()` in the policy engine. Adding a new cloud provider requires only a registry entry + an OpenFGA model type — no new code branch.

---

## Identity Mapping (from `app/auth/identity.py`)

- Maps OIDC token claims to stable application principal slugs used by OpenFGA (`user:{principal}`).
- For role-suffix principals, permits all providers and lets OpenFGA's `can_use(provider:<cloud>)` enforce per-cloud boundaries.

---

## Test Configuration (from `tests/conftest.py`)

Tests force `FGA_ENABLED=false` so OpenFGA is bypassed during test runs:

```python
os.environ["FGA_ENABLED"] = "false"
```
