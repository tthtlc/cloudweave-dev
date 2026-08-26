Build a production-structured web application in React + JavaScript, and place the entire app inside a top-level directory named "server".

Goal:
Create a role-aware frontend for a cloud management platform that authenticates users through a backend Dex deployment, supports Google and GitHub login, creates or links an internal user identity after successful login, and shows different routes/pages based on the user role.

Core architecture requirements:
1. Authentication must be delegated to backend Dex, not handled directly in the frontend.
2. Dex must be treated as the identity federation layer for Google and GitHub login.
3. The application must assume a backend "identity service" exists which:
   - receives the Dex-authenticated identity,
   - creates an internal user ID on first login,
   - links multiple external identities to one internal user,
   - detects when a newly authenticated external identity may belong to an existing internal user,
   - prompts the user to collapse/link identities when appropriate.
4. Authorization must be role-based and separate from login mechanics.
5. Use React Router v6 style protected routing and role-based route guards.

Roles:
- superadmin
- owner
- admin
- viewer

Role rules:
- viewer is the default and lowest role.
- Any first-time user who logs in through Google or GitHub must automatically receive:
  - a generated internal user ID,
  - the default role "viewer".
- The system must include one predefined, pregenerated internal user with role "superadmin".
- superadmin can:
  - list all current users,
  - view each user’s linked identities,
  - manage users,
  - change any user’s role to superadmin, owner, admin, or viewer,
  - especially promote existing users to admin.
- admin can:
  - log in through Dex,
  - land on an admin dashboard,
  - provision AWS,
  - provision Nutanix,
  - view AWS resources,
  - view Nutanix resources.
- owner can access the same dashboard shell pattern as admin, but wire it so permissions are easy to differentiate later.
- viewer can log in and see a minimal read-only landing page with their profile, linked identities, and current role.

Identity model requirements:
- After successful OAuth2/OIDC login through Google or GitHub, call a backend endpoint such as:
  - POST /api/auth/exchange
  This endpoint returns:
  - internalUserId
  - role
  - linkedIdentities
  - needsIdentityCollapse (boolean)
  - collapseCandidates (array)
  - session info
- If needsIdentityCollapse is true, redirect the user to an identity-collapse page.
- The identity-collapse page must:
  - explain that the authenticated external identity appears to match an existing internal user,
  - show the candidate internal user records,
  - allow the user to choose:
    - link/collapse into an existing internal user, or
    - keep as separate account if backend policy allows,
  - submit the decision to backend.
- Show linked identities such as:
  - google:<subject>
  - github:<subject>

Pages and routing:
1. /login
   - show branding/title
   - show two sign-in buttons:
     - Sign in with Google
     - Sign in with GitHub
   - both should redirect to Dex authorization endpoints supplied by configuration.
2. /auth/callback
   - process code/state returned from Dex
   - call backend to exchange session/token details
   - store authenticated session in React context
   - redirect by role:
     - superadmin -> /superadmin
     - admin -> /admin
     - owner -> /owner
     - viewer -> /viewer
   - if identity collapse is required, redirect to /identity/collapse
3. /identity/collapse
   - page to merge/link identities into one internal user
4. /superadmin
   - dashboard
   - list all users
   - list current role of each user
   - list linked providers/identities for each user
   - allow changing role with dropdown/select
   - allow promoting any user to admin, owner, viewer, or superadmin
5. /admin
   - admin dashboard
   - buttons:
     - Provision AWS
     - Provision Nutanix
     - View AWS Resources
     - View Nutanix Resources
6. /owner
   - owner dashboard
   - same overall UI shell as admin for future extension
   - show placeholder cards and permission-aware actions
7. /viewer
   - viewer dashboard
   - display internal user ID, role, login provider, linked identities
8. /logout
   - clear session
   - call backend logout endpoint
   - return to /login
9. Unauthorized page
10. Not found page

Navigation requirements:
- Every authenticated page must show:
  - current user info,
  - current role,
  - logout button.
- Render navigation links based on role.
- Use reusable protected route components:
  - RequireAuth
  - RequireRole

State management requirements:
- Use React Context for auth/session state.
- Persist only minimal session metadata in localStorage or sessionStorage.
- Do not store raw provider tokens unnecessarily in the browser.
- Keep token handling backend-centric whenever possible.

Dex integration requirements:
- Read Dex-related configuration from environment variables, for example:
  - REACT_APP_DEX_BASE_URL
  - REACT_APP_DEX_CLIENT_ID
  - REACT_APP_DEX_REDIRECT_URI
  - REACT_APP_API_BASE_URL
- Assume Dex is configured with both Google and GitHub connectors.
- Provide a sample config module and clearly separated auth utility functions.
- Implement login button behavior as redirect-to-Dex authorization URLs for each provider.
- Support OAuth2/OIDC callback flow through backend-friendly exchange logic.

Backend API contract assumptions:
Create a small frontend API client layer that calls endpoints such as:
- GET /api/session
- POST /api/auth/exchange
- POST /api/auth/collapse
- POST /api/logout
- GET /api/users
- PATCH /api/users/:id/role
- GET /api/resources/aws
- GET /api/resources/nutanix
- POST /api/provision/aws
- POST /api/provision/nutanix

Provisioning behavior:
- For AWS and Nutanix provisioning buttons, structure the code so the frontend calls backend endpoints that execute the real provisioning workflow.
- Add clear comments and placeholder adapters indicating that the backend implementation must follow the exact sequence and order of calls from:
  - test_script/scripts/provision_aws.sh
  - test_script/scripts/provision_nutanix.sh
- Do not invent cloud API sequences in the frontend.
- Instead, create clean action handlers and API abstractions that expect the backend to preserve the exact orchestration order from those scripts.

Docker/Dex requirements:
- Also generate:
  - a sample docker-compose.yml,
  - a sample dex config file,
  - a sample .env.example,
  - startup documentation in README.md.
- The sample Dex configuration must demonstrate connectors for:
  - Google
  - GitHub
- Put comments/TODO markers where client ID, client secret, issuer URL, redirect URI, and cookie/session settings must be filled in.
- the runtime output of "docker ps" is /tmp/docker.out, where the different component lives in the following directories: ./vault, ./dex, ./openfga_postgres (OpenFGA + Postgres), and system architecture are here:  ./system_design/ARCHITECTURE.md.
- other relevant architectural description are summarized below:

dex/ARCHITECTURE.md
libcloud.rest/ARCHITECTURE.md
libcloud/ARCHITECTURE.md
lldap/ARCHITECTURE.md
stoplight_mock/ARCHITECTURE.md
system_design/ARCHITECTURE.md
vault/ARCHITECTURE.md

UI requirements:
- Use plain React + JavaScript, no TypeScript.
- Use functional components and hooks.
- Keep styling simple and clean; CSS modules or plain CSS are fine.
- Provide:
  - loading states,
  - error banners,
  - success messages for role updates and provisioning actions.
- Superadmin user table should support:
  - search/filter by email or internal user ID,
  - role dropdown,
  - provider badges for linked identities.

Security requirements:
- Do not trust role values from the browser alone.
- Treat frontend role checks as UX-only; backend must enforce authorization.
- Keep auth logic modular.
- Avoid exposing provider secrets in frontend code.
- Include comments noting where CSRF/state validation and secure cookie handling belong in the full backend implementation.

Project structure:
Create the application inside:
- server/

Suggested structure:
- server/package.json
- server/README.md
- server/.env.example
- server/docker-compose.yml
- server/public/
- server/src/main entry files
- server/src/router/
- server/src/context/AuthContext.js
- server/src/components/
- server/src/pages/LoginPage.js
- server/src/pages/AuthCallbackPage.js
- server/src/pages/IdentityCollapsePage.js
- server/src/pages/SuperAdminDashboard.js
- server/src/pages/AdminDashboard.js
- server/src/pages/OwnerDashboard.js
- server/src/pages/ViewerDashboard.js
- server/src/pages/UnauthorizedPage.js
- server/src/pages/NotFoundPage.js
- server/src/services/api.js
- server/src/services/auth.js
- server/src/components/RequireAuth.js
- server/src/components/RequireRole.js
- server/src/components/Layout.js
- server/src/styles/

Implementation details:
- Make the code runnable.
- Include mock fallback data mode so the UI can be demonstrated without a live backend.
- Isolate mock mode behind a config flag.
- Include example users in mock mode:
  - predefined superadmin internal user,
  - first-login viewer,
  - sample admin user,
  - sample owner user.
- Include a sample identity-collapse scenario where a Google and GitHub login map to the same human and prompt for linking.

Deliverables:
1. Full React project code under "server".
2. Role-based routing implementation.
3. Dex login integration scaffolding for Google and GitHub.
4. Internal user creation / identity linking UI flow.
5. Superadmin user management UI.
6. Admin dashboard with buttons for AWS/Nutanix provision and resource views.
7. Logout button visible on every authenticated page.
8. README with setup, environment variables, Dex integration notes, mock mode, and route overview.

Coding style:
- Keep code modular and readable.
- Prefer small reusable components.
- Use clear names for route guards, auth state, user role checks, and API calls.
- Do not generate unnecessary complexity.
- Add brief comments only where the intent is not obvious.

Important:
- Follow the identity model where external identities authenticate through Dex, then map into an internal user record used by the platform.
- Support linking multiple providers to one internal user.
- Prompt for identity collapse when duplicate identities are detected.
- Ensure first-time users default to viewer.
- Ensure superadmin can manage all users and roles.
