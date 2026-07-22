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
    DeprovisionRequest,
    EmailUpdateRequest,
    ExchangeRequest,
    ExchangeResponse,
    ProvisionRequest,
    RoleUpdateRequest,
    SessionResponse,
    TupleWriteRequest,
    UpdateRequest,
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

    def _clouds_for(internal_user_id: str) -> list[dict[str, Any]]:
        # Live per-cloud capabilities from OpenFGA, so the portal renders only
        # the tenant(s) the user can access (rbac_design.md). Pending users are
        # keyed in OpenFGA by their full internal id; LLDAP users by their uid.
        principal = users._fga_principal(internal_user_id)
        return fga.cloud_capabilities(principal)

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
            clouds=_clouds_for(claims["internalUserId"]),
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
        outcome["clouds"] = _clouds_for(outcome["internalUserId"])
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
            clouds=_clouds_for(user["internalUserId"]),
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

    # --- resource / provision / deprovision / update ------------------------
    # These four verbs are cloud-parametric: AWS and Nutanix share one code
    # path. Each route runs the OpenFGA check for the requested cloud, then
    # delegates to the LibcloudProxy method (which replays the per-cloud
    # provision_<cloud>.sh / deprovision_<cloud>.sh script or the libcloud REST
    # PATCH). The legacy /api/<verb>/aws routes below are kept as thin aliases
    # for backward compatibility with older portal builds.

    SUPPORTED_CLOUDS = ("aws", "nutanix")

    def _require_cloud(cloud: str) -> None:
        if cloud not in SUPPORTED_CLOUDS:
            raise APIError("not_supported", f"unsupported cloud: {cloud}", 400, {"cloud": cloud})

    @app.get("/api/resources/{cloud}")
    def resources_by_cloud(cloud: str, req: Request):
        _require_cloud(cloud)
        claims = _require_session(req)
        principal = _principal(claims)
        if not fga.can_view(principal, cloud):
            raise APIError("authz_forbidden", f"Cannot view {cloud} resources", 403)
        return proxy.list_nodes(cloud)

    @app.post("/api/provision/{cloud}")
    def provision_by_cloud(cloud: str, body: ProvisionRequest, req: Request):
        _require_cloud(cloud)
        claims = _require_session(req)
        principal = _principal(claims)
        if not fga.can_provision(principal, cloud):
            raise APIError("authz_forbidden", f"Cannot provision {cloud}", 403)
        return proxy.provision(cloud, body.vmName or f"libcloud-{'demo' if cloud == 'aws' else 'ntnx'}-{int(__import__('time').time())}")

    @app.post("/api/deprovision/{cloud}")
    def deprovision_by_cloud(cloud: str, body: DeprovisionRequest, req: Request):
        # Deprovisioning is a write scope (compute:node:delete), so we require
        # the same can_provision grant as provisioning. The proxy then shells
        # out to test_script/scripts/deprovision_<cloud>.sh, which re-runs the
        # FGA check and DELETEs /v1/compute/nodes/{id} — the script is the single
        # source of truth for the deprovisioning sequence.
        _require_cloud(cloud)
        claims = _require_session(req)
        principal = _principal(claims)
        if not fga.can_provision(principal, cloud):
            raise APIError("authz_forbidden", f"Cannot deprovision {cloud}", 403)
        return proxy.deprovision(cloud, body.vmName, body.vmId)

    @app.post("/api/update/{cloud}")
    def update_by_cloud(cloud: str, body: UpdateRequest, req: Request):
        # Editing a VM is a write scope distinct from create/delete. We require
        # the OpenFGA can_update grant (Owner ∪ Admin; Viewer and SuperAdmin-by-
        # default cannot — rbac_design.md changelog #10). The proxy then PATCHes
        # /v1/compute/nodes/{id} on the libcloud REST API.
        _require_cloud(cloud)
        claims = _require_session(req)
        principal = _principal(claims)
        if not fga.can_update(principal, cloud):
            raise APIError("authz_forbidden", f"Cannot update {cloud} VM", 403)
        updates = {
            "name": body.name,
            "new_size_id": body.newSizeId,
            "memory_mib": body.memoryMib,
            "tag_key": body.tagKey,
            "tag_value": body.tagValue,
        }
        return proxy.update_node(cloud, body.vmId, updates)

    # --- legacy per-cloud routes removed ------------------------------------
    # The cloud-parametric routes above (e.g. /api/resources/{cloud}) already
    # match /api/resources/aws and /api/resources/nutanix, so explicit per-cloud
    # aliases would be unreachable dead code. Older portal builds that still
    # POST to /api/provision/aws etc. keep working because {cloud} captures
    # "aws" | "nutanix".

    return app


app = create_app()
