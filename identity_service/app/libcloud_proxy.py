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
        token = self._auth.get_token_full(cloud)
        cache_dir = tempfile.mkdtemp(prefix=f"deprovision-{cloud}-tokens-")
        user = self._deprovision_user(cloud)
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
            raise APIError("deprovision_token_cache", "could not write token cache", 500) from exc

        env = self._deprovision_env(cloud, user, cache_dir)
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

    # --- deprovision helpers (per-cloud script + env) ------------------------
    @staticmethod
    def _deprovision_script(cloud: str) -> str:
        s = get_settings()
        if cloud == "aws":
            return s.deprovision_aws_script
        if cloud == "nutanix":
            return s.deprovision_ntnx_script
        return ""

    @staticmethod
    def _deprovision_user(cloud: str) -> str:
        s = get_settings()
        if cloud == "aws":
            return s.provisioner_aws_user or "aws-admin"
        if cloud == "nutanix":
            return s.provisioner_ntnx_user or "ntnx-admin"
        return "cloud-admin"

    @staticmethod
    def _deprovision_env(cloud: str, user: str, cache_dir: str) -> dict[str, str]:
        # Common env shared by both deprovision_<cloud>.sh scripts: PATH/HOME,
        # the OpenFGA JWKS-refresh skip, the libcloud REST + Dex + FGA endpoints,
        # and the temp token cache we just populated.
        s = get_settings()
        env = {
            "PATH": os.environ.get(
                "PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            ),
            "HOME": os.environ.get("HOME", "/tmp"),
            # Suppress common.sh's openfga_ensure_fresh.sh call (the identity
            # service already keeps OpenFGA's JWKS fresh; the helper is not
            # mounted in the container and would just emit a warning).
            "OPENFGA_SKIP_RESTART": "1",
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
                    "NUTANIX_HOST": s.ntnx_host,
                    "NUTANIX_PORT": str(s.ntnx_port),
                    "NUTANIX_API_VERSION": s.ntnx_api_version,
                    "NUTANIX_VERIFY_SSL": "true" if s.ntnx_verify_ssl else "false",
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
