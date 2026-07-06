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
Integration tests against the Stoplight Nutanix v4 emulator.

Start the mock stack before running:

    cd ../stoplight_mock && docker compose up -d
    cd ../libcloud/contrib/docker/nutanix && ./run_tests.sh integration
"""

import os
import ssl
import unittest
import uuid
import urllib.error
import urllib.request

from libcloud.compute.base import NodeImage
from libcloud.compute.providers import Provider, get_driver
from libcloud.compute.types import NodeState

EMULATOR_SEED_CLUSTER_ID = "00000000-0000-0000-0000-000000000001"
EMULATOR_SEED_SUBNET_ID = "00000000-0000-0000-0000-000000000002"
EMULATOR_SEED_IMAGE_ID = "00000000-0000-0000-0000-000000000003"
EMULATOR_SEED_STORAGE_CONTAINER_ID = "00000000-0000-0000-0000-000000000005"

DEFAULT_HOST = os.environ.get("NUTANIX_EMULATOR_HOST", "host.docker.internal")
DEFAULT_PORT = int(os.environ.get("NUTANIX_EMULATOR_PORT", "9440"))
DEFAULT_USER = os.environ.get("NUTANIX_EMULATOR_USER", "admin")
DEFAULT_PASSWORD = os.environ.get("NUTANIX_EMULATOR_PASSWORD", "password")
INTEGRATION_ENABLED = os.environ.get("NUTANIX_INTEGRATION_TESTS", "") == "1"


def is_emulator_available(host=DEFAULT_HOST, port=DEFAULT_PORT, timeout=3.0):
    url = "https://%s:%s/health" % (host, port)
    context = ssl._create_unverified_context()
    try:
        with urllib.request.urlopen(url, context=context, timeout=timeout) as resp:
            return resp.status == 200
    except (urllib.error.URLError, TimeoutError, OSError):
        return False


def create_emulator_driver():
    cls = get_driver(Provider.NUTANIX)
    return cls(
        key=DEFAULT_USER,
        secret=DEFAULT_PASSWORD,
        host=DEFAULT_HOST,
        port=DEFAULT_PORT,
        secure=True,
        api_version="v4.0",
        verify_ssl_cert=False,
    )


@unittest.skipUnless(
    INTEGRATION_ENABLED and is_emulator_available(),
    "Set NUTANIX_INTEGRATION_TESTS=1 and start stoplight_mock emulator",
)
class NutanixEmulatorIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.driver = create_emulator_driver()
        cls.seed_image = NodeImage(
            id=EMULATOR_SEED_IMAGE_ID,
            name="emulator-ubuntu-2204",
            driver=cls.driver,
        )

    def test_list_locations_returns_seed_cluster(self):
        locations = self.driver.list_locations()
        cluster = next((loc for loc in locations if loc.id == EMULATOR_SEED_CLUSTER_ID), None)
        self.assertIsNotNone(cluster)
        self.assertEqual(cluster.name, "emulator-cluster")

    def test_ex_list_subnets_returns_seed_subnet(self):
        subnets = self.driver.ex_list_subnets()
        subnet = next((s for s in subnets if s.get("extId") == EMULATOR_SEED_SUBNET_ID), None)
        self.assertIsNotNone(subnet)
        self.assertEqual(subnet.get("name"), "emulator-primary-subnet")

    def test_create_and_destroy_vm(self):
        vm_name = "libcloud-test-%s" % uuid.uuid4().hex[:8]
        location = next(
            loc for loc in self.driver.list_locations() if loc.id == EMULATOR_SEED_CLUSTER_ID
        )
        node = self.driver.create_node(
            name=vm_name,
            size=self.driver.list_sizes()[0],
            image=self.seed_image,
            location=location,
            ex_subnet=EMULATOR_SEED_SUBNET_ID,
            ex_description="Created by libcloud integration test",
            ex_wait_timeout=30,
        )
        self.assertTrue(node.id)
        self.assertEqual(node.name, vm_name)
        self.assertEqual(node.state, NodeState.RUNNING)

        refreshed = self.driver.ex_get_node(node.id)
        self.assertEqual(refreshed.name, vm_name)

        self.assertTrue(self.driver.destroy_node(node, ex_wait_timeout=30))

    def test_volume_snapshot_lifecycle(self):
        location = next(
            loc for loc in self.driver.list_locations() if loc.id == EMULATOR_SEED_CLUSTER_ID
        )
        volume_name = "libcloud-vol-%s" % uuid.uuid4().hex[:8]
        volume = self.driver.create_volume(
            size=10,
            name=volume_name,
            location=location,
            ex_storage_container=EMULATOR_SEED_STORAGE_CONTAINER_ID,
            ex_wait_timeout=30,
        )
        self.assertTrue(volume.id)
        self.assertEqual(volume.name, volume_name)
        self.assertGreaterEqual(volume.size, 10)

        snapshot_name = "libcloud-snap-%s" % uuid.uuid4().hex[:8]
        snapshot = self.driver.create_volume_snapshot(
            volume,
            name=snapshot_name,
            ex_wait_timeout=30,
        )
        self.assertTrue(snapshot.id)
        self.assertEqual(snapshot.name, snapshot_name)

        snapshots = self.driver.list_volume_snapshots(volume)
        self.assertTrue(any(item.id == snapshot.id for item in snapshots))

        self.assertTrue(self.driver.destroy_volume_snapshot(snapshot, ex_wait_timeout=30))
        self.assertTrue(self.driver.destroy_volume(volume, ex_wait_timeout=30))

    def test_create_and_delete_image_from_vm(self):
        location = next(
            loc for loc in self.driver.list_locations() if loc.id == EMULATOR_SEED_CLUSTER_ID
        )
        vm_name = "libcloud-img-src-%s" % uuid.uuid4().hex[:8]
        node = self.driver.create_node(
            name=vm_name,
            size=self.driver.list_sizes()[0],
            image=self.seed_image,
            location=location,
            ex_subnet=EMULATOR_SEED_SUBNET_ID,
            ex_wait_timeout=30,
        )

        image_name = "libcloud-image-%s" % uuid.uuid4().hex[:8]
        image = self.driver.create_image(
            node,
            name=image_name,
            description="Captured by libcloud integration test",
            ex_wait_timeout=30,
        )
        self.assertTrue(image.id)
        self.assertEqual(image.name, image_name)

        fetched = self.driver.get_image(image.id)
        self.assertEqual(fetched.name, image_name)

        self.assertTrue(self.driver.delete_image(image, ex_wait_timeout=30))
        self.assertTrue(self.driver.destroy_node(node, ex_wait_timeout=30))


if __name__ == "__main__":
    unittest.main()
