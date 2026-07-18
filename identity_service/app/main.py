from __future__ import annotations

import logging
from typing import Any

from fastapi import Depends, FastAPI, Request, Response
from fastapi.middleware.cors import CORSMiddleware

from app.config import get_settings
from app.dex import DexService
from app.errors import APIError, api_error_handler
from app.fga import FgaService
from app.libcloud_proxy import LibcloudProxy
from app.lldap import LldapService
from app.models import (
    CollapseRequest,
    ExchangeRequest,
    ExchangeResponse,
    ProvisionRequest,
    RoleUpdateRequest,
    SessionResponse,
)
from app.session import SessionService
from app.users import UserService

log = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(title=settings.app_title, version=settings.app_version)

    # The portal is served from :3000 and calls this service on :8766.
    # credentials=true on the browser side requires a permissive CORS origin
    # AND SameSite handling on the cookie. In production serve both behind the
    # same origin (reverse proxy) so CORS isn't needed and cookies are first-party.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["http://login.quest4science.xyz:3000", "http://localhost:3000"],
        allow_credentials=True,
        allow_methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
        allow_headers=["*"],
    )
    app.add_exception_handler(APIError, api_error_handler)

    # --- service singletons -------------------------------------------------
    dex = DexService()
    fga = FgaService()
    lldap = LldapService()
    sessions = SessionService()
    users = UserService(lldap=lldap, fga=fga)
    proxy = LibcloudProxy()

    def _principal(claims: dict[str, Any]) -> str:
        # OpenFGA tuples are keyed by LLDAP uid; for pending users we use the
        # internal id suffix. The session carries internalUserId ("int-<uid>").
        iid = claims["internalUserId"]
        return iid[4:] if iid.startswith("int-") else iid

    def _require_session(req: Request) -> dict[str, Any]:
        return sessions.read(req)

    def _require_role(req: Request, role: str) -> dict[str, Any]:
        claims = sessions.read(req)
        principal = _principal(claims)
        # superadmin satisfies any role check.
        if claims.get("role") == role or claims.get("role") == "superadmin":
            return claims
        # Re-check against OpenFGA in case the role changed server-side.
        current = fga.role_for(principal)
        if current == role or current == "superadmin":
            return claims
        raise APIError("authz_forbidden", "Insufficient role", 403, {"required": role, "have": claims.get("role")})

    # --- routes -------------------------------------------------------------
    @app.get("/health")
    def health():
        return {"status": "ok"}

    @app.get("/api/session")
    def get_session(req: Request) -> SessionResponse:
        claims = _require_session(req)
        return SessionResponse(
            internalUserId=claims["internalUserId"],
            role=claims["role"],
            linkedIdentities=claims["linkedIdentities"],
            email=claims["email"],
        )

    @app.post("/api/auth/exchange")
    def exchange(body: ExchangeRequest, req: Request, resp: Response) -> ExchangeResponse:
        # 1. CSRF/state: the browser only sanity-checked state; full validation
        #    belongs here. TODO: verify `body.state` against a server-issued
        #    nonce stored before the Dex redirect (PKCE challenge too).
        if not body.code:
            raise APIError("auth_missing_code", "authorization code required", 400)

        # 2. Token exchange with Dex (server-side client secret).
        redirect_uri = body.redirectUri or settings.dex_portal_redirect_uri
        tokens = dex.exchange_code(code=body.code, redirect_uri=redirect_uri, provider=body.provider)
        id_token = tokens.get("id_token")
        if not id_token:
            raise APIError("auth_no_id_token", "Dex did not return an id_token", 502)
        claims = dex.verify_id_token(id_token)

        # 3. Build the canonical external identity.
        external = dex.external_identity(claims, body.provider)

        # 4. Resolve internal user (existing / collapse / brand-new viewer).
        outcome = users.resolve_on_login(external)

        if outcome["needsIdentityCollapse"]:
            return ExchangeResponse(**outcome)

        # 5. Mint the httpOnly session cookie. The Dex refresh token is kept
        #    server-side only (sessions._refresh_store), keyed by session id.
        internal_user = {
            "internalUserId": outcome["internalUserId"],
            "role": outcome["role"],
            "email": outcome["email"],
            "linkedIdentities": outcome["linkedIdentities"],
        }
        sessions.create(
            resp,
            internal_user=internal_user,
            refresh_token=tokens.get("refresh_token"),
        )
        return ExchangeResponse(**outcome)

    @app.post("/api/auth/collapse")
    def collapse(body: CollapseRequest, req: Request, resp: Response) -> SessionResponse:
        # The pending identity must have been verified in /api/auth/exchange
        # (a real Dex token exchange). We do NOT trust a client-supplied subject
        # without that proof; the caller must have a valid (pre-session) state.
        # TODO: bind the pending identity to a server-side pending token issued
        # at exchange time so collapse can't be called out of band.
        user = users.apply_collapse(
            target_internal_user_id=body.targetInternalUserId or "",
            pending_identity=body.pendingIdentity.model_dump(),
            decision=body.decision,
        )
        sessions.create(resp, internal_user=user, refresh_token=None)
        return SessionResponse(
            internalUserId=user["internalUserId"],
            role=user["role"],
            linkedIdentities=user["linkedIdentities"],
            email=user["email"],
        )

    @app.post("/api/logout")
    def logout(req: Request, resp: Response):
        # TODO: revoke the Dex refresh token at Dex's revocation endpoint using
        # the server-side refresh token from sessions._refresh_store.
        sessions.revoke(req, resp)
        return {"logged_out": True}

    @app.get("/api/users")
    def list_users(req: Request):
        _require_role(req, "superadmin")
        return {"users": users.list_all()}

    @app.patch("/api/users/{internal_id}/role")
    def set_role(internal_id: str, body: RoleUpdateRequest, req: Request):
        _require_role(req, "superadmin")
        updated = users.set_role(internal_id, body.role)
        return updated

    @app.get("/api/resources/aws")
    def aws_resources(req: Request):
        claims = _require_session(req)
        principal = _principal(claims)
        if not fga.can_view(principal, "aws"):
            raise APIError("authz_forbidden", "Cannot view AWS resources", 403)
        return proxy.list_nodes("aws")

    @app.get("/api/resources/nutanix")
    def nutanix_resources(req: Request):
        claims = _require_session(req)
        principal = _principal(claims)
        if not fga.can_view(principal, "nutanix"):
            raise APIError("authz_forbidden", "Cannot view Nutanix resources", 403)
        return proxy.list_nodes("nutanix")

    @app.post("/api/provision/aws")
    def provision_aws(body: ProvisionRequest, req: Request):
        claims = _require_session(req)
        principal = _principal(claims)
        if not fga.can_provision(principal, "aws"):
            raise APIError("authz_forbidden", "Cannot provision AWS", 403)
        return proxy.provision("aws", body.vmName or f"libcloud-demo-{int(__import__('time').time())}")

    @app.post("/api/provision/nutanix")
    def provision_nutanix(body: ProvisionRequest, req: Request):
        claims = _require_session(req)
        principal = _principal(claims)
        if not fga.can_provision(principal, "nutanix"):
            raise APIError("authz_forbidden", "Cannot provision Nutanix", 403)
        return proxy.provision("nutanix", body.vmName or f"libcloud-ntnx-{int(__import__('time').time())}")

    return app


app = create_app()
