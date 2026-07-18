from __future__ import annotations

import time
import uuid
from typing import Any

from app.errors import APIError
from app.fga import FgaService
from app.lldap import LldapService

# In-memory internal-user registry for identities that are NOT in LLDAP
# (e.g. brand-new Google/GitHub logins that have not been linked yet). In a
# real deployment, persist these as LLDAP users (or a dedicated table) so the
# superadmin user-management table reflects them. Kept simple here so the
# first-login provisioning path works end-to-end without a schema migration.
_pending_users: dict[str, dict[str, Any]] = {}

DEFAULT_ROLE = "viewer"
ALLOWED_ROLES = {"superadmin", "owner", "admin", "viewer"}


class UserService:
    """Resolves an external (Dex) identity to an internal user, and runs the
    identity-collapse heuristic.

    The internal-user abstraction is the portal's own: `internalUserId` is
    stable and platform-owned, NOT the provider subject. One internal user may
    have multiple `linkedIdentities` (google:…, github:…). See
    server/src/services/mockData.js for the shape the browser expects.
    """

    def __init__(self, lldap: LldapService, fga: FgaService) -> None:
        self.lldap = lldap
        self.fga = fga

    # --- lookup helpers -----------------------------------------------------
    def _find_by_subject(self, subject: str) -> dict[str, Any] | None:
        # LLDAP users currently have no provider-subject attribute mapped, so
        # subject linking is tracked in the pending registry. TODO: persist
        # linkedIdentities on the LLDAP user (custom attribute) or a side table.
        for u in _pending_users.values():
            if subject in u["linkedIdentities"]:
                return u
        return None

    def _find_by_internal_id(self, internal_user_id: str) -> dict[str, Any] | None:
        if internal_user_id in _pending_users:
            return _pending_users[internal_user_id]
        # Fall back to LLDAP by uid (internalUserId is "int-<uid>").
        if internal_user_id.startswith("int-"):
            uid = internal_user_id[4:]
            for u in self.lldap.list_users():
                if u["internalUserId"] == internal_user_id:
                    u["role"] = self.fga.role_for(uid)
                    return u
        return None

    # --- exchange resolution -------------------------------------------------
    def resolve_on_login(self, external: dict[str, str]) -> dict[str, Any]:
        """Return one of three exchange outcomes (see README §/api/auth/exchange):
        existing user, collapse required, or brand-new viewer.
        """
        subject = external["subject"]
        existing = self._find_by_subject(subject)
        if existing:
            return {
                "internalUserId": existing["internalUserId"],
                "role": existing["role"],
                "linkedIdentities": existing["linkedIdentities"],
                "email": existing["email"],
                "needsIdentityCollapse": False,
                "collapseCandidates": [],
            }

        candidates = self.lldap.find_by_email(external["email"]) if external.get("email") else []
        if candidates:
            return {
                "internalUserId": None,
                "role": None,
                "linkedIdentities": [subject],
                "email": external["email"],
                "needsIdentityCollapse": True,
                "collapseCandidates": [
                    {
                        "internalUserId": c["internalUserId"],
                        "email": c["email"],
                        "displayName": c["displayName"],
                        "role": c["role"],
                        "linkedIdentities": c["linkedIdentities"],
                    }
                    for c in candidates
                ],
                "pendingIdentity": external,
            }

        # Brand-new internal user -> default role viewer.
        new_user = self._provision_viewer(external)
        return {
            "internalUserId": new_user["internalUserId"],
            "role": new_user["role"],
            "linkedIdentities": new_user["linkedIdentities"],
            "email": new_user["email"],
            "needsIdentityCollapse": False,
            "collapseCandidates": [],
        }

    def _provision_viewer(self, external: dict[str, str]) -> dict[str, Any]:
        internal_user_id = f"int-viewer-{uuid.uuid4().hex[:8]}"
        user = {
            "internalUserId": internal_user_id,
            "email": external.get("email", ""),
            "displayName": f"{external.get('provider','unknown')} user",
            "role": DEFAULT_ROLE,
            "linkedIdentities": [external["subject"]],
            "createdAt": _now_iso(),
        }
        _pending_users[internal_user_id] = user
        # Seed the OpenFGA tuple so subsequent authZ checks pass. The OpenFGA
        # model keys roles off the LLDAP uid; for pending users we use the
        # internal id's suffix as the principal until the user is linked into
        # LLDAP. TODO: create the LLDAP user and re-key the tuple on its uid.
        self.fga.assign_role(internal_user_id, DEFAULT_ROLE)
        return user

    # --- collapse ------------------------------------------------------------
    def apply_collapse(
        self,
        *,
        target_internal_user_id: str,
        pending_identity: dict[str, str],
        decision: str,
    ) -> dict[str, Any]:
        """`link` -> append the pending subject to the target's linkedIdentities.
        `keep` -> create a fresh viewer account for the pending identity.

        Backend policy may override `keep` -> `link` (e.g. require same email
        domain). The browser choice is advisory; this method enforces the
        final decision. See IdentityCollapsePage.js note.
        """
        if decision not in ("link", "keep"):
            raise APIError("auth_collapse_bad_decision", "decision must be 'link' or 'keep'", 400)
        if decision == "link":
            target = self._find_by_internal_id(target_internal_user_id)
            if not target:
                raise APIError("auth_collapse_target_missing", "target internal user not found", 404)
            subject = pending_identity["subject"]
            if subject not in target["linkedIdentities"]:
                target["linkedIdentities"].append(subject)
                _pending_users[target["internalUserId"]] = target
            return target

        # keep: provision a new viewer for the pending identity.
        return self._provision_viewer(pending_identity)

    # --- admin ---------------------------------------------------------------
    def list_all(self) -> list[dict[str, Any]]:
        users = self.lldap.list_users()
        # Merge in pending users not yet in LLDAP so superadmin sees everyone.
        seen = {u["internalUserId"] for u in users}
        for u in _pending_users.values():
            if u["internalUserId"] not in seen:
                users.append(dict(u))
        return users

    def set_role(self, internal_user_id: str, role: str) -> dict[str, Any]:
        if role not in ALLOWED_ROLES:
            raise APIError("auth_bad_role", f"role must be one of {sorted(ALLOWED_ROLES)}", 400)
        user = self._find_by_internal_id(internal_user_id)
        if not user:
            raise APIError("user_not_found", "internal user not found", 404)
        user["role"] = role
        if internal_user_id in _pending_users:
            _pending_users[internal_user_id] = user
        # OpenFGA is the source of truth for roles — re-key the tuple.
        self.fga.assign_role(internal_user_id, role)
        return user


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
