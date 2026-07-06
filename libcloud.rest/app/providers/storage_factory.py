"""Storage driver factory for the libcloud REST API.

Mirrors app/providers/factory.py but builds libcloud *storage* drivers from a
ProviderConnection. Backend credentials are resolved server-side from Vault
(via effective_credentials), exactly like the compute path.

  * aws     -> libcloud S3 driver (region from connection.config.region)
  * nutanix -> NutanixObjectsStorageDriver (S3-compatible; endpoint from
               connection.config.host) — requires a Nutanix Objects endpoint
               configured for the tenant.
"""
from __future__ import annotations

from libcloud.storage.drivers.s3 import S3StorageDriver, S3USEast2StorageDriver  # noqa: F401
from libcloud.storage.drivers.nutanix import NutanixObjectsStorageDriver

from app.common.errors import APIError
from app.connections.credentials import effective_credentials
from app.connections.models import ProviderConnection

# Map AWS region -> libcloud S3 driver class (so buckets land in the right
# region). Falls back to the generic S3StorageDriver for unmapped regions.
_AWS_REGION_DRIVERS = {
    "us-east-1": S3StorageDriver,
    "us-east-2": S3USEast2StorageDriver,
}


def build_storage_driver(connection: ProviderConnection):
    creds = effective_credentials(connection)
    provider = connection.provider
    if provider == "aws":
        region = connection.config.region or "us-east-1"
        cls = _AWS_REGION_DRIVERS.get(region, S3StorageDriver)
        secure = connection.config.secure if connection.config.secure is not None else True
        return cls(creds.key, creds.secret, secure=secure)
    if provider == "nutanix":
        # The standard Nutanix connection targets Prism Element (the compute
        # API), NOT a Nutanix Objects (S3-compatible) endpoint. Reusing that
        # host for object storage would point the S3 driver at the wrong
        # service. A dedicated Nutanix Objects endpoint is required; until the
        # connection model exposes one, object storage is reported unsupported
        # for the Nutanix tenant. (The NutanixObjectsStorageDriver is available
        # for a future dedicated Objects connection.)
        host = connection.config.host
        port = connection.config.port
        # Only proceed if a non-Prism Objects endpoint is explicitly supplied.
        # Prism uses port 9440 with TLS; treat that combination as "not Objects".
        is_prism = host and (port in (None, 9440, 9443))
        if is_prism:
            raise APIError(
                code="provider_capability_unsupported",
                message=(
                    "Nutanix object storage requires a dedicated Nutanix Objects "
                    "(S3-compatible) endpoint; the tenant's Prism connection "
                    "(host/port) is not an Objects endpoint. Configure a Nutanix "
                    "Objects endpoint for the tenant to enable bucket/object ops."
                ),
                status_code=501,
            )
        if not host:
            raise APIError(
                code="provider_capability_unsupported",
                message="Nutanix object storage endpoint not configured.",
                status_code=501,
            )
        secure = connection.config.secure if connection.config.secure is not None else True
        return NutanixObjectsStorageDriver(
            creds.key, creds.secret, secure=secure, host=host, port=port,
        )
    raise APIError(
        code="provider_capability_unsupported",
        message=f"Object storage not supported for provider '{provider}'",
        status_code=501,
    )
