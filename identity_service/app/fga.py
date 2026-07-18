from __future__ import annotations

import json
import logging
import urllib.error
import urllib.request
from typing import Any

from app.config import get_settings
from app.errors import APIError

log = logging.getLogger(__name__)

# Role -> OpenFGA (relation, object) used for both authZ checks and role
# assignment. The portal role is a single platform-level role; OpenFGA models
# roles per-tenant (see openfga_postgres/openfga_bootstrap.py). We map the
# portal role to the strongest relation it grants:
#   superadmin -> can_manage_platform on platform:main (break-glass owner on tenants)
#   owner     -> owner on both tenants
#   admin     -> admin on both tenants
#   viewer    -> viewer on both tenants
# For per-cloud endpoints (resources/provision) we check the finer-grained
# can_use / can_provision relations on the cloud's backend object directly.
ROLE_TUPLES = {
    "superadmin": ("can_manage_platform", "platform:main"),
    "owner": [("owner", "tenant:aws"), ("owner", "tenant:nutanix")],
    "admin": [("admin", "tenant:aws"), ("admin", "tenant:nutanix")],
    "viewer": [("viewer", "tenant:aws"), ("viewer", "tenant:nutanix")],
}

# Per-cloud authZ relations (see VALIDATION_CHECKS in openfga_bootstrap.py).
CLOUD_OBJECTS = {"aws": "aws_region:aws", "nutanix": "nutanix_cluster:nutanix"}
VIEW_RELATION = "can_use"        # viewer+: enumerate / read resources
PROVISION_RELATION = "can_provision"  # admin+: provision


class FgaService:
    """OpenFGA REST client. OpenFGA is the source of truth for authorization;
    the portal's frontend role checks are UX-only (see user_role_management.md
    §"Do not trust role values from the browser alone").
    """

    def __init__(self) -> None:
        s = get_settings()
        self.base_url = s.fga_api_url.rstrip("/")
        self.store_id = s.fga_store_id
        self.model_id = s.fga_model_id

    @property
    def enabled(self) -> bool:
        s = get_settings()
        return s.fga_enabled and bool(self.store_id and self.model_id)

    # --- low-level -----------------------------------------------------------
    def _post(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        url = f"{self.base_url}/stores/{self.store_id}{path}"
        body = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(url, data=body, method="POST", headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return json.loads(resp.read().decode("utf-8") or "{}")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            log.error("OpenFGA %s failed: %s", path, detail)
            raise APIError("authz_fga_error", "OpenFGA request failed", 503, {"path": path, "detail": detail}) from exc
        except urllib.error.URLError as exc:
            raise APIError("authz_fga_unreachable", "OpenFGA unreachable", 503) from exc

    # --- checks --------------------------------------------------------------
    def check(self, user: str, relation: str, obj: str) -> bool:
        if not self.enabled:
            return True
        body = self._post("/check", {
            "authorization_model_id": self.model_id,
            "tuple_key": {"user": user, "relation": relation, "object": obj},
        })
        return bool(body.get("allowed", False))

    def role_for(self, principal: str) -> str:
        """Derive the portal role for a principal by checking the strongest
        relation it holds. Returns 'viewer' as the floor."""
        if not self.enabled:
            return "viewer"
        if self.check(f"user:{principal}", "can_manage_platform", "platform:main"):
            return "superadmin"
        for tenant in ("tenant:aws", "tenant:nutanix"):
            if self.check(f"user:{principal}", "owner", tenant):
                return "owner"
        for tenant in ("tenant:aws", "tenant:nutanix"):
            if self.check(f"user:{principal}", "admin", tenant):
                return "admin"
        return "viewer"

    # --- writes --------------------------------------------------------------
    def _write(self, writes: list[dict[str, str]], deletes: list[dict[str, str]] = None) -> None:
        if not self.enabled:
            return
        payload: dict[str, Any] = {"authorization_model_id": self.model_id, "writes": {"tuple_keys": writes}}
        if deletes:
            payload["deletes"] = {"tuple_keys": deletes}
        self._post("/write", payload)

    def assign_role(self, principal: str, role: str) -> None:
        """Seed the OpenFGA tuples for a portal role. Idempotent at the model
        level (OpenFGA dedupes identical tuples)."""
        mapping = ROLE_TUPLES.get(role)
        if not mapping:
            return
        user = f"user:{principal}"
        if role == "superadmin":
            self._write([{"user": user, "relation": "can_manage_platform", "object": "platform:main"}])
            self._write([
                {"user": user, "relation": "owner", "object": "tenant:aws"},
                {"user": user, "relation": "owner", "object": "tenant:nutanix"},
            ])
            return
        # owner/admin/viewer: write the relation on both tenants.
        for relation, obj in mapping:
            self._write([{"user": user, "relation": relation, "object": obj}])

    # --- per-cloud authZ -----------------------------------------------------
    def can_view(self, principal: str, cloud: str) -> bool:
        obj = CLOUD_OBJECTS.get(cloud)
        if not obj:
            return False
        return self.check(f"user:{principal}", VIEW_RELATION, obj)

    def can_provision(self, principal: str, cloud: str) -> bool:
        obj = CLOUD_OBJECTS.get(cloud)
        if not obj:
            return False
        return self.check(f"user:{principal}", PROVISION_RELATION, obj)
