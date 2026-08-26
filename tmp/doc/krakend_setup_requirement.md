# KrakenD API Gateway — Feasibility Analysis for libcloud-rest-api

## Current traffic map — who calls `libcloud-rest-api:8765`

```
                    ┌────────────────────────────────────────┐
                    │           libcloud_net (Docker)          │
                    │                                         │
  identity-service ─┤──► libcloud-rest-api:8765               │
  (provision,       │    /v1/auth/me                          │
   deprovision,     │    /v1/connections:test                 │
   update, list)    │    /v1/compute/*                        │
                    │    /v1/compute/subnets                  │
                    │                                         │
                    │           ┌──────────────────┐          │
                    │           │ libcloud-rest-api │          │
                    │           │   (uvicorn)       │          │
                    │           │                   │          │
                    │           │ Auth layers:      │          │
                    │           │ 1. JWT validate   │──► dex   │
                    │           │ 2. Scope gate     │          │
                    │           │ 3. OpenFGA check  │──► openfga
                    │           │ 4. Driver cap     │          │
                    │           │ 5. Credential pol │──► vault │
                    │           └──────────────────┘          │
                    └────────────────────────────────────────┘

  Host-side (outside Docker):
    demo_curl_flows.sh        ──► localhost:8765
    provision_aws/nutanix.sh  ──► localhost:8765
    idp_login.py (OAuth cb)   ──► localhost:8765/oauth/callback
    test scripts, validation  ──► localhost:8765
```

---

## Two modes of operating KrakenD — a critical distinction

There are two fundamentally different ways KrakenD can sit in front of the REST API. They have completely different configs, complexity, and scripting requirements. This document analyzes both, but **the Lua/CEL discussion only applies to mode 2** (smart gateway).

### Mode 1: Transparent proxy (pass-through)

KrakenD does **zero auth processing**. It forwards every request — raw JWT, all headers, and body — to the REST API unchanged. The REST API still runs every layer of its own auth. KrakenD is just an extra network hop.

**Config needed: pure declarative JSON. No Lua. No CEL. No JWT validator.**

```json
{
  "endpoints": [
    {"endpoint": "/v1/compute/nodes", "method": "GET",  "backend": [{"host": ["http://libcloud-rest-api:8764"], "url_pattern": "/v1/compute/nodes"}]},
    {"endpoint": "/v1/compute/nodes", "method": "POST", "backend": [{"host": ["http://libcloud-rest-api:8764"], "url_pattern": "/v1/compute/nodes"}]}
    // ... ~20 more routes, all like this
  ]
}
```

That's it. Route definitions only. KrakenD acts as a dumb pipe — like nginx in reverse-proxy mode — and adds no auth value. The only benefit over direct access would be KrakenD-specific features (rate limiting at the gateway, request aggregation if you had multiple backends, etc.).

### Mode 2: Smart gateway (auth-enforcing)

KrakenD **takes over auth layers** before forwarding. It validates JWTs against Dex's JWKS, checks scopes, enforces provider allow-lists, and only forwards requests that pass. The idea is to offload auth from the REST API.

**Config needed: route definitions + JWT validator config + Lua/CEL scripts for scope gates, alias expansion, provider allow-lists, body-aware routing — plus the REST API must be modified to trust KrakenD-validated requests.**

This is where all the Lua/CEL scripting discussion in this document comes from. And this is where the hard blockers (OpenFGA, credential policy, driver capability) make it impractical.

### Quick comparison

| | Mode 1: Transparent proxy | Mode 2: Smart gateway |
|---|---|---|
| **What KrakenD does** | Forwards everything unchanged | Validates and authorizes, then forwards |
| **Config complexity** | Route definitions only (~20 endpoints) | Routes + JWT validator + Lua/CEL scripts |
| **Scripting needed?** | **No.** Pure JSON. | **Yes.** Lua/CEL for layers 1–2 of auth. |
| **REST API changes needed** | URL change only | Auth logic changes — must trust gateway headers |
| **Auth value added** | None | Takes over layers 1–2 (JWT + scopes) |
| **Layers 3–5 (OpenFGA, credential, driver)** | Still in REST API | Still in REST API — cannot be offloaded |
| **Result** | Extra hop, no auth benefit | Split-brain auth: some in Lua, some in Python |

This document analyzes mode 2 (smart gateway) in depth because that's the interesting question — can KrakenD replace auth logic? For mode 1 (transparent proxy), the answer is simply: yes, it works, but it adds a new service and ~20 routes of config for no auth benefit.

---

## Full auth chain — what the REST API does per request

From `authorized_route.py:84-122` and `policy.py:35-148`, every authorized request runs this sequence:

```
1. JWT validate → fetch JWKS from dex:5556, verify signature, expiry, issuer, audience
2. Extract claims → sub, scope, allowed_providers, access_token
3. Scope gate → check token.scope against required_scope (with READ_SCOPE_ALIASES expansion)
4. Provider allow-list → check connection.provider ∈ claims.allowed_providers
5. Credential policy → reject client-supplied backend creds (defense-in-depth)
6. OpenFGA: can_connect → fga.require(user, "can_connect", "libcloud_api:main", bearer=bearer)
7. OpenFGA: can_use → fga.require(user, "can_use", "provider:<cloud>", bearer=bearer)
8. OpenFGA: can_provision/read → fga.require/check(user, "can_provision"|"can_read", "<backend>:<tenant>", bearer=bearer)
9. Driver capability → probe live driver, verify operation is supported
```

Steps 6–8 each make an HTTP call to OpenFGA (`openfga:8080`), passing the **original caller's bearer token** so OpenFGA can independently validate it against Dex's JWKS.

---

## What KrakenD CE *can* do (with scripting)

KrakenD CE has a native JWT validator, plus CEL (Common Expression Language), Lua scripting, and martian DSL for custom logic. It can:

### Layer 1 — JWT validation ✅

Native support. KrakenD can fetch JWKS from `http://dex:5556/dex/keys`, validate the signature, check `iss`, `aud`, and `exp`. This is a built-in validator, not a script.

```json
{
  "extra_config": {
    "auth/validator": {
      "alg": "RS256",
      "jwk_url": "http://dex:5556/dex/keys",
      "issuer": "http://login.quest4science.xyz:5556/dex",
      "audience": ["libcloud-rest"]
    }
  }
}
```

### Layer 2 — Simple scope checking ⚠️ Possible

CEL or Lua can inspect the decoded JWT claims and check if `scope` contains a required value:

```lua
-- Lua example: check if token has required scope
local scopes = token_claims.scope:split(" ")
local required = "compute:node:create"
for _, s in ipairs(scopes) do
  if s == required then return true end
end
```

### Layer 2 — Provider allow-listing ⚠️ Possible

CEL/Lua can check if `claims.allowed_providers` includes the provider from `X-Provider-Connection`:

```lua
-- Lua example: check allowed_providers
local allowed = token_claims.allowed_providers
if allowed[1] == "*" then return true end
local conn = json.decode(headers["X-Provider-Connection"])
for _, p in ipairs(allowed) do
  if p == conn.provider then return true end
end
```

### Layer 2 — READ_SCOPE_ALIASES expansion ⚠️ Possible but tedious

The Python code has a scopes alias map (`policy.py:11-19`):

```python
READ_SCOPE_ALIASES = {
    "compute:read": {"compute:read", "compute:image:read", "compute:size:read",
                     "compute:location:read", "compute:network:read"},
}
```

This could be replicated as a Lua table lookup. Tedious but mechanical — no external dependency.

---

## What KrakenD CE *cannot* practically replicate

### Layer 5 — Credential policy enforcement ❌

`policy.py:145` calls `enforce_credential_policy(connection)` — Python code that inspects the provider connection object and rejects requests where the client supplies their own backend credentials. This is defense-in-depth: the API always uses Vault-backed identities, never client-supplied keys.

This logic depends on Python objects and is tightly coupled to the Vault integration. KrakenD has no Vault client, no concept of a "credential policy," and no way to run this check.

### Layers 6–8 — OpenFGA tuple checks ❌ (the hard blocker)

From `policy.py:73-96`, the auth flow makes **3 sequential HTTP calls** to OpenFGA per request:

```python
def _enforce_openfga(self, claims, connection, required_scope):
    fga = get_fga_client()
    user = self._fga_user(claims)
    bearer = claims.access_token

    fga.require(user, "can_connect", "libcloud_api:main", bearer=bearer)
    fga.require(user, "can_use", f"provider:{connection.provider}", bearer=bearer)

    backend = self._backend_object(connection)  # e.g., "aws_backend:tenant-abc"
    if required_scope in WRITE_SCOPES:
        fga.require(user, "can_provision", backend, bearer=bearer)
    else:
        if not fga.check(user, "can_read", backend, bearer=bearer):
            fga.require(user, "can_provision", backend, bearer=bearer)
```

This is **not** a simple HTTP call you can model as a KrakenD backend. The FGA client:

1. **Resolves the user identity** — takes `claims.sub`, applies legacy username aliases from a JSON file (`_load_map()`), and formats it as `user:<principal>`
2. **Derives the backend object** — looks up the provider's object type from `PROVIDER_OBJECT_TYPES` registry, extracts `connection.auth_binding` (tenant ID), and constructs e.g., `aws_backend:tenant-abc`
3. **Passes the original caller's bearer token** to OpenFGA so OpenFGA independently validates it against Dex's JWKS — this is the same token, forwarded
4. **Has conditional logic** — try `can_read` first; if denied, fall back to requiring `can_provision`. Write scopes skip the read check entirely
5. **Needs connection state** from `X-Provider-Connection` to build the backend object string

Could KrakenD make HTTP calls to OpenFGA from Lua? **Technically yes** — but you would be reimplementing the entire FGA client (user resolution, backend derivation, conditional check/require flow, bearer forwarding) in Lua inside a JSON config file. The result would be:

- **More complex than the original Python** — FGA logic that is 20 lines of readable Python becomes 100+ lines of unreadable Lua
- **Untestable** — there is no unit test framework for KrakenD Lua scripts. The Python FGA client has real tests
- **Brittle** — any change to the FGA model (new relation, new object type) requires editing both the Python and the KrakenD Lua in lockstep
- **No practical benefit** — you've moved complexity from one place to a worse place, and the REST API still needs its own FGA client for internal checks anyway

### Layer 9 — Driver capability probing ❌

`policy.py:150-170` calls `check_driver_capability(connection, capability)` — this **instantiates a live libcloud cloud driver** and probes its capabilities:

```python
def check_driver_capability(self, connection, operation):
    driver = build_driver(connection)     # instantiate a real cloud driver (AWS, Nutanix...)
    caps = probe_capabilities(driver)     # probe what it supports
    mapping = {
        "create_node": bool(caps.create_node_auth) or hasattr(driver, "create_node"),
        "destroy_node": hasattr(driver, "destroy_node"),
        # ...
    }
    if operation in mapping and not mapping[operation]:
        raise APIError(...)
```

KrakenD cannot import Python libraries, instantiate Apache Libcloud drivers, or probe cloud APIs. This MUST stay in the REST API.

---

## The PATCH route: body-aware scope selection

The PATCH `/v1/compute/nodes/{id}` route (`authorized_route.py:100-110`) reads the **request body** to choose which scope to require:

```python
if "authz_scope_by_body_field" in entry:
    body_bytes = await request.body()
    body_json = json.loads(body_bytes)
    field_val = body_json.get(spec["field"])   # e.g., "action"

    # policy table maps: "update" → "compute:node:update"
    #                    "resize" → "compute:node:power"
    #                    "tag"    → "compute:node:power"
    authz_scope = spec["map"].get(field_val, ...)
```

KrakenD would need to:
1. Buffer the request body (consuming it before the backend sees it — potential streaming issues)
2. Parse JSON
3. Look up a conditional mapping
4. Select the appropriate scope

This is fragile even in Python; in a KrakenD CEL/Lua config with no testing framework, it would be a maintenance nightmare. And if the mapping changes (e.g., new action type added), both `policies.json` and the KrakenD config must be updated in sync.

---

## Summary: per-layer feasibility

| # | Auth layer | KrakenD can do it? | How? | Worth it? |
|---|---|---|---|---|
| 1 | JWT validation | ✅ Yes | Native `auth/validator`, fetches JWKS from Dex | Yes — if you also solve layers 2–9 |
| 2 | Scope gate (simple) | ⚠️ Possible | CEL or Lua script parsing `claims.scope` | Tedious but doable |
| 2 | READ_SCOPE_ALIASES expansion | ⚠️ Possible | Lua table lookup | Tedious but doable |
| 2 | Provider allow-list | ⚠️ Possible | CEL/Lua checking `claims.allowed_providers` | Tedious but doable |
| 2 | Body-aware scope (PATCH) | ⚠️ Fragile | Body buffering + JSON parse + map lookup | Maintenance nightmare |
| 5 | Credential policy | ❌ No | Requires Python objects + Vault integration | — |
| 6–8 | OpenFGA tuple checks (3 calls) | ❌ No | Requires user resolution, backend derivation, conditional logic, bearer forwarding, FGA HTTP calls | Reimplementing the FGA client in Lua would be more complex, untestable, and brittle |
| 9 | Driver capability probing | ❌ No | Instantiates live libcloud cloud drivers | — |

---

## The fundamental problem: split-brain auth

Even if you invested the effort to replicate layers 1–2 in KrakenD (JWT + scope + provider allow-list via Lua/CEL), you'd end up with **auth logic split across two places**:

```
                    KrakenD (Lua/CEL)                    REST API (Python)
                    ─────────────────                    ─────────────────
                    JWT validation                       Credential policy
                    Scope gate + aliases                 OpenFGA can_connect
                    Provider allow-list                  OpenFGA can_use
                    (body-aware scope?)                  OpenFGA can_provision/read
                                                         Driver capability
```

This is **strictly worse** than keeping it all in one place:

| Concern | All in REST API (current) | Split across KrakenD + REST API |
|---|---|---|
| Single source of truth | ✅ `policies.json` + `policy.py` | ❌ `krakend.json` (Lua) + `policies.json` + `policy.py` |
| Testability | ✅ Python unit tests | ❌ Lua has no test framework; Python tests don't cover gateway logic |
| Debugging | ✅ Single stack trace | ❌ KrakenD rejects → opaque Lua error; REST API rejects → Python traceback. Two places to look |
| Adding a route | ✅ One file (`policies.json`) | ❌ Two files (`policies.json` + `krakend.json`) |
| Changing an FGA relation | ✅ One file (Python) | ❌ Two files (Lua + Python) |
| Security reasoning | ✅ One mental model | ❌ "Did KrakenD reject this or did the REST API? Which layer failed?" |

---

---

# Setup guides

Three approaches are detailed below: KrakenD Mode 1 (transparent proxy), KrakenD Mode 2 (smart gateway), and alternative solutions. All are **planning documents only — no implementation.**

---

## Approach A: KrakenD Mode 1 — Transparent proxy

KrakenD operates as a dumb pipe. It forwards every request (raw JWT, headers, body) unchanged to the REST API. No auth processing. No Lua/CEL scripting. Pure declarative JSON.

### A.1 High-level overview

```
Before:   caller ──────────► libcloud-rest-api:8765

After:    caller ──► krakend:8765 ──► libcloud-rest-api:8764 (internal, not published)
```

### A.2 Files to create

| File | Purpose |
|---|---|
| `krakend/docker-compose.yml` | KrakenD service definition, joins `libcloud_net` |
| `krakend/krakend.json` | Route table — maps every public path to the REST API backend |
| `krakend/.env` | Config values (REST API host, ports) |

### A.3 Step-by-step requirements

**Step 1 — Create the KrakenD project directory**

```
krakend/
  docker-compose.yml
  krakend.json
  .env
```

**Step 2 — `krakend/docker-compose.yml`**

- Define a single `krakend` service using `devopsfaith/krakend:latest` (or a pinned version tag)
- Join the existing external `libcloud_net` network
- Publish port `8765:8080` (KrakenD listens on 8080 internally; host sees 8765)
- Mount `./krakend.json:/etc/krakend/krakend.json:ro`
- Optionally add a healthcheck: `wget -q -O /dev/null http://127.0.0.1:8080/__health`
- Restart policy: `unless-stopped`

**Step 3 — `krakend/krakend.json`**

- Set `version` to `3` (KrakenD CE current config version)
- Define one `endpoint` per route in `libcloud.rest/app/auth/policies.json`, plus the auth and health routes that bypass the policy table
- Each endpoint maps `{method} + {path}` → `http://libcloud-rest-api:8764{path}`
- Use `"output_encoding": "no-op"` to avoid KrakenD manipulating the response body
- Routes to cover (~22 total):

| Endpoint | Methods |
|---|---|
| `/health` | GET |
| `/v1/auth/me` | POST |
| `/v1/auth/login` | POST |
| `/v1/connections:test` | POST |
| `/v1/compute/nodes` | GET, POST |
| `/v1/compute/nodes/{id}` | GET, DELETE, PATCH |
| `/v1/compute/nodes/{id}:start` | POST |
| `/v1/compute/nodes/{id}:stop` | POST |
| `/v1/compute/nodes/{id}:reboot` | POST |
| `/v1/compute/locations` | GET |
| `/v1/compute/images` | GET |
| `/v1/compute/sizes` | GET |
| `/v1/compute/subnets` | GET |
| `/v1/compute/volumes` | GET |
| `/v1/compute/keypairs` | GET |
| `/v1/jobs/{id}` | GET |
| `/v1/network/*` | GET |
| `/v1/storage/*` | GET |
| `/v1/admin/*` | * |
| `/v1/providers/*` | GET |

**Step 4 — `krakend/.env`**

- `KRAKEND_PORT=8765`
- No other env vars needed (no auth keys, no secrets)

**Step 5 — Modify `libcloud.rest/docker-compose.yml`**

- Change the `api` service:
  - Remove or change the published port from `8765:8765` to `8764:8765` (or remove the `ports:` block entirely so it is only reachable from `libcloud_net`)
  - Keep the container listening on 8765 internally; only the published port changes
- No changes to the FastAPI code itself

**Step 6 — Update all callers to point at KrakenD**

| Caller | File | Old value | New value |
|---|---|---|---|
| identity-service (docker) | `identity_service/docker-compose.yml` L49 | `http://libcloud-rest-api:8765` | `http://krakend:8765` |
| identity-service (docker) | `identity_service/app/config.py` L101 | `http://libcloud-rest-api:8765` | `http://krakend:8765` |
| identity-service (.env) | `identity_service/.env.example` L35 | `http://libcloud-rest-api:8765` | `http://krakend:8765` |
| Host scripts | `test_script/scripts/common.sh` L38 | `http://localhost:8765` | `http://localhost:8765` (unchanged — KrakenD publishes on 8765) |
| Host scripts | `demo_curl_flows.sh` L22 | `http://localhost:8765` | Unchanged |
| Host scripts | All other `localhost:8765` references | `http://localhost:8765` | Unchanged (same port) |

Key observation: **host-side callers don't change** because KrakenD takes over port 8765. Only Docker-internal callers change (from `libcloud-rest-api` container name to `krakend` container name).

**Step 7 — Resolve the OAuth callback collision**

`idp_login.py` binds a local HTTP server on the port from `LIBCLOUD_OIDC_REDIRECT_URI` to receive Dex's OAuth redirect. Currently this can be `localhost:8765`. If KrakenD owns port 8765 on the host, the callback hits KrakenD — which doesn't know what to do with it.

Options:
1. **Use a different port for OAuth callback** — set `LIBCLOUD_OIDC_REDIRECT_URI` to `http://localhost:8767/oauth/callback` (or any free port), and add the new redirect URI to Dex's `config.yaml` for the `libcloud-rest` client. `idp_login.py` binds to 8767; KrakenD never sees this traffic.
2. **Route the callback through the identity-service** — the identity-service already handles OAuth callbacks on port 8766 (`/oauth/callback`). If `idp_login.py`'s flow can be consolidated there, port 8765 is then dedicated to the REST API gateway only.

**Step 8 — Start order**

```
docker compose -f openfga_postgres/docker-compose.yml up -d    # postgres + openfga
docker compose -f dex/docker-compose.yml up -d                  # dex
docker compose -f vault/docker-compose.yml up -d                # vault
docker compose -f lldap/docker-compose.yml up -d                # lldap
docker compose -f libcloud.rest/docker-compose.yml up -d        # REST API (now on :8764)
docker compose -f krakend/docker-compose.yml up -d              # KrakenD (:8765)
docker compose -f identity_service/docker-compose.yml up -d     # identity-service
docker compose -f server/docker-compose.yml up -d               # portal
```

**Step 9 — Validation checklist**

- [ ] `curl http://localhost:8765/health` returns `{"status":"ok"}`
- [ ] `curl -H "Authorization: Bearer <token>" http://localhost:8765/v1/auth/me` works
- [ ] Provision flow works end-to-end (portal → identity-service → KrakenD → REST API)
- [ ] Deprovision flow works
- [ ] All host-side scripts (`provision_aws.sh`, `deprovision_aws.sh`, etc.) work
- [ ] `idp_login.py` OAuth callback flow works (may need port resolution from Step 7)
- [ ] KrakenD `/__health` endpoint returns 200
- [ ] KrakenD logs show no dropped headers or truncated bodies

### A.4 Ongoing maintenance burden

| Trigger | Action needed |
|---|---|
| New route added to `policies.json` | Add corresponding endpoint to `krakend.json` |
| Route removed from `policies.json` | Remove from `krakend.json` |
| Route path/method changed | Update both `policies.json` and `krakend.json` |
| New query parameter expected | Add to `krakend.json` endpoint config (`input_query_strings`) |
| REST API internal port changes | Update `krakend.json` backend host |

### A.5 What you get vs what you pay

| Get | Pay |
|---|---|
| Rate limiting at the gateway (KrakenD native) | New service to monitor, update, and debug |
| Future multi-backend aggregation (if more services are added) | ~22-route config to sync with `policies.json` forever |
| Request/response transformation (if ever needed) | Extra ~0.2ms latency per request |
| Unified entry point for all REST API traffic | One more thing that can go down and take the API with it |

---

## Approach B: KrakenD Mode 2 — Smart gateway (auth-enforcing)

KrakenD takes over JWT validation, scope gates, and provider allow-listing. The REST API must be modified to trust KrakenD-validated requests. OpenFGA, credential policy, and driver capability checks remain in the REST API.

### B.1 High-level overview

```
Before (auth all in REST API):
  caller ──► REST API: JWT validate → scope gate → provider allow-list
             → credential policy → FGA can_connect → FGA can_use
             → FGA can_provision/read → driver capability → handler

After (auth split):
  caller ──► KrakenD: JWT validate → scope gate → provider allow-list
             → forward with X-Auth-Claims header
             ──► REST API: [skip JWT validate] → credential policy
                  → FGA can_connect → FGA can_use → FGA can_provision/read
                  → driver capability → handler
```

### B.2 Files to create

| File | Purpose |
|---|---|
| `krakend/docker-compose.yml` | KrakenD service definition (same as Mode 1) |
| `krakend/krakend.json` | Route table + JWT validator + Lua/CEL auth scripts |
| `krakend/lua/scope_check.lua` | Lua script for scope gate + aliases |
| `krakend/lua/provider_allowlist.lua` | Lua script for provider allow-list check |
| `krakend/.env` | Config values |

### B.3 Files to modify

| File | Change |
|---|---|
| `libcloud.rest/app/auth/dependencies.py` | Add a "trusted gateway" path that reads claims from `X-Auth-Claims` header instead of validating JWT |
| `libcloud.rest/app/config/settings.py` | Add `trusted_gateway` config flag |
| `libcloud.rest/docker-compose.yml` | Remove published port (REST API only reachable via KrakenD on `libcloud_net`) |

### B.4 Step-by-step requirements

**Step 1 — Same as Mode 1 steps 1–2, 4** (project directory, docker-compose.yml, .env)

**Step 2 — `krakend/krakend.json` with JWT validator**

The config now includes:
- A JWT validator that fetches JWKS from `http://dex:5556/dex/keys`
- Validates `iss`, `aud`, `exp`, `alg` (RS256)
- Extracts claims into `request.context.jwt_claims`
- Lua scripts in the `extra_config` of each endpoint that run before the backend call

```json
{
  "version": 3,
  "extra_config": {
    "auth/validator": {
      "alg": "RS256",
      "jwk_url": "http://dex:5556/dex/keys",
      "issuer": "http://login.quest4science.xyz:5556/dex",
      "audience": ["libcloud-rest"],
      "cache": true,
      "cache_duration": 300,
      "operation_debug": false,
      "propagate_claims": [
        ["sub", "x-auth-sub"],
        ["scope", "x-auth-scope"],
        ["allowed_providers", "x-auth-allowed-providers"]
      ]
    }
  },
  "endpoints": [
    {
      "endpoint": "/v1/compute/nodes",
      "method": "GET",
      "extra_config": {
        "modifier/lua-proxy": {
          "pre": "lua/scope_check.lua",
          "live_reload": false
        }
      },
      "backend": [{
        "host": ["http://libcloud-rest-api:8764"],
        "url_pattern": "/v1/compute/nodes"
      }]
    }
  ]
}
```

**Step 3 — `krakend/lua/scope_check.lua`**

This Lua script, attached to each endpoint, must:
1. Read `request.context.jwt_claims` (set by the JWT validator)
2. Parse the `scope` claim (space-delimited string)
3. Expand `compute:read` into its sub-scopes (`compute:image:read`, `compute:size:read`, etc.) using a hardcoded alias table
4. Check if the expanded set contains the required scope for this route
5. If the token has `allowed_providers`, check the `X-Provider-Connection` header's `provider` field against the allowed list (unless `*` is present)
6. If either check fails, return a 403 with a JSON error body (matching the REST API's error format so callers see consistent errors)
7. Otherwise, let the request through

The alias table must mirror `policy.py:11-19` (READ_SCOPE_ALIASES) and must be kept in sync manually:

```lua
-- Must stay in sync with policy.py:READ_SCOPE_ALIASES
local scope_aliases = {
  ["compute:read"] = {
    "compute:read", "compute:image:read", "compute:size:read",
    "compute:location:read", "compute:network:read"
  }
}
```

**Step 4 — `krakend/lua/provider_allowlist.lua`**

For endpoints that are provider-specific, this Lua script:
1. Parses the `X-Provider-Connection` header (JSON)
2. Extracts the provider name
3. Checks it against the `allowed_providers` claim from the JWT
4. Returns 403 if the provider is not allowed

**Step 5 — Modify the REST API to accept trusted gateway headers**

In `libcloud.rest/app/auth/dependencies.py`, add a new function:

```python
def claims_from_trusted_gateway(request: Request) -> TokenClaims:
    """When behind KrakenD, claims are forwarded as headers.

    The gateway validates the JWT and propagates selected claims.
    This path SKIPS JWT signature verification — it trusts the gateway.
    The REST API must NOT be reachable from outside libcloud_net.
    """
    sub = request.headers.get("X-Auth-Sub")
    scope = request.headers.get("X-Auth-Scope", "")
    allowed_raw = request.headers.get("X-Auth-Allowed-Providers", "[]")
    # ... parse and return TokenClaims
```

Then modify `claims_from_request()` to check a config flag:

```python
def claims_from_request(request: Request) -> TokenClaims:
    settings = get_settings()
    if settings.trusted_gateway:
        return claims_from_trusted_gateway(request)
    return _decode_token(_bearer_token_from_request(request))
```

The REST API must also enforce that it **only accepts requests from KrakenD** when in trusted-gateway mode — check the source IP or require a shared secret header — otherwise anyone on `libcloud_net` can forge `X-Auth-*` headers.

**Step 6 — Add `trusted_gateway` config flag**

In `libcloud.rest/app/config/settings.py`:
- `trusted_gateway: bool = False` (default off — backward compatible)
- `trusted_gateway_secret: str = ""` (shared secret KrakenD sends to prove it validated the token)

KrakenD would inject the shared secret as a custom header (e.g., `X-Gateway-Secret`) that the REST API verifies before trusting the claims headers.

**Step 7 — Modify `libcloud.rest/docker-compose.yml`**

- Remove the `ports:` block entirely (or bind to `127.0.0.1:8764` for local debugging only)
- Add `TRUSTED_GATEWAY=true` and `TRUSTED_GATEWAY_SECRET=<generated-secret>` to the `environment:` block
- The REST API is now only reachable from `libcloud_net` — no external access

**Step 8 — Same caller updates as Mode 1 steps 6–8**

**Step 9 — Move the PATCH body-aware routing into the REST API (cannot be in KrakenD)**

The `authz_scope_by_body_field` logic for `PATCH /v1/compute/nodes/{id}` cannot be cleanly replicated in KrakenD Lua. Options:
1. **Leave it in the REST API** — KrakenD does a broad scope check on `compute:node:power` or `compute:node:update` (allow either), and the REST API does the fine-grained body-aware check. This means the PATCH route still does scope validation in Python, breaking the "all scope checks in KrakenD" ideal.
2. **Remove body-aware scoping** — flatten PATCH into separate endpoints: `POST /v1/compute/nodes/{id}:update`, `POST /v1/compute/nodes/{id}:resize`, `POST /v1/compute/nodes/{id}:tag`. Each has a single scope. This simplifies the gateway but changes the REST API contract.

**Step 10 — Start order and validation** — same as Mode 1 steps 8–9, plus:
- [ ] KrakenD rejects unauthenticated requests with 401
- [ ] KrakenD rejects wrong-scope requests with 403
- [ ] KrakenD rejects disallowed-provider requests with 403
- [ ] KrakenD error responses match REST API error format
- [ ] REST API rejects requests without valid `X-Gateway-Secret` header
- [ ] REST API correctly reads claims from headers
- [ ] OpenFGA checks still work (REST API has the user identity from headers)
- [ ] Provision flow works end-to-end
- [ ] JWKS cache in KrakenD refreshes before Dex rotates keys (6h rotation window)

### B.5 Ongoing maintenance burden (Mode 1 burden + additional)

| Trigger | Action needed |
|---|---|
| All Mode 1 triggers | Same as Mode 1 |
| Scope added/removed | Update `krakend/lua/scope_check.lua` + `policies.json` |
| New provider type added | Update `krakend/lua/provider_allowlist.lua` |
| READ_SCOPE_ALIASES changes | Update Lua alias table + `policy.py` |
| New route with body-aware scope | Decide: add Lua logic OR leave in REST API |
| Token claims structure changes | Update KrakenD `propagate_claims` mapping + REST API header parsing |
| Gateway secret rotated | Update both KrakenD config and REST API env var |
| Dex JWKS endpoint changes | Update `jwk_url` in KrakenD config |

### B.6 What you get vs what you pay

| Get | Pay |
|---|---|
| Centralized JWT validation (one place, not two) | Split-brain auth: scope/FGA logic lives in two places |
| KrakenD rate limiting + JWT validation | Lua scripts that must mirror Python logic exactly, with no test framework |
| Consistent 401/403 at the edge | Hard gateway→backend trust dependency (shared secret, firewall rules) |
| REST API can skip JWT crypto (faster?) | PATCH body-aware routing is still in Python — auth is not fully centralized |
| Future: add more backends, KrakenD handles auth for all | Every auth change touches 2–3 files in 2 languages |

---

## Approach C: FastAPI middleware (no external gateway)

Add rate limiting, request logging, and metrics directly to the REST API via FastAPI middleware. No new service, no new config format, no route duplication.

### C.1 High-level overview

```
Before:  caller ──► uvicorn ──► auth ──► handler ──► response

After:   caller ──► uvicorn ──► rate-limit ──► request-log ──► auth ──► handler ──► response
                     (same container, same process)
```

### C.2 Files to create or modify

| File | Action | Purpose |
|---|---|---|
| `libcloud.rest/app/common/rate_limit.py` | Create | Rate-limiting middleware |
| `libcloud.rest/app/common/request_log.py` | Create | Structured request logging middleware |
| `libcloud.rest/app/main.py` | Modify (3 lines) | Register new middleware in `create_app()` |
| `libcloud.rest/requirements.txt` | Modify (1 line) | Add `slowapi` or `limits` dependency |

### C.3 Step-by-step requirements

**Step 1 — Rate limiting middleware**

Using `slowapi` (FastAPI-compatible, Redis or in-memory backend):

```python
# libcloud.rest/app/common/rate_limit.py
from slowapi import Limiter
from slowapi.util import get_remote_address
from fastapi import Request
from app.common.errors import APIError

limiter = Limiter(key_func=get_remote_address)

async def rate_limit_middleware(request: Request, call_next):
    # Apply before the auth checks — 429 if rate limit exceeded
    # Can use different limits per route or per token
    ...
```

- Define limits per route or globally (e.g., 100 req/min per IP for `/v1/compute/*`)
- In-memory storage works for single-container deployments; Redis-backed for multi-replica
- No Docker topology change, no new service

**Step 2 — Request logging middleware**

```python
# libcloud.rest/app/common/request_log.py
import time, logging
from fastapi import Request

logger = logging.getLogger("access")

async def request_log_middleware(request: Request, call_next):
    start = time.monotonic()
    response = await call_next(request)
    elapsed_ms = (time.monotonic() - start) * 1000
    logger.info(
        "method=%s path=%s status=%s duration_ms=%.1f client=%s",
        request.method, request.url.path, response.status_code,
        elapsed_ms, request.client.host if request.client else "-"
    )
    return response
```

- Logs every request with method, path, status, duration, client IP
- Already exists in part via `RequestIDMiddleware` — extend it
- Can output JSON-structured logs for ingestion into Loki/ELK

**Step 3 — Register in `main.py`**

```python
# libcloud.rest/app/main.py — add 3 lines
from app.common.rate_limit import rate_limit_middleware
from app.common.request_log import request_log_middleware

def create_app() -> FastAPI:
    ...
    app.add_middleware(RequestIDMiddleware)
    app.add_middleware(BaseHTTPMiddleware, dispatch=rate_limit_middleware)   # NEW
    app.add_middleware(BaseHTTPMiddleware, dispatch=request_log_middleware)  # NEW
    ...
```

**Step 4 — Metrics endpoint (optional)**

Add a `/metrics` endpoint that exports Prometheus-format metrics:
- `pip install prometheus-fastapi-instrumentator`
- Two lines in `main.py` to instrument the app
- Prometheus scrapes `http://libcloud-rest-api:8765/metrics`

**Step 5 — No caller changes. No config changes. No new services.**

### C.4 What you get vs what you pay

| Get | Pay |
|---|---|
| Rate limiting in ~30 lines of Python | `slowapi` dependency (~200KB) |
| Structured request logging in ~20 lines of Python | Slightly more CPU per request (negligible) |
| Prometheus metrics in 2 lines | `prometheus-fastapi-instrumentator` dependency |
| No new service, no topology change, no route duplication | None of this is a gateway — no aggregation, no multi-backend routing |
| Testable with the same pytest framework as the rest of the app | |
| Auth stays in one place | |

---

## Approach D: nginx reverse proxy

A lightweight nginx container on `libcloud_net` as a transparent reverse proxy. Like KrakenD Mode 1 but with nginx — more familiar, simpler config.

### D.1 High-level overview

```
Before:   caller ──────────► libcloud-rest-api:8765

After:    caller ──► nginx:8765 ──► libcloud-rest-api:8764 (internal)
```

### D.2 Files to create

| File | Purpose |
|---|---|
| `nginx/docker-compose.yml` | nginx service, joins `libcloud_net`, publishes `8765` |
| `nginx/nginx.conf` | Reverse-proxy config — one `location /` block |
| `nginx/.env` | `NGINX_PORT=8765` |

### D.3 Step-by-step requirements

**Step 1 — `nginx/docker-compose.yml`**

```yaml
services:
  nginx:
    image: nginx:1.27-alpine
    container_name: libcloud-gateway
    restart: unless-stopped
    networks:
      - libcloud_net
    ports:
      - "8765:8765"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8765/health"]

networks:
  libcloud_net:
    external: true
```

**Step 2 — `nginx/nginx.conf`**

```nginx
events { worker_connections 1024; }

http {
    # Pass X-Provider-Connection and all other headers through
    proxy_pass_request_headers on;

    server {
        listen 8765;

        location / {
            proxy_pass http://libcloud-rest-api:8764;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # Preserve original request body
            proxy_pass_request_body on;
        }
    }
}
```

A single `location /` block covers **every route** — no per-route config needed. When a new route is added to `policies.json`, nginx needs zero changes. This eliminates the KrakenD route-sync maintenance burden entirely.

**Step 3 — Same REST API port change + caller updates as KrakenD Mode 1 steps 5–9**

**Step 4 — Optional: rate limiting in nginx**

```nginx
limit_req_zone $binary_remote_addr zone=api_limit:10m rate=100r/m;

location / {
    limit_req zone=api_limit burst=20 nodelay;
    proxy_pass http://libcloud-rest-api:8764;
    ...
}
```

**Step 5 — Optional: JWT validation in nginx (ngx_http_auth_jwt_module)**

Nginx Plus has native JWT validation. For open-source nginx, the `nginx-jwt` module or OpenResty (nginx + LuaJIT) can validate JWTs — but this brings back the same Lua/auth split problems as KrakenD Mode 2. For transparent proxy, just use vanilla nginx.

### D.4 What you get vs what you pay

| Get | Pay |
|---|---|
| Single `location /` block — zero route maintenance | New service (one lightweight alpine container, ~3MB) |
| Rate limiting in 3 lines of nginx config | Extra ~0.1ms latency per request (nginx is very fast) |
| Battle-tested, well-understood proxy | Must update `libcloud-rest-api` published port + Docker callers |
| Logs, headers, body all pass through by default | |
| No Lua/CEL, no JWT validator, no auth split | |

---

## Approach E: Do nothing — keep current direct-access architecture

No changes. Callers talk directly to `libcloud-rest-api:8765`. Auth is entirely in the REST API.

### E.1 What stays the same

- `identity-service` → `http://libcloud-rest-api:8765` over `libcloud_net`
- Host scripts → `http://localhost:8765` via published port
- Auth: JWT → scope → FGA → credential → driver capability — all in one Python codebase
- One place to change when auth logic changes

### E.2 What you would add if specific needs arise

| If you need... | Add... |
|---|---|
| Rate limiting | `slowapi` middleware (Approach C) — ~30 lines, same container |
| Request logging | Structured logging middleware (Approach C) — ~20 lines, same container |
| Metrics | `prometheus-fastapi-instrumentator` — 2 lines, same container |
| TLS termination | nginx sidecar (Approach D) — 1 `location /` block |
| Multi-backend routing | THEN consider KrakenD/nginx — when there are actually multiple backends |

---

## Comparison matrix

| Dimension | A: KrakenD transparent | B: KrakenD smart | C: FastAPI middleware | D: nginx | E: Do nothing |
|---|---|---|---|---|---|
| **New services** | 1 (KrakenD) | 1 (KrakenD) | 0 | 1 (nginx) | 0 |
| **Docker topology change** | Yes | Yes | No | Yes | No |
| **Caller URL changes** | Docker callers only | Docker callers only | None | Docker callers only | None |
| **REST API code changes** | None | `dependencies.py` + `settings.py` + secrets | 3 lines in `main.py` | None | None |
| **Route config to maintain** | ~22 endpoints in JSON | ~22 endpoints in JSON | 0 (auto-discovered) | 0 (single `location /`) | 0 |
| **Scripting needed** | None (pure JSON) | Lua for scope + provider checks | None (pure Python) | None | None |
| **Auth split across systems** | No (pass-through) | Yes (scope in Lua, FGA in Python) | No | No (pass-through) | No |
| **Rate limiting** | KrakenD native | KrakenD native | slowapi (Python) | nginx native | Not available |
| **Request logging** | KrakenD logging | KrakenD logging | Python logging | nginx access log | Existing uvicorn log |
| **OAuth callback conflict** | Yes — needs port change | Yes — needs port change | No | Yes — needs port change | No |
| **Per-request latency add** | ~0.2ms | ~0.5ms (JWT + Lua) | ~0.05ms | ~0.1ms | 0ms |
| **Testability of config** | Manual curl only | Manual curl only (Lua has no test framework) | pytest (same as app) | `nginx -t` syntax check | N/A |
| **Best for** | "I want a gateway now, auth later" | Not recommended — see split-brain analysis | "I need rate limiting or logging" | "I want a transparent proxy with minimum config" | "Everything works, don't fix it" |

---

## Decision guide

```
Do you have multiple backend services that need unified routing?
  ├── Yes → Consider KrakenD Mode 1 or nginx (Approach D)
  │         Wait until there are ≥2 backends before adding the complexity.
  │
  └── No (current state: single REST API backend)
      │
      Do you need rate limiting?
        ├── Yes → Approach C (FastAPI middleware — 30 lines, same container)
        │         OR Approach D (nginx — 3 lines of nginx config)
        │
        └── No
            │
            Do you need structured request logging / metrics?
              ├── Yes → Approach C (FastAPI middleware — 20 lines)
              │
              └── No → Approach E (do nothing)
                       Current architecture is fine. Add middleware
                       when specific needs arise.
```

---

## Final summary

| Aspect | Verdict |
|---|---|
| Technically possible as transparent proxy | ✅ Yes — KrakenD Mode 1 or nginx (Approach D) |
| KrakenD can do JWT validation | ✅ Yes — native support |
| KrakenD can do scope gate + provider allow-list | ⚠️ Possible with Lua/CEL, but tedious |
| KrakenD can do READ_SCOPE_ALIASES expansion | ⚠️ Possible with Lua, but tedious |
| KrakenD can do body-aware scope selection (PATCH) | ⚠️ Fragile — body buffering + JSON parse in gateway |
| KrakenD can do credential policy enforcement | ❌ No — requires Python + Vault integration |
| KrakenD can do OpenFGA tuple checks | ❌ No — reimplementing the FGA client in Lua is more complex, untestable, and brittle than the Python original |
| KrakenD can do driver capability probing | ❌ No — instantiates live libcloud drivers |
| Value of KrakenD as transparent proxy | ⚠️ Minimal — single backend, no aggregation needs, no multi-service routing |
| Added complexity of KrakenD | 🔴 New service, ~22-route config to maintain, dual auth or hard firewall requirement, breaks OAuth callback flow |
| Result if you try to offload auth to KrakenD | 🔴 Split-brain auth: JWT/scope in Lua, FGA/credential/capability in Python. Strictly worse than keeping it all in one place. |
| Best alternative for rate limiting/logging/metrics | ✅ Approach C — FastAPI middleware: 20–30 lines of Python, same container, same test framework |
| Best alternative for transparent proxy (if gateway is mandatory) | ✅ Approach D — nginx: one `location /` block, zero route maintenance, no Lua/CEL |
| Best approach for the current architecture | ✅ Approach E — do nothing. Add middleware incrementally as specific needs arise. |

**Bottom line**: KrakenD CE is the wrong tool for this job *right now*. The REST API is a single FastAPI backend with deeply embedded auth that can't be externalized without creating a worse split-brain architecture. If you need rate limiting, request logging, or metrics, add those as FastAPI middleware (Approach C) — it is a fraction of the complexity of introducing a gateway. If a transparent proxy is mandatory for operational reasons, use nginx (Approach D) — it covers every route with one `location /` block and needs no per-route maintenance. KrakenD becomes useful if/when you split into **multiple backend services** that need unified routing, or when you need its specific strengths (request aggregation across microservices, multi-protocol translation).
