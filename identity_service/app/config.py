from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from dotenv import load_dotenv
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
    dex_base_url: str = "http://dex:5556/dex"
    dex_token_url: str = "http://dex:5556/dex/token"
    dex_jwks_url: str = "http://dex:5556/dex/keys"
    dex_issuer: str = "http://dex:5556/dex"
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
    lldap_bind_dn: str = ""
    lldap_bind_pw: str = ""
    lldap_base_dn: str = "ou=people,dc=libcloud,dc=local"

    # --- libcloud REST API (cloud orchestration) ---
    libcloud_rest_url: str = "http://libcloud-rest-api:8765"

    # --- Session cookie ---
    session_secret: str = "change-me"
    session_cookie_name: str = "libcloud_portal_sid"
    session_ttl_seconds: int = 28800
    session_secure: bool = False
    session_samesite: str = "lax"

    # --- Server ---
    identity_port: int = 8766


@lru_cache
def get_settings() -> Settings:
    return Settings()
