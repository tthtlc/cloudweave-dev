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
