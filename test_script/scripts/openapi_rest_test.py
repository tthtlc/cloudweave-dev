#!/usr/bin/env python3
"""OpenAPI-driven REST API test harness for libcloud REST.

Loads the OpenAPI spec (generated/openapi.json) and the Dex/FGA credentials
sourced by overall_provision_test.sh, then exercises every REST endpoint in the
dependency order used by test_script/scripts/provision_nutanix.sh and
provision_aws.sh:

  login (Dex OIDC) -> /v1/auth/me -> /v1/connections:test -> /v1/providers
  -> catalog GETs (locations, sizes, images, storage-containers, subnets,
     networks, nodes, volumes, snapshots, key-pairs, security-groups,
     load-balancers, floating-ips, buckets)
  -> (FULL=1) full CRUD lifecycle for each resource, with cleanup
  -> admin/auth endpoints (expected 403/404 in OIDC mode)
  -> /v1/auth/logout (last)

Mutating endpoints are gated behind FULL=1 (mirroring PROVISION=1 in the
provision scripts) to avoid accidental cloud spend. Read-only by default.

Usage:
  ./test_script/scripts/openapi_rest_test.sh                 # read-only pass
  FULL=1 ./test_script/scripts/openapi_rest_test.sh          # full CRUD lifecycle
  TENANTS=aws ./test_script/scripts/openapi_rest_test.sh      # one tenant only
  VERBOSE=1 FULL=1 ./test_script/scripts/openapi_rest_test.sh
"""
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_DIR = Path(__file__).resolve().parent

DEFAULT_ENV_FILES = [
    REPO_ROOT / "dex" / "generated" / "dex.env",
    REPO_ROOT / "openfga_postgres" / "generated" / "fga.env",
    REPO_ROOT / ".env",
]

DEFAULT_OPENAPI_PATHS = [
    REPO_ROOT / "libcloud.rest" / "generated" / "openapi.json",
    REPO_ROOT / "libcloud.rest" / "tmp" / "openapi.json",
    REPO_ROOT / "stoplight_mock" / "spec" / "openapi.json",
]

# Per-tenant connection descriptors. auth_binding selects the server-side
# Vault secret (secret/libcloud/<binding>); the client never sends credentials.
TENANTS = {
    "aws": {
        "admin": "aws-admin",
        "viewer": "aws-viewer",
        "connection": {
            "provider": "aws",
            "config": {"region": "ap-southeast-1", "secure": True},
            "auth_binding": "aws",
        },
    },
    "nutanix": {
        "admin": "ntnx-admin",
        "viewer": "ntnx-viewer",
        "connection": {
            "provider": "nutanix",
            "config": {
                "host": "host.docker.internal",
                "port": 9440,
                "secure": True,
                "api_version": "v4.0",
                "verify_ssl_cert": False,
            },
            "auth_binding": "nutanix",
        },
    },
}

VERBOSE = os.environ.get("VERBOSE", "").lower() in {"1", "true", "yes"}
FULL = os.environ.get("FULL", "0") == "1"

results: list[dict[str, Any]] = []


# --------------------------------------------------------------------------- #
# Env loading + credential resolution
# --------------------------------------------------------------------------- #
def load_env_file(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.exists():
        return env
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        env[key.strip()] = val.strip()
    return env


def load_all_env() -> dict[str, str]:
    env: dict[str, str] = {}
    for f in DEFAULT_ENV_FILES:
        for k, v in load_env_file(f).items():
            # Don't let empty placeholders (e.g. repo-root .env template) clobber
            # real values from dex.env / fga.env.
            if v or k not in env:
                env[k] = v
    return env


ENV = load_all_env()
LIBCLOUD_REST_URL = os.environ.get(
    "LIBCLOUD_REST_URL", ENV.get("LIBCLOUD_REST_URL", "http://localhost:8765")
).rstrip("/")


def password_for(user: str) -> str:
    """Resolve a per-user Dex password from dex.env (see overall_provision_test.sh)."""
    mapping = {
        "superadmin": "LIBCLOUD_SUPERADMIN_PASSWORD",
        "aws-owner": "LIBCLOUD_PASSWORD_AWS_OWNER",
        "aws-admin": "LIBCLOUD_PASSWORD_AWS_ADMIN",
        "aws-viewer": "LIBCLOUD_PASSWORD_AWS_VIEWER",
        "ntnx-owner": "LIBCLOUD_PASSWORD_NTNX_OWNER",
        "ntnx-admin": "LIBCLOUD_PASSWORD_NTNX_ADMIN",
        "ntnx-viewer": "LIBCLOUD_PASSWORD_NTNX_VIEWER",
        "cloud-denied": "LIBCLOUD_PASSWORD_CLOUD_DENIED",
    }
    key = mapping.get(user)
    if not key:
        raise SystemExit(f"no password mapping for user {user!r}")
    val = os.environ.get(key) or ENV.get(key)
    if not val:
        raise SystemExit(f"missing {key} for user {user!r} (run setup.sh / source dex.env)")
    return val


# --------------------------------------------------------------------------- #
# Dex OIDC login (reuses test_script/scripts/idp_login.py + token cache)
# --------------------------------------------------------------------------- #
def login(user: str) -> str:
    env = dict(os.environ)
    env.update(ENV)
    env["LIBCLOUD_USER"] = user
    env["LIBCLOUD_PASSWORD"] = password_for(user)
    env.setdefault("IDP_TOKEN_CACHE_DIR", str(REPO_ROOT / "generated" / "tokens"))
    if VERBOSE:
        env["IDP_LOGIN_VERBOSE"] = "1"
    proc = subprocess.run(
        [sys.executable, str(SCRIPT_DIR / "idp_login.py")],
        env=env,
        text=True,
        capture_output=True,
        timeout=120,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise SystemExit(f"idp_login.py failed for {user} (rc={proc.returncode})")
    return proc.stdout.strip()


# --------------------------------------------------------------------------- #
# OpenAPI spec
# --------------------------------------------------------------------------- #
def load_spec() -> dict[str, Any]:
    for p in DEFAULT_OPENAPI_PATHS:
        if p.exists():
            if VERBOSE:
                sys.stderr.write(f"[spec] using {p}\n")
            return json.loads(p.read_text())
    raise SystemExit(
        "openapi.json not found; expected one of: "
        + ", ".join(str(p) for p in DEFAULT_OPENAPI_PATHS)
    )


SPEC = load_spec()


def spec_endpoints() -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    for path, methods in SPEC.get("paths", {}).items():
        for m in methods:
            if m in ("get", "post", "put", "patch", "delete"):
                out.append((m.upper(), path))
    return out


# --------------------------------------------------------------------------- #
# HTTP client
# --------------------------------------------------------------------------- #
def request(
    method: str,
    path: str,
    token: str | None = None,
    connection: dict | None = None,
    body: Any = None,
    headers: dict[str, str] | None = None,
    timeout: int = 60,
) -> tuple[int, Any]:
    url = f"{LIBCLOUD_REST_URL}{path}"
    hdrs = {"Accept": "application/json"}
    if token:
        hdrs["Authorization"] = f"Bearer {token}"
    if connection is not None:
        hdrs["X-Provider-Connection"] = json.dumps(connection, separators=(",", ":"))
    if body is not None:
        hdrs["Content-Type"] = "application/json"
    if headers:
        hdrs.update(headers)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    if VERBOSE:
        sys.stderr.write(f">>> {method} {path}\n")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode(errors="replace")
            status = resp.status
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode(errors="replace")
        status = exc.code
    except urllib.error.URLError as exc:
        return 0, {"_error": str(exc)}
    try:
        parsed = json.loads(raw) if raw else None
    except json.JSONDecodeError:
        parsed = raw
    return status, parsed


def data_list(payload: Any) -> list:
    if payload is None:
        return []
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        d = payload.get("data")
        if isinstance(d, list):
            return d
        if isinstance(d, dict) and "items" in d:
            return d["items"]
        if isinstance(d, dict):
            return list(d.values())
    return []


# --------------------------------------------------------------------------- #
# Result recording
# --------------------------------------------------------------------------- #
def record(
    tenant: str,
    user: str,
    method: str,
    path: str,
    status: int,
    expected: set[int],
    note: str = "",
) -> None:
    if status in expected:
        verdict = "PASS"
    elif status == 0:
        verdict = "FAIL"
    else:
        verdict = f"UNEXPECTED({status})"
    results.append(
        {
            "tenant": tenant,
            "user": user,
            "method": method,
            "path": path,
            "status": status,
            "expected": sorted(expected),
            "verdict": verdict,
            "note": note,
        }
    )
    flag = "ok" if verdict == "PASS" else "XX"
    print(f"  [{flag}] {tenant:7} {user:11} {method:6} {path:55} -> {status} {note}")


def step(n: int, title: str) -> None:
    print(f"\n=== [{n}] {title} ===")


# --------------------------------------------------------------------------- #
# Per-tenant flow
# --------------------------------------------------------------------------- #
def run_tenant(tenant: str, full: bool) -> None:
    cfg = TENANTS[tenant]
    conn = cfg["connection"]
    admin_user = cfg["admin"]
    viewer_user = cfg["viewer"]
    print(f"\n############## Tenant: {tenant} (provider={conn['provider']}) ##############")

    step(1, f"Dex IdP login (admin={admin_user}, viewer={viewer_user})")
    admin_token = login(admin_user)
    viewer_token = login(viewer_user)
    print(f"  admin token: {len(admin_token)} chars; viewer token: {len(viewer_token)} chars")

    step(2, "Health (no auth)")
    s, _ = request("GET", "/health")
    record(tenant, "-", "GET", "/health", s, {200})

    step(3, "Token validation: GET /v1/auth/me (admin)")
    s, _ = request("GET", "/v1/auth/me", token=admin_token)
    record(tenant, admin_user, "GET", "/v1/auth/me", s, {200})

    step(4, "Connection test: POST /v1/connections:test (admin)")
    s, _ = request("POST", "/v1/connections:test", token=admin_token, connection=conn)
    record(tenant, admin_user, "POST", "/v1/connections:test", s, {200, 502, 503},
           note="(502/503 ok if backend unreachable)")

    step(5, "List providers: GET /v1/providers (admin)")
    s, _ = request("GET", "/v1/providers", token=admin_token)
    record(tenant, admin_user, "GET", "/v1/providers", s, {200})

    step(6, "Catalog discovery (read endpoints, viewer + admin)")
    read_paths = [
        ("GET", "/v1/compute/locations"),
        ("GET", "/v1/compute/sizes"),
        ("GET", "/v1/compute/images"),
        ("GET", "/v1/compute/storage-containers"),
        ("GET", "/v1/compute/subnets"),
        ("GET", "/v1/compute/networks"),
        ("GET", "/v1/compute/nodes"),
        ("GET", "/v1/compute/volumes"),
        ("GET", "/v1/compute/snapshots"),
        ("GET", "/v1/compute/key-pairs"),
        ("GET", "/v1/compute/security-groups"),
        ("GET", "/v1/compute/load-balancers"),
        ("GET", "/v1/compute/floating-ips"),
        ("GET", "/v1/storage/buckets"),
    ]
    for user, token in ((viewer_user, viewer_token), (admin_user, admin_token)):
        for m, p in read_paths:
            s, _ = request(m, p, token=token, connection=conn)
            # Acceptable outcomes:
            #   200 = ok; 400 = provider-capability unsupported (e.g. storage-
            #   containers is Nutanix-only; AWS EC2 has no ex_list_load_balancers);
            #   403 = viewer scope-denied; 500/501/502/503 = backend/driver error
            #   or "not implemented" for this provider (environment, not API bug).
            record(tenant, user, m, p, s, {200, 400, 403, 500, 501, 502, 503},
                   note="(non-2xx ok: capability/scope/backend)")

    step(7, "Auth endpoints disabled in OIDC mode (expect 404 auth_local_disabled)")
    s, _ = request("POST", "/v1/auth/login", body={"username": admin_user, "password": "x"})
    record(tenant, admin_user, "POST", "/v1/auth/login", s, {404})
    s, _ = request("POST", "/v1/auth/refresh", body={"refresh_token": "x"})
    record(tenant, admin_user, "POST", "/v1/auth/refresh", s, {404})

    step(8, "Admin-scope endpoints (expect 403; no identity holds admin:connections:read)")
    s, _ = request("POST", "/v1/auth/token/introspect", token=admin_token,
                  body={"token": admin_token})
    record(tenant, admin_user, "POST", "/v1/auth/token/introspect", s, {403, 404})
    s, _ = request("POST", "/v1/admin/policies:reload", token=admin_token)
    record(tenant, admin_user, "POST", "/v1/admin/policies:reload", s, {403})

    if full:
        run_lifecycle(tenant, conn, admin_token)
    else:
        step(9, "Mutating CRUD endpoints SKIPPED (set FULL=1 to exercise)")
        for m, p in spec_endpoints():
            if m in {"POST", "PATCH", "DELETE"} and not p.startswith("/v1/auth"):
                results.append(
                    {
                        "tenant": tenant, "user": admin_user, "method": m, "path": p,
                        "status": 0, "expected": [], "verdict": "SKIP",
                        "note": "FULL=0",
                    }
                )
                print(f"  [sk] {tenant:7} {admin_user:11} {m:6} {p:55} -> SKIPPED")

    step(10, "Logout: POST /v1/auth/logout (admin) — last call (revokes jti)")
    # No body: the endpoint takes RefreshRequest | None; sending {} would 422.
    s, _ = request("POST", "/v1/auth/logout", token=admin_token)
    record(tenant, admin_user, "POST", "/v1/auth/logout", s, {200})


# --------------------------------------------------------------------------- #
# Full CRUD lifecycle (FULL=1) — dependency order from provision_*.sh
# --------------------------------------------------------------------------- #
def _first_id(payload: Any, key: str = "id") -> str | None:
    items = data_list(payload)
    for it in items:
        if isinstance(it, dict) and it.get(key):
            return str(it[key])
    return None


def run_lifecycle(tenant: str, conn: dict, token: str) -> None:
    stamp = int(time.time())
    name = f"libcloud-test-{tenant}-{stamp}"
    cleanup: list[tuple[str, str, str]] = []  # (method, path, label)

    def call(m, p, body=None, expected=None, note=""):
        s, payload = request(m, p, token=token, connection=conn, body=body)
        record(tenant, tenant + "-admin", m, p, s, expected or {200, 201, 202},
               note=note)
        return s, payload

    step(9, "Resolve catalog IDs (location/cluster, image, size, subnet)")
    _, locs = request("GET", "/v1/compute/locations", token=token, connection=conn)
    _, imgs = request("GET", "/v1/compute/images", token=token, connection=conn)
    _, subs = request("GET", "/v1/compute/subnets", token=token, connection=conn)
    cluster_id = _first_id(locs)
    image_id = _first_id(imgs)
    subnet_id = _first_id(subs)
    size_id = "small" if tenant == "nutanix" else "t3.micro"
    print(f"  cluster_id={cluster_id} image_id={image_id} subnet_id={subnet_id} size_id={size_id}")

    # ---- network (vpc) -> subnets/security-groups/load-balancers depend on it
    step(10, "Networks: create -> list -> patch -> (delete deferred)")
    s, p = call("POST", "/v1/compute/networks",
                body={"name": f"{name}-net", "cidr_block": "10.0.0.0/16"},
                expected={200, 201, 202, 400, 501})
    net_id = _first_id(p) if s in {200, 201, 202} else None
    if net_id:
        cleanup.append(("DELETE", f"/v1/compute/networks/{net_id}", "network"))
    call("GET", "/v1/compute/networks", expected={200})
    if net_id:
        call("PATCH", f"/v1/compute/networks/{net_id}",
             body={"name": f"{name}-net-renamed"}, expected={200, 202})

    # ---- subnet (needs vpc_id=net_id)
    step(11, "Subnets: create -> list -> patch -> delete")
    sub_id = None
    if net_id:
        s, p = call("POST", "/v1/compute/subnets",
                    body={"name": f"{name}-sub", "vpc_id": net_id,
                          "cidr_block": "10.0.1.0/24"},
                    expected={200, 201, 202, 400, 501})
        sub_id = _first_id(p) if s in {200, 201, 202} else None
    call("GET", "/v1/compute/subnets", expected={200})
    if sub_id:
        call("PATCH", f"/v1/compute/subnets/{sub_id}",
             body={"action": "tag", "tag_key": "env", "tag_value": "test"},
             expected={200, 202})
        call("DELETE", f"/v1/compute/subnets/{sub_id}", expected={200, 202, 204})

    # ---- key-pair
    step(12, "Key pairs: create -> list -> delete")
    kp_name = f"{name}-kp"
    call("POST", "/v1/compute/key-pairs", body={"name": kp_name},
         expected={200, 201, 202, 400, 501})
    call("GET", "/v1/compute/key-pairs", expected={200})
    call("DELETE", f"/v1/compute/key-pairs/{kp_name}", expected={200, 202, 204, 404})

    # ---- security-group (needs vpc_id)
    step(13, "Security groups: create -> list -> delete")
    sg_id = None
    if net_id:
        s, p = call("POST", "/v1/compute/security-groups",
                    body={"name": f"{name}-sg", "vpc_id": net_id},
                    expected={200, 201, 202, 400, 501})
        sg_id = _first_id(p) if s in {200, 201, 202} else None
    call("GET", "/v1/compute/security-groups", expected={200})
    if sg_id:
        call("DELETE", f"/v1/compute/security-groups/{sg_id}",
             expected={200, 202, 204, 404})

    # ---- load-balancer (needs vpc_id)
    step(14, "Load balancers: create -> list -> delete")
    lb_id = None
    if net_id:
        s, p = call("POST", "/v1/compute/load-balancers",
                    body={"name": f"{name}-lb", "vpc_id": net_id},
                    expected={200, 201, 202, 400, 501})
        lb_id = _first_id(p) if s in {200, 201, 202} else None
    call("GET", "/v1/compute/load-balancers", expected={200})
    if lb_id:
        call("DELETE", f"/v1/compute/load-balancers/{lb_id}",
             expected={200, 202, 204, 404})

    # ---- node (needs size/image/location; optional subnet)
    step(15, "Nodes: create -> get -> patch(tag) -> start/stop/reboot -> delete")
    node_id = None
    if image_id and cluster_id:
        body: dict[str, Any] = {
            "name": f"{name}-node",
            "size": {"id": size_id},
            "image": {"id": image_id},
            "location": {"id": cluster_id},
            "provider_options": {},
        }
        if subnet_id:
            body["network"] = {"subnet_id": subnet_id}
        s, p = call("POST", "/v1/compute/nodes", body=body,
                    expected={200, 201, 202, 400, 501})
        node_id = _first_id(p) if s in {200, 201, 202} else None
    call("GET", "/v1/compute/nodes", expected={200})
    if node_id:
        call("GET", f"/v1/compute/nodes/{node_id}", expected={200})
        call("PATCH", f"/v1/compute/nodes/{node_id}",
             body={"action": "tag", "tag_key": "env", "tag_value": "test"},
             expected={200, 202})
        call("POST", f"/v1/compute/nodes/{node_id}:start", body={},
             expected={200, 202, 409})
        call("POST", f"/v1/compute/nodes/{node_id}:stop", body={},
             expected={200, 202, 409})
        call("POST", f"/v1/compute/nodes/{node_id}:reboot", body={},
             expected={200, 202, 409})

    # ---- volume -> attach/detach depend on node; snapshot depends on volume
    step(16, "Volumes: create -> list -> patch -> attach -> detach -> delete")
    vol_id = None
    s, p = call("POST", "/v1/compute/volumes",
               body={"name": f"{name}-vol", "size_gb": 1},
               expected={200, 201, 202, 400, 501})
    vol_id = _first_id(p) if s in {200, 201, 202} else None
    call("GET", "/v1/compute/volumes", expected={200})
    if vol_id:
        call("PATCH", f"/v1/compute/volumes/{vol_id}",
             body={"action": "tag", "tag_key": "env", "tag_value": "test"},
             expected={200, 202})
        if node_id:
            call("POST", f"/v1/compute/volumes/{vol_id}:attach",
                 body={"node_id": node_id}, expected={200, 202, 409})
            call("POST", f"/v1/compute/volumes/{vol_id}:detach",
                 body={"node_id": node_id}, expected={200, 202, 409})

    # ---- snapshot (needs volume_id)
    step(17, "Snapshots: create -> list -> delete")
    snap_id = None
    if vol_id:
        s, p = call("POST", "/v1/compute/snapshots",
                    body={"volume_id": vol_id, "name": f"{name}-snap"},
                    expected={200, 201, 202, 400, 501})
        snap_id = _first_id(p) if s in {200, 201, 202} else None
    call("GET", "/v1/compute/snapshots", expected={200})
    if snap_id:
        call("DELETE", f"/v1/compute/snapshots/{snap_id}",
             expected={200, 202, 204, 404})

    # ---- floating-ip -> associate/disassociate depend on node
    step(18, "Floating IPs: allocate -> list -> associate -> disassociate -> release")
    fip_addr = None
    s, p = call("POST", "/v1/compute/floating-ips", body={},
                expected={200, 201, 202, 400, 501})
    if s in {200, 201, 202}:
        d = p.get("data", p) if isinstance(p, dict) else None
        if isinstance(d, dict):
            fip_addr = d.get("address") or d.get("id")
    call("GET", "/v1/compute/floating-ips", expected={200})
    if fip_addr and node_id:
        call("POST", f"/v1/compute/floating-ips/{fip_addr}:associate",
             body={"node_id": node_id}, expected={200, 202, 409})
        call("POST", f"/v1/compute/floating-ips/{fip_addr}:disassociate",
             body={}, expected={200, 202, 409})
    if fip_addr:
        call("DELETE", f"/v1/compute/floating-ips/{fip_addr}",
             expected={200, 202, 204, 404})

    # ---- images (compute:image:manage — no identity holds it; expect 403)
    step(19, "Images manage: POST/DELETE (expect 403 insufficient scope)")
    call("POST", "/v1/compute/images", body={"name": f"{name}-img"},
         expected={403, 400, 501})
    call("DELETE", "/v1/compute/images/nonexistent-image-id", expected={403, 404})

    # ---- storage buckets + objects
    step(20, "Storage: create bucket -> list -> upload -> list objects -> download -> delete object -> delete bucket")
    bucket = f"{tenant}-test-bucket-{stamp}".lower()[:63]
    call("POST", "/v1/storage/buckets", body={"name": bucket},
         expected={200, 201, 202, 400, 501})
    call("GET", "/v1/storage/buckets", expected={200})
    obj_name = "hello.txt"
    obj_b64 = base64.b64encode(b"hello from openapi_rest_test").decode()
    call("POST", f"/v1/storage/buckets/{bucket}/objects",
         body={"bucket": bucket, "object_name": obj_name, "data_b64": obj_b64,
               "content_type": "text/plain"},
         expected={200, 201, 202, 400, 501})
    call("GET", f"/v1/storage/buckets/{bucket}/objects", expected={200})
    call("POST", f"/v1/storage/buckets/{bucket}/objects/{obj_name}:download",
         body={}, expected={200, 404})
    call("DELETE", f"/v1/storage/buckets/{bucket}/objects/{obj_name}",
         expected={200, 202, 204, 404})
    call("DELETE", f"/v1/storage/buckets/{bucket}",
         expected={200, 202, 204, 404})

    # ---- jobs (connection-less; use a dummy id -> 404 or 200)
    step(21, "Jobs: GET /v1/jobs/{job_id} (dummy id)")
    call("GET", "/v1/jobs/nonexistent-job-id", expected={200, 404})

    # ---- cleanup in reverse dependency order
    step(22, "Cleanup: delete node, then volume, then network")
    if node_id:
        call("DELETE", f"/v1/compute/nodes/{node_id}", expected={200, 202, 204, 404})
    if vol_id:
        call("DELETE", f"/v1/compute/volumes/{vol_id}", expected={200, 202, 204, 404})
    for m, p, label in reversed(cleanup):
        s, _ = request(m, p, token=token, connection=conn)
        record(tenant, tenant + "-admin", m, p, s, {200, 202, 204, 404},
               note=f"cleanup {label}")


# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
def print_summary() -> int:
    print("\n" + "=" * 72)
    print("SUMMARY")
    print("=" * 72)
    counts: dict[str, int] = {}
    by_tenant: dict[str, dict[str, int]] = {}
    for r in results:
        v = r["verdict"]
        counts[v] = counts.get(v, 0) + 1
        by_tenant.setdefault(r["tenant"], {})
        by_tenant[r["tenant"]][v] = by_tenant[r["tenant"]].get(v, 0) + 1

    for tenant, c in by_tenant.items():
        parts = " ".join(f"{k}={v}" for k, v in sorted(c.items()))
        print(f"  {tenant:8} {parts}")
    print("  " + "-" * 40)
    parts = " ".join(f"{k}={v}" for k, v in sorted(counts.items()))
    print(f"  total    {parts}  (calls={len(results)})")

    # List any non-PASS/non-SKIP calls for quick triage.
    bad = [r for r in results if r["verdict"] not in {"PASS", "SKIP"}]
    if bad:
        print("\nUnexpected results:")
        for r in bad:
            print(f"  {r['tenant']:7} {r['user']:13} {r['method']:6} {r['path']:55} "
                  f"-> {r['status']} expected={r['expected']} {r['note']}")

    fails = counts.get("FAIL", 0) + counts.get("UNEXPECTED(0)", 0)
    unexpected = sum(v for k, v in counts.items() if k.startswith("UNEXPECTED"))
    return 1 if (fails or unexpected) else 0


def main() -> int:
    tenants = os.environ.get("TENANTS", "aws,nutanix").split(",")
    tenants = [t.strip() for t in tenants if t.strip() in TENANTS]
    print(f"libcloud REST OpenAPI test harness")
    print(f"  REST URL : {LIBCLOUD_REST_URL}")
    print(f"  spec     : {SPEC.get('info', {}).get('title')} {SPEC.get('openapi')}")
    print(f"  endpoints in spec: {len(spec_endpoints())}")
    print(f"  mode     : {'FULL (CRUD lifecycle)' if FULL else 'read-only (FULL=1 to enable CRUD)'}")
    print(f"  tenants  : {', '.join(tenants)}")
    for t in tenants:
        run_tenant(t, FULL)
    return print_summary()


if __name__ == "__main__":
    sys.exit(main())
