from fastapi import Query, Request

from app.auth.authorized_route import make_authorized_router
from app.common.responses import success_response
from app.network.models import (
    FloatingIPAllocateRequest,
    FloatingIPAssociateRequest,
    FloatingIPDisassociateRequest,
    InternetGatewayCreateRequest,
    LoadBalancerCreateRequest,
    NetworkCreateRequest,
    NetworkUpdateRequest,
    RouteCreateRequest,
    RouteTableAssociateRequest,
    RouteTableCreateRequest,
    SecurityGroupCreateRequest,
    SecurityGroupRuleAuthorizeRequest,
    SubnetCreateRequest,
    SubnetUpdateRequest,
)
from app.network.service import network_service

router = make_authorized_router(prefix="/v1/compute", tags=["network"])


@router.get("/networks")
def list_networks(
    request: Request,
    network_id: str | None = Query(None, alias="id"),
    is_default: bool | None = None,
):
    connection = request.state.connection
    data = network_service.list_networks(
        connection, network_id=network_id, is_default=is_default
    )
    return success_response(data, request)


@router.post("/networks")
def create_network(body: NetworkCreateRequest, request: Request):
    connection = request.state.connection
    data = network_service.create_network(connection, body)
    return success_response(data, request)


@router.patch("/networks/{network_id}")
def update_network(network_id: str, body: NetworkUpdateRequest, request: Request):
    connection = request.state.connection
    data = network_service.update_network(connection, network_id, body)
    return success_response(data, request)


@router.delete("/networks/{network_id}")
def delete_network(network_id: str, request: Request):
    connection = request.state.connection
    data = network_service.destroy_network(connection, network_id)
    return success_response(data, request)


@router.get("/subnets")
def list_subnets(
    request: Request,
    subnet_id: str | None = Query(None, alias="id"),
    vpc_id: str | None = None,
):
    connection = request.state.connection
    data = network_service.list_subnets(connection, subnet_id=subnet_id, vpc_id=vpc_id)
    return success_response(data, request)


@router.post("/subnets")
def create_subnet(body: SubnetCreateRequest, request: Request):
    connection = request.state.connection
    data = network_service.create_subnet(connection, body)
    return success_response(data, request)


@router.patch("/subnets/{subnet_id}")
def update_subnet(subnet_id: str, body: SubnetUpdateRequest, request: Request):
    connection = request.state.connection
    data = network_service.update_subnet(connection, subnet_id, body)
    return success_response(data, request)


@router.delete("/subnets/{subnet_id}")
def delete_subnet(subnet_id: str, request: Request):
    connection = request.state.connection
    data = network_service.destroy_subnet(connection, subnet_id)
    return success_response(data, request)


@router.get("/storage-containers")
def list_storage_containers(
    request: Request,
    container_id: str | None = Query(None, alias="id"),
):
    connection = request.state.connection
    data = network_service.list_storage_containers(connection, container_id=container_id)
    return success_response(data, request)


@router.get("/security-groups")
def list_security_groups(
    request: Request,
    group_id: str | None = Query(None, alias="id"),
    vpc_id: str | None = None,
):
    connection = request.state.connection
    data = network_service.list_security_groups(connection, group_id=group_id, vpc_id=vpc_id)
    return success_response(data, request)


@router.post("/security-groups")
def create_security_group(body: SecurityGroupCreateRequest, request: Request):
    connection = request.state.connection
    data = network_service.create_security_group(connection, body)
    return success_response(data, request)


@router.delete("/security-groups/{group_id}")
def delete_security_group(group_id: str, request: Request):
    connection = request.state.connection
    data = network_service.destroy_security_group(connection, group_id)
    return success_response(data, request)


@router.post("/security-groups/{group_id}:authorize")
def authorize_security_group_rule(
    group_id: str, body: SecurityGroupRuleAuthorizeRequest, request: Request
):
    connection = request.state.connection
    data = network_service.authorize_security_group_rule(connection, group_id, body)
    return success_response(data, request)


@router.get("/load-balancers")
def list_load_balancers(
    request: Request,
    lb_id: str | None = Query(None, alias="id"),
):
    connection = request.state.connection
    data = network_service.list_load_balancers(connection, lb_id=lb_id)
    return success_response(data, request)


@router.post("/load-balancers")
def create_load_balancer(body: LoadBalancerCreateRequest, request: Request):
    connection = request.state.connection
    data = network_service.create_load_balancer(connection, body)
    return success_response(data, request)


@router.delete("/load-balancers/{lb_id}")
def delete_load_balancer(lb_id: str, request: Request):
    connection = request.state.connection
    data = network_service.destroy_load_balancer(connection, lb_id)
    return success_response(data, request)


# --------------------------------------------------------------------------- #
# Floating IPs (elastic IPs)
# --------------------------------------------------------------------------- #
@router.get("/floating-ips")
def list_floating_ips(
    request: Request,
    address: str | None = Query(None),
):
    connection = request.state.connection
    data = network_service.list_floating_ips(connection, address=address)
    return success_response(data, request)


@router.post("/floating-ips")
def allocate_floating_ip(body: FloatingIPAllocateRequest, request: Request):
    connection = request.state.connection
    data = network_service.allocate_floating_ip(connection, body)
    return success_response(data, request)


@router.delete("/floating-ips/{address}")
def release_floating_ip(
    address: str,
    request: Request,
    domain: str | None = None,
):
    connection = request.state.connection
    data = network_service.release_floating_ip(connection, address, domain=domain)
    return success_response(data, request)


@router.post("/floating-ips/{address}:associate")
def associate_floating_ip(address: str, body: FloatingIPAssociateRequest, request: Request):
    connection = request.state.connection
    data = network_service.associate_floating_ip(connection, address, body)
    return success_response(data, request)


@router.post("/floating-ips/{address}:disassociate")
def disassociate_floating_ip(address: str, body: FloatingIPDisassociateRequest, request: Request):
    connection = request.state.connection
    data = network_service.disassociate_floating_ip(connection, address, body)
    return success_response(data, request)


# --------------------------------------------------------------------------- #
# Internet gateways (AWS)
# --------------------------------------------------------------------------- #
@router.get("/internet-gateways")
def list_internet_gateways(
    request: Request,
    gateway_id: str | None = Query(None, alias="id"),
    vpc_id: str | None = None,
):
    connection = request.state.connection
    data = network_service.list_internet_gateways(connection, gateway_id=gateway_id, vpc_id=vpc_id)
    return success_response(data, request)


@router.post("/internet-gateways")
def create_internet_gateway(body: InternetGatewayCreateRequest, request: Request):
    connection = request.state.connection
    data = network_service.create_internet_gateway(connection, body)
    return success_response(data, request)


# --------------------------------------------------------------------------- #
# Route tables (AWS)
# --------------------------------------------------------------------------- #
@router.get("/route-tables")
def list_route_tables(
    request: Request,
    route_table_id: str | None = Query(None, alias="id"),
    vpc_id: str | None = None,
):
    connection = request.state.connection
    data = network_service.list_route_tables(connection, route_table_id=route_table_id, vpc_id=vpc_id)
    return success_response(data, request)


@router.post("/route-tables")
def create_route_table(body: RouteTableCreateRequest, request: Request):
    connection = request.state.connection
    data = network_service.create_route_table(connection, body)
    return success_response(data, request)


@router.post("/route-tables/{route_table_id}/routes")
def create_route(route_table_id: str, body: RouteCreateRequest, request: Request):
    connection = request.state.connection
    data = network_service.create_route(connection, route_table_id, body)
    return success_response(data, request)


@router.post("/route-tables/{route_table_id}:associate")
def associate_route_table(route_table_id: str, body: RouteTableAssociateRequest, request: Request):
    connection = request.state.connection
    data = network_service.associate_route_table(connection, route_table_id, body)
    return success_response(data, request)


# --------------------------------------------------------------------------- #
# Network interfaces (AWS ENIs)
# --------------------------------------------------------------------------- #
@router.get("/network-interfaces")
def list_network_interfaces(
    request: Request,
    interface_id: str | None = Query(None, alias="id"),
):
    connection = request.state.connection
    data = network_service.list_network_interfaces(connection, interface_id=interface_id)
    return success_response(data, request)