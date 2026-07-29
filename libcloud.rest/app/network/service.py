from __future__ import annotations

from typing import Any

from app.common.errors import APIError
from app.connections.models import ProviderConnection, connection_target
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
    name = getattr(obj, "name", None)
    # libcloud<=3.9.1 bug: some EC2 parsers fall back to tags.get("Name", id)
    # with the *builtin* id() function when the resource has no Name tag
    # (route tables, subnet associations), so a non-str "name" can leak into
    # a payload and crash the JSON encoder. Never let it through.
    return name if isinstance(name, str) else None


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
                    dhcp_server=request.dhcp_server,
                    ip_pool=request.ip_pool or None,
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
                # The driver expects the EC2NetworkSubnet object (it reads
                # subnet.id) and its own attribute names ("auto_public_ip" /
                # "auto_ipv6") — resolve the subnet first and pass the action
                # through unchanged.
                subnets = driver.ex_list_subnets(subnet_ids=[subnet_id])
                subnet = subnets[0] if subnets else None
                if not subnet:
                    raise APIError(code="resource_not_found", message="Subnet not found", status_code=404)
                driver.ex_modify_subnet_attribute(
                    subnet,
                    attribute=request.action,
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

    # ------------------------------------------------------------------ #
    # Security group rules (AWS only; Nutanix -> 501). Thin wrappers over
    # ex_authorize_security_group_ingress/egress: the traffic source is a
    # CIDR list and/or another security group (group_pairs). Used by
    # test_script/scripts/provision_aws_private.sh for the bastion/internal
    # firewall rules of aws_bastion_internal_server.md.
    # ------------------------------------------------------------------ #
    def authorize_security_group_rule(
        self,
        connection: ProviderConnection,
        group_id: str,
        request: SecurityGroupRuleAuthorizeRequest,
    ) -> dict[str, Any]:
        driver = build_driver(connection)
        authorize = getattr(
            driver,
            f"ex_authorize_security_group_{request.direction}",
            None,
        )
        if connection.provider != "aws" or authorize is None:
            raise _unsupported(connection, f"security group {request.direction} rules")
        if not request.cidr_ips and not request.source_group_id:
            raise APIError(
                code="validation_error",
                message="cidr_ips or source_group_id is required",
                status_code=400,
            )
        group_pairs = [{"group_id": request.source_group_id}] if request.source_group_id else None
        kwargs: dict[str, Any] = {
            "id": group_id,
            "from_port": request.from_port,
            "to_port": request.to_port,
            "cidr_ips": request.cidr_ips or None,
            "group_pairs": group_pairs,
            "protocol": request.protocol,
        }
        # Only the ingress variant accepts a rule description.
        if request.direction == "ingress" and request.description:
            kwargs["description"] = request.description
        try:
            success = authorize(**kwargs)
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message=f"Failed to authorize security group {request.direction} rule",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc
        return {
            "id": group_id,
            "direction": request.direction,
            "authorized": bool(success),
        }

    def _serialize_sg(self, obj: Any, connection: ProviderConnection) -> dict[str, Any]:
        extra = _extra(obj)
        sg_id = _resource_id(obj)
        if not sg_id and isinstance(obj, dict):
            sg_id = obj.get("group_id") or obj.get("groupId") or ""
        return {
            "id": sg_id,
            "name": _resource_name(obj),
            # AWS EC2SecurityGroup exposes parsed ingress/egress rule dicts;
            # clients use them for idempotent rule creation (skip rules that
            # already exist). Nutanix SGs have no such attributes -> [].
            "ingress_rules": list(getattr(obj, "ingress_rules", None) or []),
            "egress_rules": list(getattr(obj, "egress_rules", None) or []),
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

    # ------------------------------------------------------------------ #
    # Internet gateways (AWS only; Nutanix -> 501). Required so the public
    # subnet of a freshly created VPC can reach the internet (the bastion
    # scenario in aws_bastion_internal_server.md).
    # ------------------------------------------------------------------ #
    def _serialize_igw(self, obj: Any, connection: ProviderConnection) -> dict[str, Any]:
        return {
            "id": getattr(obj, "id", "") or "",
            "name": _resource_name(obj),
            "vpc_id": getattr(obj, "vpc_id", None),
            "state": getattr(obj, "state", None),
            "provider": connection.provider,
            "target": connection_target(connection),
            "extra": dict(getattr(obj, "extra", None) or {}),
        }

    def list_internet_gateways(
        self,
        connection: ProviderConnection,
        gateway_id: str | None = None,
        vpc_id: str | None = None,
    ) -> list[dict[str, Any]]:
        driver = build_driver(connection)
        if not hasattr(driver, "ex_list_internet_gateways"):
            raise _unsupported(connection, "internet gateways")
        try:
            if gateway_id:
                gateways = driver.ex_list_internet_gateways(gateway_ids=[gateway_id])
            elif vpc_id:
                gateways = driver.ex_list_internet_gateways(filters={"attachment.vpc-id": vpc_id})
            else:
                gateways = driver.ex_list_internet_gateways()
        except Exception as exc:
            raise APIError("provider_operation_failed", "Failed to list internet gateways",
                           502, {"reason": str(exc)}) from exc
        return [self._serialize_igw(g, connection) for g in gateways]

    def create_internet_gateway(
        self, connection: ProviderConnection, request: InternetGatewayCreateRequest
    ) -> dict[str, Any]:
        driver = build_driver(connection)
        if not hasattr(driver, "ex_create_internet_gateway"):
            raise _unsupported(connection, "internet gateway creation")
        try:
            networks = driver.ex_list_networks(network_ids=[request.vpc_id])
            if not networks:
                raise APIError("resource_not_found", f"VPC {request.vpc_id} not found", 404)
            gateway = driver.ex_create_internet_gateway(name=request.name or None)
            driver.ex_attach_internet_gateway(gateway, networks[0])
            # Re-read so the serialized gateway reflects the attachment.
            attached = driver.ex_list_internet_gateways(gateway_ids=[gateway.id])
            gateway = attached[0] if attached else gateway
        except APIError:
            raise
        except Exception as exc:
            raise APIError("provider_operation_failed", "Failed to create internet gateway",
                           502, {"reason": str(exc)}) from exc
        return self._serialize_igw(gateway, connection)

    # ------------------------------------------------------------------ #
    # Route tables (AWS only; Nutanix -> 501). The public subnet gets a
    # route table with 0.0.0.0/0 -> IGW; the private subnet deliberately
    # stays on the VPC main (local-only) table so its VMs have NO internet
    # access (no NAT gateway is created).
    # ------------------------------------------------------------------ #
    def _serialize_route_table(self, obj: Any, connection: ProviderConnection) -> dict[str, Any]:
        routes = [
            {
                "cidr": getattr(r, "cidr", None),
                "gateway_id": getattr(r, "gateway_id", None),
                "state": getattr(r, "state", None),
            }
            for r in (getattr(obj, "routes", None) or [])
        ]
        associations = [
            {
                "id": getattr(a, "id", None),
                "subnet_id": getattr(a, "subnet_id", None),
            }
            for a in (getattr(obj, "subnet_associations", None) or [])
        ]
        return {
            "id": getattr(obj, "id", "") or "",
            "name": _resource_name(obj),
            "routes": routes,
            "subnet_associations": associations,
            "provider": connection.provider,
            "target": connection_target(connection),
            "extra": dict(getattr(obj, "extra", None) or {}),
        }

    def list_route_tables(
        self,
        connection: ProviderConnection,
        route_table_id: str | None = None,
        vpc_id: str | None = None,
    ) -> list[dict[str, Any]]:
        driver = build_driver(connection)
        if not hasattr(driver, "ex_list_route_tables"):
            raise _unsupported(connection, "route tables")
        try:
            if route_table_id:
                tables = driver.ex_list_route_tables(route_table_ids=[route_table_id])
            elif vpc_id:
                tables = driver.ex_list_route_tables(filters={"vpc-id": vpc_id})
            else:
                tables = driver.ex_list_route_tables()
        except Exception as exc:
            raise APIError("provider_operation_failed", "Failed to list route tables",
                           502, {"reason": str(exc)}) from exc
        return [self._serialize_route_table(t, connection) for t in tables]

    def _get_route_table_obj(self, driver: Any, route_table_id: str):
        tables = driver.ex_list_route_tables(route_table_ids=[route_table_id])
        if not tables:
            raise APIError("resource_not_found", f"Route table {route_table_id} not found", 404)
        return tables[0]

    def create_route_table(
        self, connection: ProviderConnection, request: RouteTableCreateRequest
    ) -> dict[str, Any]:
        driver = build_driver(connection)
        if not hasattr(driver, "ex_create_route_table"):
            raise _unsupported(connection, "route table creation")
        try:
            networks = driver.ex_list_networks(network_ids=[request.vpc_id])
            if not networks:
                raise APIError("resource_not_found", f"VPC {request.vpc_id} not found", 404)
            table = driver.ex_create_route_table(networks[0], name=request.name or None)
        except APIError:
            raise
        except Exception as exc:
            raise APIError("provider_operation_failed", "Failed to create route table",
                           502, {"reason": str(exc)}) from exc
        return self._serialize_route_table(table, connection)

    def create_route(
        self, connection: ProviderConnection, route_table_id: str, request: RouteCreateRequest
    ) -> dict[str, Any]:
        driver = build_driver(connection)
        if not hasattr(driver, "ex_create_route"):
            raise _unsupported(connection, "route creation")
        if not request.internet_gateway_id:
            raise APIError(
                code="validation_error",
                message="internet_gateway_id is required (only IGW routes are supported)",
                status_code=400,
            )
        try:
            table = self._get_route_table_obj(driver, route_table_id)
            gateways = driver.ex_list_internet_gateways(gateway_ids=[request.internet_gateway_id])
            if not gateways:
                raise APIError(
                    "resource_not_found",
                    f"Internet gateway {request.internet_gateway_id} not found",
                    404,
                )
            success = driver.ex_create_route(table, request.cidr_block, internet_gateway=gateways[0])
        except APIError:
            raise
        except Exception as exc:
            raise APIError("provider_operation_failed", "Failed to create route",
                           502, {"reason": str(exc)}) from exc
        return {
            "id": route_table_id,
            "cidr_block": request.cidr_block,
            "internet_gateway_id": request.internet_gateway_id,
            "created": bool(success),
        }

    def associate_route_table(
        self, connection: ProviderConnection, route_table_id: str, request: RouteTableAssociateRequest
    ) -> dict[str, Any]:
        driver = build_driver(connection)
        if not hasattr(driver, "ex_associate_route_table"):
            raise _unsupported(connection, "route table association")
        try:
            table = self._get_route_table_obj(driver, route_table_id)
            subnets = driver.ex_list_subnets(subnet_ids=[request.subnet_id])
            if not subnets:
                raise APIError("resource_not_found", f"Subnet {request.subnet_id} not found", 404)
            association_id = driver.ex_associate_route_table(table, subnets[0])
        except APIError:
            raise
        except Exception as exc:
            raise APIError("provider_operation_failed", "Failed to associate route table",
                           502, {"reason": str(exc)}) from exc
        return {
            "id": route_table_id,
            "subnet_id": request.subnet_id,
            "association_id": association_id,
            "associated": True,
        }

    # ------------------------------------------------------------------ #
    # Network interfaces (AWS ENIs; Nutanix -> 501). Read-only listing so
    # clients can link an ENI to its subnet, VPC and attachment state.
    # ------------------------------------------------------------------ #
    def _serialize_eni(self, obj: Any, connection: ProviderConnection) -> dict[str, Any]:
        extra = _extra(obj)
        return {
            "id": getattr(obj, "id", "") or "",
            "name": _resource_name(obj),
            "state": getattr(obj, "state", None),
            "subnet_id": extra.get("subnet_id"),
            "vpc_id": extra.get("vpc_id"),
            "provider": connection.provider,
            "target": connection_target(connection),
            "extra": extra,
        }

    def list_network_interfaces(
        self,
        connection: ProviderConnection,
        interface_id: str | None = None,
    ) -> list[dict[str, Any]]:
        driver = build_driver(connection)
        if not hasattr(driver, "ex_list_network_interfaces"):
            raise _unsupported(connection, "network interfaces")
        try:
            interfaces = driver.ex_list_network_interfaces()
        except Exception as exc:
            raise APIError("provider_operation_failed", "Failed to list network interfaces",
                           502, {"reason": str(exc)}) from exc
        if interface_id:
            interfaces = [i for i in interfaces if getattr(i, "id", "") == interface_id]
        return [self._serialize_eni(i, connection) for i in interfaces]


network_service = NetworkService()
