from libcloud.compute.drivers.nutanix import NutanixNodeDriver

from app.connections.models import ConnectionConfig


def create_nutanix_driver(key: str, secret: str, config: ConnectionConfig) -> NutanixNodeDriver:
    return NutanixNodeDriver(
        key,
        secret,
        host=config.host or "localhost",
        port=config.port or 9440,
        secure=config.secure if config.secure is not None else True,
        api_version=config.api_version or "v4.0",
        verify_ssl_cert=config.verify_ssl_cert if config.verify_ssl_cert is not None else True,
    )
