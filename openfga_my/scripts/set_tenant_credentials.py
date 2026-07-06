#!/usr/bin/env python3
"""set_tenant_credentials.py
============================
Write a tenant's backend cloud credentials into Vault. Per-tenant, NOT global:

  tenant:aws      -> secret/data/libcloud/aws      {key, secret}
  tenant:aws-dev  -> secret/data/libcloud/aws-dev  {key, secret}
  tenant:nutanix  -> secret/data/libcloud/nutanix  {key, secret}

The tenant id (TENANT) is arbitrary; the *cloud* (CLOUD=aws|nutanix) selects
which credential env fields are read (LIBCLOUD_AWS_KEY/SECRET vs
LIBCLOUD_NTNX_USER/PASSWORD). For the default tenants CLOUD is inferred from
TENANT; for any other tenant pass CLOUD explicitly.

The write is gated on OpenFGA: the caller must log in to Dex (as an LLDAP
user) and hold `can_manage_credentials` on the target tenant — a relation
defined as `owner` only. So only the tenant owner (and superadmin, who is
owner on every tenant as break-glass) can update that tenant's credentials.
admins and viewers are denied.

Usage:
  TENANT=aws LIBCLOUD_USER=aws-owner LIBCLOUD_PASSWORD=... \
    LIBCLOUD_AWS_KEY=AKIA... LIBCLOUD_AWS_SECRET=... \
    python3 scripts/set_tenant_credentials.py

  TENANT=aws-dev CLOUD=aws LIBCLOUD_USER=aws-dev-owner LIBCLOUD_PASSWORD=... \
    LIBCLOUD_AWS_KEY=AKIA... LIBCLOUD_AWS_SECRET=... \
    python3 scripts/set_tenant_credentials.py

  TENANT=nutanix LIBCLOUD_USER=ntnx-owner LIBCLOUD_PASSWORD=... \
    LIBCLOUD_NTNX_USER=admin LIBCLOUD_NTNX_PASSWORD=... \
    python3 scripts/set_tenant_credentials.py

Credentials are never read from .env; the owner supplies them at runtime.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FGA_ENV = ROOT / "generated" / "fga.env"
VAULT_ENV = ROOT.parent / "vault" / "generated" / "vault.env"
CLOUDS = {"aws", "nutanix"}


def _infer_cloud(tenant: str) -> str | None:
    """Infer the cloud for the default seeded tenants only."""
    if tenant == "aws":
        return "aws"
    if tenant == "nutanix":
        return "nutanix"
    return None


def _die(msg: str, code: int = 1) -> int:
    print(f"set_tenant_credentials: {msg}", file=sys.stderr)
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


def _fga_check(store_id: str, model_id: str, fga_url: str, user: str, relation: str, obj: str, bearer: str | None = None) -> bool:
    payload = json.dumps({
        "authorization_model_id": model_id,
        "tuple_key": {"user": user, "relation": relation, "object": obj},
    }).encode()
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    req = urllib.request.Request(
        f"{fga_url.rstrip('/')}/stores/{store_id}/check",
        data=payload, method="POST",
        headers=headers,
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return bool(json.loads(resp.read().decode() or "{}").get("allowed", False))
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"OpenFGA check failed (HTTP {exc.code}): {exc.read().decode('utf-8', 'replace')}") from exc


def _vault_write(vault_addr: str, root_token: str, tenant: str, data: dict[str, str]) -> None:
    url = f"{vault_addr.rstrip('/')}/v1/secret/data/libcloud/{tenant}"
    req = urllib.request.Request(
        url, data=json.dumps({"data": data}).encode(), method="POST",
        headers={"X-Vault-Token": root_token, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            resp.read()
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"Vault write failed (HTTP {exc.code}): {exc.read().decode('utf-8', 'replace')}") from exc


def main() -> int:
    tenant = os.environ.get("TENANT", "").strip().lower()
    if not tenant:
        return _die("TENANT is required (the tenant id, e.g. aws / aws-dev / nutanix)", 2)

    cloud = os.environ.get("CLOUD", "").strip().lower() or _infer_cloud(tenant) or ""
    if cloud not in CLOUDS:
        return _die(
            f"CLOUD must be one of {sorted(CLOUDS)} (got {cloud!r}); "
            f"set CLOUD=aws|nutanix (required for non-default tenants)",
            2,
        )

    user = os.environ.get("LIBCLOUD_USER", "").strip()
    password = os.environ.get("LIBCLOUD_PASSWORD", "").strip()
    if not user or not password:
        return _die("LIBCLOUD_USER and LIBCLOUD_PASSWORD are required (the tenant owner)", 2)

    # Collect the credential fields for this tenant's cloud (no .env lookup).
    if cloud == "aws":
        data = {
            "key": os.environ.get("LIBCLOUD_AWS_KEY", "").strip(),
            "secret": os.environ.get("LIBCLOUD_AWS_SECRET", "").strip(),
        }
        cred_env = "LIBCLOUD_AWS_KEY/LIBCLOUD_AWS_SECRET"
    else:
        data = {
            "key": os.environ.get("LIBCLOUD_NTNX_USER", "").strip(),
            "secret": os.environ.get("LIBCLOUD_NTNX_PASSWORD", "").strip(),
        }
        cred_env = "LIBCLOUD_NTNX_USER/LIBCLOUD_NTNX_PASSWORD"
    if not data["key"] or not data["secret"]:
        return _die(
            f"credential values are required at runtime for tenant:{tenant} "
            f"(cloud={cloud}; set {cred_env})",
            2,
        )

    fga = _load_env(FGA_ENV)
    store_id = fga.get("FGA_STORE_ID") or os.environ.get("FGA_STORE_ID", "")
    model_id = fga.get("FGA_MODEL_ID") or os.environ.get("FGA_MODEL_ID", "")
    fga_url = os.environ.get("FGA_API_URL", "http://localhost:8080")
    if not store_id or not model_id:
        return _die("missing FGA_STORE_ID/FGA_MODEL_ID — run ./setup.sh first", 2)

    vault = _load_env(VAULT_ENV)
    vault_addr = os.environ.get("VAULT_ADDR", vault.get("VAULT_ADDR", "http://localhost:8200"))
    root_token = os.environ.get("VAULT_ROOT_TOKEN", vault.get("VAULT_ROOT_TOKEN", ""))
    if not root_token:
        return _die("missing VAULT_ROOT_TOKEN — run ./setup.sh first", 2)

    # 1. Authenticate the caller against Dex (proves the owner identity).
    print(f"Authenticating {user} against Dex ...", file=sys.stderr)
    env = dict(os.environ)
    env["LIBCLOUD_USER"] = user
    env["LIBCLOUD_PASSWORD"] = password
    proc = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "idp_login.py")],
        env=env, capture_output=True, text=True, timeout=60,
    )
    if proc.returncode != 0:
        return _die(f"Dex login for {user} failed: {proc.stderr.strip()}")
    jwt = proc.stdout.strip()
    if not jwt:
        return _die(f"Dex login for {user} returned an empty token")

    # 2. Authorize via OpenFGA: caller must be able to manage this tenant's creds.
    fga_user = f"user:{user}"
    print(f"OpenFGA Check {fga_user} can_manage_credentials tenant:{tenant} ...", file=sys.stderr)
    try:
        allowed = _fga_check(store_id, model_id, fga_url, fga_user, "can_manage_credentials", f"tenant:{tenant}", bearer=jwt)
    except Exception as exc:
        return _die(str(exc))
    if not allowed:
        return _die(
            f"{fga_user} is not allowed to manage credentials for tenant:{tenant} "
            "(only the tenant owner / superadmin can).", 3
        )

    # 3. Write the per-tenant secret to Vault.
    print(f"Writing secret/libcloud/{tenant} to Vault ...", file=sys.stderr)
    try:
        _vault_write(vault_addr, root_token, tenant, data)
    except Exception as exc:
        return _die(str(exc))
    print(f"OK: credentials for tenant:{tenant} updated by {user}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
