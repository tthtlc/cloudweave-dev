from fastapi import APIRouter, Depends, Request

from app.auth.dependencies import get_current_claims, require_scopes
from app.auth.models import IntrospectRequest, LoginRequest, RefreshRequest, TokenClaims
from app.auth.service import auth_service
from app.common.errors import APIError
from app.common.responses import success_response
from app.config.settings import get_settings

router = APIRouter(prefix="/v1/auth", tags=["auth"])


def _local_auth_disabled() -> None:
    """Local password login is disabled when auth_mode is OIDC-only.

    User identities come from the OIDC IdP (Dex → LLDAP); the REST API must
    not mint its own tokens from a local/static user directory.
    """
    if get_settings().auth_mode.lower() == "oidc":
        raise APIError(
            code="auth_local_disabled",
            message="Local password login is disabled; authenticate via the OIDC IdP (Dex).",
            status_code=404,
        )


@router.post("/login")
def login(request_body: LoginRequest, request: Request):
    _local_auth_disabled()
    token = auth_service.login(request_body)
    return success_response(token.model_dump(), request)


@router.post("/refresh")
def refresh(request_body: RefreshRequest, request: Request):
    _local_auth_disabled()
    token = auth_service.refresh(request_body.refresh_token)
    return success_response(token.model_dump(), request)


@router.post("/logout")
def logout(
    request: Request,
    request_body: RefreshRequest | None = None,
    claims: TokenClaims = Depends(get_current_claims),
):
    refresh_token = request_body.refresh_token if request_body else None
    auth_service.logout(refresh_token, claims.jti)
    return success_response({"logged_out": True}, request)


@router.get("/me")
def me(request: Request, claims: TokenClaims = Depends(get_current_claims)):
    return success_response(
        {
            "username": claims.sub,
            "tenant_id": claims.tenant_id,
            "scope": claims.scope,
            "allowed_providers": claims.allowed_providers,
            "session_id": claims.session_id,
        },
        request,
    )


@router.post("/token/introspect")
def introspect(
    body: IntrospectRequest,
    request: Request,
    _: TokenClaims = Depends(require_scopes("admin:connections:read")),
):
    _local_auth_disabled()
    data = auth_service.introspect(body.token)
    return success_response(data, request)
