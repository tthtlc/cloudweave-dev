# System HTTP Flow: Complete Trace from Login Through All Operations

## Architecture Overview

```
┌──────────────────────┐     ┌──────────────────────┐     ┌──────────────────────┐
│  React SPA (:3000)   │────▶│ Identity Service     │────▶│  Dex (OIDC Issuer)   │
│  (Browser)           │     │ (:8766, FastAPI)     │     │  (:5556)             │
└──────────┬───────────┘     └────────┬─────────────┘     └──────────────────────┘
           │                          │
           │                          ├────▶ LLDAP (LDAP :3890, HTTP :17170)
           │                          ├────▶ OpenFGA (:8081)
           │                          └────▶ libcloud REST API (:8765)
           │
           └──────────────────────────┘
```

---

## STAGE 1: Login Initiation

### 1a. Browser → Identity Service: `GET /api/auth/begin`

**Source files:**
- `server/src/services/auth.js:17-30` — `redirectToDex()` sends the browser to begin auth
- `server/src/pages/LoginPage.js:120-131` — `handleLogin()` calls `redirectToDex(provider)` on button click
- `identity_service/app/main.py:105-112` — `auth_begin()` route handler
- `identity_service/app/auth_state.py:54-77` — `AuthService.begin()` mints state + PKCE

**Request:**
```
GET /api/auth/begin?provider=lldap&redirect_uri=http://localhost:3000/auth/callback
```

**Backend processing (`auth_state.py:54-77`):**
1. Generates a cryptographically random `state` (32 bytes, `secrets.token_urlsafe`) — CSRF protection
2. Generates a PKCE `code_verifier` (48 bytes, `secrets.token_urlsafe`)
3. Computes `code_challenge` = base64url(SHA256(code_verifier)) — S256 method
4. Stores `{code_verifier, provider, redirect_uri, exp}` keyed by `state` in `_state_store` (in-memory, TTL=600s)
5. Builds the Dex authorize URL with query params
6. Returns `{authorizeUrl, state, provider}` as JSON

**Response:**
```json
{
  "authorizeUrl": "http://login.quest4science.xyz:5556/dex/auth?client_id=libcloud-portal&redirect_uri=http://localhost:3000/auth/callback&response_type=code&scope=openid+profile+email&state=<random>&code_challenge=<SHA256>&code_challenge_method=S256&connector_id=lldap",
  "state": "<random_state>",
  "provider": "lldap"
}
```

### 1b. Browser → Dex: `GET /dex/auth?...` (Browser Redirect)

**Source file:** `server/src/services/auth.js:29-30`

The frontend sets `window.location.href = authorizeUrl`, causing a full browser navigation:

```
GET http://login.quest4science.xyz:5556/dex/auth?
    client_id=libcloud-portal&
    redirect_uri=http://localhost:3000/auth/callback&
    response_type=code&
    scope=openid+profile+email&
    state=<random>&
    code_challenge=<SHA256>&
    code_challenge_method=S256&
    connector_id=lldap
```

This is a **browser navigation** — the browser is now at Dex's login page. Depending on connector_id:
- `lldap` → Dex shows an LDAP username/password form
- `google` / `github` → Dex redirects to the upstream provider's consent screen

### 1c. Dex → Browser: Redirect back with authorization `code`

After successful authentication, Dex redirects the browser:

```
GET http://localhost:3000/auth/callback?code=<authorization_code>&state=<same_state>
```

---

## STAGE 2: Token Exchange (Callback)

### 2a. Browser → Identity Service: `POST /api/auth/exchange`

**Source files:**
- `server/src/pages/AuthCallbackPage.js:33-38` — Extracts `code` + `state` from URL, calls `api.exchange()`
- `server/src/services/api.js:50` — `exchange: (payload) => http("/api/auth/exchange", body("POST", payload))`
- `identity_service/app/main.py:114-170` — `exchange()` route handler

**Request:**
```
POST /api/auth/exchange
Content-Type: application/json
Body: {
    "provider": "lldap",
    "code": "<authorization_code>",
    "state": "<random_state>",
    "redirectUri": "http://localhost:3000/auth/callback"
}
```

**Backend processing (`main.py:114-170`):**

#### Step 2b — Consume state + retrieve PKCE verifier

**Source file:** `identity_service/app/auth_state.py:79-87`

```python
state_entry = auth.consume_state(body.state)
# Returns: {code_verifier, provider, redirect_uri}
# Side effect: removes entry from _state_store (single-use; replays fail)
# Raises APIError(400) if state unknown, reused, or expired (>600s)
```

#### Step 2c — Identity Service → Dex: `POST /dex/token` (Server-to-Server)

**Source file:** `identity_service/app/dex.py:32-64` — `DexService.exchange_code()`

```
POST http://dex:5556/dex/token
Content-Type: application/x-www-form-urlencoded
Body: {
    "grant_type": "authorization_code",
    "code": "<authorization_code>",
    "redirect_uri": "http://localhost:3000/auth/callback",
    "client_id": "libcloud-portal",
    "client_secret": "<DEX_PORTAL_CLIENT_SECRET>",    ← NEVER exposed to browser
    "code_verifier": "<PKCE_code_verifier>"           ← from server-side store
}
```

Dex validates: code is fresh, redirect_uri matches, client_secret correct, PKCE code_challenge matches code_verifier.

Dex returns:
```json
{
    "access_token": "<dex_access_token>",
    "token_type": "bearer",
    "expires_in": 3600,
    "refresh_token": "<dex_refresh_token>",
    "id_token": "<signed_jwt_id_token>"
}
```

#### Step 2d — Identity Service: Verify ID token (JWKS)

**Source file:** `identity_service/app/dex.py:66-83` — `DexService.verify_id_token()`

The identity service fetches Dex's public keys to verify the ID token signature:

```
GET http://dex:5556/dex/keys
→ Returns JWKS (JSON Web Key Set)
```

Verifies:
- JWT signature against the signing key from JWKS
- `iss` (issuer) matches `http://login.quest4science.xyz:5556/dex`
- `aud` (audience) matches `libcloud-portal`
- `exp` (expiration) is in the future
- Required claims present: `exp`, `sub`, `iss`, `aud`

The JWKS client (`PyJWKClient`) caches keys; this is not called on every request.

#### Step 2e — Identity Service → LLDAP: LDAP Search

**Source files:**
- `identity_service/app/users.py:88-165` — `UserService.resolve_on_login()`
- `identity_service/app/lldap.py:58-108` — `LldapService.list_users()` / `find_by_email()`

For identity resolution, the identity service queries LLDAP via LDAP protocol:

```
LDAP (port 3890):
  Server: lldap:3890
  Bind DN: uid=admin,ou=people,dc=libcloud,dc=local
  Password: <LLDAP_LDAP_USER_PASS>
```

For LLDAP login (`provider == "lldap"`):
```
Search base: ou=people,dc=libcloud,dc=local
Filter: (&(objectClass=person)(mail=<email>))
  OR fallback: decode Dex's protobuf-encoded sub claim to recover the uid directly
Attributes: uid, mail, cn
```

For federated login (Google/GitHub) — collapse heuristic:
```
Search base: ou=people,dc=libcloud,dc=local
Filter: (&(objectClass=person)(mail=<external_email>))
Attributes: uid, mail, cn
```

#### Step 2f — Identity Service → OpenFGA: Role Derivation

**Source file:** `identity_service/app/fga.py:255-258, 307-315` — `role_for()` → `_read_user_tuples()` → `list_tuples()`

```
POST http://openfga:8081/stores/{store_id}/read
Authorization: Bearer <provisioner_token>
Content-Type: application/json
Body: { "page_size": 100 }
```

Paginated read of all tuples in the store. Then derives role from the user's concrete tuples:
- `superadmin` on `platform:main` → role = "superadmin"
- `owner` on any `tenant:*` → role = "owner"
- `admin` on any `tenant:*` → role = "admin"
- `viewer` on any `tenant:*` → role = "viewer"
- No tuples → default "viewer"

Also derives per-cloud capabilities: `[{cloud: "aws", canView: true, canProvision: false, canUpdate: false}, ...]`

#### Step 2g — Identity Service → Browser: Session Cookie + Response

**Source file:** `identity_service/app/session.py:51-77` — `SessionService.create()`

For resolved users (no collapse needed):

1. Generates a `sid` (session id, 32 hex chars)
2. Stores `{refresh_token, id_token, internalUserId}` server-side in `_refresh_store[sid]`
3. Mints a signed JWT session cookie:
   ```python
   payload = {
       "internalUserId": "int-<uid>",
       "role": "viewer",
       "email": "user@example.com",
       "linkedIdentities": ["lldap:<sub>"],
       "sid": "<session_id>",
       "iat": <now>,
       "exp": <now + 28800>,     # 8 hours
       "jti": "<unique_id>"
   }
   cookie = jwt.encode(payload, session_secret, algorithm="HS256")
   ```
4. Sets cookie on response:
   - Name: `libcloud_portal_sid`
   - `httpOnly: true` — JavaScript cannot read it
   - `SameSite: Lax`
   - `Secure: false` (dev; true in production)
   - `Path: /`
   - `Max-Age: 28800`

**Response JSON:**
```json
{
    "internalUserId": "int-aws-viewer",
    "role": "viewer",
    "linkedIdentities": ["lldap:<base64_protobuf_sub>"],
    "email": "viewer@example.com",
    "clouds": [
        {"cloud": "aws", "canView": true, "canProvision": false, "canUpdate": false},
        {"cloud": "nutanix", "canView": true, "canProvision": false, "canUpdate": false}
    ]
}
```

For users needing collapse (email matched existing LLDAP users):
```json
{
    "needsIdentityCollapse": true,
    "collapseCandidates": [
        {
            "internalUserId": "int-existing-user",
            "email": "existing@example.com",
            "displayName": "Existing User",
            "role": "admin",
            "linkedIdentities": ["lldap:<sub>"]
        }
    ],
    "pendingIdentity": {"provider": "google", "subject": "google:<sub>", "email": "existing@example.com"},
    "pendingToken": "<server_issued_signed_jwt>"
}
```

**Frontend handling** (`AuthCallbackPage.js:42-47`):
- If `needsIdentityCollapse` is true → stash result in `sessionStorage` → navigate to `/identity/collapse`
- If false (normal login) → call `login(result)` → save meta to `sessionStorage` → navigate to role home

---

## STAGE 3: Identity Collapse (Conditional)

### 3a. Browser → Identity Service: `POST /api/auth/collapse`

**Source files:**
- `server/src/pages/IdentityCollapsePage.js:34-38` — User picks "link" or "keep", calls `api.collapse()`
- `server/src/services/api.js:51` — `collapse: (payload) => http("/api/auth/collapse", body("POST", payload))`
- `identity_service/app/main.py:172-195` — `collapse()` route handler

**Request:**
```
POST /api/auth/collapse
Content-Type: application/json
Body: {
    "targetInternalUserId": "int-existing-user",
    "pendingIdentity": { "provider": "google", "subject": "google:<sub>", "email": "..." },
    "pendingToken": "<server_issued_signed_jwt>",
    "decision": "link"         // or "keep"
}
```

**Backend processing (`main.py:179-181`):**

The `pendingToken` is validated server-side:
```python
verified_identity = auth.consume_pending(body.pendingToken)
# Validates JWT signature, checks type=="pending_identity",
# checks jti not reused (single-use), checks exp not expired (TTL=300s)
# Returns: {provider, subject, email} — THE SERVER-VERIFIED IDENTITY
```

**CRITICAL SECURITY PROPERTY:** The client-supplied `pendingIdentity` is **completely ignored**. Only the server-issued `pendingToken` is trusted. This prevents an attacker from linking an arbitrary identity into a victim's account.

**Collapse logic** (`users.py:186-213`):
- `"link"` → append the new subject to the target user's `linkedIdentities[]`
- `"keep"` → create a brand-new pending user with no OpenFGA tuples (role="pending")

**Response:** A new session cookie is minted (same as Stage 2g) and JSON returned:
```json
{
    "internalUserId": "int-existing-user",
    "role": "admin",
    "linkedIdentities": ["lldap:<sub>", "google:<sub>"],
    "email": "existing@example.com",
    "clouds": [{"cloud": "aws", "canView": true, "canProvision": true, "canUpdate": true}, ...]
}
```

---

## STAGE 4: Session Restoration (Page Reload / Direct Navigation)

### 4a. Browser → Identity Service: `GET /api/session`

**Source files:**
- `server/src/context/AuthContext.js:22-23` — On mount, if `sessionStorage` has meta, calls `api.getSession()`
- `server/src/services/api.js:49` — `getSession: () => http("/api/session")`
- `identity_service/app/main.py:94-103` — `get_session()` route handler

**Request:**
```
GET /api/session
Cookie: libcloud_portal_sid=<signed_jwt>
```

**Backend processing (`session.py:79-84`):**
1. Reads the `libcloud_portal_sid` cookie
2. Decodes and verifies the JWT (HS256 signature, `exp` check)
3. Returns fresh session data including live per-cloud capabilities from OpenFGA

**Response:**
```json
{
    "internalUserId": "int-aws-admin",
    "role": "admin",
    "linkedIdentities": ["lldap:<sub>"],
    "email": "admin@example.com",
    "clouds": [
        {"cloud": "aws", "canView": true, "canProvision": true, "canUpdate": true},
        {"cloud": "nutanix", "canView": true, "canProvision": false, "canUpdate": false}
    ]
}
```

---

## STAGE 5: Logout

### 5a. Browser → Identity Service: `POST /api/logout`

**Source files:**
- `server/src/pages/LogoutPage.js:15` — `logout()` from `useAuth()` hook
- `server/src/context/AuthContext.js:46-55` — calls `api.logout()`, then redirects to Dex logout
- `server/src/services/api.js:52` — `logout: () => http("/api/logout", body("POST", {}))`
- `identity_service/app/main.py:197-227` — `logout()` route handler

**Request:**
```
POST /api/logout
Cookie: libcloud_portal_sid=<signed_jwt>
Body: {}
```

**Backend processing (`main.py:197-227`):**

1. **Clear portal session** (`session.py:86-103`):
   - Reads the session cookie to extract `sid` and `refresh_token` + `id_token`
   - Removes entry from `_refresh_store[sid]`
   - Sets `Set-Cookie: libcloud_portal_sid=; Max-Age=0` to delete the cookie
   - Returns the stored `{refresh_token, id_token}` to the caller

2. **Revoke Dex refresh token** (best-effort):

### 5b. Identity Service → Dex: `POST /dex/token/revoke`

**Source file:** `identity_service/app/dex.py:85-106` — `DexService.revoke_token()`

```
POST http://dex:5556/dex/token/revoke
Content-Type: application/x-www-form-urlencoded
Body: {
    "token": "<refresh_token>",
    "token_type_hint": "refresh_token",
    "client_id": "libcloud-portal",
    "client_secret": "<DEX_PORTAL_CLIENT_SECRET>"
}
```

RFC 7009 token revocation. Failures are logged but never block logout.

3. **Build RP-Initiated Logout URL** (`main.py:215-226`):

```
http://login.quest4science.xyz:5556/dex/auth/logout?
    post_logout_redirect_uri=http://localhost:3000/login&
    id_token_hint=<id_token>
```

Returned as `logoutUrl` in the response:
```json
{ "logged_out": true, "logoutUrl": "http://login.quest4science.xyz:5556/dex/auth/logout?..." }
```

### 5c. Browser → Dex: `GET /dex/auth/logout?...` (Browser Redirect)

**Source file:** `server/src/pages/LogoutPage.js:20`

The frontend sets `window.location.href = logoutUrl`, redirecting the browser to Dex's RP-initiated logout endpoint. This clears Dex's SSO session cookie, then Dex redirects the browser back to:

```
GET http://localhost:3000/login
```

---

## STAGE 6: Cloud Operations (Post-Login)

All cloud operations (list resources, provision, deprovision, update) go through a two-hop path:
1. **Browser → Identity Service** (validates session + OpenFGA authorization)
2. **Identity Service → libcloud REST API** (performs the actual cloud operation)

### 6a. Provisioner Token Acquisition (Server-to-Server, on-demand)

**Source file:** `identity_service/app/idp_login.py:38-148` — `ProvisionerAuth`

Before any cloud operation, the identity service needs a token with audience `libcloud-rest` (the portal user's token has audience `libcloud-portal`). It obtains this by performing a Dex LDAP login as a per-cloud **provisioner service account** (e.g., `aws-admin`, `ntnx-admin`).

#### Step 6a-1: GET Dex authorize → follow redirects to LDAP login form

```
GET http://dex:5556/dex/auth?
    client_id=libcloud-rest&
    redirect_uri=http://127.0.0.1:8766/oauth/callback&
    response_type=code&
    scope=openid+email+profile&
    state=libcloud-dex&
    connector_id=lldap
```

The HTTP client follows redirects to reach the LDAP login form HTML.

#### Step 6a-2: POST credentials → extract code from 302 Location header

```
POST http://dex:5556/dex/auth/<login_path>
Content-Type: application/x-www-form-urlencoded
Body: { "login": "aws-admin", "password": "<LIBCLOUD_PASSWORD_AWS_ADMIN>" }
```

The client does **NOT** follow the 302 redirect. Instead, it extracts the `code` parameter from the `Location` header.

#### Step 6a-3: Exchange code for tokens (client libcloud-rest + secret)

```
POST http://dex:5556/dex/token
Content-Type: application/x-www-form-urlencoded
Body: {
    "grant_type": "authorization_code",
    "code": "<code>",
    "redirect_uri": "http://127.0.0.1:8766/oauth/callback",
    "client_id": "libcloud-rest",
    "client_secret": "<LIBCLOUD_OIDC_CLIENT_SECRET>"
}
```

Returns: `{access_token, refresh_token, expires_in}`.

The access token is cached per-cloud with its `exp` claim. On subsequent calls, the cache is used if not expired. If expired, a refresh is attempted:

#### Token Refresh (if needed):

```
POST http://dex:5556/dex/token
Content-Type: application/x-www-form-urlencoded
Body: {
    "grant_type": "refresh_token",
    "refresh_token": "<cached_refresh_token>",
    "client_id": "libcloud-rest",
    "client_secret": "<LIBCLOUD_OIDC_CLIENT_SECRET>"
}
```

### 6b. Browser → Identity Service: Cloud Resource/Provision/Deprovision/Update Requests

**Source file:** `identity_service/app/main.py:290-340`

For all cloud operations, the identity service first checks the portal session cookie and then runs an OpenFGA authorization check for the specific operation:

| Portal Route | OpenFGA Check | REST API Operation |
|---|---|---|
| `GET /api/resources/{cloud}` | `can_view(principal, cloud)` | `GET /v1/compute/nodes` |
| `POST /api/provision/{cloud}` | `can_provision(principal, cloud)` | Multiple (see below) |
| `POST /api/deprovision/{cloud}` | `can_provision(principal, cloud)` | Shells out to bash script |
| `POST /api/update/{cloud}` | `can_update(principal, cloud)` | `PATCH /v1/compute/nodes/{id}` |

### 6c. Identity Service → OpenFGA: Per-Operation Authorization Check

**Source file:** `identity_service/app/fga.py:130-137, 365-384`

```
POST http://openfga:8081/stores/{store_id}/check
Authorization: Bearer <provisioner_token>
Content-Type: application/json
Body: {
    "authorization_model_id": "<model_id>",
    "tuple_key": {
        "user": "user:aws-admin",
        "relation": "can_read",           // or "can_provision" or "can_update"
        "object": "aws_region:aws"        // or "nutanix_cluster:nutanix"
    }
}
```

This is a **live OpenFGA `/check`** — evaluates computed relations through the full model, including `can_use` → `can_read`/`can_provision` inheritance, resource-class grants, etc.

### 6d. Identity Service → libcloud REST API: Cloud Operations

**Source file:** `identity_service/app/libcloud_proxy.py`

All REST API calls carry:
- `Authorization: Bearer <provisioner_token>` (audience `libcloud-rest`)
- `X-Provider-Connection: {"provider":"aws","config":{...},"auth_binding":"aws"}` (JSON)

#### List Resources:
```
GET /v1/compute/nodes
Authorization: Bearer <provisioner_token>
X-Provider-Connection: {"provider":"aws","config":{"region":"ap-southeast-1","secure":true},"auth_binding":"aws"}
```

#### Provision (replays `provision_<cloud>.sh` sequence):
```
Step 1: POST /v1/auth/me              → validate token
Step 2: POST /v1/connections:test      → test cloud connectivity
Step 3: GET  /v1/compute/locations     → discover regions/clusters
Step 4: GET  /v1/compute/sizes         → discover instance types
Step 5: GET  /v1/compute/images        → discover images (AWS: *ubuntu* filter)
Step 6: GET  /v1/compute/storage-containers  → (Nutanix only)
Step 7: GET  /v1/compute/subnets       → discover subnets
Step 8: GET  /v1/compute/nodes         → list existing nodes
Step 9: POST /v1/compute/nodes         → create the VM
        Body: {
            "name": "libcloud-demo-<ts>",
            "size": {"id": "<resolved>"},
            "image": {"id": "<resolved>"},
            "location": {"id": "<resolved>"},   // Nutanix
            "network": {"public_ip": true, "subnet_id": "<resolved>"}  // AWS
        }
```

#### Deprovision (shells out to bash script):
**Source file:** `identity_service/app/libcloud_proxy.py:223-298`

Rather than reimplementing the deprovision flow, the identity service writes a temp token cache and executes the shell script:

```
Script: test_script/scripts/deprovision_<cloud>.sh
Env: LIBCLOUD_REST_URL, DEX_URL, FGA_API_URL, IDP_TOKEN_CACHE_DIR, etc.

The script performs:
  1. idp_login.py → Dex token exchange (same as Stage 6a)
  2. OpenFGA can_provision check
  3. DELETE /v1/compute/nodes/{vm_id}
```

#### Update (edit VM):
```
POST /v1/auth/me              → validate token
PATCH /v1/compute/nodes/{id}  → edit VM parameters
Body: {
    "action": "update",
    "name": "<new_name>",
    "new_size_id": "<size_id>",
    "memory_mib": <mem>,
    "tag_key": "<key>",
    "tag_value": "<value>"
}
```

---

## STAGE 6 Expanded: libcloud REST API Internal Auth Pipeline

**Source files (all under `libcloud.rest/`):**

| File | Role |
|------|------|
| `app/main.py` | App factory; mounts all routers and middleware |
| `app/common/middleware.py` | Request ID middleware (no auth) |
| `app/auth/authorized_route.py` | `AuthorizedAPIRoute` — single enforcement point |
| `app/auth/policy_table.py` | Hot-reloadable policy table from `policies.json` |
| `app/auth/policies.json` | Policy definitions mapping METHOD+path → scopes, capabilities |
| `app/auth/policy.py` | `PolicyEngine` — scope check, provider allow-list, credential policy, OpenFGA check |
| `app/auth/dependencies.py` | Token extraction/decode + connection extraction |
| `app/auth/service.py` | Local JWT auth (HS256) |
| `app/auth/oidc_service.py` | OIDC token decoding (JWKS + client secret), principal resolution |
| `app/auth/identity.py` | Principal resolution from OIDC claims, scope/provider tables |
| `app/auth/fga_client.py` | OpenFGA REST client for fine-grained authZ |
| `app/connections/credentials.py` | Server-side credential resolution (Vault or env) |
| `app/connections/dependencies.py` | Parsing `X-Provider-Connection` header |

### Per-Request Auth Pipeline

Every request to an authorized route (e.g., `GET /v1/compute/nodes`) goes through:

1. **Request ID Middleware** (`app/common/middleware.py`) — Attaches `X-Request-ID` to request and response. No authentication.

2. **Policy Table Lookup** (`app/auth/policy_table.py`) — Looks up `"{METHOD} {path}"` in `policies.json`. If not found → **rejected with 500** (fail-closed). The policy table auto-reloads on mtime change, or via `POST /v1/admin/policies:reload`.

3. **Token Extraction & Decode** (`app/auth/dependencies.py` → `app/auth/oidc_service.py`) — In OIDC mode:
   - Extract `Bearer` token from `Authorization` header
   - Determine JWT algorithm from header
   - For RS/ES/PS algos: fetch JWKS from Dex (`GET http://dex:5556/dex/keys`)
   - For HS algos: verify with client secret
   - Resolve OIDC `sub` to a principal slug via role-suffix pattern matching (`app/auth/identity.py`):
     - `aws-admin` → scopes: `PROVISIONER_SCOPES` for aws, providers: `["aws"]`
     - `ntnx-owner` → scopes: `PROVISIONER_SCOPES` for nutanix, providers: `["nutanix"]`
     - `superadmin` → scopes: `PROVISIONER_SCOPES` for all, providers: `["*"]`

4. **Connection Resolution** (`app/auth/dependencies.py`) — Parses `X-Provider-Connection` header (JSON) or `?connection=` query param into `ProviderConnection` model:
   ```json
   {"provider": "aws", "config": {"region": "ap-southeast-1", "secure": true}, "auth_binding": "aws"}
   ```

5. **Authorization Enforcement** (`app/auth/policy.py` — `PolicyEngine.authorize_connection()`):
   - **Scope check**: Token must have the scopes required by the policy entry. `compute:read` is an alias expanding to `compute:image:read`, `compute:size:read`, `compute:location:read`, `compute:network:read`
   - **Provider allow-list**: Token's `allowed_providers` must include the requested cloud (or `*`)
   - **Credential policy**: Blocks client-supplied backend credentials unless `allow_client_credentials=true` (dev only). The API uses its own server-side identity (Vault or env vars)
   - **OpenFGA fine-grained check** (`app/auth/fga_client.py`):
     ```
     POST http://openfga:8081/stores/{store_id}/check
     Body: {
         tuple_key: { user: "user:aws-admin", relation: "can_use", object: "provider:aws" }
     }
     → Checks can_connect (API object), can_use (provider type),
       can_read / can_provision (specific backend object derived from auth_binding)
     ```
   - **Driver capability check**: Verifies the provider driver actually supports the operation

6. **Route Handler Execution** — Only now does the actual handler run. Handlers contain **zero authorization logic**; they read from `request.state.connection` and `request.state.authorized_claims`.

### Routes that bypass this auth pipeline

These use plain `APIRouter` (not `AuthorizedAPIRoute`):
- `POST /v1/auth/login`, `POST /v1/auth/refresh` — public (disabled in OIDC mode)
- `GET /v1/auth/me`, `POST /v1/auth/logout` — use `Depends(get_current_claims)` injection
- `GET /v1/providers` — public catalog
- `GET /health` — standard health check

---

## STAGE 7: Admin Operations (Post-Login)

### 7a. User Management

**Source files:**
- `identity_service/app/main.py:229-254` — route handlers
- `identity_service/app/users.py:216-312` — `UserService` methods
- `identity_service/app/lldap.py:58-137` — `LldapService`
- `identity_service/app/fga.py:269-335` — `FgaService`

#### List Users:
```
GET /api/users
Cookie: libcloud_portal_sid=<session>
→ Requires: superadmin role (checked server-side)
→ Backend:
   1. LLDAP LDAP search for all users
   2. OpenFGA batch role derivation (single /read, not N calls)
   3. Merge in pending (non-LLDAP) users from in-memory registry
```

#### Set Role:
```
PATCH /api/users/{internal_id}/role
Cookie: libcloud_portal_sid=<session>
Body: { "role": "admin", "tenant": "aws" }
→ Requires: superadmin role
→ Backend:
   1. Find user by internal_id
   2. FgaService.clear_roles(principal) — delete all existing managed tuples
   3. FgaService.assign_role(principal, role, tenant) — write new role tuple to OpenFGA
      POST http://openfga:8081/stores/{store_id}/write
      Body: {
          "authorization_model_id": "...",
          "writes": {"tuple_keys": [{"user": "user:aws-admin", "relation": "admin", "object": "tenant:aws"}]}
      }
```

#### Set Email:
```
PATCH /api/users/{internal_id}/email
Cookie: libcloud_portal_sid=<session>
Body: { "email": "new@example.com" }
→ Requires: superadmin role
→ Backend (for LLDAP users):
   1. POST http://lldap:17170/auth/simple/login
      Body: { "username": "admin", "password": "<LLDAP_LDAP_USER_PASS>" }
      → Returns LLDAP admin JWT
   2. POST http://lldap:17170/api/graphql
      Authorization: Bearer <lldap_admin_jwt>
      Body: {
          "query": "mutation UpdateUser($user: UpdateUserInput!) { updateUser(user: $user) { ok } }",
          "variables": { "user": { "id": "<uid>", "email": "new@example.com" } }
      }
```

#### Disable User:
```
POST /api/users/{internal_id}/disable
Cookie: libcloud_portal_sid=<session>
→ Requires: superadmin role
→ Backend:
   1. FgaService.clear_roles(principal)
   2. POST http://openfga:8081/stores/{store_id}/write
      Body: { "authorization_model_id": "...", "deletes": {"tuple_keys": [<all managed tuples>]} }
   User stays in LLDAP/external IdP but has no system access
```

### 7b. OpenFGA Tuple CRUD (SuperAdmin Power Screen)

**Source file:** `identity_service/app/main.py:256-274`

```
GET    /api/tuples   → POST /stores/{id}/read   (paginated, all tuples)
POST   /api/tuples   → POST /stores/{id}/write  (writes)
DELETE /api/tuples   → POST /stores/{id}/write  (deletes)
```

All require superadmin role. The frontend `OpenFgaTuplesPage` allows direct tuple manipulation.

---

## Summary: All HTTP/LDAP Interactions

| # | From | To | Method | Path | Stage | Purpose |
|---|------|----|--------|------|-------|---------|
| 1 | Browser | Identity (:8766) | `GET` | `/api/auth/begin?provider=&redirect_uri=` | 1a | Start login; get Dex authorize URL |
| 2 | Browser | Dex (:5556) | `GET` | `/dex/auth?client_id=&...&connector_id=` | 1b | OIDC authorization (browser redirect) |
| 3 | Browser | Identity (:8766) | `POST` | `/api/auth/exchange` | 2a | Exchange auth code for session |
| 4 | Identity | Dex (:5556) | `POST` | `/dex/token` | 2c | Server-side token exchange (code→tokens) |
| 5 | Identity | Dex (:5556) | `GET` | `/dex/keys` | 2d | JWKS for ID token signature verification |
| 6 | Identity | LLDAP (:3890) | LDAP | Search `ou=people,dc=libcloud,dc=local` | 2e | Find users by email or uid |
| 7 | Identity | OpenFGA (:8081) | `POST` | `/stores/{id}/read` | 2f | Read tuples for role + capability derivation |
| 8 | Browser | Identity (:8766) | `POST` | `/api/auth/collapse` | 3a | Link/keep identity decision |
| 9 | Browser | Identity (:8766) | `GET` | `/api/session` | 4a | Restore session on page reload |
| 10 | Browser | Identity (:8766) | `POST` | `/api/logout` | 5a | Logout |
| 11 | Identity | Dex (:5556) | `POST` | `/dex/token/revoke` | 5b | Revoke Dex refresh token (RFC 7009) |
| 12 | Browser | Dex (:5556) | `GET` | `/dex/auth/logout?id_token_hint=&post_logout_redirect_uri=` | 5c | RP-initiated logout (clears Dex SSO cookie) |
| 13 | Identity | Dex (:5556) | `GET` | `/dex/auth?client_id=libcloud-rest&connector_id=lldap` | 6a-1 | Provisioner: get login form (follow redirects) |
| 14 | Identity | Dex (:5556) | `POST` | `/dex/auth/<login_path>` | 6a-2 | Provisioner: submit credentials (capture 302 code) |
| 15 | Identity | Dex (:5556) | `POST` | `/dex/token` | 6a-3 | Provisioner: exchange code for libcloud-rest token |
| 16 | Identity | Dex (:5556) | `POST` | `/dex/token` (refresh_token grant) | 6a | Provisioner: refresh cached token |
| 17 | Browser | Identity (:8766) | `GET` | `/api/resources/{cloud}` | 6b | List cloud resources |
| 18 | Identity | OpenFGA (:8081) | `POST` | `/stores/{id}/check` | 6c | Per-operation authZ: can_read/can_provision/can_update |
| 19 | Identity | libcloud REST (:8765) | `GET` | `/v1/compute/nodes` | 6d | List nodes |
| 20 | Identity | libcloud REST (:8765) | `POST` | `/v1/auth/me` | 6d | Validate provisioner token |
| 21 | Identity | libcloud REST (:8765) | `POST` | `/v1/connections:test` | 6d | Test cloud connectivity |
| 22 | Identity | libcloud REST (:8765) | `GET` | `/v1/compute/locations` | 6d | Discover regions/clusters |
| 23 | Identity | libcloud REST (:8765) | `GET` | `/v1/compute/sizes` | 6d | Discover instance types |
| 24 | Identity | libcloud REST (:8765) | `GET` | `/v1/compute/images` | 6d | Discover images |
| 25 | Identity | libcloud REST (:8765) | `GET` | `/v1/compute/storage-containers` | 6d | Nutanix storage discovery |
| 26 | Identity | libcloud REST (:8765) | `GET` | `/v1/compute/subnets` | 6d | Discover subnets |
| 27 | Identity | libcloud REST (:8765) | `POST` | `/v1/compute/nodes` | 6d | Create VM |
| 28 | Identity | libcloud REST (:8765) | `DELETE` | `/v1/compute/nodes/{id}` | 6d | Delete VM (via deprovision script) |
| 29 | Identity | libcloud REST (:8765) | `PATCH` | `/v1/compute/nodes/{id}` | 6d | Update VM parameters |
| 30 | Browser | Identity (:8766) | `POST` | `/api/provision/{cloud}` | 6b | Provision VM |
| 31 | Browser | Identity (:8766) | `POST` | `/api/deprovision/{cloud}` | 6b | Deprovision VM |
| 32 | Browser | Identity (:8766) | `POST` | `/api/update/{cloud}` | 6b | Update VM |
| 33 | Browser | Identity (:8766) | `GET` | `/api/users` | 7a | List all users (superadmin) |
| 34 | Browser | Identity (:8766) | `PATCH` | `/api/users/{id}/role` | 7a | Set user role (superadmin) |
| 35 | Browser | Identity (:8766) | `PATCH` | `/api/users/{id}/email` | 7a | Set user email (superadmin) |
| 36 | Browser | Identity (:8766) | `POST` | `/api/users/{id}/disable` | 7a | Disable user (superadmin) |
| 37 | Identity | LLDAP (:17170) | `POST` | `/auth/simple/login` | 7a | LLDAP admin login for GraphQL |
| 38 | Identity | LLDAP (:17170) | `POST` | `/api/graphql` | 7a | UpdateUser email mutation |
| 39 | Identity | OpenFGA (:8081) | `POST` | `/stores/{id}/write` | 7a | Write/delete role tuples |
| 40 | Browser | Identity (:8766) | `GET` | `/api/tuples` | 7b | List all OpenFGA tuples (superadmin) |
| 41 | Browser | Identity (:8766) | `POST` | `/api/tuples` | 7b | Write OpenFGA tuples (superadmin) |
| 42 | Browser | Identity (:8766) | `DELETE` | `/api/tuples` | 7b | Delete OpenFGA tuples (superadmin) |

---

## Key Security Properties

1. **Dex client secret is server-side only** — The browser never sees `DEX_PORTAL_CLIENT_SECRET`. Token exchange happens in `dex.py:32-64` on the identity service, not in the browser.

2. **PKCE code_verifier is server-generated and stored** — Unlike standard OAuth2 PKCE where the client generates the verifier, this system generates it server-side in `auth_state.py:54-77` and consumes it in `auth_state.py:79-87`. The browser only carries the `state` echo.

3. **Session token is httpOnly** — The `libcloud_portal_sid` cookie is set with `httponly=True` in `session.py:68-76`. JavaScript cannot read it, protecting against XSS-based session theft.

4. **Dex refresh token is server-side only** — Stored in `_refresh_store[sid]` (`session.py:62-66`), keyed by session id. The browser never receives it. On logout, the refresh token is explicitly revoked at Dex (`dex.py:85-106`).

5. **Dual-audience token separation** — The portal user's token has audience `libcloud-portal`; cloud operations use a separate provisioner service account token with audience `libcloud-rest`. The identity service bridges these (`idp_login.py:38-71`). The portal user's token is never sent to the REST API.

6. **Collapse pendingToken is server-verified** — The `POST /api/auth/collapse` handler ignores the client-supplied `pendingIdentity` entirely. It validates only the server-issued `pendingToken` (signed JWT, single-use, TTL=300s) in `main.py:179-181` and `auth_state.py:104-116`. This prevents account-takeover by linking an arbitrary identity into a victim's internal user.

7. **OpenFGA is checked twice for cloud operations** — Defense in depth:
   - Identity service checks `can_read`/`can_provision`/`can_update` before calling the REST API (`fga.py:365-384`)
   - REST API independently checks `can_connect`, `can_use`, `can_read`/`can_provision` in its own `AuthorizedAPIRoute` pipeline (`libcloud.rest/app/auth/policy.py` + `fga_client.py`)

8. **Fail-closed policy table** — The REST API's `AuthorizedAPIRoute` rejects any request whose METHOD+path is not explicitly in `policies.json` with a 500 error (`libcloud.rest/app/auth/policy_table.py`).

9. **Client-supplied credentials are blocked** — The REST API's credential policy prevents clients from sending backend credentials (cloud API keys/secrets) in the `X-Provider-Connection` body. The API resolves credentials server-side via Vault or environment variables (`libcloud.rest/app/connections/credentials.py`).

10. **Session OAuth state is single-use** — The `state` + PKCE `code_verifier` stored at `/api/auth/begin` is consumed (popped from `_state_store`) at `/api/auth/exchange`. Replays fail with 400 (`auth_state.py:79-87`).


claude --resume 2b50aebd-34dc-49de-8547-227d286c3655
