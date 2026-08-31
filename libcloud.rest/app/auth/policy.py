from app.auth.fga_client import get_fga_client
from app.auth.identity import _load_map
from app.auth.models import TokenClaims
from app.common.errors import APIError
from app.config.settings import get_settings
from app.connections.credentials import default_auth_binding, enforce_credential_policy
from app.connections.models import PROVIDER_OBJECT_TYPES, ProviderConnection
from app.providers.factory import build_driver, probe_capabilities


READ_SCOPE_ALIASES = {
    "compute:read": {
        "compute:read",
        "compute:image:read",
        "compute:size:read",
        "compute:location:read",
        "compute:network:read",
    }
}

WRITE_SCOPES = {
    "compute:node:create",
    "compute:node:delete",
    "compute:node:power",
    "compute:node:update",
    "compute:volume:manage",
    "compute:snapshot:manage",
    "compute:network:manage",
    "compute:keypair:manage",
    "compute:image:manage",
}


class PolicyEngine:
    def _token_has_scope(self, token_scopes: set[str], required_scope: str) -> bool:
        if required_scope in token_scopes:
            return True
        for granted, aliases in READ_SCOPE_ALIASES.items():
            if granted in token_scopes and required_scope in aliases:
                return True
        return False

    def _fga_user(self, claims: TokenClaims) -> str:
        aliases = (_load_map().get("legacy_username_aliases") or {})
        principal = aliases.get(claims.sub, claims.sub)
        return f"user:{principal}"

    def _backend_object(self, connection: ProviderConnection) -> str:
        # Per-tenant isolation: the OpenFGA backend object is derived from the
        # connection's auth_binding (the tenant id), NOT from the region/cluster.
        # Each tenant maps to its own backend object (<object_type>:<binding>)
        # and its own Vault secret (secret/libcloud/<binding>), so different
        # tenants are isolated.
        #
        # The object type is looked up from PROVIDER_OBJECT_TYPES (a registry in
        # app/connections/models.py), so adding a new cloud provider requires NO
        # new code branch here — only a registry entry + OpenFGA model type. See
        # how_to_add_new_tenant.md.
        obj_type = PROVIDER_OBJECT_TYPES.get(connection.provider)
        if not obj_type:
            raise APIError(
                code="auth_provider_unsupported",
                message=f"Unsupported provider: {connection.provider}",
                status_code=400,
                details={
                    "provider": connection.provider,
                    "supported": sorted(PROVIDER_OBJECT_TYPES),
                },
            )
        binding = connection.auth_binding or default_auth_binding(connection.provider)
        return f"{obj_type}:{binding}"

    def _enforce_openfga(
        self,
        claims: TokenClaims,
        connection: ProviderConnection,
        required_scope: str,
    ) -> None:
        fga = get_fga_client()
        if not fga.enabled:
            return

        settings = get_settings()
        user = self._fga_user(claims)
        # Forward the caller's Dex JWT to OpenFGA (used when OpenFGA runs with
        # OIDC authn). Same IdP + audience as this API, so the token is accepted.
        bearer = claims.access_token
        fga.require(user, "can_connect", settings.fga_api_object, bearer=bearer)
        fga.require(user, "can_use", f"provider:{connection.provider}", bearer=bearer)

        backend = self._backend_object(connection)
        if required_scope in WRITE_SCOPES or required_scope.endswith(":manage"):
            fga.require(user, "can_provision", backend, bearer=bearer)
        else:
            if not fga.check(user, "can_read", backend, bearer=bearer):
                fga.require(user, "can_provision", backend, bearer=bearer)

    def _resolve_vault_user(self, claims: TokenClaims, connection: ProviderConnection) -> None:
        """Resolve the tenant's Vault AppRole identity name from OpenFGA
        (tenant:<binding> parent vault_user:*) and stash it on the connection.
        Falls back to the deterministic 'libcloud-<binding>' name when OpenFGA
        is disabled or returns no mapping."""
        binding = connection.auth_binding or default_auth_binding(connection.provider)
        fga = get_fga_client()
        if fga.enabled:
            objects = fga.list_objects(
                "vault_user", "parent", f"tenant:{binding}", bearer=claims.access_token
            )
            if objects:
                name = objects[0]
                if name.startswith("vault_user:"):
                    name = name[len("vault_user:"):]
                connection.vault_user = name
                return
        connection.vault_user = f"libcloud-{binding}"

    def check_scopes(self, claims: TokenClaims, scopes_any_of: list[str]) -> None:
        """Scope-only gate for connection-less routes (e.g. GET /v1/jobs/{job_id}).

        Does NOT touch OpenFGA or the provider connection — those routes have no
        connection to authorize. The READ_SCOPE_ALIASES expansion in
        ``_token_has_scope`` still applies, so ``compute:read`` implies the read
        sub-scopes listed there.
        """
        token_scopes = set(claims.scope.split())
        if not any(self._token_has_scope(token_scopes, s) for s in scopes_any_of):
            raise APIError(
                code="auth_insufficient_scope",
                message="Token does not include any required scope",
                status_code=403,
                details={"required_any_of": list(scopes_any_of)},
            )

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
        self._resolve_vault_user(claims, connection)
        return connection

    def check_driver_capability(self, connection: ProviderConnection, operation: str) -> None:
        driver = build_driver(connection)
        caps = probe_capabilities(driver)
        mapping = {
            "create_node": bool(caps.create_node_auth) or hasattr(driver, "create_node"),
            "destroy_node": hasattr(driver, "destroy_node"),
            "power_node": all(
                hasattr(driver, m) for m in ("start_node", "stop_node", "reboot_node")
            ),
            "volumes": caps.supports_volumes,
            "snapshots": caps.supports_snapshots,
            "key_pairs": caps.supports_key_pairs,
            "networking": hasattr(driver, "ex_list_subnets") or hasattr(driver, "ex_list_vpcs"),
        }
        if operation in mapping and not mapping[operation]:
            raise APIError(
                code="provider_capability_unsupported",
                message=f"Provider does not support operation: {operation}",
                status_code=400,
                details={"provider": connection.provider, "operation": operation},
            )


policy_engine = PolicyEngine()
