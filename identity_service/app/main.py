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
    OpenFgaExpandRequest,
    OpenFgaListObjectsRequest,
    OpenFgaListUsersRequest,
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
    # CORS origins are derived from PUBLIC_HOSTNAME env var so a server migration
    # only needs a DNS change (or /etc/hosts entry), not a code change.
    _cors_host = f"http://{__import__('os').environ.get('PUBLIC_HOSTNAME', 'localhost')}:3000"
    app.add_middleware(
        CORSMiddleware,
        allow_origins=[_cors_host, "http://localhost:3000"],
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
        # The OpenFGA principal for the session's internal user. This MUST use
        # the same mapping as /api/session's clouds (UserService._fga_principal):
        # LLDAP users are keyed by uid ("int-<uid>" -> "<uid>"); pending
        # (federated, not yet LLDAP-linked) users are keyed by their FULL
        # internal id. Stripping "int-" unconditionally made a pending user's
        # verb checks query a non-existent principal and 403, while
        # /api/session still showed their clouds as accessible.
        return users._fga_principal(claims["internalUserId"])

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
            id_token=tokens.get("id_token"),
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
        # 1. Clear the portal session cookie and retrieve the stored Dex tokens
        #    (refresh_token + id_token) before they are dropped.
        stored = sessions.revoke(req, resp)

        # 2. Revoke the Dex refresh token at Dex's OAuth2 revocation endpoint
        #    (RFC 7009). Best-effort: failures are logged but never block logout.
        refresh_token = (stored or {}).get("refresh_token")
        if refresh_token:
            try:
                dex.revoke_token(refresh_token)
            except Exception as exc:
                log.warning("Failed to revoke Dex refresh token: %s", exc)

        # 3. No IdP-side redirect: stock Dex has no RP-initiated logout endpoint
        #    (GET /dex/auth/logout 404s with `Invalid client_id ("")`) and keeps
        #    no browser SSO cookie — every /dex/auth request re-prompts the
        #    connector login form. The refresh-token revocation above is the
        #    whole IdP-side logout; the frontend navigates to /login on its own.
        return {"logged_out": True}

    @app.get("/api/users")
    def list_users(req: Request):
        _require_role(req, "superadmin")
        return {"users": users.list_all()}

    @app.patch("/api/users/{internal_id}/role")
    def set_role(internal_id: str, body: RoleUpdateRequest, req: Request):
        _require_role(req, "superadmin")
        updated = users.set_role(internal_id, body.role, tenant=body.tenant)
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

    # --- OpenFGA explorer (superadmin) ---------------------------------------
    @app.get("/api/openfga/store")
    def openfga_store(req: Request):
        _require_role(req, "superadmin")
        return fga.get_store()

    @app.get("/api/openfga/models")
    def openfga_models(req: Request):
        _require_role(req, "superadmin")
        return fga.list_authorization_models()

    @app.get("/api/openfga/models/{model_id}")
    def openfga_model(model_id: str, req: Request):
        _require_role(req, "superadmin")
        return fga.get_authorization_model(model_id)

    @app.get("/api/openfga/assertions/{model_id}")
    def openfga_assertions(model_id: str, req: Request):
        _require_role(req, "superadmin")
        return fga.read_assertions(model_id)

    @app.get("/api/openfga/changes")
    def openfga_changes(
        req: Request,
        type: str | None = None,
        page_size: int = 50,
        continuation_token: str | None = None,
    ):
        _require_role(req, "superadmin")
        return fga.read_changes(
            change_type=type,
            page_size=page_size,
            continuation_token=continuation_token,
        )

    @app.post("/api/openfga/list-users")
    def openfga_list_users(body: OpenFgaListUsersRequest, req: Request):
        _require_role(req, "superadmin")
        payload: dict[str, Any] = {
            "object": body.object,
            "relation": body.relation,
        }
        if body.user_filters:
            payload["user_filters"] = body.user_filters
        return fga.list_users_openfga(payload)

    @app.post("/api/openfga/list-objects")
    def openfga_list_objects(body: OpenFgaListObjectsRequest, req: Request):
        _require_role(req, "superadmin")
        return fga.list_objects({
            "type": body.type,
            "relation": body.relation,
            "user": body.user,
        })

    @app.post("/api/openfga/expand")
    def openfga_expand(body: OpenFgaExpandRequest, req: Request):
        _require_role(req, "superadmin")
        return fga.expand({
            "tuple_key": {
                "relation": body.relation,
                "object": body.object,
            },
        })

    @app.get("/api/openfga/rest-api-policies")
    def openfga_rest_api_policies(req: Request):
        _require_role(req, "superadmin")
        import json as _json
        import os as _os

        path = settings.rest_api_policies_path
        if _os.path.isfile(path):
            try:
                with open(path, "r", encoding="utf-8") as fh:
                    return _json.load(fh)
            except Exception as exc:
                log.warning("Failed to read REST API policies at %s: %s", path, exc)
        return {}

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
        return proxy.list_nodes(cloud, fga.tenant_binding(principal, cloud))

    @app.get("/api/hosts/{cloud}")
    def hosts_by_cloud(cloud: str, req: Request):
        # Physical host details for the cluster's hosts (Nutanix only). Read
        # scope — same can_view gate as /api/resources/{cloud}; the proxy fans
        # out to /v1/compute/hosts, which replays the driver's ex_list_hosts
        # (clustermgmt v4 Host API) with full CPU/memory/hypervisor/serial
        # detail. AWS has no equivalent physical-host list, so it is rejected
        # here rather than delegated to the REST layer.
        _require_cloud(cloud)
        claims = _require_session(req)
        principal = _principal(claims)
        if not fga.can_view(principal, cloud):
            raise APIError("authz_forbidden", f"Cannot view {cloud} hosts", 403)
        if cloud != "nutanix":
            raise APIError(
                "not_supported",
                "Host details are only available for Nutanix",
                400,
                {"cloud": cloud},
            )
        return proxy.list_hosts(cloud, fga.tenant_binding(principal, cloud))

    @app.post("/api/provision/{cloud}")
    def provision_by_cloud(cloud: str, body: ProvisionRequest, req: Request):
        _require_cloud(cloud)
        claims = _require_session(req)
        principal = _principal(claims)
        if not fga.can_provision(principal, cloud):
            raise APIError("authz_forbidden", f"Cannot provision {cloud}", 403)
        return proxy.provision(cloud, body.vmName or f"libcloud-{'demo' if cloud == 'aws' else 'ntnx'}-{int(__import__('time').time())}", fga.tenant_binding(principal, cloud))

    @app.post("/api/provision-private/{cloud}")
    def provision_private_by_cloud(cloud: str, body: ProvisionRequest, req: Request):
        # The portal's "Provision Private VM Machine" button: bastion host +
        # internal private server pair (aws_bastion_internal_server.md /
        # nutanix_bastion_internal_server.md). Gated on the SAME OpenFGA
        # can_provision grant as single-VM provisioning — i.e. only the cloud's
        # tenant owner/admin pass, and the portal renders the button from the
        # same canProvision capability viewers/superadmins don't get. The proxy
        # shells out to test_script/scripts/provision_aws_private.sh /
        # provision_nutanix_bastion_private.sh, which stays the single source
        # of truth for the 2-VM sequence.
        _require_cloud(cloud)
        claims = _require_session(req)
        principal = _principal(claims)
        if not fga.can_provision(principal, cloud):
            raise APIError("authz_forbidden", f"Cannot provision private VM pair on {cloud}", 403)
        pair_prefix = "aws" if cloud == "aws" else "ntnx"
        return proxy.provision_private(cloud, body.vmName or f"libcloud-{pair_prefix}-pair-{int(__import__('time').time())}", fga.tenant_binding(principal, cloud))

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
        return proxy.deprovision(cloud, body.vmName, body.vmId, fga.tenant_binding(principal, cloud))

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
        return proxy.update_node(cloud, body.vmId, updates, fga.tenant_binding(principal, cloud))

    # --- legacy per-cloud routes removed ------------------------------------
    # The cloud-parametric routes above (e.g. /api/resources/{cloud}) already
    # match /api/resources/aws and /api/resources/nutanix, so explicit per-cloud
    # aliases would be unreachable dead code. Older portal builds that still
    # POST to /api/provision/aws etc. keep working because {cloud} captures
    # "aws" | "nutanix".

    return app


app = create_app()
