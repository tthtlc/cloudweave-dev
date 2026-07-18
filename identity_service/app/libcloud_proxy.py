from __future__ import annotations

import json
import logging
from typing import Any

import httpx

from app.config import get_settings
from app.errors import APIError
from app.idp_login import ProvisionerAuth
from app import aws_resolve

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
        return {
            "provider": "nutanix",
            "config": {
                "host": s.ntnx_host,
                "port": s.ntnx_port,
                "secure": True,
                "api_version": s.ntnx_api_version,
                "verify_ssl_cert": s.ntnx_verify_ssl,
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
        with httpx.Client(timeout=30) as client:
            data = self._call(client, "/v1/compute/nodes", headers, [])  # steps not returned here
        nodes = data.get("data", []) if isinstance(data, dict) else data
        return self._shape_resources(cloud, nodes)

    @staticmethod
    def _shape_resources(cloud: str, nodes: list[dict[str, Any]]) -> dict[str, Any]:
        shaped = []
        for n in nodes:
            shaped.append({
                "id": str(n.get("id") or n.get("uuid") or ""),
                "name": str(n.get("name") or ""),
                "state": str(n.get("state") or n.get("status") or "unknown"),
                "size": str(n.get("size") or n.get("size_id") or ""),
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
                    images = self._call(client, "/v1/compute/images", headers, steps, params={"name": "*ubuntu*"}).get("data", [])
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
