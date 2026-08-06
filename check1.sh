# Here's a complete audit of everything done and found in this session.
#
#  1. Hostname / Redirect Issue (Primary Problem)
#
#  Symptom: http://login.cloudweave.xyz:3000 redirected to
#  http://localhost:3000/dex/auth?...
#
#  Root cause: PUBLIC_HOSTNAME was set to localhost everywhere, so the identity
#  service and visualizer built authorize URLs pointing to localhost (the user's
#  machine) instead of login.cloudweave.xyz (the server).
#
#  Files changed
#
#  ┌─────────────────────────┬────────────────────────────────────────────────┐
#  │          File           │                     Change                     │
#  ├─────────────────────────┼────────────────────────────────────────────────┤
#  │ .env (root) line 65     │ PUBLIC_HOSTNAME=localhost →                    │
#  │                         │ login.cloudweave.xyz                           │
#  ├─────────────────────────┼────────────────────────────────────────────────┤
#  │ .env (root) line 77     │ DEX_PUBLIC_URL=http://localhost:5556 →         │
#  │                         │ http://login.cloudweave.xyz:5556               │
#  ├─────────────────────────┼────────────────────────────────────────────────┤
#  │ server/.env line 15     │ PUBLIC_HOSTNAME=localhost →                    │
#  │                         │ login.cloudweave.xyz                           │
#  ├─────────────────────────┼────────────────────────────────────────────────┤
#  │ identity_service/.env   │ Created — PUBLIC_HOSTNAME=login.cloudweave.xyz │
#  ├─────────────────────────┼────────────────────────────────────────────────┤
#  │ openfga_visualized/.env │ Created — PUBLIC_HOSTNAME=login.cloudweave.xyz │
#  └─────────────────────────┴────────────────────────────────────────────────┘
#
#  Key discovery: docker compose .env scoping
#
#  Docker compose only reads .env from its own project directory. The
#  identity_service/ and openfga_visualized/ directories had no .env files, so
#  ${PUBLIC_HOSTNAME:-localhost} in their compose files always fell back to
#  localhost — the root .env was ignored. Creating per-directory .env files fixed
#  this.
#
#  Containers recreated
#
  cd /home/ubuntu/libcloud_nutanix/identity_service && docker compose down && docker compose up -d
  cd /home/ubuntu/libcloud_nutanix/openfga_visualized && docker compose down && docker compose up -d
#
#  Note: docker compose up -d --force-recreate did NOT work — the containers kept
#  old env vars. Only docker compose down && docker compose up -d actually
#  recreated them with the new values.
#
#  Verification commands used
#
  docker inspect identity-service --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E 'PUBLIC_HOSTNAME|DEX_BASE_URL'
  docker inspect openfga-visualizer --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E 'PUBLIC_HOSTNAME|DEX_BROWSER_URL'
  set -x
  cd identity_service
  docker compose config | grep -E 'PUBLIC_HOSTNAME|DEX_BASE_URL'  # shows resolved config
  cd ..
  cd openfga_visualized
  docker compose config | grep -E 'PUBLIC_HOSTNAME|DEX_BASE_URL'  # shows resolved config
  cd ..
  set +x
#
#  ---
#  2. CORS Configuration
#
#  File: identity_service/app/main.py:48-49
#
#  _cors_host = f"http://{PUBLIC_HOSTNAME}:3000"
#  allow_origins=[_cors_host, "http://localhost:3000"]
#
#  After the fix, PUBLIC_HOSTNAME=login.cloudweave.xyz, so CORS allows both:
#  - http://login.cloudweave.xyz:3000 (the public URL)
#  - http://localhost:3000 (local dev)
#
#  This was not a separate bug — it was the same PUBLIC_HOSTNAME variable. Once
#  the identity-service container was recreated with the correct value, CORS was
#  also fixed.
#
#  ---
#  3. LLDAP Users Missing (Current Problem)
#
#  Symptom: Dex login fails with no results returned for filter 
#  (&(objectClass=person)(uid=superadmin))
#
#  Root cause: The LLDAP Docker volume only contains the admin user. All
#  provisioned users (superadmin, aws-owner, aws-admin, ntnx-*) are gone — likely
#  because the LLDAP data volume was reset or never populated.
#
#  Verification commands used
#
  docker ps --format '{{.Names}} {{.Status}}' | grep lldap
  docker logs lldap --tail 30
  docker logs dex --tail 30
  docker inspect lldap --format '{{json .Mounts}}'
#
#  # LLDAP API: get admin token
  curl -fsS -X POST "http://localhost:17170/auth/simple/login" \
    -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"0OMzVB1LsQoIbYHGNFQL"}'
#
#  # LLDAP API: list users (only "admin" returned)
  curl -fsS -X POST "http://localhost:17170/api/graphql" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${TOKEN}" \
    -d '{"query":"{ users { id email displayName } }"}'
#
#  Fix
#
#  Run setup.sh to repopulate LLDAP users (idempotent — preserves existing
#  secrets):
#
#  cd /home/ubuntu/libcloud_nutanix && ./setup.sh
#
#  ---
#  4. Full Architecture (How the Redirect Chain Works)
#
#  Browser: login.cloudweave.xyz:3000
#    │
#    ├─ Click "Sign in with LLDAP" → JS calls /api/auth/begin
#    │    │
#    │    └─ portal nginx → identity-service:8766
#    │         │
#    │         └─ Returns authorizeUrl (built from DEX_BASE_URL)
#    │              │
#    │              └─ Now: http://login.cloudweave.xyz:3000/dex/auth?...
#    │                 (Before fix: http://localhost:3000/dex/auth?...)
#    │
#    ├─ Browser redirects to /dex/auth?...
#    │    │
#    │    └─ portal nginx → proxy_pass http://dex:5556 (preserves /dex/ prefix)
#    │         │
#    │         └─ Dex serves login form (LLDAP connector)
#    │              │
#    │              └─ Dex searches LLDAP for uid (e.g., superadmin)
#    │                   └─ LLDAP: no users found → ERROR
#    │
#    └─ On success: Dex redirects to redirect_uri
#         └─ login.cloudweave.xyz:3000/auth/callback → portal SPA
#
#  Container env vars driving this flow
#
#  ┌───────────┬────────────────┬─────────────────────┬─────────────────────┐
#  │ Container │    Env Var     │       Before        │        After        │
#  ├───────────┼────────────────┼─────────────────────┼─────────────────────┤
#  │ identity- │ PUBLIC_HOSTNAM │ localhost           │ login.cloudweave.xy │
#  │ service   │ E              │                     │ z                   │
#  ├───────────┼────────────────┼─────────────────────┼─────────────────────┤
#  │ identity- │ DEX_BASE_URL   │ http://localhost:30 │ http://login.cloudw │
#  │ service   │                │ 00/dex              │ eave.xyz:3000/dex   │
#  ├───────────┼────────────────┼─────────────────────┼─────────────────────┤
#  │ openfga-v │ PUBLIC_HOSTNAM │ localhost           │ login.cloudweave.xy │
#  │ isualizer │ E              │                     │ z                   │
#  ├───────────┼────────────────┼─────────────────────┼─────────────────────┤
#  │ openfga-v │ DEX_BROWSER_UR │ http://localhost:30 │ http://login.cloudw │
#  │ isualizer │ L              │ 00/dex              │ eave.xyz:3000/dex   │
#  ├───────────┼────────────────┼─────────────────────┼─────────────────────┤
#  │ portal    │ REACT_APP_DEX_ │ http://localhost:30 │ Falls back to       │
#  │ (CRA      │ REDIRECT_URI   │ 00/auth/callback    │ window.location.ori │
#  │ build)    │                │                     │ gin/auth/callback   │
#  └───────────┴────────────────┴─────────────────────┴─────────────────────┘
#
#  ---
#  5. Remaining Action
#
#  Run setup.sh to repopulate LLDAP users — that's the last piece blocking login:
#
#  ! cd /home/ubuntu/libcloud_nutanix && ./setup.sh
#
#✻ Baked for 27s
