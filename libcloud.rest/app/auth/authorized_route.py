"""Custom FastAPI ``APIRoute`` that enforces authorization before the handler runs.

This is the single place where authorization lives for every provisioning route.
Route handlers themselves contain ZERO authorization logic — no ``policy_engine``
import, no scope strings, no ``claims`` parameter, no ``authorized_for`` Depends.
They just read ``request.state.connection`` (and, for async/job handlers,
``request.state.authorized_claims``) and call the service tier.

Enforcement flow (per request):

1. Look up the policy entry for ``f"{request.method} {route.path}"`` in the
   external ``policies.json`` table (hot-reloadable). Missing entry -> 500
   ``policy_unknown_operation`` (fail-closed).
2. Resolve ``TokenClaims`` from the bearer token.
3. If ``connection_required`` (default true): resolve the provider connection
   from the ``X-Provider-Connection`` header / ``?connection=`` query, then run
   ``policy_engine.authorize_connection`` (scope + provider allow-list + OpenFGA
   ``can_connect``/``can_use``/``can_provision``/``can_read`` + credential policy)
   and, if the entry declares a ``capability``, ``check_driver_capability``.
   Stash the authorized connection on ``request.state.connection``.
4. If ``connection_required=false``: run ``policy_engine.check_scopes`` only
   (scope gate, no connection/FGA).
5. Always stash ``request.state.authorized_claims``.
6. Call the handler.

Changing authorization for any route = editing ``app/auth/policies.json`` +
(optional) reload. No source changes, no restart.
"""

from __future__ import annotations

import json
from typing import Any, Callable

from fastapi import APIRouter, Request
from fastapi.routing import APIRoute

from app.auth.dependencies import claims_from_request, connection_from_request
from app.auth.policy import policy_engine
from app.auth.policy_table import policy_table
from app.connections.models import ProviderConnection

# OpenAPI header doc injected on every authorized route so Swagger still shows
# X-Provider-Connection even though handlers no longer declare a Depends for it.
_CONNECTION_HEADER_PARAM = {
    "name": "X-Provider-Connection",
    "in": "header",
    "required": True,
    "description": (
        "JSON provider connection object, e.g. "
        '{"provider":"aws","auth_binding":"aws"}. Preferred over the '
        "connection query parameter."
    ),
    "schema": {"type": "string"},
}


class AuthorizedAPIRoute(APIRoute):
    """APIRoute subclass that authorizes every request before the handler runs."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Startup validation + OpenAPI doc: every authorized route MUST have a
        # policy table entry (fail-closed at import time if missing). We only
        # document the X-Provider-Connection header on connection-required routes.
        method = next(iter(sorted(self.methods or {"GET"})))
        route_key = f"{method} {self.path}"
        entry = policy_table.get(route_key)
        if entry.get("connection_required", True):
            existing = (
                list(self.openapi_extra.get("parameters", []))
                if self.openapi_extra
                else []
            )
            existing.append(dict(_CONNECTION_HEADER_PARAM))
            if self.openapi_extra is None:
                self.openapi_extra = {}
            self.openapi_extra["parameters"] = existing

    def get_route_handler(self) -> Callable:
        original_route_handler = super().get_route_handler()
        route_path = self.path

        async def custom_route_handler(request: Request):
            route_key = f"{request.method} {route_path}"
            entry = policy_table.get(route_key)

            claims = claims_from_request(request)
            request.state.authorized_claims = claims

            if entry.get("connection_required", True):
                connection: ProviderConnection = connection_from_request(request)

                # Resolve the scope passed to authorize_connection. Usually it is
                # scopes_any_of[0], but a route may declare an explicit
                # ``authz_scope`` or, for action-conditional routes (e.g.
                # PATCH /nodes/{node_id}), an ``authz_scope_by_body_field`` map
                # keyed on a body field. Body bytes are cached by Starlette so
                # FastAPI's later body parsing still works.
                if "authz_scope_by_body_field" in entry:
                    spec: dict[str, Any] = entry["authz_scope_by_body_field"]
                    body_bytes = await request.body()
                    try:
                        body_json = json.loads(body_bytes) if body_bytes else {}
                    except json.JSONDecodeError:
                        body_json = {}
                    field_val = body_json.get(spec["field"]) if isinstance(body_json, dict) else None
                    authz_scope = spec["map"].get(
                        field_val, entry.get("authz_scope", entry["scopes_any_of"][0])
                    )
                else:
                    authz_scope = entry.get("authz_scope", entry["scopes_any_of"][0])

                policy_engine.authorize_connection(claims, connection, authz_scope)
                capability = entry.get("capability")
                if capability:
                    policy_engine.check_driver_capability(connection, capability)
                request.state.connection = connection
            else:
                policy_engine.check_scopes(claims, entry["scopes_any_of"])

            return await original_route_handler(request)

        return custom_route_handler


def make_authorized_router(prefix: str, tags: list[str]) -> APIRouter:
    """Build an APIRouter whose every route is auto-authorized.

    Provisioning routers (compute, network, storage, connections, jobs, admin)
    use this. Auth/providers/health stay on plain ``APIRouter`` instances so
    they bypass the policy table.
    """
    return APIRouter(prefix=prefix, tags=tags, route_class=AuthorizedAPIRoute)
