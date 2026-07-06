from __future__ import annotations

import json
import logging
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app.common.errors import APIError
from app.config.settings import get_settings
from app.connections.models import ALL_SCOPES

log = logging.getLogger(__name__)

PROVISIONER_SCOPES = [
    "compute:read",
    "compute:image:read",
    "compute:size:read",
    "compute:location:read",
    "compute:node:create",
    "compute:node:delete",
    "compute:node:power",
    "compute:node:update",
    "compute:volume:manage",
    "compute:snapshot:manage",
    "compute:network:read",
    "compute:network:manage",
    "compute:keypair:manage",
    "jobs:read",
]

READER_SCOPES = [
    "compute:read",
    "compute:image:read",
    "compute:size:read",
    "compute:location:read",
    "compute:network:read",
    "jobs:read",
]

# Stable application principals → JWT scopes (independent of IdP subject format).
# Per-cloud tenant model (see ../openfga_my/authorization.md):
#   superadmin    platform bootstrap (full access)
#   aws-owner / aws-admin    provision AWS (tenant:aws)
#   aws-viewer              enumerate AWS only
#   ntnx-owner / ntnx-admin provision Nutanix (tenant:nutanix)
#   ntnx-viewer             enumerate Nutanix only
#   cloud-denied            authenticated but unauthorized (OpenFGA denies)
PRINCIPAL_SCOPES: dict[str, list[str]] = {
    "superadmin": PROVISIONER_SCOPES,
    "aws-owner": PROVISIONER_SCOPES,
    "aws-admin": PROVISIONER_SCOPES,
    "aws-viewer": READER_SCOPES,
    "ntnx-owner": PROVISIONER_SCOPES,
    "ntnx-admin": PROVISIONER_SCOPES,
    "ntnx-viewer": READER_SCOPES,
    "cloud-denied": READER_SCOPES,
}

PRINCIPAL_PROVIDERS: dict[str, list[str]] = {
    "superadmin": ["*"],
    "aws-owner": ["aws"],
    "aws-admin": ["aws"],
    "aws-viewer": ["aws"],
    "ntnx-owner": ["nutanix"],
    "ntnx-admin": ["nutanix"],
    "ntnx-viewer": ["nutanix"],
    "cloud-denied": ["aws", "nutanix"],
}

# Legacy usernames → stable principals (kept empty by default; the LLDAP uid
# is the stable principal slug in the per-tenant model, so Dex LDAP sub already
# resolves via the known-principal fallback in resolve_principal).
LEGACY_USERNAME_ALIASES: dict[str, str] = {}

_map_cache: dict[str, Any] | None = None


def _load_map() -> dict[str, Any]:
    global _map_cache
    if _map_cache is not None:
        return _map_cache

    settings = get_settings()
    path = Path(settings.principal_map_file)
    if not path.is_file():
        _map_cache = {
            "by_sub": {},
            "by_email": {},
            "legacy_username_aliases": LEGACY_USERNAME_ALIASES,
        }
        return _map_cache

    with path.open(encoding="utf-8") as fh:
        data = json.load(fh)
    data.setdefault("by_sub", {})
    data.setdefault("by_email", {})
    aliases = dict(LEGACY_USERNAME_ALIASES)
    aliases.update(data.get("legacy_username_aliases") or {})
    data["legacy_username_aliases"] = aliases
    _map_cache = data
    return _map_cache


def resolve_principal(payload: dict[str, Any]) -> str:
    """
    Map OIDC token claims to a stable application principal slug used by
    OpenFGA (user:{principal}) and scope tables.

    Resolution order:
      1. principal_map.by_sub[sub]
      2. principal_map.by_email[email]
      3. legacy_username_aliases[preferred_username|username]
      4. sub if it already matches a known principal slug
      5. preferred_username / username
    """
    mapping = _load_map()
    sub = str(payload.get("sub") or "")
    email = str(payload.get("email") or "").lower()
    username = str(
        payload.get("preferred_username") or payload.get("username") or ""
    )

    if sub and sub in mapping["by_sub"]:
        return str(mapping["by_sub"][sub])

    if email and email in mapping["by_email"]:
        return str(mapping["by_email"][email])

    aliases = mapping.get("legacy_username_aliases") or {}
    if username and username in aliases:
        return str(aliases[username])

    known = set(PRINCIPAL_SCOPES) | set(aliases.values())
    if sub in known:
        return sub
    if username in known:
        return username

    if username:
        return username
    if sub:
        return sub
    raise APIError(
        code="auth_user_unknown",
        message="OIDC token has no mappable identity claims",
        status_code=403,
    )


def _role_suffix(principal: str) -> str | None:
    """Derive a tenant role from a principal slug's suffix.

    Tenant users are named ``<tenant>-owner`` / ``<tenant>-admin`` /
    ``<tenant>-viewer`` (e.g. ``aws-admin``, ``aws-dev-owner``,
    ``ntnx-prod-viewer``). Recognizing the suffix lets a newly created tenant
    get the correct scopes/providers WITHOUT editing PRINCIPAL_SCOPES /
    PRINCIPAL_PROVIDERS. Explicit entries in those tables still win.
    ``superadmin`` is treated as an admin-equivalent.
    """
    if principal == "superadmin":
        return "admin"
    m = re.search(r"-(owner|admin|viewer)$", principal)
    return m.group(1) if m else None


def principal_scopes(principal: str) -> list[str]:
    if principal in PRINCIPAL_SCOPES:
        return PRINCIPAL_SCOPES[principal]
    role = _role_suffix(principal)
    if role in ("owner", "admin"):
        return PROVISIONER_SCOPES
    if role == "viewer":
        return READER_SCOPES
    if principal == "admin":  # legacy local-auth admin
        return ALL_SCOPES
    return []


def principal_providers(principal: str) -> list[str]:
    if principal in PRINCIPAL_PROVIDERS:
        return PRINCIPAL_PROVIDERS[principal]
    # Role-suffix principals (e.g. aws-dev-admin): permit any provider here and
    # let OpenFGA's can_use(provider:<cloud>) enforce the per-cloud boundary
    # (the tenant parents only its own provider). superadmin is unrestricted.
    if _role_suffix(principal) is not None:
        return ["*"]
    return []


def audit_auth_event(
    *,
    event: str,
    principal: str,
    issuer: str,
    subject: str,
    email: str = "",
    source: str = "oidc",
) -> None:
    """Append JSON audit lines for authentication / principal resolution."""
    settings = get_settings()
    if not settings.auth_audit_enabled:
        return

    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "event": event,
        "source": source,
        "principal": principal,
        "issuer": issuer,
        "subject": subject,
        "email": email,
    }
    line = json.dumps(record, separators=(",", ":"))
    log.info("auth_audit %s", line)

    if settings.auth_audit_file:
        path = Path(settings.auth_audit_file)
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
