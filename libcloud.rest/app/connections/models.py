from pydantic import BaseModel, Field, field_validator

ALL_SCOPES = [
    "compute:read",
    "compute:image:read",
    "compute:image:manage",
    "compute:size:read",
    "compute:location:read",
    "compute:node:create",
    "compute:node:delete",
    "compute:node:power",
    "compute:node:update",
    "compute:volume:manage",
    "compute:snapshot:manage",
    "compute:network:read",
    "compute:network:manage",
    "compute:keypair:manage",
    "jobs:read",
    "admin:connections:read",
]


class ConnectionConfig(BaseModel):
    region: str | None = None
    host: str | None = None
    port: int | None = None
    secure: bool = True
    api_version: str | None = None
    verify_ssl_cert: bool | None = None
    # Nutanix session-cookie auth (see libcloud NutanixConnection). When
    # login_path is set the driver performs a one-time Basic-auth login and
    # reuses the returned session cookie; session_cookie lets a caller replay
    # an already-established session instead of the API re-fetching the backend
    # credential from Vault on every call.
    login_path: str | None = None
    session_cookie: str | None = None


class ConnectionCredentials(BaseModel):
    key: str
    secret: str


# Per-tenant model: auth_binding is the tenant id (e.g. "aws", "aws-dev",
# "nutanix"). It selects the OpenFGA backend object (<type>:<binding>) and the
# Vault secret at secret/libcloud/<binding>. Arbitrary tenant ids are accepted;
# authorization is enforced by OpenFGA, and a missing Vault secret surfaces as
# 503. The defaults are "aws" / "nutanix" (see connections/credentials.py).

# Structural mapping: cloud provider id -> OpenFGA backend object type.
# Adding a new cloud provider = add one entry here (plus the matching type
# definition in the OpenFGA model, a driver in app/providers/, and an entry in
# the PROVIDERS list in app/providers/routes.py). The policy engine derives the
# backend object from this registry, so NO per-provider code branch is needed
# in app/auth/policy.py::_backend_object. See how_to_add_new_tenant.md.
PROVIDER_OBJECT_TYPES: dict[str, str] = {
    "aws": "aws_region",
    "nutanix": "nutanix_cluster",
}


class ProviderConnection(BaseModel):
    """Provider target for a single API call.

    Backend credentials are NOT supplied by the client. The client selects a
    server-side identity via ``auth_binding`` — the tenant id (e.g. ``aws`` or
    ``aws-dev``); the API resolves the actual credentials from Vault at
    ``secret/libcloud/<auth_binding>``. Client-supplied ``credentials`` are
    rejected unless the API is explicitly configured with
    ``ALLOW_CLIENT_CREDENTIALS=true`` (local dev only).
    """

    provider: str
    config: ConnectionConfig = Field(default_factory=ConnectionConfig)
    credentials: ConnectionCredentials | None = None
    auth_binding: str | None = None
    # Resolved per-tenant Vault AppRole identity name (e.g. "libcloud-aws"),
    # populated by the policy engine from OpenFGA (tenant -> vault_user) and
    # consumed by the credential resolver. Not part of the client contract —
    # excluded from serialization.
    vault_user: str | None = Field(default=None, exclude=True)

    @field_validator("provider")
    @classmethod
    def _provider_must_be_registered(cls, v: str) -> str:
        # Validated against PROVIDER_OBJECT_TYPES so adding a new cloud provider
        # is a registry addition, not a Literal/enum edit. See
        # how_to_add_new_tenant.md.
        if v not in PROVIDER_OBJECT_TYPES:
            raise ValueError(
                f"Unsupported provider '{v}'. Registered: {sorted(PROVIDER_OBJECT_TYPES)}"
            )
        return v


class ConnectionCapabilities(BaseModel):
    create_node_auth: list[str] = Field(default_factory=list)
    supports_volumes: bool = False
    supports_snapshots: bool = False
    supports_key_pairs: bool = False
    supports_wait_until_running: bool = False


def connection_target(connection: ProviderConnection) -> str:
    if connection.provider == "aws":
        return f"aws:{connection.config.region or 'default'}"
    host = connection.config.host or "localhost"
    port = connection.config.port or 9440
    return f"nutanix:{host}:{port}"
