from __future__ import annotations

from typing import Any

from app.common.errors import APIError
from app.connections.models import ProviderConnection, connection_target
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
from app.providers.factory import build_driver


def _unsupported(connection: ProviderConnection, feature: str) -> "APIError":
    return APIError(
        code="provider_capability_unsupported",
        message=f"Provider '{connection.provider}' does not support {feature}",
        status_code=501,
    )


def _resource_id(obj: Any) -> str:
    if isinstance(obj, dict):
        return obj.get("extId") or obj.get("ext_id") or obj.get("id") or ""
    return getattr(obj, "id", "") or ""


def _resource_name(obj: Any) -> str | None:
    if isinstance(obj, dict):
        return obj.get("name") or _resource_id(obj) or None
    return getattr(obj, "name", None)


def _extra(obj: Any) -> dict[str, Any]:
    if isinstance(obj, dict):
        return dict(obj)
    return dict(getattr(obj, "extra", None) or {})


def _serialize_network(obj: Any, connection: ProviderConnection) -> dict[str, Any]:
    extra = _extra(obj)
    return {
        "id": _resource_id(obj),
        "name": _resource_name(obj),
        "cidr_block": extra.get("cidr_block") or extra.get("cidrBlock"),
        "state": extra.get("state"),
        "provider": connection.provider,
        "target": connection_target(connection),
        "extra": extra,
    }


def _serialize_subnet(obj: Any, connection: ProviderConnection) -> dict[str, Any]:
    extra = _extra(obj)
    return {
        "id": _resource_id(obj),
        "name": _resource_name(obj),
        "cidr_block": extra.get("cidr_block") or extra.get("cidrBlock"),
        "vpc_id": extra.get("vpc_id") or extra.get("vpcReference") or extra.get("vpc_reference"),
        "availability_zone": extra.get("availability_zone"),
        "provider": connection.provider,
        "target": connection_target(connection),
        "extra": extra,
    }


class NetworkService:
    def list_networks(
        self,
        connection: ProviderConnection,
        network_id: str | None = None,
        is_default: bool | None = None,
    ) -> list[dict[str, Any]]:
        driver = build_driver(connection)
        if network_id:
            if connection.provider == "nutanix" and hasattr(driver, "ex_get_vpc"):
                return [_serialize_network(driver.ex_get_vpc(network_id), connection)]
            if hasattr(driver, "ex_list_networks"):
                networks = driver.ex_list_networks(network_ids=[network_id])
                return [_serialize_network(n, connection) for n in networks]
            raise APIError(
                code="provider_capability_unsupported",
                message="Provider does not support network lookup",
                status_code=400,
            )
        if connection.provider == "nutanix" and hasattr(driver, "ex_list_vpcs"):
            networks = driver.ex_list_vpcs()
        elif hasattr(driver, "ex_list_networks"):
            filters = {"is-default": "true"} if is_default else None
            networks = driver.ex_list_networks(filters=filters) if filters else driver.ex_list_networks()
        else:
            raise APIError(
                code="provider_capability_unsupported",
                message="Provider does not support network listing",
                status_code=400,
            )
        results = [_serialize_network(n, connection) for n in networks]
        if is_default is not None and connection.provider == "aws":
            want = "true" if is_default else "false"
            results = [
                n
                for n in results
                if str(n.get("extra", {}).get("is_default", "")).lower() == want
            ]
        return results

    def create_network(
        self, connection: ProviderConnection, request: NetworkCreateRequest
    ) -> dict[str, Any]:
        driver = build_driver(connection)
        try:
            if connection.provider == "nutanix":
                if not hasattr(driver, "ex_create_vpc"):
                    raise APIError(
                        code="provider_capability_unsupported",
                        message="Nutanix VPC creation not supported",
                        status_code=400,
                    )
                obj = driver.ex_create_vpc(
                    name=request.name,
                    description=request.description,
                    vpc_type=request.vpc_type,
                    external_subnet_ext_ids=request.external_subnet_ids or None,
                )
            else:
                if not hasattr(driver, "ex_create_network"):
                    raise APIError(
                        code="provider_capability_unsupported",
                        message="AWS VPC creation not supported",
                        status_code=400,
                    )
                if not request.cidr_block:
                    raise APIError(
                        code="validation_error",
                        message="cidr_block is required for AWS VPC",
                        status_code=400,
                    )
                obj = driver.ex_create_network(
                    name=request.name,
                    cidr_block=request.cidr_block,
                    instance_tenancy=request.instance_tenancy or "default",
                )
        except APIError:
            raise
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to create network",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc
        return _serialize_network(obj, connection)

    def update_network(
        self, connection: ProviderConnection, network_id: str, request: NetworkUpdateRequest
    ) -> dict[str, Any]:
        driver = build_driver(connection)
        try:
            if request.tag_key and request.tag_value is not None:
                if not hasattr(driver, "ex_create_tags"):
                    raise APIError(
                        code="provider_capability_unsupported",
                        message="Tagging not supported",
                        status_code=400,
                    )
                if connection.provider == "nutanix":
                    obj = driver.ex_get_vpc(network_id)
                else:
                    obj = driver.ex_list_networks(network_ids=[network_id])[0]
                driver.ex_create_tags(obj, {request.tag_key: request.tag_value})
                return {"id": network_id, "action": "tag", "success": True}
            if connection.provider == "nutanix" and hasattr(driver, "ex_update_vpc"):
                obj = driver.ex_update_vpc(
                    network_id,
                    name=request.name,
                    description=request.description,
                )
                return _serialize_network(obj, connection)
            raise APIError(
                code="provider_capability_unsupported",
                message="Network update not supported",
                status_code=400,
            )
        except APIError:
            raise
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to update network",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc

    def destroy_network(self, connection: ProviderConnection, network_id: str) -> dict:
        driver = build_driver(connection)
        try:
            if connection.provider == "nutanix" and hasattr(driver, "ex_delete_vpc"):
                driver.ex_delete_vpc(network_id)
            elif hasattr(driver, "ex_delete_network"):
                networks = driver.ex_list_networks(network_ids=[network_id])
                if not networks:
                    raise APIError(
                        code="resource_not_found",
                        message="Network not found",
                        status_code=404,
                    )
                driver.ex_delete_network(networks[0])
            else:
                raise APIError(
                    code="provider_capability_unsupported",
                    message="Network deletion not supported",
                    status_code=400,
                )
        except APIError:
            raise
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to delete network",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc
        return {"id": network_id, "destroyed": True}

    def list_subnets(
        self,
        connection: ProviderConnection,
        subnet_id: str | None = None,
        vpc_id: str | None = None,
    ) -> list[dict[str, Any]]:
        driver = build_driver(connection)
        if subnet_id:
            if hasattr(driver, "ex_get_subnet"):
                return [_serialize_subnet(driver.ex_get_subnet(subnet_id), connection)]
            subnets = driver.ex_list_subnets(subnet_ids=[subnet_id])
            return [_serialize_subnet(s, connection) for s in subnets]
        subnets = driver.ex_list_subnets()
        results = [_serialize_subnet(s, connection) for s in subnets]
        if vpc_id:
            results = [
                s
                for s in results
                if s.get("vpc_id") == vpc_id or s["extra"].get("vpcReference") == vpc_id
            ]
        return results

    def create_subnet(
        self, connection: ProviderConnection, request: SubnetCreateRequest
    ) -> dict[str, Any]:
        driver = build_driver(connection)
        try:
            if connection.provider == "nutanix" and hasattr(driver, "ex_create_subnet"):
                obj = driver.ex_create_subnet(
                    name=request.name,
                    subnet_type=request.subnet_type,
                    cluster_ext_id=request.cluster_id,
                    vpc_ext_id=request.vpc_id,
                    network_id=request.network_id,
                    description=request.description,
                    is_external=request.is_external,
                    ip_address=request.ip_address,
                    prefix_length=request.prefix_length,
                    gateway_ip=request.gateway_ip,
                )
            elif hasattr(driver, "ex_create_subnet"):
                if not all([request.vpc_id, request.cidr_block, request.availability_zone]):
                    raise APIError(
                        code="validation_error",
                        message="vpc_id, cidr_block, and availability_zone required for AWS subnet",
                        status_code=400,
                    )
                obj = driver.ex_create_subnet(
                    name=request.name,
                    vpc_id=request.vpc_id,
                    cidr_block=request.cidr_block,
                    availability_zone=request.availability_zone,
                )
            else:
                raise APIError(
                    code="provider_capability_unsupported",
                    message="Subnet creation not supported",
                    status_code=400,
                )
        except APIError:
            raise
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to create subnet",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc
        return _serialize_subnet(obj, connection)

    def update_subnet(
        self, connection: ProviderConnection, subnet_id: str, request: SubnetUpdateRequest
    ) -> dict[str, Any]:
        driver = build_driver(connection)
        try:
            if request.action == "tag" and request.tag_key and request.tag_value is not None:
                subnet = driver.ex_get_subnet(subnet_id) if hasattr(driver, "ex_get_subnet") else None
                if not subnet:
                    subnets = driver.ex_list_subnets(subnet_ids=[subnet_id])
                    subnet = subnets[0] if subnets else None
                if not subnet:
                    raise APIError(code="resource_not_found", message="Subnet not found", status_code=404)
                driver.ex_create_tags(subnet, {request.tag_key: request.tag_value})
                return {"id": subnet_id, "action": "tag", "success": True}
            if connection.provider == "nutanix":
                if request.action == "nat":
                    driver.ex_update_subnet(subnet_id, is_nat_enabled=request.nat_enabled)
                    return {"id": subnet_id, "action": "nat", "success": True}
                obj = driver.ex_update_subnet(
                    subnet_id,
                    name=request.name,
                    description=request.description,
                )
                return _serialize_subnet(obj, connection)
            if request.action in ("auto_public_ip", "auto_ipv6"):
                attr = (
                    "mapPublicIpOnLaunch"
                    if request.action == "auto_public_ip"
                    else "assignIpv6AddressOnCreation"
                )
                driver.ex_modify_subnet_attribute(
                    subnet_id,
                    attribute=attr,
                    value=bool(request.value),
                )
                return {"id": subnet_id, "action": request.action, "success": True}
            raise APIError(
                code="provider_capability_unsupported",
                message="Subnet update not supported",
                status_code=400,
            )
        except APIError:
            raise
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to update subnet",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc

    def destroy_subnet(self, connection: ProviderConnection, subnet_id: str) -> dict:
        driver = build_driver(connection)
        try:
            if hasattr(driver, "ex_delete_subnet"):
                driver.ex_delete_subnet(subnet_id)
            else:
                raise APIError(
                    code="provider_capability_unsupported",
                    message="Subnet deletion not supported",
                    status_code=400,
                )
        except APIError:
            raise
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to delete subnet",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc
        return {"id": subnet_id, "destroyed": True}

    def list_storage_containers(
        self, connection: ProviderConnection, container_id: str | None = None
    ) -> list[dict[str, Any]]:
        if connection.provider != "nutanix":
            raise APIError(
                code="provider_capability_unsupported",
                message="Storage containers are Nutanix-only",
                status_code=400,
            )
        driver = build_driver(connection)
        if container_id:
            if hasattr(driver, "ex_get_storage_container_vmm"):
                try:
                    obj = driver.ex_get_storage_container_vmm(container_id)
                    return [self._serialize_storage(obj, connection)]
                except Exception:
                    pass
            if hasattr(driver, "ex_get_storage_container"):
                return [self._serialize_storage(driver.ex_get_storage_container(container_id), connection)]
        containers = []
        if hasattr(driver, "ex_list_storage_containers_vmm"):
            try:
                containers = driver.ex_list_storage_containers_vmm()
            except Exception:
                containers = []
        if not containers and hasattr(driver, "ex_list_storage_containers"):
            containers = driver.ex_list_storage_containers()
        return [self._serialize_storage(c, connection) for c in containers]

    def _serialize_storage(self, obj: Any, connection: ProviderConnection) -> dict[str, Any]:
        extra = _extra(obj)
        return {
            "id": _resource_id(obj),
            "name": _resource_name(obj),
            "provider": connection.provider,
            "target": connection_target(connection),
            "extra": extra,
        }

    def list_security_groups(
        self,
        connection: ProviderConnection,
        group_id: str | None = None,
        vpc_id: str | None = None,
    ) -> list[dict[str, Any]]:
        driver = build_driver(connection)
        if group_id and hasattr(driver, "ex_get_security_group"):
            return [self._serialize_sg(driver.ex_get_security_group(group_id), connection)]
        if connection.provider == "aws" and hasattr(driver, "ex_get_security_groups"):
            filters = {"vpc-id": vpc_id} if vpc_id else None
            if group_id:
                groups = driver.ex_get_security_groups(group_ids=[group_id], filters=filters)
            else:
                groups = driver.ex_get_security_groups(filters=filters)
            return [self._serialize_sg(g, connection) for g in groups]
        if not hasattr(driver, "ex_list_security_groups"):
            raise APIError(
                code="provider_capability_unsupported",
                message="Security groups not supported",
                status_code=400,
            )
        groups = driver.ex_list_security_groups()
        if group_id:
            groups = [g for g in groups if _resource_id(g) == group_id]
        if vpc_id:
            groups = [
                g
                for g in groups
                if _extra(g).get("vpc_id") == vpc_id
                or _extra(g).get("vpcReference") == vpc_id
            ]
        return [self._serialize_sg(g, connection) for g in groups]

    def create_security_group(
        self, connection: ProviderConnection, request: SecurityGroupCreateRequest
    ) -> dict[str, Any]:
        driver = build_driver(connection)
        if not hasattr(driver, "ex_create_security_group"):
            raise APIError(
                code="provider_capability_unsupported",
                message="Security group creation not supported",
                status_code=400,
            )
        try:
            if connection.provider == "nutanix":
                obj = driver.ex_create_security_group(
                    name=request.name,
                    description=request.description,
                    vpc_ext_id=request.vpc_id,
                )
            else:
                obj = driver.ex_create_security_group(
                    name=request.name,
                    description=request.description or request.name,
                    vpc_id=request.vpc_id,
                )
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to create security group",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc
        return self._serialize_sg(obj, connection)

    def destroy_security_group(self, connection: ProviderConnection, group_id: str) -> dict:
        driver = build_driver(connection)
        if not hasattr(driver, "ex_delete_security_group"):
            raise APIError(
                code="provider_capability_unsupported",
                message="Security group deletion not supported",
                status_code=400,
            )
        try:
            if connection.provider == "aws" and hasattr(driver, "ex_delete_security_group_by_id"):
                driver.ex_delete_security_group_by_id(group_id)
            else:
                driver.ex_delete_security_group(group_id)
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to delete security group",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc
        return {"id": group_id, "destroyed": True}

    def _serialize_sg(self, obj: Any, connection: ProviderConnection) -> dict[str, Any]:
        extra = _extra(obj)
        sg_id = _resource_id(obj)
        if not sg_id and isinstance(obj, dict):
            sg_id = obj.get("group_id") or obj.get("groupId") or ""
        return {
            "id": sg_id,
            "name": _resource_name(obj),
            "provider": connection.provider,
            "target": connection_target(connection),
            "extra": extra,
        }

    def list_load_balancers(
        self, connection: ProviderConnection, lb_id: str | None = None
    ) -> list[dict[str, Any]]:
        driver = build_driver(connection)
        if not hasattr(driver, "ex_list_load_balancers"):
            raise APIError(
                code="provider_capability_unsupported",
                message="Load balancers not supported",
                status_code=400,
            )
        if lb_id and hasattr(driver, "ex_get_load_balancer"):
            return [self._serialize_lb(driver.ex_get_load_balancer(lb_id), connection)]
        lbs = driver.ex_list_load_balancers()
        if lb_id:
            lbs = [lb for lb in lbs if lb.id == lb_id]
        return [self._serialize_lb(lb, connection) for lb in lbs]

    def create_load_balancer(
        self, connection: ProviderConnection, request: LoadBalancerCreateRequest
    ) -> dict[str, Any]:
        driver = build_driver(connection)
        if not hasattr(driver, "ex_create_load_balancer"):
            raise APIError(
                code="provider_capability_unsupported",
                message="Load balancer creation not supported",
                status_code=400,
            )
        try:
            obj = driver.ex_create_load_balancer(
                name=request.name,
                vpc_ext_id=request.vpc_id,
                external_ip=request.external_ip,
            )
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to create load balancer",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc
        return self._serialize_lb(obj, connection)

    def destroy_load_balancer(self, connection: ProviderConnection, lb_id: str) -> dict:
        driver = build_driver(connection)
        if not hasattr(driver, "ex_delete_load_balancer"):
            raise APIError(
                code="provider_capability_unsupported",
                message="Load balancer deletion not supported",
                status_code=400,
            )
        try:
            driver.ex_delete_load_balancer(lb_id)
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to delete load balancer",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc
        return {"id": lb_id, "destroyed": True}

    def _serialize_lb(self, obj: Any, connection: ProviderConnection) -> dict[str, Any]:
        extra = _extra(obj)
        return {
            "id": _resource_id(obj),
            "name": _resource_name(obj),
            "provider": connection.provider,
            "target": connection_target(connection),
            "extra": extra,
        }

    # ------------------------------------------------------------------ #
    # Floating IPs (AWS elastic IPs; Nutanix unsupported by the libcloud
    # driver -> 501).
    # ------------------------------------------------------------------ #
    def _serialize_floating_ip(self, ip: Any, connection: ProviderConnection) -> dict[str, Any]:
        return {
            "address": getattr(ip, "ip", "") or "",
            "id": getattr(ip, "ip", "") or "",
            "domain": getattr(ip, "domain", None),
            "instance_id": getattr(ip, "instance_id", None),
            "associated": bool(getattr(ip, "instance_id", None)),
            "provider": connection.provider,
            "target": connection_target(connection),
            "extra": dict(getattr(ip, "extra", None) or {}),
        }

    def list_floating_ips(
        self, connection: ProviderConnection, address: str | None = None
    ) -> list[dict[str, Any]]:
        driver = build_driver(connection)
        if not hasattr(driver, "ex_describe_all_addresses"):
            raise _unsupported(connection, "floating IPs")
        try:
            ips = driver.ex_describe_all_addresses()
        except Exception as exc:
            raise APIError("provider_operation_failed", "Failed to list floating IPs",
                           502, {"reason": str(exc)}) from exc
        if address:
            ips = [ip for ip in ips if getattr(ip, "ip", "") == address]
        return [self._serialize_floating_ip(ip, connection) for ip in ips]

    def allocate_floating_ip(
        self, connection: ProviderConnection, request: FloatingIPAllocateRequest
    ) -> dict[str, Any]:
        driver = build_driver(connection)
        if not hasattr(driver, "ex_allocate_address"):
            raise _unsupported(connection, "floating IP allocation")
        try:
            ip = driver.ex_allocate_address(domain=request.domain or "vpc")
        except Exception as exc:
            raise APIError("provider_operation_failed", "Failed to allocate floating IP",
                           502, {"reason": str(exc)}) from exc
        return self._serialize_floating_ip(ip, connection)

    def release_floating_ip(
        self, connection: ProviderConnection, address: str, domain: str | None = None
    ) -> dict:
        driver = build_driver(connection)
        if not hasattr(driver, "ex_release_address"):
            raise _unsupported(connection, "floating IP release")
        ip = self._find_elastic_ip(driver, address)
        try:
            driver.ex_release_address(ip, domain=domain or ip.domain)
        except Exception as exc:
            raise APIError("provider_operation_failed", "Failed to release floating IP",
                           502, {"reason": str(exc)}) from exc
        return {"address": address, "released": True}

    def associate_floating_ip(
        self, connection: ProviderConnection, address: str, request: FloatingIPAssociateRequest
    ) -> dict:
        driver = build_driver(connection)
        if not hasattr(driver, "ex_associate_address_with_node"):
            raise _unsupported(connection, "floating IP association")
        ip = self._find_elastic_ip(driver, address)
        node = self._find_node(driver, request.node_id)
        try:
            driver.ex_associate_address_with_node(
                node, ip, domain=request.domain or ip.domain
            )
        except Exception as exc:
            raise APIError("provider_operation_failed", "Failed to associate floating IP",
                           502, {"reason": str(exc)}) from exc
        return {"address": address, "node_id": request.node_id, "associated": True}

    def disassociate_floating_ip(
        self, connection: ProviderConnection, address: str, request: FloatingIPDisassociateRequest
    ) -> dict:
        driver = build_driver(connection)
        if not hasattr(driver, "ex_disassociate_address"):
            raise _unsupported(connection, "floating IP disassociation")
        ip = self._find_elastic_ip(driver, address)
        try:
            driver.ex_disassociate_address(ip, domain=request.domain or ip.domain)
        except Exception as exc:
            raise APIError("provider_operation_failed", "Failed to disassociate floating IP",
                           502, {"reason": str(exc)}) from exc
        return {"address": address, "disassociated": True}

    def _find_elastic_ip(self, driver: Any, address: str):
        ips = driver.ex_describe_all_addresses() if hasattr(driver, "ex_describe_all_addresses") else []
        for ip in ips:
            if getattr(ip, "ip", "") == address:
                return ip
        raise APIError("resource_not_found", f"Floating IP {address} not found", 404)

    def _find_node(self, driver: Any, node_id: str):
        try:
            return driver.ex_get_node(node_id)  # type: ignore[attr-defined]
        except Exception:
            pass
        nodes = driver.list_nodes()
        for n in nodes:
            if getattr(n, "id", "") == node_id or getattr(n, "name", "") == node_id:
                return n
        raise APIError("resource_not_found", f"Node {node_id} not found", 404)


network_service = NetworkService()
