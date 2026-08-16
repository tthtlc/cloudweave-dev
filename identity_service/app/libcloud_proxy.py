from __future__ import annotations

import json
import logging
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any

import httpx

from app.config import get_settings
from app.errors import APIError
from app.idp_login import ProvisionerAuth
from app import aws_resolve, hot_config

log = logging.getLogger(__name__)

# The identity service is an authZ-gated orchestrator over the libcloud REST
# API (:8765). The REST API holds the backend cloud identity (server-side IAM
# role / auth_binding + Vault secret); the client never handles credentials
# (see server/README.md §Provisioning contract).
#
# provision() replays the exact orchestration order from:
#   test_script/scripts/provision_aws.sh
#   test_script/scripts/provision_nutanix.sh
# (mirrored by MOCK_AWS_STEPS / MOCK_NUTANIX_STEPS in server/src/services/mockData.js).


# ---------------------------------------------------------------------------
# Nutanix resource inventory shown by the portal's "View Nutanix Resources"
# button — same key_resource.md grouping as AWS, mapped to Prism Central v4
# namespaces per nutanix_resource.md: clusters/VPCs/subnets (networking),
# Flow security groups + load balancers (microseg/networking), images (vmm),
# volumes + storage containers (volumes/vmm), buckets (objects), key pairs.
# Not covered (and why): snapshots — Nutanix has no single snapshot resource
# (dataprotection/volume lineage; the driver only does per-volume listing);
# IAM users/roles/policies and key pairs — the libcloud Nutanix driver has no
# iam namespace methods, and list_key_pairs is only the base-class stub
# (NotImplementedError), so "who can provision / who can access" stays out of
# scope; VM NICs — they are part of the VM resource in vmm, already visible
# in the nodes table; route tables/gateways — AWS-only REST endpoints (501).
# ---------------------------------------------------------------------------
_NTNX_CATEGORY_SPECS: list[dict[str, Any]] = [
    # --- where a VM can land -------------------------------------------------
    {
        "group": "Where a VM can land", "key": "clusters", "title": "Clusters",
        "path": "/v1/compute/locations",
        "columns": [("id", "ID"), ("name", "Name")],
        "row": lambda i: {"id": i.get("id"), "name": i.get("name") or ""},
    },
    {
        "group": "Where a VM can land", "key": "vpcs", "title": "VPCs",
        "path": "/v1/compute/networks",
        "columns": [("id", "ID"), ("name", "Name"), ("cidr", "CIDR"), ("state", "State")],
        "row": lambda i: {"id": i.get("id"), "name": i.get("name") or "",
                          "cidr": i.get("cidr_block") or "", "state": i.get("state") or ""},
    },
    {
        "group": "Where a VM can land", "key": "subnets", "title": "Subnets",
        "path": "/v1/compute/subnets",
        "columns": [("id", "ID"), ("name", "Name"), ("cidr", "CIDR"), ("vpc", "VPC")],
        "row": lambda i: {"id": i.get("id"), "name": i.get("name") or "",
                          "cidr": i.get("cidr_block") or "", "vpc": i.get("vpc_id") or ""},
    },
    # --- what network it can join ---------------------------------------------
    {
        "group": "Networks a VM can join", "key": "security_groups", "title": "Security Groups (Flow)",
        "path": "/v1/compute/security-groups",
        "columns": [("id", "ID"), ("name", "Name"), ("vpc", "VPC")],
        "row": lambda i: {"id": i.get("id"), "name": i.get("name") or "",
                          "vpc": (i.get("extra") or {}).get("vpc_id")
                                 or (i.get("extra") or {}).get("vpcReference") or ""},
    },
    {
        "group": "Networks a VM can join", "key": "load_balancers", "title": "Load Balancers",
        "path": "/v1/compute/load-balancers",
        "columns": [("id", "ID"), ("name", "Name")],
        "row": lambda i: {"id": i.get("id"), "name": i.get("name") or ""},
    },
    # --- what image it boots from ---------------------------------------------
    {
        "group": "Images a VM can boot from", "key": "images", "title": "Images",
        "path": "/v1/compute/images",
        "columns": [("id", "ID"), ("name", "Name")],
        "row": lambda i: {"id": i.get("id"), "name": i.get("name") or ""},
    },
    # --- what storage it consumes ---------------------------------------------
    {
        "group": "Storage a VM can consume", "key": "volumes", "title": "Volumes (Disks)",
        "path": "/v1/compute/volumes",
        "columns": [("id", "ID"), ("name", "Name"), ("size", "Size (GiB)"), ("state", "State")],
        "row": lambda i: {"id": i.get("id"), "name": i.get("name") or "",
                          "size": i.get("size") if i.get("size") is not None else "",
                          "state": i.get("state") or ""},
    },
    {
        "group": "Storage a VM can consume", "key": "storage_containers", "title": "Storage Containers",
        "path": "/v1/compute/storage-containers",
        "columns": [("id", "ID"), ("name", "Name")],
        "row": lambda i: {"id": i.get("id"), "name": i.get("name") or ""},
    },
    # --- what object storage already exists -------------------------------------
    {
        "group": "Object storage", "key": "buckets", "title": "Object Buckets",
        "path": "/v1/storage/buckets",
        "columns": [("name", "Name")],
        "row": lambda i: {"name": i.get("name") or ""},
    },
]
def _rt_route_summary(item: dict[str, Any]) -> str:
    parts = []
    for r in item.get("routes") or []:
        target = r.get("gateway_id") or "local"
        parts.append(f"{r.get('cidr') or ''} -> {target}")
    return ", ".join(parts)


def _rt_subnet_summary(item: dict[str, Any]) -> str:
    return ", ".join(
        str(a.get("subnet_id") or "") for a in item.get("subnet_associations") or [] if a.get("subnet_id")
    )


# ---------------------------------------------------------------------------
# AWS resource inventory shown by the portal's "View AWS Resources" button.
# Beyond EC2 instances (the `nodes` list, which keeps its own table with the
# Edit/Deprovision actions), the categories below follow the core questions
# from key_resource.md: where a VM can land, what network it can join, what
# image it boots from, what storage it consumes, what object storage exists,
# and who can access. (IAM users/roles/policies — "who can provision" — are
# not covered by the libcloud drivers and stay out of scope, per
# aws_resource.md.) Every category is a read-only GET on the libcloud REST
# API gated by compute:read / compute:network:read — scopes the provisioner
# token already holds. Each spec: (group, key, title, path, columns, row fn);
# `row` maps one raw REST item to a flat dict keyed by the column keys.
# ---------------------------------------------------------------------------
_AWS_CATEGORY_SPECS: list[dict[str, Any]] = [
    # --- where a VM can land -------------------------------------------------
    {
        "group": "Where a VM can land", "key": "vpcs", "title": "VPCs",
        "path": "/v1/compute/networks",
        "columns": [("id", "ID"), ("name", "Name"), ("cidr", "CIDR"), ("state", "State")],
        "row": lambda i: {"id": i.get("id"), "name": i.get("name") or "",
                          "cidr": i.get("cidr_block") or "", "state": i.get("state") or ""},
    },
    {
        "group": "Where a VM can land", "key": "subnets", "title": "Subnets",
        "path": "/v1/compute/subnets",
        "columns": [("id", "ID"), ("name", "Name"), ("cidr", "CIDR"), ("vpc", "VPC"), ("az", "AZ")],
        "row": lambda i: {"id": i.get("id"), "name": i.get("name") or "",
                          "cidr": i.get("cidr_block") or "", "vpc": i.get("vpc_id") or "",
                          "az": i.get("availability_zone") or ""},
    },
    # --- what network it can join ---------------------------------------------
    {
        "group": "Networks a VM can join", "key": "security_groups", "title": "Security Groups",
        "path": "/v1/compute/security-groups",
        "columns": [("id", "ID"), ("name", "Name"), ("vpc", "VPC"),
                    ("ingress", "Ingress rules"), ("egress", "Egress rules")],
        "row": lambda i: {"id": i.get("id"), "name": i.get("name") or "",
                          "vpc": (i.get("extra") or {}).get("vpc_id") or "",
                          "ingress": len(i.get("ingress_rules") or []),
                          "egress": len(i.get("egress_rules") or [])},
    },
    {
        "group": "Networks a VM can join", "key": "network_interfaces", "title": "Network Interfaces",
        "path": "/v1/compute/network-interfaces",
        "columns": [("id", "ID"), ("name", "Name"), ("state", "State"),
                    ("subnet", "Subnet"), ("vpc", "VPC")],
        "row": lambda i: {"id": i.get("id"), "name": i.get("name") or "",
                          "state": i.get("state") or "", "subnet": i.get("subnet_id") or "",
                          "vpc": i.get("vpc_id") or ""},
    },
    {
        "group": "Networks a VM can join", "key": "route_tables", "title": "Route Tables",
        "path": "/v1/compute/route-tables",
        "columns": [("id", "ID"), ("name", "Name"), ("routes", "Routes"), ("subnets", "Subnets")],
        "row": lambda i: {"id": i.get("id"), "name": i.get("name") or "",
                          "routes": _rt_route_summary(i), "subnets": _rt_subnet_summary(i)},
    },
    {
        "group": "Networks a VM can join", "key": "internet_gateways", "title": "Internet Gateways",
        "path": "/v1/compute/internet-gateways",
        "columns": [("id", "ID"), ("name", "Name"), ("vpc", "VPC"), ("state", "State")],
        "row": lambda i: {"id": i.get("id"), "name": i.get("name") or "",
                          "vpc": i.get("vpc_id") or "", "state": i.get("state") or ""},
    },
    {
        "group": "Networks a VM can join", "key": "floating_ips", "title": "Elastic IPs",
        "path": "/v1/compute/floating-ips",
        "columns": [("address", "Address"), ("instance", "Instance"), ("associated", "Associated")],
        "row": lambda i: {"address": i.get("address") or "",
                          "instance": i.get("instance_id") or "",
                          "associated": "yes" if i.get("associated") else "no"},
    },
    # --- what image it boots from ---------------------------------------------
    {
        # Server-side default name filter (same catalog the provision flow
        # resolves images from); no params => the REST API applies it.
        "group": "Images a VM can boot from", "key": "images", "title": "AMIs",
        "path": "/v1/compute/images",
        "columns": [("id", "ID"), ("name", "Name")],
        "row": lambda i: {"id": i.get("id"), "name": i.get("name") or ""},
    },
    # --- what storage it consumes ---------------------------------------------
    {
        "group": "Block storage a VM can consume", "key": "volumes", "title": "EBS Volumes",
        "path": "/v1/compute/volumes",
        "columns": [("id", "ID"), ("name", "Name"), ("size", "Size (GiB)"), ("state", "State")],
        "row": lambda i: {"id": i.get("id"), "name": i.get("name") or "",
                          "size": i.get("size") if i.get("size") is not None else "",
                          "state": i.get("state") or ""},
    },
    {
        # owner=self scopes to account-owned snapshots; the REST default
        # returns ALL public snapshots (tens of thousands).
        "group": "Block storage a VM can consume", "key": "snapshots", "title": "EBS Snapshots",
        "path": "/v1/compute/snapshots", "params": {"owner": "self"},
        "columns": [("id", "ID"), ("name", "Name"), ("volume", "Volume"), ("state", "State")],
        "row": lambda i: {"id": i.get("id"), "name": i.get("name") or "",
                          "volume": i.get("volume_id") or "", "state": i.get("state") or ""},
    },
    # --- what object storage already exists -------------------------------------
    {
        "group": "Object storage", "key": "buckets", "title": "S3 Buckets",
        "path": "/v1/storage/buckets",
        "columns": [("name", "Name")],
        "row": lambda i: {"name": i.get("name") or ""},
    },
    # --- who can access ---------------------------------------------------------
    {
        "group": "Access", "key": "key_pairs", "title": "Key Pairs",
        "path": "/v1/compute/key-pairs",
        "columns": [("name", "Name"), ("fingerprint", "Fingerprint")],
        "row": lambda i: {"name": i.get("name") or "", "fingerprint": i.get("fingerprint") or ""},
    },
]


class LibcloudProxy:
    def __init__(self) -> None:
        self._settings = get_settings
        self._auth = ProvisionerAuth()

    def _base(self) -> str:
        return self._settings().libcloud_rest_url.rstrip("/")

    # --- connection descriptor (X-Provider-Connection header value) ----------
    def _connection(self, cloud: str) -> dict[str, Any]:
        s = self._settings()
        if cloud == "aws":
            return {
                "provider": "aws",
                "config": {"region": s.aws_region, "secure": True},
                "auth_binding": s.aws_auth_binding,
            }
        # Live-reload NUTANIX_* from the bind-mounted my.env (hot_config); the
        # cached settings values are the fallback when my.env is absent/unset.
        ntnx_host = hot_config.get("NUTANIX_HOST") or s.ntnx_host
        ntnx_port = int(hot_config.get("NUTANIX_PORT") or s.ntnx_port)
        ntnx_api_version = hot_config.get("NUTANIX_API_VERSION") or s.ntnx_api_version
        ntnx_verify_ssl = (
            hot_config.get("NUTANIX_VERIFY_SSL") or str(s.ntnx_verify_ssl)
        ).lower() in ("true", "1", "yes")
        return {
            "provider": "nutanix",
            "config": {
                "host": ntnx_host,
                "port": ntnx_port,
                "secure": True,
                "api_version": ntnx_api_version,
                "verify_ssl_cert": ntnx_verify_ssl,
            },
            "auth_binding": s.ntnx_auth_binding,
        }

    def _headers(self, token: str, conn: dict[str, Any]) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "X-Provider-Connection": json.dumps(conn, separators=(",", ":")),
        }

    # --- low-level REST call with step recording -----------------------------
    def _call(
        self,
        client: httpx.Client,
        path: str,
        headers: dict[str, str],
        steps: list[str],
        *,
        method: str = "GET",
        json_body: Any = None,
        params: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        url = f"{self._base()}{path}"
        label = f"{method} {path}"
        try:
            r = client.request(method, url, headers=headers, json=json_body, params=params, timeout=30)
        except httpx.HTTPError as exc:
            steps.append(f"{label} -> ERROR (unreachable: {exc})")
            raise APIError("rest_unreachable", "libcloud REST API unreachable", 503) from exc
        ok = 200 <= r.status_code < 300
        steps.append(f"{label} -> {r.status_code} {'OK' if ok else 'ERR'}")
        if not ok:
            raise APIError("rest_error", f"libcloud REST {method} {path} failed", 502, {"status": r.status_code, "body": r.text[:500]})
        try:
            return r.json()
        except ValueError:
            return {}

    # --- public: list resources ---------------------------------------------
    def list_nodes(self, cloud: str) -> dict[str, Any]:
        token = self._auth.get_token(cloud)
        conn = self._connection(cloud)
        headers = self._headers(token, conn)
        specs = _AWS_CATEGORY_SPECS if cloud == "aws" else _NTNX_CATEGORY_SPECS
        with httpx.Client(timeout=30) as client:
            data = self._call(client, "/v1/compute/nodes", headers, [])  # steps not returned here
            categories = self._list_categories(client, headers, specs)
        nodes = data.get("data", []) if isinstance(data, dict) else data
        shaped = self._shape_resources(cloud, nodes)
        shaped["categories"] = categories
        return shaped

    def _list_categories(
        self, client: httpx.Client, headers: dict[str, str], specs: list[dict[str, Any]]
    ) -> list[dict[str, Any]]:
        # Fan out to the read-only list endpoints behind the provisioner token.
        # A failing category (e.g. IAM-denied on the backend account, or an
        # endpoint the provider doesn't support) degrades to an empty table
        # with an error note instead of blanking the page.
        # Rows are capped per category (the AMI catalog alone is thousands);
        # `total` keeps the true count so the portal can say "showing N of M".
        max_rows = self._settings().inventory_max_rows
        categories: list[dict[str, Any]] = []
        for spec in specs:
            cat: dict[str, Any] = {
                "group": spec["group"],
                "key": spec["key"],
                "title": spec["title"],
                "columns": [{"key": k, "label": label} for k, label in spec["columns"]],
            }
            try:
                data = self._call(client, spec["path"], headers, [], params=spec.get("params"))
                items = data.get("data", []) if isinstance(data, dict) else data
                rows = [spec["row"](i) for i in items]
                cat["total"] = len(rows)
                cat["rows"] = rows[:max_rows]
            except Exception as exc:
                msg = exc.message if isinstance(exc, APIError) else str(exc)
                log.warning("resource category %s failed: %s", spec["key"], msg)
                cat["total"] = 0
                cat["rows"] = []
                cat["error"] = msg
            categories.append(cat)
        return categories

    @staticmethod
    def _shape_resources(cloud: str, nodes: list[dict[str, Any]]) -> dict[str, Any]:
        shaped = []
        for n in nodes:
            public_ips = n.get("public_ips") or []
            private_ips = n.get("private_ips") or []
            shaped.append({
                "id": str(n.get("id") or n.get("uuid") or ""),
                "name": str(n.get("name") or ""),
                "state": str(n.get("state") or n.get("status") or "unknown"),
                "size": str(n.get("size") or n.get("size_id") or ""),
                "public_ips": [str(ip) for ip in public_ips],
                "private_ips": [str(ip) for ip in private_ips],
            })
        if cloud == "aws":
            s = get_settings()
            return {"region": s.aws_region, "nodes": shaped}
        return {"cluster": get_settings().ntnx_auth_binding, "nodes": shaped}

    # --- public: provision (replays provision_*.sh) -------------------------
    def provision(self, cloud: str, vm_name: str) -> dict[str, Any]:
        steps: list[str] = []
        try:
            token = self._auth.get_token(cloud)
            steps.append("idp_login (Dex -> OIDC token, audience libcloud-rest)")
            conn = self._connection(cloud)
            headers = self._headers(token, conn)
            steps.append(f"build_{cloud}_connection_param (auth_binding={conn['auth_binding']}, NO creds in client)")
            with httpx.Client(timeout=60) as client:
                # 3. token validation
                self._call(client, "/v1/auth/me", headers, steps)
                # 4. connection test
                self._call(client, "/v1/connections:test", headers, steps, method="POST", json_body=conn)
                # 5. catalog discovery
                locations = self._call(client, "/v1/compute/locations", headers, steps).get("data", [])
                sizes = self._call(client, "/v1/compute/sizes", headers, steps).get("data", [])
                if cloud == "aws":
                    images = self._call(client, "/v1/compute/images", headers, steps, params={"name": "*ubuntu*24.04*amd64*"}).get("data", [])
                else:
                    images = self._call(client, "/v1/compute/images", headers, steps).get("data", [])
                    self._call(client, "/v1/compute/storage-containers", headers, steps)
                # 6. list existing nodes
                self._call(client, "/v1/compute/nodes", headers, steps)
                # resolve image/size/subnet/cluster
                image_id, size_id, subnet_id, cluster_id = self._resolve(cloud, images, sizes, locations, client, headers, steps)
                # 7. create node
                body: dict[str, Any] = {
                    "name": vm_name,
                    "size": {"id": size_id},
                    "image": {"id": image_id},
                    "provider_options": {},
                }
                if cloud == "aws":
                    body["network"] = {"public_ip": True}
                    if subnet_id:
                        body["network"]["subnet_id"] = subnet_id
                else:
                    body["location"] = {"id": cluster_id}
                    if subnet_id:
                        body["network"] = {"subnet_id": subnet_id}
                created = self._call(client, "/v1/compute/nodes", headers, steps, method="POST", json_body=body).get("data", {})
            return {
                "provider": cloud,
                "vmName": vm_name,
                "status": "provisioned",
                "message": f"Provisioned via libcloud REST replay of provision_{cloud}.sh",
                "steps": steps,
                "node": created,
            }
        except APIError as exc:
            return {
                "provider": cloud,
                "vmName": vm_name,
                "status": "failed",
                "message": exc.message,
                "steps": steps,
                "error": exc.code,
                "details": exc.details,
            }

    def _resolve(
        self,
        cloud: str,
        images: list[dict[str, Any]],
        sizes: list[dict[str, Any]],
        locations: list[dict[str, Any]],
        client: httpx.Client,
        headers: dict[str, str],
        steps: list[str],
    ) -> tuple[str, str, str, str]:
        if cloud == "aws":
            # Pick an architecture-compatible AMI + instance type pair (port of
            # test_script/scripts/aws_resolve_catalog.py) so AWS doesn't reject
            # the create for arch mismatch.
            arch = "x86_64"
            image_id = aws_resolve.pick_image(images, arch)
            size_id = aws_resolve.pick_size(sizes, arch)
            subnet_resp = self._call(client, "/v1/compute/subnets", headers, steps).get("data", [])
            subnet_id = subnet_resp[0].get("id", "") if subnet_resp else ""
            steps.append(f"resolve IMAGE_ID={image_id} SIZE_ID={size_id} SUBNET_ID={subnet_id} (arch={arch})")
            return image_id, size_id, subnet_id, ""
        # nutanix
        image_id = images[0].get("id", "") if images else ""
        size_id = "small"
        cluster_id = locations[0].get("id", "") if locations else ""
        subnet_resp = self._call(client, "/v1/compute/subnets", headers, steps).get("data", [])
        subnet_id = subnet_resp[0].get("id", "") if subnet_resp else ""
        steps.append(f"resolve CLUSTER_ID={cluster_id} IMAGE_ID={image_id} SIZE_ID={size_id} SUBNET_ID={subnet_id}")
        return image_id, size_id, subnet_id, cluster_id

    # --- public: deprovision (shells out to deprovision_<cloud>.sh) ----------
    # The portal's per-row Deprovision button calls this. We do NOT reimplement
    # the curl DELETE flow here; we invoke test_script/scripts/deprovision_<cloud>.sh
    # so the script remains the single source of truth for the deprovisioning
    # sequence (OpenFGA can_provision check + curl DELETE /v1/compute/nodes/{id}).
    # One code path serves both AWS and Nutanix; only the script path, the
    # provisioner user/password, and a few cloud-specific env vars differ
    # (see _deprovision_env below).
    #
    # The script's require_token() reads a token cache file; we populate one
    # from our own ProvisionerAuth token so the script works without a
    # host-side generated/tokens/<user>.json having been written first.
    def deprovision(self, cloud: str, vm_name: str | None, vm_id: str | None) -> dict[str, Any]:
        if not vm_id and not vm_name:
            raise APIError("bad_request", "vmId or vmName is required", 400)

        s = self._settings()
        script = self._deprovision_script(cloud)
        if not script or not os.path.isfile(script):
            raise APIError(
                "deprovision_script_missing",
                f"deprovision_{cloud}.sh not found on this server",
                500,
                {"script": script},
            )

        # Acquire a libcloud-rest-audience token (same one the script would
        # obtain via idp_login.py) and hand it to the script via a temp cache.
        cache_dir, cache_path, user = self._token_cache(cloud)

        env = self._script_env(cloud, user, cache_dir)
        if vm_id:
            env["VM_ID"] = vm_id
        if vm_name:
            env["VM_NAME"] = vm_name

        # Run from the script's repo root so common.sh's REPO_ROOT-relative
        # paths (if any) resolve. When the container mounts only the scripts
        # dir, REPO_ROOT resolves to a parent without .env/dex.env/fga.env, so
        # the env vars we pass here are the ones common.sh uses.
        cwd = str(Path(script).resolve().parent.parent)

        try:
            proc = subprocess.run(
                ["bash", script],
                env=env,
                cwd=cwd,
                capture_output=True,
                text=True,
                timeout=s.deprovision_timeout_seconds,
            )
        except subprocess.TimeoutExpired as exc:
            raise APIError(
                "deprovision_timeout",
                f"deprovision_{cloud}.sh timed out",
                504,
                {"timeout_seconds": s.deprovision_timeout_seconds},
            ) from exc
        finally:
            self._cleanup_cache(cache_path, cache_dir)

        ok = proc.returncode == 0
        return {
            "provider": cloud,
            "vmId": vm_id or "",
            "vmName": vm_name or "",
            "status": "deprovisioned" if ok else "failed",
            "message": f"deprovision_{cloud}.sh exit={proc.returncode}",
            "exitCode": proc.returncode,
            # Truncate so a chatty script run doesn't blow up the JSON response.
            "stdout": (proc.stdout or "")[-4000:],
            "stderr": (proc.stderr or "")[-4000:],
        }

    # --- public: provision the bastion + internal private VM pair ------------
    # The portal's "Provision Private VM Machine" button calls this. As with
    # deprovision, we do NOT reimplement the orchestration in Python; we invoke
    # the per-cloud script so it stays the single source of truth for the 2-VM
    # sequence:
    #   aws     -> test_script/scripts/provision_aws_private.sh
    #              (aws_bastion_internal_server.md: dedicated VPC with a public
    #              subnet for the bastion + a private subnet with NO internet
    #              route for the internal server)
    #   nutanix -> test_script/scripts/provision_nutanix_bastion_private.sh
    #              (nutanix_bastion_internal_server.md: external + isolated
    #              VLAN pair)
    # The tenant's cloud credentials are resolved server-side by the libcloud
    # REST API from Vault (secret/libcloud/<auth_binding>) — never handled here.
    def provision_private(self, cloud: str, pair_name: str) -> dict[str, Any]:
        s = self._settings()
        script = self._provision_private_script(cloud)
        if not script or not os.path.isfile(script):
            raise APIError(
                "provision_private_script_missing",
                f"private VM pair provisioning script for {cloud} not found on this server",
                500,
                {"script": script, "cloud": cloud},
            )
        script_name = os.path.basename(script)

        cache_dir, cache_path, user = self._token_cache(cloud)

        env = self._script_env(cloud, user, cache_dir)
        # Actually create the VMs (the script dry-runs unless PROVISION=1) and
        # pin both names so the response matches what the script creates.
        env["PROVISION"] = "1"
        env["VM_PREFIX"] = pair_name
        env["BASTION_NAME"] = f"{pair_name}-bastion"
        env["INTERNAL_NAME"] = f"{pair_name}-internal"

        # Run from the script's repo root so common.sh's REPO_ROOT-relative
        # paths (if any) resolve — same convention as deprovision above.
        cwd = str(Path(script).resolve().parent.parent)

        try:
            proc = subprocess.run(
                ["bash", script],
                env=env,
                cwd=cwd,
                capture_output=True,
                text=True,
                timeout=s.provision_private_timeout_seconds,
            )
        except subprocess.TimeoutExpired as exc:
            raise APIError(
                "provision_private_timeout",
                f"{script_name} timed out",
                504,
                {"timeout_seconds": s.provision_private_timeout_seconds},
            ) from exc
        finally:
            self._cleanup_cache(cache_path, cache_dir)

        ok = proc.returncode == 0
        return {
            "provider": cloud,
            "vmName": pair_name,
            "bastionName": env["BASTION_NAME"],
            "internalName": env["INTERNAL_NAME"],
            "status": "provisioned" if ok else "failed",
            "message": f"{script_name} exit={proc.returncode}",
            "exitCode": proc.returncode,
            # Truncate so a chatty script run doesn't blow up the JSON response.
            "stdout": (proc.stdout or "")[-4000:],
            "stderr": (proc.stderr or "")[-4000:],
        }

    # --- script shell-out helpers (shared by deprovision + private-pair) -----
    def _token_cache(self, cloud: str) -> tuple[str, str, str]:
        """Acquire a libcloud-rest-audience token (same one the script would
        obtain via idp_login.py) and write it to a temp cache the script's
        require_token() can read, so the script works without a host-side
        generated/tokens/<user>.json having been written first.
        Returns (cache_dir, cache_path, user); the caller MUST _cleanup_cache()."""
        token = self._auth.get_token_full(cloud)
        cache_dir = tempfile.mkdtemp(prefix=f"script-{cloud}-tokens-")
        user = self._script_user(cloud)
        cache_path = os.path.join(cache_dir, f"{user}.json")
        try:
            with open(cache_path, "w", encoding="utf-8") as fh:
                json.dump(
                    {
                        "access_token": token.get("access_token", ""),
                        "refresh_token": token.get("refresh_token", ""),
                    },
                    fh,
                )
        except OSError as exc:
            self._cleanup_cache(cache_path, cache_dir)
            raise APIError("script_token_cache", "could not write token cache", 500) from exc
        return cache_dir, cache_path, user

    @staticmethod
    def _deprovision_script(cloud: str) -> str:
        s = get_settings()
        if cloud == "aws":
            return s.deprovision_aws_script
        if cloud == "nutanix":
            return s.deprovision_ntnx_script
        return ""

    @staticmethod
    def _provision_private_script(cloud: str) -> str:
        s = get_settings()
        if cloud == "aws":
            return s.provision_private_aws_script
        if cloud == "nutanix":
            return s.provision_private_ntnx_script
        return ""

    @staticmethod
    def _script_user(cloud: str) -> str:
        s = get_settings()
        if cloud == "aws":
            return s.provisioner_aws_user or "aws-admin"
        if cloud == "nutanix":
            return s.provisioner_ntnx_user or "ntnx-admin"
        return "cloud-admin"

    @staticmethod
    def _script_env(cloud: str, user: str, cache_dir: str) -> dict[str, str]:
        # Common env shared by the shelled-out scripts: PATH/HOME, the libcloud
        # REST + Dex + FGA endpoints, and the temp token cache we just populated.
        s = get_settings()
        env = {
            "PATH": os.environ.get(
                "PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            ),
            "HOME": os.environ.get("HOME", "/tmp"),
            "LIBCLOUD_USER": user,
            "LIBCLOUD_REST_URL": s.libcloud_rest_url,
            "DEX_URL": s.dex_url,
            "DEX_TOKEN_URL": s.dex_token_url,
            "LIBCLOUD_OIDC_CLIENT_ID": s.libcloud_oidc_client_id,
            "LIBCLOUD_OIDC_CLIENT_SECRET": s.libcloud_oidc_client_secret,
            "FGA_API_URL": s.fga_api_url,
            "FGA_STORE_ID": s.fga_store_id,
            "FGA_MODEL_ID": s.fga_model_id,
            "FGA_API_OBJECT": "libcloud_api:main",
            "IDP_TOKEN_CACHE_DIR": cache_dir,
        }
        if cloud == "aws":
            # common.sh resolves the IdP password at SOURCE time and `:?`-aborts
            # if it's empty. We already hold a valid provisioner token, so hand
            # the password through to satisfy that check. The script never logs it.
            env.update(
                {
                    "LIBCLOUD_PASSWORD": s.provisioner_aws_password,
                    "LIBCLOUD_PASSWORD_AWS_ADMIN": s.provisioner_aws_password,
                    "AWS_REGION": s.aws_region,
                    "LIBCLOUD_AWS_AUTH_BINDING": s.aws_auth_binding,
                }
            )
        elif cloud == "nutanix":
            env.update(
                {
                    "LIBCLOUD_PASSWORD": s.provisioner_ntnx_password,
                    "LIBCLOUD_PASSWORD_NTNX_ADMIN": s.provisioner_ntnx_password,
                    "LIBCLOUD_NTNX_AUTH_BINDING": s.ntnx_auth_binding,
                    "NUTANIX_HOST": hot_config.get("NUTANIX_HOST") or s.ntnx_host,
                    "NUTANIX_PORT": hot_config.get("NUTANIX_PORT") or str(s.ntnx_port),
                    "NUTANIX_API_VERSION": hot_config.get("NUTANIX_API_VERSION") or s.ntnx_api_version,
                    "NUTANIX_VERIFY_SSL": hot_config.get("NUTANIX_VERIFY_SSL")
                    or ("true" if s.ntnx_verify_ssl else "false"),
                }
            )
        return env

    # --- public: update (edit) a VM's parameters -----------------------------
    # The portal's per-row Edit button calls this. The identity service has
    # already run the OpenFGA can_update check; this method just replays the
    # libcloud REST PATCH /v1/compute/nodes/{id} (NodeUpdateRequest). Only the
    # fields the caller supplied are forwarded, so a partial edit is allowed.
    # Cloud-agnostic: the libcloud REST compute service routes Nutanix PATCHes
    # through driver.ex_update_node and AWS through the standard update path
    # (libcloud.rest/app/compute/service.py), so one code path covers both.
    def update_node(self, cloud: str, vm_id: str, updates: dict[str, Any]) -> dict[str, Any]:
        if not vm_id:
            raise APIError("bad_request", "vmId is required", 400)

        body: dict[str, Any] = {"action": "update"}
        if updates.get("name") is not None:
            body["name"] = updates["name"]
        if updates.get("new_size_id") is not None:
            body["new_size_id"] = updates["new_size_id"]
        if updates.get("memory_mib") is not None:
            body["memory_mib"] = updates["memory_mib"]
        if updates.get("tag_key") is not None:
            body["tag_key"] = updates["tag_key"]
            body["tag_value"] = updates.get("tag_value") or ""
        # Nothing to change -> no-op rather than an empty PATCH.
        if not any(k in body for k in ("name", "new_size_id", "memory_mib", "tag_key")):
            return {
                "provider": cloud,
                "vmId": vm_id,
                "status": "noop",
                "message": "No editable fields supplied; nothing to update.",
            }

        token = self._auth.get_token(cloud)
        conn = self._connection(cloud)
        headers = self._headers(token, conn)
        steps: list[str] = [f"idp_login (Dex -> OIDC token, audience libcloud-rest)"]
        try:
            with httpx.Client(timeout=60) as client:
                self._call(client, "/v1/auth/me", headers, steps)
                updated = self._call(
                    client, f"/v1/compute/nodes/{vm_id}", headers, steps,
                    method="PATCH", json_body=body,
                ).get("data", {})
        except APIError as exc:
            return {
                "provider": cloud,
                "vmId": vm_id,
                "status": "failed",
                "message": exc.message,
                "steps": steps,
                "error": exc.code,
                "details": exc.details,
            }
        return {
            "provider": cloud,
            "vmId": vm_id,
            "status": "updated",
            "message": f"Updated VM {vm_id} via libcloud REST PATCH /v1/compute/nodes/{vm_id}",
            "steps": steps,
            "node": updated,
        }

    @staticmethod
    def _cleanup_cache(cache_path: str, cache_dir: str) -> None:
        # Best-effort removal of the temp token cache (it contains a bearer
        # token); never raise on failure.
        try:
            if os.path.isfile(cache_path):
                os.unlink(cache_path)
            if os.path.isdir(cache_dir):
                os.rmdir(cache_dir)
        except OSError:
            pass
