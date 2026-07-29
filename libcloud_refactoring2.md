
                                                                                                                                                               
  schematically draw the HTTP flow via line drawing diagram to show the relationship between Dex/LLDAP as IDAP, OpenFGA, ./libcloud.rest (directory) as        
  REST API, ./vault as secret store, and ./identity_service                                                                                                    
                                                                                                                                                               

    Read, grepped 6 files, 2 greps
    … 5 earlier items hidden
    Read libcloud.rest/doc/security.md
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
                                                                                                                                                               

    Read, globbed 6 files, 2 globs
    … 5 earlier items hidden
    Read identity_service/app/users.py
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
  the authz - can it be done against the OpenFGA so that identity services need not do that at all?                                                            

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


