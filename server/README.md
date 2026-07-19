# libcloud Role Portal

A role-aware React frontend for the libcloud cloud management platform.

- **Authentication** is delegated to a backend **Dex** deployment. Dex
  federates to **Google** and **GitHub**; the portal never sees provider
  credentials.
- After login, the portal calls a backend **identity service**
  (`POST /api/auth/exchange`) that maps the Dex-authenticated external identity
  to an **internal user**, assigns the default **`viewer`** role on first
  login, and prompts for **identity collapse** when a new identity appears to
  match an existing internal user.
- **Authorization** is role-based and **separate from login mechanics**. The
  frontend role checks are UX-only — the backend (OpenFGA) is the source of
  truth.

## Roles

| Role       | Landing route | Capabilities |
|------------|---------------|--------------|
| `superadmin` | `/superadmin` | List all users, view linked identities, change any user's role (`superadmin`/`owner`/`admin`/`viewer`) |
| `owner`      | `/owner`      | Same dashboard shell as admin; permissions differentiated by backend policy |
| `admin`      | `/admin`      | Provision AWS, Provision Nutanix, View AWS resources, View Nutanix resources |
| `viewer`     | `/viewer`     | Read-only profile: internal user ID, role, login provider, linked identities |

A **predefined `superadmin`** internal user exists out of the box. Any
first-time Google/GitHub login auto-provisions a new internal user with role
`viewer`.

## Quick start (mock mode) — Docker (no host npm required)

The host has **no `node`/`npm` installed**, and it doesn't need any. The portal
is built and run entirely inside Docker via a multi-stage `Dockerfile`:

- **Stage 1 (`node:18-alpine`)** — runs `npm ci` + `npm run build` using the
  npm bundled inside the image. No host npm is touched.
- **Stage 2 (`nginx:alpine`, ~94 MB)** — runtime image with **no node/npm at
  all**; only the compiled static SPA is served.

```bash
# from the server/ directory
cp .env.example .env                 # REACT_APP_MOCK_MODE=true by default
docker build -t libcloud-portal .
docker run -d --rm --name portal -p 3000:3000 libcloud-portal
# open http://localhost:3000
```

Stop it with `docker stop portal`.

In mock mode the sign-in buttons simulate the Dex callback locally — no Dex
or backend required. Example users are seeded in
`src/services/mockData.js`:

- `superadmin@libcloud.local` — predefined superadmin (Google-linked)
- `owner@libcloud.local` — owner
- `admin@libcloud.local` — admin (Google + GitHub linked)
- `viewer@libcloud.local` — viewer (GitHub-linked)

To exercise the **identity-collapse** flow: in mock mode, signing in with a
provider whose email collides with an existing user triggers the collapse
prompt. The mock `exchange` implementation uses an email-match heuristic; see
`src/services/mockApi.js`.

### Live reload / dev server (optional, needs host npm)

If you do have `node` + `npm` on your host and want hot-reload dev mode, you
can fall back to the CRA dev server — but this is **not** required and is not
available on the default host:

```bash
cd server
npm install --legacy-peer-deps
npm start                            # http://localhost:3000
```

### Docker Compose (portal + sample Dex)

`server/docker-compose.yml` is an **illustrative reference** that starts a
portal-only Dex alongside the portal. For this stack you should use the real
`./dex` instead (see "Running against real Dex + backend" below). If you just
want to try the compose file in isolation:

```bash
cd server
docker compose up -d --build         # portal on :3000, sample dex on :5556
```

## Running against real Dex + backend

The portal uses the **same Dex that's already running** in `./dex` (the
LLDAP-backed OIDC issuer for the rest of the stack). We extend it with two
additional upstream connectors — **Google** and **GitHub** — plus a new OAuth
client `libcloud-portal` for this portal. The existing LDAP/LLDAP connector and
the `libcloud-rest` client are untouched, so the libcloud REST API and OpenFGA
keep working unchanged.

### Activation (one-time)

`dex/config.template.yaml` and `openfga_postgres/dex_bootstrap.py` already
support the optional Google/GitHub connectors + portal client. They are
**gated**: the connectors/portal client are only appended when the
corresponding env vars are set, so the running stack is unchanged until you
opt in.

1. Create Google + GitHub OAuth apps and obtain client IDs/secrets. Set the
   portal redirect URI to `http://localhost:3000/auth/callback` (or your
   production URL).

2. Export the federation env vars and re-run the bootstrap, then recreate the
   `dex` container:

   ```bash
   # from repo root
   set -a; . ./lldap/.env; . ./dex/generated/dex.env; set +a
   export LLDAP_BASE_DN="${LLDAP_LDAP_BASE_DN:-dc=libcloud,dc=local}"
   export LLDAP_BIND_DN="uid=${LLDAP_ADMIN_USER:-admin},ou=people,${LLDAP_BASE_DN}"
   export LLDAP_BIND_PW="${LLDAP_LDAP_USER_PASS:-}"
   export DEX_PORTAL_REDIRECT_URI="http://localhost:3000/auth/callback"
   export DEX_PORTAL_CLIENT_SECRET="$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
   export DEX_GOOGLE_CLIENT_ID="<your-google-client-id>"
   export DEX_GOOGLE_CLIENT_SECRET="<your-google-client-secret>"
   export DEX_GITHUB_CLIENT_ID="<your-github-client-id>"
   export DEX_GITHUB_CLIENT_SECRET="<your-github-client-secret>"
   DEX_WAIT=0 DEX_DIR="$(pwd)/dex" python3 openfga_postgres/dex_bootstrap.py
   docker compose -f dex/docker-compose.yml up -d --force-recreate dex
   ```

3. The portal client secret + connector metadata are written to
   `dex/generated/dex.env` (`DEX_PORTAL_CLIENT_SECRET`, `DEX_PORTAL_REDIRECT_URI`,
   `DEX_GOOGLE_CLIENT_ID`, `DEX_GITHUB_CLIENT_ID`). The portal backend reads
   `DEX_PORTAL_CLIENT_SECRET` to perform the token exchange with Dex.

4. Implement the backend identity service against the API contract below and
   set `REACT_APP_API_BASE_URL` to its URL.

5. Set `REACT_APP_MOCK_MODE=false` in `server/.env`.

The sample `server/dex/config.sample.yaml` and `server/docker-compose.yml`
remain as **illustrative references** for a portal-only Dex deployment; for
this stack you should use the real `./dex` as described above.

## Environment variables

| Variable | Purpose |
|----------|---------|
| `REACT_APP_DEX_BASE_URL`   | Dex issuer base URL (host form for browsers) |
| `REACT_APP_DEX_CLIENT_ID`  | OAuth client id registered in Dex (`libcloud-portal`) |
| `REACT_APP_DEX_REDIRECT_URI` | OAuth redirect URI (must match Dex exactly) |
| `REACT_APP_API_BASE_URL`   | Backend identity service base URL |
| `REACT_APP_MOCK_MODE`      | `true` = use in-memory mock data; `false` = call backend |

## Routes

| Route | Guard | Description |
|-------|-------|-------------|
| `/login`            | public           | Google / GitHub sign-in buttons → redirect to Dex |
| `/auth/callback`    | public           | Consumes `code`/`state`, calls `/api/auth/exchange`, redirects by role (or to collapse) |
| `/identity/collapse`| `RequireAuth`    | Link a new external identity into an existing internal user, or keep separate |
| `/superadmin`        | `RequireRole(superadmin)` | User management table |
| `/admin`             | `RequireRole(admin, superadmin)` | AWS/Nutanix provision + resource views |
| `/owner`             | `RequireRole(owner, superadmin)` | Same shell as admin + owner placeholders |
| `/viewer`            | `RequireRole(viewer, admin, owner, superadmin)` | Read-only profile |
| `/logout`            | public           | Clears session, calls `/api/logout`, returns to `/login` |
| `/unauthorized`      | public           | Role denied |
| `*`                  | public           | Not found |

## Backend API contract

The frontend client (`src/services/api.js`) calls:

```
GET    /api/session
POST   /api/auth/exchange
POST   /api/auth/collapse
POST   /api/logout
GET    /api/users
PATCH  /api/users/:id/role
GET    /api/resources/aws
GET    /api/resources/nutanix
POST   /api/provision/aws
POST   /api/provision/nutanix
POST   /api/deprovision/aws
```

### `POST /api/auth/exchange` response

```json
{
  "internalUserId": "int-...",
  "role": "viewer",
  "linkedIdentities": ["google:1082..."],
  "needsIdentityCollapse": false,
  "collapseCandidates": [],
  "email": "user@example.com"
}
```

When `needsIdentityCollapse` is `true`, the portal redirects to
`/identity/collapse` and submits the user's decision via
`POST /api/auth/collapse`:

```json
{
  "targetInternalUserId": "int-...",
  "pendingIdentity": { "provider": "github", "subject": "github:67890", "email": "user@example.com" },
  "decision": "link"      // or "keep"
}
```

## Provisioning contract (important)

The AWS/Nutanix provision buttons call `POST /api/provision/{aws,nutanix}`.
The **backend** must execute the exact orchestration order from:

- `test_script/scripts/provision_aws.sh`
- `test_script/scripts/provision_nutanix.sh`

The frontend **does not** invent cloud API sequences. The provisioning result
includes the ordered step list (see `src/services/mockData.js`) purely as a
contract reminder; the backend owns the real workflow:

1. `idp_login` (Dex → OIDC token)
2. Build provider connection params (region + auth_binding, **no credentials in client**)
3. `GET /v1/me`, `GET /v1/connection/test`
4. Catalog discovery (`locations`, `sizes`, `images`, …)
5. `GET /v1/compute/nodes`
6. Resolve image/size/cluster/subnet
7. `POST /v1/compute/nodes`
8. Optional teardown (`TEARDOWN_VMS=1`)

The REST API holds the backend cloud identity (server-side IAM role /
auth_binding + Vault secret); the client never handles cloud credentials.

## Deprovisioning contract

The AWS resources table's per-row **Deprovision** button calls
`POST /api/deprovision/aws` with `{ vmId, vmName }`. The backend enforces the
same `can_provision` OpenFGA check as provisioning, then **shells out to
`test_script/scripts/deprovision_aws.sh`** (passing `VM_ID`), which re-runs the
FGA check and `curl DELETE /v1/compute/nodes/{id}`. The script remains the
single source of truth for the deprovisioning sequence; the portal never
invents cloud API calls. On success the frontend refreshes the resource list
so the deleted VM disappears.

## Project structure

```
server/
├── package.json
├── package-lock.json          # pinned deps; Docker uses `npm ci`
├── Dockerfile                 # multi-stage: node build -> nginx runtime
├── .dockerignore
├── docker-compose.yml
├── .env.example
├── dex/config.sample.yaml
├── public/index.html
└── src/
    ├── index.js                # entry: BrowserRouter + AuthProvider
    ├── App.js                  # routes + guards
    ├── config.js               # env-driven config
    ├── context/AuthContext.js  # session state (React Context)
    ├── components/
    │   ├── RequireAuth.js
    │   ├── RequireRole.js
    │   ├── Layout.js
    │   ├── Banner.js
    │   └── IdentityBadges.js
    ├── pages/
    │   ├── LoginPage.js
    │   ├── AuthCallbackPage.js
    │   ├── IdentityCollapsePage.js
    │   ├── SuperAdminDashboard.js
    │   ├── AdminDashboard.js
    │   ├── OwnerDashboard.js
    │   ├── ViewerDashboard.js
    │   ├── UnauthorizedPage.js
    │   ├── NotFoundPage.js
    │   └── LogoutPage.js
    ├── services/
    │   ├── api.js              # API client (mock or http)
    │   ├── mockApi.js          # in-memory backend for mock mode
    │   ├── mockData.js         # seeded users + resource/provision stubs
    │   └── auth.js             # Dex redirect + session-meta helpers
    └── styles/app.css
```

## Security notes

- Frontend role checks (`RequireRole`) are **UX-only**. The backend must
  enforce authorization on every call (OpenFGA validates the Dex-issued JWT).
- Provider secrets live only in the backend Dex config — never in the browser
  bundle.
- The browser stores only minimal session metadata in `sessionStorage`; raw
  provider tokens are kept backend-side behind an httpOnly cookie.
- TODO markers in `dex/config.sample.yaml` indicate where client ID/secret,
  issuer URL, redirect URI, and cookie/session settings must be filled in.
- Full **CSRF/state + PKCE** validation and **secure cookie handling** belong
  in the backend `exchange`/`collapse`/`logout` implementations; the browser
  only sanity-checks the OAuth `state` it stored before the redirect.
