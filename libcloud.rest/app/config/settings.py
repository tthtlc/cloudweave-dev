from functools import lru_cache
from pathlib import Path

from dotenv import load_dotenv
from pydantic import AliasChoices, Field
from pydantic_settings import BaseSettings, SettingsConfigDict

# App root: the libcloud.rest/ directory (the parent of app/). All file-path
# settings below are resolved against this root so the app works regardless of
# the current working directory (e.g. when scripts/generate_openapi.py is run
# from $REPO_ROOT rather than from libcloud.rest/).
_APP_ROOT = Path(__file__).resolve().parents[2]

_ENV_PATH = _APP_ROOT / ".env"
if _ENV_PATH.exists():
    load_dotenv(_ENV_PATH)


def _resolve(path: str) -> str:
    """Resolve a path setting against the app root.

    Absolute paths are used as-is; relative paths are anchored to the
    libcloud.rest/ app root so they work from any cwd.
    """
    p = Path(path)
    return str(p if p.is_absolute() else (_APP_ROOT / p))


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=str(_ENV_PATH) if _ENV_PATH.exists() else None,
        extra="ignore",
    )

    jwt_signing_key: str = "change-me-in-production"
    jwt_algorithm: str = "HS256"
    access_token_ttl_seconds: int = 900
    refresh_token_ttl_seconds: int = 28800
    api_issuer: str = "libcloud-rest"
    api_audience: str = "libcloud-rest-api"

    # Optional local user directory (data/users.json). Only consulted when
    # auth_mode is "local" or "hybrid". No static/admin user is ever
    # auto-created; user identities come from the OIDC IdP (Dex → LLDAP).
    users_file: str = "data/users.json"

    app_title: str = "Libcloud REST API"
    app_version: str = "1.0.0"

    auth_mode: str = "oidc"  # local | oidc | hybrid (oidc = Dex → LLDAP)

    # Server-side backend identity.
    #
    # Per the security design (rest_api_security.md), the REST API must reach the
    # cloud backend using its OWN identity (IAM role / service account) and the
    # client must never receive or pass backend credentials. The values below are
    # the API's own backend identity, sourced from environment / secret broker
    # (ECS task role, EKS IRSA, EC2 instance profile, Vault, etc.) and never from
    # the request. In production prefer the compute platform's default credential
    # chain instead of long-lived keys.
    allow_client_credentials: bool = False

    aws_prod_key: str = Field(
        default="",
        validation_alias=AliasChoices("LIBCLOUD_AWS_PROD_KEY", "AWS_PROD_KEY"),
    )
    aws_prod_secret: str = Field(
        default="",
        validation_alias=AliasChoices("LIBCLOUD_AWS_PROD_SECRET", "AWS_PROD_SECRET"),
    )
    ntnx_lab_user: str = Field(
        default="",
        validation_alias=AliasChoices("LIBCLOUD_NTNX_LAB_USER", "NTNX_LAB_USER"),
    )
    ntnx_lab_password: str = Field(
        default="",
        validation_alias=AliasChoices("LIBCLOUD_NTNX_LAB_PASSWORD", "NTNX_LAB_PASSWORD"),
    )

    nutanix_host: str = Field(
        default="localhost",
        validation_alias=AliasChoices("NUTANIX_HOST", "LIBCLOUD_REST_NUTANIX_HOST"),
    )
    nutanix_port: int = 9440
    nutanix_api_version: str = "v4.0"
    nutanix_verify_ssl: bool = False

    # Vault secret broker (preferred source for backend cloud credentials).
    # When vault_addr + vault_token are configured, credentials are read from
    # KV v2 at {vault_mount}/data/{vault_kv_prefix}/<binding>. Environment
    # values above are used as a fallback only when Vault is not configured.
    vault_addr: str = Field(default="", validation_alias=AliasChoices("VAULT_ADDR"))
    vault_token: str = Field(default="", validation_alias=AliasChoices("VAULT_TOKEN"))
    vault_mount: str = Field(
        default="secret",
        validation_alias=AliasChoices("VAULT_KV_MOUNT", "VAULT_MOUNT"),
    )
    vault_kv_prefix: str = Field(
        default="libcloud",
        validation_alias=AliasChoices("VAULT_KV_PREFIX"),
    )

    oidc_enabled: bool = False
    oidc_issuer_url: str = ""
    oidc_jwks_url: str = ""
    oidc_client_secret: str = ""
    oidc_audience: str = "libcloud-rest"
    oidc_tenant_id: str = "default"

    # Stable principal mapping (Dex Phase 1 / Entra Phase 2)
    principal_map_file: str = "data/principal_map.json"
    auth_audit_enabled: bool = True
    auth_audit_file: str = "data/auth_audit.log"

    fga_enabled: bool = False
    fga_api_url: str = "http://localhost:8080"
    fga_store_name: str = "libcloud-rest-store"
    fga_store_id: str = ""
    fga_model_id: str = ""
    fga_api_object: str = "libcloud_api:main"
    # Per-tenant model: the backend object id is the tenant id (auth_binding).
    # These are the fallback tenant ids used when a client omits auth_binding;
    # they map to the seeded tenant:aws / tenant:nutanix and the OpenFGA
    # backend objects aws_region:aws / nutanix_cluster:nutanix.
    fga_nutanix_cluster: str = "nutanix"
    fga_aws_region_object: str = "aws"

    # Default DescribeImages filters for AWS (EC2). Restricts to Ubuntu 24.04
    # LTS (Noble Numbat) x86-64 AMIs from Canonical. The name filter matches AMI
    # names like ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*.
    # Pass name=* query param to disable, or set arch=* to skip the arch filter.
    aws_default_image_name_filter: str = "*ubuntu*24.04*amd64*"
    aws_default_image_architecture_filter: str = "x86_64"

    # External policy table: maps "METHOD path_template" -> {scopes_any_of, capability,
    # connection_required}. Loaded into memory by app.auth.policy_table and hot-reloaded
    # on file change (or via POST /v1/admin/policies:reload). Editing this file changes
    # authorization enforcement WITHOUT any source-code changes. See
    # app/auth/authorized_route.py for how it is consulted.
    policy_table_file: str = "app/auth/policies.json"

    def model_post_init(self, __context: object) -> None:
        """Anchor file-path settings to the app root so they work from any cwd."""
        for name in (
            "users_file",
            "principal_map_file",
            "auth_audit_file",
            "policy_table_file",
        ):
            setattr(self, name, _resolve(getattr(self, name)))


@lru_cache
def get_settings() -> Settings:
    return Settings()
