
  ────────────────────────────────────────

  How every request to the libcloud REST API is intercepted by the Dex / LLDAP / OpenFGA / Vault layers

  There is one single chokepoint where every provisioning request is intercepted: the custom FastAPI route class AuthorizedAPIRoute in
  app/auth/authorized_route.py. Route handlers themselves contain zero auth logic — none of them import policy_engine, declare scopes, or take a claims
  param. The interception happens before the handler runs, inside custom_route_handler.

   libcloud.rest/app/auth/authorized_route.py lines 84-102

          async def custom_route_handler(request: Request):
              route_key = f"{request.method} {route_path}"
              entry = policy_table.get(route_key)
              claims = claims_from_request(request)
              request.state.authorized_claims = claims
              if entry.get("connection_required", True):
                  connection: ProviderConnection = connection_from_request(request)
                  ...
                  policy_engine.authorize_connection(claims, connection, authz_scope)
                  capability = entry.get("capability")
                  if capability:
                      policy_engine.check_driver_capability(connection, capability)
                  request.state.connection = connection
              else:
                  policy_engine.check_scopes(claims, entry["scopes_any_of"])
              return await original_route_handler(request)

  The four external services are not all hit on every request — they sit at different stages of a layered pipeline. Here is the order in which a request is
  processed, and which layer owns each step.

  Layer 0 — Policy table (in-process, hot-reloadable JSON)

  Before any external call, policy_table.get(route_key) (app/auth/policy_table.py) looks up "METHOD path_template" in app/auth/policies.json. This decides
  what must be true for this route: scopes_any_of, optional authz_scope / authz_scope_by_body_field, optional capability, and connection_required. Missing
  entry → 500 policy_unknown_operation (fail-closed, also validated at import time in AuthorizedAPIRoute.__init__). This is the routing decision that drives
  the rest of the pipeline — it is not one of the four sibling services, but it is what selects which layers get invoked.

  Layer 1 — Dex + LLDAP (authentication + identity)

  claims_from_request(request) → _decode_token (app/auth/dependencies.py) extracts the bearer token and decodes it. In oidc/hybrid mode this goes through
  oidc_auth_service.decode_access_token (app/auth/oidc_service.py):

  • Dex is the OIDC issuer. The token's iss/aud/signature are validated against Dex's JWKS (settings.oidc_jwks_url, oidc_issuer_url, oidc_audience).
    dex/config.yaml shows Dex is configured with issuer: http://dex:5556/dex and connectors: ldap → lldap:3890. So Dex itself is the IdP front door, but
    it does not hold users.
  • LLDAP is the user store behind Dex. Dex's LDAP connector (bindDN: uid=admin,ou=people,…, userSearch.baseDN: ou=people,…) authenticates the human during
    the OAuth/OIDC code flow and maps uid→sub, mail→email, cn→name. LLDAP is never called by the REST API at request time — it was consulted by Dex at
    login time. By the time the request hits libcloud.rest, the user identity is already baked into the JWT as claims.

  After decode, resolve_principal(payload) (app/auth/identity.py) maps the OIDC sub/email/preferred_username to a stable application principal slug
  (superadmin, aws-admin, ntnx-viewer, …) via principal_map (by_sub / by_email / legacy aliases) or the <tenant>-<role> suffix convention. Then
  principal_scopes / principal_providers derive the libcloud scopes and provider allow-list for that principal. The raw Dex JWT is retained as
  claims.access_token so it can be forwarded downstream (Layer 3).

  This is the only layer that touches the human's identity. Output: a TokenClaims object stashed on request.state.authorized_claims.

  Layer 2 — Scope + provider gate (in-process, derived from Layer 1)

  Still inside authorize_connection (app/auth/policy.py), before any network call:

   libcloud.rest/app/auth/policy.py lines 121-130

          token_scopes = set(claims.scope.split())
          if not self._token_has_scope(token_scopes, required_scope):
              raise APIError(... code="auth_insufficient_scope" ...)
          allowed_providers = set(claims.allowed_providers)
          if "*" not in allowed_providers and connection.provider not in allowed_providers:
              raise APIError(... code="auth_provider_denied" ...)
          enforce_credential_policy(connection)
          self._enforce_openfga(claims, connection, required_scope)

  This is a cheap reject-fast gate using values computed from Layer 1 (scopes + allowed_providers) plus enforce_credential_policy
  (app/connections/credentials.py) which rejects any client-supplied backend credentials unless ALLOW_CLIENT_CREDENTIALS is on — defense in depth before the
  next layer.

  Layer 3 — OpenFGA (relationship-based authorization)

  _enforce_openfga (app/auth/policy.py:73-96) is the relational authz layer. It builds the FGA principal (user:<principal>) and the backend object
  (<object_type>:<auth_binding>, per-tenant isolation via PROVIDER_OBJECT_TYPES + _backend_object), then issues up to four check calls against OpenFGA
  through FgaClient (app/auth/fga_client.py):

   libcloud.rest/app/auth/policy.py lines 73-85

      def _enforce_openfga(self, claims, connection, required_scope) -> None:
          fga = get_fga_client()
          if not fga.enabled:
              return
          ...
          fga.require(user, "can_connect", settings.fga_api_object, bearer=bearer)
          fga.require(user, "can_use", f"provider:{connection.provider}", bearer=bearer)
          backend = self._backend_object(connection)
          if required_scope in WRITE_SCOPES or required_scope.endswith(":manage"):
              fga.require(user, "can_provision", backend, bearer=bearer)
          else:
              if not fga.check(user, "can_read", backend, bearer=bearer):
                  fga.require(user, "can_provision", backend, bearer=bearer)

  Two important details about how OpenFGA is wired to the other layers:

  • OpenFGA reuses Dex as its own authn. bearer = claims.access_token is the caller's Dex JWT, forwarded as Authorization: Bearer … to OpenFGA
    (fga_client.py:37-41). Because OpenFGA runs with OIDC authn against the same Dex issuer + audience, the same token is accepted. So Layer 3
    transitively trusts Layer 1's identity — no second login, no service-to-service password.
  • The OpenFGA tuples encode the LLDAP users and the tenant/provider graph. Per openfga_my/authorization.md, subjects are stable LLDAP uid slugs
    (user:aws-admin, user:ntnx-viewer, …) granted owner/admin/viewer on tenant:aws / tenant:nutanix, which parent to libcloud_api:main (→ can_connect) and
    provider:aws/provider:nutanix (→ can_use), and feed aws_region/nutanix_cluster (→ can_read / can_provision). So Layer 3 is what enforces cross-cloud
    isolation: an AWS tenant member is not a member of tenant:nutanix, so can_use provider:nutanix and can_provision nutanix_cluster:… both fail.

  If fga.enabled is false, this layer is a no-op (the scope/provider gate + credential policy still apply) — that's how the test suite runs without OpenFGA.

  Layer 4 — Vault (backend credential brokerage)

  OpenFGA only says "may you"; Vault provides "with what". This happens after the handler is dispatched, when the service tier calls
  build_driver(connection) → effective_credentials(connection) → resolve_server_credentials (app/connections/credentials.py:82-124):

   libcloud.rest/app/connections/credentials.py lines 82-94

  def resolve_server_credentials(connection: ProviderConnection) -> ConnectionCredentials:
      provider = connection.provider
      binding = connection.auth_binding or _default_binding(provider)
      vault = get_vault_client()
      if vault.enabled:
          try:
              data = vault.read_secret(binding)
          except APIError as exc:
              raise  # never silently fall back to env
          ...
          return ConnectionCredentials(key=key, secret=secret)
      creds = _env_credentials(provider, binding)
      ...

  VaultClient.read_secret (app/connections/vault_client.py) reads secret/data/libcloud/<binding> from Vault KV v2 using X-Vault-Token, with a 30s in-process
  cache. The auth_binding (tenant id) selects which secret is read — one secret per tenant, matching the per-tenant backend object OpenFGA checked in Layer
  3. Crucially, if Vault is configured but the secret is missing, the API returns 503 server_credentials_missing rather than silently falling back to env
  vars — it will not mask a misconfiguration with a stale plaintext credential. Env vars are a dev-only fallback when Vault is not configured at all.

  So the credentials the API uses to actually talk to AWS/Nutanix are the API's own backend identity, never the client's. The client only selects which
  tenant identity to use via auth_binding.

  Putting the layers in request order

  For a typical provisioning call, e.g. POST /v1/compute/nodes with X-Provider-Connection: {"provider":"aws","auth_binding":"aws"}:

  1. AuthorizedAPIRoute.custom_route_handler intercepts before the handler.
  2. Policy table → entry "POST /v1/compute/nodes" → scopes_any_of:["compute:node:create"], capability:"create_node".
  3. Dex/LLDAP (Layer 1) → decode the bearer JWT against Dex JWKS; the human was authenticated by Dex→LLDAP at login time; resolve_principal maps to e.g.
     aws-admin; scopes/providers derived.
  4. Scope + provider + credential gate (Layer 2) → reject if scope missing, if aws not in allowed_providers, or if client tried to pass backend creds.
  5. OpenFGA (Layer 3) → forward the same Dex JWT as bearer; require can_connect on libcloud_api:main, can_use on provider:aws, can_provision on
     aws_region:aws (write scope). Tuples reference the LLDAP uid slug.
  6. Capability probe → check_driver_capability(connection, "create_node") builds the driver and verifies the provider actually supports the op.
  7. Stash request.state.connection + request.state.authorized_claims; call the handler (pure provisioning logic, no authz).
  8. Vault (Layer 4) → when the handler/service calls the cloud, resolve_server_credentials reads secret/data/libcloud/aws from Vault → the API's own AWS
     keys → build_driver → libcloud → AWS.

  Connection-less routes

  Routes with connection_required: false (e.g. GET /v1/jobs/{job_id}, POST /v1/admin/policies:reload) skip Layers 2/3/4 entirely —
  policy_engine.check_scopes(claims, entry["scopes_any_of"]) runs only the scope gate from Layer 1's derived scopes. No OpenFGA, no Vault, no connection.

  Exempt surfaces

  app/auth/routes.py (token issuance: login/refresh/logout/introspect), app/providers/routes.py (public provider metadata), and /health stay on plain
  APIRouter, so they bypass AuthorizedAPIRoute and none of the four layers intercept them — by design, since the auth router issues the tokens that Layer 1
  consumes.

  Summary of who does what

  ┌─────┬──────────────────────────────────────────┬────────────────────────────────┬──────────────────────────────────────────────────────────────────────┐
  │ Lay │ Service                                  │ When invoked                   │ What it decides                                                      │
  │ er  │                                          │                                │                                                                      │
  ├─────┼──────────────────────────────────────────┼────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
  │ 0   │ policies.json (in-process)               │ every request                  │ what scopes/capability/connection this route requires                │
  ├─────┼──────────────────────────────────────────┼────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
  │ 1   │ Dex (OIDC issuer) + LLDAP (user store    │ every request (Dex JWKS);      │ is the token valid; who is the principal; what are their             │
  │     │ behind Dex's LDAP connector)             │ LLDAP at login time            │ scopes/providers                                                     │
  ├─────┼──────────────────────────────────────────┼────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
  │ 2   │ scope + provider + credential gate       │ every connection-required      │ fast reject on missing scope / wrong provider / client-supplied      │
  │     │ (in-process)                             │ request                        │ creds                                                                │
  ├─────┼──────────────────────────────────────────┼────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
  │ 3   │ OpenFGA                                  │ every connection-required      │ can_connect / can_use / can_provision / can_read over the            │
  │     │                                          │ request when FGA_ENABLED       │ tenant↔provider↔backend graph; per-tenant isolation                  │
  ├─────┼──────────────────────────────────────────┼────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
  │ 4   │ Vault                                    │ at backend-call time (service  │ supplies the API's own per-tenant cloud credentials; never falls     │
  │     │                                          │ tier)                          │ back to env when Vault is configured                                 │
  └─────┴──────────────────────────────────────────┴────────────────────────────────┴──────────────────────────────────────────────────────────────────────┘

  The key architectural property: identity flows from LLDAP → Dex → JWT, and that same JWT is reused by OpenFGA for authn, so the three identity/authz
  services form one chain rather than three independent ones; Vault is the only layer that holds secrets, and it is keyed by the same auth_binding that
  OpenFGA used as the backend object — keeping tenant isolation consistent across authz and credential retrieval.


