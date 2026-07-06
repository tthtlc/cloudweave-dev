"""Vault KV v2 client for backend cloud credentials.

The REST API reads its own backend identity (AWS / Nutanix credentials) from
Vault at runtime instead of holding raw credentials in environment files. This
implements the "secret broker" model from ``rest_api_security.md``: the API uses
its own IAM role / service account, and credentials are stored as encrypted
secrets in Vault (KV v2) rather than passed by clients or kept in plaintext env.

Secrets are cached in-process for a short TTL to avoid a Vault round-trip on
every backend call. The cache holds the resolved plaintext only in memory.
"""
from __future__ import annotations

import json
import logging
import time
import urllib.error
import urllib.request
from typing import Optional

from app.common.errors import APIError
from app.config.settings import get_settings

log = logging.getLogger(__name__)

# Cache resolved secrets for a short window. Backend credentials are long-lived
# (or rotated by the platform), so a modest TTL is safe and avoids per-request
# Vault load.
_CACHE_TTL_SECONDS = 30.0


class VaultClient:
    def __init__(self) -> None:
        self._cache: dict[str, tuple[float, dict[str, str]]] = {}

    @property
    def enabled(self) -> bool:
        settings = get_settings()
        return bool(settings.vault_addr and settings.vault_token)

    def _path(self, binding: str) -> str:
        settings = get_settings()
        return f"/v1/{settings.vault_mount}/data/{settings.vault_kv_prefix}/{binding}"

    def read_secret(self, binding: str) -> dict[str, str]:
        """Read a KV v2 secret by binding (tenant id), e.g. 'aws' or 'aws-dev'.

        Reads ``secret/data/libcloud/<binding>`` — one secret per tenant.
        """
        if not self.enabled:
            raise APIError(
                code="server_credentials_missing",
                message="Vault is not configured (VAULT_ADDR / VAULT_TOKEN missing)",
                status_code=503,
            )

        now = time.time()
        cached = self._cache.get(binding)
        if cached and (now - cached[0]) < _CACHE_TTL_SECONDS:
            return cached[1]

        settings = get_settings()
        url = settings.vault_addr.rstrip("/") + self._path(binding)
        req = urllib.request.Request(url, method="GET", headers={
            "X-Vault-Token": settings.vault_token,
            "Accept": "application/json",
        })
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                payload = json.loads(resp.read().decode("utf-8") or "{}")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            if exc.code == 404:
                raise APIError(
                    code="server_credentials_missing",
                    message=f"Vault secret not found for binding '{binding}'",
                    status_code=503,
                    details={"auth_binding": binding},
                ) from exc
            log.error("Vault read failed for %s: %s", binding, detail)
            raise APIError(
                code="server_credentials_unavailable",
                message="Vault secret read failed",
                status_code=503,
                details={"auth_binding": binding, "detail": detail},
            ) from exc
        except urllib.error.URLError as exc:
            raise APIError(
                code="server_credentials_unavailable",
                message="Vault is unreachable",
                status_code=503,
                details={"auth_binding": binding},
            ) from exc

        data = (payload.get("data") or {}).get("data") or {}
        if not isinstance(data, dict):
            raise APIError(
                code="server_credentials_missing",
                message=f"Vault secret '{binding}' has no data",
                status_code=503,
                details={"auth_binding": binding},
            )
        typed = {str(k): str(v) for k, v in data.items()}
        self._cache[binding] = (now, typed)
        return typed


_vault_client: Optional[VaultClient] = None


def get_vault_client() -> VaultClient:
    global _vault_client
    if _vault_client is None:
        _vault_client = VaultClient()
    return _vault_client
