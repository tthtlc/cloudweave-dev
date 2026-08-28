# Architecture — Identity Service

The identity service (`identity-service`, FastAPI, port **8766**) is the portal's
back end and the system's **primary authorization enforcement point**. It owns
browser sessions, performs the OIDC code exchange with Dex, decides what the
logged-in human may do by asking OpenFGA, and only then proxies cloud operations
to the libcloud REST API.

It is the component that must not be bypassed. The libcloud REST API downstream
sees a *service account*, not the end user (§5.4) — so if this service gets an
authorization decision wrong, nothing further down catches it.

See the repo-root `ARCHITECTURE.md` for how this fits the whole stack.

---

## 1. Position in the system

```
Browser ──► portal nginx :3000 ──► identity-service :8766
                 │  /api/  ─────────────┘        │
                 │  /dex/  ──► dex:5556          ├──► openfga:8080   (authorization)
                 └─ SPA                          ├──► lldap:3890     (directory, LDAP)
                                                 ├──► lldap:17170    (GraphQL, writes)
                                                 ├──► dex:5556       (token exchange)
                                                 ├──► libcloud-rest-api:8765
                                                 └──► bash test_script/scripts/*.sh
```

The host publishes `127.0.0.1:8766` only (`docker-compose.yml:20`); the browser
always arrives via the portal's nginx `/api/` proxy, so requests are same-origin
in production.

**CORS** (`app/main.py:48-55`) allows exactly two origins —
`http://<PUBLIC_HOSTNAME>:3000` and `http://localhost:3000` — with
`allow_credentials=True` and `allow_headers=["*"]`. Not a wildcard origin. Behind
the nginx proxy CORS is largely moot; it exists for split-origin dev.

---

## 2. Module map

| File | Responsibility |
|---|---|
| `app/main.py` | `create_app()`, all routes, the role/session guards, service singletons |
| `app/config.py` | `Settings` (pydantic-settings), `@lru_cache`d; derives URLs from `PUBLIC_HOSTNAME` |
| `app/hot_config.py` | Live-reload of `$REPO_ROOT/my.env` — re-read on mtime change, no restart |
| `app/auth_state.py` | `AuthService` — server-issued OAuth `state`, PKCE verifier, pending-identity tokens |
| `app/dex.py` | `DexService` — code exchange, ID-token verification, RFC 7009 revocation |
| `app/session.py` | `SessionService` — mints/verifies the httpOnly cookie; server-side refresh store |
| `app/users.py` | `UserService` — internal-user model, login resolution, identity collapse, admin ops |
| `app/fga.py` | `FgaService` — OpenFGA client, role↔relation mapping, local derivation |
| `app/lldap.py` | `LldapService` — LDAP reads, GraphQL writes |
| `app/idp_login.py` | `ProvisionerAuth` — the service-account token bridge (§5.4) |
| `app/libcloud_proxy.py` | `LibcloudProxy` — cloud verbs against libcloud REST; shells out for two of them |
| `app/aws_resolve.py` | AMI/instance-type arch-compatible selection |
| `app/models.py` | Pydantic request/response models |
| `app/errors.py` | `APIError` + JSON handler — `{error, message, details}`, no stack traces |

---

## 3. Configuration

`Settings` (`app/config.py`) is cached at startup. Notable derivations:

- **`dex_base_url`** is browser-facing and derived from `PUBLIC_HOSTNAME` into
  `http://<host>:3000/dex` (`config.py:53-70`) — i.e. through the portal proxy,
  not port 5556 directly.
- **`dex_issuer`** stays the in-container `http://dex:5556/dex` — the `iss` value
  that must match Dex's config and OpenFGA's `--authn-oidc-issuer`.
- **`lldap_bind_dn` / `lldap_bind_pw`** are derived from the raw `lldap/.env`
  vars when not set explicitly (`config.py:102-108`).
- **Script paths** for the shelled-out verbs are derived relative to the repo
  root (`config.py:110-125`).

`config.py:16-23` documents a deliberate choice: it does **not** auto-load
`dex/generated/dex.env` or `openfga_postgres/generated/fga.env`, because those
carry host-side URLs (`localhost:5556`, `localhost:8080`) that are wrong inside
a container. Compose mounts them via `env_file` and overrides the URL keys.

> **Known wrong default.** `fga_api_url` defaults to `http://openfga:8081`
> (`config.py:74`) — that is OpenFGA's **gRPC** port. The HTTP API is 8080.
> Compose corrects it (`docker-compose.yml:49`), so the deployed service is
> fine, but any run without that override silently fails discovery (§6.4).

`hot_config` (`app/hot_config.py`) re-reads `/run/config/my.env` whenever its
`(mtime, size)` changes. Only the Nutanix connection parameters use it
(`libcloud_proxy.py:261-266, 734-738`), so `NUTANIX_HOST`, port, API version and
`NUTANIX_VERIFY_SSL` can be changed at runtime with no restart — including
turning **off** TLS verification toward Nutanix.

---

## 4. Endpoint reference

`cloud ∈ {aws, nutanix}` (`main.py:364`), rejected otherwise with `400
not_supported`.

### Public

| Method | Path | Notes |
|---|---|---|
| GET | `/health` | Liveness. `{"status": "ok"}` |
| GET | `/api/auth/begin` | Mints `state` + PKCE; returns `authorizeUrl` |
| POST | `/api/auth/exchange` | Redeems code; mints session **or** returns a `pendingToken` |
| POST | `/api/auth/collapse` | Links a federated identity; requires the `pendingToken` |

### Session-authenticated

| Method | Path | Authorization |
|---|---|---|
| GET | `/api/session` | Session cookie; `clouds[]` computed live from OpenFGA |
| POST | `/api/logout` | Session cookie |
| GET | `/api/resources/{cloud}` | `can_read` |
| GET | `/api/hosts/{cloud}` | `can_read` (Nutanix physical hosts) |
| POST | `/api/provision/{cloud}` | `can_provision` |
| POST | `/api/provision-private/{cloud}` | `can_provision` (bastion + internal pair) |
| POST | `/api/deprovision/{cloud}` | `can_provision` |
| POST | `/api/update/{cloud}` | `can_update` |

### Superadmin only

User management: `GET /api/users`, `PATCH /api/users/{id}/role`,
`POST /api/users/{id}/disable`, `PATCH /api/users/{id}/email`.

Raw tuple CRUD: `GET|POST|DELETE /api/tuples`.

OpenFGA explorer: `GET /api/openfga/store`, `/models`, `/models/{id}`,
`/assertions/{id}`, `/changes`; `POST /api/openfga/list-users`, `/list-objects`,
`/expand`; and `GET /api/openfga/rest-api-policies` (a read-only dump of the
REST API's `policies.json`, path from `rest_api_policies_path`, default
`/opt/policies.json`).

> `docker-compose.yml:57-63` claims the provisioner redirect URI
> `http://127.0.0.1:8766/oauth/callback` is "served by the identity service's
> `/oauth/callback` route". **No such route exists.** It is a registered-only URI
> that Dex validates but never connects to — `ProvisionerAuth` reads the code out
> of the 302 `Location` header instead (§5.4). The comment is misleading; the
> flow is correct.

---

## 5. Authentication

### 5.1 Browser login

`GET /api/auth/begin` (`auth_state.py:54-77`) mints:

- `state` — `secrets.token_urlsafe(32)`
- `code_verifier` — `secrets.token_urlsafe(48)`, and `code_challenge =
  base64url(SHA256(verifier))`, method **S256**

Both are stored server-side in `_state_store` with a **600 s TTL**, together with
the `provider` and `redirect_uri`. Only the `state` echo goes to the browser.

`POST /api/auth/exchange` (`main.py:124-180`):

1. `auth.consume_state(state)` — a single-use `pop`, TTL-checked
   (`auth_state.py:79-87`). **This is the authoritative CSRF check.** The SPA's
   own state comparison is defence in depth only (`main.py:126-129`).
2. `provider` and `redirect_uri` are taken **from the stored state entry**, not
   from the request body (`main.py:133-134`) — a client cannot redirect the
   exchange elsewhere.
3. `dex.exchange_code()` POSTs `/dex/token` with `grant_type=authorization_code`,
   the server-held `client_secret`, and the `code_verifier`.
4. `dex.verify_id_token()` (`dex.py:66-83`) verifies the JWKS signature and
   requires `exp`, `sub`, `iss`, `aud`, with `audience=libcloud-portal` and
   `issuer=dex_issuer`.
5. `users.resolve_on_login()` (§5.3).
6. The Dex refresh token is stored **server-side only** (`session.py:61-66`).
7. The session cookie is set.

The comments in `auth_state.py:16-29` record two vulnerabilities this design
closed: browser-generated `state` that the backend never verified, and a
`/collapse` endpoint that trusted a client-supplied identity subject.

### 5.2 The session cookie

`SessionService` (`app/session.py`) issues cookie `libcloud_portal_sid`: an
**HS256 JWT** signed with `session_secret`, carrying `internalUserId`, `role`,
`email`, `linkedIdentities`, `sid`, `iat`, `exp`, `jti`.

| Flag | Value | Source |
|---|---|---|
| `HttpOnly` | true | `session.py:72` |
| `Secure` | **false** | `config.py:188` |
| `SameSite` | `lax` | `config.py:189` |
| `Max-Age` | 28800 (8 h) | `config.py:187` |
| `Path` | `/` | `session.py:75` |

`_refresh_store` (`session.py:17`) maps `sid → {refresh_token, id_token,
internalUserId}` in process memory. **The Dex refresh token never reaches the
browser** — a deliberate and correct choice, noted in the class docstring.

### 5.3 Internal users and identity collapse

An "internal user" is the portal's own stable identity, distinct from any
provider subject (`users.py:59-66`). One internal user may carry several
`linkedIdentities` (`google:…`, `github:…`).

- LLDAP users → `int-<uid>`
- Pending federated users → `int-pending-<8 hex>` (`users.py:177`)

**`_fga_principal()`** (`users.py:245-258`) maps an internal id to an OpenFGA
principal, and the distinction matters:

```python
if internal_user_id in _pending_users:   return internal_user_id   # int-pending-…
if internal_user_id.startswith("int-"):  return internal_user_id[4:]  # LLDAP uid
return internal_user_id
```

LLDAP users are keyed in OpenFGA by **uid** (bootstrap seeds `user:aws-admin`
etc.); pending users by their **full internal id**, since they have no uid yet.
The source comment notes that conflating these previously caused role changes to
write tuples for a non-existent principal and silently no-op.

**`_dex_lldap_uid()`** (`users.py:13-38`) recovers the uid from Dex's `sub`,
which is `base64(protobuf{field1=UserID, field2=ConnectorID})`, not the bare uid.
It strips any `connector:` prefix, base64url-decodes with padding repair, then
walks tag/length/value pairs looking for field 1. It is a **single-byte length
parser** — it assumes uid and connector id are ≤255 bytes and falls back to the
raw subject on any parse failure.

**`resolve_on_login()`** (`users.py:95-171`) has four branches:

| Branch | Condition | Outcome |
|---|---|---|
| A | `provider == "lldap"` | Direct login; never collapses. Role from `fga.role_for(uid)` |
| B | Subject already linked | Existing user returned |
| C | Email matches an LLDAP user | `needsIdentityCollapse: true` + `collapseCandidates` |
| D | Brand new federated user | Pending user, role `pending`, **no OpenFGA tuples** |

Branch D is the safe default: a first-time federated user is authenticated but
authorized for nothing until a superadmin assigns a role *and* tenant.

**Collapse** solves linking a Google/GitHub identity to an existing LLDAP user
with the same email, rather than creating a duplicate. `/api/auth/exchange`
issues a **single-use pending token** (HS256, `type=pending_identity`, 300 s TTL,
`jti` tracked in `_used_jti`) bound to the Dex-verified identity.
`/api/auth/collapse` accepts **only** that token; `CollapseRequest.pendingIdentity`
is explicitly ignored (`models.py:60`).

### 5.4 The provisioner service account — the audience bridge

The portal user's token has `aud=libcloud-portal`. The libcloud REST API requires
`aud=libcloud-rest`. Rather than reconfigure audiences, the identity service
**mints a separate token** by logging into Dex as a per-cloud LLDAP service
account (`aws-admin` / `ntnx-admin`, `config.py:167-170`).

`ProvisionerAuth` (`app/idp_login.py`) runs the authorization-code flow headlessly
with no callback server: it GETs `/dex/auth`, scrapes the login form action,
POSTs credentials with `follow_redirects=False`, and reads the code from the 302
`Location` header. Tokens are cached per cloud in a module-level dict, reused
until 30 s before expiry, then refreshed.

Three consequences worth being explicit about:

1. **The REST API sees the provisioner, not the human.** Downstream authorization
   evaluates the service account. The end user's permissions are checked *here*
   and nowhere else on that path.
2. **This token also authenticates to OpenFGA** (`fga.py:172-177`), which uses
   `--authn-method=oidc`. OpenFGA authenticates the *caller* but evaluates the
   *subject* in the tuple — so passing a service-account bearer while checking
   the end user is correct.
3. `_parse_token` decodes the access token with `verify_signature=False`
   (`idp_login.py:31`) purely to read `exp` for cache expiry. Safe here, but it
   is not a validation step.

### 5.5 Logout

`POST /api/logout` (`main.py:207-227`) clears the cookie, drops the server-side
refresh entry, and best-effort POSTs `/dex/token/revoke` (RFC 7009). Failures are
logged, never blocking.

Stock Dex has **no RP-initiated logout** — `GET /dex/auth/logout` 404s — and
keeps no browser SSO cookie, so every `/dex/auth` re-prompts the login form.
Refresh-token revocation is the entire IdP-side logout.

---

## 6. Authorization

### 6.1 Role gate

```python
def _require_role(req: Request, role: str) -> dict[str, Any]:
    claims = sessions.read(req)
    principal = _principal(claims)
    if claims.get("role") == role or claims.get("role") == "superadmin":
        return claims                    # ← returns without consulting OpenFGA
    current = fga.role_for(principal)    # only reached if the cookie DISAGREES
    if current == role or current == "superadmin":
        return claims
    raise APIError("authz_forbidden", "Insufficient role", 403, ...)
```
`main.py:87-97`

OpenFGA is consulted **only when the cookie's own claim is insufficient**. A
cookie asserting `role: superadmin` is honoured with no authorization lookup.
See finding 2 in §8.

### 6.2 Per-verb checks

The cloud verbs do consult OpenFGA on every request, against the **end user's**
principal (`main.py:375, 406, 424, 439, 452`):

| Verb | Relation | Object |
|---|---|---|
| view / hosts | `can_read` | `aws_region:aws` \| `nutanix_cluster:nutanix` |
| provision, provision-private, deprovision | `can_provision` | same |
| update | `can_update` | same |

Mapping constants: `CLOUD_OBJECTS`, `VIEW_RELATION`, `PROVISION_RELATION`,
`UPDATE_RELATION` (`fga.py:67-70`).

`_tenant_for_principal()` (`fga.py:44-60`) derives a tenant from the principal
slug by role suffix: `aws-admin → aws`, `ntnx-owner → nutanix` (via
`TENANT_BY_SLUG`). An unrecognised slug returns `None` rather than inventing a
tenant — least privilege by default.

### 6.3 Local derivation, and where it can diverge

`role_for()`, `cloud_capabilities()` and `batch_derive()` do **not** call
OpenFGA's `/check`. They read concrete tuples and evaluate them locally in
`_derive_from_tuples()` (`fga.py:251-312`): strongest tenant role wins
(owner > admin > viewer), `canProvision = canUpdate = (role ∈ {admin, owner})`,
`canView` additionally true for viewers and superadmins.

The source is honest about the limit (`fga.py:258-262`): it does **not** evaluate
computed relations depending on provider-level `can_use` or resource-class
grants, "so it is equivalent for the running store."

That equivalence is a property of the *current seed data*, not of the model. The
authorization model's backend objects gate writes on an **intersection** —
`(tenant_admin ∪ tenant_owner) ∩ can_use from provider`. The moment a
`provider.can_use` grant is revoked to disable a tenant (the model's intended
kill switch), `/check` would deny while this local derivation still reports
`canProvision: true`. The portal would render the button; the enforcing check in
§6.2 would still deny it, so this is a **UI/enforcement divergence, not a
bypass** — but it will mislead operators exactly when they are trying to shut
something off.

There are also **three** places hardcoding the cloud list — `CLOUD_OBJECTS`
(`fga.py:67`), `SUPPORTED_CLOUDS` (`fga.py:552`), and the inline `supported` /
`cloud_tenant` in `_derive_from_tuples` (`fga.py:293-294`) — which the code
comment itself acknowledges must be kept in sync.

### 6.4 Enabled, discovery, and fail-open

```python
@property
def enabled(self) -> bool:
    s = get_settings()
    if not s.fga_enabled:
        return False
    self._ensure_discovered()
    return bool(self.store_id and self.model_id)
```
`fga.py:179-185`

When `enabled` is false, `check()` returns **`True`** (`fga.py:241-242`) and
`_derive_authz()` grants `canView`/`canProvision`/`canUpdate` on **both** clouds
(`fga.py:316-323`).

Distinguish two paths carefully:

- **Unreachable / erroring OpenFGA → fail closed.** `_post`/`_get` raise
  `authz_fga_error` or `authz_fga_unreachable` as 503 (`fga.py:199-204,
  227-237`). Correct.
- **Discovery failure → fail open.** See finding 1 in §8. This is the dangerous
  one.

### 6.5 Role changes

`set_role()` (`users.py:260-305`) revokes before granting: `fga.clear_roles()`
then `fga.assign_role()` (`users.py:301, 304`). The comment explains why —
otherwise the old, possibly stronger, tuples remain and `role_for()` keeps
returning the old role. `clear_roles()` only removes relations in
`MANAGED_RELATIONS` (`owner`, `admin`, `viewer`, `superadmin`) on `tenant:` /
`platform:` objects (`fga.py:440-444`), so hand-written structural tuples survive.

Pending users must be given an explicit `tenant`, validated against
`KNOWN_TENANTS` (`users.py:286-292`).

---

## 7. Cloud operations

`LibcloudProxy` (`app/libcloud_proxy.py`) attaches
`Authorization: Bearer <provisioner token>` and an `X-Provider-Connection`
header — compact JSON naming the provider, connection config, and
**`auth_binding`**. It carries **no credentials**; the REST API resolves the real
cloud credential from Vault by that binding name.

`provision()` (`libcloud_proxy.py:405`) replays the shell-script sequence as REST
calls, appending a human-readable line to `steps[]` per call:

```
GET  /v1/auth/me
POST /v1/connections:test
GET  /v1/compute/locations
GET  /v1/compute/sizes
GET  /v1/compute/images          (AWS: ?name=*ubuntu*24.04*amd64*)
GET  /v1/compute/storage-containers   (Nutanix only)
GET  /v1/compute/nodes
GET  /v1/compute/subnets         (inside _resolve)
POST /v1/compute/nodes
```

AWS resolves an arch-compatible AMI and instance type by scoring
(`app/aws_resolve.py`); Nutanix takes `images[0]` and hardcodes size `small`.

`list_nodes()` additionally fans out across per-cloud **category specs**
(`_AWS_CATEGORY_SPECS`, `_NTNX_CATEGORY_SPECS`) to build the inventory view —
VPCs, subnets, security groups, images, volumes, buckets and so on. Rows are
capped at `inventory_max_rows` (default 50) with the true count in `total`; a
failing category degrades to an empty table with an `error` note rather than
blanking the page.

**Two verbs shell out** rather than calling REST, so the scripts stay the single
source of truth for their sequences:

| Verb | Script | Timeout |
|---|---|---|
| `deprovision` | `test_script/scripts/deprovision_{aws,nutanix}.sh` | 180 s |
| `provision_private` | `test_script/scripts/provision_aws_private.sh` / `provision_nutanix_bastion_private.sh` | 900 s |

Both use `subprocess.run(["bash", script], env=..., capture_output=True)` —
**list form, no `shell=True`**. User-controlled values (`vmName`, `vmId`,
pair names) are passed as environment variables, never interpolated into a
command line, so there is no shell-injection surface at the Python layer.

`update_node()` does **not** shell out — it PATCHes `/v1/compute/nodes/{id}`.

---

## 8. Security posture

### Controls that are correct

- Server-issued, single-use, TTL-bounded OAuth `state`; PKCE S256 with a
  server-held verifier; `provider`/`redirect_uri` read from the state entry.
- Complete ID-token validation: JWKS signature, `iss`, `aud`, `exp`, required
  claims.
- The Dex refresh token never reaches the browser.
- Collapse is bound to a single-use server-issued token; the client-supplied
  identity is ignored.
- New federated users land with **no** OpenFGA tuples — authenticated, authorized
  for nothing.
- Cloud credentials never transit this service; only `auth_binding` names do.
- `subprocess` calls use the list form with no shell.
- Errors return `{error, message, details}` with no stack traces.

### Findings

**1. CRITICAL — a one-shot discovery failure silently disables authorization for
the process lifetime.**

`_ensure_discovered()` sets `self._discovered = True` at `fga.py:108` **before**
attempting discovery, and `_find_store_by_name` catches bare `Exception` and
returns `""` (`fga.py:150-152`). So a single transient failure — OpenFGA not yet
accepting connections, a slow first provisioner login, a DNS blip — leaves
`store_id` empty **permanently**. There is no retry. `enabled` then stays false,
and `check()` returns `True` for every request: **allow-all, until someone
restarts the container.**

The only evidence is one line at WARNING level that reads
`"FGA store '…' not found … authorization checks skipped"`.

This is not hypothetical: `identity_service/docker-compose.yml` declares **no
`depends_on`** for the identity service, so nothing orders its start after
OpenFGA. A cold `docker compose up` is a live race.

*Remediation, in order of value:* (a) make the disabled path fail **closed**;
(b) don't latch `_discovered` on failure — retry with backoff; (c) narrow the
`except Exception`; (d) add `depends_on` with a healthcheck condition; (e) refuse
to start when `fga_enabled=true` but discovery yields nothing.

**2. CRITICAL — `_require_role` trusts the cookie's self-asserted role.**
`main.py:91` returns before consulting OpenFGA when the cookie already claims the
required role or `superadmin`. Combined with finding 3, a forged cookie reaches
every superadmin endpoint — user management, raw tuple CRUD, the OpenFGA
explorer — with no authorization lookup. *Remediation: make OpenFGA
authoritative; treat the cookie claim as a display hint only.*

**3. CRITICAL — the session signing key is a placeholder the bootstrap never
generates.** `session_secret` defaults to `"change-me"` (`config.py:185`), compose
to `"change-me-in-production"`, and `identity_service/.env` ships
`SESSION_SECRET=change-me`. Nothing in `setup.sh` or `rebuild_all.sh` generates
it — unlike the Postgres password and Dex client secrets. Since the cookie is an
HS256 JWT signed with this key, knowing it means forging a session for any user.
`verify_authz_matrix.sh:86-99` already does exactly this as a test technique.

Note the same secret also signs the **pending-identity token**
(`auth_state.py:102`). A forged pending token re-opens precisely the
account-takeover the collapse hardening was written to close: link an arbitrary
federated subject into a victim's internal user.

*Remediation: generate `SESSION_SECRET` at bootstrap and refuse to boot on the
placeholder.*

**4. HIGH — no HTTPS, so `Secure=false` on the session cookie.**
`session_secure` defaults false (`config.py:188`) and every browser-facing URL is
`http://`. The cookie and the authorization code cross the wire in clear text.
Acceptable only while the deployment is loopback/LAN-bound.

**5. MEDIUM — unescaped LDAP filter interpolation.**
`LldapService.find_by_email` builds its filter with an f-string
(`lldap.py:94`):

```python
search_filter=f"(&(objectClass=person)(mail={email}))"
```

`email` is not escaped per RFC 4515. It arrives from the Dex-verified `email`
claim, which bounds exploitability — a federated provider supplies a real
address, and LLDAP's own `mail` values are set by superadmins. But this is the
input to the **collapse candidate search**, so a crafted value that widens the
filter would surface unintended accounts as collapse targets. *Remediation: use
`ldap3.utils.conv.escape_filter_chars`.*

**6. MEDIUM — no CSRF token on cookie-authenticated writes.**
`/api/provision/*`, `/api/users/*` and `/api/tuples` rely solely on
`SameSite=Lax`. That blocks cross-site POSTs in current browsers, but there is no
defence in depth.

**7. MEDIUM — `redirect_uri` is not allowlisted here.**
`/api/auth/begin` accepts a caller-supplied `redirect_uri` (`main.py:116-121`)
and passes it to Dex. Dex's registered-URI check is the only gate. Impact is
limited — the client secret stays server-side and the exchange re-reads the URI
from server state — but the service should validate it itself.

**8. LOW — upstream response bodies are echoed to the portal.**
`_call` puts the upstream body (truncated to 500 chars) into the 502 `details`
(`libcloud_proxy.py:308`), and the shelled verbs return script `stdout`/`stderr`
truncated to 4000 chars (`libcloud_proxy.py:565-566, 638-639`). No tokens flow
through these paths today, but anything a script or the REST API prints reaches
the browser.

**9. LOW — the temp token cache file has no explicit mode.**
`_token_cache` (`libcloud_proxy.py:643-665`) writes `{user}.json` containing the
access **and refresh** tokens into a `mkdtemp` directory. The directory is 0700,
but the file is written without an explicit `chmod(0o600)`, so its mode follows
the umask. It is removed in a `finally`, but a killed process leaves it behind.

**10. LOW — secrets in subprocess environments.**
`_script_env` (`libcloud_proxy.py:694-741`) passes `LIBCLOUD_OIDC_CLIENT_SECRET`
and the provisioner passwords to the child, readable via `/proc/<pid>/environ`.
The password is handed over only to satisfy `common.sh`'s source-time `:?` check.

**11. LOW — `_used_jti` grows without bound.**
`auth_state.py:35` accumulates consumed pending-token JTIs for the process
lifetime with no pruning. Slow memory growth; entries could expire with the
token's 300 s TTL.

**12. LOW — runtime TLS downgrade toward Nutanix.**
`hot_config` lets `NUTANIX_VERIFY_SSL` be flipped by editing a bind-mounted file,
with no restart and no audit trail (`libcloud_proxy.py:734-738`).

---

## 9. Known limitations

**All state is process memory**, so the service is single-replica only:

| Store | File | Lost on restart |
|---|---|---|
| `_state_store`, `_used_jti` | `auth_state.py:34-35` | In-flight logins |
| `_refresh_store` | `session.py:17` | Dex refresh tokens (cannot revoke on logout) |
| `_pending_users` | `users.py:46` | Federated users not yet linked to LLDAP |
| `_disabled_principals` | `users.py:55` | The "disabled" marker — users re-derive as `viewer` |
| `_token_cache` | `idp_login.py:18` | Provisioner tokens (re-minted on demand) |

The last one deserves emphasis: `_disabled_principals` is the **only** record
that a user was disabled. `disable_user()` clears their OpenFGA tuples, and a
principal with no tuples derives back to the `DEFAULT_ROLE` of `viewer`
(`users.py:48`). After a restart a disabled user is a viewer again, not disabled.

The source flags the intended fixes: move session state to Redis
(`session.py:13-16`, `auth_state.py:48`) and persist pending users and
`linkedIdentities` as LLDAP entries or a side table (`users.py:43-45, 75-76`).

Other gaps:

- `LldapService.list_users` returns `linkedIdentities: []` unconditionally
  (`lldap.py:80`) — LLDAP has no provider-subject attribute mapped, so links are
  only visible for users still in `_pending_users`.
- `_dex_lldap_uid` parses only single-byte protobuf lengths (§5.3).
- The cloud list is hardcoded in three places (§6.3).
