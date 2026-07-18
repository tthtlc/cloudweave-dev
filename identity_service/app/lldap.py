from __future__ import annotations

import json
import logging
import urllib.error
import urllib.request
from typing import Any

from app.config import get_settings
from app.errors import APIError

log = logging.getLogger(__name__)


def _admin_token() -> str:
    """Log in to the LLDAP HTTP API as the admin user and return the JWT."""
    s = get_settings()
    body = json.dumps({"username": s.lldap_admin_user, "password": s.lldap_ldap_user_pass}).encode()
    req = urllib.request.Request(
        f"{s.lldap_http_url.rstrip('/')}/auth/simple/login",
        data=body, method="POST",
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            token = json.loads(resp.read().decode() or "{}").get("token", "")
    except urllib.error.HTTPError as exc:
        raise APIError("ldap_bind_failed", "LLDAP admin login failed", 503, {"detail": exc.read().decode("utf-8", "replace")}) from exc
    if not token:
        raise APIError("ldap_bind_failed", "LLDAP admin login returned no token", 503)
    return token


def _ldap_connect():
    from ldap3 import (  # imported lazily so the service can boot without ldap3 in CI
        ALL,
        Connection,
        Server,
        SUBTREE,
    )

    s = get_settings()
    server = Server(s.lldap_host, port=s.lldap_port, use_ssl=s.lldap_use_ssl, get_info=ALL)
    conn = Connection(server, user=s.lldap_bind_dn, password=s.lldap_bind_pw, auto_bind=True)
    if not conn.bind():
        raise APIError("ldap_bind_failed", "LLDAP bind failed", 503)
    return conn, SUBTREE


class LldapService:
    """Reads the internal user directory from LLDAP.

    LLDAP is the source of truth for user records (uid, mail, cn). Application
    roles live in OpenFGA, not LLDAP — see fga.py. This service only does
    directory lookups; it never authorizes.
    """

    def list_users(self) -> list[dict[str, Any]]:
        from ldap3 import ALL_ATTRIBUTES

        conn, _ = _ldap_connect()
        s = get_settings()
        users: list[dict[str, Any]] = []
        conn.search(
            search_base=s.lldap_base_dn,
            search_filter="(objectClass=person)",
            search_scope="SUBTREE",
            attributes=[ALL_ATTRIBUTES],
        )
        for entry in conn.entries:
            uid = str(entry.uid) if hasattr(entry, "uid") else str(entry.entry_dn)
            mail = str(entry.mail[0]) if hasattr(entry, "mail") and entry.mail else ""
            cn = str(entry.cn[0]) if hasattr(entry, "cn") and entry.cn else uid
            users.append({
                "internalUserId": f"int-{uid}",
                "email": mail,
                "displayName": cn,
                # role is filled in by the caller from OpenFGA; default viewer
                "role": "viewer",
                "linkedIdentities": [],  # TODO: map LLDAP -> provider subjects if stored as attributes
                "createdAt": "",
            })
        conn.unbind()
        return users

    def find_by_email(self, email: str) -> list[dict[str, Any]]:
        """Collapse heuristic input: existing internal users sharing an email."""
        if not email:
            return []
        conn, _ = _ldap_connect()
        s = get_settings()
        conn.search(
            search_base=s.lldap_base_dn,
            search_filter=f"(&(objectClass=person)(mail={email}))",
            search_scope="SUBTREE",
            attributes=["uid", "mail", "cn"],
        )
        out = []
        for entry in conn.entries:
            out.append({
                "internalUserId": f"int-{entry.uid}",
                "email": str(entry.mail[0]) if entry.mail else "",
                "displayName": str(entry.cn[0]) if entry.cn else str(entry.uid),
                "role": "viewer",
                "linkedIdentities": [],
            })
        conn.unbind()
        return out

    def set_email(self, uid: str, email: str) -> None:
        """Set the mail attribute on an LLDAP user (GraphQL updateUser).

        Email is the contact channel for the platform; the superadmin screen
        requires it, so this is how a missing email is filled in.
        """
        if not email:
            raise APIError("user_bad_email", "email must be non-empty", 400)
        token = _admin_token()
        mutation = (
            "mutation UpdateUser($user: UpdateUserInput!) {"
            "  updateUser(user: $user) { ok }"
            "}"
        )
        payload = json.dumps({"query": mutation, "variables": {"user": {"id": uid, "email": email}}}).encode()
        req = urllib.request.Request(
            f"{get_settings().lldap_http_url.rstrip('/')}/api/graphql",
            data=payload, method="POST",
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                body = json.loads(resp.read().decode() or "{}")
        except urllib.error.HTTPError as exc:
            raise APIError("ldap_update_failed", "LLDAP updateUser failed", 503, {"detail": exc.read().decode("utf-8", "replace")}) from exc
        if body.get("errors"):
            raise APIError("ldap_update_failed", "LLDAP updateUser rejected", 400, {"detail": body["errors"]})
