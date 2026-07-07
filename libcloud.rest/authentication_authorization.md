
                                                                                                                                                             
  where is the code that does the authentication or authorization check or control or verification, if direct API access to the libcloud.rest REST API         
  is attempted? (current directory).                                                                                                                           
                                                                                                                                                               

    Read 8 files
    … 5 earlier items hidden
    Read app/auth/fga_client.py
    Read app/compute/routes.py
    Read app/connections/dependencies.py

  Here's where direct API access to the libcloud.rest REST API gets authenticated and authorized. The control is enforced through FastAPI dependencies wired
  into every route, plus a policy engine invoked inside each handler.

  Authentication (who is the caller?)

  The central gate is the get_current_claims dependency in app/auth/dependencies.py. It runs the HTTPBearer check and decodes the JWT.

   libcloud.rest/app/auth/dependencies.py lines 1-47

  from fastapi import Depends
  from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
  from app.auth.models import TokenClaims
  from app.auth.oidc_service import oidc_auth_service
  from app.auth.service import auth_service
  from app.common.errors import APIError
  from app.config.settings import get_settings
  _bearer = HTTPBearer(auto_error=False)
  def _decode_token(token: str) -> TokenClaims:
      settings = get_settings()
      mode = settings.auth_mode.lower()
      if mode == "local":
          return auth_service.decode_access_token(token)
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
      raise APIError(
          code="auth_misconfigured",
          message=f"Unsupported auth_mode: {settings.auth_mode}",
          status_code=500,
      )
  def get_current_claims(
      credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
  ) -> TokenClaims:
      if not credentials or credentials.scheme.lower() != "bearer":
          raise APIError(
              code="auth_invalid_token",
              message="Bearer token required",
              status_code=401,
          )
      return _decode_token(credentials.credentials)

  Token decoding per mode:
  • Local/hybrid: app/auth/service.py AuthService.decode_access_token (HMAC JWT, aud/iss/jti-revocation check).
  • OIDC/hybrid: app/auth/oidc_service.py OidcAuthService.decode_access_token (JWKS or HS client-secret, iss/aud/exp, then maps principal → scopes via
    app/auth/identity.py).

  Scope enforcement (token-level authorization)

  require_scopes / require_any_scopes in the same file are the FastAPI dependencies attached to each endpoint. They depend on get_current_claims, so the
  Bearer check runs first.

   libcloud.rest/app/auth/dependencies.py lines 50-78

  def require_scopes(*required_scopes: str):
      def dependency(claims: TokenClaims = Depends(get_current_claims)) -> TokenClaims:
          token_scopes = set(claims.scope.split())
          for scope in required_scopes:
              if scope not in token_scopes:
                  raise APIError(
                      code="auth_insufficient_scope",
                      message=f"Required scope missing: {scope}",
                      status_code=403,
                      details={"required_scope": scope},
                  )
          return claims
      return dependency
  def require_any_scopes(*accepted_scopes: str):
      def dependency(claims: TokenClaims = Depends(get_current_claims)) -> TokenClaims:
          token_scopes = set(claims.scope.split())
          if not token_scopes.intersection(accepted_scopes):
              raise APIError(
                  code="auth_insufficient_scope",
                  message="Token does not include any required scope",
                  status_code=403,
                  details={"required_any_of": list(accepted_scopes)},
              )
          return claims
      return dependency

  Per-request policy + OpenFGA authorization

  The deeper checks — scope re-check, allowed_providers claim check, credential-policy enforcement (rejects client-supplied backend creds), and OpenFGA
  can_connect / can_use / can_read / can_provision — live in policy_engine.authorize_connection / check_driver_capability / check_scopes in
  app/auth/policy.py. The route handlers themselves contain NO authorization logic; they are called by AuthorizedAPIRoute (see below) which invokes the
  policy engine before the handler runs.

   libcloud.rest/app/auth/policy.py lines 98-131

      def authorize_connection(
          self,
          claims: TokenClaims,
          connection: ProviderConnection,
          required_scope: str,
      ) -> ProviderConnection:
          token_scopes = set(claims.scope.split())
          if not self._token_has_scope(token_scopes, required_scope):
              raise APIError(
                  code="auth_insufficient_scope",
                  message="Token does not include the required scope",
                  status_code=403,
                  details={"required_scope": required_scope},
              )
          allowed_providers = set(claims.allowed_providers)
          if "*" not in allowed_providers and connection.provider not in allowed_providers:
              raise APIError(
                  code="auth_provider_denied",
                  message="Token is not authorized to use the requested provider",
                  status_code=403,
                  details={
                      "provider": connection.provider,
                      "required_scope": required_scope,
                  },
              )
          # Defense in depth: reject client-supplied backend credentials before
          # OpenFGA checks and before any backend call. The API uses its own
          # backend identity (see connections/credentials.py).
          enforce_credential_policy(connection)
          self._enforce_openfga(claims, connection, required_scope)
          return connection

  OpenFGA calls themselves: app/auth/fga_client.py (FgaClient.check / require), which forwards the caller's Dex JWT to OpenFGA when OIDC authn is enabled.

  Externalized authorization: the policy table + AuthorizedAPIRoute

  Authorization is data-driven and lives OUTSIDE route source code, so route handlers focus purely on cloud-resource provisioning. Two pieces:

  1. app/auth/policies.json — a table keyed by "METHOD path_template" (e.g. "GET /v1/compute/locations"). Each entry declares:
     • scopes_any_of — token must hold at least one (with READ_SCOPE_ALIASES expansion), replacing the old require_scopes / require_any_scopes args.
     • authz_scope — the scope passed to policy_engine.authorize_connection (defaults to scopes_any_of[0]).
     • authz_scope_by_body_field — optional: for action-conditional routes (e.g. PATCH /nodes/{node_id}), maps a body field value to an authz_scope.
     • capability — optional driver capability passed to policy_engine.check_driver_capability (e.g. "create_node", "volumes").
     • connection_required — default true; false for connection-less routes (jobs, admin) which use policy_engine.check_scopes instead.

  2. app/auth/authorized_route.py — a custom FastAPI APIRoute subclass (AuthorizedAPIRoute) set as the route_class of every provisioning router via
     make_authorized_router(prefix, tags). For each request it: looks up the table entry by "{method} {route.path}" (fail-closed 500
     policy_unknown_operation if missing), resolves claims + the X-Provider-Connection header, runs the policy engine, and stashes
     request.state.connection + request.state.authorized_claims before calling the handler. It also injects the X-Provider-Connection header into the
     route's OpenAPI definition so Swagger still documents it.

  The table is loaded into memory at startup by app/auth/policy_table.py and hot-reloaded: a cheap mtime check on every lookup re-reads the file when it
  changes, and POST /v1/admin/policies:reload (scope admin:connections:read) forces a reload. Editing app/auth/policies.json therefore changes
  authorization enforcement with NO source-code changes and NO restart. The path is configurable via the policy_table_file setting.

  How it's wired into routes

  Provisioning routers (compute, network, storage, connections, jobs, admin) are built with make_authorized_router, so every one of their routes is
  auto-authorized. Handlers read the already-authorized connection from request.state and contain zero authz logic:

   libcloud.rest/app/compute/routes.py

  router = make_authorized_router(prefix="/v1/compute", tags=["compute"])

  @router.get("/locations")
  def list_locations(request: Request):
      connection = request.state.connection
      data = [loc.model_dump() for loc in compute_service.list_locations(connection)]
      return success_response(data, request)

  Exempt routers (no auto-authz, plain APIRouter): app/auth/routes.py (token-issuing surface: login/refresh/logout/me/introspect),
  app/providers/routes.py (public metadata, no authz), and /health (in main.py). The auth router still uses get_current_claims / require_scopes
  directly since it is the authentication surface, not a resource-provisioning surface.

  Connection source: ALL endpoints now take the provider connection from the X-Provider-Connection header (or ?connection= query); the `connection`
  field was removed from all create/update request body models, so POST/PATCH clients must send the connection header instead of embedding it in the
  body (breaking change). POST /v1/connections:test is now body-less and uses the header too.

  Summary of the chain for a direct API call

  1. AuthorizedAPIRoute (app/auth/authorized_route.py) resolves the bearer token via claims_from_request → _decode_token (auth_service local or
     oidc_auth_service OIDC) → 401 if no/invalid Bearer token.
  2. It looks up the policy entry for "{METHOD} {path}" in app/auth/policies.json (loaded by app/auth/policy_table.py) → 500 policy_unknown_operation
     if the route is not declared (fail-closed).
  3. Scope gate: token must hold >=1 of entry.scopes_any_of (READ_SCOPE_ALIASES expansion applies) → 403 auth_insufficient_scope otherwise.
  4. If connection_required: policy_engine.authorize_connection (app/auth/policy.py) → allowed_providers check, enforce_credential_policy
     (app/connections/credentials.py), then OpenFGA can_connect/can_use/can_read/can_provision via app/auth/fga_client.py → 403/503 on denial; plus
     policy_engine.check_driver_capability when entry.capability is set. The authorized connection is stashed on request.state.connection.
     If connection_required=false: policy_engine.check_scopes (scope-only, no connection/FGA).
  5. The route handler runs and reads request.state.connection / request.state.authorized_claims — pure provisioning logic, no authz code.


