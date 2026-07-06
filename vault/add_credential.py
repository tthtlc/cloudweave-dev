#!/usr/bin/env python3
"""Add (or overwrite) a credential in the Vault KV v2 libcloud store.

Writes a new secret at secret/data/libcloud/<name>. KV v2 is append-only,
so re-adding an existing name creates a new version (safe update).

Credentials can be supplied three ways (in priority order):
  1. --kv KEY=VALUE ...        (repeatable; highest priority)
  2. --from-env VAR1 VAR2 ...  (reads values from environment variables)
  3. interactive prompt        (default; reads each key silently)

Usage:
    python3 add_credential.py aws-staging --kv key=AKIA... --kv secret=...
    python3 add_credential.py aws-staging --from-env LIBCLOUD_AWS_KEY LIBCLOUD_AWS_SECRET
    python3 add_credential.py gcp-prod           # prompts for key/value pairs
"""
from __future__ import annotations

import argparse
import getpass
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


def put_secret(addr: str, token: str, name: str, data: dict[str, str]) -> int:
    url = f"{addr}/v1/{KV_MOUNT}/data/{KV_PREFIX}/{name}"
    body = json.dumps({"data": data}).encode()
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("X-Vault-Token", token)
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
    ap.add_argument("name", help="credential name (stored at secret/libcloud/<name>)")
    ap.add_argument("--addr", default=os.environ.get("VAULT_ADDR"))
    ap.add_argument("--token", default=os.environ.get("VAULT_TOKEN"))
    ap.add_argument("--kv", action="append", default=[], metavar="KEY=VALUE",
                    help="key/value pair (repeatable)")
    ap.add_argument("--from-env", nargs="+", default=[], metavar="VAR",
                    help="read values from the named environment variables (key = var name lowercased)")
    args = ap.parse_args()

    env = load_env(GENERATED_ENV)
    addr = args.addr or env.get("VAULT_ADDR") or os.environ.get("VAULT_ADDR")
    # Writes require root; prefer VAULT_ROOT_TOKEN, fall back to VAULT_TOKEN.
    token = (args.token or env.get("VAULT_ROOT_TOKEN")
             or env.get("VAULT_TOKEN") or os.environ.get("VAULT_TOKEN"))
    if not addr or not token:
        print("ERROR: VAULT_ADDR/VAULT_TOKEN not found in generated/vault.env or env.", file=sys.stderr)
        return 1

    data: dict[str, str] = {}
    for pair in args.kv:
        if "=" not in pair:
            print(f"ERROR: --kv expects KEY=VALUE, got: {pair}", file=sys.stderr)
            return 1
        k, v = pair.split("=", 1)
        data[k.strip()] = v

    for var in args.from_env:
        if var not in os.environ:
            print(f"ERROR: environment variable {var} is not set", file=sys.stderr)
            return 1
        data[var.lower()] = os.environ[var]

    if not data:
        print(f"Adding secret/{KV_PREFIX}/{args.name} interactively. "
              "Press Enter on an empty key to finish.")
        while True:
            k = input("  key (blank to finish): ").strip()
            if not k:
                break
            v = getpass.getpass(f"  value for {k}: ")
            data[k] = v

    if not data:
        print("ERROR: no key/value pairs provided.", file=sys.stderr)
        return 1

    status = put_secret(addr, token, args.name, data)
    if status in (200, 204):
        full = f"{KV_MOUNT}/{KV_PREFIX}/{args.name}"
        print(f"OK: wrote {len(data)} key(s) to {full}: {', '.join(sorted(data))}")
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
