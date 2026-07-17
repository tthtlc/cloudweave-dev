  I've read todo.md. It contains a clarification note about whether OpenFGA can accept tokens from multiple OIDC issuers (e.g., Dex + Authentik). The summary:

  • OpenFGA cannot have two independent token-signing OIDC issuers. It validates every JWT against a single JWKS endpoint (--authn-oidc-issuer). The --authn-oidc-issuer-aliases flag only aliases the iss claim for the same IdP reachable under multiple URLs — it does not add a second key source.
  • The supported way to add Authentik: federate it behind Dex as an upstream connector. Dex remains the single OIDC signing boundary (one iss, one JWKS, one aud=libcloud-rest), so neither OpenFGA nor the libcloud REST gateway need changes.
  • The first bullet about Dex signing keys living in memory (storage.type: memory) is a separate concern — it's about Dex's own key rotation lifecycle, not multi-IdP support.

  The opening question — "does this mean OpenFGA cannot have multiple IDP/OIDC components talking to it?" — is answered: multiple upstream user directories via Dex connectors = yes; multiple token-signing OIDC issuers in front of OpenFGA = no.

  what is the purpose of the Dex signing key? and so Dex has only one signing key? and so when anyone who logged into Dex via OAutht2 will not involve the signing key right?                                                                                                                                        

  Good questions — let me answer each, and they build on each other.

  1. What is the purpose of the Dex signing key?

  Dex is an OIDC Identity Provider. When a user successfully authenticates, Dex doesn't just hand back a session — it mints a signed JWT (the id_token, and signed access_token/refresh_token depending on config). The signing key is what cryptographically proves "I, Dex, issued this token".

  The flow:

  • User logs in → Dex produces a JWT with claims like iss=http://dex:5556/dex, sub=<user>, aud=libcloud-rest, exp=....
  • Dex signs that JWT with its private signing key (RS256 in most Dex setups — an RSA private key).
  • The relying party (OpenFGA, libcloud REST) verifies the signature using Dex's public key, which it fetches from Dex's JWKS endpoint (http://dex:5556/dex/keys).
  • If the signature checks out, the relying party trusts the token's claims without ever talking to Dex again.

  So the signing key's purpose is non-repudiable proof of issuance — it's the thing that makes a token trustworthy without a synchronous callback to Dex. Without it, anyone could forge a token claiming to be anyone.

  2. Does Dex have only one signing key?

  One active signing key at a time, but the JWKS can hold several public keys for rollover.

  • Dex maintains a signing key (private) and a verification key (public, published in JWKS). Internally it keeps a primary signing key used to sign new tokens.
  • For key rotation, Dex supports holding multiple keys: a new key becomes primary (used to sign), while the old public key stays in JWKS so already-issued tokens keep validating until they expire. This is standard OIDC rotation.
  • In your setup specifically: because storage.type: memory, the signing key is re-minted on every fresh container start (setup.sh:224-231). That means there's one key at a time, but it changes whenever the container restarts — which is exactly why setup.sh force-restarts OpenFGA to flush its cached
    JWKS (the old public key is gone, the new one must be fetched).

  So: "one signing key" is right in the steady state, but the more precise statement is one active signing key, with the JWKS able to advertise multiple public keys during rotation.

  3. Does logging into Dex via OAuth2 not involve the signing key?

  The login/authentication step itself doesn't use the signing key — but the token issuance that follows absolutely does. Let me separate the two phases:

  Phase A — the OAuth2/OIDC login handshake (no signing key):
  • Client → Dex: GET /auth?client_id=...&redirect_uri=...
  • Dex → user: login page (credentials checked against the upstream connector — LLDAP, etc.)
  • User → Dex: submits credentials
  • Dex → connector (LLDAP): binds/authenticates the user
  • Dex → client: redirect with an authorization code

  All of that is OAuth2 orchestration + upstream authentication. No JWT signing happens here. The signing key is not involved.

  Phase B — token endpoint (signing key is used):
  • Client → Dex: POST /token with the authorization code
  • Dex: signs the id_token (and access_token if JWT-style) with its private signing key ← here it is
  • Dex → client: signed JWT(s)

  So the moment a user "gets a token," the signing key is essential. Anyone who logged in via OAuth2 does end up holding a token that was produced by that signing key, and every downstream verifier (OpenFGA, libcloud REST) relies on the corresponding public key to trust it.

  Tying it back to your todo.md: this is why, when Dex's signing key is re-minted on container restart, "already-issued refresh tokens become invalid; users re-login." The old tokens were signed by a key whose public half no longer exists in JWKS, so signature verification fails — and a fresh login is
  required to get a token signed by the new key.

                                                                                                                                                                                                                                                                                                                     
  so is it possible that OpenFGA be able to do OIDC handshake with Dex or Authentik? (not concurrently, but only one at a time - either Dex or Authentik)                                                                                                                                                            
                                                                                                                                                                                                                                                                                                                     

  Important distinction first: OpenFGA does not perform the OIDC "handshake" (authorization-code flow with login page redirect). It is not an OIDC client/relying party in that sense. Let me separate the two roles.

  What OpenFGA actually does with OIDC

  OpenFGA's --authn-method=oidc means: "I am a resource server. I accept bearer JWTs in the Authorization: Bearer <jwt> header, and I validate them against the configured issuer's JWKS."

  It does not:
  • redirect a user to a login page,
  • run the GET /auth → login → callback → /token code-exchange flow,
  • hold an OAuth2 client_id/client_secret for user login.

  It does:
  • read the iss and aud claims from the presented JWT,
  • fetch the issuer's public keys from its JWKS endpoint,
  • verify the signature,
  • check iss matches --authn-oidc-issuer (or an alias) and aud matches --authn-oidc-audience,
  • extract the subject/principal from the verified claims and run authorization.

  So the OIDC handshake (the login dance) is done by the client — in your stack that's the human using idp_login.py/the CLI, or the libcloud REST gateway acting on a user's behalf — against Dex. OpenFGA only ever validates the resulting token.

  So: can OpenFGA validate tokens issued by Authentik instead of Dex (one at a time)?

  Yes — by reconfiguration, not concurrently. This is a different question from the multi-issuer one in your todo.md. There you asked "can OpenFGA accept tokens from both Dex and Authentik at the same time" → no. Here you're asking "can it be pointed at either one, exclusively" → yes.

  You'd switch openfga_postgres/docker-compose.yml lines 90-92 from:

  --authn-oidc-issuer=${OPENFGA_AUTHN_OIDC_ISSUER:-http://dex:5556/dex}
  --authn-oidc-audience=${OPENFGA_AUTHN_OIDC_AUDIENCE:-libcloud-rest}

  to Authentik's issuer and audience, e.g.:

  --authn-oidc-issuer=https://authentik.example/application/o/libcloud-rest/
  --authn-oidc-audience=<authentik-client-id>

  Then restart OpenFGA. It will fetch Authentik's JWKS and validate only Authentik-signed tokens. Dex-signed tokens will now fail (iss/signature mismatch). Flip the config back and it trusts Dex again. Mutually exclusive, one at a time — works.

  The practical caveats in your stack

  Even though OpenFGA could be repointed, your full chain is pinned to Dex as the single issuer on two fronts, which is why the documented design federates Authentik behind Dex rather than swapping it in:

  1. The libcloud REST gateway has the same single-issuer constraint — OIDC_ISSUER_URL / OIDC_JWKS_URL in libcloud.rest/.env, plus aud=libcloud-rest. If you repoint OpenFGA to Authentik but leave the gateway on Dex, the gateway and OpenFGA disagree on who the issuer is, and a token valid for one won't
     be valid for the other. You'd have to repoint both consistently.
  2. Audience must match. Authentik would need an OIDC client minting aud=libcloud-rest (or you change the audience config everywhere to Authentik's client ID). Mismatch = silent rejection.
  3. Principal mapping. data/principal_map.json maps Dex/LLDAP identity claims to stable principal slugs (aws-admin, etc.). Authentik emits different claim shapes (different sub, possibly different group claim names). You'd need new mapping entries or tuples break.
  4. Login client. idp_login.py and the OAuth2 client config in dex.env are built to talk to Dex's endpoints. Pointing users at Authentik means a different client_id, different token endpoint, different well-known doc — the login script would need updating.

  Net answer

  ┌───────────────────────────────────────────────────────────────────────────┬───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ Question                                                                  │ Answer                                                                                                                                                                │
  ├───────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Does OpenFGA do the OIDC login handshake with an IdP?                     │ No — it's a JWT validator (resource server), not a login client. The client/gateway does the handshake.                                                               │
  ├───────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Can OpenFGA validate Authentik tokens instead of Dex tokens, exclusively? │ Yes — repoint --authn-oidc-issuer/--authn-oidc-audience and restart; but you must also repoint the libcloud REST gateway and update login client + principal mapping. │
  ├───────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Can it validate both at the same time?                                    │ No — single JWKS, as in todo.md.                                                                                                                                      │
  ├───────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Recommended path to bring Authentik in?                                   │ Federate Authentik behind Dex as a connector — Dex stays the one signing boundary, nothing downstream changes.                                                        │
  └───────────────────────────────────────────────────────────────────────────┴───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

  So "either/or by reconfiguration" is technically fine; "swap Authentik in as a replacement issuer for the whole chain" is a meaningful migration, which is exactly why the architecture chose the Dex-federation pattern instead.

                                                                                                                                                                                                                                                                                                                     
  so openfga is not possible to do multi-issuer scenario                                                                                                                                                                                                                                                             
                                                                                                                                                                                                                                                                                                                     

  Correct — OpenFGA cannot do a true multi-issuer scenario. Let me state it precisely so the boundary is unambiguous.

  What "multi-issuer" would mean

  Two or more independent token-signing OIDC issuers (e.g. Dex and Authentik), each with their own JWKS / own signing keys, both able to hand OpenFGA a JWT that it accepts — at the same time, without reconfiguring or restarting.

  Why OpenFGA can't do that

  1. One JWKS source. --authn-oidc-issuer points at a single issuer. OpenFGA's go-oidc client fetches keys from only that issuer's /.well-known/openid-configuration → jwks_uri. It never downloads a second issuer's keys. A token signed by Authentik's private key fails signature verification because
     OpenFGA has no Authentik public key to check it against.
  2. Aliases are not a second key source. --authn-oidc-issuer-aliases (v1.5.1+) only relaxes the iss claim check for the same IdP reachable under multiple URLs (e.g. http://dex:5556/dex vs https://dex.example.com/dex). The note from upstream PR #1354 is explicit: "token validation still relies on the 
     main issuer JWKS." So aliases = alternate iss strings for one key set, not a second key set.
  3. Single audience. --authn-oidc-audience is one value. Even if two issuers existed, both would have to mint the same aud, and you'd still be blocked by point 1.

  What is and isn't possible — final grid

  ┌───────────────────────────────────────────────────────────────────────────┬────────────────────────────────────────┐
  │ Scenario                                                                  │ OpenFGA supports?                      │
  ├───────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────┤
  │ Two concurrent independent issuers, each signing tokens OpenFGA validates │ No                                     │
  ├───────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────┤
  │ One issuer with multiple URLs (iss aliases), one JWKS                     │ Yes (aliases)                          │
  ├───────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────┤
  │ One issuer at a time, swapped by reconfig + restart                       │ Yes (mutually exclusive, not "multi")  │
  ├───────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────┤
  │ Multiple upstream user directories federated behind a single issuer (Dex) │ Yes — and this is the supported design │
  └───────────────────────────────────────────────────────────────────────────┴────────────────────────────────────────┘

  The workaround that makes the system look multi-IdP

  Keep Dex as the single signing issuer in front of OpenFGA, and attach multiple upstream directories (LLDAP, Authentik, Entra, AD) as Dex connectors. From OpenFGA's perspective there is still exactly one iss, one JWKS, one aud. The multiplicity lives upstream of Dex, not at the token-signing layer.

  So your statement is right: OpenFGA itself is not capable of a multi-issuer scenario. Any "multiple IdPs" outcome in this architecture is achieved by collapsing them into one signing issuer (Dex) before the token ever reaches OpenFGA.

                                                                                                                                                                                                                                                                                                                     
  Does it make sense to say OpenFGA is right now authenticated with Dex?                                                                                                                                                                                                                                             
                                                                                                                                                                                                                                                                                                                     

  Mostly — but the phrasing is slightly off, and the distinction matters. Let me sharpen it.

  What's actually true

  • Dex is the OIDC issuer OpenFGA is configured to trust. That's set by --authn-oidc-issuer=http://dex:5556/dex (and --authn-oidc-audience=libcloud-rest).
  • OpenFGA fetches Dex's JWKS and uses it to verify bearer tokens that clients send.
  • OpenFGA itself does not log in to Dex, hold a session with Dex, or present credentials to Dex. There is no OpenFGA→Dex authentication event.

  So which verb is correct?

  ┌─────────────────────────────────────────────────────────┬──────────────────────────────────────────────────┐
  │ Statement                                               │ Accurate?                                        │
  ├─────────────────────────────────────────────────────────┼──────────────────────────────────────────────────┤
  │ "OpenFGA is authenticated with Dex"                     │ Not quite — implies OpenFGA logged in to Dex.    │
  ├─────────────────────────────────────────────────────────┼──────────────────────────────────────────────────┤
  │ "OpenFGA is configured to trust Dex as its OIDC issuer" │ Yes.                                             │
  ├─────────────────────────────────────────────────────────┼──────────────────────────────────────────────────┤
  │ "OpenFGA validates Dex-issued tokens"                   │ Yes — this is the precise operational statement. │
  ├─────────────────────────────────────────────────────────┼──────────────────────────────────────────────────┤
  │ "OpenFGA is a resource server / relying party of Dex"   │ Yes — the correct role name.                     │
  ├─────────────────────────────────────────────────────────┼──────────────────────────────────────────────────┤
  │ "OpenFGA uses Dex as its OIDC authn method"             │ Yes — matches --authn-method=oidc.               │
  └─────────────────────────────────────────────────────────┴──────────────────────────────────────────────────┘

  The right way to say it

  │ "OpenFGA is configured to authenticate incoming requests by validating JWTs issued by Dex."

  The subject of "authenticate" is the request/client, not OpenFGA. OpenFGA is the verifier; Dex is the issuer; the user/client is the authenticated party. So:

  • Clients are authenticated by OpenFGA using Dex-issued tokens.
  • OpenFGA trusts Dex, it isn't "authenticated with" Dex.

  If you want a one-liner that's both correct and captures intent: "OpenFGA's OIDC authentication is wired to Dex as the sole trusted issuer." That avoids the (small but real) implication that OpenFGA itself is a logged-in party to Dex.

                                                                                                                                                                                                                                                                                                                     
  so does the very first login request hit the LLDAP or the DEX?                                                                                                                                                                                                                                                     
                                                                                                                                                                                                                                                                                                                     

  Short answer: the very first login request hits Dex, not LLDAP. The user/client never talks to LLDAP directly — LLDAP is contacted by Dex, as a backend connector, only after Dex has already received the request. Let me confirm against your actual login client and Dex config.

    Read, grepped 1 file, 1 grep
    Read openfga_my/scripts/idp_login.py
    Grepped "...|ssl|user_filter|group_filter|base_dn" in dex/config.yaml

  Confirmed from the code. Here's the precise sequence.

  The very first request hits Dex

  idp_login.py line 194 builds the authorize URL and line 198 issues the first HTTP call:

   openfga_my/scripts/idp_login.py lines 194-198

      authorize_url = f"{DEX_URL}/dex/auth?{params}"
      jar = CookieJar()
      opener = _cookie_opener(jar)
      post_url, _html = _dex_login_page(opener, authorize_url)

  That GET http://localhost:5556/dex/auth?... is the first network hop of a login. It goes to Dex, never LLDAP. Dex then redirects internally (/dex/auth → /dex/auth/<connector_id> → /dex/auth/<id>/login) and returns the password form.

  The user's credentials are then POSTed back to Dex (line 199-209):

   openfga_my/scripts/idp_login.py lines 199-209

      form = urllib.parse.urlencode({"login": login_id, "password": password}).encode()
      _verbose(f">>> POST {post_url} (login={login_id})")
      opener.open(
          urllib.request.Request(
              post_url,
              data=form,
              method="POST",
              headers={"Content-Type": "application/x-www-form-urlencoded"},
          ),
          timeout=30,
      ).read()

  Still Dex. The client (idp_login.py) never speaks LDAP to LLDAP — there is no LLDAP host, port, or bind anywhere in this file. The comment on line 31-32 says it explicitly:

   openfga_my/scripts/idp_login.py lines 31-32

  # Map script usernames → LLDAP uid (Dex LDAP connector matches `username: uid`).
  # Users live in LLDAP (../lldap); Dex authenticates against it over LDAP.

  Where LLDAP enters — and it's Dex that calls it, not the client

  LLDAP only appears in Dex's config as a connector (dex/config.yaml):

   dex/config.yaml lines 44-45

    - type: ldap
      id: lldap

        host: lldap:3890
        insecureNoSSL: true
        # Service account bind for user lookups (admin).
        bindDN: uid=admin,ou=people,dc=libcloud,dc=local

  So when Dex receives the POSTed password, Dex's LDAP connector binds to lldap:3890 and verifies the credentials. That Dex→LLDAP call is the second hop, and it's server-to-server inside the compose network — the user/client is not involved.

  Full ordering of a fresh login

  ┌───┬───────┬─────────────────────────────┬──────────────────────────────────────────────────┐
  │ # │ Hop   │ Who → Who                   │ What                                             │
  ├───┼───────┼─────────────────────────────┼──────────────────────────────────────────────────┤
  │ 1 │ First │ Client (idp_login.py) → Dex │ GET /dex/auth?client_id=... (start OIDC flow)    │
  ├───┼───────┼─────────────────────────────┼──────────────────────────────────────────────────┤
  │ 2 │       │ Dex → Client                │ 302 chain + login HTML form                      │
  ├───┼───────┼─────────────────────────────┼──────────────────────────────────────────────────┤
  │ 3 │       │ Client → Dex                │ POST /dex/auth/<id>/login with username+password │
  ├───┼───────┼─────────────────────────────┼──────────────────────────────────────────────────┤
  │ 4 │       │ Dex → LLDAP                 │ LDAP bind + user/group lookup (server-to-server) │
  ├───┼───────┼─────────────────────────────┼──────────────────────────────────────────────────┤
  │ 5 │       │ Dex → Client                │ 302 redirect with authorization code             │
  ├───┼───────┼─────────────────────────────┼──────────────────────────────────────────────────┤
  │ 6 │       │ Client → Dex                │ POST /dex/token (exchange code)                  │
  ├───┼───────┼─────────────────────────────┼──────────────────────────────────────────────────┤
  │ 7 │       │ Dex → Client                │ signed JWT (id_token/access_token/refresh_token) │
  └───┴───────┴─────────────────────────────┴──────────────────────────────────────────────────┘

  Answer to your question

  The very first login request hits Dex. LLDAP is a backend connector that Dex calls during step 4 — it is never the entry point. From the client's and user's perspective, Dex is the only IdP they ever talk to; LLDAP is an upstream directory that Dex federates against to actually verify the password. This
  is exactly the "Dex as the stable OIDC front door" pattern from your todo.md.

  ok after the signed JWT is derived list all the possible path the request can take.                                                                                                                                                                                                                                
  Here's the full set of paths a request can take once the holder has the signed Dex JWT. I traced it through libcloud.rest/app/. The JWT is always used as a Bearer token; what happens next depends on which route it hits and which gates pass.

  The starting point

  idp_login.py prints token["access_token"] (line 261). The CLI/scripts put it in Authorization: Bearer <jwt> and call the libcloud REST API. There are also a refresh_token and id_token in the cache, handled separately.

  High-level decision tree

  JWT in hand
  ├── A. Refresh path (refresh_token) ──► Dex /dex/token
  ├── B. libcloud REST API (access_token as Bearer)
  │     ├── B1. /v1/auth/*  (plain router, decode-only)
  │     ├── B2. /v1/providers, /v1/connections  (scope-gated, no OpenFGA)
  │     └── B3. Authorized provisioning routes  (AuthorizedAPIRoute)
  │           ├── B3a. connection_required=true  → full gate chain
  │           └── B3b. connection_required=false → scope-only gate
  └── C. OpenFGA direct (same JWT forwarded as Bearer by the API)

  A. Refresh path (doesn't use the access JWT, uses the refresh token)

  login() tries the cached refresh_token first (idp_login.py:226-231):

   openfga_my/scripts/idp_login.py lines 226-228

      if cached and cached.get("refresh_token"):
          try:
              refreshed = _refresh(token_url, cached["refresh_token"])

  That POSTs to Dex's /dex/token with grant_type=refresh_token. If it fails (401/400 — e.g. Dex re-minted its signing key), it falls through to a full dex_login. So one possible path is: back to Dex, get a fresh JWT, repeat.

  B. Into the libcloud REST API

  The token enters _decode_token (app/auth/dependencies.py:16-38), which branches on auth_mode:

  • oidc → oidc_auth_service.decode_access_token — fetches Dex's JWKS, verifies signature/iss/aud/exp, then resolve_principal + principal_scopes (oidc_service.py:87-148).
  • local → HS256 local JWT (auth_service.py).
  • hybrid → try OIDC first, fall back to local.

  Decode-fail short-circuits: expired → 401 auth_expired_token; bad signature/issuer/audience → 401 auth_invalid_token; principal not in principal_map.json → 403 auth_user_unknown.

  After decode, the request splits by router class.

  B1. /v1/auth/* — plain router, decode-only

  auth/routes.py uses plain APIRouter + Depends(get_current_claims). Paths:

  • GET /v1/auth/me → returns claims echo.
  • POST /v1/auth/logout → revokes jti (local mode; no-op for pure OIDC since Dex holds the session).
  • POST /v1/auth/token/introspect → requires admin:connections:read scope; local-only (disabled in OIDC mode).
  • POST /v1/auth/login and /refresh → disabled in OIDC mode (_local_auth_disabled, lines 13-24) — tokens come from Dex, not here.

  So for an OIDC JWT, the only real destinations are /me and /logout. No connection, no OpenFGA, no provider call.

  B2. /v1/providers, /v1/connections — scope-gated, no OpenFGA

  Per the authorized_route.py docstring (lines 7-8 & 131-133), these stay on plain APIRouter and use require_scopes/require_any_scopes. Path: decode → scope check → handler. No X-Provider-Connection, no OpenFGA tuple check, no Vault, no cloud call (except test_connection, which does build a driver).

  B3. Authorized provisioning routes — AuthorizedAPIRoute

  This is the main path (compute, network, storage, jobs, admin). custom_route_handler (authorized_route.py:84-122) runs before the handler. Two sub-paths:

  B3a. connection_required=true (default) — the full gate chain

   libcloud.rest/app/auth/authorized_route.py lines 91-98

              if entry.get("connection_required", True):
                  connection: ProviderConnection = connection_from_request(request)
                  ...
                  policy_engine.authorize_connection(claims, connection, authz_scope)
                  capability = entry.get("capability")
                  if capability:
                      policy_engine.check_driver_capability(connection, capability)
                  request.state.connection = connection

  Inside authorize_connection (policy.py:115-148) the request walks these gates in order, any of which can terminate it:

  1. Scope gate — token must hold the route's scope (with READ_SCOPE_ALIASES expansion). Fail → 403 auth_insufficient_scope.
  2. Provider allow-list — claims.allowed_providers must include the connection's provider (or *). Fail → 403 auth_provider_denied.
  3. Credential policy — enforce_credential_policy rejects any client-supplied credentials unless ALLOW_CLIENT_CREDENTIALS is on (credentials.py:30-43). Fail → 403 auth_client_credentials_forbidden.
  4. OpenFGA checks — _enforce_openfga (policy.py:73-96) forwards the same Dex JWT as bearer to OpenFGA and requires:
    • can_connect on settings.fga_api_object
    • can_use on provider:<provider>
    • can_provision (write scopes) or can_read/can_provision (read scopes) on <obj_type>:<auth_binding> (per-tenant backend object)

     OpenFGA itself validates the forwarded JWT against Dex's JWKS (fga_client.py:37-41). Outcomes: allowed → continue; denied → 403 authz_fga_denied; FGA down → 503 authz_fga_unavailable/authz_fga_error.
  5. Capability check (optional, if policy entry has capability) — build_driver + probe_capabilities; rejects unsupported ops → 400 provider_capability_unsupported.

  If all gates pass, the handler runs. The handler then branches into sync vs async:

  • Sync: calls compute_service.* directly, returns the result. Path continues to: effective_credentials (credentials.py:127-136) → Vault read_secret(binding) (or env fallback) → build_driver → AWS or Nutanix libcloud driver → cloud provider API.
  • Async: _maybe_async (compute/routes.py:22-43) submits fn to JobWorker's ThreadPoolExecutor (jobs/worker.py:97-119) and returns {"job_id","status"}. The actual cloud work happens on a worker thread; the client polls GET /v1/jobs/{job_id} (which is itself a connection_required=false scope-gated
    route).

  B3b. connection_required=false — scope-only gate

   libcloud.rest/app/auth/authorized_route.py lines 119-120

              else:
                  policy_engine.check_scopes(claims, entry["scopes_any_of"])

  Path: decode → scope check → handler. No connection, no OpenFGA, no Vault, no cloud. Examples: GET /v1/jobs/{job_id}, POST /v1/admin/policies:reload.

  C. The OpenFGA side-path (the same JWT, second use)

  Whenever B3a reaches step 4, the original Dex JWT is forwarded to OpenFGA as a Bearer (policy.py:87, fga_client.py:40-41). OpenFGA re-validates it against Dex's JWKS (single-issuer, as discussed earlier) and returns allowed. So one JWT triggers two JWT-validations: one at the REST API, one at OpenFGA —
  both against the same Dex JWKS.

  The downstream provider/secret hops (after B3a passes)

  Once the handler runs for a connection-required route, the request fans out to:

  • Vault (vault_client.py:45-105): GET /v1/<mount>/data/libcloud/<binding> with X-Vault-Token. Cached 30s. 404 → 503 server_credentials_missing; unreachable → 503 server_credentials_unavailable.
  • libcloud driver (providers/factory.py:11-17): AWS (create_aws_driver) or Nutanix (create_nutanix_driver), built with the server-resolved creds, not anything the client sent.
  • Cloud provider API: AWS EC2 / Nutanix Prism — the actual list_nodes, create_node, etc. Provider-side errors bubble up as provider_operation_failed (in async jobs) or the raw exception (sync).

  Compact enumeration of all possible request destinations

  ┌────┬───────────────────────────────────────┬────────────────────────────────────────────────────────────┬─────────────────────────────────────────────────────────────┐
  │ #  │ Path                                  │ Touched services                                           │ Gates                                                       │
  ├────┼───────────────────────────────────────┼────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
  │ 1  │ Refresh token → new JWT               │ Dex only                                                   │ none (Dex validates its own refresh token)                  │
  ├────┼───────────────────────────────────────┼────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
  │ 2  │ /v1/auth/me, /logout                  │ REST API decode only                                       │ JWT signature/claims                                        │
  ├────┼───────────────────────────────────────┼────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
  │ 3  │ /v1/auth/token/introspect             │ REST API                                                   │ JWT + admin:connections:read scope                          │
  ├────┼───────────────────────────────────────┼────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
  │ 4  │ /v1/providers, /v1/connections (list) │ REST API                                                   │ JWT + scope                                                 │
  ├────┼───────────────────────────────────────┼────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
  │ 5  │ /v1/connections:test                  │ REST API → Vault → cloud driver                            │ JWT + scope (+ creds/driver for test)                       │
  ├────┼───────────────────────────────────────┼────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
  │ 6  │ Sync provisioning route (read)        │ REST API → OpenFGA → Vault → cloud                         │ scope + provider + creds + FGA can_read/can_use/can_connect │
  ├────┼───────────────────────────────────────┼────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
  │ 7  │ Sync provisioning route (write)       │ REST API → OpenFGA → Vault → cloud                         │ scope + provider + creds + FGA can_provision + capability   │
  ├────┼───────────────────────────────────────┼────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
  │ 8  │ Async provisioning route              │ REST API → OpenFGA → JobWorker → (Vault → cloud) on thread │ same as 6/7, then job poll via path 9                       │
  ├────┼───────────────────────────────────────┼────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
  │ 9  │ GET /v1/jobs/{job_id}                 │ REST API (job store in-memory)                             │ JWT + scope, no connection                                  │
  ├────┼───────────────────────────────────────┼────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
  │ 10 │ POST /v1/admin/policies:reload        │ REST API (hot-reload policies.json)                        │ JWT + scope, no connection                                  │
  └────┴───────────────────────────────────────┴────────────────────────────────────────────────────────────┴─────────────────────────────────────────────────────────────┘

  Terminal failure short-circuits (request stops here)

  • 401 auth_invalid_token / auth_expired_token — JWT bad/expired (Dex key rotated, etc.)
  • 403 auth_user_unknown — principal not in principal_map.json
  • 403 auth_insufficient_scope — missing scope
  • 403 auth_provider_denied — provider not in allowed_providers
  • 403 auth_client_credentials_forbidden — client tried to pass backend creds
  • 403 authz_fga_denied — OpenFGA said no
  • 400 provider_capability_unsupported — driver lacks the op
  • 500 policy_unknown_operation — route missing from policies.json (fail-closed)
  • 503 authz_fga_unavailable / server_credentials_missing / server_credentials_unavailable — OpenFGA or Vault down
  • provider_operation_failed — cloud API error (in async jobs)

  So the JWT's life after issuance is essentially: (refresh round-trip to Dex) → (validate at REST API) → optionally (re-validate at OpenFGA) → optionally (fetch creds from Vault) → optionally (call AWS/Nutanix), with scope/provider/capability gates interleaved and several no-cloud terminal paths (/me,
  /jobs, /admin, /providers).
