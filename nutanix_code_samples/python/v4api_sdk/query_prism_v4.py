#!/usr/bin/env python3
"""
Query the local Nutanix v4 mock "Prism Central" emulators, one per minor
version, from the host.  Each minor version of the v4 API is served by its own
stateful emulator on a dedicated port (see `docker ps` / stoplight_mock):

    v4.0  ->  https://localhost:9440   (schema mock: http://localhost:4010)
    v4.1  ->  https://localhost:9441   (schema mock: http://localhost:4011)
    v4.2  ->  https://localhost:9442   (schema mock: http://localhost:4012)
    v4.3  ->  https://localhost:9443   (schema mock: http://localhost:4013)

The emulator speaks HTTPS with a self-signed certificate, so TLS verification
is disabled here (same as `verify_ssl = False` in the SDK samples).

Stdlib only — no pip/uv dependencies required.

Usage:
    python3 query_prism_v4.py                 # probe all four versions
    python3 query_prism_v4.py --version v4.3  # probe one version
    python3 query_prism_v4.py --version 4.2   # minor token also accepted
"""

import argparse
import json
import ssl
import sys
import urllib.request
import urllib.error

# Version -> (emulator port, prism schema-mock port)
VERSIONS = {
    "v4.0": (9440, 4010),
    "v4.1": (9441, 4011),
    "v4.2": (9442, 4012),
    "v4.3": (9443, 4013),
}

# Read-only list endpoints, keyed by a friendly name.  The `{v}` placeholder is
# replaced with the API version (e.g. v4.3) so the path matches the emulator's
# served spec.
ENDPOINTS = [
    ("VMs", "/api/vmm/{v}/ahv/config/vms"),
    ("Images", "/api/vmm/{v}/content/images"),
    ("Subnets", "/api/networking/{v}/config/subnets"),
    ("Clusters", "/api/clustermgmt/{v}/config/clusters"),
    ("Tasks", "/api/prism/{v}/config/tasks"),
]

_CTX = ssl.create_default_context()
_CTX.check_hostname = False
_CTX.verify_mode = ssl.CERT_NONE


def get_json(base_url: str, path: str):
    """GET `base_url + path`, return (status, parsed_json_or_None)."""
    url = base_url + path
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10, context=_CTX) as resp:
            body = resp.read().decode("utf-8")
            return resp.status, json.loads(body) if body else None
    except urllib.error.HTTPError as exc:
        return exc.code, None
    except urllib.error.URLError as exc:
        return 0, {"error": str(exc.reason)}


def total(results) -> str:
    """Pull `metadata.totalAvailableResults` out of a v4 list response."""
    if isinstance(results, dict):
        metadata = results.get("metadata") or {}
        if "totalAvailableResults" in metadata:
            return str(metadata["totalAvailableResults"])
    return "-"


def probe(version: str):
    port, prism_port = VERSIONS[version]
    base = f"https://localhost:{port}"
    print(f"\n{'=' * 62}")
    print(f"  {version}   emulator https://localhost:{port}   (schema mock http://localhost:{prism_port})")
    print(f"{'=' * 62}")

    status, health = get_json(base, "/health")
    print(f"  /health                                   -> {status}")
    if isinstance(health, dict):
        print(f"     vms={health.get('vms')}  subnets={health.get('subnets')}  "
              f"tasks={health.get('tasks')}")

    for name, path in ENDPOINTS:
        url_path = path.format(v=version)
        status, data = get_json(base, url_path)
        count = total(data)
        print(f"  GET {url_path:<48} -> {status}  (results: {count})")


def main():
    parser = argparse.ArgumentParser(description="Query the Nutanix v4 mock emulators.")
    parser.add_argument(
        "--version", "-V",
        help="API version to query: v4.0, v4.1, v4.2, v4.3 (default: all)",
    )
    args = parser.parse_args()

    if args.version:
        token = args.version if args.version.startswith("v") else f"v{args.version}"
        if token not in VERSIONS:
            print(f"Unsupported version '{args.version}'. Supported: {', '.join(VERSIONS)}")
            sys.exit(2)
        probe(token)
    else:
        for version in VERSIONS:
            probe(version)
    print()


if __name__ == "__main__":
    main()
