from __future__ import annotations

import json
import logging
import urllib.error
import urllib.request
from typing import Any

from app.config import get_settings
from app.errors import APIError
from app.idp_login import ProvisionerAuth

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

# Per-cloud authZ relations (see VALIDATION_CHECKS in openfga_bootstrap.py and
# libcloud.rest/app/auth/policy.py). The REST API gates read operations on
# `can_read` over the backend object (aws_region:nutanix_cluster), and write
# operations on `can_provision`. (`can_use` is a provider:* gate the REST API
# also enforces; the portal mirrors the backend-level read/provision check.)
CLOUD_OBJECTS = {"aws": "aws_region:aws", "nutanix": "nutanix_cluster:nutanix"}
VIEW_RELATION = "can_read"        # viewer+: enumerate / read resources
PROVISION_RELATION = "can_provision"  # admin+: provision

# user->role tuples on tenant:/platform: that represent a portal role. These
# are the only tuples clear_roles() will revoke (it leaves structural/infra
# tuples like parent/provider/tenant alone).
MANAGED_RELATIONS = {"owner", "admin", "viewer", "superadmin"}


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
        # OpenFGA is configured with --authn-method=oidc (issuer=Dex, audience=
        # libcloud-rest), so every API call needs a bearer token. We reuse the
        # provisioner service-account token (ProvisionerAuth performs a Dex
        # LDAP login for the aws-admin/ntnx-admin service users and caches it).
        # OpenFGA only authenticates the API caller via the JWT (iss+aud+sig);
        # the actual authz decision is on the tuple's `user` principal, so the
        # provisioner's subject is fine here.
        self._auth = ProvisionerAuth()

    def _bearer(self) -> str:
        try:
            return self._auth.get_token("aws")
        except Exception as exc:
            log.warning("provisioner token unavailable for FGA: %s", exc)
            return ""

    @property
    def enabled(self) -> bool:
        s = get_settings()
        return s.fga_enabled and bool(self.store_id and self.model_id)

    # --- low-level -----------------------------------------------------------
    def _post(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        url = f"{self.base_url}/stores/{self.store_id}{path}"
        body = json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        token = self._bearer()
        if token:
            headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(url, data=body, method="POST", headers=headers)
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

    def _delete(self, triples: list[dict[str, str]]) -> None:
        if not self.enabled or not triples:
            return
        self._post("/write", {
            "authorization_model_id": self.model_id,
            "deletes": {"tuple_keys": triples},
        })

    def _read_user_tuples(self, user: str) -> list[dict[str, str]]:
        """All tuples where `user` is the subject.

        This OpenFGA build's /read requires an object in the filter (it rejects
        a user-only filter), so we read the whole store and filter client-side.
        Fine for this store's size; for a large store, switch to /read per
        (object-type, relation) or maintain a side index.
        """
        return [t for t in self.list_tuples() if t["user"] == user]

    def clear_roles(self, principal: str) -> None:
        """Revoke every managed role tuple for `principal`.

        Reads the user's actual tuples first and deletes only the ones that
        exist — this OpenFGA build rejects deleting a non-existent tuple with
        `write_failed_due_to_invalid_input`, so a blind superset delete would
        fail whenever the user doesn't hold every role. Used by set_role()
        (drop old role before writing the new one) and by the portal's disable
        action (revoke all access for this system only).
        """
        if not self.enabled:
            return
        user = f"user:{principal}"
        managed = [
            t for t in self._read_user_tuples(user)
            if t["relation"] in MANAGED_RELATIONS
            and (t["object"].startswith("tenant:") or t["object"].startswith("platform:"))
        ]
        self._delete(managed)

    # --- raw tuple CRUD (superadmin tuples screen) --------------------------
    def list_tuples(self) -> list[dict[str, str]]:
        """Read every tuple in the store (paginated). Returns [{user,relation,object}]."""
        out: list[dict[str, str]] = []
        token = ""
        while True:
            payload: dict[str, Any] = {"page_size": 100}
            if token:
                payload["continuation_token"] = token
            body = self._post("/read", payload)
            for t in body.get("tuples", []):
                k = t.get("key", {})
                out.append({"user": k.get("user", ""), "relation": k.get("relation", ""), "object": k.get("object", "")})
            token = body.get("continuation_token") or ""
            if not token:
                break
        return out

    def write_tuples(self, triples: list[dict[str, str]]) -> None:
        if not self.enabled or not triples:
            return
        self._write(triples)

    def delete_tuples(self, triples: list[dict[str, str]]) -> None:
        self._delete(triples)


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
