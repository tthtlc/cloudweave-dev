#!/usr/bin/env python3
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
Schema-parity validator for the Nutanix libcloud driver.

Validates the request bodies produced by the driver's payload builders
(``libcloud.common.nutanix``) against the Nutanix v4 OpenAPI specs in
``../../nutanix_swagger`` for every available version (v4.0 through v4.3).

This is a field-presence check, not full JSON-Schema validation: the Nutanix
specs mark the ``$objectType`` discriminators as ``required``, but the official
v4 SDK omits them and the API infers the type, so strict validation would
produce false positives. Instead we assert that every field the driver emits is
a real property of the target schema, and that the shapes we care about
(flat ``backingInfo``, ``config.cloudInitScript`` guest customization, and the
v4.3 ``nicNetworkInfo`` rename) match.

Usage::

    python3 libcloud/scripts/validate_nutanix_schema_parity.py

Requires PyYAML (``pip install pyyaml``).
"""

import os
import sys

LIBCLOUD_SRC = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
REPO_ROOT = os.path.abspath(os.path.join(LIBCLOUD_SRC, ".."))
sys.path.insert(0, LIBCLOUD_SRC)  # expose the "libcloud" package

try:
    import yaml
except ImportError:  # pragma: no cover
    print("ERROR: PyYAML is required. Install with: pip install pyyaml")
    sys.exit(2)

from libcloud.common.nutanix import (  # noqa: E402
    build_image_create_payload,
    build_image_url_source,
    build_recovery_point_create_payload,
    build_subnet_create_payload,
    build_vm_create_payload,
    build_volume_group_create_payload,
    build_vpc_create_payload,
)

NUTANIX_SWAGGER = os.path.join(REPO_ROOT, "nutanix_swagger")
VERSIONS = ["v4.0", "v4.1", "v4.2", "v4.3"]

SEED_CLUSTER = "00000000-0000-0000-0000-000000000001"
SEED_SUBNET = "00000000-0000-0000-0000-000000000002"
SEED_IMAGE = "00000000-0000-0000-0000-000000000003"


class _NoTimestampLoader(yaml.SafeLoader):
    pass


def _construct_scalar(loader, node):
    return loader.construct_scalar(node)


_NoTimestampLoader.add_constructor("tag:yaml.org,2002:timestamp", _construct_scalar)


def load_spec(namespace, version):
    filename = os.path.join(NUTANIX_SWAGGER, "swagger-%s-%s-all.yaml" % (namespace, version))
    with open(filename, encoding="utf-8") as fh:
        return yaml.load(fh, Loader=_NoTimestampLoader)


def _resolve(spec, ref):
    node = spec
    for part in ref[2:].split("/"):
        node = node[part.replace("~1", "/").replace("~0", "~")]
    return node


def flatten(spec, schema):
    """Return (required, properties) for a schema, resolving $ref and allOf."""
    required = []
    properties = {}
    seen = set()

    def walk(node):
        if not isinstance(node, dict) or id(node) in seen:
            return
        seen.add(id(node))
        if "$ref" in node:
            walk(_resolve(spec, node["$ref"]))
        if "allOf" in node:
            for sub in node["allOf"]:
                walk(sub)
        for name in node.get("required", []) or []:
            if name not in required:
                required.append(name)
        for name in node.get("properties", {}) or {}:
            if name not in properties:
                properties[name] = node["properties"][name]

    walk(schema)
    return required, properties


def schema_component(spec, name):
    return spec["components"]["schemas"][name]


def request_schema(spec, path, method="post"):
    op = spec["paths"].get(path, {}).get(method, {})
    return (op.get("requestBody") or {}).get("content", {}).get("application/json", {}).get("schema")


def _check_keys(failures, version, label, obj, allowed, allow=frozenset()):
    extra = set(obj) - set(allowed) - set(allow)
    if extra:
        failures.append("%s: %s has unknown keys %s" % (version, label, sorted(extra)))


def validate_vm_payload(failures):
    for version in VERSIONS:
        spec = load_spec("vmm", version)
        payload = build_vm_create_payload(
            name="parity-vm",
            cluster_ext_id=SEED_CLUSTER,
            num_sockets=1,
            num_cores_per_socket=1,
            memory_mib=2048,
            image_ext_id=SEED_IMAGE,
            disk_size_mib=20480,
            subnet_ext_id=SEED_SUBNET,
            user_data="#cloud-config\nssh_authorized_keys:\n  - test\n",
            api_version=version,
        )

        # Top-level Vm object
        _, vm_props = flatten(spec, schema_component(spec, "vmm.%s.ahv.config.Vm" % version))
        _check_keys(failures, version, "Vm", payload, vm_props)

        # Disks: flat backingInfo (VmDisk fields directly, no vmDisk wrapper)
        _, disk_props = flatten(spec, schema_component(spec, "vmm.%s.ahv.config.Disk" % version))
        _, vmdisk_props = flatten(spec, schema_component(spec, "vmm.%s.ahv.config.VmDisk" % version))
        for disk in payload.get("disks", []):
            _check_keys(failures, version, "Disk", disk, disk_props)
            backing = disk.get("backingInfo", {})
            if "vmDisk" in backing:
                failures.append("%s: disk backingInfo still wraps vmDisk" % version)
            _check_keys(failures, version, "VmDisk", backing, vmdisk_props, allow={"$objectType"})

        # Guest customization: config.cloudInitScript (not cloudInit.userData)
        gc = payload.get("guestCustomization")
        if gc:
            _, gc_props = flatten(
                spec, schema_component(spec, "vmm.%s.ahv.config.GuestCustomizationParams" % version)
            )
            _check_keys(failures, version, "GuestCustomizationParams", gc, gc_props)
            if "cloudInit" in gc:
                failures.append("%s: guestCustomization still uses cloudInit.userData" % version)
            if "config" in gc:
                _, ci_props = flatten(
                    spec, schema_component(spec, "vmm.%s.ahv.config.CloudInit" % version)
                )
                _check_keys(failures, version, "CloudInit", gc["config"], ci_props)

        # NICs: networkInfo (v4.0-v4.2) / nicNetworkInfo (v4.3)
        _, nic_props = flatten(spec, schema_component(spec, "vmm.%s.ahv.config.Nic" % version))
        for nic in payload.get("nics", []):
            _check_keys(failures, version, "Nic", nic, nic_props)
            if version == "v4.3":
                if "nicNetworkInfo" not in nic:
                    failures.append("%s: v4.3 NIC is missing nicNetworkInfo" % version)
            elif "networkInfo" not in nic:
                failures.append("%s: NIC is missing networkInfo" % version)


def validate_simple_payloads(failures):
    # Each entry: (builder, kwargs, namespace, path, versions-available)
    checks = [
        (
            build_image_create_payload,
            {"name": "p", "image_type": "DISK_IMAGE", "source": build_image_url_source("https://e/x.iso")},
            "vmm",
            "content/images",
            VERSIONS,
        ),
        (
            build_volume_group_create_payload,
            {"name": "p", "cluster_ext_id": SEED_CLUSTER, "disk_size_bytes": 10737418240},
            "volumes",
            "config/volume-groups",
            VERSIONS,
        ),
        (
            build_subnet_create_payload,
            {"name": "p", "subnet_type": "VLAN", "network_id": 200},
            "networking",
            "config/subnets",
            VERSIONS,
        ),
        (
            build_vpc_create_payload,
            {"name": "p", "vpc_type": "REGULAR"},
            "networking",
            "config/vpcs",
            VERSIONS,
        ),
        (
            build_recovery_point_create_payload,
            {"name": "p", "volume_group_ext_id": SEED_CLUSTER},
            "dataprotection",
            "config/recovery-points",
            ["v4.1", "v4.2", "v4.3"],
        ),
    ]

    for builder, kwargs, namespace, path, available in checks:
        for version in available:
            spec = load_spec(namespace, version)
            schema = request_schema(spec, "/%s/%s/%s" % (namespace, version, path))
            if not schema:
                failures.append("%s: no request schema for /%s/%s/%s" % (version, namespace, version, path))
                continue
            _, props = flatten(spec, schema)
            payload = builder(**kwargs)
            _check_keys(failures, version, builder.__name__, payload, props)


def main():
    failures = []
    validate_vm_payload(failures)
    validate_simple_payloads(failures)

    if failures:
        print("FAILED — %d problem(s):" % len(failures))
        for failure in failures:
            print("  - %s" % failure)
        return 1

    print("OK — all payload builders match the Nutanix v4 schemas for %s" % ", ".join(VERSIONS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
