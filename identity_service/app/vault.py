from __future__ import annotations

import json
import logging
import urllib.error
import urllib.request
from typing import Any

from app.config import get_settings
from app.errors import APIError

log = logging.getLogger(__name__)

# The identity service's scoped Vault capability for the company-admin
# "create department" flow (design_company_department.md §3). It mints
# per-department AppRoles and writes/reads per-department backend credentials
# using the narrow department-orchestrator token (NOT root), so it cannot read
# any AppRole secret_id back and cannot touch non-libcloud paths. Every call is
# gated upstream by OpenFGA can_create_department / can_manage_credentials.

KV_MOUNT = "secret"
KV_PREFIX = "libcloud"
AUTH_KV_PREFIX = "libcloud-vault-auth"
APPROLE_MOUNT = "approle"


class VaultService:
    """Per-department Vault orchestration (AppRole + credential), scoped to the
    department-orchestrator token."""

    def __init__(self) -> None:
        s = get_settings()
        self.addr = s.vault_addr.rstrip("/")
        self.token = s.vault_dept_orchestrator_token

    @property
    def enabled(self) -> bool:
        return bool(self.addr and self.token)

    def _request(
        self, method: str, path: str, body: dict | None = None
    ) -> dict[str, Any]:
        if not self.enabled:
            raise APIError(
                "vault_unconfigured",
                "Vault is not configured for department orchestration "
                "(VAULT_ADDR / VAULT_DEPT_ORCHESTRATOR_TOKEN missing)",
                503,
            )
        if not path.startswith("/v1/"):
            path = "/v1" + path if path.startswith("/") else "/v1/" + path
        url = self.addr + path
        data = json.dumps(body).encode("utf-8") if body is not None else None
        headers = {"X-Vault-Token": self.token}
        if data is not None:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                return json.loads(resp.read().decode("utf-8") or "{}")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            log.error("Vault %s %s failed: %s", method, path, detail)
            raise APIError(
                "vault_error",
                "Vault request failed",
                503,
                {"path": path, "detail": detail[:400]},
            ) from exc
        except urllib.error.URLError as exc:
            raise APIError("vault_unreachable", "Vault is unreachable", 503) from exc

    def create_department_identity(self, dept: str) -> None:
        """Create the per-department Vault AppRole identity: ACL policy
        ``libcloud-read-<dept>``, AppRole role ``libcloud-<dept>``, a minted
        secret_id, and the role_id+secret_id auth material at
        ``secret/data/libcloud-vault-auth/libcloud-<dept>``. Mirrors
        scripts/vault_tenant_role.py, but via the department-orchestrator token.
        The role_id/secret_id are NEVER returned to the caller (invisible to the
        company admin)."""
        role = f"libcloud-{dept}"
        policy_name = f"libcloud-read-{dept}"
        policy = (
            f'path "{KV_MOUNT}/data/{KV_PREFIX}/{dept}" {{ capabilities = ["read"] }}\n'
            f'path "{KV_MOUNT}/metadata/{KV_PREFIX}/{dept}" {{ capabilities = ["read", "list"] }}\n'
        )

        self._request("PUT", f"/sys/policies/acl/{policy_name}", {"policy": policy})
        self._request(
            "POST",
            f"/auth/{APPROLE_MOUNT}/role/{role}",
            {
                "token_policies": [policy_name],
                "token_ttl": "60m",
                "token_max_ttl": "120m",
            },
        )
        role_id_resp = self._request(
            "GET", f"/auth/{APPROLE_MOUNT}/role/{role}/role-id"
        )
        role_id = (role_id_resp.get("data") or {}).get("role_id", "")
        if not role_id:
            raise APIError("vault_error", f"AppRole {role} returned no role_id", 503)
        sid_resp = self._request(
            "POST", f"/auth/{APPROLE_MOUNT}/role/{role}/secret-id", {}
        )
        secret_id = (sid_resp.get("data") or {}).get("secret_id", "")
        if not secret_id:
            raise APIError("vault_error", f"AppRole {role} returned no secret_id", 503)
        self._request(
            "POST",
            f"/{KV_MOUNT}/data/{AUTH_KV_PREFIX}/{role}",
            {"data": {"role_id": role_id, "secret_id": secret_id}},
        )
        log.info("Created department AppRole identity for %s", dept)

    def write_department_credential(
        self, dept: str, key: str, secret: str, host: str = ""
    ) -> None:
        """Write the department's backend cloud credential to
        ``secret/data/libcloud/<dept>`` = {key, secret[, host]}. ``host`` is the
        Nutanix Prism Central URL (empty for AWS). Fire-and-forget: the value is
        not echoed back to the caller."""
        data = {"key": key, "secret": secret}
        if host:
            data["host"] = host
        self._request(
            "POST",
            f"/{KV_MOUNT}/data/{KV_PREFIX}/{dept}",
            {"data": data},
        )

    def read_department_credential(self, dept: str) -> dict[str, str]:
        """Read the department's backend cloud credential {key, secret[, host]}.
        Gated upstream by OpenFGA can_manage_credentials (view/rotate, D1)."""
        payload = self._request("GET", f"/{KV_MOUNT}/data/{KV_PREFIX}/{dept}")
        data = (payload.get("data") or {}).get("data") or {}
        if not isinstance(data, dict):
            raise APIError(
                "server_credentials_missing",
                f"Vault secret '{dept}' has no data",
                503,
            )
        return {str(k): str(v) for k, v in data.items()}

    def write_department_provider_credential(
        self, dept: str, cloud: str, key: str, secret: str, host: str = ""
    ) -> None:
        """Write one provider's backend credential for a multi-provider
        department to ``secret/data/libcloud/<dept>-<cloud>`` (kept separate
        from the primary ``secret/data/libcloud/<dept>`` secret the provisioning
        path reads). Fire-and-forget; the value is not echoed back."""
        data = {"key": key, "secret": secret}
        if host:
            data["host"] = host
        self._request(
            "POST",
            f"/{KV_MOUNT}/data/{KV_PREFIX}/{dept}-{cloud}",
            {"data": data},
        )

    def read_department_provider_credential(self, dept: str, cloud: str) -> dict[str, str]:
        """Read a single provider's backend credential {key, secret[, host]} for
        a multi-provider department."""
        payload = self._request("GET", f"/{KV_MOUNT}/data/{KV_PREFIX}/{dept}-{cloud}")
        data = (payload.get("data") or {}).get("data") or {}
        if not isinstance(data, dict):
            raise APIError(
                "server_credentials_missing",
                f"Vault secret '{dept}-{cloud}' has no data",
                503,
            )
        return {str(k): str(v) for k, v in data.items()}


_vault_service: VaultService | None = None


def get_vault_service() -> VaultService:
    global _vault_service
    if _vault_service is None:
        _vault_service = VaultService()
    return _vault_service
