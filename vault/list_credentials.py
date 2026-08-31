#!/usr/bin/env python3
"""List all credentials stored in the Vault KV v2 libcloud prefix.

Reads VAULT_ADDR and VAULT_ROOT_TOKEN (fallback VAULT_TOKEN) from
generated/vault.env by default (overridable by environment variables or CLI
flags). Lists every secret path under secret/metadata/libcloud/ and prints each
secret's keys (without values) plus metadata version/timestamps.

Usage:
    python3 list_credentials.py
    python3 list_credentials.py --addr http://localhost:8200 --token hvs...
    python3 list_credentials.py --show-values   # prints secret values too
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


def list_keys(addr: str, token: str, path: str) -> list[str]:
    """Recursively list KV v2 keys under a metadata path."""
    url = f"{addr}/v1/{KV_MOUNT}/metadata/{path}?list=true"
    status, data = request("LIST", url, token)
    if status == 404:
        return []
    if status != 200:
        return []
    keys = data.get("data", {}).get("keys", [])
    found: list[str] = []
    for k in keys:
        sub = f"{path}/{k}" if path else k
        if k.endswith("/"):
            found.extend(list_keys(addr, token, sub[:-1]))
        else:
            found.append(sub)
    return found


def read_secret(addr: str, token: str, name: str) -> dict | None:
    url = f"{addr}/v1/{KV_MOUNT}/data/{name}"
    status, data = request("GET", url, token)
    if status != 200:
        return None
    return data.get("data", {})


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--addr", default=os.environ.get("VAULT_ADDR"))
    ap.add_argument("--token", default=os.environ.get("VAULT_TOKEN"))
    ap.add_argument("--show-values", action="store_true", help="print secret values (sensitive!)")
    args = ap.parse_args()

    env = load_env(GENERATED_ENV)
    addr = args.addr or env.get("VAULT_ADDR") or os.environ.get("VAULT_ADDR")
    # Reads need a token that can read secret/data/libcloud/*; the orchestrator
    # VAULT_TOKEN can only read the AppRole auth material, so prefer the root
    # token (like add/delete_credential.py do).
    token = (args.token or env.get("VAULT_ROOT_TOKEN")
             or env.get("VAULT_TOKEN") or os.environ.get("VAULT_TOKEN"))
    if not addr or not token:
        print("ERROR: VAULT_ADDR/VAULT_TOKEN not found in generated/vault.env or env.", file=sys.stderr)
        return 1

    print(f"Vault: {addr}")
    print(f"KV v2 mount: {KV_MOUNT}/   prefix: {KV_PREFIX}/\n")

    # list_keys returns paths relative to the KV mount (already include the
    # KV_PREFIX), so do not re-prepend the prefix here.
    paths = list_keys(addr, token, KV_PREFIX)
    if not paths:
        print("No credentials found.")
        return 0

    for full in sorted(paths):
        print(f"== {KV_MOUNT}/{full} ==")
        secret = read_secret(addr, token, full)
        if secret is None:
            print("  (could not read)\n")
            continue
        metadata = secret.get("metadata", {})
        data = secret.get("data", {})
        print(f"  current_version: {metadata.get('current_version')}")
        print(f"  created_time:    {metadata.get('created_time')}")
        print(f"  updated_time:    {metadata.get('updated_time')}")
        print(f"  keys ({len(data)}): {', '.join(sorted(data))}")
        if args.show_values:
            for k in sorted(data):
                print(f"    {k} = {data[k]}")
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
