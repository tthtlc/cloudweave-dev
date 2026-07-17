# Full Source-Code Trace: libcloud REST API Security Architecture

## Client–Server Execution, Layered Authorization, and Complete API Coverage

---

## 1. Architecture Overview

The security model splits across two repositories and six layers:

```
┌─────────────────────────────────────────────────────────────┐
│  openfga_my/                    libcloud.rest/               │
│  (infrastructure / scripts)     (REST API server)            │
│                                                              │
│  provision_aws.sh ──OIDC token──►  FastAPI middleware        │
│  common.sh                           │                       │
│  idp_login.py                        ▼                       │
│                              Layer 1: JWT decode + identity  │
│                              Layer 2: Scope + provider gate  │
│                              Layer 3: Credential policy      │
│                              Layer 4: OpenFGA enforcement    │
│                              Layer 5: Vault credential fetch │
│                              Layer 6: Cloud operation        │
│                                      │                       │
│  openfga_bootstrap.py ──seeds──► OpenFGA tuple store         │
│                              ◄──checks── FgaClient           │
│                                                              │
│  vault_bootstrap.py ──seeds──► Vault KV v2                   │
│                              ◄──reads── VaultClient          │
└─────────────────────────────────────────────────────────────┘
```

| Step | execution_path.md | Where enforced | Repo |
|------|-------------------|----------------|------|
| 1. Authenticate | OIDC token from Dex | Client script → Dex IdP | `openfga_my/` |
| 2. Extract identity | Resolve principal + group memberships | Server `oidc_service.py` | `libcloud.rest/` |
| 3. OpenFGA check | BEFORE every cloud operation | Server `policy.py` | `libcloud.rest/` |
| 4. Fetch Vault creds | Resolve backend cloud identity | Server `credentials.py` | `libcloud.rest/` |
| 5. Execute | libcloud → cloud provider | Server service layer | `libcloud.rest/` |

The client script (`provision_aws.sh`) performs **only Step 1** — OIDC authentication. Steps 2–5 run **server-side** inside the REST API on every request. The client never handles cloud credentials or makes OpenFGA calls directly.

---

## 2. Client-Side Execution (Step 1 Only)

### 2.1 Entry Point

**File:** `openfga_my/scripts/provision_aws.sh` — line 50
```bash
idp_login
```

This calls the function defined in `openfga_my/scripts/common.sh`, lines 222–235:

```python
idp_login() {
  local user="${1:-$LIBCLOUD_USER}"
  local password="${2:-$LIBCLOUD_PASSWORD}"
  : "${password:?Password required for user ${user}}"

  step "1" "Dex IdP login (OIDC authorization code flow) user=${user}"
  export LIBCLOUD_USER="${user}" LIBCLOUD_PASSWORD="${password}"
  ACCESS_TOKEN=$(python3 "${SCRIPT_DIR}/idp_login.py")
}
```

### 2.2 OIDC Authorization Code Flow

**File:** `openfga_my/scripts/idp_login.py`

| Step | Function | Lines | What it does |
|------|----------|-------|-------------|
| 1 | `dex_login()` | 195–240 | Opens Dex authorization page, submits LDAP credentials via form POST, captures OAuth2 authorization code from local callback server |
| 2 | `_exchange_code()` | 111–138 | Exchanges authorization code for access + refresh tokens at Dex `/dex/token` |
| 3 | `_save_cache()` | 173–175 | Caches tokens to `generated/tokens/<username>.json` for reuse |
| 4 | `_refresh()` | 141–157 | On subsequent runs, refreshes cached token instead of full login |

**User identity mapping** — lines 39–48:
```python
USER_UID = {
    "cloud-admin": "cloud-admin",
    "cloud-readonly": "cloud-readonly",
    "cloud-denied": "cloud-denied",
    "admin": "cloud-admin",
    "provisioner": "cloud-admin",
    "reader": "cloud-readonly",
    "outsider": "cloud-denied",
}
```
Maps script-level usernames to LLDAP UIDs. Dex authenticates against LLDAP over LDAP (`uid=` match).

### 2.3 Token Propagation

Every `libcloud_api` call in `common.sh` (lines 292–304) attaches the token:
```bash
libcloud_api() {
  local method="$1" path="$2" body="${3:-}"
  local -a extra=()
  # Send the provider connection via the X-Provider-Connection header (never via
  # the `?connection=` query parameter, which leaks into logs/proxies/history).
  if [[ -n "${CONNECTION_PARAM}" ]]; then
    extra+=("-H" "X-Provider-Connection: ${CONNECTION_PARAM}")
  fi
  curl_http "${method}" "${LIBCLOUD_REST_URL}${path}" "${body}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Accept: application/json" \
    "${extra[@]}"
}
```

The `X-Provider-Connection` header (line 298) carries only `provider` + `region` + `auth_binding` (a tenant selector, **not** a secret):
```json
{"provider":"aws","config":{"region":"ap-southeast-1","secure":true},"auth_binding":"aws"}
```

### 2.4 Client-Side OpenFGA Preview (Disabled by Default)

`common.sh` lines 259–273 define `openfga_authorization_flow()`, which performs the same `can_connect` / `can_use` / `can_provision` checks the server will enforce. It is **commented out** in `provision_aws.sh` line 51:

```bash
#openfga_authorization_flow "aws" "${AWS_BACKEND_OBJECT}"
```

This is a convenience preview, not a security gate — the real enforcement is server-side (Section 3.5).

---

## 3. Server-Side Execution — Six-Layer Authorization Chain

Every cloud operation request passes through six sequential layers inside the REST API. Any layer can reject the request with a 401 or 403 before a single byte reaches the cloud provider.

### 3.1 Layer 0 — HTTP Bearer Token Extraction

**File:** `libcloud.rest/app/auth/dependencies.py`, lines 38–47

```python
_bearer = HTTPBearer(auto_error=False)

def get_current_claims(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> TokenClaims:
    if not credentials or credentials.scheme.lower() != "bearer":
        raise APIError(code="auth_invalid_token", message="Bearer token required",
                       status_code=401)
    return _decode_token(credentials.credentials)
```

Every protected route depends on `get_current_claims` (directly or through `require_scopes`/`require_any_scopes`). No token → 401.

### 3.2 Layer 1 — JWT Decode + Identity Resolution

#### 3.2.1 Token Decode

**File:** `libcloud.rest/app/auth/dependencies.py`, lines 13–35

```python
def _decode_token(token: str) -> TokenClaims:
    mode = settings.auth_mode.lower()     # "oidc"
    if mode == "oidc":
        return oidc_auth_service.decode_access_token(token)
```

**File:** `libcloud.rest/app/auth/oidc_service.py`, lines 87–148

```python
def decode_access_token(self, token: str) -> TokenClaims:
    # 1. Validate JWT signature against Dex JWKS (line 96-101)
    header = jwt.get_unverified_header(token)
    if alg.startswith("HS"):
        payload = self._decode_with_client_secret(token, settings)
    else:
        payload = self._decode_with_jwks(token, settings)  # RS256/ES256/PS256

    # 2. Resolve stable principal slug (line 115)
    principal = resolve_principal(payload)

    # 3. Map principal → scopes (line 116)
    scopes = principal_scopes(principal)

    # 4. Map principal → allowed providers (line 125)
    providers = principal_providers(principal)

    # 5. Return TokenClaims with bearer token preserved for OpenFGA forwarding
    return TokenClaims(
        sub=principal,
        scope=" ".join(scopes),
        allowed_providers=providers,
        access_token=token,       # ← forwarded to OpenFGA for OIDC authn
        ...
    )
```

#### 3.2.2 Principal Resolution (Step 2 in execution_path.md)

**File:** `libcloud.rest/app/auth/identity.py`, lines 106–149

Resolution order:
```
1. principal_map.by_sub[sub]           ← explicit sub→principal mapping
2. principal_map.by_email[email]       ← email→principal mapping
3. legacy_username_aliases[username]   ← legacy name→principal mapping
4. sub if it matches a known principal ← direct match
5. preferred_username / username       ← fallback to Dex claim
```

Known principals and their scopes/providers — lines 50–70:

| Principal | Scopes | Allowed Providers |
|-----------|--------|-------------------|
| `superadmin` | All 14 scopes (PROVISIONER_SCOPES) | `["*"]` |
| `aws-owner` | All 14 scopes | `["aws"]` |
| `aws-admin` | All 14 scopes | `["aws"]` |
| `aws-viewer` | 6 read scopes (READER_SCOPES) | `["aws"]` |
| `ntnx-owner` | All 14 scopes | `["nutanix"]` |
| `ntnx-admin` | All 14 scopes | `["nutanix"]` |
| `ntnx-viewer` | 6 read scopes | `["nutanix"]` |
| `cloud-denied` | 6 read scopes | `["aws", "nutanix"]` |

**Role suffix resolution** — lines 152–165: principals matching `<tenant>-(owner|admin|viewer)` (e.g., `aws-dev-admin`) automatically get provisioner/reader scopes and `["*"]` providers **without** being listed in the static tables. OpenFGA enforces the actual per-tenant boundary.

#### 3.2.3 TokenClaims Model

**File:** `libcloud.rest/app/auth/models.py`, lines 34–49

```
TokenClaims
  sub: str                 ← stable application principal (e.g. "aws-admin")
  iss: str                 ← OIDC issuer (Dex)
  aud: str                 ← JWT audience
  iat / nbf / exp: int     ← JWT timestamps
  jti: str                 ← JWT id
  scope: str               ← space-separated JWT scopes
  tenant_id: str           ← OIDC tenant id
  allowed_providers: list  ← e.g. ["aws"] or ["*"]
  session_id: str          ← session id (sid/jti)
  access_token: str | None ← raw Bearer token for downstream forwarding
```

### 3.3 Layer 2 — JWT Scope Gate + Provider Allowlist

**File:** `libcloud.rest/app/auth/policy.py`, lines 98–131

```python
def authorize_connection(self, claims, connection, required_scope):
    # --- Gate 1: Token scope check (line 104-111) ---
    token_scopes = set(claims.scope.split())
    if not self._token_has_scope(token_scopes, required_scope):
        raise APIError(code="auth_insufficient_scope", status_code=403,
                       details={"required_scope": required_scope})

    # --- Gate 2: Provider allowlist (line 113-123) ---
    allowed_providers = set(claims.allowed_providers)
    if "*" not in allowed_providers and connection.provider not in allowed_providers:
        raise APIError(code="auth_provider_denied", status_code=403,
                       details={"provider": connection.provider})
```

**Scope alias expansion** — lines 11–19: `compute:read` expands to include `compute:image:read`, `compute:size:read`, `compute:location:read`, `compute:network:read`. This lets read-only endpoints accept either a specific scope or the broad `compute:read`.

**Provider allowlist** — `aws-viewer` has `["aws"]`, so any request with `connection.provider == "nutanix"` fails here before OpenFGA is even consulted.

### 3.4 Layer 3 — Credential Policy Enforcement

**File:** `libcloud.rest/app/connections/credentials.py`, lines 30–43

```python
def enforce_credential_policy(connection):
    if connection.credentials is not None and not settings.allow_client_credentials:
        raise APIError(code="auth_client_credentials_forbidden", status_code=403,
                       message="Client-supplied backend credentials are not accepted. "
                               "The API uses its own backend identity; set 'auth_binding' "
                               "instead of 'credentials'.")
```

Called inside `authorize_connection` at line 128. Rejects any client that attempts to pass cloud credentials directly. The client may only specify `auth_binding` (a tenant ID), which the server resolves to actual credentials via Vault (Layer 5).

### 3.5 Layer 4 — OpenFGA Authorization Enforcement (Step 3 in execution_path.md)

#### 3.5.1 Enforcement Entry Point

**File:** `libcloud.rest/app/auth/policy.py`, lines 73–96

```python
def _enforce_openfga(self, claims, connection, required_scope):
    fga = get_fga_client()
    if not fga.enabled:
        return                          # ← short-circuit when FGA not configured

    user = self._fga_user(claims)       # → "user:aws-admin"
    bearer = claims.access_token        # forward Dex JWT to OpenFGA

    # Check 1: Can this principal connect to the API at all?
    fga.require(user, "can_connect", settings.fga_api_object, bearer=bearer)     # line 88

    # Check 2: Can this principal use this cloud provider?
    fga.require(user, "can_use", f"provider:{connection.provider}", bearer=bearer)  # line 89

    # Check 3: Can this principal read/provision on this backend?
    backend = self._backend_object(connection)  # → "aws_region:aws"
    if required_scope in WRITE_SCOPES or required_scope.endswith(":manage"):
        fga.require(user, "can_provision", backend, bearer=bearer)            # line 93
    else:
        if not fga.check(user, "can_read", backend, bearer=bearer):           # line 95
            fga.require(user, "can_provision", backend, bearer=bearer)        # line 96 (fallback)
```

**Three OpenFGA checks per request:**

| # | Relation | Object | Meaning |
|---|----------|--------|---------|
| 1 | `can_connect` | `libcloud_api:main` | Is this principal permitted to call the REST API at all? |
| 2 | `can_use` | `provider:aws` | Is this principal permitted to use this cloud provider? |
| 3a | `can_read` | `aws_region:aws` | Read-only access on this backend (viewer+). Falls back to check 3b. |
| 3b | `can_provision` | `aws_region:aws` | Write/provision access on this backend (admin+). Required for write scopes. |

**Write scope classification** — lines 21–31:
```python
WRITE_SCOPES = {
    "compute:node:create", "compute:node:delete", "compute:node:power",
    "compute:node:update", "compute:volume:manage", "compute:snapshot:manage",
    "compute:network:manage", "compute:keypair:manage", "compute:image:manage",
}
```

Any scope in this set → `can_provision` required. Any scope ending in `:manage` → `can_provision` required. Read scopes → `can_read` first, `can_provision` fallback.

#### 3.5.2 FGA User Resolution

**File:** `libcloud.rest/app/auth/policy.py`, lines 43–46

```python
def _fga_user(self, claims):
    aliases = (_load_map().get("legacy_username_aliases") or {})
    principal = aliases.get(claims.sub, claims.sub)
    return f"user:{principal}"
```

The `claims.sub` is the stable principal slug (e.g., `aws-admin`) resolved by `resolve_principal()` in Layer 1. This becomes `user:aws-admin` for the OpenFGA tuple key.

#### 3.5.3 Backend Object Resolution

**File:** `libcloud.rest/app/auth/policy.py`, lines 48–71

```python
def _backend_object(self, connection):
    obj_type = PROVIDER_OBJECT_TYPES.get(connection.provider)   # "aws" → "aws_region"
    binding = connection.auth_binding or default_auth_binding(connection.provider)
    return f"{obj_type}:{binding}"                              # → "aws_region:aws"
```

**Provider → Object Type Registry** — `libcloud.rest/app/connections/models.py`, lines 49–52:
```python
PROVIDER_OBJECT_TYPES = {
    "aws": "aws_region",
    "nutanix": "nutanix_cluster",
}
```

The `auth_binding` from the client's connection descriptor becomes the backend object ID. This is the per-tenant isolation mechanism: `auth_binding: "aws"` → `aws_region:aws`, `auth_binding: "aws-dev"` → `aws_region:aws-dev`. Each tenant has its own backend object, its own Vault secret, and its own OpenFGA tuples.

#### 3.5.4 OpenFGA HTTP Client

**File:** `libcloud.rest/app/auth/fga_client.py`

| Method | Lines | What it does |
|--------|-------|-------------|
| `enabled` (property) | 22–25 | `settings.fga_enabled and bool(self.store_id and self.model_id)` — when False, all checks pass through |
| `check()` | 27–66 | POST to `/stores/{store_id}/check` with `{authorization_model_id, tuple_key: {user, relation, object}}`. Returns `bool`. Forwards the Dex JWT as Bearer token. |
| `require()` | 68–75 | Calls `check()`; raises 403 `authz_fga_denied` if not allowed. |

**Check payload** — lines 31–34:
```python
payload = {
    "authorization_model_id": self.model_id,
    "tuple_key": {"user": user, "relation": relation, "object": obj},
}
```

**Error handling** — lines 52–66:
- `HTTPError` → 503 `authz_fga_error` (OpenFGA returned an error)
- `URLError` → 503 `authz_fga_unavailable` (OpenFGA unreachable)

**OIDC forwarding** — line 41:
```python
if bearer:
    headers["Authorization"] = f"Bearer {bearer}"
```
The caller's Dex-issued JWT is forwarded to OpenFGA. OpenFGA validates it against the same Dex JWKS. This means OpenFGA can enforce that only authenticated callers query the tuple store.

### 3.6 Layer 5 — Cloud Credential Resolution (Step 4 in execution_path.md)

#### 3.6.1 Resolution Entry Point

**File:** `libcloud.rest/app/connections/credentials.py`, lines 82–124

```python
def resolve_server_credentials(connection):
    binding = connection.auth_binding or _default_binding(connection.provider)

    # Preferred: Vault KV v2
    vault = get_vault_client()
    if vault.enabled:
        data = vault.read_secret(binding)              # line 95
        return ConnectionCredentials(key=..., secret=...)

    # Fallback: environment variables (dev only)
    creds = _env_credentials(provider, binding)         # line 112
```

Resolution order:
1. **Vault KV v2** — reads `secret/data/libcloud/<binding>` (line 95)
2. **Environment fallback** — `LIBCLOUD_AWS_PROD_KEY` / `LIBCLOUD_AWS_PROD_SECRET` (lines 70–79)

#### 3.6.2 Vault Client

**File:** `libcloud.rest/app/connections/vault_client.py`

| Aspect | Detail | Lines |
|--------|--------|-------|
| Enabled check | `bool(settings.vault_addr and settings.vault_token)` | 37–39 |
| Secret path | `/v1/{mount}/data/{kv_prefix}/{binding}` → `/v1/secret/data/libcloud/aws` | 41–43 |
| HTTP method | `GET` with `X-Vault-Token` header | 64–66 |
| Cache TTL | 30 seconds (in-memory only) | 29 |
| KV v2 data extraction | `payload["data"]["data"]` | 95 |
| 404 handling | 503 `server_credentials_missing` | 73–79 |
| Connection error | 503 `server_credentials_unavailable` | 87–93 |

#### 3.6.3 Settings

**File:** `libcloud.rest/app/config/settings.py`

Key configuration fields:

| Field | Default | Purpose |
|-------|---------|---------|
| `auth_mode` | `"oidc"` | Authentication mode (local/oidc/hybrid) |
| `oidc_issuer_url` | `""` | Dex issuer URL (`http://dex:5556/dex`) |
| `oidc_jwks_url` | `""` | Dex JWKS endpoint for JWT validation |
| `oidc_audience` | `"libcloud-rest"` | Required JWT audience |
| `fga_enabled` | `False` | Master switch for OpenFGA enforcement |
| `fga_api_url` | `"http://localhost:8080"` | OpenFGA server URL |
| `fga_store_id` | `""` | OpenFGA store ID (from bootstrap) |
| `fga_model_id` | `""` | OpenFGA model ID (from bootstrap) |
| `fga_api_object` | `"libcloud_api:main"` | Object for `can_connect` check |
| `allow_client_credentials` | `False` | When False, rejects client-supplied creds |
| `vault_addr` | `""` | Vault server URL |
| `vault_token` | `""` | Vault auth token |
| `vault_kv_prefix` | `"libcloud"` | KV path prefix for cloud creds |

### 3.7 Layer 6 — Cloud Operation Execution (Step 5 in execution_path.md)

After all five authorization layers pass, the route handler calls the service layer which drives libcloud. Example from `libcloud.rest/app/compute/routes.py`, lines 122–142:

```python
@router.post("/nodes")
def create_node(body: NodeCreateRequest, request: Request,
                claims: TokenClaims = Depends(require_scopes("compute:node:create"))):
    connection = policy_engine.authorize_connection(claims, body.connection, "compute:node:create")
    policy_engine.check_driver_capability(connection, "create_node")
    # → compute_service.create_node(connection, body)
    # → libcloud driver.create_node(...)
    # → AWS EC2 RunInstances API
```

The `authorize_connection` call (line 128) runs Layers 2–4. The service layer (`compute_service.create_node`) runs Layer 5 (credential resolution) then invokes the libcloud driver.

---

## 4. Complete API Surface — Endpoint × Authorization Mapping

### 4.1 Compute Endpoints

**File:** `libcloud.rest/app/compute/routes.py` (prefix: `/v1/compute`)

| # | Method | Path | Required Scope | OpenFGA Relation | Driver Capability Check | Line |
|---|--------|------|----------------|-----------------|------------------------|------|
| 1 | GET | `/locations` | `compute:location:read` † | `can_read` | — | 49–57 |
| 2 | GET | `/images` | `compute:image:read` † | `can_read` | — | 60–85 |
| 3 | GET | `/sizes` | `compute:size:read` † | `can_read` | — | 88–96 |
| 4 | GET | `/nodes` | `compute:read` | `can_read` | — | 99–107 |
| 5 | GET | `/nodes/{id}` | `compute:read` | `can_read` | — | 110–119 |
| 6 | POST | `/nodes` | `compute:node:create` | `can_provision` | `create_node` | 122–142 |
| 7 | PATCH | `/nodes/{id}` | `compute:node:power` or `compute:node:update` | `can_provision` | — | 145–156 |
| 8 | POST | `/nodes/{id}:start` | `compute:node:power` | `can_provision` | — | 159–168 |
| 9 | POST | `/nodes/{id}:stop` | `compute:node:power` | `can_provision` | — | 171–180 |
| 10 | POST | `/nodes/{id}:reboot` | `compute:node:power` | `can_provision` | — | 183–192 |
| 11 | DELETE | `/nodes/{id}` | `compute:node:delete` | `can_provision` | `destroy_node` | 195–225 |
| 12 | GET | `/volumes` | `compute:volume:manage` † | `can_read` | — | 228–237 |
| 13 | POST | `/volumes` | `compute:volume:manage` | `can_provision` | `volumes` | 240–260 |
| 14 | PATCH | `/volumes/{id}` | `compute:volume:manage` | `can_provision` | — | 263–272 |
| 15 | DELETE | `/volumes/{id}` | `compute:volume:manage` | `can_provision` | — | 275–284 |
| 16 | POST | `/volumes/{id}:attach` | `compute:volume:manage` | `can_provision` | — | 287–296 |
| 17 | POST | `/volumes/{id}:detach` | `compute:volume:manage` | `can_provision` | — | 299–308 |
| 18 | GET | `/snapshots` | `compute:snapshot:manage` † | `can_read` | — | 311–324 |
| 19 | POST | `/snapshots` | `compute:snapshot:manage` | `can_provision` | `snapshots` | 327–347 |
| 20 | DELETE | `/snapshots/{id}` | `compute:snapshot:manage` | `can_provision` | — | 350–360 |
| 21 | POST | `/images` | `compute:image:manage` | `can_provision` | — | 363–382 |
| 22 | DELETE | `/images/{id}` | `compute:image:manage` | `can_provision` | — | 385–394 |
| 23 | GET | `/key-pairs` | `compute:keypair:manage` † | `can_read` | — | 397–405 |
| 24 | POST | `/key-pairs` | `compute:keypair:manage` | `can_provision` | `key_pairs` | 408–417 |
| 25 | DELETE | `/key-pairs/{name}` | `compute:keypair:manage` | `can_provision` | `key_pairs` | 420–430 |

† Accepts `compute:read` as alternative scope via `require_any_scopes`.

### 4.2 Network Endpoints

**File:** `libcloud.rest/app/network/routes.py` (prefix: `/v1/compute`)

| # | Method | Path | Required Scope | OpenFGA Relation | Line |
|---|--------|------|----------------|-----------------|------|
| 26 | GET | `/networks` | `compute:network:read` † | `can_read` | 25–37 |
| 27 | POST | `/networks` | `compute:network:manage` | `can_provision` | 40–48 |
| 28 | PATCH | `/networks/{id}` | `compute:network:manage` | `can_provision` | 51–60 |
| 29 | DELETE | `/networks/{id}` | `compute:network:manage` | `can_provision` | 63–72 |
| 30 | GET | `/subnets` | `compute:network:read` † | `can_read` | 75–85 |
| 31 | POST | `/subnets` | `compute:network:manage` | `can_provision` | 88–96 |
| 32 | PATCH | `/subnets/{id}` | `compute:network:manage` | `can_provision` | 99–108 |
| 33 | DELETE | `/subnets/{id}` | `compute:network:manage` | `can_provision` | 111–120 |
| 34 | GET | `/storage-containers` | `compute:read` † | `can_read` | 123–132 |
| 35 | GET | `/security-groups` | `compute:network:read` † | `can_read` | 135–147 |
| 36 | POST | `/security-groups` | `compute:network:manage` | `can_provision` | 150–158 |
| 37 | DELETE | `/security-groups/{id}` | `compute:network:manage` | `can_provision` | 161–170 |
| 38 | GET | `/load-balancers` | `compute:network:read` † | `can_read` | 173–182 |
| 39 | POST | `/load-balancers` | `compute:network:manage` | `can_provision` | 185–193 |
| 40 | DELETE | `/load-balancers/{id}` | `compute:network:manage` | `can_provision` | 196–205 |
| 41 | GET | `/floating-ips` | `compute:network:read` † | `can_read` | 211–220 |
| 42 | POST | `/floating-ips` | `compute:network:manage` | `can_provision` | 223–231 |
| 43 | DELETE | `/floating-ips/{addr}` | `compute:network:manage` | `can_provision` | 234–244 |
| 44 | POST | `/floating-ips/{addr}:associate` | `compute:network:manage` | `can_provision` | 247–256 |
| 45 | POST | `/floating-ips/{addr}:disassociate` | `compute:network:manage` | `can_provision` | 259–268 |

† Accepts `compute:read` as alternative scope via `require_any_scopes`.

### 4.3 Storage Endpoints

**File:** `libcloud.rest/app/storage/routes.py` (prefix: `/v1/storage`)

| # | Method | Path | Required Scope | OpenFGA Relation | Line |
|---|--------|------|----------------|-----------------|------|
| 46 | GET | `/buckets` | `compute:read` † | `can_read` | 15–23 |
| 47 | POST | `/buckets` | `compute:network:manage` | `can_provision` | 26–34 |
| 48 | DELETE | `/buckets/{name}` | `compute:network:manage` | `can_provision` | 37–47 |
| 49 | GET | `/buckets/{name}/objects` | `compute:read` † | `can_read` | 50–60 |
| 50 | POST | `/buckets/{name}/objects` | `compute:network:manage` | `can_provision` | 63–74 |
| 51 | POST | `/buckets/{name}/objects/{path}:download` | `compute:read` † | `can_read` | 77–88 |
| 52 | DELETE | `/buckets/{name}/objects/{path}` | `compute:network:manage` | `can_provision` | 91–101 |

† Accepts `compute:network:read` as alternative scope via `require_any_scopes`.

### 4.4 Connections, Jobs, Auth, and Providers

**File:** `libcloud.rest/app/connections/routes.py` (prefix: `/v1/connections`)

| # | Method | Path | Required Scope | OpenFGA Relation | Line |
|---|--------|------|----------------|-----------------|------|
| 53 | POST | `:test` | `compute:read` | `can_read` | 13–25 |

**File:** `libcloud.rest/app/jobs/routes.py` (prefix: `/v1/jobs`)

| # | Method | Path | Required Scope | Additional Check | Line |
|---|--------|------|----------------|-----------------|------|
| 54 | GET | `/{job_id}` | `jobs:read` | Owner check: `job.requested_by == claims.sub` OR caller has `admin:connections:read` scope | 11–27 |

**File:** `libcloud.rest/app/auth/routes.py` (prefix: `/v1/auth`)

| # | Method | Path | Auth Required | Line |
|---|--------|------|---------------|------|
| 55 | POST | `/login` | None (local auth disabled in OIDC mode) | 27–31 |
| 56 | POST | `/refresh` | None (local auth disabled in OIDC mode) | 34–38 |
| 57 | POST | `/logout` | Bearer token (`get_current_claims`) | 41–49 |
| 58 | GET | `/me` | Bearer token (`get_current_claims`) | 52–63 |
| 59 | POST | `/token/introspect` | `admin:connections:read` | 66–74 |

**File:** `libcloud.rest/app/providers/routes.py` (prefix: `/v1/providers`)

| # | Method | Path | Auth Required | Line |
|---|--------|------|---------------|------|
| 60 | GET | `` (root) | **None** — public endpoint | 50–52 |

---

## 5. OpenFGA Authorization Model — Full Type Hierarchy

**File:** `openfga_my/openfga_bootstrap.py`, lines 190–489

### 5.1 Type Definitions (Schema 1.1)

```
┌──────────┐
│   user   │  (leaf type — no relations)
└────┬─────┘
     │  member of...
     ▼
┌──────────┐
│  tenant  │  owner → admin → viewer → member (union)
│          │  can_assign_owner, can_assign_admin, can_assign_viewer
│          │  can_manage_credentials (owner only)
│          │  can_provision (admin + owner), can_read (viewer + admin + owner)
└────┬─────┘
     │  parent of...
     ▼
┌───────────────┐
│  libcloud_api │  can_connect = direct + tenant#member (via parent tupleToUserset)
└───────────────┘

┌──────────┐
│ provider  │  parent (→ tenant), allowed (→ user)
│           │  can_use = direct + allowed + tenant#member (via parent tupleToUserset)
└────┬─────┘
     │  provider of...        tenant of...
     ▼                        ▼
┌─────────────┐    ┌──────────────────┐
│  aws_region  │    │  nutanix_cluster │   (identical structure)
│              │    │                   │
│ provider     │    │ provider          │   → links to provider:aws / provider:nutanix
│ tenant       │    │ tenant            │   → links to tenant:aws / tenant:nutanix
│ operator     │    │ operator          │   → directly assigned users
│ viewer       │    │ viewer            │   → directly assigned users
│              │    │                   │
│ tenant_admin │    │ tenant_admin      │   → tenant#admin (computed via tupleToUserset)
│ tenant_owner │    │ tenant_owner      │   → tenant#owner (computed)
│ tenant_viewer│    │ tenant_viewer     │   → tenant#viewer (computed)
│              │    │                   │
│ can_read     │    │ can_read          │   = viewer | operator | tenant_viewer |
│              │    │                   │     tenant_admin | tenant_owner |
│              │    │                   │     provider#can_use
│              │    │                   │
│ can_provision│    │ can_provision     │   = (operator | tenant_admin | tenant_owner)
│              │    │                   │     AND provider#can_use (intersection)
└─────────────┘    └──────────────────┘
```

### 5.2 Key Relationship: `can_provision` as Intersection

`can_provision` requires **both** conditions (intersection):

1. **Role condition** — principal is `operator`, `tenant_admin`, or `tenant_owner` on the backend object
2. **Provider condition** — principal has `can_use` on the linked `provider`

This is the mechanism that enforces per-cloud isolation. An `aws-admin` satisfies `operator` on `aws_region:aws` but has no `can_use` on `provider:nutanix`, so `can_provision` on `nutanix_cluster:nutanix` → **DENIED**.

### 5.3 Seeded Tuples

**File:** `openfga_my/openfga_bootstrap.py`, lines 502–533

**17 initial tuples** written by bootstrap:

| # | User | Relation | Object | Purpose |
|---|------|----------|--------|---------|
| 1 | `user:superadmin` | `superadmin` | `platform:main` | Platform bootstrap identity |
| 2 | `user:superadmin` | `owner` | `tenant:aws` | Break-glass AWS access |
| 3 | `user:superadmin` | `owner` | `tenant:nutanix` | Break-glass Nutanix access |
| 4 | `user:aws-owner` | `owner` | `tenant:aws` | AWS tenant owner |
| 5 | `user:aws-admin` | `admin` | `tenant:aws` | AWS tenant admin |
| 6 | `user:aws-viewer` | `viewer` | `tenant:aws` | AWS tenant viewer |
| 7 | `user:ntnx-owner` | `owner` | `tenant:nutanix` | Nutanix tenant owner |
| 8 | `user:ntnx-admin` | `admin` | `tenant:nutanix` | Nutanix tenant admin |
| 9 | `user:ntnx-viewer` | `viewer` | `tenant:nutanix` | Nutanix tenant viewer |
| 10 | `tenant:aws` | `parent` | `libcloud_api:main` | AWS tenant → API gateway |
| 11 | `tenant:nutanix` | `parent` | `libcloud_api:main` | Nutanix tenant → API gateway |
| 12 | `tenant:aws` | `parent` | `provider:aws` | AWS tenant → AWS provider |
| 13 | `tenant:nutanix` | `parent` | `provider:nutanix` | Nutanix tenant → Nutanix provider |
| 14 | `provider:aws` | `provider` | `aws_region:aws` | AWS provider → backend |
| 15 | `tenant:aws` | `tenant` | `aws_region:aws` | AWS tenant → backend |
| 16 | `provider:nutanix` | `provider` | `nutanix_cluster:nutanix` | Nutanix provider → backend |
| 17 | `tenant:nutanix` | `tenant` | `nutanix_cluster:nutanix` | Nutanix tenant → backend |

**Scale note:** User role assignments (e.g., `user:alice` → `member` of `tenant:aws`) are written separately by the identity reconciler (`scripts/openfga-tuple-reconcile.py`) and the `chain-role-assign.sh` flow. The bootstrap seeds only the static structural tuples. Tuple count stays **O(users × roles)** not **O(users × API paths)**.

### 5.4 Validation Checks

**File:** `openfga_my/openfga_bootstrap.py`, lines 536–578

**33 post-deploy validation checks** verify the model behaves correctly:

| Category | Examples | Lines |
|----------|----------|-------|
| Platform superadmin | `can_manage_platform`, `can_connect`, `can_use` on both providers, `can_provision` on both backends | 538–543 |
| AWS owner | `can_connect`, `can_use` AWS, `can_provision` AWS, `can_assign_admin` | 545–548 |
| AWS admin | `can_use` AWS, `can_provision` AWS, **cannot** `can_assign_admin` | 550–553 |
| Credential management | owner ✓, admin ✗, viewer ✗ (tested for both AWS and Nutanix) | 555–562 |
| AWS viewer | `can_read` ✓, `can_provision` ✗, `can_assign_viewer` ✗ | 564–567 |
| Cross-cloud isolation | `aws-admin` cannot `can_use` or `can_provision` Nutanix | 569–570 |
| Nutanix admin/viewer | mirror of AWS checks | 572–575 |
| Denied user | `cloud-denied` cannot `can_connect` | 577 |

---

## 6. Error Code Catalog

**File:** `libcloud.rest/app/common/errors.py`

All authorization errors are raised as `APIError` with structured JSON responses:

```json
{
  "error": {"code": "...", "message": "...", "details": {...}},
  "meta": {"request_id": "..."}
}
```

| HTTP | Code | Raised By | File:Line | Condition |
|------|------|-----------|-----------|-----------|
| 401 | `auth_invalid_token` | `dependencies.py:42` | Bearer header missing or malformed |
| 401 | `auth_invalid_token` | `oidc_service.py:109` | JWT signature invalid |
| 401 | `auth_expired_token` | `oidc_service.py:103` | JWT expired |
| 403 | `auth_insufficient_scope` | `policy.py:106` | Token lacks required scope |
| 403 | `auth_provider_denied` | `policy.py:115` | Principal not allowed to use this provider |
| 403 | `auth_client_credentials_forbidden` | `credentials.py:34` | Client supplied cloud credentials |
| 403 | `auth_user_unknown` | `identity.py:145` | OIDC principal cannot be mapped |
| 403 | `authz_fga_denied` | `fga_client.py:69` | OpenFGA returned `allowed: false` |
| 403 | `auth_connection_denied` | `jobs/routes.py:22` | Job ownership check failed |
| 503 | `authz_fga_error` | `fga_client.py:55` | OpenFGA returned HTTP error |
| 503 | `authz_fga_unavailable` | `fga_client.py:63` | OpenFGA unreachable |
| 503 | `server_credentials_missing` | `credentials.py:105` | Vault secret not found |
| 503 | `server_credentials_unavailable` | `vault_client.py:82` | Vault read failed |
| 503 | `server_credentials_unavailable` | `vault_client.py:88` | Vault unreachable |

---

## 7. Complete Authorization Flow (End-to-End Walkthrough)

What happens when **`aws-admin`** calls `POST /v1/compute/nodes` to provision an EC2 instance:

```
┌──────────────────────────────────────────────────────────────────────┐
│ CLIENT (openfga_my/scripts/provision_aws.sh)                         │
│                                                                      │
│  1. idp_login                                                        │
│     └─ idp_login.py → Dex /dex/auth → LLDAP uid=aws-admin           │
│     └─ Dex /dex/token → access_token (JWT, RS256, aud=libcloud-rest) │
│                                                                      │
│  2. build_aws_connection_param "ap-southeast-1"                      │
│     └─ connection = {provider:"aws", config:{region:"..."},          │
│                      auth_binding:"aws"}                             │
│                                                                      │
│  3. POST /v1/compute/nodes                                           │
│     └─ Authorization: Bearer <access_token>                          │
│     └─ X-Provider-Connection: <connection_json>                      │
│     └─ Body: {name, size, image, connection, ...}                    │
└──────────────────────┬───────────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────────────┐
│ SERVER (libcloud.rest/)                                              │
│                                                                      │
│  LAYER 0 — dependencies.py:38                                       │
│  └─ HTTPBearer extracts "Bearer <token>" from Authorization header   │
│                                                                      │
│  LAYER 1 — oidc_service.py:87                                       │
│  ├─ jwt.decode(token, Dex JWKS, aud="libcloud-rest")                │
│  ├─ resolve_principal(payload) → "aws-admin"                        │
│  ├─ principal_scopes("aws-admin") → PROVISIONER_SCOPES (14 scopes)  │
│  ├─ principal_providers("aws-admin") → ["aws"]                      │
│  └─ TokenClaims(sub="aws-admin", scope="compute:node:create ...",   │
│                  allowed_providers=["aws"], access_token=<raw_jwt>)  │
│                                                                      │
│  LAYER 2 — policy.py:98 authorize_connection()                      │
│  ├─ Gate 1: "compute:node:create" in token.scopes? → YES ✓          │
│  └─ Gate 2: "aws" in ["aws"]? → YES ✓                               │
│                                                                      │
│  LAYER 3 — credentials.py:30 enforce_credential_policy()            │
│  └─ connection.credentials is None? → skip (no client creds) ✓       │
│                                                                      │
│  LAYER 4 — policy.py:73 _enforce_openfga()                          │
│  ├─ fga.check("user:aws-admin", "can_connect", "libcloud_api:main") │
│  │   → tenant:aws → parent → libcloud_api:main → can_connect = true │
│  ├─ fga.require("user:aws-admin", "can_use", "provider:aws")        │
│  │   → tenant:aws#admin → member → parent → provider:aws            │
│  │   → can_use = true                                               │
│  └─ fga.require("user:aws-admin", "can_provision", "aws_region:aws")│
│      → tenant:aws#admin → tenant_admin → aws_region:aws             │
│      → AND provider:aws#can_use → true                              │
│      → can_provision = true ✓                                       │
│                                                                      │
│  LAYER 5 — credentials.py:82 resolve_server_credentials()           │
│  ├─ auth_binding = "aws"                                            │
│  ├─ VaultClient.read_secret("aws")                                  │
│  └─ → GET /v1/secret/data/libcloud/aws → {key, secret}              │
│                                                                      │
│  LAYER 6 — compute/service.py → libcloud driver                     │
│  └─ driver.create_node(name, size, image, ...)                      │
│  └─ → AWS EC2 RunInstances API                                      │
│  └─ → 201 Created {node_id, state, public_ips, ...}                  │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 8. File Reference Index

### Client-Side (openfga_my/)

| File | Purpose | Key Lines |
|------|---------|-----------|
| `scripts/provision_aws.sh` | AWS provisioning demo client | 50 (idp_login), 52 (build_connection), 57–116 (API calls) |
| `scripts/common.sh` | Shared curl helpers, OpenFGA preview | 222–235 (idp_login), 259–273 (openfga_authorization_flow), 292–304 (libcloud_api) |
| `scripts/idp_login.py` | OIDC authorization code flow against Dex | 195–240 (dex_login), 111–138 (token exchange), 39–48 (USER_UID map) |
| `openfga_bootstrap.py` | OpenFGA store/model/tuple seeding + validation | 190–489 (LIBCLOUD_MODEL), 502–533 (INITIAL_TUPLES), 536–578 (VALIDATION_CHECKS) |

### Server-Side (libcloud.rest/)

| File | Purpose | Key Lines |
|------|---------|-----------|
| `app/auth/dependencies.py` | Bearer extraction, scope gate dependency | 38–47 (get_current_claims), 50–63 (require_scopes), 66–78 (require_any_scopes) |
| `app/auth/oidc_service.py` | JWT decode, principal resolution, scope assignment | 87–148 (decode_access_token) |
| `app/auth/identity.py` | Principal mapping, scope/provider tables, role suffix | 50–70 (PRINCIPAL_SCOPES/PROVIDERS), 106–149 (resolve_principal), 152–165 (_role_suffix) |
| `app/auth/models.py` | TokenClaims, request/response models | 34–49 (TokenClaims) |
| `app/auth/policy.py` | Authorization engine: scope gate, provider gate, OpenFGA enforcement | 11–19 (READ_SCOPE_ALIASES), 21–31 (WRITE_SCOPES), 73–96 (_enforce_openfga), 98–131 (authorize_connection) |
| `app/auth/fga_client.py` | OpenFGA HTTP client: check/require | 27–66 (check), 68–75 (require) |
| `app/connections/credentials.py` | Credential policy, Vault/env credential resolution | 30–43 (enforce_credential_policy), 82–124 (resolve_server_credentials) |
| `app/connections/vault_client.py` | Vault KV v2 client with in-memory cache | 45–105 (read_secret) |
| `app/connections/models.py` | ProviderConnection, PROVIDER_OBJECT_TYPES registry | 49–52 (PROVIDER_OBJECT_TYPES), 55–81 (ProviderConnection) |
| `app/config/settings.py` | All configuration, env-var mapping | 13–117 (Settings) |
| `app/common/errors.py` | APIError, structured error responses | 7–50 |
| `app/compute/routes.py` | 25 compute endpoints | 49–430 (all routes) |
| `app/network/routes.py` | 20 network endpoints | 25–268 (all routes) |
| `app/storage/routes.py` | 7 storage endpoints | 15–101 (all routes) |
| `app/connections/routes.py` | Connection test endpoint | 13–25 |
| `app/jobs/routes.py` | Job status endpoint | 11–27 |
| `app/auth/routes.py` | Auth endpoints (login/me/introspect) | 27–74 |
| `app/providers/routes.py` | Provider catalog (public) | 50–52 |

### Documentation

| File | Location | Purpose |
|------|----------|---------|
| `execution_path.md` | `openfga_my/` | Conceptual 5-step auth flow, OpenFGA model design, API→relation mapping |
| `ARCHITECTURE.md` | `openfga_my/` | System architecture, 3-tier security model, sequence diagrams |
| `rest_api_security.md` | `openfga_my/` | Client/REST API compromise analysis, credential design rationale |
| `system_flow.md` | `doc/` | End-to-end system flow diagrams with OpenFGA check details |
| `how_to_add_new_endpoint.md` | `doc/` | Guide for adding endpoints with full auth integration |
| `authorization.md` | `openfga_my/` | Per-tenant authorization model design |

---

## 9. Design Principles

1. **Client never handles cloud credentials.** The client sends `auth_binding` (a tenant ID); the server resolves actual AWS/Nutanix keys from Vault. Client-supplied credentials are rejected.
2. **OpenFGA runs on every request.** No caching of authorization decisions — every cloud operation triggers a fresh `/check` call.
3. **Three-tier authorization:** (a) JWT scope → what API endpoints you may call; (b) provider allowlist → which clouds you may target; (c) OpenFGA → what you may do on each backend.
4. **Per-tenant isolation.** Each `auth_binding` maps to its own `aws_region:<binding>` or `nutanix_cluster:<binding>` object and its own Vault secret at `secret/libcloud/<binding>`. Arbitrary tenant IDs are accepted; authorization is enforced by OpenFGA.
5. **OIDC-forwarding to OpenFGA.** The client's Dex-issued JWT is forwarded as the Bearer token on OpenFGA `/check` calls. OpenFGA validates it against the same Dex JWKS, so unauthenticated callers cannot query the tuple store.
6. **Tuple count stays O(users × roles).** Static structural tuples (17) are written once by bootstrap. Only user→role assignments are added per-user. The model uses computed relations (tupleToUserset) so permissions propagate without per-user-per-resource tuples.
7. **Provider extensibility.** Adding a new cloud provider requires: (a) an entry in `PROVIDER_OBJECT_TYPES`, (b) a matching type in the OpenFGA model, (c) a libcloud driver. The policy engine discovers the object type from the registry — no new code branches.
