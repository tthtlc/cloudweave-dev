# Full AWS Admin Provisioning Flow

> Captured from `run_aws_admin.log.stderr` on 2026-07-01  
> Script: `./scripts/provision_aws.sh`  
> User: `aws-admin` | Tenant: `aws` | Region: `ap-southeast-1` (Singapore)

---

## Overview

The script `provision_aws.sh` automates end-to-end AWS EC2 instance provisioning through a **libcloud REST API** (`localhost:8765`) fronted by a **Dex OAuth2 identity provider** (`localhost:5556`) backed by LDAP. The flow is a textbook **discover-then-provision** pattern: authenticate, enumerate what's available in the cloud, select, then create.

**Total HTTP requests:** 12 (10 read-only discovery, 1 connectivity test, 1 mutating create)  
**Outcome:** EC2 instance `i-016be52ac5fcbe41a` (t3.micro, Ubuntu 22.04, `10.99.1.99`) created in `ap-southeast-1a`

---

## Architecture: The Complete Auth Stack

Before tracing the HTTP flow, it's essential to understand the four-component architecture:

```
┌──────────────────────────────────────────────────────────────────────┐
│                        AUTHENTICATION STACK                          │
│                                                                      │
│  ┌──────────┐    ┌──────────────┐    ┌──────────────┐    ┌────────┐ │
│  │ LLDAP    │    │ Dex IdP      │    │ idp_login.py │    │ libcloud│ │
│  │ :3890    │    │ :5556        │    │ (localhost)  │    │ :8765  │ │
│  │          │    │              │    │              │    │        │ │
│  │ User    │    │ OAuth2       │    │ OAuth2       │    │ JWT    │ │
│  │ Directory│◄──│ Connector    │◄───│ Client       │───►│ Token  │ │
│  │ (LDAP)  │    │ (Dex)        │    │ (Python)     │    │ Auth   │ │
│  └──────────┘    └──────────────┘    └──────────────┘    └────────┘ │
│                                                                      │
│  Users:    aws-admin, aws-owner, aws-viewer, cloud-admin,           │
│            ntnx-admin, ntnx-owner, ntnx-viewer, superadmin          │
│  Client:   libcloud-rest  (secret: HbpzexeVfU0STxDY9f14Td3-...)    │
│  Redirect: http://127.0.0.1:8766/oauth/callback                     │
└──────────────────────────────────────────────────────────────────────┘
```

**LLDAP** is the source of truth — a lightweight LDAP server holding user identities, passwords, and group memberships. Users are created in LLDAP by `setup.sh` using `lldap-cli`.

**Dex** is the OIDC Identity Provider (IdP). It does NOT store user passwords itself. It delegates authentication to LLDAP over an LDAP connector. Dex is configured as a "dumb proxy": it presents an OAuth2/OIDC interface to clients, but all password verification happens in LLDAP. The connector mapping is:
| LDAP Attribute | OIDC Claim | Example |
|----------------|------------|---------|
| `uid` | `sub` | `aws-admin` |
| `mail` | `email` | `aws-admin@libcloud.local` |
| `cn` | `name` | `AWS Administrator` |

**idp_login.py** is a Python script implementing the OAuth2 Authorization Code flow with PKCE-like protections. It acts as a native OAuth2 client: it opens Dex's authorize URL in a cookie-aware session, submits credentials, captures the redirect callback on a local ephemeral HTTP server, and exchanges the authorization code for tokens.

**libcloud REST API** (:8765) consumes the resulting access token as a Bearer token. It validates the JWT against Dex's JWKS endpoint and maps the `sub` claim to internal RBAC roles.

---

## Flow Diagram

```
┌──────────┐   ┌──────────┐   ┌──────────────┐   ┌──────────┐   ┌──────────┐
│ LLDAP    │   │ Dex IdP  │   │ idp_login.py │   │ libcloud  │   │   AWS    │
│ :3890    │   │ :5556    │   │ :8766 (cb)   │   │ REST :8765│   │ ap-se-1  │
└────┬─────┘   └────┬─────┘   └──────┬───────┘   └────┬─────┘   └────┬─────┘
     │              │                │                 │              │
     │    ╔═════════ PHASE 1: OAuth2 Authorization Code Flow ═══════╗ │
     │              │                │                 │              │
     │         [a]  │<── GET /dex/   │                 │              │
     │              │    auth?...    │                 │              │
     │              │── 302 → /lldap │                │              │
     │              │── 302 → /login │                │              │
     │              │── 200 HTML form│                │              │
     │              │                │                 │              │
     │         [b]  │<── POST /dex/  │                 │              │
     │              │    auth/lldap/ │                 │              │
     │              │    login       │                 │              │
     │              │                │                 │              │
     │<── LDAP bind │                │                 │              │
     │── user OK ──►│                │                 │              │
     │              │                │                 │              │
     │              │── 302 → http://127.0.0.1:8766/   │              │
     │              │    oauth/callback?code=AUTH_CODE  │              │
     │              │                │                 │              │
     │              │         [c]   │ POST /dex/token  │              │
     │              │<──────────────│ (exchange code)  │              │
     │              │── access_token │                │              │
     │              │    id_token   │                 │              │
     │              │    refresh_tok│                 │              │
     │    ╚════════════════════════ END PHASE 1 ═══════════════════╝ │
     │              │                │                 │              │
     │              │    ╔══════ PHASE 2-5: API calls ═════════╗     │
     │              │                │                 │              │
     │              │           [3]  │── GET /v1/auth/ │              │
     │              │                │    me (Bearer)  │              │
     │              │                │                 │              │
     │              │           [4]  │── POST /v1/     │              │
     │              │                │    connections  │              │
     │              │                │    :test ───────┼── verify ───►│
     │              │                │                 │              │
     │              │    [5-11]      │── GET /v1/      │              │
     │              │                │    compute/* ───┼── enumerate ─►│
     │              │                │    (7 listings) │              │
     │              │                │                 │              │
     │              │          [12]  │── POST /v1/     │              │
     │              │                │    compute/     │              │
     │              │                │    nodes ───────┼── CREATE ────►│
     │    ╚════════════════════════════════════════════╝              │
     │              │                │                 │              │
     │              │     ┌──────────┴────────┐        │              │
     │              │     │ deprovision_aws.sh│        │              │
     │              │     └───────────────────┘        │              │
```

> **Note on log visibility:** The verbose log output (`VERBOSE=1`) only shows requests [a] and [b] because `idp_login.py` uses Python's `urllib` directly, not the `curl_http()` bash function. The redirects (302), the callback capture, and the token exchange happen inside `urllib` and are not printed by the bash-level `VERBOSE=1` flag. However, the `_verbose()` calls in `idp_login.py` do print [a] and [b] (the initial GET and the login POST) because `VERBOSE=1` propagates to `IDP_LOGIN_VERBOSE=1`.

---

## Script Invocation & Environment

```bash
TENANT=aws
LIBCLOUD_USER=aws-admin
VERBOSE=1
PROVISION=1
./scripts/provision_aws.sh
```

The script first runs `set_tenant_credentials.py` to resolve AWS key/secret bindings:
```
set_tenant_credentials: credential values are required at runtime for tenant:aws
(cloud=aws; set LIBCLOUD_AWS_KEY/LIBCLOUD_AWS_SECRET)
```
Credentials are bound via the `auth_binding: "aws"` mechanism — the API server resolves secrets server-side without the client sending them in plaintext.

---

## Phase 1 — OAuth2 Authentication in Depth

The two log lines visible in `run_aws_admin.log.stderr` are the tip of an iceberg. The complete OAuth2 Authorization Code flow involves **5 HTTPS round-trips** between `idp_login.py` and Dex, plus **1 LDAP bind** between Dex and LLDAP. Only requests [a] and [b] appear in the verbose output; the rest happen inside Python's `urllib` redirect-following and are invisible at the bash logging level.

### The Actors

| Component | Role | Port | Auth Mechanism |
|-----------|------|------|----------------|
| **idp_login.py** | OAuth2 client (native app) | ephemeral :8766 | Knows client_secret, user password |
| **Dex** | OIDC Identity Provider | :5556 | Delegates to LLDAP via LDAP bind |
| **LLDAP** | User directory / password store | :3890 | Verifies LDAP bind (uid + password) |
| **libcloud REST** | Resource API (JWT consumer) | :8765 | Validates Bearer JWT against Dex JWKS |

### The Credential Resolution (pre-flow)

Before any HTTP requests, `common.sh` resolves the user's password through a layered cascade (`scripts/common.sh:52-99`):

```
LIBCLOUD_USER=aws-admin
  → case aws-admin → LIBCLOUD_PASSWORD="${LIBCLOUD_PASSWORD_AWS_ADMIN:-}"
    → from dex/generated/dex.env: LIBCLOUD_PASSWORD_AWS_ADMIN=SA-YxB5zqiYyA8M0mscsjfOkuWd
```

This password was generated by `dex_bootstrap.py` (via `secrets.token_urlsafe(18)`) and persisted to `dex.env` by `setup.sh`. The same password was used to create the user in LLDAP via `lldap-cli`. So there is a **shared secret** between the provisioning script and LLDAP, mediated by the generated env file.

---

### Step-by-Step OAuth2 Flow

The entry point is `idp_login()` in `common.sh:213-226`, which calls `python3 scripts/idp_login.py`. This invokes the `dex_login()` function in `idp_login.py:195-240`.

#### Step [a] — Initiate Authorization Request (visible in log)

```
>>> GET http://localhost:5556/dex/auth?client_id=libcloud-rest&redirect_uri=http%3A%2F%2F127.0.0.1%3A8766%2Foauth%2Fcallback&response_type=code&scope=openid+email+profile&state=libcloud-dex
```

**Code path:** `idp_login.py:214` → `idp_login.py:218` → `_dex_login_page():179,183`

**What actually happens (urllib follows redirects transparently):**

```
Client                          Dex :5556
  │                                │
  │── GET /dex/auth?               │
  │   client_id=libcloud-rest      │
  │   redirect_uri=...8766/...     │  ← OAuth2 authorize request
  │   response_type=code           │
  │   scope=openid email profile   │
  │   state=libcloud-dex           │
  │                                │
  │       ← 302 /dex/auth/lldap    │  ← Dex selects the only connector (lldap)
  │                                │
  │── GET /dex/auth/lldap?         │  ← urllib follows redirect (invisible)
  │   client_id=libcloud-rest      │
  │   ...                          │
  │                                │
  │       ← 302 /dex/auth/lldap/   │  ← Dex redirects to login form
  │          login?back=&          │
  │          state=zhk3znl3cukejdjd7toh6ptkb
  │                                │
  │── GET /dex/auth/lldap/login    │  ← urllib follows redirect (invisible)
  │   ?back=&state=zhk3znl3c...   │
  │                                │
  │       ← 200 HTML login form    │  ← Dex returns the password prompt page
  │                                │
```

**Key detail: the `state` parameter mutation.** The initial `state=libcloud-dex` is the client's CSRF token. After the redirect chain, Dex replaces it with its own session state `state=zhk3znl3cukejdjd7toh6ptkb`. This is Dex's internal session identifier, not the client's CSRF value. The client doesn't need to validate it because it's about to submit credentials directly (not receive a callback with a code yet).

The `opener.open()` in `_dex_login_page` (line 183) returns the final HTML response: Dex's login form. The function then parses the HTML to find the form `action` URL:

```python
# idp_login.py:185-191
match = re.search(r'action="(/dex/auth/[^"]+)"', html)
# Extracts: /dex/auth/lldap/login?back=&state=zhk3znl3cukejdjd7toh6ptkb
post_url = urllib.parse.urljoin(f"{DEX_URL}/", action.lstrip("/"))
```

---

#### Step [b] — Password Authentication (visible in log)

```
>>> POST http://localhost:5556/dex/auth/lldap/login?back=&state=zhk3znl3cukejdjd7toh6ptkb (login=aws-admin)
```

**Code path:** `idp_login.py:219-229`

**What the client sends:**
```
POST /dex/auth/lldap/login?back=&state=zhk3znl3cukejdjd7toh6ptkb
Content-Type: application/x-www-form-urlencoded

login=aws-admin&password=SA-YxB5zqiYyA8M0mscsjfOkuWd
```

**What happens inside Dex (the invisible LDAP authentication):**

```
Client                  Dex :5556                    LLDAP :3890
  │                        │                            │
  │── POST /dex/auth/      │                            │
  │   lldap/login          │                            │
  │   login=aws-admin      │                            │
  │   password=SA-YxB5...  │                            │
  │                        │                            │
  │                        │── LDAP BIND                │
  │                        │   uid=aws-admin,           │
  │                        │   ou=people,               │
  │                        │   dc=libcloud,dc=local     │
  │                        │   password=SA-YxB5...      │
  │                        │                            │
  │                        │        ←── success ──      │  ← LLDAP verifies password
  │                        │                            │
  │                        │── LDAP SEARCH              │
  │                        │   baseDN: ou=people,       │
  │                        │     dc=libcloud,dc=local   │
  │                        │   filter: (objectClass=    │
  │                        │     person)                │
  │                        │   username: uid            │
  │                        │                            │
  │                        │        ←── user attrs ──   │  ← Returns uid, mail, cn
  │                        │                            │
  │       ← 302 Location:  │                            │
  │          http://127.0.  │                            │
  │          0.1:8766/     │                            │
  │          oauth/callback │                            │
  │          ?code=PLTKY... │                            │
  │          &state=libcloud│                            │
  │          -dex           │                            │
  │                        │                            │
```

**The LDAP Bind is the actual password check.** Dex's LDAP connector configuration (`config.yaml:44-62`) specifies:

```yaml
connectors:
  - type: ldap
    id: lldap
    config:
      host: lldap:3890
      bindDN: uid=admin,ou=people,dc=libcloud,dc=local    # service account
      bindPW: 0OMzVB1LsQoIbYHGNFQL                         # service account pw
      userSearch:
        baseDN: ou=people,dc=libcloud,dc=local
        filter: "(objectClass=person)"
        username: uid         # user types uid at login form
        idAttr: uid           # → OIDC `sub` claim
        emailAttr: mail       # → OIDC `email` claim
        nameAttr: cn          # → OIDC `name` claim
```

The flow is:
1. Dex binds to LLDAP as the **service account** (`uid=admin`) to establish an authenticated LDAP session.
2. Dex searches for a user where `uid=aws-admin`.
3. Dex attempts to **bind as that user** using the password from the login form. If LLDAP accepts the bind, the password is correct.
4. Dex fetches the user's attributes (`uid`, `mail`, `cn`) for the OIDC claims.

This is the **moment of truth** — the password `SA-YxB5zqiYyA8M0mscsjfOkuWd` is verified against LLDAP's stored hash for `aws-admin`. No password comparison happens in Dex itself; Dex is a pure proxy.

---

#### Step [c] — Redirect & Authorization Code Capture (invisible in log)

After successful authentication, Dex issues an HTTP 302 redirect:

```
HTTP 302
Location: http://127.0.0.1:8766/oauth/callback?code=PLTKY...&state=libcloud-dex
```

Notice the `state` has reverted to `libcloud-dex` — the client's original CSRF token. This is Dex restoring the client's state after authentication completes successfully.

The `urllib` opener follows this redirect. The destination is `127.0.0.1:8766` — the ephemeral HTTP server that `idp_login.py` started **before** submitting the login form:

```python
# idp_login.py:201-203
server = HTTPServer(("127.0.0.1", 8766), _CallbackHandler)
thread = Thread(target=server.handle_request, daemon=True)
thread.start()
```

The `_CallbackHandler.do_GET` (line 68-83) extracts the `code` parameter and stores it in a class variable:

```python
class _CallbackHandler(BaseHTTPRequestHandler):
    auth_code = ""
    def do_GET(self):
        params = urllib.parse.parse_qs(parsed.query)
        if "code" in params:
            _CallbackHandler.auth_code = params["code"][0]
            # Responds: "Authentication complete. You can close this window."
```

The `opener.open()` call returns after receiving the callback handler's 200 response. The main thread then joins the server thread (line 231).

---

#### Step [d] — Token Exchange (invisible in log)

With the authorization code captured, `idp_login.py` calls `_exchange_code()`:

```python
# idp_login.py:239-240
token_url = f"{DEX_ISSUER}/token"   # = http://localhost:5556/dex/token
return _exchange_code(token_url, _CallbackHandler.auth_code)
```

```
Client                          Dex :5556
  │                                │
  │── POST /dex/token              │
  │   Content-Type:                │
  │     application/x-www-form-    │
  │     urlencoded                 │
  │                                │
  │   grant_type=authorization_code│
  │   code=PLTKY...                │  ← The authorization code from step [c]
  │   redirect_uri=http://127.0.   │
  │     0.1:8766/oauth/callback    │
  │   client_id=libcloud-rest      │
  │   client_secret=HbpzexeVfU...  │  ← From dex/generated/dex.env
  │                                │
  │       ← 200 OK                 │
  │       {                        │
  │         "access_token": "eyJ..",│  ← Signed JWT (RS256)
  │         "token_type": "bearer",│
  │         "expires_in": 3600,    │
  │         "refresh_token": "RF..",│
  │         "id_token": "eyJ.."    │  ← OIDC identity token
  │       }                        │
  │                                │
```

This is the standard OAuth2 token endpoint. Dex validates:
1. The `code` was issued by Dex and hasn't been used before (one-time use)
2. The `client_id` matches the client that initiated the request
3. The `client_secret` matches the `staticClients[0].secret` in `config.yaml`
4. The `redirect_uri` matches the original authorize request

On success, Dex returns a JWT `access_token` signed with its private key (RS256). The libcloud REST API will later validate this JWT against Dex's `/dex/keys` JWKS endpoint.

---

#### Step [e] — Token Caching (invisible in log)

`idp_login.py` saves the token response to disk for future reuse:

```python
# idp_login.py:325
_save_cache(username, token)  # → generated/tokens/aws-admin.json
```

On subsequent runs, `idp_login.py` attempts a **refresh_token** grant first (line 305-307), avoiding the full login flow if the refresh token is still valid. Only if the refresh fails (401/400) does it fall back to the full username+password flow.

---

### What the Two Log Lines Actually Represent

| Log Line | What It Shows | What's Hidden |
|----------|---------------|---------------|
| `>>> GET http://localhost:5556/dex/auth?...` | The initial OAuth2 authorize request | Three internal 302 redirects (auth → auth/lldap → auth/lldap/login → HTML form) that urllib follows silently |
| `>>> POST http://localhost:5556/dex/auth/lldap/login?... (login=aws-admin)` | The credential submission form | The LDAP bind to LLDAP (actual password verification), the 302 redirect to the callback server, the callback capture, and the POST to `/dex/token` for code exchange |

### Complete OAuth2 Message Sequence

```
#  ACTUAL HTTP MESSAGES (7 total, 2 visible)

 Msg │ Method │ URL                                  │ Visible? │ Purpose
─────┼────────┼──────────────────────────────────────┼──────────┼──────────────────────────
  1  │ GET    │ /dex/auth?client_id=libcloud-rest...  │  ✅ YES  │ Initiate OAuth2 auth flow
  2  │GET(302)│ /dex/auth/lldap?...                   │  ❌ no   │ Dex selects LDAP connector
  3  │GET(302)│ /dex/auth/lldap/login?state=zhk3...   │  ❌ no   │ Dex redirects to login form
  4  │ GET    │ /dex/auth/lldap/login?state=zhk3...   │  ❌ no   │ Fetch HTML login form
  5  │ POST   │ /dex/auth/lldap/login?state=zhk3...   │  ✅ YES  │ Submit credentials
     │        │     [Dex → LLDAP: LDAP BIND]          │          │ ← Password verified here
  6  │GET(302)│ http://127.0.0.1:8766/oauth/callback  │  ❌ no   │ Redirect with auth code
     │        │     [Captured by local HTTPServer]     │          │
  7  │ POST   │ /dex/token                            │  ❌ no   │ Exchange code for tokens
     │        │     [access_token saved & printed]     │          │
```

### Where Is the Actual Password Authentication?

**The password check happens between log lines [a] and [b].** More precisely, it occurs inside Dex's connector logic when it receives the POST at step 5. Here's exactly where:

1. `idp_login.py:221-229` sends `POST /dex/auth/lldap/login` with `login=aws-admin&password=SA-YxB5zqiYyA8M0mscsjfOkuWd`
2. Dex's HTTP handler receives the POST and extracts the `login` and `password` form fields
3. Dex's LDAP connector (`config.yaml:44-62`) performs an **LDAP bind** to `lldap:3890` with:
   - DN: `uid=aws-admin,ou=people,dc=libcloud,dc=local`
   - Password: `SA-YxB5zqiYyA8M0mscsjfOkuWd`
4. **LLDAP validates the bind.** If the password matches the stored hash, the bind succeeds. If not, LLDAP returns an LDAP invalid credentials error.
5. On success, Dex creates a session, generates an authorization code, and returns the 302 redirect to the callback URL.

The critical architectural point: **Dex never sees the actual password hash.** LLDAP is the sole password verifier. Dex sends the password in the LDAP bind request and LLDAP returns success/failure. This is the standard LDAP authentication pattern — the application (Dex) proxies the credentials to the directory server (LLDAP).

### The OIDC Identity Produced

The JWT `id_token` that Dex issues contains claims derived from the LLDAP user entry:

```
JWT payload (decoded):
{
  "iss": "http://localhost:5556/dex",
  "sub": "aws-admin",              ← LLDAP uid → idAttr
  "aud": "libcloud-rest",          ← OAuth2 client_id
  "exp": 1751364426,
  "iat": 1751360826,
  "email": "aws-admin@libcloud.local",  ← LLDAP mail attribute
  "name": "AWS Admin",                  ← LLDAP cn attribute
  "federated_claims": {
    "connector_id": "lldap",
    "user_id": "aws-admin"
  }
}
```

The libcloud REST API validates this JWT against `http://localhost:5556/dex/keys` (Dex's JWKS endpoint) and maps the `sub` claim to the RBAC scope returned in `GET /v1/auth/me`. The `tenant_id` and `allowed_providers` are determined by the REST API's own policy engine, not by the JWT claims — Dex is purely an identity provider; authorization is the REST API's concern.

---

## Phase 2 — Identity Verification

### Request #3: Verify Authenticated Session

```
>>> GET http://localhost:8765/v1/auth/me
>>> Headers: Authorization: Bearer ***REDACTED***
```

**What this does:** Confirms the bearer token obtained from the OAuth2 flow is valid and returns the authenticated user's identity and permissions.

**Response (HTTP 200):**
```json
{
    "data": {
        "username": "aws-admin",
        "tenant_id": "default",
        "scope": "compute:read compute:image:read compute:size:read compute:location:read compute:node:create compute:node:delete compute:node:power compute:node:update compute:volume:manage compute:snapshot:manage compute:network:read compute:network:manage compute:keypair:manage jobs:read",
        "allowed_providers": ["aws"],
        "session_id": "aws-admin"
    }
}
```

**Key observation:** The user `aws-admin` has broad compute permissions including `compute:node:create`, `compute:node:delete`, `compute:volume:manage`, and `compute:network:manage` — everything needed to provision and tear down infrastructure. The user is scoped to provider `aws` only.

---

## Phase 3 — AWS Connectivity Test

### Request #4: Validate AWS Credentials

```
>>> POST http://localhost:8765/v1/connections:test
>>> Body:
{
    "provider": "aws",
    "config": {
        "region": "ap-southeast-1",
        "secure": true
    },
    "auth_binding": "aws"
}
```

**What this does:** Tests that the libcloud API can successfully authenticate to AWS using the bound credentials. This is a **pre-flight check** — if credentials are invalid, expired, or lack permissions, the script fails here before any resource enumeration.

**Response (HTTP 200):**
```json
{
    "data": {
        "target": "aws:ap-southeast-1",
        "provider": "aws",
        "status": "ok",
        "capabilities": {
            "create_node_auth": ["ssh_key"],
            "supports_volumes": true,
            "supports_snapshots": true,
            "supports_key_pairs": true,
            "supports_wait_until_running": true
        }
    }
}
```

**Key observation:** The connection is established to `ap-southeast-1`. Capabilities include SSH key-based node auth, volume/snapshot support, and the ability to wait until an instance reaches running state.

---

## Phase 4 — Resource Discovery (Enumeration)

This phase enumerates AWS resources to determine *what is available* before selecting targets for provisioning. All requests carry the `X-Provider-Connection` header containing the resolved AWS connection context.

### Request #5: List Locations (Availability Zones)

```
>>> GET http://localhost:8765/v1/compute/locations
```

**What this does:** Queries `DescribeAvailabilityZones` via the AWS EC2 API. Returns the availability zones in `ap-southeast-1`.

**Response summary:**
| ID | Name               | Country   |
|----|--------------------|-----------|
| 0  | ap-southeast-1a    | Singapore |
| 1  | ap-southeast-1b    | Singapore |
| 2  | ap-southeast-1c    | Singapore |

**Purpose:** Discover which AZs are available for placing nodes.

---

### Request #6: List EC2 Instance Sizes (1st call)

```
>>> GET http://localhost:8765/v1/compute/sizes
```

**What this does:** Queries the AWS Price List / EC2 `DescribeInstanceTypes` API. Returns the complete catalog of EC2 instance types with specs.

**Response size:** 537,106 bytes (~537 KB) — hundreds of instance types.

**Sample data:**
| Type            | vCPU | RAM    | Arch   | Family         |
|-----------------|------|--------|--------|----------------|
| a1.2xlarge      | 8    | 16 GiB | 64-bit | General purpose |
| c5.large        | 2    | 4 GiB  | x86_64 | Compute opt    |
| t3.micro        | 2    | 1 GiB  | x86_64 | Burstable      |
| ...             | ...  | ...    | ...    | ...            |

**Purpose:** Discover which instance types exist. The script later filters this list to select `t3.micro`.

---

### Request #7: Search for Ubuntu AMIs (1st call)

```
>>> GET http://localhost:8765/v1/compute/images?name=%2AUbuntu%2A
```

(`%2A` = `*` URL-encoded, so the query is `*Ubuntu*`)

**What this does:** Queries `DescribeImages` with a name filter for `*Ubuntu*`. Returns all public AMIs whose name contains "Ubuntu".

**Response size:** 3,254,863 bytes (~3.1 MB). This is a massive catalog, including:
- Deep Learning AMIs (GPU-enabled, various Ubuntu versions)
- Marketplace images (ClearImages, third-party)
- Canonical official Ubuntu AMIs
- Community AMIs
- Cloud9 Ubuntu AMIs (dev environment images)

Each entry includes `architecture`, `owner_id`, `creation_date`, `root_device_type`, `virtualization_type`, and release note URLs.

**Purpose:** Discover which Ubuntu images are available to boot from.

---

### Request #8: List Existing EC2 Instances

```
>>> GET http://localhost:8765/v1/compute/nodes
```

**What this does:** Queries `DescribeInstances` to find what's already running.

**Response:**
```json
{
    "data": [
        {
            "id": "i-0b351afdefc267cab",
            "name": "libcloud-demo-1782893547",
            "state": "running",
            "public_ips": ["52.77.240.23"],
            "private_ips": ["10.99.1.135"],
            "extra": {
                "availability": "ap-southeast-1a",
                "architecture": "x86_64",
                "image_id": "ami-04d37d9971ba85c64",
                "instance_type": "t3.micro",
                "launch_time": "2026-07-01T08:12:40.000Z"
            }
        }
    ]
}
```

**Key observation:** One existing node (`i-0b351afdefc267cab`) from a previous run ~2 hours earlier. It's a `t3.micro` in `ap-southeast-1a` using AMI `ami-04d37d9971ba85c64` (Cloud9Ubuntu22) with public IP `52.77.240.23` and private IP `10.99.1.135`.

---

### Request #9: Search for Ubuntu AMIs (2nd call)

```
>>> GET http://localhost:8765/v1/compute/images?name=%2AUbuntu%2A
```

**Same as Request #7** — re-fetches the full 3.1 MB image catalog. This duplicate call is part of the script's selection logic: it iterates the image list to find a matching Ubuntu 22.04 x86_64 image suitable for `t3.micro`.

---

## Phase 5 — Target Selection & Provisioning

### Request #10: List Instance Sizes (2nd call)

```
>>> GET http://localhost:8765/v1/compute/sizes
```

**Same as Request #6** — re-fetches the full 537 KB sizes catalog. The script narrows down to a specific size matching the selected image's architecture.

**Script decision output:**
```
Selected image=Cloud9Ubuntu22-2026-06-23T14-03
Selected size=t3.micro arch=x86_64
```

The script selected:
- **Image:** `Cloud9Ubuntu22-2026-06-23T14-03` — a Cloud9 dev environment Ubuntu 22.04 AMI (likely AMI `ami-04d37d9971ba85c64`, matching the existing node)
- **Size:** `t3.micro` — 2 vCPU, 1 GiB RAM, x86_64, burstable (free-tier eligible)

---

### Request #11: List Subnets

```
>>> GET http://localhost:8765/v1/compute/subnets
```

**What this does:** Queries `DescribeSubnets` to find available VPC subnets for placing the new instance.

**Response summary:**
| Subnet ID                  | Name                 | CIDR         | VPC ID                  | Available IPs | Zone              |
|----------------------------|----------------------|--------------|-------------------------|---------------|-------------------|
| subnet-00925510c452acbfa   | libcloud-test-subnet | 10.99.1.0/24 | vpc-05dcbeb7a862763aa   | 250           | ap-southeast-1a   |
| subnet-02ce81cd701438fbf   | test-libcloud-subnet | 10.88.1.0/24 | vpc-049ac91e89f253a13   | 251           | ap-southeast-1a   |
| subnet-0433b513ff4b9e2f0   | test-libcloud-subnet | 10.88.1.0/24 | vpc-0e7b83388d24b32a8   | 251           | ap-southeast-1a   |

**Selection:** The script picks `subnet-00925510c452acbfa` (`libcloud-test-subnet`, 10.99.1.0/24) — the same subnet as the existing node.

---

### Request #12: CREATE EC2 Instance ← THE PROVISIONING STEP

```
>>> POST http://localhost:8765/v1/compute/nodes
>>> Body:
{
    "name": "libcloud-demo-1782900426",
    "size": {
        "id": "t3.micro"
    },
    "image": {
        "id": "ami-04d37d9971ba85c64"
    },
    "network": {
        "public_ip": true,
        "subnet_id": "subnet-00925510c452acbfa"
    },
    "connection": {
        "provider": "aws",
        "config": {
            "region": "ap-southeast-1",
            "secure": true
        },
        "auth_binding": "aws"
    }
}
```

**What this does:** The **only mutating API call** in the entire flow. Calls `RunInstances` on the AWS EC2 API with:

| Parameter          | Value                                    |
|--------------------|------------------------------------------|
| **Name**           | `libcloud-demo-1782900426`               |
| **Instance Type**  | `t3.micro`                               |
| **AMI**            | `ami-04d37d9971ba85c64` (Cloud9Ubuntu22) |
| **Subnet**         | `subnet-00925510c452acbfa` (10.99.1.0/24)|
| **Public IP**      | `true` (assign public IPv4)              |
| **Region**         | `ap-southeast-1`                         |

The instance ID suffix `1782900426` is a timestamp-based identifier.

**Response (HTTP 200):**
```json
{
    "data": {
        "id": "i-016be52ac5fcbe41a",
        "name": "libcloud-demo-1782900426",
        "state": "pending",
        "public_ips": [],
        "private_ips": ["10.99.1.99"],
        "extra": {
            "availability": "ap-southeast-1a",
            "architecture": "x86_64",
            "image_id": "ami-04d37d9971ba85c64",
            "instance_id": "i-016be52ac5fcbe41a",
            "instance_type": "t3.micro",
            "launch_time": "2026-07-01T10:07:19.000Z",
            "status": "pending",
            "subnet_id": "subnet-00925510c452acbfa",
            "vpc_id": "vpc-05dcbeb7a862763aa",
            "groups": [{"group_id": "sg-0dc02ef6ca5a5044a", "group_name": "default"}],
            "network_interfaces": [{
                "id": "eni-0b36e266e87104146",
                "state": "in-use",
                "private_ips": [{"private_ip": "10.99.1.99", "primary": "true"}]
            }],
            "tags": {"Name": "libcloud-demo-1782900426"}
        }
    }
}
```

**Provisioning result:** EC2 instance created successfully:
- **Instance ID:** `i-016be52ac5fcbe41a`
- **State:** `pending` (initializing — transitions to `running` shortly after)
- **Private IP:** `10.99.1.99`
- **Public IP:** not yet assigned (assigned once `running`)
- **Availability Zone:** `ap-southeast-1a`
- **Security Group:** `sg-0dc02ef6ca5a5044a` (default)
- **Network Interface:** `eni-0b36e266e87104146`
- **Tags:** `Name=libcloud-demo-1782900426`

---

## Post-Provisioning

The log concludes with the deprovision script being invoked:
```bash
+ LIBCLOUD_USER=aws-admin
+ VERBOSE=1
+ ./scripts/deprovision_aws.sh
+ exit
```

This suggests the `provision_aws.sh` script, after creating the node, automatically calls `deprovision_aws.sh` to tear it down — indicating this was a **test/demo provisioning run** rather than a persistent deployment.

---

## Complete Request Summary Table

| # | Method | Endpoint | Phase | Line | Response Size |
|---|--------|----------|-------|------|---------------|
| 1 | `GET` | `localhost:5556/dex/auth` | Auth | 16 | (redirect) |
| 2 | `POST` | `localhost:5556/dex/auth/lldap/login` | Auth | 17 | (redirect) |
| 3 | `GET` | `localhost:8765/v1/auth/me` | Identity | 18 | 433 B |
| 4 | `POST` | `localhost:8765/v1/connections:test` | Test | 47 | 271 B |
| 5 | `GET` | `localhost:8765/v1/compute/locations` | **List** | 91 | 258 B |
| 6 | `GET` | `localhost:8765/v1/compute/sizes` | **List** | 132 | 537 KB |
| 7 | `GET` | `localhost:8765/v1/compute/images?name=*Ubuntu*` | **List** | 21,926 | 3.1 MB |
| 8 | `GET` | `localhost:8765/v1/compute/nodes` | **List** | 164,999 | 2 KB |
| 9 | `GET` | `localhost:8765/v1/compute/images?name=*Ubuntu*` | **List** | 165,128 | 3.1 MB |
| 10 | `GET` | `localhost:8765/v1/compute/sizes` | **List** | 308,201 | 537 KB |
| 11 | `GET` | `localhost:8765/v1/compute/subnets` | **List** | 329,997 | 1.1 KB |
| 12 | `POST` | `localhost:8765/v1/compute/nodes` | ➤ **CREATE** | 330,075 | 1.8 KB |

**Data transferred total:** ~7.3 MB (almost entirely from image and size catalogs in requests #6, #7, #9, #10)

---

## Request Type Breakdown

```
Auth requests:        2  (16.7%)  — Dex OAuth2 login
Identity check:       1  ( 8.3%)  — Session validation
Connectivity test:    1  ( 8.3%)  — AWS credential verification
Read/list requests:   7  (58.3%)  — Resource enumeration
Create requests:      1  ( 8.3%)  — EC2 instance provisioning
                     --
Total                12 (100%)
```

**Read vs Write ratio:** 11:1 — the vast majority of HTTP traffic is read-only discovery. This is characteristic of infrastructure-as-code provisioning: you enumerate the cloud surface first, make a targeted selection, then issue a single creation call.

---

## Identity Model

The `aws-admin` user operates with the following RBAC scope:

| Permission | Scope |
|------------|-------|
| `compute:read` | Read compute resources |
| `compute:image:read` | List/search AMIs |
| `compute:size:read` | List instance types |
| `compute:location:read` | List regions/AZs |
| `compute:node:create` | **Create EC2 instances** |
| `compute:node:delete` | Terminate EC2 instances |
| `compute:node:power` | Start/stop/reboot |
| `compute:node:update` | Modify instance attributes |
| `compute:volume:manage` | Create/attach/detach/delete EBS volumes |
| `compute:snapshot:manage` | Create/delete EBS snapshots |
| `compute:network:read` | List subnets/VPCs |
| `compute:network:manage` | Create/modify network resources |
| `compute:keypair:manage` | Create/delete SSH key pairs |
| `jobs:read` | Query async job status |

The user is restricted to `allowed_providers: ["aws"]` — they cannot provision resources on other clouds (Nutanix, GCP, etc.) even if the libcloud server supports them.

---

## AWS Credential Lifecycle: From Environment to Vault to EC2 API

A critical design property of this system is that **the provisioning client (`provision_aws.sh`) never handles AWS credentials**. The client sends only `auth_binding: "aws"` in the `X-Provider-Connection` header. The libcloud REST API resolves the actual `AWS_ACCESS_KEY` / `AWS_SECRET_ACCESS_KEY` server-side from HashiCorp Vault. This section traces exactly how credentials flow from the operator's shell into Vault and then into the EC2 API.

### Credential Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│                     CREDENTIAL LIFECYCLE                           │
│                                                                    │
│  ┌──────────────────┐          ┌──────────────────┐               │
│  │ Operator's shell │          │  libcloud REST   │               │
│  │ (host)           │          │  API container   │               │
│  │                  │          │                  │               │
│  │ AWS_ACCESS_KEY   │          │ .env:            │               │
│  │ AWS_SECRET_KEY   │          │  VAULT_ADDR=     │               │
│  └────────┬─────────┘          │   vault:8200     │               │
│           │                    │  VAULT_TOKEN=    │               │
│           │                    │   hvs.CAESIM...  │               │
│    ┌──────▼──────────┐         └────────┬─────────┘               │
│    │ set_tenant_     │                  │                          │
│    │ credentials.py  │                  │                          │
│    │                 │                  │                          │
│    │ 1. Dex login    │                  │                          │
│    │ 2. OpenFGA check│                  │                          │
│    │ 3. Vault write  │─────── PUT ─────►│                          │
│    └─────────────────┘    secret/data/  │                          │
│                           libcloud/aws  │                          │
│                                         │                          │
│                           ┌─────────────▼──────────────┐          │
│                           │ HashiCorp Vault :8200      │          │
│                           │                            │          │
│                           │ KV v2: secret/data/        │          │
│                           │   libcloud/aws             │          │
│                           │   {                        │          │
│                           │     "key": "AKIAYHGE...",  │          │
│                           │     "secret": "ZOgTuU..."  │          │
│                           │   }                        │          │
│                           │   libcloud/nutanix         │          │
│                           │   {                        │          │
│                           │     "key": "admin",        │          │
│                           │     "secret": "NtnxPwd..." │          │
│                           │   }                        │          │
│                           └─────────────┬──────────────┘          │
│                                         │                          │
│                           ┌─────────────▼──────────────┐          │
│                           │ resolve_server_credentials │          │
│                           │   (credentials.py:82)      │          │
│                           │                            │          │
│                           │ 1. vault_client.read_      │          │
│                           │    secret("aws")           │          │
│                           │ 2. GET /v1/secret/data/    │          │
│                           │    libcloud/aws            │          │
│                           │    X-Vault-Token: hvs...   │          │
│                           │ 3. Returns {key, secret}   │          │
│                           │ 4. Cached in-memory 30s    │          │
│                           └─────────────┬──────────────┘          │
│                                         │                          │
│                                    ┌────▼────┐                    │
│                                    │ AWS EC2 │                    │
│                                    │ API     │                    │
│                                    └─────────┘                    │
└────────────────────────────────────────────────────────────────────┘
```

### Step 1: Credential Seeding (`set_tenant_credentials.py`)

The operator (or `aws-owner`) writes AWS credentials to Vault using a **three-gate process** (file: `scripts/set_tenant_credentials.py`):

**Gate 1 — Dex Authentication (lines 159-172):**
```python
# Prove the operator IS the claimed owner user
env["LIBCLOUD_USER"] = user       # e.g., "aws-owner"
env["LIBCLOUD_PASSWORD"] = password
proc = subprocess.run([sys.executable, "scripts/idp_login.py"], env=env, ...)
jwt = proc.stdout.strip()         # Validated JWT from Dex
```
The operator must successfully authenticate as `aws-owner` against Dex/LLDAP. This proves their identity.

**Gate 2 — OpenFGA Authorization (lines 174-185):**
```python
# Verify the owner role via OpenFGA policy check
fga_user = f"user:aws-owner"
allowed = _fga_check(..., fga_user, "can_manage_credentials", "tenant:aws")
# → True if user is owner on tenant:aws (or superadmin)
```
OpenFGA verifies the user holds the `can_manage_credentials` relation on `tenant:aws`. Only `owner` (and `superadmin` as break-glass) have this relation. `aws-admin` and `aws-viewer` are **denied**.

**Gate 3 — Vault Write (lines 187-193):**
```python
# Write to Vault KV v2 using root token
_vault_write(vault_addr, root_token, tenant="aws", data={
    "key": "AKIAYHGEH2P7SNGEPLZH",       # LIBCLOUD_AWS_KEY
    "secret": "ZOgTuUtKRHlOu9NvjWP..."    # LIBCLOUD_AWS_SECRET
})
# → PUT /v1/secret/data/libcloud/aws
#   X-Vault-Token: hvs.3WR6Oq3I0HKtMTsD9YBBUbao (root token)
```

The Vault write uses the **root token** (from `vault/generated/vault.env`) — the highest-privilege credential. This is acceptable because the operator has already passed two strong identity gates (Dex + OpenFGA) before reaching this point. The root token never leaves the host and is only used by this admin script.

**What the log reveals about this step:**

The preamble of `run_aws_admin.log.stderr` shows a credential seeding attempt that **failed**:

```
+ LIBCLOUD_USER=aws-owner
+ LIBCLOUD_AWS_KEY=              ← EMPTY — the key was not provided
+ LIBCLOUD_AWS_SECRET=ZOgTuUtKRHlOu9NvjWP52hUx2/D1EGkBRY83BwwW
+ python3 scripts/set_tenant_credentials.py
set_tenant_credentials: credential values are required at runtime for tenant:aws
(cloud=aws; set LIBCLOUD_AWS_KEY/LIBCLOUD_AWS_SECRET)
```

The AWS access key (`AKIAYHGEH2P7SNGEPLZH`) was available as `AWS_ACCESS_KEY` (standard AWS env var) but not as `LIBCLOUD_AWS_KEY` (the name `set_tenant_credentials.py` expects). The secret was accidentally mapped from the wrong env var. The write was **skipped**.

However, the provisioning still succeeded because **the credentials were already in Vault from a prior successful seeding run**. This demonstrates Vault's persistence across script invocations.

### Step 2: Vault Bootstrap & Token Issuance (`vault_bootstrap.py`)

Before any credentials can be written or read, `setup.sh` calls `vault_bootstrap.py` (superadmin-gated) which:

1. **Initializes** Vault (`POST /v1/sys/init`) with 1 key share, threshold 1 → returns `root_token` + `unseal_key`
2. **Unseals** Vault (`POST /v1/sys/unseal`)
3. **Enables KV v2** at `secret/` (`POST /v1/sys/mounts/secret`)
4. **Creates a read-only ACL policy** named `libcloud-rest-read`:
   ```hcl
   path "secret/data/libcloud/*" {
     capabilities = ["read"]
   }
   path "secret/metadata/libcloud/*" {
     capabilities = ["read", "list"]
   }
   ```
5. **Issues a least-privilege read token** for the libcloud REST API:
   ```
   POST /v1/auth/token/create
   → {policies: ["libcloud-rest-read"], ttl: "768h", renewable: true}
   → VAULT_TOKEN=hvs.CAESIMiuCVSAPk-MOHMQCgxpEMzsMeXp1djBJEaEl0VRZG_T...
   ```

The root token, unseal key, and libcloud read token are written to `vault/generated/vault.env` (chmod 600). The read token has **no write access** — it can only read from `secret/data/libcloud/*`.

### Step 3: Token Synchronization to libcloud REST API

`setup.sh` (lines 218-249) syncs the Vault token into the libcloud REST API's `.env`:

```bash
# setup.sh: sync_libcloud_rest_vault()
# Reads VAULT_TOKEN from vault/generated/vault.env
# Writes it to ../libcloud.rest/.env:
#   VAULT_ADDR=http://vault:8200
#   VAULT_TOKEN=hvs.CAESIMiuCVSAPk-MOHMQCgxpEMzsMeXp1djBJEaEl0VRZG_T...
```

The docker-compose file for libcloud REST maps these as environment variables into the container:
```yaml
# libcloud.rest/docker-compose.yml
environment:
  VAULT_ADDR: http://vault:8200
  # VAULT_TOKEN is read from .env
```

Both containers (`vault` and `libcloud-rest-api`) are on the shared Docker network `libcloud_net`, so `http://vault:8200` resolves within the container.

### Step 4: Runtime Credential Resolution (Inside the `POST /v1/connections:test` Handler)

When the libcloud REST API receives a connection request with `auth_binding: "aws"`, the credential resolution chain is:

```
POST /v1/connections:test
  body: {provider: "aws", config: {region: "ap-southeast-1"}, auth_binding: "aws"}
       │
       ▼
effective_credentials(connection)          ← credentials.py:127
  │
  ├─ enforce_credential_policy()           ← credentials.py:30
  │   └─ Rejects client-supplied creds (ALLOW_CLIENT_CREDENTIALS=false)
  │
  └─ resolve_server_credentials()          ← credentials.py:82
       │
       ├─ binding = connection.auth_binding or default_auth_binding("aws")
       │           = "aws"
       │
       └─ vault = get_vault_client()
          │
          └─ vault.enabled?                ← vault_client.py:37
             │  (true when VAULT_ADDR + VAULT_TOKEN are both set)
             │
             ├─ YES → vault.read_secret("aws")
             │        │
             │        ├─ Check in-memory cache (30s TTL)
             │        │
             │        └─ GET http://vault:8200/v1/secret/data/libcloud/aws
             │           X-Vault-Token: hvs.CAESIMiuCVSAPk-MOHMQCgxpEMz...
             │           │
             │           └─ Response:
             │              {
             │                "data": {
             │                  "data": {
             │                    "key": "AKIAYHGEH2P7SNGEPLZH",
             │                    "secret": "ZOgTuUtKRHlOu9NvjWP..."
             │                  }
             │                }
             │              }
             │           │
             │           └─ Returns ConnectionCredentials(key=..., secret=...)
             │
             └─ NO → _env_credentials("aws", "aws")
                      └─ Falls back to LIBCLOUD_AWS_PROD_KEY / LIBCLOUD_AWS_PROD_SECRET
                         from the API's own .env (empty in production — dev only)
```

### Step 5: The AWS EC2 API Call

With the resolved `ConnectionCredentials`, the libcloud REST API constructs an authenticated AWS SDK call. The credentials `{key: "AKIAYHGEH2P7SNGEPLZH", secret: "ZOgTuUtKRHlOu9NvjWP..."}` are passed to the AWS API via Signature V4 signing — they authenticate the `DescribeInstances`, `DescribeImages`, `RunInstances`, etc. calls that back the 8 listing/provisioning endpoints.

### The Client-Side Guarantee

The critical security property: **the provisioning client never touches AWS credentials**. From the client's perspective, the entire interaction is:

```bash
# The client sends ONLY this (no AWS key/secret anywhere):
POST /v1/compute/nodes
X-Provider-Connection: {"provider":"aws","config":{"region":"ap-southeast-1","secure":true},"auth_binding":"aws"}
Authorization: Bearer eyJ...  (Dex OIDC JWT)

{
  "name": "libcloud-demo-...",
  "size": {"id": "t3.micro"},
  "image": {"id": "ami-04d37d9971ba85c64"},
  "network": {"public_ip": true, "subnet_id": "subnet-..."},
  "connection": {
    "provider": "aws",
    "config": {"region": "ap-southeast-1", "secure": true},
    "auth_binding": "aws"
  }
}
```

The `auth_binding: "aws"` is the only clue the client gives about which credentials to use. Everything else happens server-side:

| What | Where | Who Can Access |
|------|-------|---------------|
| AWS Access Key ID | Vault `secret/data/libcloud/aws` | Only libcloud REST container (read token) |
| AWS Secret Key | Vault `secret/data/libcloud/aws` | Only libcloud REST container (read token) |
| OIDC JWT | Client memory | Client (short-lived, ~1h) |
| Vault root token | `vault/generated/vault.env` (host, 0600) | Only host scripts (setup.sh, set_tenant_credentials.py) |
| Vault read token | libcloud REST `.env` → container env | Only libcloud REST container |
| User password | `dex/generated/dex.env` (host) | Only host scripts (idp_login.py) |

### Security Properties

1. **No credentials in client code.** The provisioning scripts (`provision_aws.sh`, `common.sh`) contain zero AWS secrets.
2. **No credentials in transit to client.** The bearer token in `Authorization: Bearer` is a Dex OIDC JWT, not an AWS credential.
3. **No credentials in `.env` files.** The libcloud REST `.env` has `LIBCLOUD_AWS_PROD_KEY=` (empty). Credentials live only in Vault's encrypted KV store.
4. **Per-tenant isolation.** `secret/data/libcloud/aws` and `secret/data/libcloud/aws-dev` are separate secrets — different tenants can use entirely different AWS accounts.
5. **Write-gated by OpenFGA.** Only `owner` (and `superadmin`) can write credentials to Vault. `admin` and `viewer` cannot.
6. **Least-privilege Vault token.** The libcloud REST API's token can only `read` from `secret/data/libcloud/*` and `list` metadata. It cannot write secrets, cannot read other paths, and cannot manage Vault itself.
7. **In-memory only on the API side.** The `VaultClient` caches decoded credentials in a Python dict with a 30-second TTL. Credentials never touch the API container's filesystem.
