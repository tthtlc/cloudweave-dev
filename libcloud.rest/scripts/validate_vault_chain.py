#!/usr/bin/env python3
"""
validate_vault_chain.py
=======================
End-to-end validation that the libcloud REST API resolves its OWN backend
credentials from Vault (not from the client, not from plaintext env) and
constructs a real provider driver.

What this proves
----------------
The full server-side chain used on every backend call:

    build_driver(connection)
      -> effective_credentials(connection)            app/connections/credentials.py
           -> enforce_credential_policy(connection)   reject client-supplied creds
           -> resolve_server_credentials(connection)  Vault-first, env fallback
                -> VaultClient.read_secret(binding)   KV v2: secret/data/libcloud/<binding>
      -> create_aws_driver(key, secret, config)       app/providers/aws.py
      -> EC2NodeDriver constructed with Vault creds

By default it stands up a tiny in-process mock Vault KV v2 server, configures
the app to use it, blanks the env fallback, and asserts the constructed
driver's key equals the Vault secret. With --real it runs against a live Vault
at VAULT_ADDR/VAULT_TOKEN (read-only).

Exit code 0 = pass, 1 = fail.

Usage
-----
    # Mock (no Vault required):
    python3 scripts/validate_vault_chain.py

    # Real Vault (reads secret/data/libcloud/<binding>, e.g. aws):
    VAULT_ADDR=http://localhost:8200 VAULT_TOKEN=... python3 scripts/validate_vault_chain.py --real

Run from the libcloud.rest project root (so `app.*` imports resolve), ideally
with the venv active:  . .venv/bin/activate
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

# Make the project root importable when run as `python3 scripts/validate_vault_chain.py`.
_PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PROJECT_ROOT not in sys.path:
    sys.path.insert(0, _PROJECT_ROOT)

# --- mock Vault -------------------------------------------------------------

MOCK_KEY = "vaultkey"
MOCK_SECRET = "vaultsecret"


class _MockVaultHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        if not self.path.startswith("/v1/secret/data/libcloud/"):
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(
            json.dumps({"data": {"data": {"key": MOCK_KEY, "secret": MOCK_SECRET}}}).encode()
        )

    def log_message(self, *_args) -> None:  # silence
        return


def _start_mock_vault() -> tuple[str, HTTPServer]:
    srv = HTTPServer(("127.0.0.1", 0), _MockVaultHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{srv.server_address[1]}", srv


# --- validation -------------------------------------------------------------

def _configure_env(mock_addr: str | None) -> None:
    """Point the app at Vault (mock or real) and blank the env fallback."""
    if mock_addr:
        os.environ["VAULT_ADDR"] = mock_addr
        os.environ["VAULT_TOKEN"] = "mock-token"
    # Force the env fallback to be unusable so any resolved credential MUST
    # have come from Vault.
    os.environ["LIBCLOUD_AWS_PROD_KEY"] = ""
    os.environ["LIBCLOUD_AWS_PROD_SECRET"] = ""
    os.environ["LIBCLOUD_NTNX_LAB_USER"] = ""
    os.environ["LIBCLOUD_NTNX_LAB_PASSWORD"] = ""
    # Ensure client-supplied credentials stay rejected.
    os.environ.setdefault("ALLOW_CLIENT_CREDENTIALS", "false")


def _print_chain() -> None:
    print("Chain under test:")
    print("  build_driver(connection)")
    print("    -> effective_credentials(connection)")
    print("         -> enforce_credential_policy(connection)   # reject client creds")
    print("         -> resolve_server_credentials(connection)  # Vault-first")
    print("              -> VaultClient.read_secret(binding)    # KV v2 read")
    print("    -> create_aws_driver(key, secret, config)")
    print("    -> EC2NodeDriver")
    print()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("--real", action="store_true", help="Use live Vault at VAULT_ADDR/VAULT_TOKEN instead of a mock.")
    parser.add_argument("--binding", default="aws", help="auth_binding (tenant id) to resolve (default aws).")
    args = parser.parse_args()

    _print_chain()

    srv = None
    mock_addr = None
    if args.real:
        if not os.environ.get("VAULT_ADDR") or not os.environ.get("VAULT_TOKEN"):
            print("FAIL: --real requires VAULT_ADDR and VAULT_TOKEN in the environment.", file=sys.stderr)
            return 1
        print(f"Using LIVE Vault at {os.environ['VAULT_ADDR']} (binding={args.binding})")
        expected_key = None  # unknown; just assert non-empty
    else:
        mock_addr, srv = _start_mock_vault()
        print(f"Using MOCK Vault at {mock_addr} (binding={args.binding})")
        expected_key = MOCK_KEY

    _configure_env(mock_addr if not args.real else os.environ["VAULT_ADDR"])

    # Imports after env is set so Settings picks up VAULT_*/LIBCLOUD_* values.
    from app.config.settings import get_settings
    get_settings.cache_clear()

    from app.providers.factory import build_driver
    from app.connections.models import ProviderConnection, ConnectionConfig

    # Client sends NO credentials — only provider + region + auth_binding.
    conn = ProviderConnection(
        provider="aws",
        config=ConnectionConfig(region="us-east-1"),
        auth_binding=args.binding,
    )
    print(f"ProviderConnection: provider={conn.provider}, region={conn.config.region}, "
          f"auth_binding={conn.auth_binding}, credentials={conn.credentials}")

    driver = build_driver(conn)
    print(f"Constructed driver: {type(driver).__name__}")
    print(f"Resolved key: {driver.key!r}")

    if conn.credentials is not None:
        print("FAIL: test fixture accidentally carried client credentials.", file=sys.stderr)
        return 1
    if not driver.key:
        print("FAIL: driver has no resolved key (credentials not resolved).", file=sys.stderr)
        return 1
    if expected_key is not None and driver.key != expected_key:
        print(f"FAIL: expected key {expected_key!r} from Vault, got {driver.key!r}.", file=sys.stderr)
        return 1

    print("\nPASS: build_driver resolved backend credentials from Vault and constructed the driver.")
    if srv:
        srv.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
