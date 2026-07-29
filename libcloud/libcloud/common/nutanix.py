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
Common connection and helper utilities for Nutanix Prism Central v4 REST APIs.
"""

from __future__ import annotations

import base64
import json
import time
import uuid
from typing import Any, Dict, List, Optional, Tuple

from libcloud.common.base import ConnectionUserAndKey, JsonResponse
from libcloud.common.types import InvalidCredsError, LibcloudError

__all__ = [
    "NutanixResponse",
    "NutanixConnection",
    "DEFAULT_API_VERSION",
    "DEFAULT_PAGE_SIZE",
    "MAX_PAGE_SIZE",
    "SYNTHETIC_SIZES",
    "api_path",
    "vmm_path",
    "clustermgmt_path",
    "networking_path",
    "prism_path",
    "volumes_path",
    "dataprotection_path",
    "new_request_id",
    "build_vm_create_payload",
    "build_volume_group_create_payload",
    "build_recovery_point_create_payload",
    "build_image_create_payload",
    "build_image_url_source",
    "build_image_vm_disk_source",
    "build_vpc_create_payload",
    "build_subnet_create_payload",
    "extract_task_ext_id",
    "extract_etag",
    "extract_entity_ext_id_from_task",
    "extract_task_completion_detail",
    "extract_ips_from_nics",
    "mib_to_bytes",
    "bytes_to_mib",
    "gib_to_bytes",
    "bytes_to_gib",
]

NS_VMM = "vmm"
NS_CLUSTERMGMT = "clustermgmt"
NS_NETWORKING = "networking"
NS_PRISM = "prism"
NS_VOLUMES = "volumes"
NS_DATAPROTECTION = "dataprotection"

DEFAULT_API_VERSION = "v4.0"
DEFAULT_PAGE_SIZE = 100
MAX_PAGE_SIZE = 100

SYNTHETIC_SIZES = {
    "small": {"vcpus": 1, "cores_per_vcpu": 1, "memory_mib": 2048, "disk_mib": 20480},
    "medium": {"vcpus": 2, "cores_per_vcpu": 1, "memory_mib": 4096, "disk_mib": 51200},
    "large": {"vcpus": 4, "cores_per_vcpu": 1, "memory_mib": 8192, "disk_mib": 102400},
    "xlarge": {"vcpus": 8, "cores_per_vcpu": 1, "memory_mib": 16384, "disk_mib": 204800},
}

TASK_SUCCESS_STATUSES = {"SUCCEEDED"}
TASK_FAILURE_STATUSES = {"FAILED", "CANCELED", "CANCELLED", "ABORTED"}
TASK_PENDING_STATUSES = {"RUNNING", "QUEUED", "PENDING"}


class NutanixResponse(JsonResponse):
    """
    Map Nutanix v4 HTTP failures to Libcloud exceptions.
    """

    def parse_error(self):
        body = self.parse_body()
        message = self._extract_error_message(body)
        status = self.status

        if status in (401, 403):
            raise InvalidCredsError(message)
        if status == 404:
            raise LibcloudError(message, driver=self.connection.driver)
        if status == 409:
            raise LibcloudError("Conflict: %s" % message, driver=self.connection.driver)
        if status == 422:
            raise LibcloudError("Validation error: %s" % message, driver=self.connection.driver)
        if status == 428:
            raise LibcloudError("Precondition required: %s" % message, driver=self.connection.driver)
        if status == 429:
            raise LibcloudError("Rate limit exceeded: %s" % message, driver=self.connection.driver)
        if status >= 500:
            raise LibcloudError("Server error: %s" % message, driver=self.connection.driver)

        raise LibcloudError(message, driver=self.connection.driver)

    def _extract_error_message(self, body):
        if isinstance(body, dict):
            data = body.get("data")
            if isinstance(data, dict):
                if data.get("message"):
                    return str(data["message"])
                errors = data.get("error")
                if isinstance(errors, list) and errors:
                    parts = []
                    for err in errors:
                        if isinstance(err, dict):
                            parts.append(err.get("message") or err.get("code") or str(err))
                        else:
                            parts.append(str(err))
                    return "; ".join(parts)
            metadata = body.get("metadata")
            if isinstance(metadata, dict) and metadata.get("message"):
                return str(metadata["message"])
            return json.dumps(body)
        return str(body)


class NutanixConnection(ConnectionUserAndKey):
    """
    HTTPS connection to Nutanix Prism Central using HTTP Basic authentication.

    Libcloud passes ``key`` as the username and ``secret`` as the password.
    """

    host = "localhost"
    port = 9440
    responseCls = NutanixResponse

    def __init__(
        self,
        user_id,
        key,
        secure=True,
        host=None,
        port=None,
        url=None,
        timeout=None,
        proxy_url=None,
        backoff=None,
        retry_delay=None,
        api_version=DEFAULT_API_VERSION,
        verify_ssl_cert=True,
    ):
        if port is None:
            port = self.port
        super().__init__(
            user_id,
            key,
            secure=secure,
            host=host,
            port=port,
            url=url,
            timeout=timeout,
            proxy_url=proxy_url,
            backoff=backoff,
            retry_delay=retry_delay,
        )
        self.api_version = api_version
        self.verify_ssl_cert = verify_ssl_cert

    def add_default_headers(self, headers):
        credentials = base64.b64encode(("%s:%s" % (self.user_id, self.key)).encode("utf-8")).decode(
            "ascii"
        )
        headers["Authorization"] = "Basic %s" % credentials
        headers["Accept"] = "application/json"
        headers["Content-Type"] = "application/json"
        headers.setdefault("NTNX-Request-Id", new_request_id())
        return headers

    def _request(self, method, path, params=None, data=None, headers=None):
        extra_headers = headers or {}
        return self.request(
            path,
            method=method,
            params=params,
            data=data,
            headers=extra_headers,
        )

    def _paged_request(
        self,
        path,
        limit=DEFAULT_PAGE_SIZE,
        page=0,
        params=None,
        max_pages=None,
    ):
        limit = min(max(limit, 1), MAX_PAGE_SIZE)
        query = dict(params or {})
        query["$limit"] = limit

        results = []
        current_page = page
        pages_fetched = 0

        while True:
            query["$page"] = current_page
            response = self._request("GET", path, params=query)
            body = response.object
            data = body.get("data") if isinstance(body, dict) else None

            if not data:
                break

            if isinstance(data, list):
                results.extend(data)
                if len(data) < limit:
                    break
            else:
                results.append(data)
                break

            current_page += 1
            pages_fetched += 1
            if max_pages is not None and pages_fetched >= max_pages:
                break

        return results

    def _wait_for_task(self, task_ext_id, timeout=600, interval=2.0):
        path = prism_path(self.api_version, "config/tasks/%s" % task_ext_id)
        deadline = time.time() + timeout

        while time.time() < deadline:
            response = self._request("GET", path)
            body = response.object
            task = body.get("data") if isinstance(body, dict) else {}
            status = (task.get("status") or "").upper()

            if status in TASK_SUCCESS_STATUSES:
                return task
            if status in TASK_FAILURE_STATUSES:
                errors = task.get("errorMessages") or []
                raise LibcloudError(
                    "Task %s failed with status %s: %s" % (task_ext_id, status, errors),
                    driver=self.driver,
                )
            if status not in TASK_PENDING_STATUSES and status:
                return task

            time.sleep(interval)

        raise LibcloudError(
            "Timed out waiting for task %s" % task_ext_id,
            driver=self.driver,
        )

    def encode_data(self, data):
        if data is None:
            return ""
        if isinstance(data, str):
            return data
        return json.dumps(data)


def api_path(namespace, api_version, resource_path):
    resource_path = resource_path.lstrip("/")
    return "/api/%s/%s/%s" % (namespace, api_version, resource_path)


def vmm_path(api_version, resource_path):
    return api_path(NS_VMM, api_version, resource_path)


def clustermgmt_path(api_version, resource_path):
    return api_path(NS_CLUSTERMGMT, api_version, resource_path)


def networking_path(api_version, resource_path):
    return api_path(NS_NETWORKING, api_version, resource_path)


def prism_path(api_version, resource_path):
    return api_path(NS_PRISM, api_version, resource_path)


def volumes_path(api_version, resource_path):
    return api_path(NS_VOLUMES, api_version, resource_path)


def dataprotection_path(api_version, resource_path):
    return api_path(NS_DATAPROTECTION, api_version, resource_path)


def new_request_id():
    return str(uuid.uuid4())


def extract_ips_from_nics(nics):
    public_ips = []
    private_ips = []

    if not nics:
        return public_ips, private_ips

    for nic in nics:
        network_info = nic.get("networkInfo") or {}
        for family in ("ipv4", "ipv6"):
            ip_block = network_info.get(family) or {}
            ip_configs = ip_block.get("ipAddresses") or []
            for ip_entry in ip_configs:
                if isinstance(ip_entry, dict):
                    value = ip_entry.get("value") or ip_entry.get("ipAddress")
                else:
                    value = str(ip_entry)
                if value:
                    private_ips.append(value)

    return public_ips, private_ips


def mib_to_bytes(mib):
    return mib * 1024 * 1024


def bytes_to_mib(value):
    return int(value / (1024 * 1024))


def gib_to_bytes(gib):
    return gib * 1024 * 1024 * 1024


def bytes_to_gib(value):
    return int(value / (1024 * 1024 * 1024))


def build_vm_create_payload(
    name,
    cluster_ext_id,
    num_sockets,
    num_cores_per_socket,
    memory_mib,
    image_ext_id=None,
    disk_size_mib=None,
    subnet_ext_id=None,
    storage_container_ext_id=None,
    description=None,
    categories=None,
    guest_customization=None,
    cloud_init=None,
    user_data=None,
    nics=None,
    power_on=True,
    assign_ip=None,
    ip_address=None,
    ip_prefix_length=None,
    data_disks=None,
):
    payload = {
        "name": name,
        "cluster": {"extId": cluster_ext_id},
        "numSockets": num_sockets,
        "numCoresPerSocket": num_cores_per_socket,
        "memorySizeBytes": mib_to_bytes(memory_mib),
        "powerState": "ON" if power_on else "OFF",
    }

    if description:
        payload["description"] = description

    if categories:
        payload["categories"] = categories

    disks = []
    if image_ext_id:
        vm_disk = {
            "diskSizeBytes": mib_to_bytes(disk_size_mib or 20480),
            "dataSource": {
                "reference": {
                    "imageExtId": image_ext_id,
                }
            },
        }
        if storage_container_ext_id:
            vm_disk["storageContainer"] = {"extId": storage_container_ext_id}
        disks.append({"backingInfo": {"vmDisk": vm_disk}})
    elif disk_size_mib:
        vm_disk = {"diskSizeBytes": mib_to_bytes(disk_size_mib)}
        if storage_container_ext_id:
            vm_disk["storageContainer"] = {"extId": storage_container_ext_id}
        disks.append({"backingInfo": {"vmDisk": vm_disk}})

    for data_disk in data_disks or []:
        data_disk_size_mib = data_disk.get("size_mib")
        if not data_disk_size_mib:
            raise LibcloudError(
                "data_disks entries require a size_mib value",
                driver=None,
            )
        vm_disk = {"diskSizeBytes": mib_to_bytes(data_disk_size_mib)}
        data_disk_container = (
            data_disk.get("storage_container_ext_id") or storage_container_ext_id
        )
        if data_disk_container:
            vm_disk["storageContainer"] = {"extId": data_disk_container}
        disk = {"backingInfo": {"vmDisk": vm_disk}}
        bus = data_disk.get("bus")
        if bus:
            disk_address = {"busType": str(bus).upper()}
            if data_disk.get("index") is not None:
                disk_address["index"] = data_disk["index"]
            disk["diskAddress"] = disk_address
        disks.append(disk)

    if disks:
        payload["disks"] = disks

    if nics is not None:
        payload["nics"] = nics
    elif subnet_ext_id:
        nic = {
            "networkInfo": {
                "subnet": {"extId": subnet_ext_id},
            }
        }
        ipv4_config = {}
        if ip_address:
            ipv4_config["ipAddress"] = {"value": ip_address}
            if ip_prefix_length is not None:
                ipv4_config["ipAddress"]["prefixLength"] = ip_prefix_length
        if assign_ip is not None:
            ipv4_config["shouldAssignIp"] = assign_ip
        elif ip_address:
            ipv4_config["shouldAssignIp"] = True
        if ipv4_config:
            nic["networkInfo"]["ipv4Config"] = ipv4_config
        payload["nics"] = [nic]

    customization = guest_customization or {}
    if cloud_init:
        customization.setdefault("cloudInit", {})["userData"] = cloud_init
    if user_data:
        customization.setdefault("cloudInit", {})["userData"] = user_data
    if customization:
        payload["guestCustomization"] = customization

    return payload


def build_volume_group_create_payload(
    name,
    cluster_ext_id,
    disk_size_bytes,
    disk_index=0,
    storage_container_ext_id=None,
    description=None,
    disk_data_source_reference=None,
):
    disk = {
        "index": disk_index,
        "diskSizeBytes": disk_size_bytes,
    }
    if storage_container_ext_id:
        disk["storageContainerId"] = storage_container_ext_id
    if disk_data_source_reference:
        disk["diskDataSourceReference"] = disk_data_source_reference

    payload = {
        "name": name,
        "clusterReference": cluster_ext_id,
        "disks": [disk],
    }
    if description:
        payload["description"] = description
    return payload


def build_recovery_point_create_payload(name, volume_group_ext_id):
    return {
        "name": name,
        "volumeGroupRecoveryPoints": [
            {
                "volumeGroupExtId": volume_group_ext_id,
            }
        ],
    }


def build_image_url_source(url, allow_insecure_url=False, basic_auth=None):
    source = {
        "$objectType": "vmm.v4.content.UrlSource",
        "url": url,
        "shouldAllowInsecureUrl": allow_insecure_url,
    }
    if basic_auth:
        source["basicAuth"] = basic_auth
    return source


def build_image_vm_disk_source(disk_ext_id):
    return {
        "$objectType": "vmm.v4.content.VmDiskSource",
        "extId": disk_ext_id,
    }


def build_vpc_create_payload(
    name,
    description=None,
    vpc_type="REGULAR",
    external_subnet_ext_ids=None,
):
    payload = {
        "name": name,
        "vpcType": vpc_type,
    }
    if description:
        payload["description"] = description
    if external_subnet_ext_ids:
        payload["externalSubnets"] = [
            {"subnetReference": ext_id} for ext_id in external_subnet_ext_ids
        ]
    return payload


def build_subnet_create_payload(
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
):
    payload = {
        "name": name,
        "subnetType": subnet_type,
        "isExternal": is_external,
    }
    if description:
        payload["description"] = description
    if cluster_ext_id:
        payload["clusterReference"] = cluster_ext_id
    if vpc_ext_id:
        payload["vpcReference"] = vpc_ext_id
    if network_id is not None:
        payload["networkId"] = network_id

    ip_config_ipv4 = None
    if ip_address and prefix_length is not None:
        ip_config_ipv4 = {
            "ipSubnet": {
                "ip": {"value": ip_address},
                "prefixLength": prefix_length,
            },
        }
        if gateway_ip:
            ip_config_ipv4["defaultGatewayIp"] = {"value": gateway_ip}

    if ip_pool:
        if ip_config_ipv4 is None:
            raise LibcloudError(
                "ip_pool requires ip_address and prefix_length",
                driver=None,
            )
        pool_list = []
        for pool in ip_pool:
            if isinstance(pool, str):
                start_ip, _, end_ip = pool.partition("-")
            else:
                start_ip, end_ip = pool
            start_ip = (start_ip or "").strip()
            end_ip = (end_ip or "").strip()
            if not start_ip or not end_ip:
                raise LibcloudError(
                    "ip_pool entries must be 'start-end' strings or (start, end) pairs",
                    driver=None,
                )
            pool_list.append({"startIp": {"value": start_ip}, "endIp": {"value": end_ip}})
        ip_config_ipv4["poolList"] = pool_list

    if dhcp_server:
        if ip_config_ipv4 is None:
            raise LibcloudError(
                "dhcp_server requires ip_address and prefix_length",
                driver=None,
            )
        ip_config_ipv4["dhcpServerAddress"] = {"value": dhcp_server}

    if ip_config_ipv4 is not None:
        payload["ipConfig"] = [{"ipv4": ip_config_ipv4}]

    return payload


def build_image_create_payload(
    name,
    image_type,
    source,
    description=None,
    cluster_ext_ids=None,
    category_ext_ids=None,
):
    payload = {
        "name": name,
        "type": image_type,
        "source": source,
    }
    if description:
        payload["description"] = description
    if cluster_ext_ids:
        payload["clusterLocationExtIds"] = cluster_ext_ids
    if category_ext_ids:
        payload["categoryExtIds"] = category_ext_ids
    return payload


def extract_vm_disk_ext_id(vm_json, disk_index=0):
    disks = vm_json.get("disks") or []
    if not disks:
        return None

    index = disk_index if disk_index < len(disks) else 0
    disk = disks[index]
    backing = disk.get("backingInfo") or disk.get("backing_info") or {}
    vm_disk = backing.get("vmDisk") or backing.get("vm_disk") or {}

    return (
        vm_disk.get("diskExtId")
        or vm_disk.get("disk_ext_id")
        or disk.get("extId")
        or disk.get("ext_id")
    )


def extract_task_ext_id(response_body):
    data = response_body.get("data")
    if isinstance(data, dict):
        return data.get("extId")
    return None


def extract_etag(response_headers):
    for key, value in response_headers.items():
        if key.lower() == "etag":
            return value.strip('"')
    return None


def extract_entity_ext_id_from_task(task):
    affected = task.get("entitiesAffected") or task.get("entities_affected") or []
    for entity in affected:
        if isinstance(entity, dict):
            ext_id = entity.get("extId") or entity.get("ext_id")
            if ext_id:
                return ext_id
    return None


def extract_task_completion_detail(task, key):
    details = task.get("completionDetails") or task.get("completion_details") or []
    for detail in details:
        if not isinstance(detail, dict):
            continue
        detail_key = detail.get("name") or detail.get("key")
        if detail_key == key:
            return detail.get("value") or detail.get("stringValue") or detail.get("string_value")
    return None
