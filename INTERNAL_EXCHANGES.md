# Internal Transactions & HTTP Exchanges — Audit Questionnaire

**Scope.** The complete set of questions to ask about every HTTP / RPC / LDAP /
subprocess transaction between the subsystems of `libcloud_nutanix`. Each
question is anchored to the mechanism that actually exists in source, so it can
be answered by reading code rather than guessing.

**Authority.** Anchors are `path:line` against the current tree. Where the code
and a doc disagree, the code wins (see `ARCHITECTURE.md` §10).

**Companion.** `internal-exchanges.html` renders the key flows as hop-by-hop
traces (method + path + headers + token per hop).

---

## 1. Subsystem inventory

| Concern | Component | Container / address |
|---|---|---|
| Identity (who you are) | LLDAP + Dex | `lldap:3890` (LDAP) / `:17170` (GraphQL), `dex:5556` (OIDC) |
| Session (still signed in) | identity-service (FastAPI) | `identity-service:8766` |
| Authorization (may you) | OpenFGA | `openfga:8080` (HTTP) / `:8081` (gRPC) |
| Datastore | PostgreSQL | `postgres:5432` |
| Secrets (how we reach cloud) | Vault | `vault:8200` |
| Cloud abstraction (doing it) | libcloud.rest + Apache libcloud | `api:8765` |
| Front door | React SPA + nginx | `portal:3000` |
| Operator UI | OpenFGA visualizer (Flask) | `:5050` |
| Backend stand-ins | Nutanix emulator + Stoplight Prism | `:9440-9443`, `:4010-4013` |

### Exchange matrix (who talks to whom)

| Edge | From → To | Bearer / secret | Notes |
|---|---|---|---|
| A/B | Browser ↔ Portal nginx → identity-service | `Cookie: libcloud_portal_sid` (HS256) | `/api/` proxy |
| C | Browser ↔ Dex | (OIDC front channel: `code`, `state`, `code_challenge`) | `/dex/` proxy |
| D | identity-service ↔ Dex | OAuth client secrets, provisioner LDAP creds | token/JWKS/revoke |
| E | identity-service ↔ OpenFGA | provisioner Dex JWT (`aud=libcloud-rest`) | check/read/write |
| F | identity-service ↔ LLDAP | admin bind DN/PW | LDAP read + GraphQL write |
| G | identity-service ↔ libcloud.rest | provisioner Dex JWT + `X-Provider-Connection` | provision replay |
| H | identity-service ↔ Vault | department-orchestrator token | AppRole + credential |
| I | identity-service → `.sh` → Dex/OpenFGA/libcloud.rest | env vars + temp token cache | deprovision/private-pair |
| J | libcloud.rest ↔ Dex | (verifies JWT via JWKS) | token validation |
| K | libcloud.rest ↔ OpenFGA | forwarded Dex JWT | can_connect/use/provision/read |
| L | libcloud.rest ↔ Vault | orchestrator token → AppRole → tenant token | 3-step secret read |
| M/N | libcloud.rest ↔ AWS/Nutanix (emulator) | cloud credential from Vault | driver |
| O | Dex ↔ LLDAP | LDAP bind (admin) | user search |
| P | OpenFGA ↔ Dex | (verifies caller JWT via JWKS) | OIDC authn |
| Q | OpenFGA ↔ PostgreSQL | (internal) | tuples/models/assertions |
| R | OpenFGA visualizer ↔ Dex/OpenFGA | portal OAuth client | read-only, superadmin gate |
| S | bootstrap/operator scripts ↔ everything | root token / scoped tokens / SUPERADMIN_JWT | setup + verify |

---

## 2. Cross-cutting questions (ask about every edge)

An edge is undocumented until all 14 are answered:

1. **Which credential authenticates the caller, and which principal does it name?**
   The system's central ambiguity: identity-service authenticates *to* OpenFGA as
   the provisioner, but the *subject evaluated* is the end user (`fga.py:276-280`).
2. **Synchronous request/response, redirect, callback, or poll?** (OIDC 302
   redirect in `idp_login.py:132`; Nutanix task polling.)
3. **Exact method + path + Content-Type + body schema.** (`/check` vs `/read`
   vs `/write` on OpenFGA; Vault `/sys/policies/acl/*` vs
   `/auth/approle/.../login` vs `/secret/data/...`.)
4. **Which headers carry state?** (`Authorization`, `Cookie`, `X-Provider-Connection`,
   `X-Vault-Token`, `X-Request-ID`, `Accept`.)
5. **Fail-closed or fail-open?** (OpenFGA unreachable → `503` at `fga.py:234-237`,
   vs `enabled=False` → `check()` returns `True` at `fga.py:274`.)
6. **Error status + body shape, and does the other side map it or swallow it?**
   (identity-service wraps REST `502` with upstream JSON at `libcloud_proxy.py:343`;
   `_upstream_reason` digs out the real cloud error.)
7. **Timeouts, retries, cache TTLs per hop.** (30 s httpx; 30 s Vault secret +
   auth-material caches; provisioner token cache with `exp−30s` refresh margin.)
8. **Idempotent / replay-safe?** (OpenFGA tuple dedupe vs. non-idempotent
   AppRole `secret-id` minting.)
9. **Is there a correlation ID through the chain?** (`X-Request-ID` at
   libcloud.rest — does identity-service propagate it into the subprocess?)
10. **What secret crosses this wire, and is it logged / cachable / in `/proc`?**
    (provisioner password → shelled scripts via env, `libcloud_proxy.py:880-901`.)
11. **TLS or plaintext? Loopback / bridge / public interface?**
12. **Who can even reach it?** (`127.0.0.1` vs `0.0.0.0` — portal :3000,
    visualizer :5050, emulators :9440 are public.)
13. **Ordering / startup dependency — is there a race?** (no `depends_on` for
    identity-service → OpenFGA; discovery-latch bug, `fga.py:135-141`.)
14. **Trust boundary or defense-in-depth re-check?** (enforcement points 1/2/3.)

---

## 3. Per-edge questions

### A/B — Browser ↔ Portal nginx ↔ identity-service

- Complete `/api/` surface: is every route in `api.js` mirrored in `main.py`, and
  are there orphaned handlers or uncalled client methods?
- How does nginx route `/api/`, `/dex/`, and the SPA fallback, and what happens to
  an unmatched URL?
- Are `HttpOnly`, `SameSite=Lax`, `Max-Age=28800`, `Secure=False` on
  `libcloud_portal_sid` preserved through the proxy (`session.py`)?
- CORS: origin derived from `PUBLIC_HOSTNAME` (`main.py:52`) — why is it needed at
  all when both live on :3000?
- Which routes are cookie-authenticated vs. public (`/health`), and is any
  state-mutating route reachable without a session?

### C — Browser ↔ Dex (OIDC front channel)

- Exact authorize URL (`/dex/auth?...connector_id=lldap`), and which params carry
  `code_challenge` / `state`?
- Is the authorization **code** ever visible to the SPA or server logs? Where is
  it consumed?
- Does Dex set/read a browser SSO cookie, or re-prompt every time (the logout note,
  `main.py:229-233`)?
- What does Dex render for the `lldap` connector, and how does the SPA know to
  redirect vs. show it?

### D — identity-service ↔ Dex (server-to-server)

- Token exchange: exact `POST /dex/token` body for `authorization_code`, and what
  happens when Dex returns no `id_token` (`main.py:153-155`)?
- JWKS fetch: `GET /dex/keys` — cached? What breaks on Dex's 6-hour key rotation
  (the `RefreshUnknownKID` pin)?
- ID-token validation: which claims are required (`iss/aud/exp/sub`) and which are
  *not* checked?
- Provisioner login (no callback server): how is the code read from the `302
  Location` (`idp_login.py:132-137`), and why is `127.0.0.1:8766/oauth/callback`
  never actually connected to?
- Refresh: when is `grant_type=refresh_token` called, and what happens when refresh
  fails (`idp_login.py:79-85`)?
- Revoke: `POST /dex/token/revoke` on logout — best-effort, and does Dex `memory`
  storage make it moot on restart?

### E — identity-service ↔ OpenFGA

- Exact REST paths for `check`/`read`/`write`/`list-users`/`list-objects`/`expand`/
  `changes`/`authorization-models`/`assertions`.
- Why does `/read` require a full-store read + client-side filter
  (`fga.py:470-478`), and what does that cost at scale?
- What bearer token is sent, and how does the **subject** (`user:<principal>`)
  differ from the **caller** authenticated by the bearer?
- When `enabled` is false, which callers get `allowed=True` / full capabilities
  (`fga.py:365-374`) and which get `503` — is that split intentional?
- What triggers `/write` (assign_role/clear_roles/create_company/create_department)
  and who is authorized to reach it (the "any `libcloud-rest`-audience token can
  write" finding)?

### F — identity-service ↔ LLDAP

- Which operations use LDAP (`ldap3`) vs. GraphQL (`POST /auth/simple/login` then
  `POST /api/graphql`)?
- Admin bind DN/PW, and how the multi-valued `role` attribute is read/written
  (`lldap.py`)?
- How are the 8 seeded + 30 pool users enumerated, and how does an LLDAP `uid`
  map to an OpenFGA principal (the `int-` stripping, `main.py:71-79`)?

### G — identity-service ↔ libcloud.rest (provision replay)

- Exact ordered call sequence: `auth/me` → `connections:test` → `locations` →
  `sizes` → `images` → `nodes` → `subnets` → `POST nodes` (`libcloud_proxy.py:452-484`)?
- How is `X-Provider-Connection` serialized (compact JSON) and which fields are in
  it — and which are **not** (no credentials, `_headers` at `libcloud_proxy.py:314`)?
- What bearer token is presented, and what `aud` — does libcloud.rest see the end
  user or the provisioner?
- How is `auth_binding` (tenant → Vault secret) chosen when a user holds roles on
  several tenants of one cloud (`fga.py:582-610`)?
- How are per-category resource lists fanned out, and what does a `501` (unsupported
  capability) degrade to (`libcloud_proxy.py:408-411`)?
- For deprovision/private-pair: what is passed into the shell subprocess (env,
  token cache), and how are secrets exposed via `/proc/<pid>/environ`?

### H — identity-service ↔ Vault (department flow, new)

- Which token authenticates identity-service to Vault (department-orchestrator),
  and what is its policy scope vs. the libcloud.rest orchestrator token?
- Exact calls in `create_department_identity` (`vault.py:73-115`): policy `PUT`,
  role `POST`, `role-id` GET, `secret-id` POST, then the plaintext KV round-trip —
  why is `secret_id` persisted back into KV despite being write-only in Vault?
- Ordering/atomicity if Vault succeeds but OpenFGA `create_department` fails
  halfway (`main.py:543-551` fire-and-forget) — is the department left
  half-provisioned?
- How are `read_department_credential` / `rotate_department_credential` gated
  (OpenFGA `can_manage_credentials` on `tenant:<dept>`, `main.py:554-569`), and is
  the credential value ever echoed to the browser?

### I — identity-service → subprocess scripts (→ Dex/OpenFGA/libcloud.rest)

- Why are deprovision/private-pair delegated to `.sh` scripts, and which side is the
  single source of truth for each sequence?
- What is the env contract (`IDP_TOKEN_CACHE_DIR`, `PROVISION`, `VM_*`,
  `LIBCLOUD_*`) and how does the script's own OpenFGA re-check duplicate the
  service's check?
- How is stdout/stderr truncated (`[-4000:]`, `libcloud_proxy.py:718-719`) and
  returned, and does that leak anything?

### J/K/L — libcloud.rest ↔ Dex / OpenFGA / Vault

- **J** — how is the bearer decoded (JWKS, `iss`, `aud=libcloud-rest`), and how is
  `sub` mapped through `principal_map.json` / legacy aliases to a `user:`?
- **K** — exact order in `authorize_connection` (`policy.py:134-168`): scope →
  provider allowlist → credential policy → `can_connect` → `can_use` →
  `can_provision`/`can_read` → `list_objects` for `vault_user`. Which run when
  `fga.enabled` is false?
- **K** — what status does an unmapped route produce (`policy_unknown_operation`
  500), and is fail-closed the intended default?
- **L** — the Vault 3-step (`vault_client.py`): (1) `GET secret/data/libcloud-vault-auth/<vault_user>`
  with orchestrator token → (2) `POST /auth/approle/login` → (3) `GET secret/data/libcloud/<binding>`
  with tenant token. Which token impersonates which tenants, and what are the three
  cache TTLs (30 s / 30 s / lease)?
- **L** — when Vault is configured but a secret is missing, does libcloud.rest
  fall back to env creds or fail closed with `503` (`credentials.py:99-103`)?

### M/N — libcloud.rest ↔ AWS / Nutanix (and the emulator)

- **M** — driver auth: per-request Basic vs. session-cookie (`POST <login_path>` →
  replay `Set-Cookie`), and the `nutanix:<host>:<port>` session-cache TTL.
- **M** — task lifecycle: POST → `202` → poll `GET .../tasks/{id}` until `SUCCEEDED`;
  poll interval/timeout, and what the *emulator* does differently (fixed 200/400 ms
  timers, no failure paths).
- **M** — is `ETag`/`If-Match` sent, and does the emulator's lack of `ETag`
  silently skip optimistic concurrency?
- **N** — emulator fidelity: what is mocked (auth no-op, fake `NTNX_IAM_SESSION`
  vs real `NTNX_IGW_SESSION`, `stop_node` no-op), and which would hide a bug on a
  real Prism cluster?

### O — Dex ↔ LLDAP

- Bind DN/PW + search filter (`dex/config.yaml:87-97`), and how `uid→sub`,
  `mail→email`, `cn→name` map.
- On an LLDAP outage, does Dex fail the login or accept stale state (`memory`)?

### P — OpenFGA ↔ Dex

- How does OpenFGA validate the caller JWT (issuer `http://dex:5556/dex`, audience
  `libcloud-rest`), and why was `v1.16.0` (PR #3101 `RefreshUnknownKID`) load-bearing?
- Since OIDC authn is signature/iss/aud only, **what authorizes writes** (any
  authenticated user can self-grant)?

### Q — OpenFGA ↔ PostgreSQL

- What lives there (tuples/models/assertions), and is it reachable only via the
  OpenFGA API or also directly by other components?
- Real datastore volume name (the `openfga-data` vs
  `openfga_postgres_openfga-pg-data` doc drift)?

### R — OpenFGA visualizer ↔ Dex / OpenFGA

- How does it do its own SSO login (callback `:5050`), and is its OpenFGA access
  genuinely read-only + superadmin-gated?
- Why Werkzeug dev server on `0.0.0.0:5050`?

### S — bootstrap / operator scripts ↔ everything

- Chain of trust order (LLDAP → Dex superadmin login → `SUPERADMIN_JWT` → OpenFGA
  bootstrap → Vault bootstrap) — which step is the gate everything refuses to run
  without?
- How do `idp_login.py`, `set_tenant_credentials.py`, `vault_bootstrap.py`
  authenticate, and which token do they present (root vs. scoped)?
- Where is each generated secret written (`.env`, `fga.env`, `dex.env`, `vault.env`)
  and which are git-tracked?

---

## 4. Highest-value questions (start here)

1. **Which principal does each hop evaluate, and which credential authenticates the
   caller?** (The provisioner-vs-end-user split is the crux.)
2. **For every `enabled=False` / `except Exception` path, does it fail open or
   closed?** (OpenFGA discovery latch, Vault fallback, `_derive_authz` allow-all.)
3. **Exact wire format** of `X-Provider-Connection`, the OpenFGA `check` body, and
   the Vault 3-step — can a client forge any of them?
4. **Does the same `auth_binding`/tenant string stay consistent** across LLDAP uid
   → Dex `sub` → OpenFGA `user:` → Vault `libcloud-<binding>`?
5. **Which secrets cross which edge in cleartext (no TLS), and which land in git,
   logs, or `/proc`?**
