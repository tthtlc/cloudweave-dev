# Portal (React SPA) Architecture

This is the reference for the `server/` React portal — the browser-facing front
door of the whole libcloud stack. It covers what gets built, how it is served,
how it reaches the backend, the route/role model, the browser-side auth flow,
and the security properties (and caveats) of shipping a static bundle.

Source is the only truth; every claim below cites file and line.

---

## 1. What it is

A single-page **Create-React-App** application that is compiled once to a static
bundle and served by **nginx**, with no Node runtime in the runtime image.

| Concern | Detail | Source |
|---|---|---|
| Framework | CRA via `react-scripts` `5.0.1`, React `^18.2.0`, `react-router-dom` `^6.22.3` | `package.json:9-13` |
| Build | `npm ci --legacy-peer-deps` then `npm run build` (`react-scripts build`) | `package.json:22,24`, `Dockerfile:22-24` |
| Build stage | `node:18-alpine` — the only place node/npm exist | `Dockerfile:4` |
| Runtime stage | `nginx:alpine`; only `/app/build` is copied in as `/usr/share/nginx/html` | `Dockerfile:26-27` |
| Runtime process | `nginx -g 'daemon off;'` (or via the entrypoint) | `Dockerfile:59`, `docker-entrypoint.sh:32` |
| Port | nginx listens on **3000** | `Dockerfile:31`, `Dockerfile:58` |

The runtime image contains **no node/npm** — it is a static file server. Any
JS executed runs in the *browser*, against the pre-built bundle.

---

## 2. The single front door

This is the most important architectural fact about the portal: **the browser
talks to exactly one origin — the portal's nginx on port 3000.** Everything the
SPA needs (`/api/*` and `/dex/*`) is reverse-proxied by nginx to the internal
Docker services. The nginx config is not a file in the repo; it is generated
inline by a `printf` at image build time (`Dockerfile:30-57`):

| `location` | `proxy_pass` | Purpose |
|---|---|---|
| `/api/` | `http://identity-service:8766` | All portal/identity API calls (`Dockerfile:34-40`) |
| `/dex/` | `http://dex:5556` | All Dex OIDC endpoints — login form, authorize, token, keys (`Dockerfile:44-50`) |
| `/` | (static root + `try_files $uri /index.html`) | SPA fallback so client-side routes like `/auth/callback` hit `index.html` (`Dockerfile:53-56`) |

Notes on the mechanics:

- The `/dex/` block has `proxy_pass http://dex:5556;` with **no trailing slash**,
  so the original request path is preserved. A browser request to
  `/dex/auth?…` is forwarded as `/dex/auth?…` to Dex — which is why Dex is
  configured with an issuer path of `/dex` (see `dex/config.sample.yaml:16`).
- Each proxy block forwards `Host`, `X-Real-IP`, `X-Forwarded-For` and
  `X-Forwarded-Proto` (`Dockerfile:36-39, 46-49`).
- Because the browser only ever reaches port 3000, the rest of the stack does
  **not** need to be published to the host at all: the identity service and Dex
  are reached over the shared internal Docker network `libcloud_net`
  (`docker-compose.yml:33-34, 49-51`). This is the reason the other services in
  the stack bind to `127.0.0.1` / stay off the host port map — the portal is
  the single intended public surface.

The port mapping publishes on **all interfaces** — note there is deliberately no
`127.0.0.1:` prefix (`docker-compose.yml:36`):

```yaml
ports:
  - "${PORTAL_HTTP_PORT:-3000}:3000"
```

The built-in dev defaults in `config.js` (`http://localhost:5556/dex`,
`http://localhost:8766`) are for the raw CRA dev server; in the Docker image the
compose build args point the browser at the single door instead
(`docker-compose.yml:18-21` derives the Dex/API/redirect URLs from
`PUBLIC_HOSTNAME` on port 3000).

---

## 3. Build-time vs runtime config

### 3.1 Build-time: CRA bakes `REACT_APP_*` into the bundle

CRA only exposes variables prefixed `REACT_APP_` to the browser, and it
substitutes them **at build time** into the static JS (see `.env.example:2-3`).
The Dockerfile therefore declares each one as an `ARG` and promotes it to `ENV`
so `react-scripts build` sees it (`Dockerfile:8-19`):

```
REACT_APP_DEX_BASE_URL, REACT_APP_DEX_CLIENT_ID, REACT_APP_DEX_REDIRECT_URI,
REACT_APP_API_BASE_URL, REACT_APP_MOCK_MODE, REACT_APP_DISABLE_FEDERATION
```

`server/.env` is **dockerignored** (`.dockerignore:7`), so the values are passed
as **build args** rather than being copied into the image (`Dockerfile:6-7`,
`docker-compose.yml:17-23`). Two subtleties worth knowing:

- Docker Compose **does** read `server/.env` for its own `${VAR}` interpolation
  at build/up time — so `.env` still drives the build args; it is simply never
  `COPY`ed into the image build context.
- The runtime `environment:` block in `docker-compose.yml:40-47` re-declares the
  same `REACT_APP_*` values, but the compose comment is explicit that they are
  **kept only for operator introspection** — nginx serves a pre-built bundle and
  does not re-read them.

### 3.2 Runtime: the air-gapped hostname patcher

Because an air-gapped host **cannot rebuild the image** (no `node:18-alpine`
pull), `docker-entrypoint.sh` patches the baked-in hostname in the already-built
JS at every container start (`docker-entrypoint.sh:1-14`). It works as follows:

1. `BAKED='cwcloudweave.xyz'` — the hostname compiled into the bundle the last
   time the image was built (`docker-entrypoint.sh:16`). `BAKED_RE` is the
   regex-escaped form (`:17`).
2. It reads `PUBLIC_HOSTNAME` from the bind-mounted `/run/config/my.env`
   (`../my.env`, mounted at `docker-compose.yml:31`) first; the container env
   var `PUBLIC_HOSTNAME` is only a fallback, then `localhost`
   (`docker-entrypoint.sh:18-25`).
3. If the resolved host differs from `BAKED`, it `sed -i`-replaces `BAKED_RE`
   with the resolved host across **every `.js` file** under
   `/usr/share/nginx/html` (`docker-entrypoint.sh:27-30`).
4. Then execs nginx (`:32`).

The image is wired to this patcher via an entrypoint override and a read-only
bind mount of the script (`docker-compose.yml:28-32`).

**Maintenance hazard (stated in the script itself, `docker-entrypoint.sh:10-14`):**
`BAKED` is a constant until the image is rebuilt. If the image is ever rebuilt
*elsewhere* with a different base hostname, `BAKED` (and the escaped `BAKED_RE`)
must be updated to match — otherwise the patcher silently finds nothing to
replace and the bundle keeps serving the stale hostname. Note the current
`BAKED` (`cwcloudweave.xyz`) is already different from the `PUBLIC_HOSTNAME`
(`rocky96`) in `server/.env:15`, which is exactly what this patch step exists
to reconcile at runtime.

---

## 4. Route table and role screens

All routing lives in `src/App.js` (`Routes`/`Route`). Guards wrap pages in
`Layout` where the page is part of the authenticated shell.

| Path | Component | Guard | Audience / purpose |
|---|---|---|---|
| `/login` | `LoginPage` | none | Entry point. Redirects to role home if already authenticated (`App.js:24`, `LoginPage.js:12-14`). |
| `/auth/callback` | `AuthCallbackPage` | none | Dex OIDC callback; exchanges the code (`App.js:25`). |
| `/unauthorized` | `UnauthorizedPage` | none | 403 fallback for wrong-role access (`App.js:26`). |
| `/logout` | `LogoutPage` | none | Calls backend logout, returns to `/login` (`App.js:27`). |
| `/identity/collapse` | `IdentityCollapsePage` | `RequireAuth` | Link/keep a newly matched identity (`App.js:31-40`). |
| `/pending` | `PendingApprovalPage` | `RequireAuth` | Authenticated but no role/tenant assigned yet (`App.js:43-52`). |
| `/disabled` | `DisabledAccountPage` | `RequireAuth` | Account revoked by a SuperAdmin (`App.js:55-64`). |
| `/superadmin` | `SuperAdminDashboard` | `RequireRole(["superadmin"])` | User management (`App.js:67-76`). |
| `/superadmin/tuples` | `OpenFgaTuplesPage` | `RequireRole(["superadmin"])` | Raw OpenFGA tuple CRUD (`App.js:78-86`). |
| `/superadmin/explorer` | `OpenFgaExplorerPage` | `RequireRole(["superadmin"])` | Authorization store explorer (`App.js:87-96`). |
| `/admin` | `AdminDashboard` | `RequireRole(["admin"])` | Provision/view/edit/deprovision (`App.js:97-106`). |
| `/owner` | `OwnerDashboard` | `RequireRole(["owner"])` | Same shell as admin + owner placeholder (`App.js:107-116`). |
| `/viewer` | `ViewerDashboard` | `RequireRole(["viewer","admin","owner","superadmin"])` | Read-only profile + resources; all roles allowed (`App.js:117-126`). |
| `/` | `Navigate → /login` | none | Root redirect (`App.js:128`). |
| `*` | `NotFoundPage` | none | 404 catch-all (`App.js:129`). |

### 4.1 Role → landing route

`roleHome()` in `src/services/auth.js:56-65` maps the session role to the
post-login destination:

| Role | Landing route |
|---|---|
| `superadmin` | `/superadmin` |
| `admin` | `/admin` |
| `owner` | `/owner` |
| `pending` | `/pending` |
| `viewer` (and default) | `/viewer` |

`disabled` is handled by the guard (redirected to `/disabled`), not by
`roleHome`.

### 4.2 Dashboard components

- **`AdminDashboard`** exports the shared `CloudDashboard` shell (`role="admin"`)
  plus the default admin export. The shell is cloud-parametric: `CLOUD_META`
  maps `aws`/`nutanix` to the same provision/deprovision/update/resource calls
  (`AdminDashboard.js:134-157`). Mutation buttons (Edit/Deprovision/Provision)
  are gated on the **per-cloud OpenFGA capabilities** carried in
  `session.clouds` (`AdminDashboard.js:165-169, 321-322`).
- **`OwnerDashboard`** reuses `CloudDashboard role="owner"` and appends an
  empty "owner-specific (placeholder)" card; the backend policy is what
  differentiates owner from admin (`OwnerDashboard.js:4-19`).
- **`ViewerDashboard`** renders the profile table plus `CloudDashboard`
  in `readOnly` mode — no Provision/Edit/Deprovision controls
  (`ViewerDashboard.js:6-41`).

### 4.3 Special-state pages

- **`PendingApprovalPage`** — account exists but has no role/tenant; instructs
  the user to wait for SuperAdmin assignment (`PendingApprovalPage.js:8-15`).
- **`DisabledAccountPage`** — account remains in LLDAP/IdP but all OpenFGA role
  tuples were revoked; all actions denied (`DisabledAccountPage.js:8-15`).
- **`UnauthorizedPage`** — role not in the allowed set for a route; links to
  `/viewer` (`UnauthorizedPage.js:4-13`).
- **`IdentityCollapsePage`** — the "one user, many providers" merge screen; lets
  the user **link** a new external identity into an existing internal user or
  **keep** it as a separate pending account (`IdentityCollapsePage.js:30-48`).
- **`NotFoundPage`** — plain 404 (`NotFoundPage.js:4-13`).

---

## 5. Auth from the browser's point of view

### 5.1 Starting login

`LoginPage`'s sign-in buttons call `handleLogin(provider)`
(`LoginPage.js:124-136`), which (in real mode) calls `redirectToDex(provider)`
in `src/services/auth.js:13-31`:

1. `GET /api/auth/begin?provider=<provider>&redirect_uri=<redirectUri>`
   (`auth.js:17-24`) — the identity service mints the CSRF `state` + PKCE
   verifier and returns `{ authorizeUrl, state }`.
2. The browser stashes `{ state, provider }` in `sessionStorage` under the key
   **`libcloud.portal.oauth`** (`auth.js:29`).
3. Then `window.location.href = authorizeUrl` redirects the whole page to Dex
   (`auth.js:30`).

The browser **does not generate the state itself** — the server is the
authoritative validator on callback (`auth.js:13-16`).

### 5.2 The callback

`AuthCallbackPage` reads `code`, `state` (and `mock_provider` in mock mode) from
the query string, consumes the stored OAuth state, sanity-checks
`stored.state === state`, and calls `POST /api/auth/exchange` with
`{ provider, code, state, redirectUri }` (`AuthCallbackPage.js:18-38`). On a
successful exchange it either:

- stashes the collapse payload under **`libcloud.portal.collapse`** and routes
  to `/identity/collapse` when `needsIdentityCollapse` is true
  (`AuthCallbackPage.js:42-47`); or
- calls `login(result)` and navigates to `roleHome(result.role)`
  (`AuthCallbackPage.js:49-50`).

### 5.3 Where the session actually lives

**The real session is the httpOnly cookie set by the identity service.** The
browser stores only UX metadata in `sessionStorage`, and **no provider tokens
are ever stored client-side**:

| `sessionStorage` key | Contents | Source |
|---|---|---|
| `libcloud.portal.oauth` | transient `{ state, provider }` for the in-flight redirect | `auth.js:29` |
| `libcloud.portal.session` | session metadata: `internalUserId`, `role`, `email`, `linkedIdentities` | `auth.js:11, 42-44`; written in `AuthContext.js:35-44` |
| `libcloud.portal.collapse` | the pending `exchange` result during identity collapse | `AuthCallbackPage.js:44`, `IdentityCollapsePage.js:12-15` |

The comment in `auth.js:39-41` is explicit: this is "only for UX (route guards,
greeting)", and the backend owns the session. Every API call goes through
`fetch(..., { credentials: "include" })` so the httpOnly cookie is sent with
each request (`api.js:30`). On mount, `AuthContext` tries to restore the session
by calling `GET /api/session` when session metadata exists (`AuthContext.js:13-33`).

Logout calls `POST /api/logout` (which revokes the Dex refresh token
server-side), clears the local metadata, and returns to `/login`
(`LogoutPage.js:9-30`, `AuthContext.js:46-55`).

---

## 6. Client-side guards are cosmetic

`RequireAuth` and `RequireRole` are **UX-only**. Their own source comments say
so:

- `RequireAuth.js:5-6` — "UX-only auth gate. The backend MUST re-validate the
  session on every API call; this component only decides what to render."
- `RequireRole.js:5-6` — "UX-only role gate. … Backend authorization (OpenFGA)
  is the source of truth; this only shapes navigation/rendering."

Mechanically, `RequireAuth` just redirects unauthenticated users to `/login`
(`RequireAuth.js:14-16`), and `RequireRole` adds two more redirects —
`/disabled` for the `disabled` role, `/unauthorized` for any role not in the
allowed list (`RequireRole.js:14-19`). The same "UX only" framing is repeated on
the mutating screens (e.g. `SuperAdminDashboard.js:134-135`: "The backend
enforces authorization (OpenFGA); these controls are UX only").

The real enforcement lives in the **identity service**: the httpOnly cookie
session, and per-verb OpenFGA checks on every `/api/*` call. A user can edit the
bundle in devtools to reach any screen; they still cannot make a backend call
their role does not permit.

---

## 7. The superadmin screens

All three superadmin routes are gated by `RequireRole(["superadmin"])`
(`App.js:67-96`). The nav bar also only shows these tabs to superadmins
(`Layout.js:17-24`).

### 7.1 `OpenFgaTuplesPage` (`/superadmin/tuples`)

Raw OpenFGA relationship-tuple management — "the single mechanism behind role
grants AND disable" (`OpenFgaTuplesPage.js:5-9`):

- Lists all tuples via `GET /api/tuples` (`api.js:62`, `OpenFgaTuplesPage.js:22`).
- Adds a tuple via `POST /api/tuples` (`api.js:63`, `OpenFgaTuplesPage.js:50`).
- Deletes a tuple via `DELETE /api/tuples` (`api.js:64`, `OpenFgaTuplesPage.js:62`).

The page warns that structural tuples (`parent`/`provider`/`tenant`) drive
permission propagation and should be edited with care (`OpenFgaTuplesPage.js:83-88`).

### 7.2 `OpenFgaExplorerPage` (`/superadmin/explorer`)

A five-tab read-only explorer (`OpenFgaExplorerPage.js:5-11`) over the `/api/openfga/*`
endpoints declared in `api.js:90-103`:

| Tab | Shows | Endpoints called |
|---|---|---|
| **Users & Roles** | Internal users joined with their tuples; per-user tuple expansion | `GET /api/users`, `GET /api/tuples` (`OpenFgaExplorerPage.js:80`) |
| **REST API Routes** | Which REST routes require which scopes/capabilities, and which roles can reach them | `GET /api/openfga/rest-api-policies` (`api.js:103`, `OpenFgaExplorerPage.js:263`) |
| **Store & Models** | Store metadata, authorization models + type definitions, model assertions | `GET /api/openfga/store`, `GET /api/openfga/models`, `GET /api/openfga/models/:id`, `GET /api/openfga/assertions/:modelId` (`OpenFgaExplorerPage.js:399, 413, 424`) |
| **Changes** | Tuple change log / audit trail with WRITE/DELETE filter + pagination | `GET /api/openfga/changes?…` (`api.js:94-99`, `OpenFgaExplorerPage.js:607`) |
| **Query** | Interactive List-Users / List-Objects / Expand | `POST /api/openfga/list-users`, `POST /api/openfga/list-objects`, `POST /api/openfga/expand` (`api.js:100-102`, `OpenFgaExplorerPage.js:735, 747, 759`) |

`SuperAdminDashboard` (`/superadmin`) is the user-management companion: it lists
users via `GET /api/users`, commits role/tenant changes via
`PATCH /api/users/:id/role`, sets email via `PATCH /api/users/:id/email`, and
disables via `POST /api/users/:id/disable` (`api.js:54-61`,
`SuperAdminDashboard.js:73, 87, 105`).

---

## 8. Mock mode

### 8.1 The flag and its (conflicting) defaults

`config.js:18` treats mock mode as **ON** when the env var is unset:

```js
mockMode: env("REACT_APP_MOCK_MODE", "true").toLowerCase() === "true",
```

`server/.env.example:35` also defaults it to `true` (for demo/dev convenience),
while `docker-compose.yml:22` defaults the *build arg* to `false`. The effective
value depends on which path supplies `REACT_APP_MOCK_MODE` at build time —
`.env.example` and the raw CRA dev server lean true; a compose build with no
override builds `false`.

### 8.2 What it does

When on, `api.js:47-49` replaces the HTTP client with the in-memory `mockApi`
implementation, so the whole UI runs with no Dex and no identity service.
Critically, `LoginPage` renders a **"Mock mode is ON"** banner and a
**Mock sign-in (no Dex)** dropdown (`LoginPage.js:27-31, 49, 58-122`) that calls
`mockApi.mockLoginAs(internalUserId)` (`mockApi.js:94-106`) to impersonate **any
seeded user — including `superadmin`** — with zero Dex involvement. In mock mode
the normal sign-in buttons don't touch Dex either; they jump straight to
`/auth/callback?mock_provider=<provider>` (`LoginPage.js:125-128`), and the mock
`exchange` signs LLDAP in as the pregenerated superadmin (`mockApi.js:122-132`).

### 8.3 The honest risk

- `mockLoginAs` / `listMockUsers` and the entire `mockData.js` dataset are
  **imported unconditionally** (`api.js:23`, `mockApi.js:5-20`) and therefore
  **compiled into the bundle regardless of the flag**. In a non-mock build the
  picker is never rendered and those functions are unreachable from the UI, but
  the code and the seeded-user data are still present in the publicly-served JS.
- The flag gates only the *default client selection*; it is not a build-time
  tree-shake. A user cannot flip it from the browser (it is baked in), but the
  on/off state is decided entirely by how the image was built — there is no
  runtime confirmation that a "production" bundle was built with mock mode off.
- The seeded data (`mockData.js`) contains only fictional placeholder users and
  mock OpenFGA tuples — no real credentials — but it is a faithful blueprint of
  internal user IDs, role names, tenant labels and the OpenFGA model, which is
  exactly the information a hostile reader would use to target the real system.

The correct production posture is `REACT_APP_MOCK_MODE=false` in `server/.env`
(it is, at `server/.env:34`) **and** verifying that the built image actually
baked `false` (the compose build-arg default).

---

## 9. Security notes

These are the properties as they actually stand in source; each is caveated
rather than hand-waved.

1. **Published on all interfaces.** The compose `ports` mapping has no
   `127.0.0.1:` prefix — `${PORTAL_HTTP_PORT:-3000}:3000` exposes nginx on
   every host interface (`docker-compose.yml:36`). This is deliberate: the
   portal is the intended public surface (see §2). If that is not desired for a
   given deployment, the mapping must be narrowed to `127.0.0.1:3000:3000`.

2. **No TLS.** The nginx config performs no TLS termination (`Dockerfile:30-57`),
   and every browser-facing URL in the config surface is `http://`
   (`docker-compose.yml:18-21`, `config.js:8,14`, `.env.example`). The front
   door is plain HTTP. Consequently the identity service's session cookie must
   be delivered **without** the `Secure` flag for the browser to send it over
   this front door — i.e. the cookie is `Secure=false` (or the deployment adds a
   TLS-terminating reverse proxy in front of the portal, which is not present
   here). Any production exposure should terminate TLS upstream of port 3000.

3. **Mock-mode default risk.** The code-level and `.env.example` defaults are
   `true` (`config.js:18`, `.env.example:35`); only the compose build arg
   defaults `false` (`docker-compose.yml:22`). A bundle accidentally built from
   the wrong source of truth ships a superadmin-impersonation UI (see §8).

4. **No secrets in `REACT_APP_*` (verified).** The `REACT_APP_*` values actually
   present in `server/.env` and `.env.example` are: the public OAuth client id
   `libcloud-portal`, hostnames/URLs (`PUBLIC_HOSTNAME`, base/redirect URLs),
   and two boolean feature flags (`REACT_APP_MOCK_MODE`,
   `REACT_APP_DISABLE_FEDERATION`). **No provider client secret, no password, no
   token, no API key** is set as a `REACT_APP_*` var, so none is baked into the
   bundle. This matches the guidance in `.env.example:5-7` and
   `dex/config.sample.yaml:37` — the client *secret* lives only in the backend
   (Dex/identity service) and is used server-side during `POST /api/auth/exchange`.
   Because any future `REACT_APP_*` var would be baked into a publicly-served
   static bundle, the invariant is: **never** add a secret under that prefix.

5. **Client-side guards are cosmetic.** `RequireAuth` / `RequireRole` shape
   rendering only; the authoritative enforcement is the identity service's
   cookie session plus per-verb OpenFGA checks (see §6). Both components carry
   this disclaimer in their own source (`RequireAuth.js:5-6`, `RequireRole.js:5-6`).

6. **CSRF/state and PKCE enforcement is backend-owned.** The browser only
   sanity-checks the OAuth `state` it stored before the redirect
   (`AuthCallbackPage.js:24-30`); the full state + PKCE validation happens in
   the backend `exchange` step (`auth.js:13-16`,
   `AuthCallbackPage.js:25-28`). The sample Dex config leaves its own TODOs for
   strong signing keys and a production issuer (`dex/config.sample.yaml:16, 32`).
