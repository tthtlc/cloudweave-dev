from fastapi import Depends, Header, Query
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from starlette.requests import Request

from app.auth.models import TokenClaims
from app.auth.oidc_service import oidc_auth_service
from app.auth.service import auth_service
from app.common.errors import APIError
from app.config.settings import get_settings
from app.connections.dependencies import parse_connection_raw
from app.connections.models import ProviderConnection

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


def _bearer_token_from_request(request: Request) -> str:
    """Extract the raw bearer token from the Authorization header (or raise)."""
    header = request.headers.get("Authorization") or request.headers.get("authorization")
    if not header:
        raise APIError(
            code="auth_invalid_token",
            message="Bearer token required",
            status_code=401,
        )
    parts = header.split(" ", 1)
    if len(parts) != 2 or parts[0].lower() != "bearer" or not parts[1]:
        raise APIError(
            code="auth_invalid_token",
            message="Bearer token required",
            status_code=401,
        )
    return parts[1]


def claims_from_request(request: Request) -> TokenClaims:
    """Resolve TokenClaims directly from a Starlette Request.

    Used by ``AuthorizedAPIRoute`` (which runs before FastAPI resolves Depends).
    The ``get_current_claims`` dependency below delegates here so auth-router
    endpoints keep working unchanged.
    """
    return _decode_token(_bearer_token_from_request(request))


def connection_from_request(request: Request) -> ProviderConnection:
    """Resolve ProviderConnection directly from a Starlette Request.

    Reads the ``X-Provider-Connection`` header (preferred) or the URL-encoded
    ``connection`` query parameter. Same precedence as ``parse_connection_query``.
    """
    xpc = request.headers.get("X-Provider-Connection") or request.headers.get(
        "x-provider-connection"
    )
    if xpc:
        return parse_connection_raw(xpc, url_encoded=False)
    raw = request.query_params.get("connection")
    if raw:
        return parse_connection_raw(raw, url_encoded=True)
    raise APIError(
        code="invalid_connection",
        message="Missing provider connection; send X-Provider-Connection header or connection query parameter",
        status_code=400,
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
