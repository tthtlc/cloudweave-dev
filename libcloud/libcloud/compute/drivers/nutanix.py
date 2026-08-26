# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
Nutanix Prism Central v4 AHV compute driver.
"""

from __future__ import annotations

import base64
import json

from libcloud.common.nutanix import (
    DEFAULT_API_VERSION,
    DEFAULT_PAGE_SIZE,
    SYNTHETIC_SIZES,
    NutanixConnection,
    build_recovery_point_create_payload,
    build_image_create_payload,
    build_image_url_source,
    build_image_vm_disk_source,
    build_subnet_create_payload,
    build_vpc_create_payload,
    build_vm_create_payload,
    build_volume_group_create_payload,
    bytes_to_gib,
    bytes_to_mib,
    clustermgmt_path,
    dataprotection_path,
    extract_entity_ext_id_from_task,
    extract_etag,
    extract_ips_from_nics,
    extract_task_completion_detail,
    extract_task_ext_id,
    extract_vm_disk_ext_id,
    gib_to_bytes,
    networking_path,
    microseg_path,
    prism_path,
    volumes_path,
    vmm_path,
)
from libcloud.common.types import LibcloudError
from libcloud.compute.base import (
    Node,
    NodeDriver,
    NodeImage,
    NodeLocation,
    NodeSize,
    StorageVolume,
    VolumeSnapshot,
)
from libcloud.compute.types import NodeState, Provider, StorageVolumeState, VolumeSnapshotState
from libcloud.utils.iso8601 import parse_date

__all__ = ["NutanixNodeDriver"]


class NutanixNodeDriver(NodeDriver):
    """
    Libcloud compute driver for Nutanix Prism Central AHV via v4 REST APIs.

    :keyword key: Prism Central username.
    :keyword secret: Prism Central password.
    :keyword host: Prism Central hostname or IP.
    :keyword port: HTTPS port (default ``9440``).
    :keyword secure: Use HTTPS (default ``True``).
    :keyword api_version: Nutanix v4 API version (default ``v4.0``).
    :keyword verify_ssl_cert: Verify TLS certificates (default ``True``).
    :keyword login_path: Optional path to the Prism Central session endpoint.
        When set, the driver performs a one-time HTTP Basic-auth login and
        reuses the returned session cookie on subsequent requests (mirrors
        ``VCloudConnection``). When ``None`` (default), per-request Basic auth
        is used.
    :keyword session_cookie: Optional pre-existing session cookie. When
        provided, the driver skips the Basic-auth login and attaches this cookie
        to every request — letting callers reuse a session (and avoid
        re-fetching the Nutanix credential from Vault on every call).
    """

    type = Provider.NUTANIX
    name = "Nutanix"
    website = "https://www.nutanix.com"
    api_name = "nutanix"
    connectionCls = NutanixConnection
    features = {"create_node": ["ssh_key"]}

    NODE_STATE_MAP = {
        "ON": NodeState.RUNNING,
        "POWERED_ON": NodeState.RUNNING,
        "OFF": NodeState.STOPPED,
        "POWERED_OFF": NodeState.STOPPED,
        "PAUSED": NodeState.PAUSED,
        "SUSPENDED": NodeState.SUSPENDED,
        "PENDING": NodeState.PENDING,
        "DELETING": NodeState.PENDING,
    }

    VOLUME_STATE_MAP = {
        "AVAILABLE": StorageVolumeState.AVAILABLE,
        "INUSE": StorageVolumeState.INUSE,
        "CREATING": StorageVolumeState.CREATING,
        "DELETING": StorageVolumeState.DELETING,
        "ERROR": StorageVolumeState.ERROR,
    }

    SNAPSHOT_STATE_MAP = {
        "COMPLETE": VolumeSnapshotState.AVAILABLE,
        "CREATING": VolumeSnapshotState.CREATING,
        "DELETING": VolumeSnapshotState.DELETING,
        "ERROR": VolumeSnapshotState.ERROR,
    }

    def __init__(
        self,
        key,
        secret=None,
        secure=True,
        host=None,
        port=None,
        api_version=DEFAULT_API_VERSION,
        verify_ssl_cert=True,
        login_path=None,
        session_cookie=None,
        **kwargs,
    ):
        self._api_version = api_version
        self.verify_ssl_cert = verify_ssl_cert
        super().__init__(
            key,
            secret,
            secure=secure,
            host=host,
            port=port,
            api_version=api_version,
            verify_ssl_cert=verify_ssl_cert,
            **kwargs,
        )
        # BaseDriver.__init__ stores api_version on the driver but does not
        # forward it to the connection, so the connection keeps its own default
        # (v4.0). Sync it here: the connection's _wait_for_task builds the task
        # polling URL from self.api_version, and it must match the version every
        # other request uses (self._api_version), otherwise task polling targets
        # the wrong /api/prism/{version}/config/tasks/... route.
        self.connection.api_version = api_version
        # Optional session-cookie authentication (see NutanixConnection).
        if login_path is not None:
            self.connection.login_path = login_path
        if session_cookie is not None:
            self.connection.session_cookie = session_cookie
        if not self.verify_ssl_cert:
            self.connection.connection.ca_cert = False

    def ex_authenticate(self):
        """Derive the Prism Central session cookie via Basic auth.

        Performs the login (if ``login_path`` is configured and no cookie has
        been cached yet) and returns the session cookie. Returns ``None`` when
        the driver is using per-request Basic auth (no ``login_path``). Callers
        can persist the returned cookie and reuse it on later instances via the
        ``session_cookie`` keyword, avoiding a fresh Vault lookup per request.
        """
        self.connection._get_auth_token()
        return self.connection.session_cookie

    def list_nodes(self, **kwargs):
        path = vmm_path(self._api_version, "ahv/config/vms")
        params = self._build_list_params(kwargs)
        page_size = kwargs.get("ex_page_size", DEFAULT_PAGE_SIZE)
        start_page = kwargs.get("ex_page", 0)
        max_records = kwargs.get("ex_limit")

        if max_records is not None:
            params["$limit"] = min(page_size, max_records)
            params["$page"] = start_page
            response = self.connection._request("GET", path, params=params)
            data = response.object.get("data", [])
            vms = data if isinstance(data, list) else [data]
            return [self._to_node(vm) for vm in vms[:max_records]]

        vms = self.connection._paged_request(
            path,
            limit=page_size,
            page=start_page,
            params=params,
        )
        return [self._to_node(vm) for vm in vms]

    def list_images(self, location=None, **kwargs):
        path = vmm_path(self._api_version, "content/images")
        params = self._build_list_params(kwargs)
        images = self.connection._paged_request(
            path,
            limit=kwargs.get("ex_page_size", DEFAULT_PAGE_SIZE),
            page=kwargs.get("ex_page", 0),
            params=params,
        )
        return [self._to_image(img) for img in images]

    def get_image(self, image_id):
        path = vmm_path(self._api_version, "content/images/%s" % image_id)
        response = self.connection._request("GET", path)
        data = response.object.get("data")
        if not data:
            raise LibcloudError("Image %s not found" % image_id, driver=self)
        return self._to_image(data)

    def create_image(self, node, name, description=None, **kwargs):
        disk_ext_id = kwargs.get("ex_disk_ext_id")
        if not disk_ext_id and node:
            path = vmm_path(self._api_version, "ahv/config/vms/%s" % node.id)
            response = self.connection._request("GET", path)
            vm_json = response.object.get("data") or {}
            disk_index = kwargs.get("ex_disk_index", 0)
            disk_ext_id = extract_vm_disk_ext_id(vm_json, disk_index=disk_index)

        if not disk_ext_id:
            raise LibcloudError(
                "create_image requires a VM disk; pass ex_disk_ext_id or ensure "
                "the node has disks",
                driver=self,
            )

        source = build_image_vm_disk_source(disk_ext_id)
        return self._create_image_resource(
            name=name,
            source=source,
            description=description,
            image_type=kwargs.get("ex_image_type", "DISK_IMAGE"),
            cluster_ext_ids=kwargs.get("ex_cluster_ext_ids"),
            category_ext_ids=kwargs.get("ex_category_ext_ids"),
            **kwargs,
        )

    def ex_create_image_from_url(self, name, url, description=None, **kwargs):
        source = build_image_url_source(
            url,
            allow_insecure_url=kwargs.get("ex_allow_insecure_url", False),
            basic_auth=kwargs.get("ex_basic_auth"),
        )
        return self._create_image_resource(
            name=name,
            source=source,
            description=description,
            image_type=kwargs.get("ex_image_type", "DISK_IMAGE"),
            cluster_ext_ids=kwargs.get("ex_cluster_ext_ids"),
            category_ext_ids=kwargs.get("ex_category_ext_ids"),
            **kwargs,
        )

    def delete_image(self, node_image, **kwargs):
        path = vmm_path(self._api_version, "content/images/%s" % node_image.id)
        etag = self._get_image_etag(node_image.id)
        headers = {"If-Match": etag} if etag else {}
        response = self.connection._request("DELETE", path, headers=headers)
        task_ext_id = extract_task_ext_id(response.object)
        if kwargs.get("ex_wait", True) and task_ext_id:
            self.connection._wait_for_task(
                task_ext_id,
                timeout=kwargs.get("ex_wait_timeout", 600),
            )
        return True

    def list_sizes(self, location=None):
        sizes = []
        for name, spec in SYNTHETIC_SIZES.items():
            sizes.append(
                NodeSize(
                    id=name,
                    name=name,
                    ram=spec["memory_mib"],
                    disk=int(spec["disk_mib"] / 1024),
                    bandwidth=None,
                    price=0.0,
                    driver=self,
                    extra={
                        "vcpus": spec["vcpus"],
                        "cores_per_vcpu": spec["cores_per_vcpu"],
                        "disk_mib": spec["disk_mib"],
                        "synthetic": True,
                    },
                )
            )
        return sizes

    def list_locations(self):
        return self.ex_list_clusters()

    def create_node(
        self,
        name,
        size,
        image,
        location=None,
        auth=None,
        **kwargs,
    ):
        cluster_ext_id = kwargs.get("ex_cluster") or (location.id if location else None)
        if not cluster_ext_id:
            raise LibcloudError(
                "create_node requires ex_cluster or location",
                driver=self,
            )

        size_extra = size.extra or {}
        num_sockets = kwargs.get("ex_vcpus", size_extra.get("vcpus", 1))
        num_cores = kwargs.get("ex_cores_per_vcpu", size_extra.get("cores_per_vcpu", 1))
        memory_mib = kwargs.get("ex_memory_mib", size.ram)
        image_ext_id = kwargs.get("ex_image_id", image.id)

        guest_customization = kwargs.get("ex_guest_customization")
        if auth is not None and hasattr(auth, "pubkey"):
            guest_customization = guest_customization or {}
            user_data = "#cloud-config\nssh_authorized_keys:\n  - %s\n" % auth.pubkey
            guest_customization.setdefault("config", {}).setdefault("cloudInitScript", {})[
                "value"
            ] = base64.b64encode(user_data.encode("utf-8")).decode("ascii")
            guest_customization["config"].setdefault("datasourceType", "CONFIG_DRIVE_V2")

        payload = build_vm_create_payload(
            name=name,
            cluster_ext_id=cluster_ext_id,
            num_sockets=num_sockets,
            num_cores_per_socket=num_cores,
            memory_mib=memory_mib,
            image_ext_id=image_ext_id,
            disk_size_mib=kwargs.get("ex_disk_size_mib", size_extra.get("disk_mib")),
            subnet_ext_id=kwargs.get("ex_subnet"),
            storage_container_ext_id=kwargs.get("ex_storage_container"),
            description=kwargs.get("ex_description"),
            categories=kwargs.get("ex_categories"),
            guest_customization=guest_customization,
            cloud_init=kwargs.get("ex_cloud_init"),
            user_data=kwargs.get("ex_user_data"),
            nics=kwargs.get("ex_nics"),
            power_on=kwargs.get("ex_power_on", True),
            assign_ip=kwargs.get("ex_assign_ip"),
            ip_address=kwargs.get("ex_ip_address"),
            ip_prefix_length=kwargs.get("ex_ip_prefix_length"),
            data_disks=kwargs.get("ex_data_disks"),
            api_version=self._api_version,
        )

        path = vmm_path(self._api_version, "ahv/config/vms")
        response = self.connection._request("POST", path, data=json.dumps(payload))

        task_ext_id = extract_task_ext_id(response.object)
        task = None
        if kwargs.get("ex_wait", True) and task_ext_id:
            task = self.connection._wait_for_task(
                task_ext_id,
                timeout=kwargs.get("ex_wait_timeout", 600),
            )

        if task_ext_id and kwargs.get("ex_wait", True) and task:
            entity_ext_id = extract_entity_ext_id_from_task(task)
            if entity_ext_id:
                return self.ex_get_node(entity_ext_id)

        return Node(
            id=task_ext_id or name,
            name=name,
            state=NodeState.PENDING,
            public_ips=[],
            private_ips=[],
            driver=self,
            extra={"task_ext_id": task_ext_id, "cluster_ext_id": cluster_ext_id},
        )

    def destroy_node(self, node, **kwargs):
        path = vmm_path(self._api_version, "ahv/config/vms/%s" % node.id)
        etag = self._get_vm_etag(node.id)
        headers = {"If-Match": etag} if etag else {}
        response = self.connection._request("DELETE", path, headers=headers)

        task_ext_id = extract_task_ext_id(response.object)
        if kwargs.get("ex_wait", True) and task_ext_id:
            self.connection._wait_for_task(
                task_ext_id,
                timeout=kwargs.get("ex_wait_timeout", 600),
            )
        return True

    def reboot_node(self, node, **kwargs):
        return self._vm_power_action(node.id, "reboot", **kwargs)

    def start_node(self, node, **kwargs):
        return self._vm_power_action(node.id, "power-on", **kwargs)

    def stop_node(self, node, **kwargs):
        return self._vm_power_action(node.id, "shutdown", **kwargs)

    def ex_get_node(self, node_id):
        path = vmm_path(self._api_version, "ahv/config/vms/%s" % node_id)
        response = self.connection._request("GET", path)
        data = response.object.get("data")
        if not data:
            raise LibcloudError("VM %s not found" % node_id, driver=self)
        return self._to_node(data)

    def ex_update_node(self, node_id, **kwargs):
        """
        Update VM attributes such as name, description, or memory.

        :param node_id: VM extId.
        :keyword name: New VM name.
        :keyword description: New VM description.
        :keyword ex_memory_mib: New memory size in MiB.
        """
        payload = {}
        if kwargs.get("name") is not None:
            payload["name"] = kwargs["name"]
        if kwargs.get("description") is not None:
            payload["description"] = kwargs["description"]
        if kwargs.get("ex_memory_mib") is not None:
            payload["memorySizeBytes"] = kwargs["ex_memory_mib"] * 1024 * 1024
        if not payload:
            raise LibcloudError("ex_update_node requires at least one field", driver=self)

        path = vmm_path(self._api_version, "ahv/config/vms/%s" % node_id)
        etag = self._get_vm_etag(node_id)
        headers = {"If-Match": etag} if etag else {}
        entity_ext_id = self._execute_async_mutation(
            "PUT",
            path,
            data=json.dumps(payload),
            headers=headers,
            **kwargs,
        )
        return self.ex_get_node(entity_ext_id or node_id)

    def ex_get_task(self, task_id):
        path = prism_path(self._api_version, "config/tasks/%s" % task_id)
        response = self.connection._request("GET", path)
        data = response.object.get("data")
        if not data:
            raise LibcloudError("Task %s not found" % task_id, driver=self)
        return data

    def ex_list_clusters(self, **kwargs):
        path = clustermgmt_path(self._api_version, "config/clusters")
        params = self._build_list_params(kwargs)
        clusters = self.connection._paged_request(
            path,
            limit=kwargs.get("ex_page_size", DEFAULT_PAGE_SIZE),
            page=kwargs.get("ex_page", 0),
            params=params,
        )
        return [self._to_location(cluster) for cluster in clusters]

    def ex_list_hosts(self, cluster_ext_id=None, **kwargs):
        """List physical hosts (nodes) managed by Prism Central.

        Mirrors the Prism Element ``get_host_details`` sample against the v4
        clustermgmt host API (CPU, memory, hypervisor, serial, model, ...).

        :param cluster_ext_id: Optional cluster extId to scope the listing to a
            single cluster (``/config/clusters/{extId}/hosts``). When omitted,
            the cluster-wide ``/config/hosts`` endpoint is used.
        :return: list of host detail dicts (see :meth:`_to_host`).
        """
        if cluster_ext_id:
            path = clustermgmt_path(
                self._api_version, "config/clusters/%s/hosts" % cluster_ext_id
            )
        else:
            path = clustermgmt_path(self._api_version, "config/hosts")
        params = self._build_list_params(kwargs)
        hosts = self.connection._paged_request(
            path,
            limit=kwargs.get("ex_page_size", DEFAULT_PAGE_SIZE),
            page=kwargs.get("ex_page", 0),
            params=params,
        )
        return [self._to_host(host) for host in hosts]

    def ex_get_host(self, host_ext_id, cluster_ext_id=None):
        """Get the details of a single physical host.

        :param host_ext_id: Host UUID.
        :param cluster_ext_id: Optional cluster extId; required only for the
            cluster-scoped host endpoint. When omitted the cluster-wide
            ``/config/hosts/{extId}`` endpoint is used.
        :return: host detail dict (see :meth:`_to_host`).
        """
        if cluster_ext_id:
            path = clustermgmt_path(
                self._api_version,
                "config/clusters/%s/hosts/%s" % (cluster_ext_id, host_ext_id),
            )
        else:
            path = clustermgmt_path(self._api_version, "config/hosts/%s" % host_ext_id)
        response = self.connection._request("GET", path)
        data = response.object.get("data")
        if not data:
            raise LibcloudError("Host %s not found" % host_ext_id, driver=self)
        return self._to_host(data)

    def ex_get_host_bmc_info(self, host_ext_id, cluster_ext_id=None):
        """Get BMC details (IP + credential status) for a host.

        The v4 clustermgmt API does not expose BIOS/BMC firmware *versions* on
        the Host entity (those were Prism Element v2 fields); the closest
        clustermgmt equivalent is this ``bmc-info`` endpoint, which returns the
        BMC IP address and credential status.

        :param host_ext_id: Host UUID.
        :param cluster_ext_id: Cluster extId. Required — the bmc-info endpoint
            is only served cluster-scoped in v4.
        :return: dict with ``bmc_ip`` and ``bmc_status`` keys.
        """
        if not cluster_ext_id:
            raise LibcloudError(
                "ex_get_host_bmc_info requires cluster_ext_id", driver=self
            )
        path = clustermgmt_path(
            self._api_version,
            "config/clusters/%s/hosts/%s/bmc-info" % (cluster_ext_id, host_ext_id),
        )
        response = self.connection._request("GET", path)
        data = response.object.get("data") or {}
        return self._to_bmc_info(data)

    def ex_list_subnets(self, **kwargs):
        path = networking_path(self._api_version, "config/subnets")
        params = self._build_list_params(kwargs)
        return self.connection._paged_request(
            path,
            limit=kwargs.get("ex_page_size", DEFAULT_PAGE_SIZE),
            page=kwargs.get("ex_page", 0),
            params=params,
        )

    def ex_get_subnet(self, subnet_id):
        path = networking_path(self._api_version, "config/subnets/%s" % subnet_id)
        response = self.connection._request("GET", path)
        data = response.object.get("data")
        if not data:
            raise LibcloudError("Subnet %s not found" % subnet_id, driver=self)
        return data

    def ex_create_subnet(
        self,
        name,
        subnet_type="VLAN",
        cluster_ext_id=None,
        vpc_ext_id=None,
        network_id=None,
        description=None,
        is_external=False,
        ip_address=None,
        prefix_length=None,
        gateway_ip=None,
        dhcp_server=None,
        ip_pool=None,
        **kwargs,
    ):
        payload = build_subnet_create_payload(
            name=name,
            subnet_type=subnet_type,
            cluster_ext_id=cluster_ext_id,
            vpc_ext_id=vpc_ext_id,
            network_id=network_id,
            description=description,
            is_external=is_external,
            ip_address=ip_address,
            prefix_length=prefix_length,
            gateway_ip=gateway_ip,
            dhcp_server=dhcp_server,
            ip_pool=ip_pool,
        )
        path = networking_path(self._api_version, "config/subnets")
        entity_ext_id = self._execute_async_mutation(
            "POST",
            path,
            data=json.dumps(payload),
            **kwargs,
        )
        if entity_ext_id:
            return self.ex_get_subnet(entity_ext_id)
        return payload

    def ex_update_subnet(self, subnet_id, **kwargs):
        payload = {}
        if kwargs.get("name") is not None:
            payload["name"] = kwargs["name"]
        if kwargs.get("description") is not None:
            payload["description"] = kwargs["description"]
        if kwargs.get("is_nat_enabled") is not None:
            payload["isNatEnabled"] = kwargs["is_nat_enabled"]
        if not payload:
            raise LibcloudError("ex_update_subnet requires at least one field", driver=self)

        path = networking_path(self._api_version, "config/subnets/%s" % subnet_id)
        entity_ext_id = self._execute_async_mutation(
            "PUT",
            path,
            data=json.dumps(payload),
            **kwargs,
        )
        return self.ex_get_subnet(entity_ext_id or subnet_id)

    def ex_delete_subnet(self, subnet_id, **kwargs):
        path = networking_path(self._api_version, "config/subnets/%s" % subnet_id)
        self._execute_async_mutation("DELETE", path, **kwargs)
        return True

    def ex_list_vpcs(self, **kwargs):
        path = networking_path(self._api_version, "config/vpcs")
        params = self._build_list_params(kwargs)
        return self.connection._paged_request(
            path,
            limit=kwargs.get("ex_page_size", DEFAULT_PAGE_SIZE),
            page=kwargs.get("ex_page", 0),
            params=params,
        )

    def ex_get_vpc(self, vpc_id):
        path = networking_path(self._api_version, "config/vpcs/%s" % vpc_id)
        response = self.connection._request("GET", path)
        data = response.object.get("data")
        if not data:
            raise LibcloudError("VPC %s not found" % vpc_id, driver=self)
        return data

    def ex_create_vpc(
        self,
        name,
        description=None,
        vpc_type="REGULAR",
        external_subnet_ext_ids=None,
        **kwargs,
    ):
        payload = build_vpc_create_payload(
            name=name,
            description=description,
            vpc_type=vpc_type,
            external_subnet_ext_ids=external_subnet_ext_ids,
        )
        path = networking_path(self._api_version, "config/vpcs")
        entity_ext_id = self._execute_async_mutation(
            "POST",
            path,
            data=json.dumps(payload),
            **kwargs,
        )
        if entity_ext_id:
            return self.ex_get_vpc(entity_ext_id)
        return {"name": name, "description": description, "vpcType": vpc_type}

    def ex_update_vpc(self, vpc_id, **kwargs):
        payload = {}
        if kwargs.get("name") is not None:
            payload["name"] = kwargs["name"]
        if kwargs.get("description") is not None:
            payload["description"] = kwargs["description"]
        if not payload:
            raise LibcloudError("ex_update_vpc requires at least one field", driver=self)

        path = networking_path(self._api_version, "config/vpcs/%s" % vpc_id)
        entity_ext_id = self._execute_async_mutation(
            "PUT",
            path,
            data=json.dumps(payload),
            **kwargs,
        )
        return self.ex_get_vpc(entity_ext_id or vpc_id)

    def ex_delete_vpc(self, vpc_id, **kwargs):
        path = networking_path(self._api_version, "config/vpcs/%s" % vpc_id)
        self._execute_async_mutation("DELETE", path, **kwargs)
        return True

    def ex_list_storage_containers(self, **kwargs):
        path = clustermgmt_path(self._api_version, "config/storage-containers")
        params = self._build_list_params(kwargs)
        return self.connection._paged_request(
            path,
            limit=kwargs.get("ex_page_size", DEFAULT_PAGE_SIZE),
            page=kwargs.get("ex_page", 0),
            params=params,
        )

    def ex_get_storage_container(self, container_id):
        path = clustermgmt_path(
            self._api_version,
            "config/storage-containers/%s" % container_id,
        )
        response = self.connection._request("GET", path)
        data = response.object.get("data")
        if not data:
            raise LibcloudError(
                "Storage container %s not found" % container_id,
                driver=self,
            )
        return data

    def ex_list_storage_containers_vmm(self, **kwargs):
        """Back-compat alias; storage containers live in the clustermgmt namespace."""
        return self.ex_list_storage_containers(**kwargs)

    def ex_get_storage_container_vmm(self, container_id):
        """Back-compat alias; storage containers live in the clustermgmt namespace."""
        return self.ex_get_storage_container(container_id)

    def ex_list_templates(self, **kwargs):
        path = vmm_path(self._api_version, "content/templates")
        params = self._build_list_params(kwargs)
        return self.connection._paged_request(
            path,
            limit=kwargs.get("ex_page_size", DEFAULT_PAGE_SIZE),
            page=kwargs.get("ex_page", 0),
            params=params,
        )

    def ex_list_security_groups(self, **kwargs):
        path = microseg_path(self._api_version, "config/policies")
        params = self._build_list_params(kwargs)
        return self.connection._paged_request(
            path,
            limit=kwargs.get("ex_page_size", DEFAULT_PAGE_SIZE),
            page=kwargs.get("ex_page", 0),
            params=params,
        )

    def ex_get_security_group(self, policy_id):
        path = microseg_path(
            self._api_version,
            "config/policies/%s" % policy_id,
        )
        response = self.connection._request("GET", path)
        data = response.object.get("data")
        if not data:
            raise LibcloudError(
                "Security policy %s not found" % policy_id,
                driver=self,
            )
        return data

    def ex_create_security_group(
        self,
        name,
        description=None,
        policy_type="APPLICATION",
        **kwargs,
    ):
        payload = {
            "name": name,
            "type": policy_type,
            "state": kwargs.get("state", "SAVE"),
        }
        if description:
            payload["description"] = description
        if kwargs.get("vpc_ext_id"):
            payload["vpcReferences"] = [kwargs["vpc_ext_id"]]
        if kwargs.get("rules"):
            payload["rules"] = kwargs["rules"]

        path = microseg_path(self._api_version, "config/policies")
        entity_ext_id = self._execute_async_mutation(
            "POST",
            path,
            data=json.dumps(payload),
            **kwargs,
        )
        if entity_ext_id:
            return self.ex_get_security_group(entity_ext_id)
        return payload

    def ex_delete_security_group(self, policy_id, **kwargs):
        path = microseg_path(
            self._api_version,
            "config/policies/%s" % policy_id,
        )
        self._execute_async_mutation("DELETE", path, **kwargs)
        return True

    def ex_list_load_balancers(self, **kwargs):
        """List floating IPs as simple load-balancer VIP frontends."""
        path = networking_path(self._api_version, "config/floating-ips")
        params = self._build_list_params(kwargs)
        return self.connection._paged_request(
            path,
            limit=kwargs.get("ex_page_size", DEFAULT_PAGE_SIZE),
            page=kwargs.get("ex_page", 0),
            params=params,
        )

    def ex_get_load_balancer(self, floating_ip_id):
        path = networking_path(
            self._api_version,
            "config/floating-ips/%s" % floating_ip_id,
        )
        response = self.connection._request("GET", path)
        data = response.object.get("data")
        if not data:
            raise LibcloudError(
                "Floating IP %s not found" % floating_ip_id,
                driver=self,
            )
        return data

    def ex_create_load_balancer(
        self,
        name,
        vpc_ext_id,
        external_ip=None,
        **kwargs,
    ):
        payload = {
            "name": name,
            "vpcReference": vpc_ext_id,
        }
        if external_ip:
            payload["floatingIp"] = {"ipv4": {"value": external_ip}}

        path = networking_path(self._api_version, "config/floating-ips")
        response = self.connection._request("POST", path, data=json.dumps(payload))
        task_ext_id = extract_task_ext_id(response.object)
        entity_ext_id = None
        if kwargs.get("ex_wait", True) and task_ext_id:
            task = self.connection._wait_for_task(
                task_ext_id,
                timeout=kwargs.get("ex_wait_timeout", 600),
            )
            entity_ext_id = extract_entity_ext_id_from_task(task)
        if entity_ext_id:
            return self.ex_get_load_balancer(entity_ext_id)
        return payload

    def ex_delete_load_balancer(self, floating_ip_id, **kwargs):
        path = networking_path(
            self._api_version,
            "config/floating-ips/%s" % floating_ip_id,
        )
        self._execute_async_mutation("DELETE", path, **kwargs)
        return True

    def list_volumes(self, **kwargs):
        path = volumes_path(self._api_version, "config/volume-groups")
        params = self._build_list_params(kwargs)
        volume_groups = self.connection._paged_request(
            path,
            limit=kwargs.get("ex_page_size", DEFAULT_PAGE_SIZE),
            page=kwargs.get("ex_page", 0),
            params=params,
        )
        return [self._to_volume(volume_group) for volume_group in volume_groups]

    def create_volume(self, size, name, location=None, snapshot=None, **kwargs):
        cluster_ext_id = kwargs.get("ex_cluster") or (location.id if location else None)
        if not cluster_ext_id:
            raise LibcloudError(
                "create_volume requires ex_cluster or location",
                driver=self,
            )

        disk_data_source_reference = None
        if snapshot is not None:
            disk_data_source_reference = {
                "extId": snapshot.extra.get("volume_group_recovery_point_ext_id") or snapshot.id,
                "entityType": "VOLUME_GROUP_RECOVERY_POINT",
            }

        payload = build_volume_group_create_payload(
            name=name,
            cluster_ext_id=cluster_ext_id,
            disk_size_bytes=gib_to_bytes(size),
            disk_index=kwargs.get("ex_disk_index", 0),
            storage_container_ext_id=kwargs.get("ex_storage_container"),
            description=kwargs.get("ex_description"),
            disk_data_source_reference=disk_data_source_reference,
        )

        path = volumes_path(self._api_version, "config/volume-groups")
        response = self.connection._request("POST", path, data=json.dumps(payload))
        task_ext_id = extract_task_ext_id(response.object)
        volume_ext_id = None

        if kwargs.get("ex_wait", True) and task_ext_id:
            task = self.connection._wait_for_task(
                task_ext_id,
                timeout=kwargs.get("ex_wait_timeout", 600),
            )
            volume_ext_id = extract_entity_ext_id_from_task(task)

        if volume_ext_id:
            return self.ex_get_volume(volume_ext_id)

        return StorageVolume(
            id=task_ext_id or name,
            name=name,
            size=size,
            driver=self,
            state=StorageVolumeState.CREATING,
            extra={
                "task_ext_id": task_ext_id,
                "cluster_ext_id": cluster_ext_id,
            },
        )

    def destroy_volume(self, volume, **kwargs):
        path = volumes_path(
            self._api_version,
            "config/volume-groups/%s" % volume.id,
        )
        etag = self._get_volume_group_etag(volume.id)
        headers = {"If-Match": etag} if etag else {}
        response = self.connection._request("DELETE", path, headers=headers)
        task_ext_id = extract_task_ext_id(response.object)
        if kwargs.get("ex_wait", True) and task_ext_id:
            self.connection._wait_for_task(
                task_ext_id,
                timeout=kwargs.get("ex_wait_timeout", 600),
            )
        return True

    def attach_volume(self, node, volume, device=None, **kwargs):
        payload = {"extId": node.id}
        if device is not None:
            try:
                payload["index"] = int(device)
            except (TypeError, ValueError):
                raise LibcloudError(
                    "device must be an integer SCSI bus index for Nutanix volumes",
                    driver=self,
                )

        path = volumes_path(
            self._api_version,
            "config/volume-groups/%s/$actions/attach-vm" % volume.id,
        )
        response = self.connection._request("POST", path, data=json.dumps(payload))
        task_ext_id = extract_task_ext_id(response.object)
        if kwargs.get("ex_wait", True) and task_ext_id:
            self.connection._wait_for_task(
                task_ext_id,
                timeout=kwargs.get("ex_wait_timeout", 600),
            )

        if volume.extra is None:
            volume.extra = {}
        volume.extra["attached_vm_ext_id"] = node.id
        volume.state = StorageVolumeState.INUSE
        return True

    def detach_volume(self, volume, **kwargs):
        vm_ext_id = kwargs.get("ex_vm_ext_id") or (volume.extra or {}).get("attached_vm_ext_id")
        if not vm_ext_id:
            attachments = self._list_volume_vm_attachments(volume.id)
            if len(attachments) == 1:
                vm_ext_id = attachments[0].get("extId")
            else:
                raise LibcloudError(
                    "detach_volume requires ex_vm_ext_id when the volume has "
                    "zero or multiple VM attachments",
                    driver=self,
                )

        payload = {"extId": vm_ext_id}
        path = volumes_path(
            self._api_version,
            "config/volume-groups/%s/$actions/detach-vm" % volume.id,
        )
        response = self.connection._request("POST", path, data=json.dumps(payload))
        task_ext_id = extract_task_ext_id(response.object)
        if kwargs.get("ex_wait", True) and task_ext_id:
            self.connection._wait_for_task(
                task_ext_id,
                timeout=kwargs.get("ex_wait_timeout", 600),
            )

        if volume.extra and volume.extra.get("attached_vm_ext_id") == vm_ext_id:
            volume.extra.pop("attached_vm_ext_id", None)
        volume.state = StorageVolumeState.AVAILABLE
        return True

    def create_volume_snapshot(self, volume, name=None, **kwargs):
        snapshot_name = name or "snapshot-%s" % volume.name
        payload = build_recovery_point_create_payload(snapshot_name, volume.id)
        path = dataprotection_path(self._api_version, "config/recovery-points")
        response = self.connection._request("POST", path, data=json.dumps(payload))
        task_ext_id = extract_task_ext_id(response.object)
        recovery_point_ext_id = None

        if kwargs.get("ex_wait", True) and task_ext_id:
            task = self.connection._wait_for_task(
                task_ext_id,
                timeout=kwargs.get("ex_wait_timeout", 600),
            )
            recovery_point_ext_id = extract_task_completion_detail(task, "recoveryPointExtId")
            if not recovery_point_ext_id:
                recovery_point_ext_id = extract_entity_ext_id_from_task(task)

        if recovery_point_ext_id:
            return self.ex_get_volume_snapshot(recovery_point_ext_id, volume=volume)

        return VolumeSnapshot(
            id=task_ext_id or snapshot_name,
            driver=self,
            size=volume.size,
            state=VolumeSnapshotState.CREATING,
            name=snapshot_name,
            extra={
                "task_ext_id": task_ext_id,
                "volume_group_ext_id": volume.id,
            },
        )

    def list_volume_snapshots(self, volume, **kwargs):
        path = dataprotection_path(self._api_version, "config/recovery-points")
        params = self._build_list_params(kwargs)
        params["$filter"] = kwargs.get("ex_filter") or (
            "volumeGroupRecoveryPoints/any(vg: vg/volumeGroupExtId eq '%s')" % volume.id
        )
        recovery_points = self.connection._paged_request(
            path,
            limit=kwargs.get("ex_page_size", DEFAULT_PAGE_SIZE),
            page=kwargs.get("ex_page", 0),
            params=params,
        )
        return [
            self._to_volume_snapshot(recovery_point, volume=volume)
            for recovery_point in recovery_points
        ]

    def destroy_volume_snapshot(self, snapshot, **kwargs):
        path = dataprotection_path(
            self._api_version,
            "config/recovery-points/%s" % snapshot.id,
        )
        etag = self._get_recovery_point_etag(snapshot.id)
        headers = {"If-Match": etag} if etag else {}
        response = self.connection._request("DELETE", path, headers=headers)
        task_ext_id = extract_task_ext_id(response.object)
        if kwargs.get("ex_wait", True) and task_ext_id:
            self.connection._wait_for_task(
                task_ext_id,
                timeout=kwargs.get("ex_wait_timeout", 600),
            )
        return True

    def ex_get_volume(self, volume_id):
        path = volumes_path(self._api_version, "config/volume-groups/%s" % volume_id)
        response = self.connection._request("GET", path)
        data = response.object.get("data")
        if not data:
            raise LibcloudError("Volume group %s not found" % volume_id, driver=self)
        disks = self._list_volume_disks(volume_id)
        attachments = self._list_volume_vm_attachments(volume_id)
        return self._to_volume(data, disks=disks, vm_attachments=attachments)

    def ex_get_volume_snapshot(self, recovery_point_id, volume=None):
        path = dataprotection_path(
            self._api_version,
            "config/recovery-points/%s" % recovery_point_id,
        )
        response = self.connection._request("GET", path)
        data = response.object.get("data")
        if not data:
            raise LibcloudError(
                "Recovery point %s not found" % recovery_point_id,
                driver=self,
            )
        return self._to_volume_snapshot(data, volume=volume)

    def ex_list_volume_vm_attachments(self, volume_group_id, **kwargs):
        path = volumes_path(
            self._api_version,
            "config/volume-groups/%s/vm-attachments" % volume_group_id,
        )
        params = self._build_list_params(kwargs)
        return self.connection._paged_request(
            path,
            limit=kwargs.get("ex_page_size", DEFAULT_PAGE_SIZE),
            page=kwargs.get("ex_page", 0),
            params=params,
        )

    def _execute_async_mutation(self, method, path, data=None, headers=None, **kwargs):
        response = self.connection._request(method, path, data=data, headers=headers)
        task_ext_id = extract_task_ext_id(response.object)
        if kwargs.get("ex_wait", True) and task_ext_id:
            task = self.connection._wait_for_task(
                task_ext_id,
                timeout=kwargs.get("ex_wait_timeout", 600),
            )
            return extract_entity_ext_id_from_task(task)
        return None

    def _vm_power_action(self, node_id, action, **kwargs):
        etag = self._get_vm_etag(node_id)
        headers = {"If-Match": etag} if etag else {}
        path = vmm_path(
            self._api_version,
            "ahv/config/vms/%s/$actions/%s" % (node_id, action),
        )
        response = self.connection._request("POST", path, data="{}", headers=headers)
        task_ext_id = extract_task_ext_id(response.object)
        if kwargs.get("ex_wait", True) and task_ext_id:
            self.connection._wait_for_task(
                task_ext_id,
                timeout=kwargs.get("ex_wait_timeout", 600),
            )
        return True

    def _get_vm_etag(self, node_id):
        path = vmm_path(self._api_version, "ahv/config/vms/%s" % node_id)
        response = self.connection._request("GET", path)
        headers = getattr(response, "headers", {}) or {}
        return extract_etag(headers)

    def _get_volume_group_etag(self, volume_group_id):
        path = volumes_path(
            self._api_version,
            "config/volume-groups/%s" % volume_group_id,
        )
        response = self.connection._request("GET", path)
        headers = getattr(response, "headers", {}) or {}
        return extract_etag(headers)

    def _get_recovery_point_etag(self, recovery_point_id):
        path = dataprotection_path(
            self._api_version,
            "config/recovery-points/%s" % recovery_point_id,
        )
        response = self.connection._request("GET", path)
        headers = getattr(response, "headers", {}) or {}
        return extract_etag(headers)

    def _get_image_etag(self, image_id):
        path = vmm_path(self._api_version, "content/images/%s" % image_id)
        response = self.connection._request("GET", path)
        headers = getattr(response, "headers", {}) or {}
        return extract_etag(headers)

    def _create_image_resource(
        self,
        name,
        source,
        description=None,
        image_type="DISK_IMAGE",
        cluster_ext_ids=None,
        category_ext_ids=None,
        **kwargs,
    ):
        payload = build_image_create_payload(
            name=name,
            image_type=image_type,
            source=source,
            description=description,
            cluster_ext_ids=cluster_ext_ids,
            category_ext_ids=category_ext_ids,
        )
        path = vmm_path(self._api_version, "content/images")
        response = self.connection._request("POST", path, data=json.dumps(payload))
        task_ext_id = extract_task_ext_id(response.object)
        image_ext_id = None

        if kwargs.get("ex_wait", True) and task_ext_id:
            task = self.connection._wait_for_task(
                task_ext_id,
                timeout=kwargs.get("ex_wait_timeout", 600),
            )
            image_ext_id = extract_task_completion_detail(task, "imageExtId")
            if not image_ext_id:
                image_ext_id = extract_entity_ext_id_from_task(task)

        if image_ext_id:
            return self.get_image(image_ext_id)

        return NodeImage(
            id=task_ext_id or name,
            name=name,
            driver=self,
            extra={
                "task_ext_id": task_ext_id,
                "description": description,
                "image_type": image_type,
            },
        )

    def _list_volume_disks(self, volume_group_id, **kwargs):
        path = volumes_path(
            self._api_version,
            "config/volume-groups/%s/disks" % volume_group_id,
        )
        params = self._build_list_params(kwargs)
        return self.connection._paged_request(
            path,
            limit=kwargs.get("ex_page_size", DEFAULT_PAGE_SIZE),
            page=kwargs.get("ex_page", 0),
            params=params,
        )

    def _list_volume_vm_attachments(self, volume_group_id, **kwargs):
        return self.ex_list_volume_vm_attachments(volume_group_id, **kwargs)

    def _build_list_params(self, kwargs):
        params = {}
        if kwargs.get("ex_filter"):
            params["$filter"] = kwargs["ex_filter"]
        if kwargs.get("ex_select"):
            params["$select"] = kwargs["ex_select"]
        if kwargs.get("ex_orderby"):
            params["$orderby"] = kwargs["ex_orderby"]
        return params

    def _to_node(self, vm_json):
        ext_id = vm_json.get("extId") or vm_json.get("uuid") or ""
        name = vm_json.get("name") or ext_id
        power_state = vm_json.get("powerState") or ""
        state = self.NODE_STATE_MAP.get(str(power_state).upper(), NodeState.UNKNOWN)

        public_ips, private_ips = extract_ips_from_nics(vm_json.get("nics"))

        created_at = None
        if vm_json.get("createTime"):
            try:
                created_at = parse_date(vm_json["createTime"])
            except Exception:
                created_at = None

        cluster = vm_json.get("cluster") or {}
        extra = {
            "cluster_ext_id": cluster.get("extId"),
            "power_state": power_state,
            "nics": vm_json.get("nics"),
            "disks": vm_json.get("disks"),
            "categories": vm_json.get("categories"),
            "description": vm_json.get("description"),
            "creation_time": vm_json.get("createTime"),
            "owner_reference": vm_json.get("ownershipInfo"),
            "num_sockets": vm_json.get("numSockets"),
            "num_cores_per_socket": vm_json.get("numCoresPerSocket"),
            "memory_size_bytes": vm_json.get("memorySizeBytes"),
            "memory_mib": (
                bytes_to_mib(vm_json["memorySizeBytes"])
                if vm_json.get("memorySizeBytes")
                else None
            ),
        }

        return Node(
            id=ext_id,
            name=name,
            state=state,
            public_ips=public_ips,
            private_ips=private_ips,
            driver=self,
            created_at=created_at,
            extra=extra,
        )

    def _to_image(self, image_json):
        ext_id = image_json.get("extId") or ""
        name = image_json.get("name") or ext_id
        size_bytes = image_json.get("sizeBytes")
        image_type = image_json.get("type") or image_json.get("imageType")
        source = image_json.get("source") or {}
        extra = {
            "description": image_json.get("description"),
            "image_type": image_type,
            "cluster_ext_ids": image_json.get("clusterExtIds")
            or image_json.get("clusterLocationExtIds"),
            "size_bytes": size_bytes,
            "create_time": image_json.get("createTime"),
            "update_time": image_json.get("updateTime") or image_json.get("lastUpdateTime"),
            "source": source,
            "checksum": image_json.get("checksum"),
            "owner_ext_id": image_json.get("ownerExtId"),
        }
        return NodeImage(id=ext_id, name=name, driver=self, extra=extra)

    def _to_location(self, cluster_json):
        ext_id = cluster_json.get("extId") or ""
        name = cluster_json.get("name") or ext_id
        extra = {
            "cluster_type": cluster_json.get("clusterType"),
            "hypervisor_types": cluster_json.get("config", {}).get("hypervisorTypes"),
            "aos_version": cluster_json.get("aosVersion"),
            "num_nodes": cluster_json.get("numNodes"),
        }
        return NodeLocation(
            id=ext_id,
            name=name,
            country=None,
            driver=self,
            extra=extra,
        )

    def _to_host(self, host_json):
        """Normalize a clustermgmt v4 ``Host`` entity into a flat dict.

        Field names mirror the v4 clustermgmt Host schema (camelCase) but are
        normalized to snake_case for stable consumption by the REST layer and
        portal, matching the ``get_host_details`` sample fields (CPU threads,
        memory, hypervisor, serial) plus the v4 additions (block model, GPU,
        node status).
        """
        ext_id = host_json.get("extId") or ""
        name = host_json.get("hostName") or ext_id
        hypervisor = host_json.get("hypervisor") or {}
        cluster = host_json.get("cluster") or {}
        memory_bytes = host_json.get("memorySizeBytes")
        return {
            "id": ext_id,
            "name": name,
            "host_type": host_json.get("hostType"),
            "hypervisor": hypervisor.get("fullName") or hypervisor.get("type"),
            "hypervisor_type": hypervisor.get("type"),
            "number_of_vms": hypervisor.get("numberOfVms"),
            "cluster_name": cluster.get("name"),
            "cluster_ext_id": cluster.get("uuid") or cluster.get("extId"),
            "num_cpu_cores": host_json.get("numberOfCpuCores"),
            "num_cpu_threads": host_json.get("numberOfCpuThreads"),
            "num_cpu_sockets": host_json.get("numberOfCpuSockets"),
            "cpu_capacity_hz": host_json.get("cpuCapacityHz"),
            "cpu_frequency_hz": host_json.get("cpuFrequencyHz"),
            "cpu_model": host_json.get("cpuModel"),
            "memory_size_bytes": memory_bytes,
            "memory_gib": bytes_to_gib(memory_bytes) if memory_bytes else None,
            "block_serial": host_json.get("blockSerial"),
            "block_model": host_json.get("blockModel"),
            "gpu_driver_version": host_json.get("gpuDriverVersion"),
            "gpu_list": host_json.get("gpuList"),
            "node_status": host_json.get("nodeStatus"),
            "maintenance_state": host_json.get("maintenanceState"),
            "is_degraded": host_json.get("isDegraded"),
            "is_secure_booted": host_json.get("isSecureBooted"),
            "boot_time_usecs": host_json.get("bootTimeUsecs"),
            "rackable_unit_uuid": host_json.get("rackableUnitUuid"),
        }

    def _to_bmc_info(self, bmc_json):
        """Normalize a clustermgmt v4 ``BmcInfo`` entity into a flat dict.

        Returns the BMC IP and credential status; the BMC username/password
        (``credential``) is intentionally not exposed.
        """
        ip_address = bmc_json.get("ipAddress") or {}
        ipv4 = (ip_address.get("ipv4") or {}).get("value")
        ipv6 = (ip_address.get("ipv6") or {}).get("value")
        return {
            "bmc_ip": ipv4 or ipv6,
            "bmc_status": bmc_json.get("status"),
        }

    def _to_volume(self, volume_group_json, disks=None, vm_attachments=None):
        ext_id = volume_group_json.get("extId") or ""
        name = volume_group_json.get("name") or ext_id

        if disks is None:
            disks = volume_group_json.get("disks")
            if disks is None and ext_id:
                disks = self._list_volume_disks(ext_id)
        if vm_attachments is None:
            vm_attachments = volume_group_json.get("vmAttachments")
            if vm_attachments is None and ext_id:
                vm_attachments = self._list_volume_vm_attachments(ext_id)

        disks = disks or []
        vm_attachments = vm_attachments or []

        total_bytes = 0
        for disk in disks:
            total_bytes += disk.get("diskSizeBytes") or 0

        attached_vm_ext_ids = []
        for attachment in vm_attachments:
            vm_ext_id = attachment.get("extId")
            if vm_ext_id:
                attached_vm_ext_ids.append(vm_ext_id)

        state = (
            StorageVolumeState.INUSE
            if attached_vm_ext_ids
            else StorageVolumeState.AVAILABLE
        )
        mapped_state = self.VOLUME_STATE_MAP.get(
            str(volume_group_json.get("status", "")).upper()
        )
        if mapped_state:
            state = mapped_state

        extra = {
            "cluster_ext_id": volume_group_json.get("clusterReference"),
            "description": volume_group_json.get("description"),
            "disks": disks,
            "vm_attachments": vm_attachments,
            "attached_vm_ext_id": attached_vm_ext_ids[0] if len(attached_vm_ext_ids) == 1 else None,
            "attached_vm_ext_ids": attached_vm_ext_ids,
            "sharing_status": volume_group_json.get("sharingStatus"),
            "usage_type": volume_group_json.get("usageType"),
            "attachment_type": volume_group_json.get("attachmentType"),
            "protocol": volume_group_json.get("protocol"),
            "size_bytes": total_bytes,
        }

        return StorageVolume(
            id=ext_id,
            name=name,
            size=bytes_to_gib(total_bytes) if total_bytes else 0,
            driver=self,
            state=state,
            extra=extra,
        )

    def _to_volume_snapshot(self, recovery_point_json, volume=None):
        ext_id = recovery_point_json.get("extId") or ""
        name = recovery_point_json.get("name") or ext_id
        status = str(recovery_point_json.get("status") or "").upper()
        state = self.SNAPSHOT_STATE_MAP.get(status, VolumeSnapshotState.UNKNOWN)

        created_at = None
        if recovery_point_json.get("creationTime"):
            try:
                created_at = parse_date(recovery_point_json["creationTime"])
            except Exception:
                created_at = None

        volume_group_recovery_points = recovery_point_json.get("volumeGroupRecoveryPoints") or []
        volume_group_recovery_point = (
            volume_group_recovery_points[0] if volume_group_recovery_points else {}
        )

        extra = {
            "volume_group_ext_id": volume_group_recovery_point.get("volumeGroupExtId"),
            "volume_group_recovery_point_ext_id": volume_group_recovery_point.get("extId"),
            "status": status,
            "recovery_point_type": recovery_point_json.get("recoveryPointType"),
            "expiration_time": recovery_point_json.get("expirationTime"),
            "location_references": recovery_point_json.get("locationReferences"),
        }

        return VolumeSnapshot(
            id=ext_id,
            driver=self,
            size=volume.size if volume else None,
            created=created_at,
            state=state,
            name=name,
            extra=extra,
        )
