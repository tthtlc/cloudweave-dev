"""Vault KV v2 client for backend cloud credentials.

The REST API reads its own backend identity (AWS / Nutanix credentials) from
Vault at runtime instead of holding raw credentials in environment files. This
implements the "secret broker" model from ``rest_api_security.md``: the API uses
its own IAM role / service account, and credentials are stored as encrypted
secrets in Vault (KV v2) rather than passed by clients or kept in plaintext env.

Per-tenant identities: instead of a single token that can read every tenant's
secret, each tenant has its own Vault AppRole (the tenant's "vault user"). The
tenant -> vault_user mapping is resolved from OpenFGA by the policy engine and
passed in as ``vault_user``. The client:

  1. reads the AppRole login material (role_id + secret_id) from
     ``secret/data/libcloud-vault-auth/<vault_user>`` using the narrow
     orchestrator token (VAULT_TOKEN), then
  2. performs an AppRole login to obtain a short-lived, tenant-scoped token, and
  3. reads ``secret/data/libcloud/<binding>`` with that token.

Secrets and AppRole tokens are cached in-process for a short TTL to avoid a
Vault round-trip on every backend call. The cache holds the resolved plaintext
only in memory.
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

# Cache resolved secrets / auth material for a short window. Backend credentials
# are long-lived (or rotated by the platform), so a modest TTL is safe.
_CACHE_TTL_SECONDS = 30.0
# AppRole tokens are short-lived; refresh a little before they expire.
_TOKEN_REFRESH_MARGIN_SECONDS = 30.0
# Fallback TTL when Vault returns no lease_duration (shouldn't happen).
_DEFAULT_TOKEN_TTL_SECONDS = 300.0


class VaultClient:
    def __init__(self) -> None:
        self._secret_cache: dict[str, tuple[float, dict[str, str]]] = {}
        self._auth_cache: dict[str, tuple[float, dict[str, str]]] = {}
        self._token_cache: dict[str, tuple[float, str]] = {}

    @property
    def enabled(self) -> bool:
        settings = get_settings()
        return bool(settings.vault_addr and settings.vault_token)

    def _auth_path(self, vault_user: str) -> str:
        s = get_settings()
        return f"/v1/{s.vault_mount}/data/{s.vault_approle_auth_prefix}/{vault_user}"

    def _secret_path(self, binding: str) -> str:
        s = get_settings()
        return f"/v1/{s.vault_mount}/data/{s.vault_kv_prefix}/{binding}"

    def _request(
        self, method: str, path: str, token: str, body: dict | None = None
    ) -> dict:
        s = get_settings()
        url = s.vault_addr.rstrip("/") + path
        data = json.dumps(body).encode("utf-8") if body is not None else None
        headers: dict[str, str] = {"Accept": "application/json"}
        if token:
            headers["X-Vault-Token"] = token
        if data is not None:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return json.loads(resp.read().decode("utf-8") or "{}")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            if exc.code == 404:
                raise APIError(
                    code="server_credentials_missing",
                    message=f"Vault secret not found at {path}",
                    status_code=503,
                    details={"path": path},
                ) from exc
            log.error("Vault %s %s failed: %s", method, path, detail)
            raise APIError(
                code="server_credentials_unavailable",
                message="Vault request failed",
                status_code=503,
                details={"path": path, "detail": detail},
            ) from exc
        except urllib.error.URLError as exc:
            raise APIError(
                code="server_credentials_unavailable",
                message="Vault is unreachable",
                status_code=503,
                details={"path": path},
            ) from exc

    def _auth_material(self, vault_user: str) -> dict[str, str]:
        """Read the AppRole login material (role_id + secret_id) for *vault_user*
        using the orchestrator token (VAULT_TOKEN)."""
        now = time.time()
        cached = self._auth_cache.get(vault_user)
        if cached and (now - cached[0]) < _CACHE_TTL_SECONDS:
            return cached[1]

        s = get_settings()
        payload = self._request("GET", self._auth_path(vault_user), s.vault_token)
        data = (payload.get("data") or {}).get("data") or {}
        if not isinstance(data, dict):
            data = {}
        typed = {str(k): str(v) for k, v in data.items()}
        if not typed.get("role_id") or not typed.get("secret_id"):
            raise APIError(
                code="server_credentials_missing",
                message=f"Vault AppRole auth material for '{vault_user}' is missing role_id/secret_id",
                status_code=503,
                details={"vault_user": vault_user},
            )
        self._auth_cache[vault_user] = (now, typed)
        return typed

    def _approle_token(self, vault_user: str) -> str:
        """Obtain a short-lived tenant token by logging in as *vault_user*'s AppRole."""
        now = time.time()
        cached = self._token_cache.get(vault_user)
        if cached and cached[0] > now + _TOKEN_REFRESH_MARGIN_SECONDS:
            return cached[1]

        material = self._auth_material(vault_user)
        s = get_settings()
        resp = self._request(
            "POST",
            f"/v1/auth/{s.vault_approle_mount}/login",
            token="",
            body={"role_id": material["role_id"], "secret_id": material["secret_id"]},
        )
        auth = resp.get("auth") or {}
        token = auth.get("client_token") or ""
        if not token:
            raise APIError(
                code="server_credentials_unavailable",
                message=f"Vault AppRole login failed for '{vault_user}'",
                status_code=503,
                details={"vault_user": vault_user},
            )
        try:
            lease = float(auth.get("lease_duration") or _DEFAULT_TOKEN_TTL_SECONDS)
        except (TypeError, ValueError):
            lease = _DEFAULT_TOKEN_TTL_SECONDS
        self._token_cache[vault_user] = (now + lease, token)
        return token

    def read_secret(self, binding: str, vault_user: str | None = None) -> dict[str, str]:
        """Read a KV v2 secret by binding (tenant id), e.g. 'aws' or 'aws-dev'.

        Reads ``secret/data/libcloud/<binding>`` authenticated as the tenant's
        per-tenant AppRole identity (*vault_user*, default ``libcloud-<binding>``).
        """
        if not self.enabled:
            raise APIError(
                code="server_credentials_missing",
                message="Vault is not configured (VAULT_ADDR / VAULT_TOKEN missing)",
                status_code=503,
            )

        vault_user = vault_user or f"libcloud-{binding}"
        now = time.time()
        cached = self._secret_cache.get(binding)
        if cached and (now - cached[0]) < _CACHE_TTL_SECONDS:
            return cached[1]

        token = self._approle_token(vault_user)
        payload = self._request("GET", self._secret_path(binding), token)
        data = (payload.get("data") or {}).get("data") or {}
        if not isinstance(data, dict):
            raise APIError(
                code="server_credentials_missing",
                message=f"Vault secret '{binding}' has no data",
                status_code=503,
                details={"auth_binding": binding},
            )
        typed = {str(k): str(v) for k, v in data.items()}
        self._secret_cache[binding] = (now, typed)
        return typed


_vault_client: Optional[VaultClient] = None


def get_vault_client() -> VaultClient:
    global _vault_client
    if _vault_client is None:
        _vault_client = VaultClient()
    return _vault_client
