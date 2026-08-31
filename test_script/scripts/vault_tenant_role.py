#!/usr/bin/env python3
"""vault_tenant_role.py
======================
Create a tenant's per-tenant Vault AppRole identity (the tenant's "vault user")
and store its login material so the libcloud REST API can authenticate to Vault
as that tenant.

For each tenant this creates:
  - an ACL policy ``libcloud-read-<tenant>`` scoped to that tenant's cloud secret
    at ``secret/data/libcloud/<tenant>`` (+ metadata),
  - an AppRole role ``libcloud-<tenant>`` bound to that policy, and
  - a secret_id, stored (with the role_id) at
    ``secret/data/libcloud-vault-auth/libcloud-<tenant>``.

The tenant -> vault_user mapping is recorded separately in OpenFGA
(``tenant:<tenant> parent vault_user:libcloud-<tenant>``) by create_tenant.sh /
openfga_bootstrap.py. The REST API resolves that mapping, reads this script's
auth material with its orchestrator token, performs an AppRole login, and reads
the tenant's cloud secret with the resulting short-lived token.

This mirrors set_tenant_credentials.py (same env/HTTP style) but creates the
Vault *identity*, not the tenant's cloud credentials. Tenant cloud credentials
are written separately by set_tenant_credentials.py (owner-gated).

Usage:
  TENANT=aws-dev python3 scripts/vault_tenant_role.py
  TENANT=aws-dev ROLE=libcloud-aws-dev python3 scripts/vault_tenant_role.py

The root token comes from ../vault/generated/vault.env (or VAULT_ROOT_TOKEN in
the environment). Callers (create_tenant.sh) gate this on a superadmin login.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
VAULT_ENV = REPO_ROOT / "vault" / "generated" / "vault.env"


def _die(msg: str, code: int = 1) -> int:
    print(f"vault_tenant_role: {msg}", file=sys.stderr)
    return code


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


def _request(method: str, path: str, token: str, body: dict | None = None) -> dict:
    """Vault HTTP API call rooted at /v1/. Returns the decoded JSON body."""
    if not path.startswith("/v1/"):
        path = "/v1" + path if path.startswith("/") else "/v1/" + path
    url = os.environ.get("VAULT_ADDR", "").rstrip("/") + path
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
        raise RuntimeError(
            f"Vault {method} {path} failed (HTTP {exc.code}): "
            f"{exc.read().decode('utf-8', 'replace')}"
        ) from exc


def main() -> int:
    tenant = os.environ.get("TENANT", "").strip().lower()
    if not tenant:
        return _die("TENANT is required (the tenant id, e.g. aws / nutanix / aws-dev)", 2)
    role = os.environ.get("ROLE", "").strip() or f"libcloud-{tenant}"

    vault = _load_env(VAULT_ENV)
    vault_addr = os.environ.get("VAULT_ADDR", vault.get("VAULT_ADDR", "http://localhost:8200")).rstrip("/")
    root_token = os.environ.get("VAULT_ROOT_TOKEN", vault.get("VAULT_ROOT_TOKEN", ""))
    if not root_token:
        return _die("missing VAULT_ROOT_TOKEN — run ./setup.sh first", 2)
    os.environ.setdefault("VAULT_ADDR", vault_addr)

    kv_mount = os.environ.get("VAULT_KV_MOUNT", "secret")
    kv_prefix = os.environ.get("VAULT_KV_PREFIX", "libcloud")
    auth_prefix = os.environ.get("VAULT_APPROLE_AUTH_PREFIX", "libcloud-vault-auth")
    approle_mount = os.environ.get("VAULT_APPROLE_MOUNT", "approle")

    policy_name = f"libcloud-read-{tenant}"
    policy = (
        f'path "{kv_mount}/data/{kv_prefix}/{tenant}" {{ capabilities = ["read"] }}\n'
        f'path "{kv_mount}/metadata/{kv_prefix}/{tenant}" {{ capabilities = ["read", "list"] }}\n'
    )

    # 1. Scoped read policy for this tenant.
    _request("PUT", f"/sys/policies/acl/{policy_name}", root_token, {"policy": policy})
    print(f"Ensured tenant ACL policy {policy_name}.", file=sys.stderr)

    # 2. AppRole role bound to that policy. Role create/update returns 204 with
    #    no body, so read the role_id back via its own endpoint.
    _request(
        "POST",
        f"/auth/{approle_mount}/role/{role}",
        root_token,
        {
            "token_policies": [policy_name],
            "token_ttl": "60m",
            "token_max_ttl": "120m",
        },
    )
    role_id_resp = _request("GET", f"/auth/{approle_mount}/role/{role}/role-id", root_token)
    role_id = (role_id_resp.get("data") or {}).get("role_id", "")
    if not role_id:
        return _die(f"AppRole {role} returned no role_id")
    print(f"Created AppRole {role} (role_id={role_id[:8]}…).", file=sys.stderr)

    # 3. Mint a secret_id.
    sid_resp = _request(
        "POST",
        f"/auth/{approle_mount}/role/{role}/secret-id",
        root_token,
        {},
    )
    secret_id = (sid_resp.get("data") or {}).get("secret_id", "")
    if not secret_id:
        return _die(f"AppRole {role} returned no secret_id")

    # 4. Store the login material for the REST API (orchestrator token reads it).
    _request(
        "POST",
        f"/v1/{kv_mount}/data/{auth_prefix}/{role}",
        root_token,
        {"data": {"role_id": role_id, "secret_id": secret_id}},
    )
    print(f"OK: AppRole {role} created for tenant:{tenant} "
          f"(policy={policy_name}, auth material at {kv_mount}/data/{auth_prefix}/{role}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
