"""Server-side backend credential resolution.

Per ``rest_api_security.md`` the REST API must use its own backend identity
(IAM role / service account) to reach the cloud provider. Clients authenticate
to the API with OIDC/OAuth2 and never receive or pass backend credentials.

The client selects a server-side identity by ``auth_binding`` on the
connection object. The API resolves the actual credentials from its own
environment / secret broker here.
"""
from __future__ import annotations

from app.common.errors import APIError
from app.config.settings import get_settings
from app.connections.models import (
    ConnectionCredentials,
    ProviderConnection,
)
from app.connections.vault_client import get_vault_client


# Per-tenant model: auth_binding is the tenant id (e.g. "aws", "aws-dev",
# "nutanix"). Defaults map to the seeded tenant:aws / tenant:nutanix. Arbitrary
# tenant ids are accepted — authorization is enforced by OpenFGA
# (can_use / can_provision on the per-tenant backend object), and a missing
# Vault secret surfaces as 503.
_PROVIDER_TO_DEFAULT_BINDING = {"aws": "aws", "nutanix": "nutanix"}


def enforce_credential_policy(connection: ProviderConnection) -> None:
    """Reject client-supplied credentials unless explicitly enabled for dev."""
    settings = get_settings()
    if connection.credentials is not None and not settings.allow_client_credentials:
        raise APIError(
            code="auth_client_credentials_forbidden",
            message=(
                "Client-supplied backend credentials are not accepted. "
                "The API uses its own backend identity; set 'auth_binding' "
                "instead of 'credentials'."
            ),
            status_code=403,
            details={"provider": connection.provider},
        )


def default_auth_binding(provider: str) -> str:
    """Default auth_binding (tenant id) when the client omits it.

    Resolution order:
      1. provider-specific settings override (FGA_AWS_REGION_OBJECT /
         FGA_NUTANIX_CLUSTER) if set,
      2. the per-provider default in _PROVIDER_TO_DEFAULT_BINDING,
      3. the provider id itself (so a newly added provider with no explicit
         default still resolves to a tenant id equal to its provider id).
    """
    settings = get_settings()
    if provider == "nutanix" and settings.fga_nutanix_cluster:
        return settings.fga_nutanix_cluster
    if provider == "aws" and settings.fga_aws_region_object:
        return settings.fga_aws_region_object
    return _PROVIDER_TO_DEFAULT_BINDING.get(provider, provider)


# Back-compat alias for any internal caller.
_default_binding = default_auth_binding


def _env_credentials(provider: str, binding: str) -> ConnectionCredentials | None:
    """Fallback: read the API's own backend identity from environment."""
    settings = get_settings()
    if provider == "aws":
        key, secret = settings.aws_prod_key, settings.aws_prod_secret
    elif provider == "nutanix":
        key, secret = settings.ntnx_lab_user, settings.ntnx_lab_password
    else:  # pragma: no cover - guarded by the connection model
        return None
    if not key or not secret:
        return None
    return ConnectionCredentials(key=key, secret=secret)


def resolve_server_credentials(connection: ProviderConnection) -> ConnectionCredentials:
    """Resolve the API's own backend credentials for the requested provider.

    Resolution order:
      1. Vault KV v2 (preferred secret broker) when VAULT_ADDR/VAULT_TOKEN set.
      2. Environment fallback (dev only, when Vault is not configured).
    """
    provider = connection.provider
    binding = connection.auth_binding or _default_binding(provider)

    vault = get_vault_client()
    if vault.enabled:
        # The per-tenant Vault AppRole identity (resolved from OpenFGA by the
        # policy engine, or the deterministic fallback name).
        vault_user = connection.vault_user or f"libcloud-{binding}"
        try:
            data = vault.read_secret(binding, vault_user=vault_user)
        except APIError as exc:
            # If Vault is reachable but the secret is missing/unavailable, do
            # NOT silently fall back to env — that would hide a misconfiguration
            # and potentially use a stale/plaintext credential. Surface the 503.
            raise
        key = data.get("key") or ""
        secret = data.get("secret") or ""
        if not key or not secret:
            raise APIError(
                code="server_credentials_missing",
                message=f"Vault secret '{binding}' is missing key/secret fields",
                status_code=503,
                details={"auth_binding": binding},
            )
        return ConnectionCredentials(key=key, secret=secret)

    creds = _env_credentials(provider, binding)
    if creds is None:
        raise APIError(
            code="server_credentials_missing",
            message=(
                "The API is not configured with a backend identity for this "
                "provider. Configure Vault (preferred) or the server-side "
                "credential env vars."
            ),
            status_code=503,
            details={"provider": provider, "auth_binding": binding},
        )
    return creds


def effective_credentials(connection: ProviderConnection) -> ConnectionCredentials:
    """Return the credentials to use for a backend call.

    Client-supplied credentials are rejected unless the API allows them; the
    server-side identity is used otherwise.
    """
    enforce_credential_policy(connection)
    if connection.credentials is not None:
        return connection.credentials
    return resolve_server_credentials(connection)
