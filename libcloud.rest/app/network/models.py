from typing import Any, Literal

from pydantic import BaseModel, Field

from app.connections.models import ProviderConnection


class NetworkCreateRequest(BaseModel):
    connection: ProviderConnection
    name: str
    description: str | None = None
    cidr_block: str | None = None
    vpc_type: Literal["REGULAR", "TRANSIT"] = "REGULAR"
    instance_tenancy: str | None = None
    external_subnet_ids: list[str] = Field(default_factory=list)
    provider_options: dict[str, Any] = Field(default_factory=dict)


class NetworkUpdateRequest(BaseModel):
    connection: ProviderConnection
    name: str | None = None
    description: str | None = None
    tag_key: str | None = None
    tag_value: str | None = None


class SubnetCreateRequest(BaseModel):
    connection: ProviderConnection
    name: str
    subnet_type: Literal["VLAN", "OVERLAY"] = "VLAN"
    vpc_id: str | None = None
    cluster_id: str | None = None
    network_id: int | None = None
    cidr_block: str | None = None
    availability_zone: str | None = None
    description: str | None = None
    is_external: bool = False
    ip_address: str | None = None
    prefix_length: int | None = None
    gateway_ip: str | None = None
    provider_options: dict[str, Any] = Field(default_factory=dict)


class SubnetUpdateRequest(BaseModel):
    connection: ProviderConnection
    action: Literal["update", "nat", "auto_public_ip", "auto_ipv6", "tag"] = "update"
    name: str | None = None
    description: str | None = None
    nat_enabled: bool | None = None
    value: bool | None = None
    tag_key: str | None = None
    tag_value: str | None = None


class SecurityGroupCreateRequest(BaseModel):
    connection: ProviderConnection
    name: str
    description: str | None = None
    vpc_id: str | None = None


class LoadBalancerCreateRequest(BaseModel):
    connection: ProviderConnection
    name: str
    vpc_id: str
    external_ip: str | None = None


class FloatingIPAllocateRequest(BaseModel):
    connection: ProviderConnection
    # EC2 address domain: "vpc" (default) or "standard" (EC2-Classic).
    domain: str = "vpc"


class FloatingIPAssociateRequest(BaseModel):
    connection: ProviderConnection
    node_id: str
    domain: str | None = None


class FloatingIPDisassociateRequest(BaseModel):
    connection: ProviderConnection
    domain: str | None = None
