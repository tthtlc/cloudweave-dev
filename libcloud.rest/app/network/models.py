from typing import Any, Literal

from pydantic import BaseModel, Field


class NetworkCreateRequest(BaseModel):
    name: str
    description: str | None = None
    cidr_block: str | None = None
    vpc_type: Literal["REGULAR", "TRANSIT"] = "REGULAR"
    instance_tenancy: str | None = None
    external_subnet_ids: list[str] = Field(default_factory=list)
    provider_options: dict[str, Any] = Field(default_factory=dict)


class NetworkUpdateRequest(BaseModel):
    name: str | None = None
    description: str | None = None
    tag_key: str | None = None
    tag_value: str | None = None


class SubnetCreateRequest(BaseModel):
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
    dhcp_server: str | None = None
    # Nutanix IPAM pools, e.g. ["10.1.200.10-10.1.200.50"]; require ip_address
    # and prefix_length.
    ip_pool: list[str] = Field(default_factory=list)
    provider_options: dict[str, Any] = Field(default_factory=dict)


class SubnetUpdateRequest(BaseModel):
    action: Literal["update", "nat", "auto_public_ip", "auto_ipv6", "tag"] = "update"
    name: str | None = None
    description: str | None = None
    nat_enabled: bool | None = None
    value: bool | None = None
    tag_key: str | None = None
    tag_value: str | None = None


class SecurityGroupCreateRequest(BaseModel):
    name: str
    description: str | None = None
    vpc_id: str | None = None


class SecurityGroupRuleAuthorizeRequest(BaseModel):
    # Authorize one ingress/egress rule on an existing security group (AWS).
    # Traffic source is EITHER a list of CIDR blocks (cidr_ips) OR another
    # security group (source_group_id -> group_pairs), mirroring
    # ex_authorize_security_group_ingress/egress in the EC2 driver.
    direction: Literal["ingress", "egress"] = "ingress"
    protocol: str = "tcp"
    from_port: int
    to_port: int
    cidr_ips: list[str] = Field(default_factory=list)
    source_group_id: str | None = None
    description: str | None = None


class InternetGatewayCreateRequest(BaseModel):
    # Creates an IGW and attaches it to vpc_id (AWS). Both steps in one call so
    # a client never sees a dangling, unattached gateway.
    vpc_id: str
    name: str | None = None


class RouteTableCreateRequest(BaseModel):
    vpc_id: str
    name: str | None = None


class RouteCreateRequest(BaseModel):
    # destination CIDR + exactly one target. Only internet_gateway_id is
    # supported today (the bastion/public-subnet scenario); the EC2 driver
    # also accepts node / network_interface / vpc_peering_connection.
    cidr_block: str
    internet_gateway_id: str | None = None


class RouteTableAssociateRequest(BaseModel):
    subnet_id: str


class LoadBalancerCreateRequest(BaseModel):
    name: str
    vpc_id: str
    external_ip: str | None = None


class FloatingIPAllocateRequest(BaseModel):
    # EC2 address domain: "vpc" (default) or "standard" (EC2-Classic).
    domain: str = "vpc"


class FloatingIPAssociateRequest(BaseModel):
    node_id: str
    domain: str | None = None


class FloatingIPDisassociateRequest(BaseModel):
    domain: str | None = None
