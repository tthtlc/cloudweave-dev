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

| Role         | Landing route   | Capabilities |
|--------------|-----------------|--------------|
| `superadmin` | `/superadmin`   | User management: list all users, view linked identities, change any user's role (`superadmin`/`owner`/`admin`/`viewer`/`disabled`), assign tenant (`aws`/`nutanix`), set email, disable users. Raw OpenFGA tuple CRUD. Authorization store explorer. |
| `owner`      | `/owner`        | Same provisioning + resource-view shell as admin; permissions differentiated by backend OpenFGA policy. Placeholder for future owner-specific actions. |
| `admin`      | `/admin`        | Provision AWS/Nutanix VMs, view resources (region/cluster, state, size), inline edit VMs (name, size, memory, tags), deprovision VMs. |
| `viewer`     | `/viewer`       | Read-only profile (internal user ID, email, role, login provider, linked identities) + read-only resource view for assigned tenant. |
| `pending`    | `/pending`      | Newly created account awaiting role/tenant assignment by a SuperAdmin. |
| `disabled`   | `/disabled`     | Account exists in LLDAP/IdP but all OpenFGA role tuples have been revoked. No platform actions permitted. |

A **predefined `superadmin`** internal user exists out of the box. Any
first-time Google/GitHub login auto-provisions a new internal user with role
`pending` (awaiting SuperAdmin assignment).

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

### Public / Unauthenticated Routes

| Route | Component | Function & Purpose |
|---|---|---|
| `/login` | `LoginPage` | **Entry point.** Renders sign-in buttons for LLDAP, Google, and GitHub (all proxied through Dex OIDC). In mock mode, provides a dropdown to impersonate any pre-seeded user and skip real authentication. If the user is already authenticated, redirects them to their role-appropriate dashboard. |
| `/auth/callback` | `AuthCallbackPage` | **OAuth2 callback handler.** Dex redirects here after a successful login with `code` and `state` query params. This page validates the OAuth state (CSRF protection), exchanges the authorization code for a session via the backend, and routes the user onward — either to `/identity/collapse` (if the new identity matched existing users) or directly to their role dashboard. |
| `/unauthorized` | `UnauthorizedPage` | **403 fallback.** Shown when an authenticated user's role does not match the roles required for a route (e.g., a `viewer` trying to access `/admin`). Displays a "not permitted" message with a link back to the viewer dashboard. |
| `/logout` | `LogoutPage` | **Session termination.** Calls the backend logout endpoint (which revokes the Dex refresh token), clears the local session state, and redirects to `/login`. If the backend returns an IdP logout URL (for future non-Dex providers), it redirects there instead. |
| `/` | `Navigate` → `/login` | **Root redirect.** The bare domain immediately sends unauthenticated users to the login page. |
| `*` (catch-all) | `NotFoundPage` | **404 page.** Any path not matching a defined route renders a "Not found" message with a link back to `/login`. |

### Authenticated (Any Role) — Gated by `RequireAuth`

These routes require a valid session but no specific role:

| Route | Component | Function & Purpose |
|---|---|---|
| `/identity/collapse` | `IdentityCollapsePage` | **Identity linking / deduplication.** When a user signs in with a new external provider (e.g., Google) whose email matches an existing internal user, the backend returns `needsIdentityCollapse: true`. This page lets the user **link** the new identity into an existing internal account or **keep** it as a separate pending account. This is how the system handles "one user, multiple identity providers." |
| `/pending` | `PendingApprovalPage` | **Awaiting role assignment.** Shown to users who have authenticated successfully but have a `pending` role (no tenant or role assigned yet). Explains that a SuperAdmin must assign them a role and tenant before they can access cloud resources. |
| `/disabled` | `DisabledAccountPage` | **Account revoked.** Displayed to users whose role is `disabled`. Explains that their account still exists in LLDAP but all OpenFGA role tuples have been revoked, meaning no platform actions are permitted. Directs them to contact a SuperAdmin for re-enablement. |

### SuperAdmin Routes — Gated by `RequireRole(["superadmin"])`

| Route | Component | Function & Purpose |
|---|---|---|
| `/superadmin` | `SuperAdminDashboard` | **User management.** The central administrative panel. Lists all internal users (both LLDAP-provisioned and OAuth2/federated). A SuperAdmin can: assign/change a user's **role** (`superadmin`, `owner`, `admin`, `viewer`, `disabled`), assign a **tenant** (`aws` or `nutanix`) for federated users, set/update email addresses, and **disable** users (revoking all their OpenFGA tuples). All changes go through `PATCH /api/users/:id/role`. |
| `/superadmin/tuples` | `OpenFgaTuplesPage` | **Raw OpenFGA tuple management.** Direct CRUD interface over the OpenFGA relationship store. A SuperAdmin can list, filter, add, and delete arbitrary authorization tuples (`user → relation → object`). This is the low-level mechanism behind role grants and disables — e.g., deleting a `user:<uid> admin tenant:aws` tuple revokes that user's admin access on AWS. |
| `/superadmin/explorer` | `OpenFgaExplorerPage` | **Authorization store explorer.** A comprehensive multi-tab view of the OpenFGA authorization system: **Users & Roles** (who has what), **REST API Routes** (which API endpoints are protected by which policies), **Store & Models** (the OpenFGA authorization model and type definitions), **Changes** (tuple change log/audit trail), and **Query** (interactive relationship queries to check permissions). |

### Tenant-Scoped Role Routes

| Route | Component | Guard | Function & Purpose |
|---|---|---|---|
| `/admin` | `AdminDashboard` | `RequireRole(["admin"])` | **Admin dashboard.** A `CloudDashboard` rendered with `role="admin"`. For the user's assigned tenant (AWS or Nutanix), this dashboard allows **provisioning** new VMs, **viewing** existing resources (with region/cluster, state, size), **editing** VM properties (name, size, memory, tags) via `PATCH /v1/compute/nodes/{id}`, and **deprovisioning** VMs. Permissions (canProvision, canUpdate) are computed live by the backend from OpenFGA. |
| `/owner` | `OwnerDashboard` | `RequireRole(["owner"])` | **Owner dashboard.** Uses the same `CloudDashboard` shell as admin (`role="owner"`), plus a placeholder section for future owner-specific actions. The backend (OpenFGA) differentiates owner from admin permissions; the UI keeps the same layout so backend policy is the only thing that changes between the two roles. |
| `/viewer` | `ViewerDashboard` | `RequireRole(["viewer", "admin", "owner", "superadmin"])` | **Read-only dashboard.** Accessible by all roles (including superadmin). Shows the user's **profile** (internal ID, email, role, login provider, linked identities) and a **read-only** `CloudDashboard` (no provision/edit/deprovision buttons — only "View Resources"). This is the default landing page for viewers, and a fallback for any authenticated user who wants a resource overview without mutation controls. |

## Architecture

### Auth & Role Gating

- **`RequireAuth`** — checks for a valid session; redirects to `/login` if absent. Shows a "Loading session…" placeholder while the session is being fetched.
- **`RequireRole`** — extends `RequireAuth`; also checks `session.role` against an allowed list. Routes to `/disabled` if the role is `disabled`, `/unauthorized` if the role isn't in the allowed set.

Frontend role checks are **UX-only**. The backend (OpenFGA) is the source of truth for all authorization decisions.

### Role-to-Dashboard Mapping

The `roleHome()` helper in `src/services/auth.js` maps each role to its landing route:

| Role | Landing Route |
|---|---|
| `superadmin` | `/superadmin` |
| `admin` | `/admin` |
| `owner` | `/owner` |
| `viewer` | `/viewer` |
| `pending` | `/pending` |
| `disabled` | `/disabled` |

### Navigation Shell (`Layout.js`)

All authenticated routes are wrapped in a shared `Layout` component that renders:
- A **top bar** with brand ("libcloud Portal"), current user email/role, and a logout button.
- A **role-aware nav bar** — nav links are filtered to only show tabs the current user's role permits:
  - **SuperAdmin** sees: Viewer, Superadmin, Tuples, Explorer
  - **Admin** sees: Viewer, Admin
  - **Owner** sees: Viewer, Owner
  - **Viewer** sees: Viewer

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
POST   /api/provision-private/nutanix
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

## Private VM pair provisioning contract

The **Provision Private VM Machine** button (rendered beside **Provision
AWS** / **Provision Nutanix** only when the session's per-cloud capability has
`canProvision` — i.e. that tenant's owner/admin; viewers and superadmins never
see it) calls `POST /api/provision-private/{cloud}` with `{ vmName }` (the pair
prefix). The backend enforces the same `can_provision` OpenFGA check as
single-VM provisioning, then **shells out to the per-cloud script** (passing
`PROVISION=1`, `VM_PREFIX`/`BASTION_NAME`/`INTERNAL_NAME`), which stays the
single source of truth for the 2-VM scenario:

- `test_script/scripts/provision_aws_private.sh`
  (`aws_bastion_internal_server.md`):
  1. Ensure VPC `libcloud-private-vpc` (`10.0.0.0/16`)
  2. Ensure public subnet `libcloud-public-subnet` (`10.0.0.0/24`, auto-assign
     public IP) + private subnet `libcloud-private-subnet` (`10.0.16.0/24`)
  3. Ensure internet gateway + public route table (`0.0.0.0/0` → IGW,
     associated with the public subnet; **no NAT gateway** — the private
     subnet keeps the local-only main route table)
  4. Ensure security groups (bastion: SSH/22 from the operator CIDR; internal:
     SSH/22 from the bastion SG + app port from the VPC CIDR) and the key pair
  5. Create the bastion VM (public subnet + public IP) and the internal VM
     (private subnet, **no public IP → no internet access**)
  6. Verify both VMs
- `test_script/scripts/provision_nutanix_bastion_private.sh`
  (`nutanix_bastion_internal_server.md`):
  1. Ensure subnet `vlan100-external` (VLAN 100, `10.1.100.0/24` + IPAM pool)
  2. Ensure subnet `vlan200-internal` (VLAN 200, `10.1.200.0/24` + IPAM pool, isolated)
  3. Create the bastion host on the external VLAN (2 vCPU, 4 GiB, 20 GiB data disk)
  4. Create the internal private server on the isolated VLAN (no internet access)
  5. Verify both VMs

The AWS network primitives the script needs (security-group rule
authorization, internet gateways, route tables) are exposed by the libcloud
REST API as `POST /v1/compute/security-groups/{id}:authorize`,
`/v1/compute/internet-gateways` and `/v1/compute/route-tables[...]`, all gated
on the `compute:network:manage` scope → the same OpenFGA `can_provision`
grant. The tenant's credentials are picked automatically from Vault
(`secret/libcloud/<auth_binding>`) by the libcloud REST API — the portal and
identity service never handle them. The response carries the script's
`stdout`/`stderr` and `exitCode`; the frontend renders them in a result card.

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
    │   ├── OpenFgaTuplesPage.js
    │   ├── OpenFgaExplorerPage.js
    │   ├── AdminDashboard.js
    │   ├── OwnerDashboard.js
    │   ├── ViewerDashboard.js
    │   ├── PendingApprovalPage.js
    │   ├── DisabledAccountPage.js
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
