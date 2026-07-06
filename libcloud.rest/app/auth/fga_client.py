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

    @property
    def enabled(self) -> bool:
        settings = get_settings()
        return settings.fga_enabled and bool(self.store_id and self.model_id)

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
