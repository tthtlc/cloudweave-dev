from typing import Any

from libcloud.compute.base import NodeDriver

from app.config.settings import get_settings
from app.connections.credentials import effective_credentials
from app.connections.models import ConnectionCapabilities, ProviderConnection, connection_target
from app.connections.session_cache import get_session_cookie, put_session_cookie
from app.providers.aws import create_aws_driver
from app.providers.nutanix import create_nutanix_driver


def build_driver(connection: ProviderConnection) -> NodeDriver:
    if connection.provider == "nutanix":
        return _build_nutanix_driver(connection)

    creds = effective_credentials(connection)
    if connection.provider == "aws":
        return create_aws_driver(creds.key, creds.secret, connection.config)
    raise ValueError(f"Unsupported provider: {connection.provider}")


def _build_nutanix_driver(connection: ProviderConnection) -> NodeDriver:
    config = connection.config
    target = connection_target(connection)

    # Reuse an already-established session cookie (client-supplied or cached) so
    # we don't need to fetch the backend credential from Vault on every call.
    session_cookie = config.session_cookie or get_session_cookie(target)
    if session_cookie:
        return create_nutanix_driver("", "", config, session_cookie=session_cookie)

    # First auth for this target: resolve credentials (Vault), then perform the
    # one-time Basic-auth login to derive a session cookie and cache it.
    creds = effective_credentials(connection)
    login_path = config.login_path or get_settings().nutanix_login_path
    driver = create_nutanix_driver(creds.key, creds.secret, config, login_path=login_path)

    if login_path:
        # Derive the cookie eagerly (no-op if the endpoint issued none, e.g.
        # real Prism Central — the driver then falls back to Basic auth).
        driver.connection._get_auth_token()
        cookie = driver.connection.session_cookie
        if cookie:
            put_session_cookie(target, cookie)
    return driver


def probe_capabilities(driver: NodeDriver) -> ConnectionCapabilities:
    features = getattr(driver, "features", {}) or {}
    create_node_auth = features.get("create_node", [])
    if isinstance(create_node_auth, bool):
        create_node_auth = []

    supports_volumes = hasattr(driver, "create_volume") and callable(driver.create_volume)
    supports_snapshots = hasattr(driver, "create_volume_snapshot") and callable(
        driver.create_volume_snapshot
    )
    supports_key_pairs = hasattr(driver, "create_key_pair") and callable(driver.create_key_pair)
    supports_wait = hasattr(driver, "wait_until_running") and callable(driver.wait_until_running)

    return ConnectionCapabilities(
        create_node_auth=list(create_node_auth) if create_node_auth else [],
        supports_volumes=supports_volumes,
        supports_snapshots=supports_snapshots,
        supports_key_pairs=supports_key_pairs,
        supports_wait_until_running=supports_wait,
    )


def test_connection(connection: ProviderConnection) -> dict[str, Any]:
    driver = build_driver(connection)
    driver.list_locations()
    caps = probe_capabilities(driver)
    return {
        "target": connection_target(connection),
        "provider": connection.provider,
        "status": "ok",
        "capabilities": caps.model_dump(),
    }
