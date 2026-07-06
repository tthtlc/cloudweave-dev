from libcloud.compute.providers import get_driver
from libcloud.compute.types import Provider

from app.connections.models import ConnectionConfig


def create_aws_driver(key: str, secret: str, config: ConnectionConfig):
    cls = get_driver(Provider.EC2)
    kwargs: dict = {"region": config.region or "us-east-1"}
    if config.secure is not None:
        kwargs["secure"] = config.secure
    return cls(key, secret, **kwargs)
