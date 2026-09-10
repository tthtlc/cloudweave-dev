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

# Role -> OpenFGA relation used when seeding a portal role into OpenFGA.
# Roles are PER-TENANT (rbac_design.md §"Role semantics"): an Admin/Owner/Viewer
# is bound to exactly one tenant and has no authority over any other tenant. The
# portal's role taxonomy is platform-level, so the tenant is derived from the
# principal slug (aws-admin -> tenant:aws, ntnx-owner -> tenant:nutanix,
# aws-dev-admin -> tenant:aws-dev, ...). A principal with no tenant prefix gets
# NO tenant tuple (it must be explicitly assigned to a tenant by a SuperAdmin
# before it can read/provision anything) — this is the least-privilege default
# the design requires and closes the previous "admin on both tenants" over-grant
# that let aws-admin provision Nutanix.
#
#   superadmin -> superadmin on platform:main ONLY (no tenant owner; gets global
#                read-only via platform.global_reader, can_provision nowhere by
#                default). Break-glass provisioning still requires an explicit
#                owner/admin grant on the target tenant.
#   owner      -> owner on the derived tenant
#   admin      -> admin on the derived tenant
#   viewer     -> viewer on the derived tenant
ROLE_RELATION = {"owner": "owner", "admin": "admin", "viewer": "viewer"}

# Tenants that currently exist in the OpenFGA store, keyed by the principal-slug
# prefix used in LLDAP (setup.sh creates aws-*/ntnx-* users). Used to validate a
# derived tenant before writing a tuple (a principal like "foo-admin" with an
# unknown tenant prefix writes nothing rather than creating a phantom
# tenant:foo).
TENANT_BY_SLUG = {"aws": "aws", "ntnx": "nutanix", "aws1": "aws1", "aws2": "aws2"}
KNOWN_TENANTS = tuple(TENANT_BY_SLUG.values())


_ROLE_STRENGTH = {"viewer": 0, "admin": 1, "owner": 2}


def _stronger(a: str, b: str) -> bool:
    """True when role `a` outranks role `b` (owner > admin > viewer)."""
    return _ROLE_STRENGTH.get(a, -1) > _ROLE_STRENGTH.get(b, -1)


def _tenant_for_principal(principal: str) -> str | None:
    """Derive the tenant id from a principal slug, e.g. aws-admin -> aws,
    ntnx-owner -> nutanix, aws-dev-viewer -> aws-dev. Returns None for
    superadmin or any principal whose tenant is not known."""
    if principal == "superadmin":
        return None
    # Match everything up to the trailing -<role>.
    for role in ("owner", "admin", "viewer"):
        if principal.endswith(f"-{role}"):
            slug = principal[: -(len(role) + 1)]
            # Direct tenant id (e.g. "aws") or slug alias (e.g. "ntnx" -> "nutanix").
            if slug in TENANT_BY_SLUG:
                return TENANT_BY_SLUG[slug]
            if slug in KNOWN_TENANTS:
                return slug
            return None
    return None

# Per-cloud authZ relations (see VALIDATION_CHECKS in openfga_bootstrap.py and
# libcloud.rest/app/auth/policy.py). The REST API gates read operations on
# `can_read` over the backend object (aws_region:nutanix_cluster), and write
# operations on `can_provision`. (`can_use` is a provider:* gate the REST API
# also enforces; the portal mirrors the backend-level read/provision check.)
CLOUD_OBJECTS = {"aws": "aws_region:aws", "nutanix": "nutanix_cluster:nutanix"}

# tenant id -> portal cloud (provider) is now DERIVED from OpenFGA rather than
# hard-coded (design_company_department.md §2/§3.6). The authoritative mapping is
# the structural tuple `tenant:<tid> parent provider:<aws|nutanix>`; departments
# created at runtime resolve without a code change. _cloud_map_from() below is
# the pure helper consumed by _derive_from_tuples() and tenant_binding().

# The seeded tenant per cloud. Preferred when a principal holds roles on several
# tenants of the same cloud (e.g. superadmin, owner on every tenant) so its
# provisioning keeps routing to the original tenant rather than an arbitrary one.
DEFAULT_BINDING = {"aws": "aws", "nutanix": "nutanix"}


def _cloud_map_from(tuples: list[dict[str, str]]) -> dict[str, list[str]]:
    """Derive ``{tenant_id: [cloud, ...]}`` from the structural tuples
    ``tenant:<tid> parent provider:<cloud>``. A department may be parented to
    several providers, so the value is a list (multi-provider departments)."""
    out: dict[str, list[str]] = {}
    for t in tuples:
        if (
            t.get("relation") == "parent"
            and t.get("object", "").startswith("provider:")
            and t.get("user", "").startswith("tenant:")
        ):
            out.setdefault(t["user"][len("tenant:"):], []).append(
                t["object"][len("provider:"):]
            )
    return out
VIEW_RELATION = "can_read"        # viewer+: enumerate / read resources
PROVISION_RELATION = "can_provision"  # admin+: provision
UPDATE_RELATION = "can_update"    # admin+: edit / update VM parameters (owner ∪ admin)

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
        self.store_name = s.fga_store_name
        self._discovered = False
        # OpenFGA is configured with --authn-method=oidc (issuer=Dex, audience=
        # libcloud-rest), so every API call needs a bearer token. We reuse the
        # provisioner service-account token (ProvisionerAuth performs a Dex
        # LDAP login for the aws-admin/ntnx-admin service users and caches it).
        # OpenFGA only authenticates the API caller via the JWT (iss+aud+sig);
        # the actual authz decision is on the tuple's `user` principal, so the
        # provisioner's subject is fine here.
        self._auth = ProvisionerAuth()

    # -- auto-discovery --------------------------------------------------------

    def _ensure_discovered(self) -> None:
        """Auto-discover store and model IDs from the OpenFGA API at runtime
        when they are not explicitly configured.  Keeps ``fga.env`` (written by
        the bootstrap container) the single source of truth."""
        if self._discovered:
            return
        self._discovered = True

        s = get_settings()
        if not s.fga_enabled:
            return

        if not self.store_id:
            sid = self._find_store_by_name(self.store_name)
            if sid:
                self.store_id = sid
                log.info("Auto-discovered FGA store '%s' -> %s", self.store_name, sid)
            else:
                log.warning(
                    "FGA store '%s' not found at %s — authorization checks skipped",
                    self.store_name, self.base_url,
                )

        if self.store_id and not self.model_id:
            mid = self._latest_model(self.store_id)
            if mid:
                self.model_id = mid
                log.info("Auto-discovered latest FGA model -> %s", mid)
            else:
                log.warning(
                    "No authorization model in store %s — authorization checks skipped",
                    self.store_id,
                )

    def _find_store_by_name(self, name: str) -> str:
        """Find an OpenFGA store by name.  Returns the store id or ``""``."""
        try:
            url = f"{self.base_url}/stores"
            headers = {"Accept": "application/json"}
            token = self._bearer()
            if token:
                headers["Authorization"] = f"Bearer {token}"
            req = urllib.request.Request(url, method="GET", headers=headers)
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
            headers = {"Accept": "application/json"}
            token = self._bearer()
            if token:
                headers["Authorization"] = f"Bearer {token}"
            req = urllib.request.Request(url, method="GET", headers=headers)
            with urllib.request.urlopen(req, timeout=10) as resp:
                body = json.loads(resp.read().decode("utf-8") or "{}")
                models = body.get("authorization_models", [])
                if models:
                    return models[0]["id"]
        except Exception as exc:
            log.warning("Failed to auto-discover latest FGA model: %s", exc)
        return ""

    def _bearer(self) -> str:
        try:
            return self._auth.get_token("aws")
        except Exception as exc:
            log.warning("provisioner token unavailable for FGA: %s", exc)
            return ""

    @property
    def enabled(self) -> bool:
        s = get_settings()
        if not s.fga_enabled:
            return False
        self._ensure_discovered()
        return bool(self.store_id and self.model_id)

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

    def _get(self, path: str, params: dict[str, str] | None = None) -> dict[str, Any]:
        """GET request to OpenFGA with query params. Same auth + error handling
        as ``_post`` but for the read-only endpoints (store, models, assertions,
        changes)."""
        if not self.enabled:
            return {}
        url = f"{self.base_url}/stores/{self.store_id}{path}"
        if params:
            from urllib.parse import urlencode

            filtered = {k: v for k, v in params.items() if v is not None and v != ""}
            if filtered:
                url = f"{url}?{urlencode(filtered)}"
        headers = {"Accept": "application/json"}
        token = self._bearer()
        if token:
            headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(url, method="GET", headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return json.loads(resp.read().decode("utf-8") or "{}")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            log.error("OpenFGA %s failed: %s", path, detail)
            raise APIError(
                "authz_fga_error", "OpenFGA request failed", 503,
                {"path": path, "detail": detail},
            ) from exc
        except urllib.error.URLError as exc:
            raise APIError(
                "authz_fga_unreachable", "OpenFGA unreachable", 503,
            ) from exc

    # --- checks --------------------------------------------------------------
    def check(self, user: str, relation: str, obj: str) -> bool:
        if not self.enabled:
            return True
        body = self._post("/check", {
            "authorization_model_id": self.model_id,
            "tuple_key": {"user": user, "relation": relation, "object": obj},
        })
        return bool(body.get("allowed", False))

    # --- cached authz derivation -------------------------------------------

    @staticmethod
    def _derive_from_tuples(
        tuples: list[dict[str, str]],
        tenant_cloud: dict[str, str],
    ) -> dict[str, Any]:
        """Derive portal role + per-cloud capabilities from a set of concrete
        OpenFGA tuples for a single user.  Pure function — does no I/O.

        Local derivation mirrors the OpenFGA model's concrete tuple set.  It
        does NOT evaluate computed relations that depend on provider-level
        ``can_use`` or resource-class grants (neither is seeded in the current
        bootstrap), so it is equivalent for the running store.

        ``tenant_cloud`` maps tenant id -> cloud (derived from the structural
        ``tenant:<tid> parent provider:<cloud>`` tuples) and replaces the former
        hard-coded TENANT_CLOUD map.
        """
        tenant_roles: dict[str, str] = {}  # tenant_id -> strongest relation
        is_superadmin = False
        is_company_admin = False

        for t in tuples:
            rel = t["relation"]
            obj = t["object"]

            if rel == "superadmin" and obj == "platform:main":
                is_superadmin = True
            elif rel == "admin" and obj.startswith("company:"):
                is_company_admin = True
            elif obj.startswith("tenant:") and rel in ("owner", "admin", "viewer"):
                tenant_id = obj[7:]  # strip "tenant:"
                current = tenant_roles.get(tenant_id)
                # Keep the strongest: owner > admin > viewer
                if current is None or _stronger(rel, current):
                    tenant_roles[tenant_id] = rel

        # --- derive role (strongest across all tenants) --------------------
        # company_admin sits above tenant owner/admin (a company admin may also
        # hold a department role, but the company dashboard is their primary).
        if is_superadmin:
            role = "superadmin"
        elif is_company_admin:
            role = "company_admin"
        elif "owner" in tenant_roles.values():
            role = "owner"
        elif "admin" in tenant_roles.values():
            role = "admin"
        else:
            role = "viewer"

        # --- derive per-cloud capabilities --------------------------------
        supported = ("aws", "nutanix")
        # Aggregate the user's strongest role per cloud across ALL their tenants
        # (a cloud is a provider; aws1/aws2 are distinct AWS tenants under it).
        # A multi-provider tenant contributes its role to every cloud it is
        # parented to, so an admin on a department bound to both aws + nutanix
        # derives capabilities on both.
        cloud_roles: dict[str, str] = {}
        for tenant_id, rel in tenant_roles.items():
            for cloud in tenant_cloud.get(tenant_id, []):
                current = cloud_roles.get(cloud)
                if current is None or _stronger(rel, current):
                    cloud_roles[cloud] = rel

        clouds: list[dict[str, Any]] = []
        for cloud in supported:
            cloud_role = cloud_roles.get(cloud)
            is_privileged = cloud_role in ("admin", "owner")

            clouds.append(
                {
                    "cloud": cloud,
                    "canView": bool(
                        is_privileged or cloud_role == "viewer" or is_superadmin
                    ),
                    "canProvision": is_privileged,
                    "canUpdate": is_privileged,
                }
            )

        return {"role": role, "clouds": clouds}

    def _derive_authz(self, principal: str) -> dict[str, Any]:
        """Single-user wrapper: read tuples for *principal* and derive authz."""
        if not self.enabled:
            return {
                "role": "viewer",
                "clouds": [
                    {"cloud": c, "canView": True, "canProvision": True, "canUpdate": True}
                    for c in self.SUPPORTED_CLOUDS
                ],
            }
        all_tuples = self.list_tuples()
        tenant_cloud = _cloud_map_from(all_tuples)
        user_tuples = [t for t in all_tuples if t["user"] == f"user:{principal}"]
        return self._derive_from_tuples(user_tuples, tenant_cloud)

    def batch_derive(
        self, principals: list[str]
    ) -> dict[str, dict[str, Any]]:
        """Read the full tuple store **once** and derive role + cloud
        capabilities for every principal in *principals*.  Returns
        ``{principal: {"role": str, "clouds": [...]}, ...}``.

        Use this in list-users paths where calling ``role_for`` N times would
        otherwise trigger N full ``/read`` calls."""
        if not principals:
            return {}
        if not self.enabled:
            fallback = {
                "role": "viewer",
                "clouds": [
                    {"cloud": c, "canView": True, "canProvision": True, "canUpdate": True}
                    for c in self.SUPPORTED_CLOUDS
                ],
            }
            return {p: fallback for p in principals}

        all_tuples = self.list_tuples()
        tenant_cloud = _cloud_map_from(all_tuples)

        # Index by user: prefix so we can look up by f"user:{principal}"
        by_user: dict[str, list[dict[str, str]]] = {}
        for t in all_tuples:
            user = t.get("user", "")
            if user:
                by_user.setdefault(user, []).append(t)

        result: dict[str, dict[str, Any]] = {}
        for p in principals:
            result[p] = self._derive_from_tuples(
                by_user.get(f"user:{p}", []), tenant_cloud
            )
        return result

    def role_for(self, principal: str) -> str:
        """Derive the portal role for a principal from its concrete tuples.
        Returns 'viewer' as the floor.  One ``/read``, no /check fan-out."""
        return self._derive_authz(principal)["role"]

    # --- writes --------------------------------------------------------------
    @staticmethod
    def _key(t: dict[str, str]) -> tuple[str, str, str]:
        return (t.get("user", ""), t.get("relation", ""), t.get("object", ""))

    def _write(self, writes: list[dict[str, str]], deletes: list[dict[str, str]] = None) -> None:
        if not self.enabled:
            return
        # OpenFGA rejects a request that (a) lists the same tuple twice in
        # writes or deletes, or (b) lists a tuple in BOTH writes and deletes.
        # Deduplicate each side and drop any delete that is also a write (a
        # no-op change: e.g. re-selecting the same admin/role).
        writes = list({self._key(t): t for t in (writes or [])}.values())
        deletes = list({self._key(t): t for t in (deletes or [])}.values())
        write_keys = {self._key(t) for t in writes}
        deletes = [t for t in deletes if self._key(t) not in write_keys]
        if not writes and not deletes:
            return
        payload: dict[str, Any] = {"authorization_model_id": self.model_id, "writes": {"tuple_keys": writes}}
        if deletes:
            payload["deletes"] = {"tuple_keys": deletes}
        self._post("/write", payload)

    def assign_role(self, principal: str, role: str, tenant: str | None = None) -> None:
        """Seed the OpenFGA tuple(s) for a portal role. PER-TENANT
        (rbac_design.md): owner/admin/viewer are written on the single tenant
        derived from the principal slug, never on both tenants. superadmin is
        written only on platform:main (no tenant owner). Idempotent at the model
        level (OpenFGA dedupes identical tuples).

        When *tenant* is provided (e.g. superadmin assigning a pending user),
        the slug-derivation path is skipped and the tuple is written directly on
        that tenant. When *tenant* is None, the tenant is derived from the
        principal slug for backward compatibility with LLDAP users."""
        user = f"user:{principal}"
        if role == "superadmin":
            self._write([{"user": user, "relation": "superadmin", "object": "platform:main"}])
            return
        relation = ROLE_RELATION.get(role)
        if not relation:
            return
        if tenant is not None:
            # Explicit tenant from caller (e.g. pending user assignment).
            self._write([{"user": user, "relation": relation, "object": f"tenant:{tenant}"}])
            return
        # Derive tenant from principal slug for LLDAP users.
        tenant = _tenant_for_principal(principal)
        if not tenant:
            # No tenant binding -> no auto-grant. The user is denied at every
            # tenant until a SuperAdmin assigns them to one.
            return
        self._write([{"user": user, "relation": relation, "object": f"tenant:{tenant}"}])

    def _delete(self, triples: list[dict[str, str]]) -> None:
        if not self.enabled or not triples:
            return
        # Deduplicate before sending: OpenFGA rejects a delete list with the
        # same tuple twice (e.g. overlapping filters in a cascade delete).
        triples = list({self._key(t): t for t in triples}.values())
        if not triples:
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

    # --- store metadata ------------------------------------------------------
    def get_store(self) -> dict[str, Any]:
        """Return store metadata (id, name, created_at, updated_at)."""
        return self._get("")

    # --- authorization models ------------------------------------------------
    def list_authorization_models(self) -> dict[str, Any]:
        """Return all authorization models for the store (paginated)."""
        return self._get("/authorization-models")

    def get_authorization_model(self, model_id: str) -> dict[str, Any]:
        """Return a single authorization model with its type definitions."""
        return self._get(f"/authorization-models/{model_id}")

    # --- assertions ----------------------------------------------------------
    def read_assertions(self, model_id: str) -> dict[str, Any]:
        """Read assertions for an authorization model ID."""
        return self._get(f"/assertions/{model_id}")

    # --- tuple change log ----------------------------------------------------
    def read_changes(
        self,
        change_type: str | None = None,
        page_size: int = 50,
        continuation_token: str | None = None,
    ) -> dict[str, Any]:
        """Paginated tuple change log (audit trail)."""
        return self._get("/changes", {
            "type": change_type or "",
            "page_size": str(page_size),
            "continuation_token": continuation_token or "",
        })

    # --- relationship queries ------------------------------------------------
    def list_users_openfga(self, body: dict[str, Any]) -> dict[str, Any]:
        """OpenFGA list-users: find users with a relation to an object."""
        return self._post("/list-users", {
            "authorization_model_id": self.model_id,
            **body,
        })

    def list_objects(self, body: dict[str, Any]) -> dict[str, Any]:
        """OpenFGA list-objects: find objects of a type the user can access."""
        return self._post("/list-objects", {
            "authorization_model_id": self.model_id,
            **body,
        })

    def expand(self, body: dict[str, Any]) -> dict[str, Any]:
        """Expand a relationship into its userset tree."""
        return self._post("/expand", {
            "authorization_model_id": self.model_id,
            **body,
        })

    # --- per-cloud authZ -----------------------------------------------------
    def tenant_binding(self, principal: str, cloud: str) -> str | None:
        """The tenant id (== the Vault auth_binding) the principal holds a role
        on under `cloud`, or None. Reads the user's concrete tuples so it works
        for both LLDAP uid principals (aws1-admin) and pending federated
        principals keyed by their full internal id.

        When the principal holds roles on several tenants of the same cloud
        (e.g. superadmin, owner everywhere), the seeded default tenant for that
        cloud is preferred so provisioning keeps routing to the original tenant
        rather than an arbitrary one."""
        found: dict[str, str] = {}  # tenant_id -> strongest relation
        all_tuples = self.list_tuples()
        tenant_cloud = _cloud_map_from(all_tuples)
        for t in all_tuples:
            if t.get("user") != f"user:{principal}":
                continue
            rel = t["relation"]
            obj = t["object"]
            if obj.startswith("tenant:") and rel in ("owner", "admin", "viewer"):
                tenant_id = obj[len("tenant:"):]
                if cloud in tenant_cloud.get(tenant_id, []) and _stronger(rel, found.get(tenant_id, "")):
                    found[tenant_id] = rel
        if not found:
            return None
        default = DEFAULT_BINDING.get(cloud)
        if default and default in found:
            return default
        # Otherwise pick the strongest tenant (owner > admin > viewer).
        return max(found, key=lambda tid: _ROLE_STRENGTH.get(found[tid], -1))

    def _backend_object(self, principal: str, cloud: str) -> str | None:
        """The OpenFGA backend object the principal is actually bound to under
        `cloud` (e.g. aws_region:aws1 for aws1-admin), falling back to the
        seeded default tenant object when the principal has no tenant tuple."""
        obj_type = {"aws": "aws_region", "nutanix": "nutanix_cluster"}.get(cloud)
        if not obj_type:
            return None
        binding = self.tenant_binding(principal, cloud)
        if binding:
            return f"{obj_type}:{binding}"
        return CLOUD_OBJECTS.get(cloud)

    def clouds_for_tenant(self, tenant_id: str) -> list[str]:
        """The cloud(s) (aws|nutanix) a tenant is bound to, derived from the
        structural ``tenant:<tid> parent provider:<cloud>`` tuples. Empty for an
        unknown/tenant-less id. One /read, no /check fan-out."""
        if not self.enabled:
            return []
        return _cloud_map_from(self.list_tuples()).get(tenant_id, [])

    def cloud_for_tenant(self, tenant_id: str) -> str | None:
        """Back-compat single-cloud view of :meth:`clouds_for_tenant`."""
        clouds = self.clouds_for_tenant(tenant_id)
        return clouds[0] if clouds else None

    # --- company / department management (design_company_department.md §7) ---

    def create_company(self, name: str, admin_principal: str) -> None:
        """Create a company and assign its main administrator.
        company:<name> is parented to platform:main; user:<admin> is its admin."""
        self._write([
            {"user": "platform:main", "relation": "platform", "object": f"company:{name}"},
            {"user": f"user:{admin_principal}", "relation": "admin", "object": f"company:{name}"},
        ])

    def create_department(
        self, company_id: str, dept: str, clouds: list[str], owner_principal: str
    ) -> None:
        """Create a department (a tenant parented to a company) with its full
        per-department wiring. ``clouds`` may hold one or more providers, so a
        department can be bound to AWS and/or Nutanix. For each provider we
        write the structural ``tenant parent provider`` tuple plus the backend
        object (aws_region / nutanix_cluster) wiring; the tenant/vault_user/
        owner/company links are written once. Mirrors create_tenant.sh's tuple
        set, plus the company parent link and multi-provider support."""
        backend = {"aws": "aws_region", "nutanix": "nutanix_cluster"}
        writes: list[dict[str, str]] = [
            {"user": f"company:{company_id}", "relation": "parent", "object": f"tenant:{dept}"},
            {"user": f"tenant:{dept}", "relation": "parent", "object": "libcloud_api:main"},
            {"user": f"tenant:{dept}", "relation": "parent", "object": f"vault_user:libcloud-{dept}"},
            {"user": f"user:{owner_principal}", "relation": "owner", "object": f"tenant:{dept}"},
        ]
        for cloud in clouds:
            writes.extend([
                {"user": f"tenant:{dept}", "relation": "parent", "object": f"provider:{cloud}"},
                {"user": f"provider:{cloud}", "relation": "provider", "object": f"{backend[cloud]}:{dept}"},
                {"user": f"tenant:{dept}", "relation": "tenant", "object": f"{backend[cloud]}:{dept}"},
                {"user": "platform:main", "relation": "platform", "object": f"{backend[cloud]}:{dept}"},
            ])
        self._write(writes)

    def list_companies(self) -> list[dict[str, Any]]:
        """Return [{id, admin, departments: [{id, clouds, owner}]}] derived from
        the concrete tuples. One /read."""
        tuples = self.list_tuples()
        company_admin: dict[str, str] = {}
        dept_company: dict[str, str] = {}
        dept_clouds: dict[str, list[str]] = {}
        dept_owner: dict[str, str] = {}
        for t in tuples:
            rel, obj, user = t["relation"], t["object"], t["user"]
            if rel == "admin" and obj.startswith("company:"):
                company_admin[obj.split(":", 1)[1]] = (
                    user.split(":", 1)[1] if user.startswith("user:") else user
                )
            elif rel == "parent" and user.startswith("company:") and obj.startswith("tenant:"):
                dept_company[obj.split(":", 1)[1]] = user.split(":", 1)[1]
            elif rel == "parent" and user.startswith("tenant:") and obj.startswith("provider:"):
                dept_clouds.setdefault(user.split(":", 1)[1], []).append(obj.split(":", 1)[1])
            elif rel == "owner" and obj.startswith("tenant:"):
                dept_owner[obj.split(":", 1)[1]] = (
                    user.split(":", 1)[1] if user.startswith("user:") else user
                )

        companies: dict[str, dict[str, Any]] = {}
        for dept, company in dept_company.items():
            c = companies.setdefault(
                company, {"id": company, "admin": company_admin.get(company, ""), "departments": []}
            )
            c["departments"].append({
                "id": dept,
                "clouds": dept_clouds.get(dept, []),
                "owner": dept_owner.get(dept, ""),
            })
        for company, admin in company_admin.items():
            companies.setdefault(company, {"id": company, "admin": admin, "departments": []})
        return list(companies.values())

    def company_for(self, principal: str) -> str | None:
        """The company the principal is the main admin of (or None)."""
        if not self.enabled:
            return None
        for t in self.list_tuples():
            if (
                t["relation"] == "admin"
                and t["object"].startswith("company:")
                and t["user"] == f"user:{principal}"
            ):
                return t["object"].split(":", 1)[1]
        return None

    # --- company / department lifecycle (edit + delete) ----------------------

    @staticmethod
    def _department_objects(dept: str) -> set[str]:
        """Object ids owned by one department (its tenant + derived backend and
        vault objects). Shared objects (provider, libcloud_api, platform) are
        NOT included — those are never deleted wholesale."""
        return {
            f"tenant:{dept}",
            f"vault_user:libcloud-{dept}",
            f"aws_region:{dept}",
            f"nutanix_cluster:{dept}",
        }

    def update_company(
        self, company_id: str, *, new_id: str | None = None, admin_principal: str | None = None
    ) -> None:
        """Rename a company (re-key ``company:<old>`` -> ``company:<new>`` in
        every tuple that references it) and/or replace its admin."""
        if not new_id and not admin_principal:
            return
        target = new_id or company_id
        tuples = self.list_tuples()
        writes: list[dict[str, str]] = []
        deletes: list[dict[str, str]] = []

        # 1. Admin change: drop existing admin tuple(s) on the old id, add new.
        if admin_principal:
            for t in tuples:
                if t["relation"] == "admin" and t["object"] == f"company:{company_id}":
                    deletes.append(t)
            writes.append({
                "user": f"user:{admin_principal}",
                "relation": "admin",
                "object": f"company:{target}",
            })

        # 2. Rename: re-key the company object in user/object position. Admin
        #    tuples are skipped here only when step 1 is replacing them.
        if new_id and new_id != company_id:
            for t in tuples:
                if t["object"] != f"company:{company_id}" and t["user"] != f"company:{company_id}":
                    continue
                if admin_principal and t["relation"] == "admin" and t["object"] == f"company:{company_id}":
                    continue
                nt = dict(t)
                if nt["object"] == f"company:{company_id}":
                    nt["object"] = f"company:{new_id}"
                if nt["user"] == f"company:{company_id}":
                    nt["user"] = f"company:{new_id}"
                deletes.append(t)
                writes.append(nt)

        if writes or deletes:
            self._write(writes, deletes)

    def delete_company(self, company_id: str) -> None:
        """Delete a company and every department under it: the company object,
        its admin link, each department's tenant + backend + vault objects, and
        the tenant's outgoing parent links. Shared objects are left alone."""
        tuples = self.list_tuples()
        depts = {
            t["object"].split(":", 1)[1]
            for t in tuples
            if t["relation"] == "parent"
            and t["user"] == f"company:{company_id}"
            and t["object"].startswith("tenant:")
        }
        objects = {f"company:{company_id}"}
        for d in depts:
            objects |= self._department_objects(d)
        extra_users = {f"company:{company_id}"} | {f"tenant:{d}" for d in depts}
        deletes = [
            t for t in tuples if t["object"] in objects or t["user"] in extra_users
        ]
        self._delete(deletes)

    def update_department(
        self,
        dept: str,
        *,
        clouds: list[str] | None = None,
        owner_principal: str | None = None,
    ) -> None:
        """Edit a department: replace its owner and/or change the set of bound
        providers. Adding a provider writes its backend-object wiring; removing
        one deletes that wiring. Rename is intentionally out of scope (the
        department id is a stable slug)."""
        backend = {"aws": "aws_region", "nutanix": "nutanix_cluster"}
        tuples = self.list_tuples()
        writes: list[dict[str, str]] = []
        deletes: list[dict[str, str]] = []

        if owner_principal:
            for t in tuples:
                if t["relation"] == "owner" and t["object"] == f"tenant:{dept}":
                    deletes.append(t)
            writes.append({
                "user": f"user:{owner_principal}",
                "relation": "owner",
                "object": f"tenant:{dept}",
            })

        if clouds is not None:
            current = [
                t["object"].split(":", 1)[1]
                for t in tuples
                if t["relation"] == "parent"
                and t["user"] == f"tenant:{dept}"
                and t["object"].startswith("provider:")
            ]
            add = [c for c in clouds if c not in current]
            remove = [c for c in current if c not in clouds]
            for c in add:
                writes.extend([
                    {"user": f"tenant:{dept}", "relation": "parent", "object": f"provider:{c}"},
                    {"user": f"provider:{c}", "relation": "provider", "object": f"{backend[c]}:{dept}"},
                    {"user": f"tenant:{dept}", "relation": "tenant", "object": f"{backend[c]}:{dept}"},
                    {"user": "platform:main", "relation": "platform", "object": f"{backend[c]}:{dept}"},
                ])
            for c in remove:
                for t in tuples:
                    if t["object"] == f"{backend[c]}:{dept}":
                        deletes.append(t)
                    elif (
                        t["user"] == f"tenant:{dept}"
                        and t["relation"] == "parent"
                        and t["object"] == f"provider:{c}"
                    ):
                        deletes.append(t)

        if writes or deletes:
            self._write(writes, deletes)

    def delete_department(self, dept: str) -> None:
        """Delete a department (tenant + backend + vault objects, its outgoing
        parent links, and every member role tuple)."""
        objects = self._department_objects(dept)
        extra_users = {f"tenant:{dept}"}
        deletes = [
            t for t in self.list_tuples()
            if t["object"] in objects or t["user"] in extra_users
        ]
        self._delete(deletes)

    # --- department members (company admin manages users within departments) --

    def list_department_members(self, company_id: str) -> list[dict[str, Any]]:
        """Return [{user, department, role, clouds}] for every user holding a
        role (owner/admin/viewer) in one of the company's departments."""
        tuples = self.list_tuples()
        tenant_cloud = _cloud_map_from(tuples)
        depts = {
            t["object"].split(":", 1)[1]
            for t in tuples
            if t["relation"] == "parent"
            and t["user"] == f"company:{company_id}"
            and t["object"].startswith("tenant:")
        }
        members: list[dict[str, Any]] = []
        seen: set[tuple[str, str]] = set()
        for t in tuples:
            if not (t["object"].startswith("tenant:") and t["relation"] in ("owner", "admin", "viewer") and t["user"].startswith("user:")):
                continue
            dept = t["object"].split(":", 1)[1]
            if dept not in depts:
                continue
            principal = t["user"].split(":", 1)[1]
            key = (principal, dept)
            if key in seen:
                continue
            seen.add(key)
            members.append({
                "user": principal,
                "department": dept,
                "role": t["relation"],
                "clouds": tenant_cloud.get(dept, []),
            })
        return members

    def assign_department_user(self, dept: str, principal: str, role: str) -> None:
        """Set a user's role on a department, replacing any existing role tuple
        on that tenant (owner/admin/viewer)."""
        relation = ROLE_RELATION.get(role)
        if not relation:
            return
        user = f"user:{principal}"
        deletes = [
            t for t in self.list_tuples()
            if t["user"] == user and t["object"] == f"tenant:{dept}" and t["relation"] in MANAGED_RELATIONS
        ]
        self._write([{"user": user, "relation": relation, "object": f"tenant:{dept}"}], deletes)

    def remove_department_user(self, dept: str, principal: str) -> None:
        """Revoke a user's role tuple(s) on a department."""
        user = f"user:{principal}"
        deletes = [
            t for t in self.list_tuples()
            if t["user"] == user and t["object"] == f"tenant:{dept}" and t["relation"] in MANAGED_RELATIONS
        ]
        self._delete(deletes)

    def can_view(self, principal: str, cloud: str) -> bool:
        obj = self._backend_object(principal, cloud)
        if not obj:
            return False
        return self.check(f"user:{principal}", VIEW_RELATION, obj)

    def can_provision(self, principal: str, cloud: str) -> bool:
        obj = self._backend_object(principal, cloud)
        if not obj:
            return False
        return self.check(f"user:{principal}", PROVISION_RELATION, obj)

    def can_update(self, principal: str, cloud: str) -> bool:
        # Edit / update VM parameters. Owner ∪ Admin (and per-class Admin via the
        # resource_class arm on the backend). Viewer and SuperAdmin (by default)
        # cannot (rbac_design.md changelog #10).
        obj = self._backend_object(principal, cloud)
        if not obj:
            return False
        return self.check(f"user:{principal}", UPDATE_RELATION, obj)

    # The clouds the portal offers resource dashboards for. Keep in sync with
    # CLOUD_OBJECTS and the backends seeded by openfga_bootstrap.py.
    SUPPORTED_CLOUDS = ("aws", "nutanix")

    def cloud_capabilities(self, principal: str) -> list[dict[str, Any]]:
        """Live per-cloud can_view/can_provision/can_update for a principal.
        Reads the user's tuples once and derives capabilities locally —
        no per-cloud /check fan-out (was 6 calls, now 1 /read)."""
        return self._derive_authz(principal)["clouds"]
