
                                                                                                                                                             
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

  Inside each handler, policy_engine.authorize_connection(...) runs the deeper checks: scope re-check, allowed_providers claim check, credential-policy
  enforcement (rejects client-supplied backend creds), and OpenFGA can_connect / can_use / can_read / can_provision checks. See app/auth/policy.py.

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

  How it's wired into routes

  Each router (e.g. app/compute/routes.py) declares the scope dependency and then calls policy_engine.authorize_connection before doing any work:

   libcloud.rest/app/compute/routes.py lines 49-57

  @router.get("/locations")
  def list_locations(
      request: Request,
      connection: ProviderConnection = Depends(parse_connection_query),
      claims: TokenClaims = Depends(require_any_scopes("compute:location:read", "compute:read")),
  ):
      connection = policy_engine.authorize_connection(claims, connection, "compute:location:read")
      data = [loc.model_dump() for loc in compute_service.list_locations(connection)]
      return success_response(data, request)

  app/main.py registers the routers; there is no global auth middleware — protection is per-endpoint via these dependencies. Only /health (in main.py) and
  the /auth/* login/refresh/introspect endpoints in app/auth/routes.py are intentionally unauthenticated.

  Summary of the chain for a direct API call

  1. HTTPBearer + get_current_claims (app/auth/dependencies.py) → 401 if no/invalid Bearer token.
  2. _decode_token → auth_service (local) or oidc_auth_service (OIDC) verifies signature, exp, iss, aud, revocation, and resolves principal/scopes.
  3. require_scopes / require_any_scopes → 403 if the token lacks the endpoint's scope.
  4. policy_engine.authorize_connection (app/auth/policy.py) → scope re-check, allowed_providers check, enforce_credential_policy
     (app/connections/credentials.py), then OpenFGA can_connect/can_use/can_read/can_provision via app/auth/fga_client.py → 403/503 on denial.


