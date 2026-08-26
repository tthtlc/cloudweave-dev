from libcloud.compute.drivers.nutanix import NutanixNodeDriver

from app.connections.models import ConnectionConfig


def create_nutanix_driver(
    key: str,
    secret: str,
    config: ConnectionConfig,
    *,
    login_path: str | None = None,
    session_cookie: str | None = None,
) -> NutanixNodeDriver:
    return NutanixNodeDriver(
        key,
        secret,
        host=config.host or "localhost",
        port=config.port or 9440,
        secure=config.secure if config.secure is not None else True,
        api_version=config.api_version or "v4.0",
        verify_ssl_cert=config.verify_ssl_cert if config.verify_ssl_cert is not None else True,
        login_path=login_path if login_path is not None else config.login_path,
        session_cookie=session_cookie if session_cookie is not None else config.session_cookie,
    )
