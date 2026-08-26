from __future__ import annotations

from typing import Any

from libcloud.compute.base import Node, NodeAuthPassword, NodeAuthSSHKey, NodeImage, NodeLocation, NodeSize

from app.common.errors import APIError
from app.config.settings import get_settings
from app.compute.models import (
    ImageCreateRequest,
    ImageResponse,
    KeyPairCreateRequest,
    KeyPairResponse,
    LocationResponse,
    NodeCreateRequest,
    NodeResponse,
    NodeUpdateRequest,
    SizeResponse,
    SnapshotCreateRequest,
    SnapshotResponse,
    VolumeAttachRequest,
    VolumeCreateRequest,
    VolumeResponse,
    VolumeUpdateRequest,
)
from app.connections.models import ProviderConnection, connection_target
from app.providers.factory import build_driver

AWS_ALLOWED_EX = {
    "ex_securitygroup",
    "ex_securitygroups",
    "ex_security_group_ids",
    "ex_keyname",
    "ex_subnet",
    "ex_assign_public_ip",
    "ex_userdata",
    "ex_metadata",
    "ex_blockdevicemappings",
    "ex_spot",
    "ex_placement_group",
    "ex_iamprofile",
    "ex_volume_type",
    "ex_encrypted",
    "ex_iops",
}

NUTANIX_ALLOWED_EX = {
    "ex_subnet",
    "ex_description",
    "ex_cluster",
    "ex_memory_mib",
    "ex_vcpus",
    "ex_cores_per_vcpu",
    "ex_storage_container",
    "ex_disk_size_mib",
    "ex_user_data",
    "ex_cloud_init",
    "ex_nics",
    "ex_categories",
    "ex_power_on",
    "ex_assign_ip",
    "ex_ip_address",
    "ex_ip_prefix_length",
    "ex_data_disks",
    "ex_wait",
}


def _filter_provider_options(provider: str, options: dict[str, Any]) -> dict[str, Any]:
    allowed = AWS_ALLOWED_EX if provider == "aws" else NUTANIX_ALLOWED_EX
    filtered = {}
    for key, value in options.items():
        if key in allowed:
            filtered[key] = value
    return filtered


def _serialize_node(node: Node, connection: ProviderConnection) -> NodeResponse:
    return NodeResponse(
        id=node.id,
        name=node.name,
        state=str(node.state),
        public_ips=list(node.public_ips or []),
        private_ips=list(node.private_ips or []),
        size=node.size.id if node.size else None,
        image=node.image.id if node.image else None,
        provider=connection.provider,
        target=connection_target(connection),
        extra={k: v for k, v in (node.extra or {}).items() if k != "password"},
    )


def _find_size(driver, size_id: str) -> NodeSize:
    sizes = driver.list_sizes()
    matches = [s for s in sizes if s.id == size_id]
    if not matches:
        raise APIError(
            code="resource_not_found",
            message="Size not found",
            status_code=404,
            details={"size_id": size_id},
        )
    return matches[0]


def _find_location(driver, connection: ProviderConnection, location_id: str) -> NodeLocation:
    if connection.provider == "nutanix" and hasattr(driver, "ex_list_clusters"):
        clusters = driver.ex_list_clusters()
        matches = [c for c in clusters if c.id == location_id]
        if matches:
            return matches[0]
    locations = driver.list_locations()
    matches = [loc for loc in locations if loc.id == location_id]
    if not matches:
        raise APIError(
            code="resource_not_found",
            message="Location not found",
            status_code=404,
            details={"location_id": location_id},
        )
    return matches[0]


def _resolve_subnet(driver, connection: ProviderConnection, subnet_id: str):
    if connection.provider == "aws" and hasattr(driver, "ex_list_subnets"):
        subnets = driver.ex_list_subnets(subnet_ids=[subnet_id])
        if subnets:
            return subnets[0]
    return subnet_id


def _resolve_aws_security_group_kwargs(driver, subnet_id: str | None, security_group: str | None) -> dict[str, Any]:
    """Map REST network.security_group to EC2 RunInstances params.

    With a subnet (VPC), EC2 requires SecurityGroupId.* — groupName cannot be
    combined with SubnetId (InvalidParameterCombination).
    """
    if not security_group:
        return {}
    if not subnet_id:
        return {"ex_securitygroup": security_group}

    group_id = security_group
    if not security_group.startswith("sg-") and hasattr(driver, "ex_get_security_groups"):
        matches = driver.ex_get_security_groups(group_names=[security_group])
        if matches:
            group_id = matches[0].id
    return {"ex_security_group_ids": [group_id]}


def _build_auth(request: NodeCreateRequest):
    if not request.auth:
        return None
    if request.auth.type == "ssh_key":
        if not request.auth.public_key:
            raise APIError(
                code="validation_error",
                message="public_key required for ssh_key auth",
                status_code=400,
            )
        return NodeAuthSSHKey(public_key=request.auth.public_key)
    if request.auth.type == "password":
        if not request.auth.password:
            raise APIError(
                code="validation_error",
                message="password required for password auth",
                status_code=400,
            )
        return NodeAuthPassword(password=request.auth.password)
    return None


def _enrich_host_bmc(
    driver, host: dict[str, Any], cluster_ext_id: str | None = None
) -> dict[str, Any]:
    """Best-effort attach BMC IP/status to a host detail dict (Nutanix).

    Mirrors the get_host_details sample's per-host stats fetch: after listing
    hosts, each host's BMC details are fetched individually via
    ``ex_get_host_bmc_info``. Any failure (e.g. emulator without bmc-info, or a
    host missing its cluster reference) degrades to leaving the fields unset
    rather than failing the whole listing.
    """
    host_ext_id = host.get("id")
    resolved_cluster = host.get("cluster_ext_id") or cluster_ext_id
    if (
        not host_ext_id
        or not resolved_cluster
        or not hasattr(driver, "ex_get_host_bmc_info")
    ):
        return host
    try:
        bmc = driver.ex_get_host_bmc_info(host_ext_id, resolved_cluster)
    except Exception:
        return host
    if bmc:
        host["bmc_ip"] = bmc.get("bmc_ip")
        host["bmc_status"] = bmc.get("bmc_status")
    return host


class ComputeService:
    def list_nodes(self, connection: ProviderConnection, node_id: str | None = None) -> list[NodeResponse]:
        driver = build_driver(connection)
        if node_id:
            if hasattr(driver, "ex_get_node"):
                nodes = [driver.ex_get_node(node_id)]
            else:
                nodes = [n for n in driver.list_nodes() if n.id == node_id]
        else:
            nodes = driver.list_nodes()
        return [_serialize_node(n, connection) for n in nodes]

    def get_node(self, connection: ProviderConnection, node_id: str) -> NodeResponse:
        nodes = self.list_nodes(connection, node_id=node_id)
        if not nodes:
            raise APIError(
                code="resource_not_found",
                message="Node not found",
                status_code=404,
                details={"node_id": node_id},
            )
        return nodes[0]

    def create_node(self, connection: ProviderConnection, request: NodeCreateRequest) -> NodeResponse:
        driver = build_driver(connection)
        size = _find_size(driver, request.size.id)
        image = NodeImage(id=request.image.id, name=None, driver=driver)

        kwargs: dict[str, Any] = {
            "name": request.name,
            "size": size,
            "image": image,
        }

        if request.location:
            kwargs["location"] = _find_location(driver, connection, request.location.id)

        auth = _build_auth(request)
        if auth:
            kwargs["auth"] = auth

        if request.network:
            if request.network.subnet_id:
                kwargs["ex_subnet"] = _resolve_subnet(driver, connection, request.network.subnet_id)
            if request.network.public_ip:
                kwargs["ex_assign_public_ip"] = True
            if request.network.security_group:
                if connection.provider == "aws":
                    kwargs.update(
                        _resolve_aws_security_group_kwargs(
                            driver, request.network.subnet_id, request.network.security_group
                        )
                    )
                else:
                    kwargs["ex_securitygroup"] = request.network.security_group

        if request.auth and request.auth.type == "key_pair" and request.auth.key_name:
            kwargs["ex_keyname"] = request.auth.key_name

        if request.tags and connection.provider == "aws":
            kwargs["ex_metadata"] = request.tags

        kwargs.update(_filter_provider_options(connection.provider, request.provider_options))

        try:
            node = driver.create_node(**kwargs)
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to create node",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc

        if request.execution.wait_until_running and hasattr(driver, "wait_until_running"):
            try:
                node = driver.wait_until_running(node, timeout=request.execution.timeout_seconds)
            except Exception as exc:
                raise APIError(
                    code="provider_operation_failed",
                    message="Node created but wait_until_running failed",
                    status_code=502,
                    details={"node_id": node.id, "reason": str(exc)},
                ) from exc

        return _serialize_node(node, connection)

    def destroy_node(self, connection: ProviderConnection, node_id: str) -> dict:
        driver = build_driver(connection)
        node = self._get_driver_node(driver, connection, node_id)
        try:
            success = driver.destroy_node(node)
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to destroy node",
                status_code=502,
                details={"node_id": node_id, "reason": str(exc)},
            ) from exc
        return {"id": node_id, "destroyed": success}

    def power_node(self, connection: ProviderConnection, node_id: str, action: str) -> dict:
        driver = build_driver(connection)
        node = self._get_driver_node(driver, connection, node_id)
        try:
            if action == "start":
                driver.start_node(node)
            elif action == "stop":
                driver.stop_node(node)
            elif action == "reboot":
                driver.reboot_node(node)
            else:
                raise APIError(code="validation_error", message="Unsupported power action", status_code=400)
        except APIError:
            raise
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message=f"Failed to {action} node",
                status_code=502,
                details={"node_id": node_id, "reason": str(exc)},
            ) from exc
        return {"id": node_id, "action": action, "success": True}

    def update_node(
        self, connection: ProviderConnection, node_id: str, request: NodeUpdateRequest
    ) -> dict:
        driver = build_driver(connection)
        node = self._get_driver_node(driver, connection, node_id)
        try:
            if request.action == "resize":
                if not request.new_size_id:
                    raise APIError(
                        code="validation_error",
                        message="new_size_id required for resize",
                        status_code=400,
                    )
                size = _find_size(driver, request.new_size_id)
                if not hasattr(driver, "ex_change_node_size"):
                    raise APIError(
                        code="provider_capability_unsupported",
                        message="Resize not supported",
                        status_code=400,
                    )
                driver.ex_change_node_size(node, size)
                return {"id": node_id, "action": "resize", "new_size": request.new_size_id, "success": True}
            if request.action == "tag":
                if not request.tag_key or request.tag_value is None:
                    raise APIError(
                        code="validation_error",
                        message="tag_key and tag_value required",
                        status_code=400,
                    )
                if not hasattr(driver, "ex_create_tags"):
                    raise APIError(
                        code="provider_capability_unsupported",
                        message="Tagging not supported",
                        status_code=400,
                    )
                driver.ex_create_tags(node, {request.tag_key: request.tag_value})
                return {"id": node_id, "action": "tag", "success": True}
            if connection.provider == "nutanix" and hasattr(driver, "ex_update_node"):
                kwargs: dict[str, Any] = {}
                if request.name is not None:
                    kwargs["name"] = request.name
                if request.description is not None:
                    kwargs["description"] = request.description
                if request.memory_mib is not None:
                    kwargs["ex_memory_mib"] = request.memory_mib
                updated = driver.ex_update_node(node_id, **kwargs)
                return _serialize_node(updated, connection).model_dump()
            raise APIError(
                code="provider_capability_unsupported",
                message="Node update not supported",
                status_code=400,
            )
        except APIError:
            raise
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to update node",
                status_code=502,
                details={"node_id": node_id, "reason": str(exc)},
            ) from exc

    def _get_driver_node(self, driver, connection: ProviderConnection, node_id: str) -> Node:
        if hasattr(driver, "ex_get_node"):
            return driver.ex_get_node(node_id)
        for node in driver.list_nodes():
            if node.id == node_id:
                return node
        raise APIError(
            code="resource_not_found",
            message="Node not found",
            status_code=404,
            details={"node_id": node_id},
        )

    def list_images(
        self,
        connection: ProviderConnection,
        owner: str | None = None,
        filters: dict[str, str] | None = None,
        arch: str | None = None,
    ) -> list[ImageResponse]:
        driver = build_driver(connection)
        kwargs: dict[str, Any] = {}
        if connection.provider == "aws":
            if owner:
                kwargs["ex_owner"] = owner
            aws_filters: dict[str, str] = {}
            if filters is None:
                default_name = get_settings().aws_default_image_name_filter.strip()
                if default_name:
                    aws_filters["name"] = default_name
                default_arch = get_settings().aws_default_image_architecture_filter.strip()
                if default_arch:
                    aws_filters["architecture"] = default_arch
            else:
                aws_filters = dict(filters)
            # Allow explicit arch override (None = use default; "" or "*" = skip arch filter)
            if arch is not None:
                if arch == "" or arch == "*":
                    aws_filters.pop("architecture", None)
                else:
                    aws_filters["architecture"] = arch
            if aws_filters:
                kwargs["ex_filters"] = aws_filters
        try:
            images = driver.list_images(**kwargs) if kwargs else driver.list_images()
        except TypeError:
            images = driver.list_images()
        return [
            ImageResponse(id=img.id, name=img.name, extra=dict(img.extra or {}))
            for img in images
        ]

    def list_sizes(self, connection: ProviderConnection) -> list[SizeResponse]:
        driver = build_driver(connection)
        return [
            SizeResponse(
                id=size.id,
                name=size.name,
                ram=size.ram,
                disk=size.disk,
                bandwidth=size.bandwidth,
                extra=dict(size.extra or {}),
            )
            for size in driver.list_sizes()
        ]

    def list_locations(self, connection: ProviderConnection) -> list[LocationResponse]:
        driver = build_driver(connection)
        if connection.provider == "nutanix" and hasattr(driver, "ex_list_clusters"):
            clusters = driver.ex_list_clusters()
            return [
                LocationResponse(id=c.id, name=c.name, extra=dict(c.extra or {}))
                for c in clusters
            ]
        return [
            LocationResponse(
                id=loc.id,
                name=loc.name,
                country=getattr(loc, "country", None),
                extra=dict(loc.extra or {}),
            )
            for loc in driver.list_locations()
        ]

    def list_hosts(
        self, connection: ProviderConnection, cluster_ext_id: str | None = None
    ) -> list[dict[str, Any]]:
        """List physical hosts (Nutanix) with full hardware details."""
        driver = build_driver(connection)
        if not hasattr(driver, "ex_list_hosts"):
            raise APIError(
                code="provider_capability_unsupported",
                message="Host listing not supported",
                status_code=400,
            )
        try:
            hosts = driver.ex_list_hosts(cluster_ext_id=cluster_ext_id)
            return [_enrich_host_bmc(driver, h, cluster_ext_id) for h in hosts]
        except APIError:
            raise
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to list hosts",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc

    def get_host(
        self,
        connection: ProviderConnection,
        host_id: str,
        cluster_ext_id: str | None = None,
    ) -> dict[str, Any]:
        """Get the details of a single physical host (Nutanix)."""
        driver = build_driver(connection)
        if not hasattr(driver, "ex_get_host"):
            raise APIError(
                code="provider_capability_unsupported",
                message="Host details not supported",
                status_code=400,
            )
        try:
            host = driver.ex_get_host(host_id, cluster_ext_id=cluster_ext_id)
            return _enrich_host_bmc(driver, host, cluster_ext_id)
        except APIError:
            raise
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to get host",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc

    def get_host_bmc_info(
        self,
        connection: ProviderConnection,
        host_id: str,
        cluster_ext_id: str | None = None,
    ) -> dict[str, Any]:
        """Get BMC details (IP + credential status) for a single host (Nutanix)."""
        driver = build_driver(connection)
        if not hasattr(driver, "ex_get_host_bmc_info"):
            raise APIError(
                code="provider_capability_unsupported",
                message="Host BMC info not supported",
                status_code=400,
            )
        if not cluster_ext_id:
            raise APIError(
                code="validation_error",
                message="cluster_ext_id is required for host BMC info",
                status_code=400,
            )
        try:
            return driver.ex_get_host_bmc_info(host_id, cluster_ext_id)
        except APIError:
            raise
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to get host BMC info",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc

    def create_volume(self, connection: ProviderConnection, request: VolumeCreateRequest) -> VolumeResponse:
        driver = build_driver(connection)
        if not hasattr(driver, "create_volume"):
            raise APIError(
                code="provider_capability_unsupported",
                message="Provider does not support volume creation",
                status_code=400,
            )
        location = None
        if request.location:
            location = _find_location(driver, connection, request.location.id)
        kwargs = _filter_provider_options(connection.provider, request.provider_options)
        snapshot = None
        if request.snapshot_id:
            if hasattr(driver, "ex_get_volume_snapshot"):
                snapshot = driver.ex_get_volume_snapshot(request.snapshot_id)
            else:
                raise APIError(
                    code="provider_capability_unsupported",
                    message="Snapshot restore not supported",
                    status_code=400,
                )
        try:
            volume = driver.create_volume(
                request.size_gb,
                name=request.name,
                location=location,
                snapshot=snapshot,
                **kwargs,
            )
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to create volume",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc
        return VolumeResponse(
            id=volume.id,
            name=volume.name,
            size=volume.size,
            state=str(volume.state) if volume.state else None,
            extra=dict(volume.extra or {}),
        )

    def list_volumes(
        self, connection: ProviderConnection, volume_id: str | None = None
    ) -> list[VolumeResponse]:
        driver = build_driver(connection)
        if not hasattr(driver, "list_volumes"):
            raise APIError(
                code="provider_capability_unsupported",
                message="Volume listing not supported",
                status_code=400,
            )
        if volume_id and hasattr(driver, "ex_get_volume"):
            volume = driver.ex_get_volume(volume_id)
            return [self._serialize_volume(volume)]
        volumes = driver.list_volumes()
        if volume_id:
            volumes = [v for v in volumes if v.id == volume_id]
        return [self._serialize_volume(v) for v in volumes]

    def _serialize_volume(self, volume) -> VolumeResponse:
        return VolumeResponse(
            id=volume.id,
            name=volume.name,
            size=volume.size,
            state=str(volume.state) if volume.state else None,
            extra=dict(volume.extra or {}),
        )

    def destroy_volume(self, connection: ProviderConnection, volume_id: str) -> dict:
        driver = build_driver(connection)
        volumes = self.list_volumes(connection, volume_id=volume_id)
        if not volumes:
            raise APIError(
                code="resource_not_found",
                message="Volume not found",
                status_code=404,
            )
        if not hasattr(driver, "destroy_volume"):
            raise APIError(
                code="provider_capability_unsupported",
                message="Volume deletion not supported",
                status_code=400,
            )
        vol_list = driver.list_volumes()
        volume = next((v for v in vol_list if v.id == volume_id), None)
        try:
            success = driver.destroy_volume(volume)
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to destroy volume",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc
        return {"id": volume_id, "destroyed": success}

    def update_volume(
        self, connection: ProviderConnection, volume_id: str, request: VolumeUpdateRequest
    ) -> dict:
        driver = build_driver(connection)
        vol_list = driver.list_volumes() if hasattr(driver, "list_volumes") else []
        volume = next((v for v in vol_list if v.id == volume_id), None)
        if not volume:
            raise APIError(code="resource_not_found", message="Volume not found", status_code=404)
        try:
            if request.action == "tag":
                if not request.tag_key or request.tag_value is None:
                    raise APIError(
                        code="validation_error",
                        message="tag_key and tag_value required",
                        status_code=400,
                    )
                driver.ex_create_tags(volume, {request.tag_key: request.tag_value})
                return {"id": volume_id, "action": "tag", "success": True}
            if hasattr(driver, "ex_modify_volume"):
                driver.ex_modify_volume(
                    volume,
                    size=request.new_size_gb,
                    volume_type=request.volume_type,
                    iops=request.iops,
                )
                return {"id": volume_id, "action": "modify", "success": True}
            raise APIError(
                code="provider_capability_unsupported",
                message="Volume modify not supported",
                status_code=400,
            )
        except APIError:
            raise
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to update volume",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc

    def attach_volume(self, connection: ProviderConnection, request: VolumeAttachRequest, volume_id: str) -> dict:
        driver = build_driver(connection)
        if not hasattr(driver, "attach_volume"):
            raise APIError(
                code="provider_capability_unsupported",
                message="Provider does not support volume attach",
                status_code=400,
            )
        node = self._get_driver_node(driver, connection, request.node_id)
        volumes = driver.list_volumes() if hasattr(driver, "list_volumes") else []
        volume = next((v for v in volumes if v.id == volume_id), None)
        if not volume:
            raise APIError(
                code="resource_not_found",
                message="Volume not found",
                status_code=404,
                details={"volume_id": volume_id},
            )
        try:
            success = driver.attach_volume(node, volume, device=request.device)
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to attach volume",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc
        return {"volume_id": volume_id, "node_id": request.node_id, "attached": success}

    def detach_volume(self, connection: ProviderConnection, request: VolumeAttachRequest, volume_id: str) -> dict:
        driver = build_driver(connection)
        if not hasattr(driver, "detach_volume"):
            raise APIError(
                code="provider_capability_unsupported",
                message="Provider does not support volume detach",
                status_code=400,
            )
        node = self._get_driver_node(driver, connection, request.node_id)
        volumes = driver.list_volumes() if hasattr(driver, "list_volumes") else []
        volume = next((v for v in volumes if v.id == volume_id), None)
        if not volume:
            raise APIError(
                code="resource_not_found",
                message="Volume not found",
                status_code=404,
                details={"volume_id": volume_id},
            )
        try:
            if connection.provider == "nutanix":
                success = driver.detach_volume(volume, ex_vm_ext_id=request.node_id)
            else:
                success = driver.detach_volume(volume)
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to detach volume",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc
        return {"volume_id": volume_id, "node_id": request.node_id, "detached": success}

    def create_snapshot(
        self, connection: ProviderConnection, request: SnapshotCreateRequest
    ) -> SnapshotResponse:
        driver = build_driver(connection)
        if not hasattr(driver, "create_volume_snapshot"):
            raise APIError(
                code="provider_capability_unsupported",
                message="Snapshot creation not supported",
                status_code=400,
            )
        vol_list = driver.list_volumes() if hasattr(driver, "list_volumes") else []
        volume = next((v for v in vol_list if v.id == request.volume_id), None)
        if not volume and hasattr(driver, "ex_get_volume"):
            volume = driver.ex_get_volume(request.volume_id)
        if not volume:
            raise APIError(
                code="resource_not_found",
                message="Volume not found",
                status_code=404,
            )
        try:
            snap = driver.create_volume_snapshot(volume, name=request.name)
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to create snapshot",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc
        return self._serialize_snapshot(snap, request.volume_id)

    def list_snapshots(
        self,
        connection: ProviderConnection,
        volume_id: str | None = None,
        snapshot_id: str | None = None,
        owner: str | None = None,
    ) -> list[SnapshotResponse]:
        driver = build_driver(connection)
        if snapshot_id and hasattr(driver, "ex_get_volume_snapshot"):
            snap = driver.ex_get_volume_snapshot(snapshot_id)
            return [self._serialize_snapshot(snap, volume_id)]
        if volume_id and hasattr(driver, "list_volume_snapshots"):
            vol_list = driver.list_volumes() if hasattr(driver, "list_volumes") else []
            volume = next((v for v in vol_list if v.id == volume_id), None)
            if not volume and hasattr(driver, "ex_get_volume"):
                volume = driver.ex_get_volume(volume_id)
            if not volume:
                raise APIError(code="resource_not_found", message="Volume not found", status_code=404)
            return [
                self._serialize_snapshot(s, volume_id)
                for s in driver.list_volume_snapshots(volume)
            ]
        if hasattr(driver, "list_snapshots"):
            # owner is AWS-only ("self"|"amazon"|<account-id>): without it
            # DescribeSnapshots returns ALL public snapshots (tens of
            # thousands), so inventory callers should pass owner="self".
            snaps = (
                driver.list_snapshots(owner=owner)
                if owner and connection.provider == "aws"
                else driver.list_snapshots()
            )
            return [self._serialize_snapshot(s, None) for s in snaps]
        raise APIError(
            code="provider_capability_unsupported",
            message="Snapshot listing not supported",
            status_code=400,
        )

    def destroy_snapshot(
        self, connection: ProviderConnection, snapshot_id: str, volume_id: str | None = None
    ) -> dict:
        driver = build_driver(connection)
        if not hasattr(driver, "destroy_volume_snapshot"):
            raise APIError(
                code="provider_capability_unsupported",
                message="Snapshot deletion not supported",
                status_code=400,
            )
        try:
            if hasattr(driver, "ex_get_volume_snapshot"):
                snap = driver.ex_get_volume_snapshot(snapshot_id)
            else:
                snaps = self.list_snapshots(connection, volume_id=volume_id, snapshot_id=snapshot_id)
                if not snaps:
                    raise APIError(code="resource_not_found", message="Snapshot not found", status_code=404)
                vol_list = driver.list_volumes()
                volume = next((v for v in vol_list if v.id == volume_id), None)
                snap = driver.list_volume_snapshots(volume)
                snap = next((s for s in snap if s.id == snapshot_id), None)
            driver.destroy_volume_snapshot(snap)
        except APIError:
            raise
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to destroy snapshot",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc
        return {"id": snapshot_id, "destroyed": True}

    def _serialize_snapshot(self, snap, volume_id: str | None) -> SnapshotResponse:
        return SnapshotResponse(
            id=snap.id,
            name=getattr(snap, "name", None),
            volume_id=volume_id,
            state=str(getattr(snap, "state", None)) if getattr(snap, "state", None) else None,
            extra=dict(getattr(snap, "extra", None) or {}),
        )

    def create_image(
        self, connection: ProviderConnection, request: ImageCreateRequest
    ) -> ImageResponse:
        driver = build_driver(connection)
        try:
            if request.url and hasattr(driver, "ex_create_image_from_url"):
                img = driver.ex_create_image_from_url(
                    name=request.name,
                    url=request.url,
                    description=request.description,
                )
            elif request.vm_id and hasattr(driver, "create_image"):
                node = self._get_driver_node(driver, connection, request.vm_id)
                img = driver.create_image(node, name=request.name, description=request.description)
            else:
                raise APIError(
                    code="validation_error",
                    message="Provide url or vm_id for image creation",
                    status_code=400,
                )
        except APIError:
            raise
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to create image",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc
        return ImageResponse(id=img.id, name=img.name, extra=dict(img.extra or {}))

    def destroy_image(self, connection: ProviderConnection, image_id: str) -> dict:
        driver = build_driver(connection)
        if not hasattr(driver, "delete_image"):
            raise APIError(
                code="provider_capability_unsupported",
                message="Image deletion not supported",
                status_code=400,
            )
        try:
            images = driver.list_images()
            image = next((i for i in images if i.id == image_id), None)
            if not image:
                raise APIError(code="resource_not_found", message="Image not found", status_code=404)
            driver.delete_image(image)
        except APIError:
            raise
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to delete image",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc
        return {"id": image_id, "destroyed": True}

    def list_key_pairs(self, connection: ProviderConnection) -> list[KeyPairResponse]:
        driver = build_driver(connection)
        if not hasattr(driver, "list_key_pairs"):
            raise APIError(
                code="provider_capability_unsupported",
                message="Key pair listing not supported",
                status_code=400,
            )
        try:
            pairs = driver.list_key_pairs()
        except NotImplementedError as exc:
            # hasattr() can't distinguish a real implementation from the
            # NodeDriver base stub, which raises NotImplementedError (e.g.
            # Nutanix). Surface it as a clean 501, not a 500.
            raise APIError(
                code="provider_capability_unsupported",
                message=f"Provider '{connection.provider}' does not support key pair listing",
                status_code=501,
            ) from exc
        return [
            KeyPairResponse(
                name=k.name,
                fingerprint=getattr(k, "fingerprint", None),
                public_key=getattr(k, "public_key", None),
            )
            for k in pairs
        ]

    def delete_key_pair(self, connection: ProviderConnection, name: str) -> dict:
        driver = build_driver(connection)
        if not hasattr(driver, "delete_key_pair"):
            raise APIError(
                code="provider_capability_unsupported",
                message="Key pair deletion not supported",
                status_code=400,
            )
        try:
            driver.delete_key_pair(name)
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to delete key pair",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc
        return {"name": name, "destroyed": True}

    def create_key_pair(self, connection: ProviderConnection, request: KeyPairCreateRequest) -> KeyPairResponse:
        driver = build_driver(connection)
        if not hasattr(driver, "create_key_pair"):
            raise APIError(
                code="provider_capability_unsupported",
                message="Provider does not support key pair creation",
                status_code=400,
            )
        try:
            key = driver.create_key_pair(name=request.name)
        except TypeError:
            key = driver.create_key_pair(name=request.name, public_key=request.public_key)
        except Exception as exc:
            raise APIError(
                code="provider_operation_failed",
                message="Failed to create key pair",
                status_code=502,
                details={"reason": str(exc)},
            ) from exc
        return KeyPairResponse(
            name=key.name,
            fingerprint=getattr(key, "fingerprint", None),
            public_key=getattr(key, "public_key", None),
            private_key=getattr(key, "private_key", None),
        )


compute_service = ComputeService()
