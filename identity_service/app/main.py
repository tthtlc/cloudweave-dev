from __future__ import annotations

import logging
from typing import Any

from fastapi import Depends, FastAPI, Request, Response
from fastapi.middleware.cors import CORSMiddleware

from app.auth_state import AuthService
from app.config import get_settings
from app.dex import DexService
from app.errors import APIError, api_error_handler
from app.fga import FgaService
from app.libcloud_proxy import LibcloudProxy
from app.lldap import LldapService
from app.models import (
    CollapseRequest,
    EmailUpdateRequest,
    ExchangeRequest,
    ExchangeResponse,
    ProvisionRequest,
    RoleUpdateRequest,
    SessionResponse,
    TupleWriteRequest,
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
    auth = AuthService()

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

    @app.get("/api/auth/begin")
    def auth_begin(provider: str, redirect_uri: str | None = None) -> dict[str, str]:
        """Start a login: mint a server-issued `state` + PKCE verifier, store
        them, and return the Dex authorize URL (with `state` + `code_challenge`
        + `connector_id`). The browser redirects to `authorizeUrl`; on callback
        it sends `state` + `code` to /api/auth/exchange, which consumes them."""
        redir = redirect_uri or settings.dex_portal_redirect_uri
        return auth.begin(provider=provider, redirect_uri=redir)

    @app.post("/api/auth/exchange")
    def exchange(body: ExchangeRequest, req: Request, resp: Response) -> ExchangeResponse:
        # 1. CSRF/state + PKCE: the server issued `state` and a PKCE verifier at
        #    /api/auth/begin and stored them. Consume them here (single-use,
        #    TTL-bounded). The browser's client-side state check is only
        #    defense-in-depth; this is the authoritative check.
        state_entry = auth.consume_state(body.state)
        # The provider the user actually picked is the one bound at begin time;
        # prefer it over the client-supplied one.
        provider = state_entry["provider"] or body.provider
        redirect_uri = body.redirectUri or state_entry["redirect_uri"] or settings.dex_portal_redirect_uri
        code_verifier = state_entry["code_verifier"]

        if not body.code:
            raise APIError("auth_missing_code", "authorization code required", 400)

        # 2. Token exchange with Dex (server-side client secret + PKCE verifier).
        tokens = dex.exchange_code(
            code=body.code,
            redirect_uri=redirect_uri,
            provider=provider,
            code_verifier=code_verifier,
        )
        id_token = tokens.get("id_token")
        if not id_token:
            raise APIError("auth_no_id_token", "Dex did not return an id_token", 502)
        claims = dex.verify_id_token(id_token)

        # 3. Build the canonical external identity from the VERIFIED id token.
        external = dex.external_identity(claims, provider)

        # 4. Resolve internal user (existing / collapse / brand-new viewer).
        outcome = users.resolve_on_login(external)

        if outcome["needsIdentityCollapse"]:
            # Issue a single-use pending token binding the Dex-verified identity
            # to this collapse attempt. The browser carries it to /collapse;
            # the client-supplied subject is no longer trusted.
            outcome["pendingToken"] = auth.issue_pending(external)
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
        # The pending identity MUST come from the server-issued pending token
        # (consumed here, single-use), NOT from the client-supplied
        # pendingIdentity. This proves the caller authenticated this identity
        # via Dex at exchange time and prevents account-takeover by linking an
        # arbitrary subject into a victim's internal user.
        if not body.pendingToken:
            raise APIError("auth_missing_pending_token", "pendingToken required", 400)
        verified_identity = auth.consume_pending(body.pendingToken)

        user = users.apply_collapse(
            target_internal_user_id=body.targetInternalUserId or "",
            pending_identity=verified_identity,
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

    @app.post("/api/users/{internal_id}/disable")
    def disable_user(internal_id: str, req: Request):
        # System-scoped disable: revoke every managed role tuple for this user
        # in OpenFGA. The user stays valid in LLDAP / the external IdP; they are
        # simply denied everywhere in THIS system until re-granted a role.
        _require_role(req, "superadmin")
        users.disable_user(internal_id)
        return {"internalUserId": internal_id, "disabled": True}

    @app.patch("/api/users/{internal_id}/email")
    def set_email(internal_id: str, body: EmailUpdateRequest, req: Request):
        # Email is the platform's contact channel; the superadmin screen
        # requires it. This updates the LLDAP user's mail attribute.
        _require_role(req, "superadmin")
        return users.set_email(internal_id, body.email)

    # --- OpenFGA tuple CRUD (superadmin power screen) -----------------------
    @app.get("/api/tuples")
    def list_tuples(req: Request):
        _require_role(req, "superadmin")
        return {"tuples": fga.list_tuples()}

    @app.post("/api/tuples")
    def write_tuples(body: TupleWriteRequest, req: Request):
        _require_role(req, "superadmin")
        triples = [t.model_dump() for t in body.writes]
        fga.write_tuples(triples)
        return {"written": len(triples)}

    @app.delete("/api/tuples")
    def delete_tuples(body: TupleWriteRequest, req: Request):
        _require_role(req, "superadmin")
        triples = [t.model_dump() for t in body.deletes]
        fga.delete_tuples(triples)
        return {"deleted": len(triples)}

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
