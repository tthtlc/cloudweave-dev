from fastapi import APIRouter, Depends, Query, Request

from app.auth.dependencies import require_any_scopes, require_scopes
from app.auth.models import TokenClaims
from app.auth.policy import policy_engine
from app.common.responses import success_response
from app.connections.dependencies import parse_connection_query
from app.connections.models import ProviderConnection
from app.network.models import (
    FloatingIPAllocateRequest,
    FloatingIPAssociateRequest,
    FloatingIPDisassociateRequest,
    LoadBalancerCreateRequest,
    NetworkCreateRequest,
    NetworkUpdateRequest,
    SecurityGroupCreateRequest,
    SubnetCreateRequest,
    SubnetUpdateRequest,
)
from app.network.service import network_service

router = APIRouter(prefix="/v1/compute", tags=["network"])


@router.get("/networks")
def list_networks(
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    network_id: str | None = Query(None, alias="id"),
    is_default: bool | None = None,
    claims: TokenClaims = Depends(require_any_scopes("compute:network:read", "compute:read")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:network:read")
    data = network_service.list_networks(
        connection, network_id=network_id, is_default=is_default
    )
    return success_response(data, request)


@router.post("/networks")
def create_network(
    body: NetworkCreateRequest,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("compute:network:manage")),
):
    connection = policy_engine.authorize_connection(claims, body.connection, "compute:network:manage")
    data = network_service.create_network(connection, body)
    return success_response(data, request)


@router.patch("/networks/{network_id}")
def update_network(
    network_id: str,
    body: NetworkUpdateRequest,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("compute:network:manage")),
):
    connection = policy_engine.authorize_connection(claims, body.connection, "compute:network:manage")
    data = network_service.update_network(connection, network_id, body)
    return success_response(data, request)


@router.delete("/networks/{network_id}")
def delete_network(
    network_id: str,
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    claims: TokenClaims = Depends(require_scopes("compute:network:manage")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:network:manage")
    data = network_service.destroy_network(connection, network_id)
    return success_response(data, request)


@router.get("/subnets")
def list_subnets(
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    subnet_id: str | None = Query(None, alias="id"),
    vpc_id: str | None = None,
    claims: TokenClaims = Depends(require_any_scopes("compute:network:read", "compute:read")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:network:read")
    data = network_service.list_subnets(connection, subnet_id=subnet_id, vpc_id=vpc_id)
    return success_response(data, request)


@router.post("/subnets")
def create_subnet(
    body: SubnetCreateRequest,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("compute:network:manage")),
):
    connection = policy_engine.authorize_connection(claims, body.connection, "compute:network:manage")
    data = network_service.create_subnet(connection, body)
    return success_response(data, request)


@router.patch("/subnets/{subnet_id}")
def update_subnet(
    subnet_id: str,
    body: SubnetUpdateRequest,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("compute:network:manage")),
):
    connection = policy_engine.authorize_connection(claims, body.connection, "compute:network:manage")
    data = network_service.update_subnet(connection, subnet_id, body)
    return success_response(data, request)


@router.delete("/subnets/{subnet_id}")
def delete_subnet(
    subnet_id: str,
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    claims: TokenClaims = Depends(require_scopes("compute:network:manage")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:network:manage")
    data = network_service.destroy_subnet(connection, subnet_id)
    return success_response(data, request)


@router.get("/storage-containers")
def list_storage_containers(
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    container_id: str | None = Query(None, alias="id"),
    claims: TokenClaims = Depends(require_any_scopes("compute:read", "compute:network:read")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:read")
    data = network_service.list_storage_containers(connection, container_id=container_id)
    return success_response(data, request)


@router.get("/security-groups")
def list_security_groups(
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    group_id: str | None = Query(None, alias="id"),
    vpc_id: str | None = None,
    claims: TokenClaims = Depends(require_any_scopes("compute:network:read", "compute:read")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:network:read")
    data = network_service.list_security_groups(
        connection, group_id=group_id, vpc_id=vpc_id
    )
    return success_response(data, request)


@router.post("/security-groups")
def create_security_group(
    body: SecurityGroupCreateRequest,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("compute:network:manage")),
):
    connection = policy_engine.authorize_connection(claims, body.connection, "compute:network:manage")
    data = network_service.create_security_group(connection, body)
    return success_response(data, request)


@router.delete("/security-groups/{group_id}")
def delete_security_group(
    group_id: str,
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    claims: TokenClaims = Depends(require_scopes("compute:network:manage")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:network:manage")
    data = network_service.destroy_security_group(connection, group_id)
    return success_response(data, request)


@router.get("/load-balancers")
def list_load_balancers(
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    lb_id: str | None = Query(None, alias="id"),
    claims: TokenClaims = Depends(require_any_scopes("compute:network:read", "compute:read")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:network:read")
    data = network_service.list_load_balancers(connection, lb_id=lb_id)
    return success_response(data, request)


@router.post("/load-balancers")
def create_load_balancer(
    body: LoadBalancerCreateRequest,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("compute:network:manage")),
):
    connection = policy_engine.authorize_connection(claims, body.connection, "compute:network:manage")
    data = network_service.create_load_balancer(connection, body)
    return success_response(data, request)


@router.delete("/load-balancers/{lb_id}")
def delete_load_balancer(
    lb_id: str,
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    claims: TokenClaims = Depends(require_scopes("compute:network:manage")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:network:manage")
    data = network_service.destroy_load_balancer(connection, lb_id)
    return success_response(data, request)


# --------------------------------------------------------------------------- #
# Floating IPs (elastic IPs)
# --------------------------------------------------------------------------- #
@router.get("/floating-ips")
def list_floating_ips(
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    address: str | None = Query(None),
    claims: TokenClaims = Depends(require_any_scopes("compute:network:read", "compute:read")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:network:read")
    data = network_service.list_floating_ips(connection, address=address)
    return success_response(data, request)


@router.post("/floating-ips")
def allocate_floating_ip(
    body: FloatingIPAllocateRequest,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("compute:network:manage")),
):
    connection = policy_engine.authorize_connection(claims, body.connection, "compute:network:manage")
    data = network_service.allocate_floating_ip(connection, body)
    return success_response(data, request)


@router.delete("/floating-ips/{address}")
def release_floating_ip(
    address: str,
    request: Request,
    domain: str | None = None,
    connection: ProviderConnection = Depends(parse_connection_query),
    claims: TokenClaims = Depends(require_scopes("compute:network:manage")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:network:manage")
    data = network_service.release_floating_ip(connection, address, domain=domain)
    return success_response(data, request)


@router.post("/floating-ips/{address}:associate")
def associate_floating_ip(
    address: str,
    body: FloatingIPAssociateRequest,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("compute:network:manage")),
):
    connection = policy_engine.authorize_connection(claims, body.connection, "compute:network:manage")
    data = network_service.associate_floating_ip(connection, address, body)
    return success_response(data, request)


@router.post("/floating-ips/{address}:disassociate")
def disassociate_floating_ip(
    address: str,
    body: FloatingIPDisassociateRequest,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("compute:network:manage")),
):
    connection = policy_engine.authorize_connection(claims, body.connection, "compute:network:manage")
    data = network_service.disassociate_floating_ip(connection, address, body)
    return success_response(data, request)
