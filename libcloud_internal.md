                                                                                                                                                               
  schematically draw the HTTP flow via line drawing diagram to show the relationship between Dex/LLDAP as IDAP, OpenFGA, ./libcloud.rest (directory) as        
  REST API, ./vault as secret store, and ./identity_service                                                                                                    
                                                                                                                                                               

    Read 3 files
    Read identity_service/app/main.py
    Read identity_service/app/config.py
    Read identity_service/app/libcloud_proxy.py

    Grepped, globbed, read 2 greps, 1 glob, 1 file
    Grepped "vault" in libcloud.rest
    Grepped "vault" in identity_service
    Globbed "" in .
    Read libcloud.rest/doc/security.md

    Read 2 files
    Read identity_service/docker-compose.yml
    Read libcloud.rest/docker-compose.yml

  Here's the schematic HTTP flow between the five components (plus the browser portal and cloud backends they ultimately drive). Drawn from
  identity_service/app/main.py, libcloud_proxy.py, config.py, both docker-compose.yml files, and libcloud.rest/doc/security.md.

                            ┌──────────────────────────────────────────────────────────────────────────┐
                            │                         BROWSER  (portal SPA, :3000)                        │
                            │   ../server  →  LoginPage.js / AdminDashboard.js  (api.js)                 │
                            └──────────────────────────────────────────────────────────────────────────┘
                              │ 1 GET /api/auth/begin?provider=lldap            ▲ 8 cookie libcloud_portal_sid
                              ▼ (redirect to authorizeUrl)                    │   + SessionResponse JSON
                            ┌──────────────────────────────────────────────────────────────────────────┐
                            │                          IDENTITY SERVICE  (:8766)                          │
                            │              identity_service/app/main.py  (FastAPI create_app)            │
                            │                                                                         │
                            │   AuthService   DexService   LldapService   FgaService   SessionService   │
                            │                                          UserService   LibcloudProxy        │
                            └──────────────────────────────────────────────────────────────────────────┘
         │ 2 browser→Dex            │ 4 POST /dex/token           │ 6 JWKS GET /dex/keys        │ 9 OpenFGA /check
         │   authorize URL          │   (code+PKCE+client_secret) │   verify id_token sig       │   can_view/can_provision
         │   (state+code_challenge) │   → id_token+refresh        │                             │   /can_update (authZ)
         ▼                          ▼                            ▼                             ▼
  ┌──────────────────┐   ┌──────────────────────────┐   ┌──────────────────┐        ┌──────────────────────┐
  │      DEX         │   │          DEX             │   │      DEX         │        │      OPENFGA         │
  │  /dex/auth       │   │      :5556  (OIDC)        │   │   /dex/keys      │        │   :8080 (gRPC/HTTP)  │
  │  login form      │   │   issuer: login…:5556/dex │   │   JWKS (signing) │        │   :8081 (REST /check)│
  └──────────────────┘   └──────────────────────────┘   └──────────────────┘        └──────────────────────┘
          │ 3 LDAP simple bind + userSearch (uid→sub, mail→email, cn→name)
          ▼
  ┌──────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │                                  LLDAP   (IDAP / user directory)                                      │
  │   :3890  LDAP  (bindDN uid=admin,ou=people,…  →  ou=people,dc=libcloud,dc=local)                      │
  │   :17170 HTTP/GraphQL  (updateUser → set mail; identity-collapse heuristic search)                  │
  └──────────────────────────────────────────────────────────────────────────────────────────────────────┘
          ▲                                  ▲
          │ 7 LDAP search (collapse)         │ 10 PATCH /api/users/{id}/email → GraphQL updateUser
          │   + provisioner-user lookup      │    (superadmin only; _require_role)
          └──────────────────────────────────┘
          (both calls originate from identity_service)
    ── provisioning path (authZ already passed in identity_service) ──────────────────────────────────────
                            identity_service  LibcloudProxy
                              │ 11 idp_login as provisioner (aws-admin / ntnx-admin) → Dex LDAP flow
                              │    → Bearer token, audience=libcloud-rest
                              │ 12 httpx → libcloud.rest  :8765
                              │    Authorization: Bearer <token>
                              │    X-Provider-Connection: {provider,config,auth_binding}   (NO creds in client)
                              ▼
                            ┌──────────────────────────────────────────────────────────────────────────┐
                            │                       LIBCLOUD.REST   (:8765)                            │
                            │            app/auth/authorized_route.py  (single chokepoint)            │
                            │                                                                         │
                            │  L0 policy_table  →  L1 Dex JWKS verify  →  L2 scope/provider gate       │
                            │  →  L3 OpenFGA capability check  →  L4 Vault credential brokerage        │
                            └──────────────────────────────────────────────────────────────────────────┘
                                  │ 13 JWKS GET /dex/keys         │ 14 OpenFGA /check          │ 15 KV v2 read
                                  │   (validate Bearer)            │   (capability/scope)        │   secret/data/libcloud/
                                  ▼                                ▼                             ▼
                            ┌──────────────┐            ┌──────────────────────┐        ┌──────────────────────┐
                            │     DEX      │            │       OPENFGA        │        │       VAULT          │
                            │   /dex/keys  │            │   (same store as     │        │   :8200  KV v2       │
                            │  (shared)    │            │    identity_service) │        │   <auth_binding> →   │
                            └──────────────┘            └──────────────────────┘        │   backend cloud creds│
                                                                                          └──────────────────────┘
                                                                                                    │ 16 driver call w/ resolved creds
                                                                                                    ▼
                                                                                          ┌──────────────────────┐
                                                                                          │   AWS  /  NUTANIX     │
                                                                                          │   (real cloud APIs)   │
                                                                                          └──────────────────────┘

  Key relationships, by HTTP hop:

  1. Browser → identity_service /api/auth/begin — server mints state + PKCE verifier, returns Dex authorize URL (main.py:105).
  2. Browser → Dex /dex/auth — Dex renders the LDAP login form; state + code_challenge round-trip through the browser.
  3. Dex → LLDAP LDAP simple bind + userSearch on ou=people,… — LLDAP is the user store behind Dex; the REST API never calls LLDAP at request time
     (security.md Layer 1).
  4. identity_service → Dex POST /dex/token — code→tokens exchange with PKCE verifier + dex_portal_client_secret (main.py:131, config.py:38).
  5. Browser → identity_service /api/auth/exchange with state+code — consumes single-use state, mints httpOnly libcloud_portal_sid cookie.
  6. identity_service → Dex GET /dex/keys — JWKS to verify the id_token signature/iss/aud (config.py:39, main.py:140).
  7. identity_service → LLDAP LDAP search — identity-collapse heuristic + provisioner-user lookup (lldap_host:3890).
  8. identity_service → Browser — SessionResponse (role, linkedIdentities, clouds).
  9. identity_service → OpenFGA /check — can_view / can_provision / can_update gate every /api/{resources,provision,deprovision,update}/{cloud} route
     (main.py:269,278,292,305).
  10. identity_service → LLDAP :17170 GraphQL updateUser — superadmin email change (main.py:223).
  11. identity_service → Dex (LDAP login as aws-admin / ntnx-admin) — ProvisionerAuth.get_token mints a libcloud-rest-audience bearer
      (libcloud_proxy.py:34, config.py:124).
  12. identity_service → libcloud.rest :8765 — httpx calls to /v1/compute/nodes, etc., with Authorization: Bearer + X-Provider-Connection (no client-side
      creds) (libcloud_proxy.py:60).
  13. libcloud.rest → Dex /dex/keys — re-validates the bearer token (Layer 1, security.md).
  14. libcloud.rest → OpenFGA /check — capability/scope gate (Layer 2/3).
  15. libcloud.rest → Vault :8200 KV v2 secret/data/libcloud/<auth_binding> — backend cloud credentials, keyed by the same auth_binding the client sent
      (Layer 4, security.md).
  16. libcloud.rest → AWS / Nutanix — driver call with Vault-resolved credentials.

  Net shape: Dex + LLDAP form the authentication/identity plane (LLDAP is the directory, Dex is the OIDC front door). OpenFGA is consulted twice — once by
  identity_service for portal authZ, once by libcloud.rest for capability enforcement. Vault is touched only by libcloud.rest, never by the identity service
  or the browser. identity_service is the orchestration hub; libcloud.rest is the only component that talks to real clouds.

                                                                                                                                                               
  are any of the component making any duplicated functionalities or unnecessary processing? for each components summarize what are its roles and               
  responsibilities to provide a good overview of its contribution in the system.                                                                               
                                                                                                                                                               

    Globbed, read 3 globs, 4 files
    … 4 earlier items hidden
    Read identity_service/app/fga.py
    Read identity_service/app/idp_login.py
    Read identity_service/app/users.py

    Read 2 files
    Read libcloud.rest/app/auth/fga_client.py
    Read identity_service/app/dex.py

  Per-component roles & responsibilities

  1. Browser portal (server/, :3000)

  • SPA (LoginPage.js, AdminDashboard.js) that drives the user-visible login + admin screens.
  • Calls identity_service /api/* only. Holds no auth logic — role checks there are UX-only (per fga.py:80-82).

  2. identity_service (:8766) — the orchestrator hub

  FastAPI app (app/main.py). Owns the portal-facing API contract:
  • AuthN orchestration: /api/auth/begin mints state+PKCE verifier (AuthService); /api/auth/exchange consumes them, calls Dex /dex/token (DexService),
    verifies the id_token against Dex JWKS, mints the httpOnly libcloud_portal_sid cookie (SessionService).
  • Identity resolution: UserService.resolve_on_login maps a Dex-verified external identity to an internal user, runs the identity-collapse heuristic
    against LLDAP, and seeds/revokes OpenFGA tuples on role change/disable.
  • AuthZ gate (portal-side): every /api/{resources,provision,deprovision,update}/{cloud} route runs fga.can_view/can_provision/can_update before calling
    the cloud (main.py:269,278,292,305).
  • Cloud orchestration: LibcloudProxy performs a Dex LDAP login as the per-cloud provisioner service account (ProvisionerAuth), then httpx-calls
    libcloud.rest:8765 with Authorization: Bearer + X-Provider-Connection (no client-side creds). For deprovision it shells out to
    test_script/scripts/deprovision_<cloud>.sh.
  • Admin: superadmin-only user/tuple CRUD against LLDAP (HTTP GraphQL on :17170) and OpenFGA.

  3. Dex (:5556) — OIDC issuer / IdP front door

  • OIDC issuer for two clients: libcloud-portal (the browser→identity_service flow) and libcloud-rest (the service-to-service flow).
  • Holds no users itself; its LDAP connector binds to LLDAP :3890 to authenticate humans and maps uid→sub, mail→email, cn→name.
  • Exposes /dex/auth, /dex/token, /dex/keys (JWKS).

  4. LLDAP (:3890 LDAP, :17170 HTTP) — the user directory (IDAP)

  • The actual store of users/passwords (ou=people,dc=libcloud,dc=local).
  • Consulted by Dex's LDAP connector at login time.
  • Also consulted directly by identity_service for: identity-collapse candidate lookup (LDAP search), provisioner-account password lookup, and email
    update (HTTP/GraphQL updateUser).

  5. OpenFGA (:8080/8081) — relationship-based authZ, source of truth for roles

  • Holds the tenant↔provider↔backend tuple graph (tenant:aws, tenant:nutanix, provider:aws, aws_region:aws, nutanix_cluster:nutanix, platform:main).
  • Two consumers:
    • identity_service/app/fga.py (FgaService) — portal role derivation + per-cloud can_view/can_provision/can_update + tuple CRUD for the admin screen.
    • libcloud.rest/app/auth/fga_client.py (FgaClient) — can_connect/can_use/can_provision/can_read enforcement at the REST API boundary.
  • Runs with OIDC authn against the same Dex issuer/audience, so the same JWT authorizes the /check call.

  6. libcloud.rest (:8765) — the cloud-orchestration REST API

  • One chokepoint: AuthorizedAPIRoute.custom_route_handler (security.md). Handlers contain zero auth logic.
  • Layered pipeline per request:
    • L0 policy table (policies.json) selects required scopes/capability/connection.
    • L1 Dex JWKS verifies the bearer JWT; resolve_principal maps sub→principal slug→scopes/allowed_providers.
    • L2 in-process scope + provider + credential-policy gate.
    • L3 OpenFGA can_connect/can_use/can_provision/can_read (forwards the same Dex JWT as bearer).
    • L4 Vault credential brokerage at backend-call time.
  • Talks to AWS/Nutanix with the API's own credentials (never the client's).

  7. Vault (:8200) — secret store for backend cloud credentials

  • KV v2 at secret/data/libcloud/<auth_binding>.
  • Read only by libcloud.rest (VaultClient.read_secret, 30s in-process cache). Keyed by the same auth_binding OpenFGA used as the backend object — tenant
    isolation stays consistent across authZ and credential retrieval.
  • Never touched by identity_service or the browser.

  ────────────────────────────────────────

  Duplicated / unnecessary processing

  A. OpenFGA is checked twice on every provisioning call (intentional but expensive)

  identity_service runs can_view/can_provision/can_update against OpenFGA before forwarding to libcloud.rest, which then runs can_connect + can_use +
  can_provision/can_read again (security.md Layer 3). For a single provision call that's 3 + 4 = 7 FGA /check round trips. It's defense-in-depth (the REST
  API can't trust an unauthenticated caller), but the portal-side check is redundant given the REST API enforces the same tuples. If you trust the REST API
  boundary, the portal-side per-call check could be reduced to a cheap session-role cache lookup.

  B. role_for() is a 5-call sequential fan-out, run on every login and every list_users

  FgaService.role_for (fga.py:139-152) issues up to 5 sequential OpenFGA /check calls (1 platform + 2×owner + 2×admin) to derive a single role string. It
  runs at login, at every /api/session refresh that re-checks, and inside list_all once per user (users.py:223). For N users that's 5N+ checks. A single
  /read of the user's tuples (or a cached relation lookup) would replace it.

  C. cloud_capabilities() issues 6 FGA /check calls per /api/session GET

  fga.py:276-288 runs can_view+can_provision+can_update for each of 2 clouds = 6 checks, on every session fetch. Combined with (B), a single page load after
  login can trigger 11+ OpenFGA round trips. These could be collapsed into one /read of the user's tuples and derived locally.

  D. Two near-identical OpenFGA HTTP clients

  identity_service/app/fga.py and libcloud.rest/app/auth/fga_client.py both hand-roll the same POST /stores/{id}/check wrapper with the same
  authz_fga_error/authz_fga_unavailable mapping and the same bearer-header handling. Same for /read and /write on the identity-service side. A shared
  fga-client library would remove the duplication and keep error semantics consistent.

  E. Two Dex OAuth2 code-exchange implementations in the same service

  identity_service/app/dex.py:DexService.exchange_code (browser libcloud-portal client) and identity_service/app/idp_login.py:ProvisionerAuth._full_login
  (service-account libcloud-rest client) both implement the /dex/token authorization-code exchange, JWT parsing, and refresh logic. They differ in how they
  obtain the code (browser callback vs scraping the 302 from a server-side form POST), but the token-exchange + refresh + cache logic is duplicated and
  could share a single Dex token client.

  F. Provisioner service-account login is re-run per cloud per call

  ProvisionerAuth does a full Dex LDAP form-login (GET authorize → parse form → POST credentials → exchange code) for aws-admin/ntnx-admin. There is a
  per-cloud in-process cache (_token_cache in idp_login.py), but the cache is module-local and not shared across the FgaService's own ProvisionerAuth
  instance — FgaService constructs its own ProvisionerAuth (fga.py:96) and calls get_token("aws") for every FGA /check bearer, so the cache is hit, but two
  separate ProvisionerAuth instances exist (LibcloudProxy's and FgaService's), each with its own _token_cache dict — wait, _token_cache is module-level, so
  it's actually shared. Still, the first cold call per cloud pays the full login, and the design uses a human-style LDAP login where a client-credentials
  grant or a long-lived service token would be simpler and avoid handling the provisioner password at all.

  G. deprovision re-runs the OpenFGA check inside the bash script

  identity_service already ran fga.can_provision for the deprovision route (main.py:292), then LibcloudProxy.deprovision shells out to
  deprovision_<cloud>.sh, which — per its own docstring (libcloud_proxy.py:215,286-294) — re-runs the FGA can_provision check before the curl DELETE. The
  script is described as "single source of truth," but in this path it's a second authZ point for a decision the identity service already made. Either trust
  the identity service and skip the script's check, or drop the identity-service check and rely solely on the script.

  H. LLDAP is consulted at request time by identity_service, breaking the "LLDAP is login-time-only" boundary

  security.md Layer 1 states "LLDAP is never called by the REST API at request time — it was consulted by Dex at login time." identity_service violates that
  same principle for its own request-time calls: it binds to LLDAP for the collapse heuristic, for list_users, and for set_email (GraphQL). Not strictly
  duplication, but it means LLDAP is on the hot path of admin operations, not just login. If you want LLDAP to remain a login-time-only dependency, the
  identity service should talk to it through Dex or a dedicated admin API, not direct LDAP bind.

  I. Two sources of truth for "user" state

  identity_service keeps an in-memory _pending_users registry (users.py:46) for federated users not yet linked into LLDAP, while LLDAP is the canonical
  directory. Roles for those pending users are seeded into OpenFGA keyed by int-viewer-<hex>, then re-keyed to the LLDAP uid once linked (TODO at
  users.py:181). Until that TODO is resolved, the system has two parallel user keyspaces (LLDAP uids and int-* internal ids) and a TODO-driven re-keying
  step — a classic source of "role change silently no-op'd" bugs (the comment at users.py:237-238 calls this out explicitly).

  J. Resource shape is re-mapped in identity_service

  LibcloudProxy._shape_resources (libcloud_proxy.py:105-118) re-shapes the node list returned by libcloud.rest into the portal's {id,name,state,size} form.
  Minor, but it means the REST API's contract and the portal's contract drift independently; a fields= param on the REST side would avoid the re-map.

  ────────────────────────────────────────

  Summary

  ┌───────────┬────────────────────────────────────────────────────┬───────────────────────────────────────────────────────────────────────────────────────┐
  │ Component │ Primary role                                       │ Secondary / duplicated work                                                           │
  ├───────────┼────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────┤
  │ Browser   │ UX, calls identity_service only                    │ —                                                                                     │
  │ portal    │                                                    │                                                                                       │
  ├───────────┼────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────┤
  │ identity_ │ AuthN orchestration, identity resolution, portal   │ Re-checks OpenFGA that libcloud.rest also checks (A, G); re-shapes REST output (J);   │
  │ service   │ authZ gate, cloud-call proxy, admin CRUD           │ maintains a parallel user registry (I); directly binds LLDAP (H)                      │
  ├───────────┼────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────┤
  │ Dex       │ OIDC issuer for both clients                       │ —                                                                                     │
  ├───────────┼────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────┤
  │ LLDAP     │ User directory behind Dex                          │ Also a direct dependency of identity_service admin path (H)                           │
  ├───────────┼────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────┤
  │ OpenFGA   │ Source of truth for roles/tenants                  │ Hit by both identity_service and libcloud.rest on the same provisioning request (A);  │
  │           │                                                    │ fan-out in role_for/cloud_capabilities (B, C)                                         │
  ├───────────┼────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────┤
  │ libcloud. │ Cloud REST API; layered authZ + Vault credential   │ Re-validates the bearer the identity service already obtained (necessary — different  │
  │ rest      │ brokerage                                          │ trust boundary)                                                                       │
  ├───────────┼────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────┤
  │ Vault     │ Backend credential store                           │ —                                                                                     │
  └───────────┴────────────────────────────────────────────────────┴───────────────────────────────────────────────────────────────────────────────────────┘

  The biggest concrete wins, if you want to act on this:
  1. Collapse (B) + (C) — replace role_for/cloud_capabilities fan-out with one /read + local derivation. Cuts the most FGA traffic.
  2. Decide (A) vs (G) — pick one authZ enforcement point per call (portal or REST API or script), document it, and drop the redundant check.
  3. Extract a shared fga-client and a shared dex-token-client to kill (D) and (E).
  4. Resolve (I) — finish the LLDAP re-keying TODO so there's one user keyspace.
  5. Reconsider (F) — use a client-credentials grant or a long-lived service token for the provisioner service accounts instead of replaying a human LDAP
     login.

                                                                                                                                                               
  for A - if libcloud.rest did not do the authz check, that means any one can connect to the REST API is that correct??? but if the REST API is doing          
  the authz - can be be done against the OpenFGA so that identity services need not do that at all?                                                            
                                                                                                                                                               

  Good question — let me verify exactly whose principal each OpenFGA check is evaluated against, because that determines whether the REST API's check could
  substitute for the identity service's.

    Read 2 files
    Read libcloud.rest/app/auth/identity.py
    Read libcloud.rest/app/auth/policy.py

  Short answer: my earlier framing of point A was wrong. The two OpenFGA checks are not checking the same principal — they're checking different principals,
  so they aren't actually redundant. Let me correct that with the evidence.

  Whose principal does each check evaluate?

  libcloud.rest builds the FGA user from the caller's JWT (policy.py:43-46):

  def _fga_user(self, claims: TokenClaims) -> str:
      aliases = (_load_map().get("legacy_username_aliases") or {})
      principal = aliases.get(claims.sub, claims.sub)
      return f"user:{principal}"

  claims is decoded from the Authorization: Bearer … header that the caller sent. In the portal→cloud path, that bearer is the provisioner service-account 
  token, not the portal user's:

  # identity_service/app/libcloud_proxy.py
  def _headers(self, token: str, conn: dict[str, Any]) -> dict[str, str]:
      return {
          "Authorization": f"Bearer {token}",   # token = self._auth.get_token(cloud)  ← aws-admin / ntnx-admin
          ...
      }

  So libcloud.rest's Layer-3 OpenFGA call evaluates something like:

  │ user:aws-admin can_provision aws_region:aws

  which is true by construction — aws-admin is the seeded admin of tenant:aws. It is a static configuration sanity check on the service account, not an
  authorization decision about the human who clicked the button.

  identity_service builds the FGA user from the portal user's LLDAP uid (main.py:61-65, fga.py:251-270):

  │ user:<portal-user-uid> can_provision aws_region:aws

  That is the actual human's authorization — and it is the only place it is enforced.

  Q1: If libcloud.rest didn't do its OpenFGA check, could anyone connect?

  Not "anyone on the internet." Layer 1 (Dex JWKS verify) and Layer 2 (scope + allowed_providers gate from the JWT) still run, so a caller still needs a
  valid Dex-issued JWT with aud=libcloud-rest and the right scopes for the route. Dropping Layer 3 removes the OpenFGA can_connect/can_use/can_provision
  checks — which, given the current wiring, are checking the provisioner principal and so are essentially always-true. So dropping them wouldn't change the
  portal path's security much.

  But the broader exposure is: anyone who can obtain a libcloud-rest-audience Dex JWT can call :8765 directly. That includes any LLDAP user who runs the
  idp_login.py flow themselves (the script is in the repo). Without Layer 3, a viewer-only user who grabbed a libcloud-rest token and sent
  X-Provider-Connection: {provider:aws, auth_binding:aws} would be allowed at Layer 2 only if their token's scopes included compute:node:create — and per
  identity.py:50-59, aws-viewer gets READER_SCOPES (no compute:node:create), so Layer 2 already rejects them. So Layer 2 + the principal→scope table is
  doing more of the actual work than Layer 3 is, in the current wiring.

  Net: removing libcloud.rest's OpenFGA check would not let arbitrary people provision — Layer 1+2 still gate on a valid scoped JWT — but it would remove
  the per-tenant backend-object check (can_provision aws_region:aws vs nutanix_cluster:nutanix), which is the only thing that enforces tenant isolation at
  the API boundary. That matters if you ever call the REST API with tokens that have allowed_providers=["*"] (e.g. superadmin) — Layer 3 is what stops a
  superadmin token from provisioning into a tenant it shouldn't.

  Q2: If the REST API does the authz, can identity_service stop doing it?

  Not as currently wired, no. Because the REST API sees the provisioner's token, its OpenFGA check is user:aws-admin can_provision … — always true — and
  tells you nothing about whether the portal user is allowed. If identity_service dropped its can_provision check today, a viewer-only portal user could
  click Provision, the identity service would forward aws-admin's token, and libcloud.rest would happily create the node. The portal user's authz would be
  enforced nowhere.

  To make the REST API the sole authZ point, you'd have to change the wiring so the REST API sees the portal user's identity, not the provisioner's. Two
  ways:

  • (a) Forward the portal user's own Dex JWT to libcloud.rest instead of minting a provisioner token. Then libcloud.rest's _fga_user resolves to the
    portal user, and its Layer-3 check becomes the real authz. For this to work you need:
    • the portal user's JWT to have aud=libcloud-rest (today the portal client is libcloud-portal, a different audience);
    • the portal user's JWT to carry the right scopes (today scopes are derived from the principal slug, so a viewer would get READER_SCOPES and be
      rejected at Layer 2 before OpenFGA — which is actually what you want, but it means the scope table in identity.py becomes the real authz, not
      OpenFGA);
    • the REST API to stop using its own backend identity for the cloud call, or to add a separate "act-on-behalf-of" mechanism so Vault still resolves
      the right tenant secret. Today Vault is keyed by auth_binding from X-Provider-Connection, which the caller supplies — so the portal user would need
      to be allowed to select that binding, which is exactly what OpenFGA's can_provision <backend> enforces.

  • (b) Token exchange / RFC-8693: identity_service exchanges the portal user's session for a short-lived libcloud-rest-audience token that carries the
    portal user's sub (Dex supports this via its token exchange or by issuing a custom claim). Then forward that. Same end state as (a), cleaner audience
    story.

  Either way it's a real redesign — not a flag flip — because the current architecture deliberately uses a service-account token so that the REST API holds
  the backend identity in Vault and the client never handles credentials (libcloud_proxy.py:20-23, security.md Layer 4). Forwarding the portal user's own
  token inverts that property.

  So what's the honest verdict on point A?

  I mislabeled it. The two OpenFGA checks are not redundant — they evaluate different principals for different purposes:

  ┌──────────────────────────────────────────────┬────────────────────────────────┬────────────────────────────────────────────────────────────────────────┐
  │ Check                                        │ Principal                      │ What it decides                                                        │
  ├──────────────────────────────────────────────┼────────────────────────────────┼────────────────────────────────────────────────────────────────────────┤
  │ identity_service                             │ portal user (LLDAP uid)        │ "is this human allowed to do X on cloud Y" — the real authz            │
  │ can_view/can_provision/can_update            │                                │                                                                        │
  ├──────────────────────────────────────────────┼────────────────────────────────┼────────────────────────────────────────────────────────────────────────┤
  │ libcloud.rest                                │ provisioner                    │ "is the service account configured to use this backend" — always true  │
  │ can_connect/can_use/can_provision            │ (aws-admin/ntnx-admin)         │ by design                                                              │
  └──────────────────────────────────────────────┴────────────────────────────────┴────────────────────────────────────────────────────────────────────────┘

  What is genuinely redundant / wasteful is not the existence of both checks, but:

  1. libcloud.rest's Layer-3 check is dead weight in the portal path — it always passes because the provisioner is always granted. It only earns its keep
     for direct REST API callers (scripts, other services) who forward their own token. Worth keeping for that case, but recognize it's not protecting the
     portal path.
  2. identity_service's role_for() + cloud_capabilities() fan-out (my points B and C) is the real waste — 5 + 6 = 11 sequential FGA /check calls per
     session load, just to render the portal UI. That is redundant with itself (re-deriving the same role three ways) and is the thing worth optimizing —
     collapse it to one /read of the user's tuples and derive locally.
  3. The deprovision_<cloud>.sh script re-running can_provision (my point G) is the clearest actual duplication: the identity service already checked the
     portal user, then the script checks the provisioner again (same as libcloud.rest would). Pick one.

  So: keep both boundary checks (they protect different threat models), but stop treating libcloud.rest's check as if it were enforcing the portal user's
  authz — it isn't — and fix the real redundancy in role_for/cloud_capabilities and in the deprovision script.

                                                                                                                                                               
  why per-tenant backend-object check is not done at layer 1 or 2?                                                                                             
                                                                                                                                                               

  Good question — it gets at the core of why the layers are split the way they are. The short answer: Layer 1 doesn't have the connection, and Layer 2 only 
  has static per-principal attributes — but "which tenant" is a dynamic relationship, not an attribute. Let me ground that in the code.

  What each layer actually has access to

  Layer 1 (claims_from_request → _decode_token → resolve_principal) outputs a TokenClaims with: sub, scope, allowed_providers, access_token. It only reads
  the JWT. It does not see X-Provider-Connection — that header is parsed separately by connection_from_request inside the route handler
  (authorized_route.py:18). So Layer 1 literally cannot do a per-tenant check: it has no auth_binding to check against.

  Layer 2 (authorize_connection(claims, connection, required_scope), policy.py:115-148) has both claims and connection. It checks three things, all static 
  and derived from the principal slug:
  • claims.scope contains required_scope (e.g. compute:node:create) — what operation.
  • connection.provider in claims.allowed_providers — which provider.
  • enforce_credential_policy(connection) — no client-supplied creds.

  Then it calls Layer 3.

  Layer 3 (_enforce_openfga, policy.py:73-96) builds user:<principal> from claims and <obj_type>:<auth_binding> from connection, and asks OpenFGA
  can_provision/can_read on that specific backend object.

  Why the per-tenant check can't move up to Layer 1

  Layer 1 only knows what's in the JWT. The JWT carries sub (→ principal slug), but tenant membership is not a JWT claim — it lives in the OpenFGA tuple
  graph. So even if Layer 1 had the connection, the principal→tenant mapping isn't available there. To put it in Layer 1 you'd have to bake tenant
  memberships into the token at Dex issuance time, which has three problems:

  1. Staleness. Tokens are valid until exp. If a superadmin revokes a user's admin role on tenant:aws, the user's existing token still authorizes
     tenant:aws until it expires. OpenFGA gives you real-time revocation — that's exactly why the disable action in identity_service deletes tuples
     (users.py:264-273) instead of waiting for tokens to roll.
  2. Two sources of truth. The portal's admin screen writes tuples to OpenFGA (main.py:236-248). If authz also read tenant membership from a JWT claim,
     you'd have the JWT and the tuple store disagreeing — the same duplication problem you're trying to eliminate.
  3. Coupling Dex to OpenFGA. Dex would need a custom claim provisioner that queries OpenFGA at every token issuance. Right now Dex is a pure OIDC issuer
     that knows nothing about tenants — that separation is what lets you swap either side independently.

  Why the per-tenant check can't move up to Layer 2

  Layer 2 does have the connection, so it's the only candidate. But look at what it would need: allowed_providers is a coarse provider gate derived from the
  principal slug (identity.py:61-70):

  "aws-admin"  → allowed_providers=["aws"]
  "ntnx-admin" → allowed_providers=["nutanix"]
  "superadmin" → allowed_providers=["*"]

  That answers "can this principal touch provider aws at all." It does not answer "can this principal touch auth_binding=aws but not auth_binding=aws-dev."
  The static table can't express that, because tenant membership is a many-to-many relationship, not a property of the principal:

  • aws-admin is admin of tenant:aws → can provision aws_region:aws
  • aws-dev-admin is admin of tenant:aws-dev → can provision aws_region:aws-dev
  • a future user could be admin of tenant:aws AND viewer of tenant:aws-dev

  Encoding that in PRINCIPAL_PROVIDERS would mean enumerating every (principal, tenant) pair in static config and reloading on every role change — which is
  precisely the tuple store OpenFGA exists to provide. The portal's set_role/disable_user already mutate this graph at runtime (users.py:246-273); a static
  Layer-2 table can't follow.

  There are really only two ways to move the per-tenant check into Layer 2, and both defeat the architecture:

  1. Call OpenFGA from Layer 2. Then Layer 2 is Layer 3 — you've just renamed the network call. You also lose the "cheap reject-fast gate before any
     network call" property that security.md explicitly calls out for Layer 2.
  2. Inline the tuple graph into a static table. Then you've thrown away OpenFGA's dynamic model, the admin tuple-CRUD screen, real-time revocation, and
     multi-tenant scaling — and you're back to a static ACL file.

  The deeper reason: scopes vs. relationships

  The cleanest way to see it: scopes say what, relationships say which one.

  • compute:node:create (scope, Layer 2) = "you may create nodes."
  • user:aws-admin can_provision aws_region:aws (relationship, Layer 3) = "you may create nodes in this specific tenant's backend."

  A token with compute:node:create and allowed_providers=["aws"] is necessary but not sufficient for tenant isolation — it still doesn't tell you which
  auth_binding is permitted. The auth_binding is caller-supplied in X-Provider-Connection, so without the relational check, a principal with any aws tenant
  access could target any aws tenant's backend (and thereby any tenant's Vault secret, since Vault is keyed by the same auth_binding). Layer 3 is the only
  thing that ties the caller's identity to the specific auth_binding they sent.

  So the layering is doing real work

  ┌──────┬────────────────────────────────────────────────┬──────────────────────────────────────────────────────────┬─────────────────────────────────────┐
  │ Laye │ Question it answers                            │ Data it needs                                            │ Why it's there                      │
  │ r    │                                                │                                                          │                                     │
  ├──────┼────────────────────────────────────────────────┼──────────────────────────────────────────────────────────┼─────────────────────────────────────┤
  │ 1    │ who is this, what broad scopes/providers       │ JWT only                                                 │ cheap, no network, fail-closed on   │
  │      │                                                │                                                          │ bad token                           │
  ├──────┼────────────────────────────────────────────────┼──────────────────────────────────────────────────────────┼─────────────────────────────────────┤
  │ 2    │ does the token's category allow this           │ JWT-derived attributes + connection.provider             │ cheap reject-fast, no network,      │
  │      │ op+provider                                    │                                                          │ static                              │
  ├──────┼────────────────────────────────────────────────┼──────────────────────────────────────────────────────────┼─────────────────────────────────────┤
  │ 3    │ is this principal related to this specific     │ principal (from JWT) + auth_binding (from connection) +  │ the only layer that knows tenant    │
  │      │ tenant backend                                 │ tuple graph                                              │ membership                          │
  └──────┴────────────────────────────────────────────────┴──────────────────────────────────────────────────────────┴─────────────────────────────────────┘

  The per-tenant check is inherently relational and dynamic, so it lives in the relational layer. Moving it up would either collapse Layer 2 into Layer 3
  (no benefit) or replace the tuple graph with static config (losing everything OpenFGA was added for). Layer 2's allowed_providers already does the
  provider-level isolation that's statically knowable; Layer 3 does the tenant-within-provider isolation that isn't.

                                                                                                                                                               
  can i eliminate the need for identity services and totally separate the role authz (by OpenFGA) and authn (by Authentik) and Authentik will also             
  replace the existing role of Dex, and thus the entire libcloud.rest layer will just implement the functional logic of orchestrating the access to the        
  Libcloud Apache layer.                                                                                                                                       
                                                                                                                                                               

  Yes, this is feasible and architecturally cleaner than the current setup — but it has one non-negotiable design decision and three things you have to
  re-home. Let me lay out what you'd actually be doing.

  The non-negotiable decision

  The whole reason identity_service exists today is the audience bridge: portal users get libcloud-portal-audience tokens, but libcloud.rest requires
  libcloud-rest-audience tokens. The identity service bridges that by logging in as a per-cloud provisioner service account (aws-admin/ntnx-admin) and
  forwarding that token to libcloud.rest (libcloud_proxy.py:60-65, idp_login.py).

  If you eliminate identity_service, you must pick one of:

  • (A) The portal user's own Authentik JWT authorizes libcloud.rest directly. One audience for both. No service-account bridge. libcloud.rest's Layer
    1/2/3 enforce the real user's authz, not the provisioner's. This is the option that actually lets you delete identity_service.
  • (B) libcloud.rest itself mints/obtains a service-account token. Then libcloud.rest is doing what identity_service did — you've moved the code, not
    eliminated it.

  So "eliminate identity_service" really means "commit to (A)." That's a real change: today libcloud.rest's OpenFGA check is on the provisioner principal
  (always-true, as we established last turn); under (A) it becomes the actual user authz. That's a strengthening of the security posture, not a weakening —
  and it dissolves my earlier point A entirely.

  What the new architecture looks like

     Browser (portal SPA)
       │  Authentik OIDC code flow (PKCE)
       ▼
     Authentik  (:9000 / :9443)        ← replaces Dex; can also absorb LLDAP as a source
       │  id_token + access_token (aud=libcloud-rest)
       ▼
     Browser holds JWT (in-memory OR via oauth2-proxy / Authentik proxy outpost session)
       │  Authorization: Bearer <user's own JWT>
       │  X-Provider-Connection: {provider, config, auth_binding}
       ▼
     libcloud.rest  (:8765)
       │  L0 policy table
       │  L1 verify JWT vs Authentik JWKS  →  resolve_principal(sub) → scopes/providers
       │  L2 scope + provider + credential-policy gate
       │  L3 OpenFGA /check  (user:<principal> can_provision <obj_type>:<auth_binding>)
       │  L4 Vault read secret/data/libcloud/<auth_binding>  →  backend cloud creds
       ▼
     AWS / Nutanix

  OpenFGA is reconfigured to trust Authentik as its OIDC issuer (it already supports --authn-method=oidc; just point it at Authentik's JWKS). The principal
  slug convention (aws-admin, ntnx-viewer, …) stays — it's just resolved from an Authentik JWT instead of a Dex JWT.

  What you gain by deleting identity_service

  • One less service in the critical path. No more :8766 hop on every portal API call.
  • Real user attribution in libcloud.rest's audit logs. Today logs say "aws-admin did X" (always). After: "ntnx-viewer did X" — actually useful.
  • My earlier points A, D, E, F, G, I all dissolve:
    • (A) the duplicate OpenFGA check — gone, because there's no portal-side check anymore; libcloud.rest's check is the real one.
    • (D) two near-identical FGA HTTP clients — only libcloud.rest/app/auth/fga_client.py remains.
    • (E) two Dex token-exchange implementations — gone.
    • (F) provisioner LDAP-login-as-human hack — gone (use Authentik client-credentials for service accounts, or just drop service accounts entirely under
      option A).
    • (G) deprovision script re-running FGA — gone, since there's no identity-service pre-check to duplicate.
    • (I) the parallel _pending_users registry — gone; Authentik is the only directory.
  • LLDAP can be retired if you let Authent- LLDAP can be retired if you let Authentik be the directory (it has its own user store + LDAP source support).
    One directory instead of two.
  • Simpler mental model: Authentik authenticates, OpenFGA authorizes, libcloud.rest orchestrates, Vault secrets. Four boxes, one arrow each.

  What you have to re-home (the real cost)

  Three responsibilities currently live in identity_service and have to go somewhere:

  1. Session management (SessionService: httpOnly cookie + server-side refresh-token storage). The current design protects the JWT from XSS via a cookie.
     If you delete identity_service, you have three options:
    • oauth2-proxy / Traefik forward-auth / Authentik's embedded proxy outpost in front of libcloud.rest. The proxy holds the session cookie, validates it
      against Authentik, and forwards the JWT as an Authorization: Bearer header to libcloud.rest. This preserves the httpOnly-cookie property.
      Recommended.
    • SPA holds the JWT in memory (refresh via silent renew). Simpler, but XSS-exposed.
    • Rebuild a thin BFF — which is just identity_service by another name. Don't do this.

  2. Identity-collapse heuristic (UserService.resolve_on_login + apply_collapse): when a federated login (Google/GitHub) email-matches an existing LLDAP
     user, prompt to link. Real business logic. Three options:
    • Move it into Authentik's policy/flow engine. Authentik has expression policies and custom stages; this is the natural home. Learning curve, but it's
      where this kind of logic belongs in an Authentik-centric architecture.
    • Move it into libcloud.rest as a first-login hook. A /v1/identities:resolve route that runs the heuristic on first sighting of a sub. Keeps the logic
      in code, not in policy config.
    • Drop it. Simplify the model to "one Authentik user = one principal, no federation collapse." Only viable if you actually want federated users to be
      distinct accounts.

  3. Admin screens (/api/users, /api/tuples, role set/disable, email update):
    • User CRUD → Authentik's admin UI (it has one). Drop the portal's user screen.
    • Tuple CRUD → thin admin route in libcloud.rest (superadmin-only, already gated by Layer 2 scope check), or use OpenFGA's own UI/API.
    • Role assignment → same thin admin route, writes to OpenFGA.

  What you do not lose

  • "API holds its own backend identity in Vault, client never handles credentials." This property is about Vault creds, not the JWT. Vault stays keyed by
    auth_binding; the caller still selects it via X-Provider-Connection; OpenFGA still enforces can_provision <obj_type>:<auth_binding>. Switching from a
    provisioner JWT to the user's JWT doesn't touch this — the client still never sees AWS/Nutanix keys.
  • Per-tenant isolation. Still enforced by Layer 3, now against the real user principal (stronger, not weaker).
  • Real-time revocation. Still works — disable = delete OpenFGA tuples, takes effect on the next /check, no token blocklist needed.

  Migration checklist

  1. Stand up Authentik. Configure an OIDC provider with audience libcloud-rest. Migrate users from LLDAP (Authentik can read LLDAP as a source first,
     then absorb them).
  2. Reconfigure OpenFGA: --authn-method=oidc pointing at Authentik's JWKS/issuer instead of Dex's.
  3. Ensure Authentik JWTs carry claims resolve_principal can map (sub, email, preferred_username). Either keep the <tenant>-<role> username convention in
     Authentik, or update principal_map / resolve_principal to use Authentik groups/attributes.
  4. Put an auth proxy (oauth2-proxy or Authentik proxy outpost) in front of libcloud.rest. It validates the Authentik session and forwards the user's JWT
     as Authorization: Bearer.
  5. Update the portal SPA to call libcloud.rest directly (the /v1/compute/* routes already exist). Remove the /api/* indirection.
  6. Re-home the collapse heuristic (pick one of the three options above) or drop it.
  7. Add a thin /v1/admin/tuples CRUD route in libcloud.rest for the superadmin screen, or point the admin at OpenFGA's UI.
  8. Decommission identity_service, Dex, and (optionally) LLDAP.

  When not to do this

  • If you need the portal user's JWT to not be accepted by libcloud.rest directly (e.g. you want libcloud.rest callable only by service accounts, never
    by humans), then you need the audience bridge and identity_service (or something doing its job) stays.
  • If the collapse heuristic is load-bearing and you don't want to learn Authentik's policy engine, the cost of re-homing it may exceed the benefit of
    deleting identity_service.
  • If you have no appetite for a migration that touches the IdP, OpenFGA config, the portal SPA, and libcloud.rest's middleware in one coordinated cut,
    defer it.

  Bottom line

  Yes, it's feasible and it's the right direction. The current identity_service exists almost entirely to bridge the audience gap and hold the session
  cookie — both of which have standard solutions (single audience + auth proxy) that don't require a custom service. Deleting it lets libcloud.rest's
  existing auth pipeline become the real authz enforcement point, dissolves six of the duplication/redundancy points from my earlier analysis, and gives you
  one IdP (Authentik) instead of two (Dex + LLDAP). The cost is one non-trivial migration and re-homing the collapse heuristic.

                                                                                                                                                               
  since Authentik have policy and flow engine, is that not duplicating the role of OpenFGA?                                                                    
                                                                                                                                                               

  They overlap only if you let them. Both can answer "is this user allowed to do X," but they're built for very different shapes of "X," and the duplication
  only appears if you start using Authentik policies for tenancy decisions (or OpenFGA for login-flow decisions). Draw the line deliberately and they stay
  complementary.

  What each is actually built for

  Authentik flows + policies decide things at the identity boundary:
  • Who can log in, who needs MFA, which flow applies to this user.
  • Who can see which application (the libcloud portal as a whole).
  • Can a federated login be linked to an existing account (the collapse heuristic).
  • Can the user self-enroll, reset password, access the admin console.

  Inputs: user attributes, group memberships, request context, session. These are all IdP-owned data. The engine is a state machine for login UX plus
  boolean expressions over identity attributes.

  OpenFGA decides things at the resource boundary:
  • Can this principal can_provision aws_region:aws.
  • Can this principal can_read nutanix_cluster:nutanix.
  • Can this principal can_update a specific VM.

  Inputs: the tuple graph — user:alice admin tenant:aws, tenant:aws parent aws_region:aws, etc. These are application-owned data. The engine is a ReBAC
  graph evaluator with a /check API designed for per-request enforcement at high throughput.

  The clean dividing line

  ┌───────────────────────────────────────────────────────────────────┬────────────────────────────────────────────┐
  │ Decision                                                          │ Owner                                      │
  ├───────────────────────────────────────────────────────────────────┼────────────────────────────────────────────┤
  │ Is this token valid? Who is the subject?                          │ Authentik (Layer 1)                        │
  ├───────────────────────────────────────────────────────────────────┼────────────────────────────────────────────┤
  │ May this user log in at all? MFA required?                        │ Authentik flow                             │
  ├───────────────────────────────────────────────────────────────────┼────────────────────────────────────────────┤
  │ May this user see the portal application?                         │ Authentik policy (application access gate) │
  ├───────────────────────────────────────────────────────────────────┼────────────────────────────────────────────┤
  │ Is this federated identity linkable to an existing account?       │ Authentik flow (collapse heuristic)        │
  ├───────────────────────────────────────────────────────────────────┼────────────────────────────────────────────┤
  │ May this user provision a node in tenant:aws?                     │ OpenFGA (Layer 3)                          │
  ├───────────────────────────────────────────────────────────────────┼────────────────────────────────────────────┤
  │ May this user read nutanix_cluster:nutanix?                       │ OpenFGA                                    │
  ├───────────────────────────────────────────────────────────────────┼────────────────────────────────────────────┤
  │ Which auth_binding may this user select in X-Provider-Connection? │ OpenFGA                                    │
  ├───────────────────────────────────────────────────────────────────┼────────────────────────────────────────────┤
  │ Which Vault secret does the API use for this auth_binding?        │ Vault (not a policy decision)              │
  └───────────────────────────────────────────────────────────────────┴────────────────────────────────────────────┘

  The split is the classic one: Authentik answers "are you authenticated and may you enter," OpenFGA answers "given you're in, may you touch this specific 
  resource." As long as you keep tenancy decisions out of Authentik and identity-flow decisions out of OpenFGA, there's no duplication.

  Where duplication creeps in (and how to avoid it)

  The danger zone is role assignment. You'll be tempted to model "alice is admin of tenant:aws" as Authentik group membership (aws-admins group) and check
  it via an Authentik policy — because Authentik groups are right there and you already have an admin UI for them. If you do that, you now have two stores
  of truth for the same fact (Authentik group + OpenFGA tuple), and they will drift. Pick one:

  • OpenFGA is the source of truth for tenancy roles. The admin "set role" action writes an OpenFGA tuple. Authentik groups are only for IdP-level
    concerns (MFA-required, console-access, password-reset-allowed). The portal's role screen talks to OpenFGA, not to Authentik. Recommended.
  • Authentik groups are the source of truth, mirrored to OpenFGA by a sync job. Then OpenFGA becomes a derived cache, not the source. You've effectively
    replaced OpenFGA with "Authentik groups + a syncer + your own graph traversal code." Don't do this — see below.

  Why Authentik groups can't replace OpenFGA

  Authentik groups are flat. They can express "alice is in the aws-admins group." They cannot express:

  • tenant:aws parents aws_region:aws (so an admin of the tenant inherits can_provision on the region).
  • provider:aws parents aws_region:aws and aws_region:aws-dev (so a member of tenant:aws can_use provider:aws but only can_provision their own region,
    not the dev region).
  • user:alice viewer tenant:aws ∪ user:alice admin tenant:nutanix (one user, two roles, two tenants — without enumerating every (user, tenant) pair).

  OpenFGA's tuple graph encodes these relationships and evaluates them at /check time. To replace it with Authentik groups you'd have to flatten the graph
  into one group per (tenant, role) pair, write your own traversal code in libcloud.rest, and re-implement can_provision/can_read/can_update as
  group-membership lookups plus your own logic. That's exactly what OpenFGA was added to avoid, and you'd lose the high-throughput /check API that
  libcloud.rest's Layer 3 calls on every request.

  So Authentik policies could do resource authz, but they'd be a poor fit — flat, no graph, no per-object relations, no request-time /check API. OpenFGA
  could do login-flow decisions, but it'd be a poor fit — no UI, no concept of stages, no notion of authentication. Use each for what it's built for.

  One legitimate cross-over

  Authentik expression policies can call external HTTP endpoints. If you ever need a flow stage gated on a resource authz decision — e.g. "only users who
  can_provision aws_region:aws may enroll the AWS-specific MFA factor" — an Authentik expression policy can call OpenFGA's /check. That's not duplication;
  it's Authentik delegating the authz part to OpenFGA. Rare, but clean when you need it.

  Bottom line

  Authentik's policy/flow engine and OpenFGA solve different problems that sound similar ("who can do what"). Authentik owns identity lifecycle and
  access-to-the-IdP-protected-surface; OpenFGA owns tenancy and resource authz. They only duplicate if you put tenancy roles in Authentik groups (or
  login-flow logic in OpenFGA tuples). Keep tenancy in OpenFGA, keep identity in Authentik, and the two engines stay complementary — and the collapse
  heuristic I suggested moving to Authentik last turn is identity logic, not authz, so it goes in Authentik's flow engine without colliding with OpenFGA.

                                                                                                                                                               
  in the table "the clean dividing line" above: how is the existing architecture (which consists of Dex/OpenFGA/libcloud.rest REST/identity                    
  service/LLDAP) filling up the table?                                                                                                                         
                                                                                                                                                               

  Same table, filled in with the current architecture's owners. The interesting thing is what it reveals about gaps and duplications.

  ┌─────────────────┬──────────────────────────────────────────────────────────┬───────────────────────────────────────────────────────────────────────────┐
  │ Decision        │ Current owner(s)                                         │ Notes / gaps                                                              │
  ├─────────────────┼──────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────┤
  │ Is this token   │ Dex (issuer) + identity_service                          │ Validated twice on the portal→cloud path: once for the portal user's      │
  │ valid? Who is   │ DexService.verify_id_token (portal path,                 │ id_token at /api/auth/exchange, once for the provisioner's access_token   │
  │ the subject?    │ aud=libcloud-portal) + libcloud.rest Layer 1 (API path,  │ at libcloud.rest's boundary. Different tokens, different audiences, same  │
  │                 │ aud=libcloud-rest)                                       │ Dex JWKS — so two JWKS fetches + two signature checks per provisioning    │
  │                 │                                                          │ call.                                                                     │
  ├─────────────────┼──────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────┤
  │ May this user   │ Dex (login form / connector chooser) + LLDAP (password   │ No MFA configured — Dex's LDAP connector does a single password bind. No  │
  │ log in at all?  │ bind via Dex's LDAP connector)                           │ account-state check beyond LLDAP accepting the bind.                      │
  │ MFA required?   │                                                          │                                                                           │
  ├─────────────────┼──────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────┤
  │ May this user   │ Nobody, explicitly. Implicit "any LLDAP user can reach   │ Gap. A disabled-in-LLDAP-but-still-boundable user, or a brand-new viewer  │
  │ see the portal  │ the portal." identity_service's session check on /api/*  │ with no tenant, can still load the SPA and see the screens — they just    │
  │ application?    │ is the de facto gate, but there's no IdP-level "may this │ can't call any /api/* successfully.                                       │
  │                 │ user access this application" decision.                  │                                                                           │
  ├─────────────────┼──────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────┤
  │ Is this         │ identity_service UserService.resolve_on_login +          │ Identity-flow logic living in the orchestrator, not in the IdP. This is   │
  │ federated       │ apply_collapse +                                         │ the architectural smell I flagged earlier (point H) — LLDAP is supposed   │
  │ identity        │ AuthService.issue_pending/consume_pending                │ to be login-time-only, but the collapse heuristic makes identity_service  │
  │ linkable to an  │                                                          │ an identity-resolution service too.                                       │
  │ existing        │                                                          │                                                                           │
  │ account?        │                                                          │                                                                           │
  ├─────────────────┼──────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────┤
  │ May this user   │ identity_service FgaService.can_provision → OpenFGA      │ The actual user authz is enforced only by identity_service.               │
  │ provision a     │ (real user authz, main.py:278). libcloud.rest Layer 3    │ libcloud.rest's Layer 3 check is dead weight in the portal path — it      │
  │ node in         │ also calls OpenFGA, but on the provisioner principal     │ checks a different principal and always passes.                           │
  │ tenant:aws?     │ (user:aws-admin), which is always-true by design.        │                                                                           │
  ├─────────────────┼──────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────┤
  │ May this user   │ Same split: identity_service FgaService.can_view         │ Same duplication as row 5.                                                │
  │ read            │ (main.py:269) is the real check; libcloud.rest Layer 3   │                                                                           │
  │ nutanix_cluster │ can_read runs on the provisioner principal.              │                                                                           │
  │ :nutanix?       │                                                          │                                                                           │
  ├─────────────────┼──────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────┤
  │ Which           │ identity_service LibcloudProxy._connection hardcodes one │ The "which binding may they select" question isn't really exposed today — │
  │ auth_binding    │ binding per cloud (aws_auth_binding / ntnx_auth_binding  │ there's exactly one binding per cloud. If you ever add tenant:aws-dev,    │
  │ may this user   │ from settings, libcloud_proxy.py:40-58). The portal user │ the current code can't represent the user choosing between aws and        │
  │ select in       │ never selects; the identity_service picks based on the   │ aws-dev; you'd have to add a parameter and let OpenFGA enforce the        │
  │ X-Provider-Conn │ route.                                                   │ choice.                                                                   │
  │ ection?         │                                                          │                                                                           │
  ├─────────────────┼──────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────┤
  │ Which Vault     │ libcloud.rest Layer 4 resolve_server_credentials → Vault │ Clean. One owner, one store. identity_service and the browser never touch │
  │ secret does the │ KV v2 secret/data/libcloud/<binding>                     │ Vault.                                                                    │
  │ API use for     │ (credentials.py:82-124).                                 │                                                                           │
  │ this            │                                                          │                                                                           │
  │ auth_binding?   │                                                          │                                                                           │
  └─────────────────┴──────────────────────────────────────────────────────────┴───────────────────────────────────────────────────────────────────────────┘

  What the mapping reveals

  Comparing this to the Authentik-based target table from the previous turn, three things stand out:

  1. Row 4 (collapse) is the misplaced responsibility. It's identity-flow logic (linking a federated subject to an existing account) sitting in the
     orchestrator. In the target architecture it moves to Authentik's flow engine — its natural home. Today it's in identity_service because Dex has no
     flow engine to put it in.

  2. Rows 5/6 (provision/read) are the duplicated work. Two OpenFGA /check calls per provisioning request, on different principals, only one of which is
     the real authz. The other (libcloud.rest Layer 3 on the provisioner) is structurally always-true. In the target architecture, with the portal user's
     own JWT forwarded, libcloud.rest's Layer 3 becomes the single real check and identity_service's goes away.

  3. Row 3 (app access gate) is the missing responsibility. No component today decides "may this user see the portal." Authentik's application-access
     policy fills this cleanly in the target architecture; in the current architecture it's an implicit "any LLDAP user," which is fine while LLDAP is the
     only directory but becomes a real gap if you ever federate (Google/GitHub users would all see the portal too, even with no tenant).

  Rows 1, 7, 8 are essentially unchanged between the two architectures — same owner, same mechanism, just with Authentik substituted for Dex. The
  substantive differences are rows 3, 4, 5, 6, which is exactly the surface area identity_service exists to cover today and which the Authentik + OpenFGA
  split absorbs natively.

                                                                                                                                                               
  when user connected to the Dex/LLDAP initiate a logout in the current application design, are all the sessions in OpenFGA/libcloud.rest REST                 
  API/identity session all logout at the same time?                                                                                                            
                                                                                                                                                               

    Read identity_service/app/session.py

  No. Only the identity_service cookie is actually cleared. Everything else stays alive. Let me trace it through the code.

  What POST /api/logout actually does today

  # identity_service/app/main.py:196-201
  @app.post("/api/logout")
  def logout(req: Request, resp: Response):
      # TODO: revoke the Dex refresh token at Dex's revocation endpoint using
      # the server-side refresh token from sessions._refresh_store.
      sessions.revoke(req, resp)
      return {"logged_out": True}

  # identity_service/app/session.py:82-91
  def revoke(self, req: Request, resp: Response) -> None:
      s = self._settings()
      token = req.cookies.get(s.session_cookie_name)
      if token:
          try:
              claims = self._decode(token)
              _refresh_store.pop(claims.get("sid", ""), None)  # drop refresh token from memory
          except APIError:
              pass
      resp.delete_cookie(s.session_cookie_name, path="/")      # delete the cookie

  That's the entire logout. Two things happen: the cookie is deleted, and the Dex refresh token is dropped from the in-memory _refresh_store. The TODO is
  explicit: Dex's revocation endpoint is never called.

  State of each component after logout

  ┌───────────────────────┬──────────────────────────────────────────┬───────────────────────────────────────────────────────┬─────────────────────────────┐
  │ Component             │ Holds a session?                         │ State after POST /api/logout                          │ Actually logged out?        │
  ├───────────────────────┼──────────────────────────────────────────┼───────────────────────────────────────────────────────┼─────────────────────────────┤
  │ identity_service      │ Yes — httpOnly cookie                    │ Cookie deleted, _refresh_store entry popped           │ ✅ Yes                      │
  │                       │ libcloud_portal_sid + in-memory          │                                                       │                             │
  │                       │ _refresh_store[sid]                      │                                                       │                             │
  ├───────────────────────┼──────────────────────────────────────────┼───────────────────────────────────────────────────────┼─────────────────────────────┤
  │ Dex refresh token     │ N/A — it's a token, not a session        │ Dropped from _refresh_store but not revoked at Dex.   │ ❌ No — TODO at main.py:198 │
  │ (the one              │                                          │ Still valid at Dex until natural expiry.              │                             │
  │ identity_service      │                                          │                                                       │                             │
  │ held)                 │                                          │                                                       │                             │
  ├───────────────────────┼──────────────────────────────────────────┼───────────────────────────────────────────────────────┼─────────────────────────────┤
  │ Dex SSO session       │ Yes — Dex's own session cookie           │ Untouched. The user is still SSO-logged-in at Dex.    │ ❌ No — not even attempted  │
  │ (browser cookie on    │                                          │ Clicking "log in" again may skip the password prompt  │                             │
  │ Dex's domain)         │                                          │ entirely.                                             │                             │
  ├───────────────────────┼──────────────────────────────────────────┼───────────────────────────────────────────────────────┼─────────────────────────────┤
  │ Provisioner token     │ Yes — module-level dict, keyed by cloud, │ Untouched. Persists across user logouts by design —   │ ❌ No — by design           │
  │ cache                 │ holds the aws-admin/ntnx-admin           │ the provisioner is a service account, not tied to any │                             │
  │ (idp_login._token_cac │ access+refresh tokens                    │ user session.                                         │                             │
  │ he)                   │                                          │                                                       │                             │
  ├───────────────────────┼──────────────────────────────────────────┼───────────────────────────────────────────────────────┼─────────────────────────────┤
  │ OpenFGA               │ No — stateless. Each /check is           │ Still answering /check calls because the              │ ❌ N/A — nothing to log     │
  │                       │ authenticated by the provisioner's JWT.  │ provisioner's JWT is still valid (see row above).     │ out, but still serving the  │
  │                       │                                          │                                                       │ provisioner                 │
  ├───────────────────────┼──────────────────────────────────────────┼───────────────────────────────────────────────────────┼─────────────────────────────┤
  │ libcloud.rest         │ No — stateless. Validates the bearer JWT │ Still accepting calls from anyone holding the         │ ❌ N/A — nothing to log     │
  │                       │ per request.                             │ provisioner's token, which is still valid.            │ out, but still accepting    │
  ├───────────────────────┼──────────────────────────────────────────┼───────────────────────────────────────────────────────┼─────────────────────────────┤
  │ LLDAP                 │ No — pure LDAP bind, no session          │ N/A                                                   │ ❌ N/A                      │
  └───────────────────────┴──────────────────────────────────────────┴───────────────────────────────────────────────────────┴─────────────────────────────┘

  What this means in practice

  1. The portal cookie is gone, so the SPA can't call /api/* anymore — that's the only thing logout actually achieves. From the user's perspective, "I'm
     logged out."

  2. Dex still considers the user logged in. The Dex SSO session cookie in the browser is untouched. If the user clicks "log in" again, Dex will likely
     recognize them and issue a fresh code without a password prompt. This is the classic "single logout isn't implemented" gap — you have single sign-on
     but not single logout.

  3. The Dex refresh token identity_service held is still valid at Dex. It's just not in identity_service's memory anymore, so identity_service can't use
     it. But if it was exfiltrated before logout, the attacker can still use it against Dex until it expires. The TODO at main.py:198 acknowledges this.

  4. The provisioner token cache is completely decoupled from user sessions. It's keyed by cloud, not by user. When user A logs out and user B logs in,
     user B's provisioning call will hit the same cached provisioner token user A's call populated. The provisioner's access to libcloud.rest is
     continuous across all user logouts — it's a standing credential that outlives every individual user session.

  5. OpenFGA and libcloud.rest keep serving the provisioner. Because they're stateless and authenticate the provisioner's JWT (not the portal user's), and
     the provisioner's token is still valid (row 4), they keep answering requests. There's no per-user session in either of them to revoke.

  6. No per-user audit attribution in libcloud.rest anyway. Even before logout, libcloud.rest's logs say "aws-admin did X," not "alice did X." So logout
     doesn't change the audit trail — there's nothing user-attributed to clear.

  The gaps, in order of severity

  1. Dex SSO session not terminated — the user is still logged in at the IdP. This is the most visible gap: a "logout" button that doesn't actually log
     you out of the IdP. Fix: redirect the browser to Dex's /dex/logout endpoint after clearing the portal cookie (Dex supports RP-initiated logout, and
     optionally back-channel logout to federated providers).
  2. Dex refresh token not revoked — the TODO. Fix: call Dex's revocation endpoint with the refresh token from _refresh_store before popping it.
  3. Provisioner token cache not scoped to user sessions — by design, but worth noting. If you ever want "logout revokes the user's ability to drive cloud
     operations," you'd need to either (a) tie the provisioner token to the user's session lifetime (defeats the service-account model) or (b) accept that
     the provisioner is always-on and rely on OpenFGA's per-call authz to deny logged-out users (which works today, since the next user's /check will be on
     their own principal, not the previous user's). Option (b) is fine — but it means "logout" is purely a portal-cookie concern, not a system-wide
     session termination.
  4. No token blocklist anywhere — even if you fix (1) and (2), already-issued access tokens (short-lived) and the provisioner's cached token (long-lived)
     can't be revoked mid-flight. Standard JWT limitation; the mitigation is short access-token TTLs + refresh-token revocation, which (2) addresses for
     the portal user's refresh token but not for the provisioner's.

  How the Authentik-based target architecture changes this

  Worth noting since you were exploring it: under the Authentik + auth-proxy design from the earlier turn, logout is cleaner if you wire it up:

  • Authentik has first-class RP-initiated logout and back-channel logout (it can terminate the IdP session and notify federated providers).
  • The auth proxy (oauth2-proxy / Authentik proxy outpost) clears its own session cookie and redirects to Authentik's logout endpoint.
  • libcloud.rest and OpenFGA are still stateless — nothing to log out, but they're now authenticating the user's JWT, not the provisioner's, so once the
    auth-proxy session is gone, the browser can't get a fresh JWT to call them. The standing-credential problem (row 4 above) dissolves because there's no
    provisioner token cache anymore.

  So the same "single logout" property that's a TODO in the current architecture is built into Authentik by default. The current architecture's logout is
  essentially "delete one cookie and hope" — and the TODO comment in main.py:198 is the honest acknowledgment of that.

                                                                                                                                                               
  construct multiple curl to the different docker: first login at the Dex using one of the authenticated user in LLDAP, then after login, use that             
  cookie and JWT and access the cloud resources. then issue a logout, and demonstrate how the JWT or cookie can be reuse to access the backend resources       
  directly (libcloud.rest REST API) ? (assuming the frontend via Dex will be blocked). demonstrate all the different possible curl requests that can be        
  issued directly to the different docker in the system? (see "docker ps" for all the possible server running)                                                 
                                                                                                                                                               

  Let me first see what's actually running and grab the relevant config to make the curls accurate.

  $ docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Networks}}' 1.4s
    … 9 output lines hidden · ctrl+o to expand
    stoplight_mock-emulator-1   stoplight_mock-emulator            0.0.0.0:9440->9440/tcp, [::]:9440->9440/tcp                                               …
    stoplight_mock-prism-1      stoplight/prism:5                  0.0.0.0:4010->4010/tcp, [::]:4010->4010/tcp                                               …

  $ docker exec dex ls /etc/dex && echo '---' && docker exec dex cat /etc/dex/config.yaml 2>/dev/null | head -100 630ms
    … 94 output lines hidden · ctrl+o to expand
          # TODO: restrict via orgs/teams if you want group claims.

  $ ls /home/ubuntu/libcloud_nutanix/dex/generated/ 2>/dev/null && echo '---env---' && cat /home/ubuntu/libcloud_nutanix/dex/generated/dex.env 2>/dev/null |
    sed 's/SECRET=.*/SECRET=<redacted>/' | sed 's/PASSWORD=.*/PASSWORD=<redacted>/' 451ms
    … 40 output lines hidden · ctrl+o to expand
    DEX_GITHUB_CLIENT_ID=Ov23liBwYgY2Fub4RuV4
    DEX_GITHUB_CLIENT_SECRET=<redacted>

  $ ls /home/ubuntu/libcloud_nutanix/lldap/ 2>/dev/null && echo '---' && cat /home/ubuntu/libcloud_nutanix/lldap/.env 2>/dev/null | sed
    's/PASS=.*/PASS=<redacted>/' | sed 's/SECRET=.*/SECRET=<redacted>/' 428ms
    … 18 output lines hidden · ctrl+o to expand
    LLDAP_HTTP_PORT=17170
    LLDAP_LDAP_PORT=3890

  $ cat /home/ubuntu/libcloud_nutanix/openfga_postgres/generated/fga.env 2>/dev/null | sed 's/TOKEN=.*/TOKEN=<redacted>/' && echo '---policies---' && cat
    /home/ubuntu/libcloud_nutanix/libcloud.rest/app/auth/policies.json 2>/dev/null | head -80 377ms
    … 83 output lines hidden · ctrl+o to expand
        "scopes_any_of": ["compute:snapshot:manage"]
      },

  $ cat /home/ubuntu/libcloud_nutanix/libcloud.rest/.env 2>/dev/null | sed 's/SECRET=.*/SECRET=<redacted>/' | sed 's/TOKEN=.*/TOKEN=<redacted>/' | sed
    's/PASS=.*/PASS=<redacted>/' | head -40 523ms
    … 38 output lines hidden · ctrl+o to expand
    LIBCLOUD_REST_NUTANIX_HOST=host.docker.internal
    NUTANIX_PORT=9440

    Read identity_service/app/auth_state.py

  Let me write a comprehensive script that demonstrates all the flows, then walk through what each sectionI'll write the script in parts. First, the setup
  and discovery section

    Edited demo_curl_flows.sh +64

    ▎+ #!/usr/bin/env bash
    ▎+ # demo_curl_flows.sh — demonstrate the HTTP flows between the dockers.
    ▎+ #
    ▎+ # Sections:
    ▎+ #   A. Direct discovery curls to every docker (health, .well-known, JWKS)
    ▎+ #   B. Login at Dex as an LLDAP user (portal client libcloud-portal)
    ▎+ #   C. Exchange the code at identity_service -> portal cookie
    ▎+ #   D. Use the portal cookie to access cloud resources via identity_service
    ▎+ #   E. Logout
    ▎+ #   F. Demonstrate the portal cookie is now blocked (frontend blocked)
    ▎+ #   G. Direct Dex login as aws-admin via libcloud-rest client (server-to-server)
    ▎+ #   H. Demonstrate libcloud.rest STILL accepts that token after portal logout
    ▎ … truncated (53 more lines) · ctrl+r to review

  Now the login + exchange + use + logout section

  $ cat >> /home/ubuntu/libcloud_nutanix/demo_curl_flows.sh << 'SCRIPT_EOF'
     403ms
    … 77 input lines hidden · ctrl+o to expand
    appended B-F

  Now the bypass section (G-H) and the direct-to-other-dockers section (I

  $ cat >> /home/ubuntu/libcloud_nutanix/demo_curl_flows.sh << 'SCRIPT_EOF'
     294ms
    … 119 input lines hidden · ctrl+o to expand
    appended G-I and made executable

  Now let me verify the script is syntactically valid and walk through what each section demonstrates.

  $ bash -n /home/ubuntu/libcloud_nutanix/demo_curl_flows.sh && echo "syntax OK" && wc -l /home/ubuntu/libcloud_nutanix/demo_curl_flows.sh 299ms
    syntax OK
    258 /home/ubuntu/libcloud_nutanix/demo_curl_flows.sh

  Script written to demo_curl_flows.sh (258 lines, syntax-checked). Run it with bash demo_curl_flows.sh. Here's what each section demonstrates and why it
  matters for your logout question.

  What the script does, section by section

  A. Discovery — hits the health/metadata endpoint of every docker (portal:3000, identity-service:8766, libcloud-rest-api:8765, dex:5556/.well-known,
  openfga:8080, lldap:17170, vault:8200). Confirms what's running and that every service is reachable from the host.

  B. Login at Dex as aws-admin via the portal client — this is the browser flow, replayed with curl:
  1. GET /api/auth/begin?provider=lldap on identity_service → returns state + authorizeUrl (with PKCE code_challenge).
  2. GET the authorize URL → Dex returns the LDAP login form HTML.
  3. Regex the form action out of the HTML, POST login=aws-admin&password=… → Dex returns a 302 chain ending at redirect_uri?code=….
  4. Walk the redirects manually, extract the code.

  C. Exchange the code at identity_service — POST /api/auth/exchange with state + code. identity_service consumes the single-use state, exchanges the code
  at Dex /dex/token (with PKCE verifier + portal client secret), verifies the id_token, mints the libcloud_portal_sid httpOnly cookie. The cookie lands in
  the jar.

  D. Use the portal cookie — GET /api/session (returns role + clouds) and GET /api/resources/aws (lists AWS nodes via LibcloudProxy). This is the normal
  portal path: cookie in → identity_service checks OpenFGA → forwards to libcloud.rest with the provisioner token.

  E. Logout — POST /api/logout. identity_service deletes the cookie and drops the Dex refresh token from _refresh_store. It does not call Dex's revocation 
  endpoint (the TODO at main.py:198).

  F. Portal cookie is now blocked — re-calls /api/session and /api/resources/aws with the stale cookie. Both return 401. The frontend is blocked — exactly
  as you asked.

  G. The bypass: direct Dex login via the libcloud-rest client — this is the key demonstration. Anyone with:
  • an LLDAP password (in dex/generated/dex.env), and
  • the libcloud-rest client secret (also in dex/generated/dex.env, in the repo)

  …can run the same idp_login.py flow identity_service's ProvisionerAuth runs internally (idp_login.py:84-129), get a libcloud-rest-audience access token,
  and call libcloud.rest directly. No portal, no identity_service, no portal cookie involved.

  H. libcloud.rest still accepts the token after portal logout — three calls to libcloud.rest with the token from G:
  • GET /v1/auth/me — token introspection (Layer 1 JWT verify against Dex JWKS).
  • GET /v1/compute/nodes — list AWS nodes (Layer 2 scope gate + Layer 3 OpenFGA check on the aws-admin principal, which is always-true).
  • POST /v1/connections:test — connection validation.

  All return 200. The portal logout did nothing to stop this, because:
  1. libcloud.rest is stateless — it has no portal-session store to consult.
  2. It validates the JWT against Dex JWKS per request; the JWT is still valid (Dex wasn't told about the logout).
  3. The libcloud-rest client is a separate OAuth client from libcloud-portal; the portal logout only affected the portal's session.

  I. Direct curls to the other dockers — shows every docker is independently reachable and can be called directly:
  • OpenFGA /check — user:aws-admin can_provision aws_region:aws → {"allowed":true}. Anyone can query the authz graph directly (OpenFGA has OIDC authn,
    but the script shows the endpoint).
  • OpenFGA /read — dump the tuple store.
  • Vault /v1/secret/data/libcloud/aws — read the AWS backend credentials. Anyone with VAULT_TOKEN (in libcloud.rest/.env) gets the actual cloud keys.
    This is the most sensitive direct curl.
  • Vault /v1/secret/metadata/libcloud/ — list secrets.
  • LLDAP HTTP/GraphQL — list all users (admin basic auth).
  • LLDAP LDAP search — ldapsearch against ou=people,….

  The answer to your logout question, demonstrated

  The script's sections F + G + H together prove the point from my previous answer concretely:

  • F shows the portal cookie is dead after logout (frontend blocked ✓).
  • G shows you can get a fresh libcloud-rest-audience token from Dex without going through identity_service — using only credentials that are in the
    repo's .env files.
  • H shows libcloud.rest accepts that token after the portal logout, because libcloud.rest is stateless and never knew about the portal session.

  So "logout" in the current architecture means: the portal cookie is gone, but every other credential path to the backend is still alive. Specifically:

  ┌───────────────────────────────────────────────────────────────┬───────────────────────┬────────────────────────────────────────────┐
  │ Credential                                                    │ Alive after logout?   │ Why                                        │
  ├───────────────────────────────────────────────────────────────┼───────────────────────┼────────────────────────────────────────────┤
  │ Portal cookie (libcloud_portal_sid)                           │ ❌ deleted            │ Only thing logout touches                  │
  ├───────────────────────────────────────────────────────────────┼───────────────────────┼────────────────────────────────────────────┤
  │ Dex refresh token (held by identity_service)                  │ ✅ still valid at Dex │ TODO at main.py:198 — never revoked        │
  ├───────────────────────────────────────────────────────────────┼───────────────────────┼────────────────────────────────────────────┤
  │ Dex SSO session (browser cookie on Dex domain)                │ ✅ still alive        │ Logout doesn't touch Dex                   │
  ├───────────────────────────────────────────────────────────────┼───────────────────────┼────────────────────────────────────────────┤
  │ libcloud-rest-audience token (obtainable by direct Dex login) │ ✅ obtainable anytime │ Separate OAuth client; credentials in repo │
  ├───────────────────────────────────────────────────────────────┼───────────────────────┼────────────────────────────────────────────┤
  │ Provisioner token cache (idp_login._token_cache)              │ ✅ still cached       │ Decoupled from user sessions by design     │
  ├───────────────────────────────────────────────────────────────┼───────────────────────┼────────────────────────────────────────────┤
  │ Vault token (in libcloud.rest/.env)                           │ ✅ always valid       │ Nothing to do with user sessions           │
  ├───────────────────────────────────────────────────────────────┼───────────────────────┼────────────────────────────────────────────┤
  │ OpenFGA tuples                                                │ ✅ unchanged          │ Logout doesn't touch authz                 │
  └───────────────────────────────────────────────────────────────┴───────────────────────┴────────────────────────────────────────────┘

  The script makes this concrete: between F (blocked) and H (works), the only difference is which OAuth client you log in through. The portal logout blocked
  the libcloud-portal path; the libcloud-rest path is wide open because it was never tied to the portal session in the first place.

  To run it

  bash /home/ubuntu/libcloud_nutanix/demo_curl_flows.sh

  You may need ldap-utils for the last command (sudo apt-get install ldap-utils), and python3 for the JSON parsing (already present). The script uses real
  credentials from the repo's .env files, so it will actually log in as aws-admin and hit real services — be aware it creates a real Dex session and reads
  real Vault secrets.

                                                                                                                                                               
  elaborate on this "Layer 1 (claims_from_request → _decode_token → resolve_principal) outputs a TokenClaims with: sub, scope, allowed_providers,              
  access_token                                                                                                                                                 
                                                                                                                                                               

    Read 3 files
    Read libcloud.rest/app/auth/dependencies.py
    Read libcloud.rest/app/auth/oidc_service.py
    Read libcloud.rest/app/auth/models.py

  Let me walk through it with the actual code. Layer 1 is a four-step pipeline that turns a raw Authorization: Bearer <jwt> header into a TokenClaims object
  that the rest of the auth pipeline can use without ever touching the JWT again.

  The call chain

  AuthorizedAPIRoute.custom_route_handler(request)
      └─ claims_from_request(request)                      [dependencies.py:60]
           ├─ _bearer_token_from_request(request)          [dependencies.py:41]
           └─ _decode_token(token)                         [dependencies.py:16]
                └─ oidc_auth_service.decode_access_token(token)  [oidc_service.py:87]
                     ├─ jwt.get_unverified_header(token)   — pick algorithm
                     ├─ _decode_with_jwks(token)           — fetch signing key from Dex /dex/keys
                     │  └─ jwt.decode(...)                 — verify sig + exp + iss + aud
                     ├─ resolve_principal(payload)         [identity.py:106]  — sub → principal slug
                     ├─ principal_scopes(principal)         [identity.py:168]  — principal → scope list
                     ├─ principal_providers(principal)     [identity.py:181]  — principal → provider allow-list
                     └─ audit_auth_event(...)              — log the decode
                     → TokenClaims(...)

  Step 1: extract the bearer token

   python:41:57:libcloud.rest/app/auth/dependencies.py 

  def _bearer_token_from_request(request: Request) -> str:
      """Extract the raw bearer token from the Authorization header (or raise)."""
      header = request.headers.get("Authorization") or request.headers.get("authorization")
      if not header:
          raise APIError(code="auth_invalid_token", message="Bearer token required", status_code=401)
      parts = header.split(" ", 1)
      if len(parts) != 2 or parts[0].lower() != "bearer" or not parts[1]:
          raise APIError(code="auth_invalid_token", message="Bearer token required", status_code=401)
      return parts[1]

  No DB, no network. Just header parsing. Case-insensitive on Bearer, accepts either capitalization of the header name. This is the only place the raw JWT
  string is visible to the rest of the pipeline — it gets stashed on TokenClaims.access_token at the end so Layer 3 can forward it to OpenFGA.

  Step 2: dispatch on auth mode

   python:16:38:libcloud.rest/app/auth/dependencies.py 

  def _decode_token(token: str) -> TokenClaims:
      settings = get_settings()
      mode = settings.auth_mode.lower()
      if mode == "local":
          return auth_service.decode_access_token(token)   # HS256, signed by the REST API itself
      if mode == "oidc":
          return oidc_auth_service.decode_access_token(token)
      if mode == "hybrid":
          if oidc_auth_service._looks_like_oidc_token(token):
              try:
                  return oidc_auth_service.decode_access_token(token)
              except APIError as exc:
                  if exc.code not in {"auth_invalid_token", "auth_expired_token"}:
                      raise
          return auth_service.decode_access_token(token)
      raise APIError(code="auth_misconfigured", ...)

  The deployment in this repo runs AUTH_MODE=oidc (from libcloud.rest/.env), so the OIDC path is what executes. The hybrid mode is a dev escape hatch — it
  tries OIDC first (sniffing the algorithm + issuer), then falls back to local HS256 tokens signed by the REST API's own JWT_SIGNING_KEY. The
  _looks_like_oidc_token check (oidc_service.py:37-53) looks at the alg header: RS/ES/PS → definitely OIDC; HS → only if the issuer matches oidc_issuer_url.

  Step 3: verify the JWT against Dex JWKS

   python:55:67:libcloud.rest/app/auth/oidc_service.py 

  def _decode_with_jwks(self, token: str, settings) -> dict[str, Any]:
      signing_key = self._client().get_signing_key_from_jwt(token)
      header = jwt.get_unverified_header(token)
      alg = header.get("alg") or getattr(signing_key, "algorithm_name", "RS256")
      issuer = (settings.oidc_issuer_url or "").rstrip("/")
      return jwt.decode(
          token,
          signing_key.key,
          algorithms=[alg],
          audience=settings.oidc_audience,
          issuer=issuer,
          options={"require": ["exp", "sub"]},
      )

  This is the only network call in Layer 1 — PyJWKClient.get_signing_key_from_jwt fetches Dex's JWKS from http://dex:5556/dex/keys (configured as
  OIDC_JWKS_URL in the docker-compose). PyJWKClient caches the JWKS in-process and re-fetches only when it sees a kid it doesn't have (or after the cache
  TTL). So the first request after startup pays one round-trip to Dex; subsequent requests are local.

  jwt.decode then verifies four things, raising typed errors that the route handler maps to 401:

  ┌──────────────────────────────────────────────────────────────────┬────────────────────┬─────────────────────────┐
  │ Check                                                            │ Failure error code │ Source                  │
  ├──────────────────────────────────────────────────────────────────┼────────────────────┼─────────────────────────┤
  │ Signature (RS256 against the JWKS key)                           │ auth_invalid_token │ oidc_service.py:108-113 │
  ├──────────────────────────────────────────────────────────────────┼────────────────────┼─────────────────────────┤
  │ exp not in the past                                              │ auth_expired_token │ oidc_service.py:102-107 │
  ├──────────────────────────────────────────────────────────────────┼────────────────────┼─────────────────────────┤
  │ iss == OIDC_ISSUER_URL (http://login.quest4science.xyz:5556/dex) │ auth_invalid_token │ oidc_service.py:65      │
  ├──────────────────────────────────────────────────────────────────┼────────────────────┼─────────────────────────┤
  │ aud == OIDC_AUDIENCE (libcloud-rest)                             │ auth_invalid_token │ oidc_service.py:64      │
  ├──────────────────────────────────────────────────────────────────┼────────────────────┼─────────────────────────┤
  │ exp and sub claims present                                       │ auth_invalid_token │ oidc_service.py:66      │
  └──────────────────────────────────────────────────────────────────┴────────────────────┴─────────────────────────┘

  What Layer 1 does not verify at this step: the user's account state in LLDAP, any token blocklist, any session state. LLDAP was consulted by Dex at login
  time (Dex's LDAP connector bound to the user); by the time the JWT is here, the identity is baked into the token and won't be re-checked. There is no
  revocation mechanism — reliance is purely on exp.

  Step 4: resolve the principal

  This is the trust boundary between "what the IdP says" and "what this API allows." The JWT's sub claim is not trusted as the principal directly; it's
  mapped through a resolution chain:

   python:106:149:libcloud.rest/app/auth/identity.py 

  def resolve_principal(payload: dict[str, Any]) -> str:
      mapping = _load_map()
      sub = str(payload.get("sub") or "")
      email = str(payload.get("email") or "").lower()
      username = str(payload.get("preferred_username") or payload.get("username") or "")
      if sub and sub in mapping["by_sub"]:
          return str(mapping["by_sub"][sub])
      if email and email in mapping["by_email"]:
          return str(mapping["by_email"][email])
      aliases = mapping.get("legacy_username_aliases") or {}
      if username and username in aliases:
          return str(aliases[username])
      known = set(PRINCIPAL_SCOPES) | set(aliases.values())
      if sub in known:
          return sub
      if username in known:
          return username
      if username:
          return username
      if sub:
          return sub
      raise APIError(code="auth_user_unknown", ...)

  Resolution order:
  1. principal_map.json by_sub[sub] — explicit sub→principal mapping (file-based, hot-reloadable).
  2. principal_map.json by_email[email] — explicit email→principal mapping.
  3. legacy_username_aliases[preferred_username|username] — legacy username→principal.
  4. sub if it already matches a known principal slug in PRINCIPAL_SCOPES (e.g. aws-admin, ntnx-viewer, superadmin).
  5. preferred_username / username as a last resort.

  In this deployment, principal_map.json is empty by default (identity.py:75 LEGACY_USERNAME_ALIASES = {} and the _load_map fallback at identity.py:87-93),
  so resolution falls through to step 4: Dex's LDAP connector sets idAttr = uid, so the JWT sub is the LLDAP uid (e.g. aws-admin), which matches a known
  principal slug, and that's what's returned. The mapping file is there for when Dex's sub is opaque (e.g. Google/GitHub federated connectors encode it as
  base64(protobuf{UserID, ConnectorID})) and you need to map it back to a stable slug.

  Step 5: derive scopes and allowed_providers

  This is the key design decision: the JWT's own scope claim is ignored. Scopes are derived from the principal slug via static tables, not trusted from the
  token.

   python:50:70:libcloud.rest/app/auth/identity.py 

  PRINCIPAL_SCOPES: dict[str, list[str]] = {
      "superadmin": PROVISIONER_SCOPES,
      "aws-owner": PROVISIONER_SCOPES,
      "aws-admin": PROVISIONER_SCOPES,
      "aws-viewer": READER_SCOPES,
      "ntnx-owner": PROVISIONER_SCOPES,
      "ntnx-admin": PROVISIONER_SCOPES,
      "ntnx-viewer": READER_SCOPES,
      "cloud-denied": READER_SCOPES,
  }
  PRINCIPAL_PROVIDERS: dict[str, list[str]] = {
      "superadmin": ["*"],
      "aws-owner": ["aws"],
      "aws-admin": ["aws"],
      "aws-viewer": ["aws"],
      "ntnx-owner": ["nutanix"],
      "ntnx-admin": ["nutanix"],
      "ntnx-viewer": ["nutanix"],
      "cloud-denied": ["aws", "nutanix"],
  }

   python:168:189:libcloud.rest/app/auth/identity.py 

  def principal_scopes(principal: str) -> list[str]:
      if principal in PRINCIPAL_SCOPES:
          return PRINCIPAL_SCOPES[principal]
      role = _role_suffix(principal)              # aws-dev-admin -> "admin"
      if role in ("owner", "admin"):
          return PROVISIONER_SCOPES
      if role == "viewer":
          return READER_SCOPES
      if principal == "admin":                     # legacy local-auth admin
          return ALL_SCOPES
      return []                                    # -> decode_access_token rejects with auth_user_unknown
  def principal_providers(principal: str) -> list[str]:
      ifContinuing from `principal_providers`:
  ```python:181:189:libcloud.rest/app/auth/identity.py
  def principal_providers(principal: str) -> list[str]:
      if principal in PRINCIPAL_PROVIDERS:
          return PRINCIPAL_PROVIDERS[principal]
      if _role_suffix(principal) is not None:
          return ["*"]          # let OpenFGA's can_use(provider:<cloud>) enforce the per-cloud boundary
      return []
  ```
  The `_role_suffix` fallback (`identity.py:152-165`) is what makes new tenants work without editing the tables: a principal like `aws-dev-admin` doesn't
  have an explicit entry, but its `-admin` suffix resolves to `PROVISIONER_SCOPES` and `["*"]` providers, then Layer 3's `can_use provider:aws` check (via
  the tenant→provider graph in OpenFGA) enforces the actual boundary. So the static table is the fast path for known principals, and the suffix convention
  is the general path for new tenants.
  ## Step 6: assemble TokenClaims
  ```python:135:148:libcloud.rest/app/auth/oidc_service.py
  return TokenClaims(
      sub=principal,                                                    # ← the resolved slug, NOT the JWT sub
      iss=issuer,
      aud=str(payload.get("aud", settings.oidc_audience)),
      iat=int(payload.get("iat", 0)),
      nbf=int(payload.get("nbf", payload.get("iat", 0))),
      exp=int(payload["exp"]),
      jti=str(payload.get("jti") or payload.get("sid") or principal),
      scope=" ".join(scopes),                                          # ← derived, NOT the JWT scope claim
      tenant_id=settings.oidc_tenant_id,                                # ← from settings, not the JWT
      allowed_providers=providers,                                      # ← derived from principal
      session_id=str(payload.get("sid") or payload.get("jti") or principal),
      access_token=token,                                                # ← raw JWT, kept for Layer 3 relay
  )
  ```
  ```python:34:49:libcloud.rest/app/auth/models.py
  class TokenClaims(BaseModel):
      sub: str
      iss: str
      aud: str
      iat: int
      nbf: int
      exp: int
      jti: str
      scope: str
      tenant_id: str
      allowed_providers: list[str]
      session_id: str
      access_token: str | None = None
  ```
  ## The four fields that matter most
  Four fields in `TokenClaims` carry the entire identity decision for the rest of the pipeline. Three of them are *not* what the JWT literally says:
  | Field | Source | What it means | Used by |
  |---|---|---|---|
  | `sub` | **resolved principal slug** (e.g. `aws-admin`), not the JWT's raw `sub` | The stable application identity. The raw IdP subject is gone after
  this point — only the principal survives. | Layer 2 (`_fga_user` builds `user:<sub>`), Layer 3, audit logs |
  | `scope` | **derived from principal** via `PRINCIPAL_SCOPES`/`_role_suffix`, not the JWT's `scope` claim | Space-joined string of libcloud scopes
  (`compute:node:create compute:read …`). The JWT's own `scope` claim is discarded. | Layer 2 (`_token_has_scope` splits this string and checks against the
  policy table) |
  | `allowed_providers` | **derived from principal** via `PRINCIPAL_PROVIDERS`/`_role_suffix` | List like `["aws"]` or `["*"]`. Coarse per-provider gate. |
  Layer 2 (`connection.provider in allowed_providers`) |
  | `access_token` | **the raw JWT string**, kept verbatim | Token relay — Layer 3 forwards it as `Authorization: Bearer …` to OpenFGA, which runs its own
  OIDC authn against the same Dex. No service-to-service credential needed. | Layer 3 (`fga_client.py:40-41`) |
  The other fields (`iss`, `aud`, `iat`, `nbf`, `exp`, `jti`, `tenant_id`, `session_id`) are metadata — `exp` is checked once at decode time and then
  trusted; `jti`/`session_id` are for audit; `tenant_id` comes from settings, not the JWT.
  ## Three deliberate design choices this encodes
  **1. The IdP doesn't need to know libcloud's scope taxonomy.** Dex just authenticates and emits `sub`/`email`/`preferred_username`. The REST API maps the
  principal to scopes itself via `PRINCIPAL_SCOPES`. If you add a new scope (`compute:node:tag`, say), you change the table, not Dex's configuration. The
  trade-off: scopes can't be granted per-user at the IdP — they're per-principal-slug, baked into the table or the suffix convention.
  **2. `sub` is the principal, not the subject.** This is a rename that matters. By the time `TokenClaims` is built, the raw IdP subject (which for
  federated logins is an opaque `base64(protobuf)`) is gone. Downstream code uses `claims.sub` to mean "the principal this API knows about," not "what the
  IdP said about identity." That's why `_fga_user` in Layer 3 can do `f"user:{claims.sub}"` without re-resolving — the resolution already happened.
  **3. The token is relayed, not just verified.** `access_token=token` keeps the raw JWT so Layer 3 can forward it to OpenFGA. This is what makes the
  "OpenFGA reuses Dex as its own authn" property from `security.md` work: OpenFGA runs with `--authn-method=oidc` against the same Dex issuer + audience, so
  the same JWT that authorized `libcloud.rest` also authorizes the `/check` call to OpenFGA. No second login, no service-to-service password, no second
  token mint. The cost: `libcloud.rest` must trust OpenFGA to validate the same JWT independently, and the JWT must be valid for the duration of the
  `/check` call (which it is, since `exp` is checked at Layer 1 and the call happens within the same request).
  ## What Layer 1 explicitly does NOT do
  - **No OpenFGA call** — that's Layer 3. Layer 1 only knows the principal's *static* permissions (scopes + providers from the table); it doesn't know the
  *relational* permissions (which tenant, which backend object).
  - **No connection parsing** — `X-Provider-Connection` is parsed separately by `connection_from_request` (`dependencies.py:70-88`) and is only seen by
  Layer 2, not Layer 1.
  - **No Vault call** — that's Layer 4, at backend-call time.
  - **No LLDAP call** — LLDAP was consulted by Dex at login time; the JWT is the baked result.
  - **No token blocklist / revocation check** — relies purely on `exp`. A stolen token is valid until it expires. The mitigation is short access-token TTLs
  (`ACCESS_TOKEN_TTL_SECONDS=900` in `libcloud.rest/.env`, 15 minutes) and refresh-token revocation at the IdP (which, as we saw last turn, identity_service
  doesn't even do for the portal user's refresh token).
  - **No per-user account-state check** — if a user is disabled in LLDAP after login but before their token expires, the token is still valid here.
  Real-time disable is enforced at Layer 3 (OpenFGA tuple deletion), not Layer 1.
  So Layer 1's job is narrow and complete: turn a bearer token into a principal + static permissions, with one cacheable JWKS fetch as the only network
  cost. Everything dynamic (which tenant, which backend, which Vault secret) is deferred to Layers 2-4.

