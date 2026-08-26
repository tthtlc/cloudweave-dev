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

import base64
import json
import os
import unittest
from unittest.mock import MagicMock

from libcloud.common.nutanix import NutanixConnection, NutanixResponse
from libcloud.common.types import InvalidCredsError, LibcloudError
from libcloud.compute.providers import Provider, get_driver
from libcloud.compute.types import NodeState, StorageVolumeState, VolumeSnapshotState
from libcloud.test import LibcloudTestCase

from libcloud.compute.drivers.nutanix import NutanixNodeDriver

FIXTURES_DIR = os.path.join(
    os.path.dirname(__file__),
    "fixtures",
    "nutanix",
)


def load_fixture(name):
    with open(os.path.join(FIXTURES_DIR, name), encoding="utf-8") as fh:
        return json.load(fh)


class MockNutanixResponse(object):
    def __init__(self, body, status=200, headers=None):
        self.object = body
        self.status = status
        self.headers = headers or {}
        self.body = json.dumps(body)


class NutanixNodeDriverTests(LibcloudTestCase):
    def setUp(self):
        self.driver = NutanixNodeDriver(
            key="admin",
            secret="password",
            host="prism.example.com",
            port=9440,
            secure=True,
            api_version="v4.0",
            verify_ssl_cert=False,
        )
        self.mock_request = MagicMock()
        self.driver.connection._request = self.mock_request
        self.driver.connection._paged_request = MagicMock()
        self.driver.connection._wait_for_task = MagicMock(
            return_value=load_fixture("task_succeeded.json")["data"]
        )

    def test_provider_registration(self):
        cls = get_driver(Provider.NUTANIX)
        self.assertEqual(cls, NutanixNodeDriver)
        self.assertEqual(cls.type, Provider.NUTANIX)

    def test_list_nodes_maps_states_and_ips(self):
        self.driver.connection._paged_request.return_value = load_fixture("list_vms.json")["data"]
        nodes = self.driver.list_nodes()
        self.assertEqual(len(nodes), 2)

        running = nodes[0]
        self.assertEqual(running.name, "web-01")
        self.assertEqual(running.state, NodeState.RUNNING)
        self.assertIn("10.0.0.10", running.private_ips)

        stopped = nodes[1]
        self.assertEqual(stopped.state, NodeState.STOPPED)

    def test_list_images(self):
        self.driver.connection._paged_request.return_value = load_fixture("list_images.json")["data"]
        images = self.driver.list_images()
        self.assertEqual(len(images), 2)
        self.assertEqual(images[0].name, "ubuntu-22.04-cloud")

    def test_get_image(self):
        self.mock_request.return_value = MockNutanixResponse(load_fixture("get_image.json"))
        image = self.driver.get_image("img-11111111-1111-1111-1111-111111111111")
        self.assertEqual(image.name, "ubuntu-22.04-cloud")
        self.assertEqual(image.extra["image_type"], "DISK_IMAGE")

    def test_create_image_from_vm_disk(self):
        get_vm_response = MockNutanixResponse(load_fixture("get_vm_with_disk.json"))
        create_response = MockNutanixResponse(load_fixture("create_vm_task.json"), status=202)
        get_image_response = MockNutanixResponse(load_fixture("get_image_new.json"))
        self.mock_request.side_effect = [
            get_vm_response,
            create_response,
            get_image_response,
        ]
        self.driver.connection._wait_for_task = MagicMock(
            return_value=load_fixture("task_image_succeeded.json")["data"]
        )

        node = self.driver._to_node(load_fixture("list_vms.json")["data"][0])
        image = self.driver.create_image(
            node,
            name="web-01-image",
            description="Captured from web-01",
        )
        self.assertEqual(image.id, "img-new-1111-1111-1111-111111111111")
        self.assertEqual(image.name, "web-01-image")

    def test_ex_create_image_from_url(self):
        create_response = MockNutanixResponse(load_fixture("create_vm_task.json"), status=202)
        get_image_response = MockNutanixResponse(load_fixture("get_image_new.json"))
        self.mock_request.side_effect = [create_response, get_image_response]
        self.driver.connection._wait_for_task = MagicMock(
            return_value=load_fixture("task_image_succeeded.json")["data"]
        )

        image = self.driver.ex_create_image_from_url(
            name="remote-image",
            url="https://example.com/images/ubuntu.iso",
            ex_image_type="ISO_IMAGE",
        )
        self.assertEqual(image.id, "img-new-1111-1111-1111-111111111111")

    def test_delete_image(self):
        etag_response = MockNutanixResponse(
            load_fixture("get_image.json"),
            headers={"ETag": '"image-etag"'},
        )
        delete_response = MockNutanixResponse(load_fixture("create_vm_task.json"))
        self.mock_request.side_effect = [etag_response, delete_response]

        image = self.driver._to_image(load_fixture("get_image.json")["data"])
        self.assertTrue(self.driver.delete_image(image))

    def test_list_sizes_synthetic(self):
        sizes = self.driver.list_sizes()
        self.assertEqual(len(sizes), 4)
        self.assertEqual({size.id for size in sizes}, {"small", "medium", "large", "xlarge"})

    def test_list_locations(self):
        self.driver.connection._paged_request.return_value = load_fixture("list_clusters.json")["data"]
        locations = self.driver.list_locations()
        self.assertEqual(len(locations), 1)
        self.assertEqual(locations[0].name, "prod-cluster-01")

    def test_ex_list_subnets(self):
        self.driver.connection._paged_request.return_value = load_fixture("list_subnets.json")["data"]
        subnets = self.driver.ex_list_subnets()
        self.assertEqual(subnets[0]["name"], "vlan-100")

    def test_ex_list_hosts(self):
        self.driver.connection._paged_request.return_value = load_fixture("list_hosts.json")["data"]
        hosts = self.driver.ex_list_hosts()
        self.assertEqual(len(hosts), 2)
        self.assertEqual(hosts[0]["name"], "NTNX-POC-A")
        self.assertEqual(hosts[0]["cpu_model"], "Intel(R) Xeon(R) CPU E5-2640 v4 @ 2.40GHz")
        self.assertEqual(hosts[0]["num_cpu_threads"], 32)
        self.assertEqual(hosts[0]["memory_gib"], 128)
        self.assertEqual(hosts[0]["hypervisor"], "AHV 10.0")
        self.assertEqual(hosts[0]["cluster_name"], "NTNX-POC")

    def test_ex_get_host(self):
        self.mock_request.return_value = MockNutanixResponse(load_fixture("get_host.json"))
        host = self.driver.ex_get_host("host-00000000-0000-0000-0000-000000000001")
        self.assertEqual(host["id"], "host-00000000-0000-0000-0000-000000000001")
        self.assertEqual(host["name"], "NTNX-POC-A")
        self.assertEqual(host["block_serial"], "19FM6F160445")
        self.assertEqual(host["block_model"], "NX-3060-G5")
        self.assertEqual(host["number_of_vms"], 4)

    def test_ex_get_host_bmc_info(self):
        self.mock_request.return_value = MockNutanixResponse(load_fixture("get_host_bmc_info.json"))
        bmc = self.driver.ex_get_host_bmc_info(
            "host-00000000-0000-0000-0000-000000000001",
            cluster_ext_id="00061ebf-cluster-1",
        )
        self.assertEqual(bmc["bmc_ip"], "192.168.1.101")
        self.assertEqual(bmc["bmc_status"], "VALID")
        # Credentials must never be exposed.
        self.assertNotIn("credential", bmc)
        self.assertNotIn("password", bmc)

    def test_ex_get_host_bmc_info_requires_cluster(self):
        self.assertRaises(
            LibcloudError,
            self.driver.ex_get_host_bmc_info,
            "host-00000000-0000-0000-0000-000000000001",
        )

    def test_ex_get_node(self):
        self.mock_request.return_value = MockNutanixResponse(load_fixture("get_vm.json"))
        node = self.driver.ex_get_node("vm-11111111-1111-1111-1111-111111111111")
        self.assertEqual(node.name, "web-01")
        self.assertEqual(node.state, NodeState.RUNNING)

    def test_create_node_with_task_polling(self):
        create_response = MockNutanixResponse(load_fixture("create_vm_task.json"), status=202)
        get_vm_response = MockNutanixResponse(load_fixture("get_vm.json"))
        self.mock_request.side_effect = [create_response, get_vm_response]

        size = self.driver.list_sizes()[0]
        image = self.driver._to_image(load_fixture("list_images.json")["data"][0])
        location = self.driver._to_location(load_fixture("list_clusters.json")["data"][0])

        node = self.driver.create_node(
            name="test-vm",
            size=size,
            image=image,
            location=location,
            ex_subnet="subnet-11111111-1111-1111-1111-111111111111",
        )
        self.assertEqual(node.name, "web-01")
        self.driver.connection._wait_for_task.assert_called_once()

    def test_create_node_with_assign_ip_and_data_disks(self):
        create_response = MockNutanixResponse(load_fixture("create_vm_task.json"), status=202)
        get_vm_response = MockNutanixResponse(load_fixture("get_vm.json"))
        self.mock_request.side_effect = [create_response, get_vm_response]

        size = self.driver.list_sizes()[0]
        image = self.driver._to_image(load_fixture("list_images.json")["data"][0])
        location = self.driver._to_location(load_fixture("list_clusters.json")["data"][0])

        node = self.driver.create_node(
            name="internal-server-1",
            size=size,
            image=image,
            location=location,
            ex_subnet="subnet-11111111-1111-1111-1111-111111111111",
            ex_assign_ip=True,
            ex_data_disks=[{"size_mib": 20480, "bus": "scsi"}],
        )
        self.assertEqual(node.name, "web-01")

        _, kwargs = self.mock_request.call_args_list[0]
        payload = json.loads(kwargs["data"])
        nics = payload["nics"]
        self.assertEqual(len(nics), 1)
        ipv4_config = nics[0]["networkInfo"]["ipv4Config"]
        self.assertTrue(ipv4_config["shouldAssignIp"])
        self.assertNotIn("ipAddress", ipv4_config)

        disks = payload["disks"]
        self.assertEqual(len(disks), 2)

        boot_disk = disks[0]
        self.assertNotIn("vmDisk", boot_disk["backingInfo"])
        self.assertEqual(
            boot_disk["backingInfo"]["dataSource"]["reference"]["imageExtId"],
            image.id,
        )

        data_disk = disks[1]
        self.assertEqual(data_disk["backingInfo"]["diskSizeBytes"], 20480 * 1024 * 1024)
        self.assertEqual(data_disk["diskAddress"]["busType"], "SCSI")
        self.assertNotIn("dataSource", data_disk["backingInfo"])

    def test_create_node_with_static_ip(self):
        create_response = MockNutanixResponse(load_fixture("create_vm_task.json"), status=202)
        get_vm_response = MockNutanixResponse(load_fixture("get_vm.json"))
        self.mock_request.side_effect = [create_response, get_vm_response]

        size = self.driver.list_sizes()[0]
        image = self.driver._to_image(load_fixture("list_images.json")["data"][0])
        location = self.driver._to_location(load_fixture("list_clusters.json")["data"][0])

        self.driver.create_node(
            name="internal-server-1",
            size=size,
            image=image,
            location=location,
            ex_subnet="subnet-11111111-1111-1111-1111-111111111111",
            ex_ip_address="10.1.200.10",
            ex_ip_prefix_length=24,
        )

        _, kwargs = self.mock_request.call_args_list[0]
        payload = json.loads(kwargs["data"])
        ipv4_config = payload["nics"][0]["networkInfo"]["ipv4Config"]
        self.assertTrue(ipv4_config["shouldAssignIp"])
        self.assertEqual(ipv4_config["ipAddress"]["value"], "10.1.200.10")
        self.assertEqual(ipv4_config["ipAddress"]["prefixLength"], 24)

    def test_create_node_ssh_key_uses_cloud_init_config(self):
        create_response = MockNutanixResponse(load_fixture("create_vm_task.json"), status=202)
        get_vm_response = MockNutanixResponse(load_fixture("get_vm.json"))
        self.mock_request.side_effect = [create_response, get_vm_response]

        size = self.driver.list_sizes()[0]
        image = self.driver._to_image(load_fixture("list_images.json")["data"][0])
        location = self.driver._to_location(load_fixture("list_clusters.json")["data"][0])

        class FakeAuth(object):
            pubkey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ"

        self.driver.create_node(
            name="keyed-vm",
            size=size,
            image=image,
            location=location,
            ex_subnet="subnet-11111111-1111-1111-1111-111111111111",
            auth=FakeAuth(),
        )

        _, kwargs = self.mock_request.call_args_list[0]
        payload = json.loads(kwargs["data"])
        guest_customization = payload["guestCustomization"]
        self.assertIn("config", guest_customization)
        self.assertNotIn("cloudInit", guest_customization)
        cloud_init_script = guest_customization["config"]["cloudInitScript"]
        decoded = base64.b64decode(cloud_init_script["value"]).decode("utf-8")
        self.assertIn("ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ", decoded)
        self.assertEqual(
            guest_customization["config"]["datasourceType"],
            "CONFIG_DRIVE_V2",
        )
        # v4.0 keeps the non-deprecated networkInfo field.
        self.assertIn("networkInfo", payload["nics"][0])
        self.assertNotIn("nicNetworkInfo", payload["nics"][0])

    def test_create_node_v43_uses_nic_network_info(self):
        self.driver._api_version = "v4.3"
        self.driver.connection.api_version = "v4.3"

        create_response = MockNutanixResponse(load_fixture("create_vm_task.json"), status=202)
        get_vm_response = MockNutanixResponse(load_fixture("get_vm.json"))
        self.mock_request.side_effect = [create_response, get_vm_response]

        size = self.driver.list_sizes()[0]
        image = self.driver._to_image(load_fixture("list_images.json")["data"][0])
        location = self.driver._to_location(load_fixture("list_clusters.json")["data"][0])

        self.driver.create_node(
            name="v43-vm",
            size=size,
            image=image,
            location=location,
            ex_subnet="subnet-11111111-1111-1111-1111-111111111111",
        )

        _, kwargs = self.mock_request.call_args_list[0]
        payload = json.loads(kwargs["data"])
        nic = payload["nics"][0]
        self.assertIn("nicNetworkInfo", nic)
        self.assertNotIn("networkInfo", nic)
        self.assertEqual(
            nic["nicNetworkInfo"]["$objectType"],
            "vmm.v4.ahv.config.VirtualEthernetNicNetworkInfo",
        )

    def test_ex_create_subnet_with_ip_pool(self):
        create_response = MockNutanixResponse(load_fixture("create_vm_task.json"), status=202)
        get_subnet_response = MockNutanixResponse(
            {"data": load_fixture("list_subnets.json")["data"][0]}
        )
        self.mock_request.side_effect = [create_response, get_subnet_response]

        subnet = self.driver.ex_create_subnet(
            name="vlan200-internal",
            subnet_type="VLAN",
            cluster_ext_id="cluster-11111111-1111-1111-1111-111111111111",
            network_id=200,
            ip_address="10.1.200.0",
            prefix_length=24,
            gateway_ip="10.1.200.1",
            ip_pool=["10.1.200.10-10.1.200.50"],
        )
        self.assertEqual(subnet["name"], "vlan-100")

        _, kwargs = self.mock_request.call_args_list[0]
        payload = json.loads(kwargs["data"])
        self.assertEqual(payload["networkId"], 200)
        ipv4 = payload["ipConfig"][0]["ipv4"]
        self.assertEqual(ipv4["ipSubnet"]["ip"]["value"], "10.1.200.0")
        self.assertEqual(ipv4["ipSubnet"]["prefixLength"], 24)
        self.assertEqual(ipv4["defaultGatewayIp"]["value"], "10.1.200.1")
        self.assertEqual(
            ipv4["poolList"],
            [{"startIp": {"value": "10.1.200.10"}, "endIp": {"value": "10.1.200.50"}}],
        )
        self.assertNotIn("dhcpServerAddress", ipv4)

    def test_ex_create_subnet_ip_pool_requires_network(self):
        self.assertRaises(
            LibcloudError,
            self.driver.ex_create_subnet,
            name="vlan200-internal",
            subnet_type="VLAN",
            ip_pool=["10.1.200.10-10.1.200.50"],
        )

    def test_start_stop_reboot_destroy(self):
        task_response = MockNutanixResponse(load_fixture("create_vm_task.json"))
        etag_response = MockNutanixResponse(
            load_fixture("get_vm.json"),
            headers={"ETag": '"etag-value"'},
        )
        delete_response = MockNutanixResponse(load_fixture("create_vm_task.json"))

        node = self.driver._to_node(load_fixture("list_vms.json")["data"][0])

        self.mock_request.return_value = task_response
        self.assertTrue(self.driver.start_node(node))
        self.assertTrue(self.driver.stop_node(node))
        self.assertTrue(self.driver.reboot_node(node))

        self.mock_request.side_effect = [etag_response, task_response, delete_response]
        self.assertTrue(self.driver.destroy_node(node))

    def test_invalid_credentials_response(self):
        connection = MagicMock()
        connection.driver = self.driver
        response = NutanixResponse.__new__(NutanixResponse)
        response.connection = connection
        response.status = 401
        response.body = json.dumps(load_fixture("auth_error.json"))
        self.assertRaises(InvalidCredsError, response.parse_error)

    def test_task_wait_failure(self):
        self.driver.connection._wait_for_task = MagicMock(
            side_effect=LibcloudError("Task failed", driver=self.driver)
        )
        self.assertRaises(
            LibcloudError,
            self.driver.connection._wait_for_task,
            "task-failed",
        )

    def test_list_volumes(self):
        self.driver.connection._paged_request.side_effect = [
            load_fixture("list_volume_groups.json")["data"],
            load_fixture("list_volume_disks.json")["data"],
            [],
        ]
        volumes = self.driver.list_volumes()
        self.assertEqual(len(volumes), 1)
        self.assertEqual(volumes[0].name, "data-volume-01")
        self.assertEqual(volumes[0].size, 10)
        self.assertEqual(volumes[0].state, StorageVolumeState.AVAILABLE)

    def test_create_volume_with_task_polling(self):
        create_response = MockNutanixResponse(load_fixture("create_vm_task.json"), status=202)
        get_volume_response = MockNutanixResponse(load_fixture("get_volume_group.json"))
        self.mock_request.side_effect = [create_response, get_volume_response]
        self.driver.connection._paged_request.side_effect = [
            load_fixture("list_volume_disks.json")["data"],
            [],
        ]
        self.driver.connection._wait_for_task = MagicMock(
            return_value=load_fixture("task_volume_succeeded.json")["data"]
        )

        location = self.driver._to_location(load_fixture("list_clusters.json")["data"][0])
        volume = self.driver.create_volume(
            size=10,
            name="data-volume-01",
            location=location,
        )
        self.assertEqual(volume.id, "vg-11111111-1111-1111-1111-111111111111")
        self.assertEqual(volume.size, 10)

    def test_destroy_volume(self):
        etag_response = MockNutanixResponse(
            load_fixture("get_volume_group.json"),
            headers={"ETag": '"vg-etag"'},
        )
        delete_response = MockNutanixResponse(load_fixture("create_vm_task.json"))
        self.mock_request.side_effect = [etag_response, delete_response]

        volume = self.driver._to_volume(
            load_fixture("get_volume_group.json")["data"],
            disks=load_fixture("list_volume_disks.json")["data"],
        )
        self.assertTrue(self.driver.destroy_volume(volume))

    def test_attach_and_detach_volume(self):
        task_response = MockNutanixResponse(load_fixture("create_vm_task.json"))
        list_attachments_response = MockNutanixResponse(load_fixture("list_vm_attachments.json"))
        self.mock_request.side_effect = [
            task_response,
            task_response,
            list_attachments_response,
        ]

        node = self.driver._to_node(load_fixture("list_vms.json")["data"][0])
        volume = self.driver._to_volume(
            load_fixture("get_volume_group.json")["data"],
            disks=load_fixture("list_volume_disks.json")["data"],
        )

        self.assertTrue(self.driver.attach_volume(node, volume, device="2"))
        self.assertEqual(volume.extra["attached_vm_ext_id"], node.id)
        self.assertEqual(volume.state, StorageVolumeState.INUSE)

        self.assertTrue(self.driver.detach_volume(volume))
        self.assertEqual(volume.state, StorageVolumeState.AVAILABLE)

    def test_create_list_and_destroy_volume_snapshot(self):
        create_response = MockNutanixResponse(load_fixture("create_vm_task.json"), status=202)
        get_snapshot_response = MockNutanixResponse(load_fixture("get_recovery_point.json"))
        etag_response = MockNutanixResponse(
            load_fixture("get_recovery_point.json"),
            headers={"ETag": '"rp-etag"'},
        )
        delete_response = MockNutanixResponse(load_fixture("create_vm_task.json"))

        volume = self.driver._to_volume(
            load_fixture("get_volume_group.json")["data"],
            disks=load_fixture("list_volume_disks.json")["data"],
        )

        self.mock_request.side_effect = [
            create_response,
            get_snapshot_response,
            etag_response,
            delete_response,
        ]
        self.driver.connection._wait_for_task = MagicMock(
            return_value=load_fixture("task_recovery_point_succeeded.json")["data"]
        )

        snapshot = self.driver.create_volume_snapshot(volume, name="snapshot-data-volume-01")
        self.assertEqual(snapshot.id, "rp-11111111-1111-1111-1111-111111111111")
        self.assertEqual(snapshot.state, VolumeSnapshotState.AVAILABLE)

        self.driver.connection._paged_request.return_value = load_fixture("list_recovery_points.json")["data"]
        snapshots = self.driver.list_volume_snapshots(volume)
        self.assertEqual(len(snapshots), 1)
        self.assertEqual(snapshots[0].name, "snapshot-data-volume-01")

        self.assertTrue(self.driver.destroy_volume_snapshot(snapshot))


class NutanixSessionAuthTests(LibcloudTestCase):
    """Cookie-based session auth: Basic-auth login -> reuse the session cookie."""

    def test_default_uses_per_request_basic_auth(self):
        driver = NutanixNodeDriver(
            key="admin",
            secret="password",
            host="prism.example.com",
            port=9440,
            verify_ssl_cert=False,
        )
        self.assertIsNone(driver.connection.login_path)
        self.assertIsNone(driver.connection.session_cookie)

        headers = driver.connection.add_default_headers({})
        self.assertTrue(headers["Authorization"].startswith("Basic "))
        self.assertNotIn("Cookie", headers)

    def test_session_cookie_kwarg_injects_cookie_header(self):
        driver = NutanixNodeDriver(
            key="admin",
            secret="password",
            host="prism.example.com",
            port=9440,
            verify_ssl_cert=False,
            session_cookie="NTNX_IAM_SESSION=abc123",
        )
        self.assertEqual(driver.connection.session_cookie, "NTNX_IAM_SESSION=abc123")

        headers = driver.connection.add_default_headers({})
        self.assertEqual(headers["Cookie"], "NTNX_IAM_SESSION=abc123")
        self.assertNotIn("Authorization", headers)

    def test_login_path_derives_cookie_from_set_cookie(self):
        connection = NutanixConnection(
            "admin",
            "password",
            host="prism.example.com",
            port=9440,
            login_path="/api/nutanix/v1/session",
        )
        fake_response = MagicMock()
        fake_response.headers = {"set-cookie": "NTNX_IAM_SESSION=xyz789; Path=/; HttpOnly"}
        low_level = MagicMock()
        low_level.getresponse.return_value = fake_response
        connection.connection = low_level

        connection._get_auth_token()

        # Login was a POST to login_path carrying the Basic auth header.
        args, kwargs = low_level.request.call_args
        self.assertEqual(kwargs["method"], "POST")
        self.assertEqual(kwargs["url"], "/api/nutanix/v1/session")
        self.assertTrue(kwargs["headers"]["Authorization"].startswith("Basic "))

        self.assertEqual(
            connection.session_cookie,
            "NTNX_IAM_SESSION=xyz789; Path=/; HttpOnly",
        )

        # Subsequent requests now reuse the cookie instead of Basic auth.
        headers = connection.add_default_headers({})
        self.assertEqual(headers["Cookie"], "NTNX_IAM_SESSION=xyz789; Path=/; HttpOnly")
        self.assertNotIn("Authorization", headers)

    def test_login_path_rejected_credentials_raises(self):
        connection = NutanixConnection(
            "admin",
            "password",
            host="prism.example.com",
            port=9440,
            login_path="/api/nutanix/v1/session",
        )
        fake_response = MagicMock()
        fake_response.headers = {}
        fake_response.status_code = 401
        low_level = MagicMock()
        low_level.getresponse.return_value = fake_response
        connection.connection = low_level
        connection.driver = MagicMock()

        self.assertRaises(InvalidCredsError, connection._get_auth_token)
        self.assertIsNone(connection.session_cookie)

    def test_login_path_missing_set_cookie_falls_back_to_basic_auth(self):
        connection = NutanixConnection(
            "admin",
            "password",
            host="prism.example.com",
            port=9440,
            login_path="/api/nutanix/v1/session",
        )
        fake_response = MagicMock()
        fake_response.headers = {}
        fake_response.status_code = 404
        low_level = MagicMock()
        low_level.getresponse.return_value = fake_response
        connection.connection = low_level
        connection.driver = MagicMock()

        # No cookie and a non-auth failure -> cookie flow disabled, no exception.
        connection._get_auth_token()
        self.assertIsNone(connection.session_cookie)
        self.assertIsNone(connection.login_path)

        # Subsequent headers fall back to Basic auth, not a cookie.
        headers = connection.add_default_headers({})
        self.assertTrue(headers["Authorization"].startswith("Basic "))
        self.assertNotIn("Cookie", headers)

    def test_driver_ex_authenticate_returns_cookie(self):
        driver = NutanixNodeDriver(
            key="admin",
            secret="password",
            host="prism.example.com",
            port=9440,
            verify_ssl_cert=False,
            login_path="/api/nutanix/v1/session",
        )
        fake_response = MagicMock()
        fake_response.headers = {"set-cookie": "NTNX_IAM_SESSION=derived"}
        low_level = MagicMock()
        low_level.getresponse.return_value = fake_response
        driver.connection.connection = low_level

        cookie = driver.ex_authenticate()
        self.assertEqual(cookie, "NTNX_IAM_SESSION=derived")

        # Calling again is a cached no-op (no second login request).
        self.assertEqual(driver.ex_authenticate(), "NTNX_IAM_SESSION=derived")
        low_level.request.assert_called_once()


if __name__ == "__main__":
    unittest.main()
