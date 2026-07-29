"""Unit test for the resource-inventory fan-out in LibcloudProxy.list_nodes
(the portal's "View <cloud> Resources" categories, grouped per key_resource.md;
AWS specs per aws_resource.md, Nutanix specs per nutanix_resource.md).

Runs inside the identity-service container with plain `python` (no pytest —
same convention as test_authz_consistency.py) and hits NO network:
LibcloudProxy._call is stubbed with canned per-path payloads, and
ProvisionerAuth is bypassed by constructing the proxy via __new__.

Covers:
  - list_nodes("aws") / list_nodes("nutanix") return region/cluster + nodes +
    one category per spec in the cloud's spec table, in the declared group
    order, with rows mapped from the raw libcloud REST item shapes;
  - each category carries `total` (true count) and rows capped at
    inventory_max_rows;
  - the AWS snapshots category asks the REST API for owner=self (the REST
    default returns ALL public snapshots);
  - a failing category degrades to rows=[] + an error note (the rest of the
    page must stay up).

Run:  docker exec -e PYTHONPATH=/tmp/cattest identity-service \
        python /tmp/cattest/test_resource_categories.py
(the /tmp/cattest overlay carries the working-tree app/ code; see
verify_authz_matrix.sh for the docker cp convention.)
"""

from __future__ import annotations

import sys
from types import SimpleNamespace

from app.errors import APIError
from app.libcloud_proxy import _AWS_CATEGORY_SPECS, _NTNX_CATEGORY_SPECS, LibcloudProxy

PASS = 0
FAIL = 0
FAILURES: list[str] = []


def report(ok: bool, name: str, detail: str = "") -> None:
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        FAILURES.append(name)
        print(f"  FAIL  {name}\n        {detail}")


# Canned libcloud REST payloads per path (shapes mirror the real serializers
# in libcloud.rest/app/{compute,network,storage}). Paths not in a cloud's spec
# table are simply never requested for that cloud.
def _canned() -> dict[str, list[dict]]:
    return {
        "/v1/compute/nodes": [{"id": "i-1", "name": "vm-1", "state": "running", "size": "t3.micro"}],
        "/v1/compute/locations": [{"id": "cluster-1", "name": "NTNX-POC"}],
        "/v1/compute/networks": [{"id": "vpc-1", "name": "vpc-a", "cidr_block": "10.0.0.0/16", "state": "available"}],
        "/v1/compute/subnets": [{"id": "subnet-1", "name": "pub", "cidr_block": "10.0.0.0/24",
                                 "vpc_id": "vpc-1", "availability_zone": "ap-southeast-1a"}],
        "/v1/compute/security-groups": [{"id": "sg-1", "name": "bastion",
                                         "extra": {"vpc_id": "vpc-1", "vpcReference": "vpc-1"},
                                         "ingress_rules": [{"from_port": 22}], "egress_rules": []}],
        "/v1/compute/load-balancers": [{"id": "lb-1", "name": "lb-a"}],
        "/v1/compute/network-interfaces": [{"id": "eni-1", "name": "eni-1", "state": "in-use",
                                            "subnet_id": "subnet-1", "vpc_id": "vpc-1"}],
        "/v1/compute/route-tables": [{
            "id": "rtb-1", "name": "pub-rtb",
            "routes": [{"cidr": "0.0.0.0/0", "gateway_id": "igw-1", "state": "active"},
                       {"cidr": "10.0.0.0/16", "gateway_id": None, "state": "active"}],
            "subnet_associations": [{"id": "rtbassoc-1", "subnet_id": "subnet-1"}],
        }],
        "/v1/compute/internet-gateways": [{"id": "igw-1", "name": "igw", "vpc_id": "vpc-1", "state": "available"}],
        "/v1/compute/floating-ips": [{"address": "1.2.3.4", "instance_id": "i-1", "associated": True}],
        "/v1/compute/images": [{"id": "ami-1", "name": "ubuntu-jammy"}],
        "/v1/compute/volumes": [{"id": "vol-1", "name": None, "size": 8, "state": "in-use"}],
        "/v1/compute/snapshots": [{"id": "snap-1", "name": "bkp", "volume_id": "vol-1", "state": "completed"}],
        "/v1/compute/storage-containers": [{"id": "sc-1", "name": "default-container"}],
        "/v1/storage/buckets": [{"id": "bucket-a", "name": "bucket-a"}],
        "/v1/compute/key-pairs": [{"name": "kp", "fingerprint": "aa:bb"}],
    }


def _make_proxy(fail_paths: set[str] | None = None, max_rows: int = 50) -> tuple[LibcloudProxy, dict]:
    canned = _canned()
    fail_paths = fail_paths or set()
    calls: dict[str, dict] = {}

    proxy = LibcloudProxy.__new__(LibcloudProxy)  # bypass ProvisionerAuth init
    proxy._settings = lambda: SimpleNamespace(  # noqa: E731 - test stub
        libcloud_rest_url="http://rest",
        aws_region="ap-southeast-1", aws_auth_binding="aws",
        inventory_max_rows=max_rows,
        ntnx_host="ntnx", ntnx_port=9440, ntnx_api_version="v4.0",
        ntnx_verify_ssl=False, ntnx_auth_binding="nutanix",
    )
    proxy._auth = SimpleNamespace(get_token=lambda cloud: "tok")

    def fake_call(client, path, headers, steps, **kwargs):
        calls[path] = kwargs
        if path in fail_paths:
            raise APIError("rest_error", f"boom {path}", 502)
        return {"data": canned.get(path, [])}

    proxy._call = fake_call
    return proxy, calls


def _groups(cats: list[dict]) -> list[str]:
    groups: list[str] = []
    for c in cats:
        if c["group"] not in groups:
            groups.append(c["group"])
    return groups


def test_aws_categories() -> None:
    proxy, calls = _make_proxy()
    out = proxy.list_nodes("aws")
    report(out.get("region") == "ap-southeast-1", "aws region key", str(out.get("region")))
    report([n["id"] for n in out.get("nodes", [])] == ["i-1"], "aws nodes shaped", str(out.get("nodes")))

    cats = out.get("categories") or []
    report(len(cats) == len(_AWS_CATEGORY_SPECS), f"{len(_AWS_CATEGORY_SPECS)} aws categories", f"got {len(cats)}")
    report(_groups(cats) == [
        "Where a VM can land", "Networks a VM can join", "Images a VM can boot from",
        "Block storage a VM can consume", "Object storage", "Access",
    ], "aws group order follows key_resource.md", str(_groups(cats)))

    by_key = {c["key"]: c for c in cats}

    sg = by_key["security_groups"]["rows"][0]
    report(sg["ingress"] == 1 and sg["egress"] == 0 and sg["vpc"] == "vpc-1",
           "security group row (rule counts + vpc)", str(sg))

    rt = by_key["route_tables"]["rows"][0]
    report(rt["routes"] == "0.0.0.0/0 -> igw-1, 10.0.0.0/16 -> local" and rt["subnets"] == "subnet-1",
           "route table row (route + subnet summaries)", str(rt))

    eip = by_key["floating_ips"]["rows"][0]
    report(eip == {"address": "1.2.3.4", "instance": "i-1", "associated": "yes"},
           "elastic IP row", str(eip))

    vol = by_key["volumes"]["rows"][0]
    report(vol["size"] == 8 and vol["state"] == "in-use", "volume row", str(vol))

    kp = by_key["key_pairs"]["rows"][0]
    report(kp == {"name": "kp", "fingerprint": "aa:bb"}, "key pair row", str(kp))

    eni = by_key["network_interfaces"]["rows"][0]
    report(eni["subnet"] == "subnet-1" and eni["vpc"] == "vpc-1", "network interface row", str(eni))

    report(all(c.get("total") == 1 for c in cats), "every category total == canned count",
           str([(c["key"], c.get("total")) for c in cats]))

    report(calls.get("/v1/compute/snapshots", {}).get("params") == {"owner": "self"},
           "snapshots fetched with owner=self", str(calls.get("/v1/compute/snapshots")))

    # AWS must not call Nutanix-only endpoints (and vice versa).
    report("/v1/compute/storage-containers" not in calls and "/v1/compute/locations" not in calls,
           "aws fan-out skips nutanix-only paths", str(sorted(calls)))

    for c in cats:
        if "error" in c:
            report(False, f"aws category {c['key']} error-free", c["error"])
    report(True, "all aws categories error-free")


def test_nutanix_categories() -> None:
    proxy, calls = _make_proxy()
    out = proxy.list_nodes("nutanix")
    report("cluster" in out and "nodes" in out, "nutanix cluster + nodes keys", str(list(out)))

    cats = out.get("categories") or []
    report(len(cats) == len(_NTNX_CATEGORY_SPECS), f"{len(_NTNX_CATEGORY_SPECS)} nutanix categories",
           f"got {len(cats)}")
    report(_groups(cats) == [
        "Where a VM can land", "Networks a VM can join", "Images a VM can boot from",
        "Storage a VM can consume", "Object storage",
    ], "nutanix group order follows key_resource.md", str(_groups(cats)))

    by_key = {c["key"]: c for c in cats}

    cl = by_key["clusters"]["rows"][0]
    report(cl == {"id": "cluster-1", "name": "NTNX-POC"}, "cluster row", str(cl))

    sg = by_key["security_groups"]["rows"][0]
    report(sg["vpc"] == "vpc-1" and "ingress" not in sg, "nutanix SG row (vpc, no rule counts)", str(sg))

    sc = by_key["storage_containers"]["rows"][0]
    report(sc == {"id": "sc-1", "name": "default-container"}, "storage container row", str(sc))

    lb = by_key["load_balancers"]["rows"][0]
    report(lb == {"id": "lb-1", "name": "lb-a"}, "load balancer row", str(lb))

    report(all(c.get("total") == 1 for c in cats), "every nutanix category total == canned count",
           str([(c["key"], c.get("total")) for c in cats]))

    # Nutanix must not call AWS-only (or unsupported-for-nutanix) endpoints.
    for skipped in ("/v1/compute/snapshots", "/v1/compute/route-tables",
                    "/v1/compute/internet-gateways", "/v1/compute/floating-ips",
                    "/v1/compute/network-interfaces", "/v1/compute/key-pairs"):
        if skipped in calls:
            report(False, f"nutanix fan-out skips {skipped}", str(sorted(calls)))
    report(True, "nutanix fan-out skips aws-only paths")

    for c in cats:
        if "error" in c:
            report(False, f"nutanix category {c['key']} error-free", c["error"])
    report(True, "all nutanix categories error-free")


def test_rows_capped_with_total() -> None:
    proxy, _ = _make_proxy(max_rows=0)
    out = proxy.list_nodes("aws")
    by_key = {c["key"]: c for c in out.get("categories", [])}
    vpcs = by_key.get("vpcs", {})
    report(vpcs.get("rows") == [] and vpcs.get("total") == 1,
           "rows capped at max_rows, total keeps true count", str(vpcs))


def test_category_failure_isolated() -> None:
    proxy, _ = _make_proxy(fail_paths={"/v1/storage/buckets"})
    out = proxy.list_nodes("nutanix")
    by_key = {c["key"]: c for c in out.get("categories", [])}
    buckets = by_key.get("buckets", {})
    report(buckets.get("rows") == [] and "boom" in (buckets.get("error") or ""),
           "failing category degrades to rows=[] + error", str(buckets))
    report(by_key["volumes"]["rows"][0]["id"] == "vol-1",
           "other categories unaffected", str(by_key["volumes"]["rows"]))


def main() -> int:
    test_aws_categories()
    test_nutanix_categories()
    test_rows_capped_with_total()
    test_category_failure_isolated()
    print(f"\n=== Summary: {PASS} passed, {FAIL} failed ===")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
