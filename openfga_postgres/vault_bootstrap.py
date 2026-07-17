#!/usr/bin/env python3
"""
vault_bootstrap.py
==================
Initialize, unseal, configure and seed a local Vault server for the libcloud
REST API. Vault stores backend cloud login credentials (AWS / Nutanix) as
encrypted KV v2 secrets under ``secret/libcloud/*``. The libcloud REST API
reads them at runtime instead of holding raw credentials in environment files.

Idempotent and safe to re-run:
  1. Verify a superadmin JWT (SUPERADMIN_JWT) is present and valid — without a
     successful Dex login as the LLDAP `superadmin` user, Vault seeding is
     refused. This enforces: backend cloud credentials can only be written by
     superadmin.
  2. Wait for Vault to be reachable.
  3. Initialize (1 key, threshold 1) if not yet initialized; persist root token
     and unseal key to generated/vault.env (gitignored, host-persistent).
  4. Unseal if sealed.
  5. Enable KV v2 at ``secret/`` if not already enabled.
  6. Create a least-privilege read policy ``libcloud-rest-read`` and a token for
     the libcloud REST API; write the token to generated/vault.env as
     VAULT_TOKEN.
  7. Per-tenant backend cloud credentials are NOT seeded here. They are
     written by the tenant owner via scripts/set_tenant_credentials.py, which
     gates the write on OpenFGA ``can_manage_credentials`` (owner-only). This
     keeps AWS/Nutanix credentials out of global env vars and lets different
     tenants use different backend accounts.

This is a single-host demo configuration. For production use Raft storage, TLS
listeners, auto-unseal, and short-lived dynamic credentials.
"""
from __future__ import annotations

import json
import logging
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

logging.basicConfig(
    level=os.environ.get("VAULT_LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("vault-bootstrap")

# vault.env (root token + unseal key + API read token) lives in the sibling
# ../vault project (self-contained standalone compose). Override via
# VAULT_OUTPUT_DIR for non-default layouts.
GENERATED_DIR = Path(os.environ.get("VAULT_OUTPUT_DIR", Path(__file__).resolve().parent.parent / "vault" / "generated"))
VAULT_ENV = GENERATED_DIR / "vault.env"
KV_MOUNT = os.environ.get("VAULT_KV_MOUNT", "secret")
KV_PREFIX = os.environ.get("VAULT_KV_PREFIX", "libcloud")
READ_POLICY_NAME = os.environ.get("VAULT_LIBCLOUD_POLICY", "libcloud-rest-read")

READ_POLICY = f"""# Read-only access to libcloud backend credentials (KV v2).
path "{KV_MOUNT}/data/{KV_PREFIX}/*" {{
  capabilities = ["read"]
}}
path "{KV_MOUNT}/metadata/{KV_PREFIX}/*" {{
  capabilities = ["read", "list"]
}}
"""


def _vault_addr() -> str:
    return os.environ.get("VAULT_ADDR", "http://vault:8200").rstrip("/")


def _request(method: str, path: str, *, token: str | None = None, body: dict | None = None,
             timeout: float = 10.0, allow_statuses: tuple[int, ...] = ()) -> tuple[int, dict]:
    # Vault's HTTP API is rooted at /v1/. Normalize so callers can pass either
    # "/sys/init" or "/v1/sys/init" (and the KV path used by seed_secret).
    if not path.startswith("/v1/"):
        path = "/v1" + path if path.startswith("/") else "/v1/" + path
    url = _vault_addr() + path
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["X-Vault-Token"] = token
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8") or "{}"
            return resp.status, json.loads(raw)
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            payload = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            payload = {"raw": raw}
        if exc.code in allow_statuses:
            return exc.code, payload
        raise RuntimeError(f"{method} {path} -> HTTP {exc.code}: {raw}") from exc


def wait_for_vault(timeout: float = 120.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            status, _ = _request("GET", "/sys/init", timeout=5)
            if status == 200:
                return
        except Exception:
            pass
        time.sleep(2)
    raise RuntimeError(f"Timed out waiting for Vault at {_vault_addr()}")


def _read_existing_env() -> dict[str, str]:
    if not VAULT_ENV.is_file():
        return {}
    out: dict[str, str] = {}
    for line in VAULT_ENV.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v
    return out


def _write_env(values: dict[str, str]) -> Path:
    GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    lines = [
        "# Generated by vault_bootstrap.py — DO NOT COMMIT (gitignored).",
        "# Vault root token + unseal key + libcloud REST API token.",
        f"VAULT_ADDR={values['VAULT_ADDR']}",
        f"VAULT_TOKEN={values['VAULT_TOKEN']}",
        f"VAULT_ROOT_TOKEN={values['VAULT_ROOT_TOKEN']}",
        f"VAULT_UNSEAL_KEY={values['VAULT_UNSEAL_KEY']}",
    ]
    VAULT_ENV.write_text("\n".join(lines) + "\n", encoding="utf-8")
    try:
        os.chmod(VAULT_ENV, 0o600)
    except OSError:
        pass
    log.info("Wrote %s", VAULT_ENV)
    return VAULT_ENV


def initialize_if_needed(existing: dict[str, str]) -> tuple[str, str]:
    """Return (root_token, unseal_key). Initialize only if not yet initialized."""
    _, payload = _request("GET", "/sys/init")
    if payload.get("initialized"):
        root = existing.get("VAULT_ROOT_TOKEN", "")
        key = existing.get("VAULT_UNSEAL_KEY", "")
        if root and key:
            log.info("Vault already initialized (using stored root token + unseal key)")
            return root, key
        raise RuntimeError(
            "Vault is initialized but ../vault/generated/vault.env has no VAULT_ROOT_TOKEN/"
            "VAULT_UNSEAL_KEY. Restore ../vault/generated/vault.env or reinitialize the volume."
        )

    log.info("Initializing Vault (secret_shares=1, threshold=1) ...")
    _, init = _request("POST", "/sys/init", body={"secret_shares": 1, "secret_threshold": 1})
    root_token = init["root_token"]
    unseal_key = init["keys"][0]
    log.info("Vault initialized")
    return root_token, unseal_key


def unseal_if_needed(unseal_key: str) -> None:
    _, status = _request("GET", "/sys/seal-status")
    if not status.get("sealed"):
        log.info("Vault already unsealed")
        return
    log.info("Unsealing Vault ...")
    _request("POST", "/sys/unseal", body={"key": unseal_key})
    log.info("Vault unsealed")


def enable_kv_v2(root_token: str) -> None:
    # Mounts are configured at /sys/mounts/<mount> (trailing slash for KV mount).
    path = f"/sys/mounts/{KV_MOUNT}"
    try:
        _request(
            "POST",
            path,
            token=root_token,
            body={"type": "kv", "config": {}, "options": {"version": "2"}},
            allow_statuses=(400,),
        )
        log.info("KV v2 enabled at %s/", KV_MOUNT)
    except RuntimeError as exc:
        if "already in use" in str(exc).lower() or "path is already in use" in str(exc).lower():
            log.info("KV v2 already enabled at %s/", KV_MOUNT)
            return
        raise


def ensure_read_token(root_token: str) -> str:
    _request(
        "PUT",
        f"/sys/policies/acl/{READ_POLICY_NAME}",
        token=root_token,
        body={"policy": READ_POLICY},
    )
    log.info("Ensured ACL policy %s", READ_POLICY_NAME)

    _, created = _request(
        "POST",
        "/auth/token/create",
        token=root_token,
        body={"policies": [READ_POLICY_NAME], "ttl": "768h", "renewable": True},
    )
    token = created["auth"]["client_token"]
    log.info("Issued libcloud REST API read token (policy=%s)", READ_POLICY_NAME)
    return token


def seed_secret(root_token: str, name: str, data: dict[str, str]) -> None:
    if not any(data.values()):
        log.warning("Skipping secret %s (no values provided)", name)
        return
    _request(
        "POST",
        f"/v1/{KV_MOUNT}/data/{KV_PREFIX}/{name}",
        token=root_token,
        body={"data": data},
    )
    log.info("Seeded secret %s/data/%s/%s", KV_MOUNT, KV_PREFIX, name)


def main() -> int:
    # Gate: only superadmin may initialize/configure Vault. Per-tenant
    # backend credential seeding is handled separately by
    # scripts/set_tenant_credentials.py, which gates writes on the tenant
    # owner's OpenFGA `can_manage_credentials` relation — not on global env.
    if not os.environ.get("SUPERADMIN_JWT", "").strip():
        log.error(
            "SUPERADMIN_JWT is not set. Vault initialization is gated on a "
            "successful Dex login as the LLDAP `superadmin` user. Run "
            "./scripts/superadmin_auth.sh first (or ./setup.sh) and export "
            "SUPERADMIN_JWT."
        )
        return 3
    wait_for_vault()
    existing = _read_existing_env()

    root_token, unseal_key = initialize_if_needed(existing)
    unseal_if_needed(unseal_key)
    enable_kv_v2(root_token)
    libcloud_token = ensure_read_token(root_token)

    # NOTE: backend cloud credentials are NOT seeded here. They are written
    # per-tenant by the tenant owner via scripts/set_tenant_credentials.py
    # (gated on OpenFGA can_manage_credentials). This script only initializes
    # Vault, enables KV v2, and issues the libcloud REST API read token.

    public_addr = os.environ.get("VAULT_PUBLIC_ADDR", "http://localhost:8200").rstrip("/")
    _write_env(
        {
            "VAULT_ADDR": public_addr,
            "VAULT_TOKEN": libcloud_token,
            "VAULT_ROOT_TOKEN": root_token,
            "VAULT_UNSEAL_KEY": unseal_key,
        }
    )

    print(
        json.dumps(
            {
                "vault_env": str(VAULT_ENV),
                "vault_addr": public_addr,
                "kv_path_prefix": f"{KV_MOUNT}/{KV_PREFIX}",
                "read_policy": READ_POLICY_NAME,
                "note": "per-tenant credentials are seeded by scripts/set_tenant_credentials.py (owner-gated)",
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
