# OpenFGA RBAC Visualizer — Architecture & Implementation Notes

A single-file Flask dashboard that visualizes the complete RBAC flow of the
project's live OpenFGA store. It has its **own SSO authentication screen**
(Dex authorization-code flow) and makes every OpenFGA call **as the
logged-in user**. Everything below describes what was actually built,
verified, broken, and fixed during implementation.

---

## 1. Overview

- One Python file (`app.py`, ~1642 lines) contains the entire backend **and**
  the frontend (HTML/CSS/JS embedded as string constants — no templates, no
  build step).
- Frontend uses D3.js v7 (vendored at `static/d3.v7.min.js`, CDN fallback).
- Backend proxies a live OpenFGA server: fetches the authorization model and
  all tuples, derives a graph, and fans out live `check` calls to show how
  permissions actually propagate.
- Authentication is a real login screen backed by the project's Dex SSO; the
  issued JWT is verified (JWKS, issuer, audience, expiry, nonce) and kept in
  a server-side session. No token files, no shared credentials, no silent
  pickup of previous authentication (explicit user requirement).

### Project layout

```
openfga_visualized/
├── app.py                 # backend + embedded frontend (everything)
├── requirements.txt       # flask, requests, pyjwt[crypto], pyyaml
├── Dockerfile             # container image for the visualizer
├── docker-compose.yml     # compose service (openfga-visualizer)
├── .env                   # env overrides (PUBLIC_HOSTNAME, OIDC_ISSUER, …)
├── README.md              # run/config instructions
├── ARCHITECTURE.md        # this file
├── static/d3.v7.min.js    # vendored D3 v7.9.0 (offline capable)
├── static/vis-network.min.js  # vendored vis-network (Model Graph tab)
├── .flask_secret          # auto-generated Flask session key (mode 0600)
└── .venv/                 # python virtualenv
```

Run: `.venv/bin/python app.py` → http://${PUBLIC_HOSTNAME:-localhost}:5050

---

## 2. Work done (chronological)

1. **Read the task** (`prompt.md`): several visualization options were
   sketched; the chosen deliverable was the "complete runnable dashboard" —
   a single Python file connecting to the live OpenFGA server, rendering the
   hierarchy with D3, and showing permission propagation.
2. **Gathered ground truth from the parent project**
   (`/home/ubuntu/libcloud_nutanix`): `openfga_authorization_model.md`,
   `openfga_tuples_transcribed.md`, `openfga_postgres/.env`,
   `dex/config.yaml`. Established: store `01KXFQ6JWFD2MZKFDFSHYNNNXE`,
   model `01KXWWZY8424AMK2B443FH7TQ0`, OpenFGA on `:8080` with OIDC authn,
   issuer `http://dex:5556/dex`, audience `libcloud-rest`.
3. **Built v1**: Flask backend + embedded D3 frontend, venv, vendored D3,
   requirements, README. Verified against the live store using the project's
   superadmin JWT (52 tuples, 26 nodes, single root `platform:main`).
4. **Reworked authentication** (user requirement: separate application, own
   login screen, must NOT pick up previously authenticated credentials):
   removed all token-file/env pickup, implemented the Dex authorization-code
   flow, server-side sessions, login/logout routes, and 401→re-login
   handling throughout.
5. **Registered the dashboard as an OIDC client callback** in
   `dex/config.yaml` (added four port-5050 redirect URIs to the existing
   `libcloud-rest` client; user-approved) and restarted the `dex` container.
6. **Fixed a production bug found on first real login**: 500s ("invalid
   response from server" in the UI) caused by reading the Flask `session`
   from ThreadPoolExecutor worker threads. Fixed by capturing the token in
   the request thread and passing it explicitly.
7. **Built and then reverted** a "Re-authenticate with `prompt=login`"
   feature, at the user's explicit request ("ignore this statement").

---

## 3. System context

```
 browser
    │  ① SSO login (authorization-code flow)
    ▼
 ┌─────────────────────┐        ┌──────────────────────────────┐
 │ RBAC Visualizer     │  ②     │ Dex (:5556)                  │
 │ app.py (:5050)      │◄──────►│ issuer http://dex:5556/dex   │
 │ Flask, threaded     │ token  │ connectors: LLDAP, Google,   │
 └─────────┬───────────┘ verify │            GitHub            │
           │ ③ bearer JWT       └──────────────────────────────┘
           ▼
 ┌─────────────────────┐
 │ OpenFGA (:8080)     │  authn: oidc, issuer = Dex,
 │ store libcloud-rest │  audience = **libcloud-rest** (pinned)
 └─────────────────────┘
```

Key facts that shape the design:

- OpenFGA validates bearer tokens against `OPENFGA_AUTHN_OIDC_ISSUER` and
  `OPENFGA_AUTHN_OIDC_AUDIENCE=libcloud-rest`
  (`openfga_postgres/.env:53-55`). A token issued for **any other client id**
  is rejected with `401 {"code":"invalid_claims"}`. → The dashboard must sign
  users in through the existing `libcloud-rest` Dex client; it cannot have
  its own client id without also changing OpenFGA.
- The store holds **68 tuples** (41 wiring + 27 grants), **9 types**
  (`user`, `platform`, `tenant`, `libcloud_api`, `provider`,
  `resource_class`, `aws_region`, `nutanix_cluster`, `vault_user`), model schema 1.1.
- The authorization model is immutable/versioned; the store contains 4
  historical models, only `01KXWWZY8424AMK2B443FH7TQ0` is pinned/active.
- Dex static clients live in `dex/config.yaml` and are loaded **only at
  startup** — any redirect-URI change requires `docker restart dex`.

---

## 4. Backend architecture (`app.py`)

### 4.1 Configuration

All env-overridable, defaults match the project:

| Variable | Default | Purpose |
|---|---|---|
| `OPENFGA_API_URL` | `http://localhost:8080` | OpenFGA base URL |
| `OPENFGA_STORE_ID` | `""` (auto-discover) | store — empty = look up by `OPENFGA_STORE_NAME` |
| `OPENFGA_MODEL_ID` | `""` (auto-discover) | model — empty = latest model in the store |
| `OPENFGA_STORE_NAME` | `libcloud-rest-store` | store name used for auto-discovery |
| `OIDC_ISSUER` | `http://dex:5556/dex` | Dex issuer (canonical in-container URL) |
| `OIDC_CLIENT_ID` | `libcloud-rest` | must equal OpenFGA's audience |
| `OIDC_CLIENT_SECRET` | read from `../dex/config.yaml` | client secret |
| `OIDC_SCOPES` | `openid profile email groups` | requested scopes |
| `DEX_CONFIG` | `../dex/config.yaml` | where to read the secret |
| `DEX_BROWSER_URL` | `""` | browser-facing Dex URL (via portal nginx) for OAuth redirects |
| `OAUTH_REDIRECT_URI` | derived from request host | must be registered in Dex |
| `SUPERADMIN_EMAIL` | `superadmin@libcloud.local` | only this account may sign in (fallback gate) |
| `SUPERADMIN_SUB` | `""` | exact Dex `sub` of the superadmin (strongest gate) |
| `LIBCLOUD_FGA_PATH` | `../openfga_postgres/model/libcloud.fga` | DSL file for the Model Graph tab |
| `PUBLIC_HOSTNAME` | `localhost` | used to derive OIDC_ISSUER / DEX_BROWSER_URL |
| `FLASK_SECRET_KEY` | generated into `./.flask_secret` | cookie signing |
| `PORT` | `5050` | listen port |

Constants: `CACHE_TTL = 30s`, `CHECK_WORKERS = 8`,
`SESSION_LIFETIME = 12h`.

### 4.2 OpenFGA client layer

- `fga_get` / `fga_post` — thin wrappers with 15/30 s timeouts. They raise:
  - `FGAAuthError` on **401** (token rejected → force re-login),
  - `FGAError` on any other non-200 or connection failure (→ HTTP 502 JSON).
- `_headers(token=None)` — builds the Authorization header. **The token must
  be passed explicitly when calling from worker threads** (see §8, lesson 2).
- `get_model()` / `get_tuples()` — cached for 30 s in a module-level dict.
  `get_tuples` walks the `read` endpoint's `continuation_token` pagination
  (100/page) and normalizes to `{user, relation, object, timestamp}`.
- `fga_check(user, relation, object, token=None)` — POST `/check`; pins
  `authorization_model_id` only when `MODEL_ID` is set (auto-discovery omits it).
- `fga_expand(object, relation)` — POST `/expand` for derivation trees; likewise
  pins `authorization_model_id` only when `MODEL_ID` is set.

### 4.3 Graph derivation (`build_graph`)

Tuples are split into two classes:

- **Wiring** — `user` field is an object (e.g. `platform:main platform
  tenant:aws`): becomes a hierarchy edge `parent → child` labeled with the
  relation. Userset refs (`obj#relation`) are normalized to their object.
- **Grants** — `user` field starts with `user:`: becomes a role grant
  `(user, relation, object)`.

Roots = objects that never appear as a child (here: just `platform:main`).
Result: `{nodes, hierarchy, grants, roots}` — the single source for both the
tree view and the object/user pickers.

### 4.4 Model summarization

`summarize_rewrite()` renders OpenFGA rewrite ASTs as short strings:
`this` → `direct`; `computedUserset` → `= relation`; `tupleToUserset` →
`parent -> relation`; `union`/`intersection`/`exclusion` → `(a U b)` /
`(a & b)` / `(a - b)` (recursive over `children`). `model_summary()`
additionally extracts `metadata.relations[*].directly_related_user_types`
(the types writable via tuples) — note this lives in **metadata**, not in
the rewrite rule (see §8, lesson 4).

### 4.5 API surface

All `/api/*` routes are wrapped by `@require_auth` (valid dashboard session
or `401 {auth_required:true}`) and `@api` (maps `FGAAuthError` → 401 +
session drop, `FGAError` → 502 JSON).

| Endpoint | Purpose |
|---|---|
| `GET /api/config` | store/model/api_url + logged-in user identity |
| `GET /api/model` | model id, schema, per-type relation summaries |
| `GET /api/tuples` | all tuples (paginated read) |
| `GET /api/graph` | derived nodes / hierarchy / grants / roots |
| `GET /api/check` | single check → `{allowed, resolution}` |
| `GET /api/expand` | derivation tree for `object#relation` |
| `GET /api/matrix?object=` | users × relations grid of live checks |
| `GET /api/user_permissions?user=` | everything a user can do, grouped by object |
| `GET /api/model_graph` | store/type/relation graph derived from the `libcloud.fga` DSL |
| `GET /api/model_dsl` | raw `libcloud.fga` DSL source + type count |

The last two **fan out**: matrix runs `len(users) × len(relations)` checks,
user_permissions runs `len(objects) × len(relations-of-type)` checks, both
through a `ThreadPoolExecutor(max_workers=8)`. The session token is captured
once in the request thread and passed into every worker call. Per-call
failures degrade gracefully (matrix cell `null`, permission omitted) instead
of failing the whole request.

---

## 5. How the visualization is implemented

The frontend is a single embedded page (`HTML_PAGE`, no Jinja — served as a
static string so JS braces never collide with templating). Five tabs —
Hierarchy, Permission Matrix, Check, Model, and Model Graph (a vis-network
force-directed graph built from the `libcloud.fga` DSL via
`parse_fga_dsl`/`build_model_graph`) — all data fetched at boot (`/api/config`,
then `/api/graph` + `/api/model` in parallel).

### 5.1 Hierarchy tab (D3 collapsible tree)

Data pipeline:

1. `buildForest()` builds a nested JS object from `/api/graph`:
   - `childMap`: parent → children from wiring edges;
   - `grantsByObj`: object → its user grants, appended as leaf children when
     "show role grants" is on;
   - recursion carries an **ancestor set as a cycle guard** (shared nodes
     like `libcloud_api:main` are fine — they appear once per parent; true
     cycles are cut);
   - an **occurrence counter** marks objects appearing under multiple
     parents → rendered with a purple `⇄ shared` tag.
2. `renderTree()` wraps the forest in a synthetic root when needed, runs
   `d3.hierarchy(data, d => d.collapsed ? null : d.kids)` and
   `d3.tree().nodeSize([24, 210])` (tidy tree, horizontal).
3. Rendering:
   - links: `d3.linkHorizontal()` cubic curves, class `.link`;
   - **edge labels**: the relation name at the link midpoint
     (`(s.y+t.y)/2`, `(s.x+t.x)/2 − 4`), small italic — this is what makes
     the *flow* readable (`platform`, `parent`, `tenant`, `provider`,
     `bound`, `owner`, …);
   - nodes: circle filled with the per-type color (white for leaves),
     label = object name (type prefix stripped), users in gray;
   - collapsed nodes show `(+N)` descendant counts.
4. Interaction:
   - click a node with children → toggles its `collapsed` flag and re-renders
     (full re-render is fine at this size, ~18 objects + grants);
   - pan/zoom via `d3.zoom()` (scale 0.25–3) applied to a wrapper `<g>`;
     the zoom behavior is attached **once** (guarded by a `__zoomInit` flag)
     — attaching it on every re-render stacked listeners and broke panning;
   - controls: grants toggle, "Expand all", "Collapse below depth 2"
     (`setCollapsed(d, depth, 2)`);
   - SVG height is recomputed per render from the tree's x-extent; a color
     legend maps all 9 types.

### 5.2 Permission Matrix tab

- Object picker (grouped by type via `<optgroup>`) → `/api/matrix`.
- The grid renders **every cell as a live check result**:
  - `●` solid green — a **direct tuple** exists (`direct` list from the
    store), bold border;
  - `○` pale green — **inherited/computed** through the model (check true,
    no tuple) — this cell *is* the permission propagation;
  - `·` gray — denied.
- Column headers are vertical (`writing-mode: vertical-rl`) to fit all 12
  tenant relations.
- Example verified live: `superadmin` on `tenant:aws` shows
  `can_assign_owner ○` (inherited via `platform → can_manage_platform`) and
  `can_read ○` (via `global_reader`) but **not** `can_provision` — exactly
  the model's intent, visible at a glance.

### 5.3 Check tab

- Three inputs with `<datalist>` autocomplete (users, relations from the
  model, objects) → `/api/check` → green/red ALLOWED/DENIED panel with the
  server's `resolution` string.
- **"Show derivation"** → `/api/expand`, rendered by a recursive
  `expandNode()`: node name in bold; `union`/`intersection`/`difference`
  become nested labeled lists; leaves render chips for `users`,
  `computed: obj#rel`, and `tupleset -> userset` (tupleToUserset). This
  answers "*why* is this allowed?" — e.g. `tenant:aws#can_read` expands to
  viewer/admin/owner ∪ `platform → global_reader`.
- **"Everything a user can do"** → `/api/user_permissions`: objects with any
  allowed relation listed with relation chips, plus a summary
  ("access on N of M objects").

### 5.4 Model tab

One card per type: relation name, the summarized rewrite rule (monospace),
and chips for directly-assignable types. The header explains the notation
(`direct`, `= alias`, `parent -> relation`, `U`, `&`, `-`).

### 5.5 Shared frontend behavior

- `api()` fetch helper: **401 → `window.location = '/login'`** (any expired/
  dropped session returns to the auth screen automatically); other errors go
  to a red banner.
- Type colors: platform purple, tenant blue, api cyan, provider green,
  resource_class amber, backends red/pink, user gray.
- D3 loads from `/static/d3.v7.min.js`; a one-line `document.write` fallback
  switches to the CDN if the vendored file is missing. The Model Graph tab loads
  `vis-network` from the vendored `/static/vis-network.min.js` with the same
  CDN-fallback pattern.

---

## 6. SSO implementation (features in detail)

### 6.1 Requirements (from the user, twice clarified)

- The dashboard is a **separate application** → it gets its **own
  authentication screen**.
- It must **not pick up any previously authenticated credential** — no token
  files, no env tokens, no shared sessions. (The v1 behavior of reading
  `generated/tokens/superadmin.jwt` was explicitly rejected and removed.)
- **Sign-in is hard-gated to the LLDAP superadmin account only.** Any other
  connector user (Google, GitHub) or any non-superadmin LLDAP user is denied at
  `/callback`. The gate is `is_superadmin()` (app.py), which matches
  `SUPERADMIN_SUB` (exact Dex `sub`) or, when unset, `SUPERADMIN_EMAIL`
  (`superadmin@libcloud.local`); the rejection logs the offending `sub`/`email`
  and redirects to
  `/login?error=only the LLDAP superadmin account may sign in`.

### 6.2 Flow

```
GET /            no session ──► 302 /login
GET /login       branded sign-in page (own screen, dark card)
GET /auth/start  session.clear(); generate state+nonce (stored in the
                 Flask session); 302 to Dex /dex/auth with
                 client_id=libcloud-rest, redirect_uri, scope, state, nonce
   │             Dex renders its connector page (LLDAP / Google / GitHub) —
   │             but only a superadmin login survives the callback gate below
   ▼
GET /callback    verify state (one-time, popped); exchange code at
                 /dex/token with HTTP-Basic client_id:client_secret;
                 verify id_token signature via Dex JWKS (PyJWKClient,
                 RS256) + issuer + audience + exp + **nonce**;
                 **enforce is_superadmin(claims)** — any non-superadmin
                 (incl. Google/GitHub) is rejected here
   ▼
 server-side session created; cookie carries only an opaque sid
```

### 6.3 Token & session storage

- `_sessions`: in-memory dict `sid → {id_token, user{name,email}, expires}`;
  expiry = `min(token exp, now + 12h)`.
- The browser cookie (Flask signed session; HttpOnly — modern browsers
  default SameSite to Lax, which allows the top-level GET redirect back from
  Dex) carries only the 24-byte random `sid` — **the JWT never touches the
  browser or disk**. Cookie size limits are a non-issue.
- `app.secret_key` comes from `FLASK_SECRET_KEY` or is generated once into
  `./.flask_secret` (mode 0600), so restarts don't invalidate cookies…
  …but sessions are in-memory: **an app restart logs everyone out**
  (deliberate, acceptable, documented).
- `current_session()` validates presence + expiry; expired entries are
  dropped (`drop_session()`).

### 6.4 Client identity

- Client **id** is `libcloud-rest` — forced by OpenFGA's pinned audience
  (§3). Using any other client reproduces `invalid_claims`.
- Client **secret** is read at request time from `../dex/config.yaml`
  (`staticClients` entry matching the id) via PyYAML — no secret is
  duplicated in source, and it stays in sync when `dex_bootstrap.py`
  regenerates it. `OIDC_CLIENT_SECRET` overrides.
- OIDC endpoints come from the issuer's
  `/.well-known/openid-configuration` (cached), with hardcoded
  `{issuer}/auth|token|keys` fallbacks.

### 6.5 Callback URL handling

- `redirect_uri()` = `OAUTH_REDIRECT_URI` env, else
  `request.host_url + '/callback'` — whatever host spelling the user typed
  is used, and **must exactly match** a registered URI in Dex.
- Registered in `dex/config.yaml` under `libcloud-rest` (with an explanatory
  comment):
  `http://localhost:5050/callback`, `http://127.0.0.1:5050/callback`,
  `http://rocky96:5050/callback`; then `docker restart dex`.

### 6.6 Failure & lifecycle handling

- `/callback` rejects: IdP error param → login page with the error; bad/
  reused state → `invalid_state`; missing code; token exchange failure →
  `token_exchange_failed`; missing id_token; JWKS/JWT errors (bad signature,
  wrong iss/aud, expired, bad nonce) → shown on the login page. Dex
  unreachable → `sso_unreachable`.
- Upstream 401 at any later point (`FGAAuthError`) → session dropped
  server-side, API returns `401 {auth_required:true}`, JS redirects to
  `/login`. This is the re-login path for expired tokens.
- `/logout` drops the server session → `/login`. A "sign out" link sits in
  the dashboard header; the header also shows "signed in as \<name\> · store
  … · model …".
- State and nonce are single-use (`session.pop` in the callback) —
  replaying a callback URL fails with `invalid_state`.

### 6.7 The reverted experiment

A "↻ Re-authenticate" button using `prompt=login` (Dex v2.41 accepts it and
would force the credential prompt despite a live SSO session) was
implemented, verified at the Dex level, then **fully reverted** at the
user's request. Nothing of it remains in the code.

---

## 7. How the connections were tested

No browser/Node was available, so testing combined curl, the live servers,
Flask's in-process test client, and a JS parser (esprima via pip).

### 7.1 OpenFGA connection (live, before SSO)

- API shape verified with curl + the project's superadmin JWT:
  `POST /stores/{id}/read` pagination (`continuation_token`), model fetch.
- Graph counts asserted: 26 nodes, 39 wiring edges, 9 grants, root
  `platform:main`. (The SuperAdmin owner-grants on both tenants were
  deliberately removed — superadmin is a control-plane role that can read
  everything but cannot provision; see the comment in
  `openfga_postgres/openfga_bootstrap.py`.)
- **RBAC semantics asserted against the live check endpoint:**
  - `aws-viewer can_read tenant:aws` → true; `can_provision` → false;
  - `superadmin can_read tenant:aws` → true (global_reader),
    `can_provision` → false, `can_assign_owner` → true (platform chain);
  - `aws-owner`: all tenant relations except `can_assign_owner`/`platform`;
  - `aws-compute-admin can_provision aws_region:aws` → **true** (per-class
    role reaches the backend through `bound`), and
    `can_provision resource_class:aws-network` → **false** (class isolation);
  - `ntnx-owner` → nothing on AWS objects (tenant isolation);
  - `ntnx-compute-viewer` → viewer+can_read only on
    `resource_class:nutanix-compute` and can_read on the cluster.
- Matrix endpoint cross-checked for `tenant:aws` and
  `resource_class:aws-compute` (users × relations grids).

### 7.2 Dex connection

- Discovery doc fetched: issuer/auth/token/jwks endpoints confirmed.
- **redirect_uri acceptance**: requested `/dex/auth` with the dashboard's
  client_id + callback → got the Dex connector page (`<title>dex</title>`,
  LLDAP/Google/GitHub links) instead of an error page — proves the new
  redirect URIs were registered (before the config edit this would fail).
- `prompt=login` support probed the same way (accepted; feature later
  reverted).

### 7.3 Auth flow (curl against the running app)

- `GET /` unauthenticated → `302 → /login`.
- `GET /login` → 200, own sign-in page.
- `GET /api/config` unauthenticated → `401 {"auth_required":true}`.
- `GET /auth/start` → 302 to Dex with correct client_id, redirect_uri,
  scopes, state, nonce; following it yields the Dex connector page.

### 7.4 Auth flow (Flask test client, in-process)

- bad `state` on `/callback` → `?error=invalid_state`;
- valid state + bogus code → `?error=token_exchange_failed`;
- injected fake session → `/` serves the dashboard, `/api/config` returns
  the user identity;
- upstream 401 with the fake token → `401 auth_required` **and** the
  server-side session is dropped;
- expired session entry → 401.

### 7.5 Frontend

- The embedded JS (11.9 KB) was extracted and parsed with **esprima**
  (pure-Python ES parser installed in the venv) after every edit — Node was
  not installed, so this substituted for a browser syntax check.
- Static asset: `/static/d3.v7.min.js` → 200.

### 7.6 The 500 bug (found by the user's first real login)

- Symptom: banner "invalid response from server" (frontend's fallback when
  an API returns non-JSON). Log showed **10 × HTTP 500** with
  `RuntimeError: Working outside of request context` at `api_matrix`.
- Root cause: `ThreadPoolExecutor` workers called `fga_check` → `_headers()`
  → `get_token()` → Flask `session` proxy, which exists only in the request
  thread.
- Fix: capture `tok = get_token()` in the request thread; pass
  `token=tok` through `fga_check`/`fga_post`/`_headers`.
- Regression test: monkeypatched `get_model`/`get_tuples` with canned data,
  injected session, drove `/api/matrix` and `/api/user_permissions` through
  the real thread pool → 200 JSON, per-worker `FGAAuthError` degrades to
  `null` cells instead of crashing.

---

## 8. Lessons learned

1. **OpenFGA's OIDC audience is pinned** (`OPENFGA_AUTHN_OIDC_AUDIENCE`).
   `401 invalid_claims` almost always means "token issued for the wrong
   client id" (or expired). Any new app must reuse the pinned client
   (`libcloud-rest`) or OpenFGA must be reconfigured — there is no way
   around it from the client side.
2. **Flask's `session` is request-thread-local.** The moment checks were
   fanned out to a `ThreadPoolExecutor`, every worker call 500'd. Capture
   request-scoped values (tokens, user ids) before entering threads and pass
   them explicitly. The generic frontend message ("invalid response from
   server") hid this; the server log had the real traceback — check it
   first.
3. **Token files expire silently.** Reading `superadmin.jwt` from disk works
   until `exp` passes, then everything fails with `invalid_claims`. A real
   login flow is the only durable fix for an interactive tool.
4. **The Explorer's "computed" label is a UI quirk**: it looks for
   `directly_related_user_types` on the rewrite rule, but OpenFGA stores it
   under `metadata.relations`. Our model tab reads the correct location.
5. **Dex static clients load at startup only** — `docker restart dex` after
   every config change. And `redirect_uri` matching is exact-string: scheme,
   host spelling, port, and path must all be registered.
6. **Shell footgun**: `pkill -f "python app.py"` also matched the wrapping
   shell's own command line and killed the session's command. Kill by
   listening-port PID (`ss -ltnp`) instead.
7. **State/nonce must be single-use** (`session.pop`) or callback URLs
   become replayable.
8. Attaching `d3.zoom()` inside a re-render function stacks behaviors and
   breaks panning — attach once, guard with a flag.
9. The tuple count drifted (66 documented → 52 live): orphaned
   auto-provisioned `int-viewer-*` tuples were cleaned up at some point.
   Always build from live reads, never from transcribed docs.

---

## 9. Characteristics & limitations

- **Single process, Werkzeug dev server** (`threaded=True`) — fine for a
  team tool on localhost/LAN; not hardened for public exposure (no TLS, dev
  server). Bind is `0.0.0.0`; restrict with a firewall or reverse proxy.
- **In-memory sessions**: restart = all users logged out; not horizontally
  scalable (would need a shared session store).
- **30 s cache** on model+tuples: tuple edits appear within 30 s; checks are
  always live (never cached).
- **Fan-out cost**: matrix = users × relations checks (10 × 12 = 120 for
  tenants), user_permissions = Σ objects × relations-of-their-type (≈140 for
  the current model) — parallelized over 8 workers, typically sub-second
  against a local OpenFGA.
- **Checks evaluate the tuple subject, not the caller**: OpenFGA's OIDC
  authn only authenticates the caller (any valid Dex token for the pinned
  audience may call the API); a check for `user:aws-viewer` returns that
  user's permissions regardless of who is signed in. So every logged-in
  user sees the same matrix.
- Shared objects in the tree are **duplicated per parent** (tree layout, not
  a graph layout) and tagged `⇄ shared`.
- Token refresh: none — when the Dex token expires (or OpenFGA 401s), the
  session is dropped and the user logs in again. Refresh tokens were
  deliberately not used (keeps "no lingering credentials" simple).
