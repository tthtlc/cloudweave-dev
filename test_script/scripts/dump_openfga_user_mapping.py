#!/usr/bin/env python3
"""dump_openfga_user_mapping.py
===============================
Dump the login-user -> tenant -> vault_user mapping stored in OpenFGA.

Reads every relationship tuple from the OpenFGA store and prints three views:

  1. tenant -> vault_user  (the per-tenant Vault AppRole identity mapping)
  2. login user -> tenant  (owner/admin/viewer role bindings)
  3. resolved: login user -> tenant -> vault_user

Authn: OpenFGA runs with OIDC authn, so a bearer token is required. Supply one
via --bearer, FGA_API_TOKEN, or SUPERADMIN_JWT (a valid Dex token). Without one
the /read call returns 401 and the script prints a hint.

Defaults are loaded from openfga_postgres/generated/fga.env (FGA_API_URL /
FGA_STORE_ID); override with environment variables or --url/--store.

Usage:
    SUPERADMIN_JWT=... python3 test_script/scripts/dump_openfga_user_mapping.py
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
FGA_ENV = REPO_ROOT / "openfga_postgres" / "generated" / "fga.env"


def load_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.is_file():
        return env
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip()
    return env


def _request(
    method: str, url: str, bearer: str | None, body: dict | None = None
) -> tuple[int, dict]:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if bearer:
        req.add_header("Authorization", f"Bearer {bearer}")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            raw = resp.read().decode("utf-8") or "{}"
            return resp.status, json.loads(raw)
    except urllib.error.HTTPError as exc:
        return exc.code, {"error": exc.read().decode("utf-8", "replace")}
    except urllib.error.URLError as exc:
        print(f"ERROR: cannot reach OpenFGA at {url}: {exc.reason}", file=sys.stderr)
        sys.exit(2)


def read_all_tuples(base: str, store: str, bearer: str | None) -> list[dict[str, str]]:
    """Read every tuple in the store (paginated /read)."""
    out: list[dict[str, str]] = []
    token = ""
    while True:
        payload: dict = {"page_size": 100}
        if token:
            payload["continuation_token"] = token
        status, body = _request("POST", f"{base}/stores/{store}/read", bearer, payload)
        if status != 200:
            hint = body.get("error") or json.dumps(body)
            print(f"ERROR: OpenFGA /read failed (HTTP {status}): {hint}", file=sys.stderr)
            if status == 401:
                print(
                    "Hint: pass a Dex token via --bearer / FGA_API_TOKEN / SUPERADMIN_JWT.",
                    file=sys.stderr,
                )
            sys.exit(1)
        for t in body.get("tuples", []):
            k = t.get("key", {})
            out.append({
                "user": k.get("user", ""),
                "relation": k.get("relation", ""),
                "object": k.get("object", ""),
            })
        token = body.get("continuation_token") or ""
        if not token:
            break
    return out


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--bearer", default=None, help="OpenFGA bearer token (Dex JWT)")
    ap.add_argument("--url", default=None, help="OpenFGA base URL")
    ap.add_argument("--store", default=None, help="OpenFGA store id")
    args = ap.parse_args()

    env = load_env(FGA_ENV)
    base = (
        args.url or os.environ.get("FGA_API_URL") or env.get("FGA_API_URL")
        or "http://localhost:8080"
    ).rstrip("/")
    store = args.store or os.environ.get("FGA_STORE_ID") or env.get("FGA_STORE_ID") or ""
    bearer = (
        args.bearer or os.environ.get("FGA_API_TOKEN")
        or os.environ.get("SUPERADMIN_JWT") or None
    )

    if not store:
        print("ERROR: FGA_STORE_ID not found in fga.env / env. Run ./setup.sh first.", file=sys.stderr)
        return 1

    tuples = read_all_tuples(base, store, bearer)

    vault_map: list[tuple[str, str]] = []          # (tenant, vault_user)
    role_map: list[tuple[str, str, str]] = []      # (user, relation, tenant)
    for t in tuples:
        obj = t["object"]
        if obj.startswith("vault_user:"):
            vault_map.append((t["user"], obj))
        elif obj.startswith("tenant:") and t["relation"] in ("owner", "admin", "viewer"):
            role_map.append((t["user"], t["relation"], obj))

    print(f"OpenFGA: {base}  store={store}\n")

    print("== tenant -> vault_user (Vault AppRole identity mapping) ==")
    if vault_map:
        for user, obj in sorted(vault_map):
            print(f"  {user:<22} -> {obj}")
    else:
        print("  (none)")

    print("\n== login user -> tenant (role bindings) ==")
    if role_map:
        for user, rel, tenant in sorted(role_map):
            print(f"  {user:<22} {rel:<8} {tenant}")
    else:
        print("  (none)")

    tenant_to_vault = {u: o for u, o in vault_map}
    print("\n== resolved: login user -> tenant -> vault_user ==")
    if role_map:
        seen: set[tuple[str, str]] = set()
        for user, _rel, tenant in sorted(role_map):
            key = (user, tenant)
            if key in seen:
                continue
            seen.add(key)
            vu = tenant_to_vault.get(tenant, "(no vault_user)")
            print(f"  {user:<22} -> {tenant:<16} -> {vu}")
    else:
        print("  (none)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
