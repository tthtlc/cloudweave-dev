from __future__ import annotations

import logging
from typing import Any

import httpx

from app.config import get_settings
from app.errors import APIError

log = logging.getLogger(__name__)

# The identity service is an authZ-gated orchestrator over the libcloud REST
# API (:8765). The REST API holds the backend cloud identity (server-side IAM
# role / auth_binding + Vault secret); the client never handles credentials
# (see server/README.md §Provisioning contract).
#
# The exact orchestration order the backend MUST replay lives in:
#   test_script/scripts/provision_aws.sh
#   test_script/scripts/provision_nutanix.sh
# (mirrored by MOCK_AWS_STEPS / MOCK_NUTANIX_STEPS in server/src/services/mockData.js).
# Below, `provision()` returns the contract-shaped result with the step list;
# the actual replay is a TODO wired to call the REST API in that order.


class LibcloudProxy:
    def __init__(self) -> None:
        self._settings = get_settings

    def _base(self) -> str:
        return self._settings().libcloud_rest_url.rstrip("/")

    def list_nodes(self, cloud: str) -> dict[str, Any]:
        """GET /v1/compute/nodes against the libcloud REST API, shaped into the
        portal's /api/resources/{cloud} contract."""
        try:
            resp = httpx.get(f"{self._base()}/v1/compute/nodes", timeout=15, headers={"Accept": "application/json"})
        except httpx.HTTPError as exc:
            raise APIError("rest_unreachable", "libcloud REST API unreachable", 503) from exc
        if resp.status_code != 200:
            raise APIError("rest_error", "libcloud REST API error", 502, {"status": resp.status_code, "body": resp.text})
        nodes = resp.json().get("nodes") or resp.json().get("data") or []
        return self._shape_resources(cloud, nodes)

    @staticmethod
    def _shape_resources(cloud: str, nodes: list[dict[str, Any]]) -> dict[str, Any]:
        # Normalize libcloud node objects into the portal's expected shape
        # (see mockData.js MOCK_AWS_RESOURCES / MOCK_NUTANIX_RESOURCES).
        shaped = []
        for n in nodes:
            shaped.append({
                "id": str(n.get("id") or n.get("uuid") or ""),
                "name": str(n.get("name") or ""),
                "state": str(n.get("state") or n.get("status") or "unknown"),
                "size": str(n.get("size") or n.get("size_id") or ""),
            })
        if cloud == "aws":
            return {"region": "ap-southeast-1", "nodes": shaped}  # TODO: pull region from connection
        return {"cluster": "nutanix", "nodes": shaped}

    def provision(self, cloud: str, vm_name: str) -> dict[str, Any]:
        """Submit a provisioning job to the libcloud REST API.

        TODO (real implementation): replay the exact step order from
        test_script/scripts/provision_{aws,nutanix}.sh:
            1. idp_login (Dex -> OIDC token for the REST API)
            2. build_{aws,nutanix}_connection_param (region + auth_binding, NO creds in client)
            3. GET /v1/me, GET /v1/connection/test
            4. catalog discovery (locations, sizes, images, [storage-containers for nutanix])
            5. GET /v1/compute/nodes
            6. resolve IMAGE_ID/SIZE_ID/SUBNET_ID ([CLUSTER_ID for nutanix])
            7. POST /v1/compute/nodes
            8. optional teardown_libcloud_vms (if TEARDOWN_VMS=1)
        The REST API holds the backend cloud identity in Vault; this service
        only forwards the request with the caller's authZ context.
        """
        steps = _PROVISION_STEPS[cloud]
        # For now we return the contract-shaped "queued" response so the portal
        # UX works end-to-end. Replace with the real REST API replay above.
        log.warning("provision(%s) returning stubbed queued result; real replay TODO", cloud)
        return {
            "provider": cloud,
            "vmName": vm_name,
            "status": "queued",
            "message": f"Provisioning request accepted (stub). Backend must replay the {cloud} script sequence.",
            "steps": steps,
        }


_PROVISION_STEPS = {
    "aws": [
        "idp_login (Dex -> OIDC token)",
        "build_aws_connection_param (region + auth_binding, NO creds in client)",
        "GET /v1/me",
        "GET /v1/connection/test",
        "GET /v1/compute/locations",
        "GET /v1/compute/sizes",
        "GET /v1/compute/images?name=<filter>",
        "GET /v1/compute/nodes",
        "resolve IMAGE_ID/SIZE_ID (architecture-compatible)",
        "GET /v1/compute/subnets",
        "POST /v1/compute/nodes  (name, size, image, network.public_ip, subnet_id)",
        "optional teardown_libcloud_vms (if TEARDOWN_VMS=1)",
    ],
    "nutanix": [
        "idp_login (Dex -> OIDC token)",
        "build_nutanix_connection_param (auth_binding, NO creds in client)",
        "GET /v1/me",
        "GET /v1/connection/test",
        "GET /v1/compute/locations",
        "GET /v1/compute/sizes",
        "GET /v1/compute/images",
        "GET /v1/compute/storage-containers",
        "GET /v1/compute/nodes",
        "resolve CLUSTER_ID/IMAGE_ID/SIZE_ID/SUBNET_ID",
        "POST /v1/compute/nodes  (name, size, image, location, network.subnet_id)",
        "optional teardown_libcloud_vms (if TEARDOWN_VMS=1)",
    ],
}
