# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with this
# work for additional information regarding copyright ownership.
"""
Nutanix Objects (S3-compatible) storage driver.

Nutanix Objects exposes an S3-compatible API. This driver subclasses the
libcloud S3 driver and only overrides the service identity (name/type) and the
default endpoint, so all S3 bucket/object operations (list_containers,
create_container, delete_container, list_container_objects, upload_object,
download_object, delete_object) work unchanged against a Nutanix Objects
endpoint.

The endpoint host is supplied via the constructor ``host`` argument (resolved by
the libcloud REST API from the connection config). When ``secure=False`` the
driver talks plain HTTP (useful for a dev/mock endpoint).
"""

from libcloud.storage.drivers.s3 import BaseS3StorageDriver

__all__ = ["NutanixObjectsStorageDriver"]


class NutanixObjectsStorageDriver(BaseS3StorageDriver):
    """S3-compatible driver for Nutanix Objects."""

    name = "Nutanix Objects"
    website = "https://www.nutanix.com/products/objects"
    connection_name = "nutanix.objects"
    # Default endpoint; overridden by the ``host`` constructor argument.
    host = "objects.nutanix.com"
    region_name = "nutanix"
    # Nutanix Objects supports both virtual-host and path-style; path-style is
    # the safe default for custom endpoints / mock servers.
    path_style = True

    def __init__(self, key, secret, secure=True, host=None, port=None, **kwargs):
        host = host or self.host
        port = port or (443 if secure else 80)
        # BaseS3StorageDriver.__init__ forces SigV4; Nutanix Objects accepts
        # SigV4. The base signature is (user_id, key, secure, host, port, url,
        # timeout, proxy_url, token, retry_delay, backoff).
        super().__init__(key, secret, secure, host, port)
