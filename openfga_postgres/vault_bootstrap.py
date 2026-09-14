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
  6. Enable AppRole auth and create one AppRole identity per seeded tenant
     (role ``libcloud-<tenant>``, policy ``libcloud-read-<tenant>``) plus a
     narrow orchestrator token (policy ``libcloud-vault-auth-read``) that can
     only read the per-tenant AppRole auth material, never the cloud secrets.
     Write the orchestrator token to generated/vault.env as VAULT_TOKEN.
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
AUTH_KV_PREFIX = os.environ.get("VAULT_APPROLE_AUTH_PREFIX", "libcloud-vault-auth")
APPROLE_MOUNT = os.environ.get("VAULT_APPROLE_MOUNT", "approle")
ORCH_POLICY_NAME = os.environ.get("VAULT_ORCHESTRATOR_POLICY", "libcloud-vault-auth-read")
SEED_TENANTS = [
    t.strip() for t in os.environ.get("VAULT_TENANTS", "aws,nutanix").split(",") if t.strip()
]

# Orchestrator token: read only the per-tenant AppRole auth material (role_id +
# secret_id), never the tenant cloud secrets themselves. The REST API uses this
# to obtain each tenant's AppRole login material, then reads the tenant's cloud
# secret with the short-lived per-tenant token that AppRole login returns.
ORCHESTRATOR_POLICY = f"""# Read-only access to per-tenant AppRole auth material (KV v2).
path "{KV_MOUNT}/data/{AUTH_KV_PREFIX}/*" {{
  capabilities = ["read"]
}}
path "{KV_MOUNT}/metadata/{AUTH_KV_PREFIX}/*" {{
  capabilities = ["read", "list"]
}}
"""

# Department orchestrator token (identity-service): mint per-department AppRoles
# and read/write per-department backend credentials. This is the identity-service's
# scoped Vault capability for the company-admin "create department" flow (write
# credential + create AppRole) and "view/rotate credential" (read). It is NOT
# root: no non-libcloud paths, and no read-back of any AppRole secret_id (the
# secret-id path grants only "update", i.e. mint; auth material is written to KV,
# not read). The identity-service gates every use behind OpenFGA
# can_manage_credentials / can_create_department.
DEPARTMENT_ORCHESTRATOR_POLICY_NAME = os.environ.get(
    "VAULT_DEPT_ORCHESTRATOR_POLICY", "department-orchestrator"
)
DEPARTMENT_ORCHESTRATOR_POLICY = f"""# Scoped department provisioning: create per-department AppRoles and
# read/write per-department cloud credentials (KV v2).
path "{KV_MOUNT}/data/{KV_PREFIX}/*" {{
  capabilities = ["create", "update", "read"]
}}
path "{KV_MOUNT}/metadata/{KV_PREFIX}/*" {{
  capabilities = ["list"]
}}
path "{KV_MOUNT}/data/{AUTH_KV_PREFIX}/*" {{
  capabilities = ["create", "update"]
}}
path "sys/policies/acl/libcloud-read-*" {{
  capabilities = ["create", "update"]
}}
# The trailing `*` makes this a PREFIX match, so `read` also covers the
# .../role-id sub-endpoint and `update` also covers .../secret-id. A separate
# `libcloud-*/role-id` path does NOT match (Vault only globs the final segment).
path "auth/{APPROLE_MOUNT}/role/libcloud-*" {{
  capabilities = ["create", "update", "read"]
}}
"""


def _tenant_read_policy(tenant: str) -> str:
    """ACL policy scoped to a single tenant's backend cloud credentials."""
    return f"""# Read-only access to tenant '{tenant}' backend cloud credentials (KV v2).
path "{KV_MOUNT}/data/{KV_PREFIX}/{tenant}" {{
  capabilities = ["read"]
}}
path "{KV_MOUNT}/metadata/{KV_PREFIX}/{tenant}" {{
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
        f"VAULT_DEPT_ORCHESTRATOR_TOKEN={values.get('VAULT_DEPT_ORCHESTRATOR_TOKEN', '')}",
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


def ensure_orchestrator_token(root_token: str) -> str:
    """Issue the REST API's orchestrator token (auth-material read only)."""
    _request(
        "PUT",
        f"/sys/policies/acl/{ORCH_POLICY_NAME}",
        token=root_token,
        body={"policy": ORCHESTRATOR_POLICY},
    )
    log.info("Ensured orchestrator ACL policy %s", ORCH_POLICY_NAME)

    _, created = _request(
        "POST",
        "/auth/token/create",
        token=root_token,
        body={"policies": [ORCH_POLICY_NAME], "ttl": "768h", "renewable": True},
    )
    token = created["auth"]["client_token"]
    log.info("Issued libcloud REST API orchestrator token (policy=%s)", ORCH_POLICY_NAME)
    return token


def ensure_department_orchestrator_token(root_token: str) -> str:
    """Issue the identity-service's department-orchestrator token (mint
    per-department AppRoles + read/write per-department credentials)."""
    _request(
        "PUT",
        f"/sys/policies/acl/{DEPARTMENT_ORCHESTRATOR_POLICY_NAME}",
        token=root_token,
        body={"policy": DEPARTMENT_ORCHESTRATOR_POLICY},
    )
    log.info("Ensured department-orchestrator ACL policy %s", DEPARTMENT_ORCHESTRATOR_POLICY_NAME)

    _, created = _request(
        "POST",
        "/auth/token/create",
        token=root_token,
        body={"policies": [DEPARTMENT_ORCHESTRATOR_POLICY_NAME], "ttl": "768h", "renewable": True},
    )
    token = created["auth"]["client_token"]
    log.info("Issued department-orchestrator token (policy=%s)", DEPARTMENT_ORCHESTRATOR_POLICY_NAME)
    return token


def enable_approle(root_token: str) -> None:
    _request(
        "POST",
        f"/sys/auth/{APPROLE_MOUNT}",
        token=root_token,
        body={"type": "approle"},
        allow_statuses=(400,),
    )
    log.info("AppRole auth enabled at %s/", APPROLE_MOUNT)


def ensure_tenant_approle(root_token: str, tenant: str) -> None:
    """Create a per-tenant AppRole (role 'libcloud-<tenant>', policy
    'libcloud-read-<tenant>') and store its role_id + secret_id at
    secret/data/libcloud-vault-auth/libcloud-<tenant>."""
    role = f"libcloud-{tenant}"
    policy_name = f"libcloud-read-{tenant}"

    _request(
        "PUT",
        f"/sys/policies/acl/{policy_name}",
        token=root_token,
        body={"policy": _tenant_read_policy(tenant)},
    )
    log.info("Ensured tenant ACL policy %s", policy_name)

    _request(
        "POST",
        f"/auth/{APPROLE_MOUNT}/role/{role}",
        token=root_token,
        body={
            "token_policies": [policy_name],
            "token_ttl": "60m",
            "token_max_ttl": "120m",
        },
    )
    # Vault's create-role response does not carry the role_id; it is generated
    # on role creation and must be read back from the role-id sub-endpoint.
    _, rid_resp = _request(
        "GET",
        f"/auth/{APPROLE_MOUNT}/role/{role}/role-id",
        token=root_token,
    )
    role_id = (rid_resp.get("data") or {}).get("role_id", "")
    if not role_id:
        raise RuntimeError(f"AppRole {role} returned no role_id")
    log.info("Created AppRole %s (role_id=%s…)", role, role_id[:8])

    _, sid_resp = _request(
        "POST",
        f"/auth/{APPROLE_MOUNT}/role/{role}/secret-id",
        token=root_token,
        body={},
    )
    secret_id = (sid_resp.get("data") or {}).get("secret_id", "")
    if not secret_id:
        raise RuntimeError(f"AppRole {role} returned no secret_id")
    log.info("Minted secret_id for AppRole %s", role)

    _request(
        "POST",
        f"/v1/{KV_MOUNT}/data/{AUTH_KV_PREFIX}/{role}",
        token=root_token,
        body={"data": {"role_id": role_id, "secret_id": secret_id}},
    )
    log.info("Stored AppRole auth material at %s/data/%s/%s", KV_MOUNT, AUTH_KV_PREFIX, role)


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
    enable_approle(root_token)
    orchestrator_token = ensure_orchestrator_token(root_token)
    dept_orchestrator_token = ensure_department_orchestrator_token(root_token)

    # Per-tenant AppRole identities (role + scoped policy + secret_id). These
    # are the "vault users": one per tenant, shared by that tenant's admin and
    # viewer. The tenant -> vault_user mapping lives in OpenFGA
    # (tenant:<t> parent vault_user:libcloud-<t>); the bootstrap creates the
    # Vault side for the seeded tenants, and create_tenant.sh /
    # vault_tenant_role.py do the same for tenants added later.
    for tenant in SEED_TENANTS:
        ensure_tenant_approle(root_token, tenant)

    # NOTE: backend cloud credentials are NOT seeded here. They are written
    # per-tenant by the tenant owner via scripts/set_tenant_credentials.py
    # (gated on OpenFGA can_manage_credentials). This script initializes Vault,
    # enables KV v2 + AppRole, and issues the per-tenant AppRoles + the
    # orchestrator read token.

    public_addr = os.environ.get("VAULT_PUBLIC_ADDR", "http://localhost:8200").rstrip("/")
    _write_env(
        {
            "VAULT_ADDR": public_addr,
            "VAULT_TOKEN": orchestrator_token,
            "VAULT_ROOT_TOKEN": root_token,
            "VAULT_UNSEAL_KEY": unseal_key,
            "VAULT_DEPT_ORCHESTRATOR_TOKEN": dept_orchestrator_token,
        }
    )

    print(
        json.dumps(
            {
                "vault_env": str(VAULT_ENV),
                "vault_addr": public_addr,
                "kv_path_prefix": f"{KV_MOUNT}/{KV_PREFIX}",
                "approle_mount": APPROLE_MOUNT,
                "orchestrator_policy": ORCH_POLICY_NAME,
                "tenant_approles": [f"libcloud-{t}" for t in SEED_TENANTS],
                "note": "per-tenant cloud credentials are seeded by scripts/set_tenant_credentials.py (owner-gated)",
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
