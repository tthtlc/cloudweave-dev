#!/usr/bin/env python3
"""List Vault's own users — auth-method users/roles and identity entities.

This is the "strict Vault sense" of a user: the identities Vault itself manages
for authentication and authorization (AppRole roles, userpass users, LDAP
users/groups, token roles, and the identity engine's entities/aliases/groups).
It does **not** dump the cloud tenant accounts stored as KV secrets under
``secret/libcloud/`` — use ``list_credentials.py`` for those.

Reads ``VAULT_ADDR`` and ``VAULT_ROOT_TOKEN`` (fallback ``VAULT_TOKEN``) from
``generated/vault.env`` by default; each is overridable via environment
variables or CLI flags. Prefers the root token because listing auth methods,
identity entities, and roles requires privileged access (the read-only
``libcloud-rest-read`` token cannot see them).

Sensitive values are never printed: this is a names-and-metadata dump only.
Secret IDs, policy HCL bodies, and login material are deliberately omitted.

Usage:
    python3 list_users.py
    python3 list_users.py --addr http://localhost:8200 --token hvs...
    python3 list_users.py --json     # machine-readable JSON instead of text
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

GENERATED_ENV = Path(__file__).resolve().parent / "generated" / "vault.env"


def load_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.exists():
        return env
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip()
    return env


def request(method: str, url: str, token: str) -> tuple[int, dict]:
    req = urllib.request.Request(url, method=method)
    req.add_header("X-Vault-Token", token)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        return exc.code, {"error": body}
    except urllib.error.URLError as exc:
        print(f"ERROR: cannot reach Vault at {url}: {exc.reason}", file=sys.stderr)
        sys.exit(2)


def _list_keys(addr: str, token: str, path: str) -> list[str] | None:
    """LIST a Vault path; return the keys, [] if empty, None if forbidden/absent."""
    url = f"{addr}/v1/{path}?list=true"
    status, data = request("LIST", url, token)
    if status == 200:
        return data.get("data", {}).get("keys", [])
    return None  # 404 (not enabled / none), 403 (no privilege), etc.


def _get(addr: str, token: str, path: str) -> dict | None:
    """GET a Vault path; return the ``data`` payload or None on failure."""
    url = f"{addr}/v1/{path}"
    status, data = request("GET", url, token)
    if status != 200:
        return None
    return data.get("data")


# Auth-method type -> the endpoint(s) that list its users/roles. ``None`` means
# "no listable user/role collection" (e.g. cert, radius).
AUTH_USER_LISTS: dict[str, list[str]] = {
    "approle": ["auth/approle/role"],
    "userpass": ["auth/userpass/users"],
    "ldap": ["auth/ldap/users", "auth/ldap/groups"],
    "okta": ["auth/okta/users", "auth/okta/groups"],
    "oidc": ["auth/oidc/role"],
    "jwt": ["auth/jwt/role"],
    "github": ["auth/github/users", "auth/github/teams"],
    "kubernetes": ["auth/kubernetes/role"],
    "token": ["auth/token/roles"],
    "azure": ["auth/azure/role"],
    "gcp": ["auth/gcp/roleset"],
    "alicloud": ["auth/alicloud/role"],
}


def collect(addr: str, token: str) -> dict:
    """Gather every Vault user/identity into one nested structure."""
    out: dict = {
        "status": {},
        "auth_methods": {},
        "identity": {"entities": [], "groups": []},
    }

    status, data = request("GET", f"{addr}/v1/sys/seal-status", token)
    out["status"] = data if status == 200 else {"sealed": None, "initialized": None}

    # Enabled auth methods + their mount accessors (accessor -> path map is
    # needed to resolve entity aliases back to a mount path).
    accessor_to_path: dict[str, str] = {}
    status, data = request("GET", f"{addr}/v1/sys/auth", token)
    methods: dict = data.get("data", {}) if status == 200 else {}
    for mount_path, mount in methods.items():
        mount_path = mount_path.rstrip("/")
        mtype = mount.get("type", "")
        out["auth_methods"][mount_path] = {
            "type": mtype,
            "description": mount.get("description", ""),
            "users": {},
        }
        acc = mount.get("accessor")
        if acc:
            accessor_to_path[acc] = mount_path

        # List this method's users/roles (roles, users, groups, ...).
        for rel in AUTH_USER_LISTS.get(mtype, []):
            keys = _list_keys(addr, token, rel)
            if keys is None:
                continue
            label = rel.rsplit("/", 1)[-1]
            out["auth_methods"][mount_path]["users"][label] = sorted(keys)

    # Per-role metadata for the two most common "user"-like collections.
    for mount_path, info in out["auth_methods"].items():
        mtype = info["type"]
        if mtype == "approle":
            meta: dict = {}
            for role in info["users"].get("role", []):
                m = _get(addr, token, f"auth/approle/role/{role}")
                if m is None:
                    continue
                meta[role] = {
                    "token_policies": m.get("token_policies", []),
                    "token_ttl": m.get("token_ttl"),
                    "token_max_ttl": m.get("token_max_ttl"),
                    "token_type": m.get("token_type"),
                }
            info["roles_meta"] = meta
        elif mtype == "userpass":
            meta = {}
            for user in info["users"].get("users", []):
                m = _get(addr, token, f"auth/userpass/users/{user}")
                if m is None:
                    continue
                meta[user] = {
                    "token_policies": m.get("token_policies", []),
                    "token_ttl": m.get("token_ttl"),
                    "token_max_ttl": m.get("token_max_ttl"),
                }
            info["users_meta"] = meta

    # Identity engine: entities (the canonical "users") + their aliases, then
    # groups. Resolve each alias's mount_accessor back to a mount path.
    entity_ids = _list_keys(addr, token, "identity/entity/id") or []
    for eid in entity_ids:
        m = _get(addr, token, f"identity/entity/id/{eid}")
        if m is None:
            continue
        aliases = []
        for a in m.get("aliases", []) or []:
            aliases.append({
                "name": a.get("name"),
                "mount_type": a.get("mount_type"),
                "mount_path": accessor_to_path.get(a.get("mount_accessor"), a.get("mount_accessor")),
            })
        out["identity"]["entities"].append({
            "id": m.get("id"),
            "name": m.get("name"),
            "policies": m.get("policies", []),
            "metadata": m.get("metadata", {}),
            "aliases": aliases,
        })

    group_ids = _list_keys(addr, token, "identity/group/id") or []
    for gid in group_ids:
        m = _get(addr, token, f"identity/group/id/{gid}")
        if m is None:
            continue
        out["identity"]["groups"].append({
            "id": m.get("id"),
            "name": m.get("name"),
            "policies": m.get("policies", []),
            "member_entity_ids": m.get("member_entity_ids", []),
        })

    return out


def render_text(dump: dict) -> str:
    lines: list[str] = []
    st = dump["status"]
    sealed = st.get("sealed")
    init = st.get("initialized")
    lines.append(f"Vault status: initialized={init} sealed={sealed}")

    lines.append("\n== Auth methods ==")
    if not dump["auth_methods"]:
        lines.append("  (none / cannot read)")
    for mount_path in sorted(dump["auth_methods"]):
        info = dump["auth_methods"][mount_path]
        lines.append(f"\n  [{mount_path}/] type={info['type']}  {info['description']}")
        for label, keys in sorted(info["users"].items()):
            lines.append(f"    {label} ({len(keys)}): {', '.join(keys) if keys else '(none)'}")
        if info.get("roles_meta"):
            lines.append("    roles:")
            for role, m in sorted(info["roles_meta"].items()):
                lines.append(f"      {role}: policies={m['token_policies']} "
                             f"ttl={m['token_ttl']} max_ttl={m['token_max_ttl']} "
                             f"type={m['token_type']}")
        if info.get("users_meta"):
            lines.append("    users:")
            for user, m in sorted(info["users_meta"].items()):
                lines.append(f"      {user}: policies={m['token_policies']} "
                             f"ttl={m['token_ttl']} max_ttl={m['token_max_ttl']}")

    lines.append("\n== Identity entities (users) ==")
    entities = dump["identity"]["entities"]
    if not entities:
        lines.append("  (none)")
    for e in entities:
        lines.append(f"  {e['name']}  (id={e['id']})")
        if e["policies"]:
            lines.append(f"    policies: {', '.join(e['policies'])}")
        if e["metadata"]:
            lines.append(f"    metadata: {e['metadata']}")
        for a in e["aliases"]:
            lines.append(f"    alias: {a['name']}  (mount={a['mount_path']}, type={a['mount_type']})")

    lines.append("\n== Identity groups ==")
    groups = dump["identity"]["groups"]
    if not groups:
        lines.append("  (none)")
    for g in groups:
        lines.append(f"  {g['name']}  (id={g['id']})")
        if g["policies"]:
            lines.append(f"    policies: {', '.join(g['policies'])}")
        if g["member_entity_ids"]:
            lines.append(f"    members: {', '.join(g['member_entity_ids'])}")

    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--addr", default=os.environ.get("VAULT_ADDR"))
    ap.add_argument("--token", default=os.environ.get("VAULT_TOKEN"))
    ap.add_argument("--json", action="store_true", help="print a single JSON object instead of text")
    args = ap.parse_args()

    env = load_env(GENERATED_ENV)
    addr = args.addr or env.get("VAULT_ADDR") or os.environ.get("VAULT_ADDR")
    # Identity entities + auth-method listing need privileged access, so prefer
    # the root token (like add/delete_credential.py do).
    token = (args.token or env.get("VAULT_ROOT_TOKEN")
             or env.get("VAULT_TOKEN") or os.environ.get("VAULT_TOKEN"))
    if not addr or not token:
        print("ERROR: VAULT_ADDR/VAULT_TOKEN not found in generated/vault.env or env.", file=sys.stderr)
        return 1

    dump = collect(addr, token)
    if args.json:
        print(json.dumps(dump, indent=2, default=str))
    else:
        print(render_text(dump))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
