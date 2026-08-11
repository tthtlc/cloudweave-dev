from __future__ import annotations

import json
import logging
import urllib.error
import urllib.request
from typing import Optional

from app.common.errors import APIError
from app.config.settings import get_settings

log = logging.getLogger(__name__)


class FgaClient:
    def __init__(self) -> None:
        settings = get_settings()
        self.base_url = settings.fga_api_url.rstrip("/")
        self.store_id = settings.fga_store_id
        self.model_id = settings.fga_model_id
        self.store_name = settings.fga_store_name
        self._discovered = False

    # -- auto-discovery --------------------------------------------------------

    def _ensure_discovered(self) -> None:
        """Auto-discover store and model IDs from the OpenFGA API.

        When FGA_STORE_ID / FGA_MODEL_ID are not explicitly configured the
        client queries OpenFGA at runtime: find the store by name, then pick
        the latest authorization model.  This keeps ``fga.env`` (written by
        the bootstrap container) the single source of truth and avoids
        hard-coding IDs in ``libcloud.rest/.env``.
        """
        if self._discovered:
            return
        self._discovered = True

        settings = get_settings()
        if not settings.fga_enabled:
            return

        if not self.store_id:
            sid = self._find_store_by_name(self.store_name)
            if sid:
                self.store_id = sid
                log.info("Auto-discovered FGA store '%s' -> %s", self.store_name, sid)
            else:
                log.warning(
                    "FGA store '%s' not found at %s — authorization checks will be skipped",
                    self.store_name, self.base_url,
                )

        if self.store_id and not self.model_id:
            mid = self._latest_model(self.store_id)
            if mid:
                self.model_id = mid
                log.info("Auto-discovered latest FGA model -> %s", mid)
            else:
                log.warning(
                    "No authorization model found in store %s — authorization checks will be skipped",
                    self.store_id,
                )

    def _find_store_by_name(self, name: str) -> str:
        """Find an OpenFGA store by name.  Returns the store id or ``""``."""
        try:
            url = f"{self.base_url}/stores"
            req = urllib.request.Request(
                url, method="GET", headers={"Accept": "application/json"}
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                body = json.loads(resp.read().decode("utf-8") or "{}")
                for store in body.get("stores", []):
                    if store.get("name") == name:
                        return store["id"]
        except Exception as exc:
            log.warning("Failed to auto-discover FGA store by name '%s': %s", name, exc)
        return ""

    def _latest_model(self, store_id: str) -> str:
        """Return the latest authorization model id for *store_id*, or ``""``."""
        try:
            url = f"{self.base_url}/stores/{store_id}/authorization-models?page_size=1"
            req = urllib.request.Request(
                url, method="GET", headers={"Accept": "application/json"}
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                body = json.loads(resp.read().decode("utf-8") or "{}")
                models = body.get("authorization_models", [])
                if models:
                    return models[0]["id"]
        except Exception as exc:
            log.warning("Failed to auto-discover latest FGA model: %s", exc)
        return ""

    # -- properties ------------------------------------------------------------

    @property
    def enabled(self) -> bool:
        settings = get_settings()
        if not settings.fga_enabled:
            return False
        self._ensure_discovered()
        return bool(self.store_id and self.model_id)

    # -- check -----------------------------------------------------------------

    def check(self, user: str, relation: str, obj: str, bearer: str | None = None) -> bool:
        if not self.enabled:
            return True

        payload = {
            "authorization_model_id": self.model_id,
            "tuple_key": {"user": user, "relation": relation, "object": obj},
        }
        url = f"{self.base_url}/stores/{self.store_id}/check"
        headers = {"Content-Type": "application/json", "Accept": "application/json"}
        # When OpenFGA runs with OIDC authn, forward the caller's Dex-issued JWT
        # (same IdP + audience as the REST API). Without a bearer, OpenFGA will
        # reject the request with 401, surfaced as authz_fga_error below.
        if bearer:
            headers["Authorization"] = f"Bearer {bearer}"
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode("utf-8"),
            method="POST",
            headers=headers,
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                body = json.loads(resp.read().decode("utf-8") or "{}")
                return bool(body.get("allowed", False))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            log.error("OpenFGA check failed: %s", detail)
            raise APIError(
                code="authz_fga_error",
                message="OpenFGA authorization check failed",
                status_code=503,
                details={"relation": relation, "object": obj, "detail": detail},
            ) from exc
        except urllib.error.URLError as exc:
            raise APIError(
                code="authz_fga_unavailable",
                message="OpenFGA service is unavailable",
                status_code=503,
            ) from exc

    def require(self, user: str, relation: str, obj: str, bearer: str | None = None) -> None:
        if not self.check(user, relation, obj, bearer=bearer):
            raise APIError(
                code="authz_fga_denied",
                message="OpenFGA denied the requested action",
                status_code=403,
                details={"user": user, "relation": relation, "object": obj},
            )


_fga_client: Optional[FgaClient] = None


def get_fga_client() -> FgaClient:
    global _fga_client
    if _fga_client is None:
        _fga_client = FgaClient()
    return _fga_client
