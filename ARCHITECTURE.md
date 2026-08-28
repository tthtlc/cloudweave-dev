# System Architecture — libcloud_nutanix

**Scope.** How the whole stack fits together: what each container is, how an HTTP
request travels from a browser to a cloud provider, and — the main emphasis —
where authentication and authorization are actually enforced, and where they are
not.

**Authority.** Every claim below was verified against source. Where the
per-subsystem `ARCHITECTURE.md` files disagreed with the code, the code won and
those files were corrected; §10 lists what changed. Line references are of the
form `path:line` and point at the current tree.

**Related documents.** `identity_service/ARCHITECTURE.md`, `dex/ARCHITECTURE.md`,
`lldap/ARCHITECTURE.md`, `vault/ARCHITECTURE.md`,
`openfga_visualized/ARCHITECTURE.md`, `libcloud.rest/ARCHITECTURE.md`,
`stoplight_mock/ARCHITECTURE.md`, `libcloud/ARCHITECTURE.md`. This document is
the entry point; those go deeper on one component each. Start with
`identity_service/` — it owns sessions and the primary authorization enforcement
point.

---

## 1. What the system does

It is a **multi-tenant self-service cloud provisioning portal**. A user signs in
through a browser, and — subject to a relationship-based authorization model —
provisions, edits, lists, or destroys virtual machines on one of two backend
clouds (**AWS** and **Nutanix Prism Central**). The user never holds cloud
credentials; the platform holds them in Vault and acts on the user's behalf.

Five concerns are deliberately split across five separate services:

| Concern | Component | Answers the question |
|---|---|---|
| **Identity** (who you are) | LLDAP + Dex | Which human is this? |
| **Session** (staying signed in) | identity-service | Is this browser still that human? |
| **Authorization** (what you may do) | OpenFGA | May this human do this to that? |
| **Secrets** (how we reach the cloud) | Vault | What credential provisions this tenant? |
| **Cloud abstraction** (doing it) | libcloud.rest + Apache libcloud | Talk to AWS / Nutanix |

The separation is the point: no component both decides permission *and* holds
the credential.

### Tenancy model

Two tenants ship seeded: `aws` and `nutanix`. Each has three roles — **owner**,
**admin**, **viewer** — plus a platform-wide **superadmin**. Eight LLDAP users
are created by `setup.sh:441-448`: `superadmin`, `aws-owner`, `aws-admin`,
`aws-viewer`, `ntnx-owner`, `ntnx-admin`, `ntnx-viewer`, and `cloud-denied` (an
authenticated-but-unauthorized user that exists to prove denial works).

Role capabilities, from the OpenFGA model (§5):

| | viewer | admin | owner | superadmin |
|---|---|---|---|---|
| Read resources (`can_read`) | ✅ | ✅ | ✅ | ✅ (via `global_reader`) |
| Provision / destroy (`can_provision`) | ❌ | ✅ | ✅ | ❌ |
| Edit VM (`can_update`) | ❌ | ✅ | ✅ | ❌ |
| Manage tenant credentials (`can_manage_credentials`) | ❌ | ❌ | ✅ | ❌ |
| Assign admin/viewer roles | ❌ | ❌ | ✅ | ❌ |
| Assign tenant **owner** | ❌ | ❌ | ❌ | ✅ |

Note the deliberate asymmetry: **superadmin can read everything and grant
anything, but cannot itself provision.** It is a control-plane role, not a
data-plane one (`openfga_postgres/openfga_bootstrap.py:855-861`).

---

## 2. Deployment topology

Everything runs as Docker containers on **one shared external bridge network,
`libcloud_net`** (`docker network inspect` → `internal=false`, `driver=bridge`).
Containers address each other by service DNS name.

| Service | Container | In-network address | Host binding |
|---|---|---|---|
| Role portal (React SPA + nginx) | `portal` | `portal:3000` | **`0.0.0.0:3000`** |
| Identity service (FastAPI) | `identity-service` | `identity-service:8766` | `127.0.0.1:8766` |
| libcloud REST API (FastAPI) | `libcloud-rest-api` | `api:8765` | `127.0.0.1:8765` |
| Dex (OIDC issuer) | `dex` | `dex:5556` | `127.0.0.1:5556` |
| LLDAP (directory) | `lldap` | `lldap:3890` (LDAP), `:17170` (web) | `127.0.0.1` both |
| OpenFGA | `openfga` | `openfga:8080` (HTTP), `:8081` (gRPC), `:2112` (metrics) | `127.0.0.1` all |
| PostgreSQL (OpenFGA store) | `openfga-postgres` | `postgres:5432` | `127.0.0.1:5433` |
| Vault | `vault` | `vault:8200` | `127.0.0.1:8200` |
| OpenFGA visualizer (Flask) | `openfga-visualizer` | `:5050` | **`0.0.0.0:5050`** |
| Nutanix emulator ×4 | `emulator[-41..43]` | `:9440` | **`0.0.0.0:9440-9443`** |
| Stoplight Prism ×4 | `prism[-41..43]` | `:4010` | `127.0.0.1:4010-4013` |

### The portal is the single front door

The portal's nginx is not just a static file server — it is the **reverse proxy
that makes everything else loopback-only**. From `server/Dockerfile:30-57`:

```nginx
location /api/  { proxy_pass http://identity-service:8766; }  # portal API
location /dex/  { proxy_pass http://dex:5556; }               # OIDC endpoints
location /      { try_files $uri /index.html; }               # SPA fallback
```

So the browser only ever talks to **port 3000**. It never contacts Dex (5556),
the identity service (8766), or the REST API (8765) directly. That is why every
other service binds to `127.0.0.1` — they are reachable only from within
`libcloud_net` or from the host itself.

**Three services break that rule** and listen on all interfaces: the portal
(intended), the **OpenFGA visualizer on 5050**, and the **Nutanix emulators on
9440-9443**. See §9 findings 8 and 9.

### Bootstrap and lifecycle scripts

| Script | Purpose |
|---|---|
| `setup.sh` | Build-free bootstrap; recreates containers from pre-built images. Works air-gapped. The canonical start path. |
| `rebuild_all.sh` | Online counterpart — rebuilds every image with a `build:` directive, then runs `setup.sh`. |
| `docker_teardown.sh` | Host-wide destructive teardown. **Removes named volumes** — Vault unseal key, OpenFGA tuples, and LLDAP users are permanently lost. |
| `migrate2internal/backup-system.sh` / `restore-system.sh` | Ships images + volumes + project files to an air-gapped host. |
| `test_script/system_validate.sh`, `test_script/scripts/*` | ~90 operator and verification scripts. |

---

## 3. The bootstrap chain of trust

`setup.sh` establishes trust in a strict order — each step is gated on the
previous one. This is the system's root-of-trust story.

```
 1. Render dex/config.yaml from config.template.yaml   (dex_bootstrap.py)
 2. Start LLDAP, apply custom schema, create `superadmin`
 3. Start Postgres → OpenFGA → Dex → Vault
 4. ── GATE ── Log in to Dex as superadmin → SUPERADMIN_JWT
 5. Create the 7 per-tenant LLDAP users        (gated on step 4)
 6. OpenFGA bootstrap: store + model + 48 tuples  (gated on step 4)
 7. Vault bootstrap: init, unseal, enable KV v2   (gated on step 4)
 7a. Seed per-tenant cloud credentials into Vault (tenant owner logs in)
 8. Restart REST API + visualizer to pick up fresh OpenFGA state
 9. Recreate the portal container
10. Host-side Python venv for libcloud.rest (best-effort)
```

Step 4 (`setup.sh:426-434` → `test_script/scripts/superadmin_auth.sh`) is the
pivot. It performs a **real OIDC login** as `superadmin` against Dex, verifies
the resulting JWT, and exports `SUPERADMIN_JWT`. Everything privileged
downstream — writing the authorization model, seeding secrets, creating users —
refuses to run without it. Bootstrap is therefore not a backdoor: it uses the
same identity path a human would.

The JWT is verified by running `verify_superadmin_jwt.py` **inside the
identity-service container** (`superadmin_auth.sh:74-79`), so the host needs no
Python crypto dependency.

---

## 4. Authentication

### 4.1 The directory: LLDAP

LLDAP is the sole user store. Base DN `dc=libcloud,dc=local`, users under
`ou=people`, groups under `ou=groups`. Admin bind DN is
`uid=admin,ou=people,dc=libcloud,dc=local`.

Three custom attributes are applied at bootstrap via LLDAP's GraphQL API
(`lldap/scripts/setup-schema.sh:56-58`): `department` (single-valued), **`role`
(multi-valued, `isList: true`)**, and `jobtitle` (single-valued).

Management is split by protocol: reads use LDAP (`ldap3`), writes use the
GraphQL API at `POST /api/graphql` after `POST /auth/simple/login`
(`identity_service/app/lldap.py:15-136`).

### 4.2 The issuer: Dex

Dex `v2.41.1` is the only OIDC issuer.

| Property | Value | Source |
|---|---|---|
| Issuer (`iss`) | `http://dex:5556/dex` | `dex/config.yaml:26` |
| Storage | **`memory`** — tokens die on restart | `dex/config.yaml:28-29` |
| Connector | `lldap`, LDAP to `lldap:3890`, `insecureNoSSL: true` | `dex/config.yaml:78-88` |
| Claim map | `uid → sub`, `mail → email`, `cn → name` | `dex/config.yaml:95-97` |
| Group search | **none configured** — there is no `groups` claim | `dex/config.yaml:89-97` |
| Grants | `authorization_code`, `refresh_token` only | `dex/config.yaml:41` |
| Approval screen | `skipApprovalScreen: true` | `dex/config.yaml:39` |

There is **no password grant and no client-credentials grant**. Machine
identities authenticate by scripting the authorization-code flow as a real LLDAP
user (§6.3).

The issuer is the *in-container* DNS name on purpose: OpenFGA, the identity
service, and the REST API all validate `iss` and fetch JWKS over `libcloud_net`.
Browser-facing URLs go through the portal's `/dex/` proxy instead. Host scripts
use `http://localhost:5556`. All three views must agree on the `iss` string, and
they do.

**Two static OAuth clients** are registered:

| Client | Used by | Redirect URIs | PKCE |
|---|---|---|---|
| `libcloud-portal` | Browser login via identity-service | `http://<host>:3000/auth/callback`, `http://localhost:3000/auth/callback` | **Yes**, S256 |
| `libcloud-rest` | Service accounts, CLI scripts, OpenFGA audience | 6 URIs incl. `127.0.0.1:8766/8767`, `localhost:5050` | No — client secret only |

Federated Google/GitHub connectors are rendered conditionally by
`openfga_postgres/dex_bootstrap.py:139-161` when client IDs are set, and can be
hard-disabled for air-gapped installs via `DEX_DISABLE_FEDERATION=1`.

### 4.3 Three distinct authentication contexts

This is the part most easily misread. **Three different credentials circulate,
and they are not interchangeable.**

**(a) Browser session — an identity-service cookie, not a Dex token.**
After the OIDC exchange, the identity service mints its *own* HS256 JWT and sets
it as cookie `libcloud_portal_sid` (`identity_service/app/session.py:33-77`):
`HttpOnly`, `SameSite=Lax`, `Max-Age=28800` (8 h), `Secure=False` by default.
Claims: `internalUserId, role, email, linkedIdentities, sid, iat, exp, jti`.

The **Dex refresh token never reaches the browser** — it is held server-side in
an in-memory map keyed by `sid` (`session.py:17`). That is a good design
decision, and it is undermined by the signing-key problem in §9 finding 2.

**(b) Provisioner service-account token — `aud=libcloud-rest`.**
The identity service does **not** forward the user's token downstream. For each
cloud it performs a server-side Dex LDAP login as a dedicated service account
(`aws-admin` / `ntnx-admin`) and caches the resulting token
(`identity_service/app/idp_login.py:38-148`). This token is what it presents to
both the libcloud REST API and OpenFGA.

**(c) Superadmin bootstrap JWT — `aud=libcloud-rest`.**
Obtained by `test_script/scripts/idp_login.py`, used only by `setup.sh` and
operator scripts.

The consequence of (b): **the libcloud REST API sees the provisioner, not the
end user.** The end user's authorization is decided *upstream*, in the identity
service (§5.3). The REST API re-checks, but against the service account. This is
a real trust boundary — the identity service is the component that must not be
bypassed.

---

## 5. Authorization

### 5.1 OpenFGA deployment

OpenFGA `v1.16.0`, built from a checksum-pinned release tarball
(`openfga_postgres/Dockerfile:42-45`), backed by PostgreSQL 16, playground
disabled. Store name `libcloud-rest-store`; store and model IDs are written to
`openfga_postgres/generated/fga.env` and auto-discovered at runtime by every
client if unset.

The version pin is load-bearing. `v1.16.0` is the first release containing
PR #3101, which sets `RefreshUnknownKID: true` on the JWKS cache. Without it,
Dex's 6-hourly signing-key rotation causes every `Check` to fail with
`invalid_claims` until OpenFGA is restarted (`openfga_postgres/Dockerfile:11-38`).
**Do not downgrade to 1.8.x.**

OpenFGA authenticates callers with OIDC:

```
--authn-method=oidc
--authn-oidc-issuer=http://dex:5556/dex
--authn-oidc-audience=libcloud-rest
```

### 5.2 The authorization model

8 types, schema 1.1 (`openfga_postgres/model/libcloud.fga`, identical to the
JSON posted by `openfga_bootstrap.py:217-837`):

```
type user

type platform
  relations
    define superadmin: [user]
    define can_manage_global_policy: superadmin
    define can_manage_iam_mapping: superadmin
    define can_manage_platform: superadmin
    define can_manage_tenant_lifecycle: superadmin
    define global_reader: superadmin

type tenant
  relations
    define owner: [user]
    define admin: [user]
    define viewer: [user]
    define platform: [platform]
    define member: [user] or owner or admin or viewer
    define can_read: viewer or admin or owner or global_reader from platform
    define can_provision: admin or owner
    define can_update: admin or owner
    define can_manage_credentials: owner
    define can_assign_admin: owner
    define can_assign_viewer: owner
    define can_assign_owner: can_manage_platform from platform

type libcloud_api
  relations
    define parent: [tenant]
    define platform: [platform]
    define can_connect: [user] or member from parent or global_reader from platform

type provider
  relations
    define parent: [tenant]
    define platform: [platform]
    define can_use: [user] or member from parent or global_reader from platform

type resource_class
  relations
    define tenant: [tenant]
    define platform: [platform]
    define admin: [user]
    define viewer: [user]
    define tenant_owner:  owner  from tenant
    define tenant_admin:  admin  from tenant
    define tenant_viewer: viewer from tenant
    define can_read: viewer or tenant_viewer or admin or tenant_admin
                     or tenant_owner or global_reader from platform
    define can_provision: admin or tenant_admin or tenant_owner
    define can_update:    admin or tenant_admin or tenant_owner

type aws_region        # nutanix_cluster is structurally identical
  relations
    define tenant: [tenant]
    define provider: [provider]
    define resource_class: [resource_class]
    define platform: [platform]
    define tenant_owner:  owner  from tenant
    define tenant_admin:  admin  from tenant
    define tenant_viewer: viewer from tenant
    define can_read: tenant_viewer or tenant_admin or tenant_owner
                     or can_use from provider or can_read from resource_class
                     or global_reader from platform
    define can_provision: ((tenant_admin or tenant_owner) and can_use from provider)
                          or can_provision from resource_class
    define can_update:    ((tenant_admin or tenant_owner) and can_use from provider)
                          or can_update from resource_class
```

The design worth noting is on the backend objects: writes require an
**intersection** — you must be a tenant admin/owner *and* the tenant must still
be permitted to use that provider. Revoking `provider.can_use` for a tenant
instantly disables provisioning for everyone in it without touching per-user
grants. That is the intended kill switch.

Bootstrap seeds **48 tuples** (39 structural wiring + 9 role grants) via
`openfga_bootstrap.py:855-931`, then runs ~50 `Check` assertions to validate
them.

At runtime the **only** writer is `identity_service/app/fga.py` —
`assign_role()` (`:379-407`) and `clear_roles()` (`:427-445`), reachable through
the superadmin-gated `PATCH /api/users/{id}/role` and `POST
/api/users/{id}/disable`. Operator scripts under `test_script/scripts/` also
write tuples out-of-band.

### 5.3 Three enforcement points

| # | Where | What it checks | Code |
|---|---|---|---|
| 1 | identity-service, per verb | `can_read` / `can_provision` / `can_update` on `aws_region:aws` or `nutanix_cluster:nutanix`, for **the end user** | `identity_service/app/main.py:375,406,424,439,452` |
| 2 | libcloud.rest, per route | Scope from `policies.json`, then `can_connect` @ `libcloud_api:main`, `can_use` @ `provider:<x>`, then `can_provision`/`can_read` on the backend object — for **the provisioner** | `libcloud.rest/app/auth/policy.py:73-96,115-148` |
| 3 | Vault credential write | `can_manage_credentials` on `tenant:<t>` | `test_script/scripts/set_tenant_credentials.py:79-96` |

Point 1 is the one that reflects the human's permissions. Point 2 is a
defence-in-depth check against the service account.

### 5.4 The REST API policy table

`libcloud.rest` does **not** put authorization decorators on handlers. Instead
every authorized router uses a custom route class, `AuthorizedAPIRoute`
(`libcloud.rest/app/auth/authorized_route.py:80-124`), which consults an
external, hot-reloadable table at `libcloud.rest/app/auth/policies.json`.

Each entry is keyed `"METHOD /path/template"` and carries `scopes_any_of`,
optional `authz_scope`, optional driver `capability`, `connection_required`, and
`authz_scope_by_body_field` (which routes `PATCH /nodes/{id}` to different
scopes depending on the requested action).

It is **fail-closed**: a request to a route with no policy entry returns
`500 policy_unknown_operation` (`policy_table.py:110-126`). Adding an endpoint
without adding a policy makes it unreachable rather than unprotected — the right
default. Reload without restart via `POST /v1/admin/policies:reload`.

---

## 6. Operational HTTP flows

### 6.1 Browser login (authorization code + PKCE)

```
 1. Browser  GET  http://<host>:3000/login
             → nginx SPA fallback → LoginPage

 2. Browser  GET  /api/auth/begin?provider=lldap&redirect_uri=http://<host>:3000/auth/callback
             → nginx /api/ → identity-service:8766
    identity-service mints state (32B) + PKCE code_verifier (48B), stores them
    in-memory with a 600 s TTL, returns { authorizeUrl, state, provider }

 3. Browser  GET  http://<host>:3000/dex/auth
                    ?client_id=libcloud-portal
                    &redirect_uri=http://<host>:3000/auth/callback
                    &response_type=code&scope=openid profile email
                    &state=<...>&code_challenge=<S256>&code_challenge_method=S256
                    &connector_id=lldap
             → nginx /dex/ → dex:5556
    Dex serves the LLDAP login form directly (connector_id pins it)

 4. Browser  POST /dex/auth/lldap/login    (login + password, form-encoded)
    Dex binds to LLDAP as admin, searches ou=people for (objectClass=person),
    matches uid, then 302s back

 5. Browser  GET  http://<host>:3000/auth/callback?code=<...>&state=<...>
             → SPA route AuthCallbackPage

 6. Browser  POST /api/auth/exchange   { provider, code, state, redirectUri }

 7. identity-service:
      a. consume_state(state)     — single-use pop, TTL-checked. AUTHORITATIVE CSRF check.
      b. provider + redirect_uri are read FROM THE STATE ENTRY, not the request body
      c. POST http://dex:5556/dex/token
           grant_type=authorization_code, code, redirect_uri,
           client_id=libcloud-portal, client_secret=<server-side>, code_verifier
      d. verify id_token: JWKS from http://dex:5556/dex/keys,
           require exp/sub/iss/aud, aud == libcloud-portal, iss == http://dex:5556/dex
      e. resolve_on_login() → existing user | collapse-required | pending
      f. store Dex refresh_token server-side keyed by sid
      g. Set-Cookie: libcloud_portal_sid=<HS256 JWT>; HttpOnly; SameSite=Lax;
                     Max-Age=28800; Path=/
      h. return { internalUserId, role, email, linkedIdentities, clouds[] }
         where clouds[] is computed live from OpenFGA

 8. Browser stores only UX metadata in sessionStorage; navigates to role home
```

The PKCE verifier and the client secret both stay server-side; the browser
handles neither. `state` is server-issued and single-use, which is the real CSRF
defence — the SPA's own state comparison is decorative.

### 6.2 Provisioning a VM, end to end

```
 1. Browser  POST /api/provision/aws   { vmName }      (cookie, credentials:include)

 2. identity-service _require_session() → verify cookie JWT (HS256, exp)

 3. identity-service → OpenFGA
      POST http://openfga:8080/stores/<store>/check
      Authorization: Bearer <provisioner Dex JWT>     ← authenticates the CALLER
      { "authorization_model_id": "<model>",
        "tuple_key": { "user": "user:<end-user principal>",   ← the SUBJECT checked
                       "relation": "can_provision",
                       "object": "aws_region:aws" } }
      → { "allowed": true }
    ── deny here ⇒ 403, nothing downstream happens ──

    Note the split: the bearer token authenticates identity-service to OpenFGA,
    but the subject evaluated is the END USER, resolved from the session cookie
    by _principal() (main.py:67-75) → users._fga_principal(). LLDAP users are
    keyed by uid; pending federated users by their full internal id.

 4. identity-service → Dex (cached): server-side LDAP login as aws-admin
      → access token with aud=libcloud-rest

 5. identity-service → libcloud.rest, replaying the provisioning script sequence.
    Every call carries:
      Authorization: Bearer <provisioner token>
      X-Provider-Connection: { provider, region/host, auth_binding }   ← NO credentials

      GET  /v1/auth/me
      POST /v1/connections:test
      GET  /v1/compute/locations
      GET  /v1/compute/sizes
      GET  /v1/compute/images?arch=x86_64
      GET  /v1/compute/nodes
      GET  /v1/compute/subnets
      POST /v1/compute/nodes            ← the actual create

 6. libcloud.rest, per request, in order (AuthorizedAPIRoute):
      a. RequestIDMiddleware → X-Request-ID
      b. policies.json lookup "POST /v1/compute/nodes"   (fail-closed)
      c. decode bearer: JWKS from http://dex:5556/dex/keys, verify iss + aud=libcloud-rest
      d. parse X-Provider-Connection
      e. PolicyEngine.authorize_connection:
           scope check → provider allowlist → credential policy →
           OpenFGA can_connect @ libcloud_api:main
                   can_use     @ provider:aws
                   can_provision @ aws_region:aws
      f. driver capability check
      g. handler runs

 7. libcloud.rest → Vault
      GET http://vault:8200/v1/secret/data/libcloud/aws
      X-Vault-Token: <libcloud-rest-read token>
      → { data: { data: { key, secret } } }        cached in-process for 30 s

 8. libcloud.rest → Apache libcloud driver → AWS EC2 / Nutanix Prism Central

 9. Response bubbles back with a steps[] trace; portal renders it
```

Client-supplied credentials are **rejected** with `403
auth_client_credentials_forbidden` unless `ALLOW_CLIENT_CREDENTIALS=true`
(default `False`, `libcloud.rest/app/config/settings.py:61`). The client selects
*which* credential by name (`auth_binding`); it never supplies the value.

### 6.3 Machine / CLI login

`test_script/scripts/idp_login.py` scripts the same browser flow headlessly: it
binds a local HTTP server on `127.0.0.1:8767` to catch the callback, GETs
`/dex/auth` with `connector_id=lldap`, scrapes the form action out of the login
HTML, POSTs credentials, captures the code from the redirect, and exchanges it
at `/dex/token` using the `libcloud-rest` client secret. Tokens are cached under
`generated/tokens/<user>.json` and refreshed via `grant_type=refresh_token`.

Port 8767 is deliberate: 8766 is taken by the identity-service container, and
collisions broke `setup.sh` (`idp_login.py:28-36`).

Note this path uses **no PKCE** and a **static `state` value** (`"libcloud-dex"`,
`idp_login.py:186`) — acceptable for a non-interactive localhost tool, but it is
not the same security posture as the browser flow.

### 6.4 Logout

```
 Browser  POST /api/logout        (cookie)
 identity-service:
   1. clear cookie + drop server-side refresh entry
   2. best-effort POST http://dex:5556/dex/token/revoke
        token=<refresh_token>&token_type_hint=refresh_token
        &client_id=libcloud-portal&client_secret=<...>
```

Dex has **no RP-initiated logout endpoint** — `GET /dex/auth/logout` returns 404
(`identity_service/app/main.py:222-226`). RFC 7009 revocation is the only
IdP-side cleanup available. Because Dex uses `storage: memory`, a Dex restart
also invalidates every refresh token.

### 6.5 Reaching Nutanix

`NutanixConnection` (`libcloud/libcloud/common/nutanix.py:139`) supports two
modes:

- **Per-request HTTP Basic** (default, `login_path = None`): every request
  carries `Authorization: Basic base64(user:pass)`, plus `Accept`,
  `Content-Type`, and a fresh `NTNX-Request-Id: <uuid4>`.
- **Session cookie** (opt-in): one `POST <login_path>` with the Basic header;
  the returned `Set-Cookie` is cached and replayed as `Cookie` on later requests
  (`common/nutanix.py:218-271`). `libcloud.rest` layers a process-wide cache on
  top, keyed `nutanix:<host>:<port>` with a 3600 s TTL
  (`app/connections/session_cache.py:24-47`).

TLS verification defaults to **on** (`verify_ssl_cert=True`); disabling works by
setting `ca_cert = False` on the underlying requests session
(`compute/drivers/nutanix.py:163-164`). Test scripts routinely disable it
because the emulator uses a self-signed certificate.

Write operations do a correct optimistic-concurrency dance — `GET` the resource
to read its `ETag`, then `PUT`/`DELETE` with `If-Match`. Against the emulator
this is a no-op, because the emulator never emits an `ETag` (§8).

Typical VM create: `POST /api/vmm/v4.0/ahv/config/vms` → `202` + task reference
→ poll `GET /api/prism/v4.0/config/tasks/{id}` until `SUCCEEDED` → `GET` the new
VM by `extId`.

---

## 7. Secret management

Vault 1.15, `file` storage backend at `/vault/file` on the `vault-data` volume,
**TLS disabled** (`vault/config.hcl:19-26`), listening `0.0.0.0:8200` in-network
and published only on `127.0.0.1:8200`.

Initialized with **1 key share, threshold 1** (`vault_bootstrap.py:158-163`).
The root token, unseal key, and a scoped read token are written to
`vault/generated/vault.env` (mode 0600). On reboot Vault comes back sealed and
re-running bootstrap unseals it with the stored key.

KV v2 layout:

```
secret/data/libcloud/<tenant>     →  { key, secret }
   secret/data/libcloud/aws       →  AWS access key / secret
   secret/data/libcloud/nutanix   →  Prism username / password  (key=user, secret=password)
```

| Consumer | Token | Access |
|---|---|---|
| `libcloud.rest` runtime | `libcloud-rest-read` (TTL 768 h, renewable) | read `secret/data/libcloud/*` |
| `set_tenant_credentials.py`, `vault/add_credential.py` | root token | write |
| `list_credentials.py` | read token | list metadata |

The **only** auth method enabled is Vault's built-in token auth.
`vault_bootstrap.py` enables KV v2, creates the read policy and token, and does
nothing else. There is **no Vault LDAP auth method** — the `vault/ARCHITECTURE.md`
claim that one exists was fabricated and has been corrected (§10).

Writing a tenant credential is itself authorized: `set_tenant_credentials.py`
logs into Dex as the tenant owner, runs an OpenFGA `can_manage_credentials`
check, and only then writes to Vault.

---

## 8. The Nutanix emulator

`stoplight_mock/` provides a two-tier stand-in for Prism Central v4, so the
stack can be exercised without a real cluster. Four API minor versions run side
by side (v4.0–v4.3).

- **Tier 1** — a stateful Node/Express shim (`mock/server.js`) on port 9440,
  HTTPS with a self-signed certificate generated at container start.
- **Tier 2** — Stoplight Prism (`stoplight/prism:5`) on 4010, serving
  schema-valid static examples for any path the shim does not intercept.

The v4.0 merged spec has 487 paths, 2206 schemas, and 109 tags.

**Fidelity gaps that matter when interpreting test results:**

1. **Authentication is a no-op.** There is an explicit bypass middleware
   (`server.js:1124`), and `merge-specs.js:93-117` strips `security` and
   `securitySchemes` from the merged spec so Prism will not 401. Any credential
   is accepted.
2. **The session cookie is fake.** `POST /api/nutanix/v1/session` mints a UUID
   and returns `Set-Cookie: NTNX_IAM_SESSION=...`. That is neither a real Prism
   endpoint nor the real gateway cookie name (`NTNX_IGW_SESSION`), and the token
   is never validated afterwards.
3. **No ETag / `If-Match`.** The shim never emits an `ETag`, so the driver's
   optimistic-concurrency logic is silently skipped. **Concurrency control is
   therefore untested by this emulator.**
4. **No real task engine.** Tasks go `QUEUED → RUNNING → SUCCEEDED` on two
   fixed timers set at creation — `RUNNING` at 200 ms and `SUCCEEDED` at 400 ms
   (`TASK_TRANSITION_MS` and `TASK_TRANSITION_MS * 2`, `server.js:20,123-139`).
   Every task therefore succeeds in 400 ms; there are no failure paths.
5. **`stop_node` does nothing.** The driver sends action `shutdown`; the shim's
   `powerMap` (`server.js:455`) does not include it, so power state is unchanged
   while a success task is still returned.
6. **State is in-memory** — lost on restart.

---

## 9. Security posture

### What is done well

- Cloud credentials never reach the browser or the client. The client names a
  binding; the server resolves the value from Vault.
- Client-supplied provider credentials are rejected by default.
- The Dex refresh token is held server-side and never sent to the browser.
- The browser flow uses PKCE S256 with a server-held verifier, plus a
  server-issued, single-use, TTL-bounded `state`.
- ID-token validation is complete: JWKS signature, `iss`, `aud`, `exp`, and
  required claims.
- The REST API's policy table is **fail-closed** — an unmapped route 500s rather
  than passing unchecked.
- Authorization is enforced server-side on every request. The SPA's route guards
  are cosmetic and are documented as such.
- Bootstrap privilege is gated on a real OIDC login, not a static bypass.
- Most services bind to `127.0.0.1`, with the portal as a deliberate single
  ingress.

### Findings, most severe first

**1. CRITICAL — Live secrets are committed to git, across eleven tracked files.**

| File | Contents |
|---|---|
| `vault/generated/vault.env` | Vault **root token** and **unseal key** |
| `dex/generated/dex.env` | OAuth client secrets + **all eight LLDAP user passwords** |
| `dex/config.yaml` | Both OAuth client secrets + the **LLDAP admin bind password** |
| `test_script/tenant_vault_secret.env` | **AWS access key + secret**, Nutanix credentials |
| `test_script/myrun_nutanix.sh` | An LLDAP password + an OIDC client secret |
| `test_script/myrun_nutanix_query.sh` | Same class of hardcoded credentials |
| `test_script/myrun_aws_admin.sh` | Same class of hardcoded credentials |
| `test_script/myrun_aws_query.sh` | Same class of hardcoded credentials |
| `test_script/myrun_aws_view.sh` | Same class of hardcoded credentials |
| `test_script/doc/provision_aws.md` | A walkthrough with the **real AWS key/secret**, LDAP bind password and client secret pasted inline (9 occurrences) |
| `test_script/doc/provision_aws.stderr` | Captured output containing the same values |

`vault/generated/vault.env` even carries the header *"DO NOT COMMIT
(gitignored)"* — but `.gitignore` cannot untrack a file that was added before
the rule existed. Anyone with repo history can unseal Vault, read every cloud
credential, and log in as any user including `superadmin`.

The last two rows are the easiest to miss: a **documentation** file and a
captured **stderr** log, where credentials were pasted while explaining a
provisioning trace. Any audit that only sweeps `.env` files will not find them.

Enumerate the current set with:

```bash
git ls-files -z | xargs -0 grep -lE '<known-secret-patterns>'
```

*Remediation: `git rm --cached` all eleven, rotate every value (Vault re-init,
Dex client secrets, all LLDAP passwords, AWS keys, LLDAP bind password), then
purge history with `git filter-repo` before the repo is shared further.
Untracking alone leaves them readable in every existing clone.*

*(Note: `libcloud.rest/doc/API.md` contains `AKIAIOSFODNN7EXAMPLE` — that is
AWS's official documentation placeholder, not a live key.)*

**2. CRITICAL — The session cookie signing key is a placeholder that bootstrap never generates.**
`session_secret` defaults to `"change-me"` (`identity_service/app/config.py:185`);
compose defaults to `"change-me-in-production"`; `identity_service/.env` ships
`SESSION_SECRET=change-me`. Grepping `setup.sh`, `rebuild_all.sh`, and the
bootstrap scripts confirms **it is never generated** — unlike the Postgres
password and Dex client secrets, which are. Since the cookie is an HS256 JWT
signed with this key, anyone who knows it can forge a valid session for any
user. `identity_service/verify_authz_matrix.sh:86-99` already does exactly this
as a test technique.
*Remediation: generate `SESSION_SECRET` in `setup.sh` alongside the other
generated secrets, and refuse to boot on the placeholder value.*

**3. CRITICAL — Role checks trust the self-asserted cookie role.**
`identity_service/app/main.py:87-97`:

```python
def _require_role(req: Request, role: str) -> dict[str, Any]:
    claims = sessions.read(req)
    principal = _principal(claims)
    # superadmin satisfies any role check.
    if claims.get("role") == role or claims.get("role") == "superadmin":
        return claims                       # ← returns without consulting OpenFGA
    current = fga.role_for(principal)       # only reached if the cookie DISAGREES
    ...
```

OpenFGA is consulted only when the cookie's own claim is insufficient. A cookie
claiming `role: superadmin` is therefore honoured with **no authorization lookup
at all**, unlocking user management, raw OpenFGA tuple CRUD, and the full
OpenFGA explorer. Combined with finding 2, this is a complete authentication
bypass to platform admin.
*Remediation: make OpenFGA authoritative — look up the role first and treat the
cookie claim as a cache hint only.*

**4. HIGH — OpenFGA authenticates but does not authorize its own API.**
OpenFGA is configured with `--authn-method=oidc --authn-oidc-audience=libcloud-rest`.
Every seeded user can obtain a token with that audience via `idp_login.py`. The
OIDC method validates issuer, audience, and signature — it does **not** scope
what a principal may do. So any authenticated user who can reach `openfga:8080`
can call `/stores/{id}/write` and grant themselves any relation. The only
control is network placement (loopback + `libcloud_net`). The compose comment at
`openfga_postgres/docker-compose.yml:104-106` states the audience sharing as a
feature; the authorization consequence is not noted.
*Remediation: give OpenFGA a distinct audience and issue management tokens
separately from user tokens, or front it with a proxy that authorizes writes.*

**5. HIGH — No TLS anywhere in the stack.**
Dex issues over `http://`; the portal serves `http://`; LDAP runs with
`insecureNoSSL: true`; Vault has `tls_disable = 1`; OpenFGA and the REST API are
plaintext. Consequently the session cookie is issued with `Secure=False`
(`config.py:188`) — it *must* be, since there is no HTTPS to carry it. Session
cookies, authorization codes, and Vault tokens all cross the wire in clear text.
Acceptable only because most ports are loopback-bound; it stops being acceptable
the moment the portal is exposed beyond localhost.

**6. HIGH — a one-shot OpenFGA discovery failure silently disables authorization
for the process lifetime.**
`identity_service/app/fga.py:240-247` returns `True` when `self.enabled` is
false, and `_derive_authz()` (`:316-323`) grants viewer + provision + update on
**both** clouds in the same state. An *unreachable* OpenFGA correctly raises
`503 authz_fga_unreachable` (`fga.py:234-237`) — so the error path fails closed.

The dangerous path is **discovery**. `_ensure_discovered()` sets
`self._discovered = True` at `fga.py:108` *before* attempting discovery, and
`_find_store_by_name` catches bare `Exception` and returns `""`
(`fga.py:150-152`). One transient failure — OpenFGA not yet accepting
connections, a slow first provisioner login — leaves `store_id` empty
**permanently, with no retry**. `enabled` stays false and every `check()` returns
`True`: allow-all until the container is restarted. The only evidence is a single
WARNING reading `"authorization checks skipped"`.

`identity_service/docker-compose.yml` declares **no `depends_on`**, so nothing
orders the identity service after OpenFGA. A cold `docker compose up` is a live
race.
*Remediation: fail closed on the disabled path; don't latch `_discovered` on
failure; narrow the exception; add `depends_on` with a healthcheck.*

**7. MEDIUM — Vault runs a development-grade posture.**
File storage, single-share unseal (threshold 1), `disable_mlock = true`, root
token persisted to disk, a 768-hour read token, and no audit device enabled.
Combined with finding 1, the unseal key and root token are also in git.

**8. MEDIUM — The OpenFGA visualizer is exposed on all interfaces.**
`0.0.0.0:5050`, served by the **Werkzeug development server**
(`openfga_visualized/app.py:1641`) over plain HTTP. It is genuinely
well-guarded — Dex SSO, full JWT verification, and a hard superadmin-only gate
(`app.py:1503-1512, 1589-1597`) — and read-only against OpenFGA. But a dev
server on a public interface is not a production posture, and the whole RBAC
graph sits behind it.

**9. MEDIUM — The Nutanix emulators are exposed on all interfaces with no authentication.**
`0.0.0.0:9440-9443`, self-signed HTTPS, auth bypassed by design (§8). Fine on an
isolated lab host; it should never be reachable from an untrusted network.

**10. MEDIUM — Portal mock mode defaults to enabled in code.**
`server/src/config.js:18` treats `mockMode` as **true** when the env var is
unset, and `.env.example` also defaults to `true`. `mockApi.mockLoginAs()`
(`mockApi.js:94-106`) allows the browser to impersonate any seeded user,
superadmin included, with no Dex involvement. The current build sets it `false`,
but the code is compiled into the bundle regardless and one missing build arg
re-enables an impersonation picker.
*Remediation: default `mockMode` to false and gate it on a non-production build.*

**11. LOW — `redirect_uri` is not allowlisted by the identity service.**
`/api/auth/begin` accepts a caller-supplied `redirect_uri`
(`main.py:116-121`) and passes it to Dex. Dex's registered-URI check is the only
gate; the service never validates it itself. Impact is limited because the client
secret stays server-side, but it is an unnecessary open-redirect surface.

**12. LOW — No explicit CSRF token on cookie-authenticated writes.**
`/api/provision/*`, `/api/users/*`, and `/api/tuples` rely solely on
`SameSite=Lax`. That blocks cross-site POSTs in current browsers, but there is no
defence in depth.

**13. LOW — All session and OAuth state is in-process memory.**
`_state_store`, `_used_jti`, `_refresh_store`, and `_pending_users` are plain
dicts. The stack is single-replica only; a restart logs everyone out and drops
pending federated identities. Documented as a known limitation.

**14. LOW — Secrets are passed to subprocesses via the environment.**
`libcloud_proxy._script_env` (`:708-732`) passes the OIDC client secret and
provisioner passwords to shelled-out provisioning scripts, making them readable
in `/proc/<pid>/environ`.

### Suggested remediation order

1. Purge and rotate the committed secrets (finding 1).
2. Generate `SESSION_SECRET` at bootstrap; refuse the placeholder (finding 2).
3. Make OpenFGA authoritative in `_require_role` (finding 3).
4. Separate the OpenFGA management audience from the user audience (finding 4).
5. Terminate TLS at the portal and set `SESSION_SECURE=true` (finding 5).
6. Make authorization fail closed (finding 6).

Findings 2 and 3 are individually critical and compose into a full bypass; they
should be fixed together.

---

## 10. Corrections applied to the subsystem documents

Each subsystem `ARCHITECTURE.md` was verified line by line against source and
corrected. The substantive errors were:

| Document | Corrected |
|---|---|
| `vault/ARCHITECTURE.md` | Removed a fabricated **Vault LDAP auth method** (§1/§6/§8.2 described `vault write auth/ldap/config`, group→policy mapping, and "LDAP-issued tokens"; none of it exists — the LLDAP bind credential feeds **Dex**, not Vault). Fixed OpenFGA datastore sqlite → **Postgres**. Corrected the "gitignored" claim for `generated/vault.env` — it is **tracked**. Fixed `openfga_my/` → `openfga_postgres/`, script paths → `test_script/scripts/`, and the loopback port binding. |
| `dex/ARCHITECTURE.md` | "Single OAuth client" → **two** (`libcloud-rest` + `libcloud-portal`). Redirect-URI list completed (2 → 8 across both clients). Federation corrected to **Google/GitHub** as implemented. Clarified that the REST API only *validates* tokens rather than running the auth-code flow. Fixed the loopback port binding, the client-secret rotation procedure, and stale `openfga_my/` and `scripts/` paths. |
| `openfga_visualized/ARCHITECTURE.md` | Store/model IDs are **auto-discovered**, not hardcoded defaults. Issuer corrected to `http://dex:5556/dex`. Callback URIs corrected. Seed tuples **52 → 48** (39 wiring + 9 grants). "Four tabs" → **five** (Model Graph added), with `/api/model_graph` and `/api/model_dsl`. Documented the **superadmin-only login gate**, which was missing entirely. |
| `libcloud.rest/ARCHITECTURE.md` | Inverted credential model corrected — credentials come from **Vault**, and client-supplied ones are **rejected** by default. Documented `policies.json` + `AuthorizedAPIRoute` (authorization moved out of handlers). IdP corrected Authentik → **Dex/LLDAP**, and `USERNAME_SCOPES` → `PRINCIPAL_SCOPES`. Added ~25 undocumented endpoints and the missing modules. |
| `stoplight_mock/ARCHITECTURE.md` | Flagged that the `mock/v40/` directory referenced by `merge-specs.js` **does not exist** and is mounted by no compose service — so the documented v4.0 spec build is not runnable as written. Removed a non-existent `myrun.sh` build helper. Corrected the `-m false` claim (static examples come from omitting `-d`, not from `-m`). **Documented the session-cookie handshake**, which the auth section omitted. Narrowed the "three path variants for every resource" overstatement. |
| `lldap/ARCHITECTURE.md` | `role` is **multi-valued** (`isList: true`), not single-valued — the applied GraphQL schema disagrees with the unused `custom-attributes.json`. Corrected the bootstrap invocation, the healthcheck source, and the loopback port bindings. |
| `libcloud/ARCHITECTURE.md` | Was not an architecture document — a bare, stale `def` listing. Replaced with a real description of the Nutanix driver: connection class, Basic vs session-cookie auth, TLS handling, task polling, ETag/`If-Match`, and the `nutanix.py` vs `nutanix_no_cookie.py` distinction. |

### Documentation added in this pass

- `identity_service/ARCHITECTURE.md` — sessions, the OIDC exchange, identity
  collapse, the provisioner audience bridge, enforcement point 1.
- `openfga_postgres/ARCHITECTURE.md` — the authorization model, the bootstrap,
  and the Dex/Vault renderers this component also hosts.
- `server/ARCHITECTURE.md` — the SPA, the nginx front door, and the build-time
  vs runtime configuration split.
- `SCRIPTS.md` (repo root) — operator reference for the bootstrap, verification,
  authorization-inspection, Vault and air-gap migration scripts.
- `presentation/` — a 27-slide system walkthrough deck and its generator.

### Remaining gaps

- `test_script/doc/doc.index` still indexes the removed `openfga_my/` tree.
- `test_script/shutdown.sh` names the retired SQLite volume `openfga-data` in
  its docstring and its `--wipe` warning; the live store is
  `openfga_postgres_openfga-pg-data`, so the warning misstates what is at risk.
