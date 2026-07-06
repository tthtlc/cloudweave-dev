#!/usr/bin/env python3
"""Delete a credential (and all its versions) from the Vault KV v2 libcloud store.

Permanently removes the secret at secret/metadata/libcloud/<name> and all
of its data. This is irreversible. Use --destroy-versions instead to only
destroy the current version's data while keeping metadata (KV v2 metadata
is preserved for audit).

Usage:
    python3 delete_credential.py aws-staging
    python3 delete_credential.py aws-staging --yes          # skip confirmation
    python3 delete_credential.py aws-staging --destroy-versions
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
KV_MOUNT = os.environ.get("VAULT_KV_MOUNT", "secret")
KV_PREFIX = os.environ.get("VAULT_KV_PREFIX", "libcloud")


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


def call(method: str, url: str, token: str, body: dict | None = None) -> int:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("X-Vault-Token", token)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
            return resp.status
    except urllib.error.HTTPError as exc:
        print(f"ERROR: HTTP {exc.code}: {exc.read().decode(errors='replace')}", file=sys.stderr)
        return exc.code
    except urllib.error.URLError as exc:
        print(f"ERROR: cannot reach Vault at {url}: {exc.reason}", file=sys.stderr)
        return 2


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("name", help="credential name (at secret/libcloud/<name>)")
    ap.add_argument("--addr", default=os.environ.get("VAULT_ADDR"))
    ap.add_argument("--token", default=os.environ.get("VAULT_TOKEN"))
    ap.add_argument("--yes", "-y", action="store_true", help="skip confirmation prompt")
    ap.add_argument("--destroy-versions", action="store_true",
                    help="only destroy current version data; keep metadata")
    args = ap.parse_args()

    env = load_env(GENERATED_ENV)
    addr = args.addr or env.get("VAULT_ADDR") or os.environ.get("VAULT_ADDR")
    # Deletes require root; prefer VAULT_ROOT_TOKEN, fall back to VAULT_TOKEN.
    token = (args.token or env.get("VAULT_ROOT_TOKEN")
             or env.get("VAULT_TOKEN") or os.environ.get("VAULT_TOKEN"))
    if not addr or not token:
        print("ERROR: VAULT_ADDR/VAULT_TOKEN not found in generated/vault.env or env.", file=sys.stderr)
        return 1

    full = f"{KV_MOUNT}/{KV_PREFIX}/{args.name}"
    action = "destroy versions of" if args.destroy_versions else "permanently delete"

    if not args.yes:
        confirm = input(f"Really {action} secret/{full}? [type the name to confirm]: ").strip()
        if confirm != args.name:
            print("Aborted (name did not match).")
            return 1

    if args.destroy_versions:
        # Destroy all versions of the latest data record.
        url = f"{addr}/v1/{KV_MOUNT}/data/{KV_PREFIX}/{args.name}"
        status = call("DELETE", url, token)
        if status in (200, 204):
            print(f"OK: destroyed current version data of {full} (metadata kept).")
            return 0
        return 1

    # Full delete: remove metadata and all versions.
    url = f"{addr}/v1/{KV_MOUNT}/metadata/{KV_PREFIX}/{args.name}"
    status = call("DELETE", url, token)
    if status in (200, 204):
        print(f"OK: deleted {full} and all its versions.")
        return 0
    if status == 404:
        print(f"NOT FOUND: {full} does not exist.")
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
