from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from dotenv import load_dotenv
from pydantic import AliasChoices, Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

_APP_ROOT = Path(__file__).resolve().parents[1]

_ENV_PATH = _APP_ROOT / ".env"
if _ENV_PATH.exists():
    load_dotenv(_ENV_PATH)

# NOTE: we intentionally do NOT auto-load dex/generated/dex.env,
# openfga_postgres/generated/fga.env, or lldap/.env here. Those files use
# host-side URLs (localhost:5556, localhost:8080) which are wrong inside a
# container on the libcloud_net network. Instead, docker-compose.yml mounts
# them via `env_file` (so DEX_PORTAL_CLIENT_SECRET / FGA_STORE_ID /
# LLDAP_LDAP_USER_PASS are available) and overrides the *_URL / *_HOST keys
# via `environment:` to their in-container form (http://dex:5556/dex,
# http://openfga:8080, lldap, http://libcloud-rest-api:8765).


class Settings(BaseSettings):
    model_config = SettingsConfigDict(extra="ignore", env_file=str(_ENV_PATH) if _ENV_PATH.exists() else None)

    app_title: str = "libcloud Portal Identity Service"
    app_version: str = "0.1.0"

    # --- Dex (OIDC issuer) ---
    # dex_base_url is the SERVER-side URL the identity service uses to build the
    # authorize URL it returns to the browser. It MUST be browser-reachable
    # (public hostname), because the browser navigates to it. The token/JWKS
    # URLs below are server-to-server (in-container DNS) and stay as dex:5556.
    dex_base_url: str = "http://login.quest4science.xyz:5556/dex"
    dex_token_url: str = "http://dex:5556/dex/token"
    dex_jwks_url: str = "http://dex:5556/dex/keys"
    # dex_issuer is the canonical `iss` claim Dex puts in ID tokens. It MUST
    # match Dex's configured issuer (now the PUBLIC URL, so federated connector
    # callbacks {issuer}/callback are browser-reachable). The identity service
    # validates ID-token `iss` against this; the key comes from dex_jwks_url
    # (in-container, fast) — same key regardless of which URL fetched it.
    dex_issuer: str = "http://login.quest4science.xyz:5556/dex"
    dex_portal_client_id: str = "libcloud-portal"
    dex_portal_client_secret: str = ""
    dex_portal_redirect_uri: str = "http://localhost:3000/auth/callback"

    # --- OpenFGA (authorization) ---
    fga_enabled: bool = True
    fga_api_url: str = "http://openfga:8081"
    fga_store_id: str = ""
    fga_model_id: str = ""
    fga_aws_tenant: str = "tenant:aws"
    fga_ntnx_tenant: str = "tenant:nutanix"

    # --- LLDAP (internal user directory) ---
    lldap_host: str = "lldap"
    lldap_port: int = 3890
    lldap_use_ssl: bool = False
    # bind_dn / bind_pw are the service-account credentials the identity service
    # uses to search LLDAP for the identity-collapse heuristic. They're NOT in
    # lldap/.env directly (that file has LLDAP_LDAP_USER_PASS / LLDAP_ADMIN_USER /
    # LLDAP_LDAP_BASE_DN); setup.sh derives LLDAP_BIND_DN/PW from those, but the
    # identity-service compose is often run standalone (without setup.sh's
    # exports), so we also accept the raw lldap/.env vars and derive below.
    lldap_bind_dn: str = ""
    lldap_bind_pw: str = ""
    lldap_base_dn: str = "ou=people,dc=libcloud,dc=local"
    # Raw lldap/.env vars (loaded into the container via docker-compose env_file).
    lldap_admin_user: str = "admin"
    lldap_ldap_user_pass: str = ""
    lldap_ldap_base_dn: str = "dc=libcloud,dc=local"
    # HTTP/GraphQL endpoint for admin mutations (updateUser to set email).
    # Default is the in-container URL on the shared libcloud_net network.
    lldap_http_url: str = "http://lldap:17170"

    @model_validator(mode="after")
    def _derive_lldap_bind(self) -> "Settings":
        if not self.lldap_bind_dn:
            self.lldap_bind_dn = f"uid={self.lldap_admin_user},ou=people,{self.lldap_ldap_base_dn}"
        if not self.lldap_bind_pw:
            self.lldap_bind_pw = self.lldap_ldap_user_pass
        return self

    @model_validator(mode="after")
    def _derive_script_paths(self) -> "Settings":
        # config.py lives at <repo_root>/identity_service/app/config.py, so
        # parents[2] is the repo root that contains test_script/.
        if not self.repo_root:
            self.repo_root = str(Path(__file__).resolve().parents[2])
        scripts = Path(self.repo_root) / "test_script" / "scripts"
        if not self.deprovision_aws_script:
            self.deprovision_aws_script = str(scripts / "deprovision_aws.sh")
        if not self.deprovision_ntnx_script:
            self.deprovision_ntnx_script = str(scripts / "deprovision_nutanix.sh")
        if not self.provision_private_ntnx_script:
            self.provision_private_ntnx_script = str(scripts / "provision_nutanix_bastion_private.sh")
        if not self.provision_private_aws_script:
            self.provision_private_aws_script = str(scripts / "provision_aws_private.sh")
        return self

    # --- libcloud REST API (cloud orchestration) ---
    libcloud_rest_url: str = "http://libcloud-rest-api:8765"

    # --- Deprovisioning via test_script/scripts/deprovision_<cloud>.sh ---
    # The identity service shells out to these scripts (curl DELETE
    # /v1/compute/nodes/{id}) rather than reimplementing the flow, so each
    # script stays the single source of truth for its deprovisioning sequence.
    # Defaults to <repo_root>/test_script/scripts/deprovision_<cloud>.sh where
    # repo_root is two parents above the identity_service package.
    repo_root: str = ""
    deprovision_aws_script: str = ""
    deprovision_ntnx_script: str = ""
    # Seconds before a deprovision_aws.sh run is killed (curl DELETE + FGA
    # checks should be well under this).
    deprovision_timeout_seconds: int = 180

    # --- Private VM pair provisioning (bastion + internal) ------------------
    # The portal's "Provision Private VM Machine" button shells out to these
    # scripts (aws_bastion_internal_server.md / nutanix_bastion_internal_server.md
    # scenarios), so each script stays the single source of truth for its 2-VM
    # sequence. Defaults derived in _derive_script_paths above.
    provision_private_ntnx_script: str = ""
    provision_private_aws_script: str = ""
    # Two VM creates (each waits on the Prism task / wait_until_running) plus
    # the network stack (subnets / VPC+IGW+route table) take much longer than
    # a deprovision.
    provision_private_timeout_seconds: int = 900

    # --- Provisioner service-account login (libcloud-rest-audience token) ---
    # The portal user authenticates via the libcloud-portal client (audience
    # libcloud-portal), but the REST API validates tokens with audience
    # libcloud-rest. To bridge this, the identity service performs the same
    # Dex LDAP login flow as test_script/scripts/idp_login.py (no ephemeral
    # callback server: we capture the code from the 302 Location header) as a
    # per-cloud provisioner LLDAP user. Portal-user authorization is still
    # enforced by the identity service via OpenFGA before these calls run.
    dex_url: str = "http://dex:5556"  # base without /dex (login form + /dex/token)
    libcloud_oidc_client_id: str = Field(default="libcloud-rest", validation_alias=AliasChoices("LIBCLOUD_OIDC_CLIENT_ID"))
    libcloud_oidc_client_secret: str = Field(default="", validation_alias=AliasChoices("LIBCLOUD_OIDC_CLIENT_SECRET"))
    libcloud_oidc_redirect_uri: str = "http://127.0.0.1:8766/oauth/callback"
    provisioner_aws_user: str = Field(default="", validation_alias=AliasChoices("LIBCLOUD_USER_AWS_ADMIN"))
    provisioner_aws_password: str = Field(default="", validation_alias=AliasChoices("LIBCLOUD_PASSWORD_AWS_ADMIN"))
    provisioner_ntnx_user: str = Field(default="", validation_alias=AliasChoices("LIBCLOUD_USER_NTNX_ADMIN"))
    provisioner_ntnx_password: str = Field(default="", validation_alias=AliasChoices("LIBCLOUD_PASSWORD_NTNX_ADMIN"))
    aws_region: str = Field(default="ap-southeast-1", validation_alias=AliasChoices("AWS_REGION"))
    aws_auth_binding: str = "aws"
    # Cap per resource category in the "View <cloud> Resources" inventory (the
    # AWS AMI catalog alone is thousands of rows); the true count rides in
    # `total`. Shared by the AWS and Nutanix category fan-out.
    inventory_max_rows: int = Field(default=50, validation_alias=AliasChoices("INVENTORY_MAX_ROWS"))
    ntnx_auth_binding: str = "nutanix"
    ntnx_host: str = Field(default="host.docker.internal", validation_alias=AliasChoices("NUTANIX_HOST"))
    ntnx_port: int = Field(default=9440, validation_alias=AliasChoices("NUTANIX_PORT"))
    ntnx_api_version: str = Field(default="v4.0", validation_alias=AliasChoices("NUTANIX_API_VERSION"))
    ntnx_verify_ssl: bool = False
    provisioner_connector_id: str = "lldap"

    # --- Session cookie ---
    session_secret: str = "change-me"
    session_cookie_name: str = "libcloud_portal_sid"
    session_ttl_seconds: int = 28800
    session_secure: bool = False
    session_samesite: str = "lax"

    # --- libcloud REST API policies (read-only, for superadmin explorer) ---
    rest_api_policies_path: str = "/opt/policies.json"

    # --- Server ---
    identity_port: int = 8766


@lru_cache
def get_settings() -> Settings:
    return Settings()
