#!/usr/bin/env python3
"""materialize_vault_users.py
=============================
Create the per-tenant Vault AppRole identities (the "vault users") for every
tenant that already has a backend secret, so the libcloud REST API can read each
tenant's credentials with a scoped, short-lived token instead of the root token.

This is the "backfill / repair" counterpart to vault_tenant_role.py (which
creates ONE tenant's identity and assumes the AppRole auth method is already
enabled). It:

  1. enables the AppRole auth method at ``auth/approle`` (idempotent),
  2. discovers tenants by listing ``secret/metadata/libcloud/`` (any tenant with
     a backend secret needs a matching vault user), and
  3. for each tenant creates:
       - ACL policy ``libcloud-read-<tenant>``  (read only that tenant's secret)
       - AppRole role ``libcloud-<tenant>`` bound to that policy
       - a secret_id, stored (with the role_id) at
         ``secret/data/libcloud-vault-auth/libcloud-<tenant>``

The tenant -> vault_user mapping itself lives in OpenFGA
(``tenant:<t> parent vault_user:libcloud-<t>``) and is written by
create_tenant.sh / openfga_bootstrap.py — this script does not touch OpenFGA.

Vault-only: uses the root token from ../vault/generated/vault.env (no superadmin
JWT required — creating identities is a Vault admin op, not an OpenFGA-gated
credential write).

Idempotent: re-running re-asserts policies/roles and mints a fresh secret_id
(the stored auth material is refreshed; old secret_ids stay valid until the
role's TTL lapses).

Usage:
    python3 test_script/scripts/materialize_vault_users.py
    python3 test_script/scripts/materialize_vault_users.py --tenant aws --tenant nutanix
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
VAULT_ENV = REPO_ROOT / "vault" / "generated" / "vault.env"


def _load_env(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v
    return out


def _request(method: str, path: str, token: str, body: dict | None = None,
             allow_statuses: tuple[int, ...] = ()) -> dict:
    """Vault HTTP API call rooted at /v1/. Returns the decoded JSON body."""
    if not path.startswith("/v1/"):
        path = "/v1" + path if path.startswith("/") else "/v1/" + path
    addr = os.environ.get("VAULT_ADDR", "").rstrip("/")
    url = addr + path
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"X-Vault-Token": token}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            raw = resp.read().decode("utf-8") or "{}"
            return json.loads(raw)
    except urllib.error.HTTPError as exc:
        if exc.code in allow_statuses:
            try:
                return json.loads(exc.read().decode("utf-8") or "{}")
            except json.JSONDecodeError:
                return {}
        raise RuntimeError(
            f"Vault {method} {path} failed (HTTP {exc.code}): "
            f"{exc.read().decode('utf-8', 'replace')}"
        ) from exc


def enable_approle(token: str, mount: str) -> None:
    _request("POST", f"/sys/auth/{mount}", token, {"type": "approle"},
             allow_statuses=(400,))  # 400 = already enabled at that path
    print(f"Enabled AppRole auth at /auth/{mount}.")


def discover_tenants(token: str, kv_mount: str, kv_prefix: str) -> list[str]:
    status, _ = _request_list(token, kv_mount, kv_prefix)
    return status


def _request_list(token: str, kv_mount: str, kv_prefix: str) -> tuple[list[str], str]:
    """LIST secret/metadata/<kv_prefix>/ and return (tenant_names, error)."""
    path = f"/{kv_mount}/metadata/{kv_prefix}"
    try:
        body = _request("LIST", path, token)
    except RuntimeError as exc:
        if "404" in str(exc) or "403" in str(exc):
            return [], str(exc)
        raise
    keys = (body.get("data") or {}).get("keys", [])
    # Keys that end in "/" are sub-directories; the rest are leaf secret names.
    return [k for k in keys if not k.endswith("/")], ""


def ensure_tenant_approle(token: str, tenant: str, kv_mount: str, kv_prefix: str,
                          auth_prefix: str, approle_mount: str) -> None:
    role = f"libcloud-{tenant}"
    policy_name = f"libcloud-read-{tenant}"
    policy = (
        f'path "{kv_mount}/data/{kv_prefix}/{tenant}" {{ capabilities = ["read"] }}\n'
        f'path "{kv_mount}/metadata/{kv_prefix}/{tenant}" {{ capabilities = ["read", "list"] }}\n'
    )

    _request("PUT", f"/sys/policies/acl/{policy_name}", token, {"policy": policy})
    # Role create/update returns 204 with no body; the role_id is read back via
    # its own endpoint (GET /auth/approle/role/:role/role-id).
    _request(
        "POST",
        f"/auth/{approle_mount}/role/{role}",
        token,
        {"token_policies": [policy_name], "token_ttl": "60m", "token_max_ttl": "120m"},
    )
    role_id_resp = _request(
        "GET",
        f"/auth/{approle_mount}/role/{role}/role-id",
        token,
    )
    role_id = (role_id_resp.get("data") or {}).get("role_id", "")
    if not role_id:
        raise RuntimeError(f"AppRole {role} returned no role_id")

    sid_resp = _request(
        "POST",
        f"/auth/{approle_mount}/role/{role}/secret-id",
        token,
        {},
    )
    secret_id = (sid_resp.get("data") or {}).get("secret_id", "")
    if not secret_id:
        raise RuntimeError(f"AppRole {role} returned no secret_id")

    _request(
        "POST",
        f"/v1/{kv_mount}/data/{auth_prefix}/{role}",
        token,
        {"data": {"role_id": role_id, "secret_id": secret_id}},
    )
    print(f"  ok  {role:<20} policy={policy_name:<22} "
          f"auth@/{kv_mount}/data/{auth_prefix}/{role}")


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--tenant", action="append", default=[],
                    help="restrict to this tenant (repeatable); default: discover all")
    args = ap.parse_args()

    env = _load_env(VAULT_ENV)
    vault_addr = os.environ.get("VAULT_ADDR", env.get("VAULT_ADDR", "http://localhost:8200")).rstrip("/")
    root_token = os.environ.get("VAULT_ROOT_TOKEN", env.get("VAULT_ROOT_TOKEN", ""))
    if not root_token:
        print("ERROR: missing VAULT_ROOT_TOKEN — run ./setup.sh first", file=sys.stderr)
        return 2
    os.environ.setdefault("VAULT_ADDR", vault_addr)

    kv_mount = os.environ.get("VAULT_KV_MOUNT", "secret")
    kv_prefix = os.environ.get("VAULT_KV_PREFIX", "libcloud")
    auth_prefix = os.environ.get("VAULT_APPROLE_AUTH_PREFIX", "libcloud-vault-auth")
    approle_mount = os.environ.get("VAULT_APPROLE_MOUNT", "approle")

    print(f"Vault: {vault_addr}")
    enable_approle(root_token, approle_mount)

    tenants = args.tenant or discover_tenants(root_token, kv_mount, kv_prefix)
    if not tenants:
        print(f"No tenants found under {kv_mount}/metadata/{kv_prefix}/ — nothing to do.")
        return 0

    print(f"Materializing vault users for {len(tenants)} tenant(s): {', '.join(tenants)}")
    failures = 0
    for t in sorted(tenants):
        try:
            ensure_tenant_approle(root_token, t, kv_mount, kv_prefix, auth_prefix, approle_mount)
        except RuntimeError as exc:
            failures += 1
            print(f"  FAIL {t}: {exc}", file=sys.stderr)

    print(f"\nDone: {len(tenants) - failures}/{len(tenants)} vault user(s) created.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
