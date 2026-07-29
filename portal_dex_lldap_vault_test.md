
# Infrastructure Smoke Test — Portal, Dex, LLDAP, Vault

Script at: **`test_script/scripts/infra-smoke-test.sh`**  
Run it against the live stack to verify all 5 core infrastructure containers are up and responding correctly via curl.

## Quick start

```bash
chmod +x test_script/scripts/infra-smoke-test.sh

# Default — tests localhost on standard ports
./test_script/scripts/infra-smoke-test.sh

# Custom host
./test_script/scripts/infra-smoke-test.sh my-host.example.com

# Override individual ports via env
PORTAL_PORT=4000 DEX_PORT=5557 ./test_script/scripts/infra-smoke-test.sh
```

Exit code = number of failures — exit 0 means everything passed (CI-ready).

## Services tested

| Service | Container | Port | What it does |
|---|---|---|---|
| Portal | `portal` | 3000 | React SPA (nginx) — role portal UI |
| Dex | `dex` | 5556 | OIDC issuer — federated login (LLDAP, Google, GitHub) |
| LLDAP | `lldap` | 17170 | LDAP user directory + admin Web UI |
| Vault | `vault` | 8200 | Encrypted secret store (cloud credentials) |
| Identity Service | `identity-service` | 8766 | Portal backend — session, users, auth, provisioning orchestrator |

All containers share the `libcloud_net` Docker network.

## Test sections (38 checks)

### 0. Docker containers — 5 checks
Confirms each container is running via `docker ps`.

### 1. Portal (port 3000) — 4 checks
- `GET /` → 200 HTML
- Content-Type: text/html
- Static JS bundle reachable

### 2. Dex OIDC (port 5556) — 10 checks
- OIDC discovery doc → 200 valid JSON
- Discovery fields: issuer, jwks_uri, authorization_endpoint, token_endpoint
- JWKS keys endpoint → 200 valid JSON, contains "keys" array
- Auth login page → 200 HTML
- Healthz → 200

### 3. LLDAP (port 17170) — 4 checks
- Web UI root → 200 HTML
- Content-Type check
- Static assets reachable

### 4. Vault (port 8200) — 5 checks
- `/v1/sys/seal-status` → 200 JSON (works in all states: uninit/sealed/unsealed)
- Contains "sealed" field
- `/v1/sys/health` — listener alive (accepts 200/429/501/503)
- Vault UI `/ui/` → 200

### 5. Identity Service (port 8766) — 7 checks
- `/health` → 200 JSON
- `/api/users` → 401 JSON (protected, no session — correct)
- `/api/session` → 401 JSON (protected — correct)
- `/api/auth/begin?provider=google` → 200 JSON with authorizeUrl
- `/api/auth/begin` (no provider) → 422 (validation — proves endpoint exists)

### 6. Cross-service — 3 checks
- Dex issuer references public hostname (quest4science)
- Vault seal-status valid JSON
- Portal SPA has React root div

## Test infrastructure

The helpers follow the pattern from `stoplight_mock/scripts/prism-test.sh`:

| Helper | Checks |
|---|---|
| `check_container <name>` | Docker container running |
| `check_code <desc> <code> [curl args]` | HTTP status code match |
| `check_body <desc> <code> <pattern> [curl args]` | Status code + response body contains pattern |
| `check_json <desc> <code> [curl args]` | Status code + valid JSON body |
| `check_ctype <desc> <mime> [curl url]` | Content-Type header starts with prefix |

All `check_*` helpers return 0 on pass, 1 on fail — so `||` fallback chains work correctly for endpoints that can return multiple valid status codes (e.g. Vault health: 200/429/501/503 all mean "alive").

## Important endpoint behaviours discovered

- **Dex `/dex/auth`** — without query params renders the login page (200 HTML), does not redirect.
- **Dex `/dex/healthz`** — Dex v2.41 added a dedicated health endpoint.
- **LLDAP** — uses lowercase `<!doctype html>` (not `<!DOCTYPE html>`).
- **Vault `/v1/sys/seal-status`** — returns 200 in every state (uninitialised, sealed, unsealed). Reliably confirms the listener is up. For readiness, additionally check `/v1/sys/health`.
- **Identity Service `/api/users`**, `/api/session` — return 401 with JSON body `{"error":"auth_no_session"}` when no session cookie is present. This is correct behaviour.
- **Identity Service `/api/auth/begin`** — returns 200 JSON with the Dex `authorizeUrl` (not a 302 redirect). Requires a `provider` query param; bare GET returns 422 (validation error).

## Sample passing output

```
╔══════════════════════════════════════════════════════╗
║   Infrastructure Smoke Test                         ║
║   Host: localhost                                   ║
║   Portal: :3000                                     ║
║   Dex:    :5556                                     ║
║   LLDAP:  :17170                                    ║
║   Vault:  :8200                                     ║
║   Identity: :8766                                   ║
╚══════════════════════════════════════════════════════╝

── 0. Docker containers — running check ──
✓ Container portal is running
✓ Container dex is running
✓ Container lldap is running
✓ Container vault is running
✓ Container identity-service is running

── 1. Portal (nginx / React SPA) — http://localhost:3000 ──
✓ Portal root (GET /) → 200 (HTTP 200)
✓ Portal root returns HTML (HTTP 200, body matches '<html')
✓ Portal serves HTML (Content-Type: text/html)
✓ Portal static JS bundle (HTTP 200)

── 2. Dex OIDC — http://localhost:5556 ──
✓ OIDC discovery (GET /.well-known/openid-configuration) → 200 (HTTP 200, valid JSON)
✓ OIDC discovery Content-Type is JSON (Content-Type: application/json)
✓ Discovery doc contains 'issuer' (HTTP 200, body matches '"issuer"')
✓ Discovery doc contains 'jwks_uri' (HTTP 200, body matches '"jwks_uri"')
✓ Discovery doc contains 'authorization_endpoint' (HTTP 200, body matches '"authorization_endpoint"')
✓ Discovery doc contains 'token_endpoint' (HTTP 200, body matches '"token_endpoint"')
✓ JWKS keys (GET /dex/keys) → 200 (HTTP 200, valid JSON)
✓ JWKS contains keys array (HTTP 200, body matches '"keys"')
✓ Auth endpoint (GET /dex/auth) → login page (200) (HTTP 200, body matches '<html')
✓ Dex healthz (GET /dex/healthz) → 200 (HTTP 200)

── 3. LLDAP — http://localhost:17170 ──
✓ LLDAP Web UI root (GET /) → 200 (HTTP 200)
✓ LLDAP returns HTML (HTTP 200, body matches '<!doctype html>')
✓ LLDAP serves HTML (Content-Type: text/html; charset=utf-8)
✓ LLDAP static assets reachable (HTTP 200)

── 4. Vault — http://localhost:8200 ──
✓ Vault seal-status (GET /v1/sys/seal-status) → 200 (HTTP 200)
✓ Seal-status returns JSON (HTTP 200, valid JSON)
✓ Seal-status contains 'sealed' field (HTTP 200, body matches '"sealed"')
✓ Vault health (GET /v1/sys/health) → listener alive (HTTP 200)
✓ Vault UI (GET /ui/) → 200 (HTTP 200)

── 5. Identity Service — http://localhost:8766 ──
✓ Health endpoint (GET /health) → 200 (HTTP 200)
✓ Health response is JSON (HTTP 200, valid JSON)
✓ API users (GET /api/users) → 401 (protected, no session) (HTTP 401, valid JSON)
✓ API session (GET /api/session) → 401 (protected, no session) (HTTP 401, valid JSON)
✓ OAuth begin (GET /api/auth/begin?provider=google) → 200 + authorizeUrl (HTTP 200, valid JSON)
✓ OAuth begin returns Dex authorizeUrl (HTTP 200, body matches 'authorizeUrl')
✓ OAuth begin no provider → 422 (validation, endpoint exists) (HTTP 422)

── 6. Cross-service connectivity ──
✓ Dex issuer matches public hostname (HTTP 200, body matches 'quest4science')
✓ Vault seal-status is valid JSON (cross-check) (HTTP 200, valid JSON)
✓ Portal SPA has react root div (HTTP 200, body matches '<div id="root"')

════════════════════════════════════════════════════════
  Results: 38 passed, 0 failed
════════════════════════════════════════════════════════
```

## Related scripts

- `stoplight_mock/scripts/prism-test.sh` — same test infrastructure pattern; tests the Nutanix API mock server
- `test_script/system_validate.sh` — full system validation
- `test_script/scripts/chain-*.sh` — lifecycle chain scripts (provision, onboard, role-assign, etc.)
