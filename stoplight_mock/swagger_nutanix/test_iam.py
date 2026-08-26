#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────────────
# Nutanix IAM mock — endpoint test runner.
#
# Enumerates EVERY path + operation declared in an IAM swagger spec and issues
# a request against the matching Stoplight Prism mock, verifying that it
# returns the operation's documented success status code. This proves the mock
# recognises each URL (no 404s) and that auth, `If-Match`, and request-body
# validation all line up.
#
# Request bodies for POST/PUT/PATCH are generated from the request schema
# (example → default → enum → type-derived value), skipping read-only fields
# and populating required fields. Path parameters ({extId}, {userExtId}) are
# filled with UUIDs, and required `If-Match` headers are supplied.
#
# Authentication follows a session-cookie flow: the first request carries
# Basic auth (or X-ntnx-api-key); if the server answers with a Set-Cookie, the
# cookie is replayed on every later request and the credential header is
# dropped. Against a static Prism mock (which issues no session cookie) the
# runner falls back to sending the credential on every request, so the tests
# still pass.
#
# Version → default port mapping (override with --port or the IAM_*_PORT env):
#   v4.0      → 9550   (IAM_V40_PORT)
#   v4.1.b2   → 9551   (IAM_V41_B2_PORT)
#   v4.1.b3   → 9552   (IAM_V41_B3_PORT)
#
# Usage:
#   ./test_iam.py                     # test all three versions (default ports)
#   ./test_iam.py --version v4.0      # one version
#   ./test_iam.py --version v4.1.b2 --port 19551
#   ./test_iam.py --list              # list endpoints without sending requests
#   ./test_iam.py -v                  # verbose (print each request + status)
#
# Exit code: number of failed requests (0 = all passed).
# ─────────────────────────────────────────────────────────────────────────────

import argparse
import base64
import json
import os
import re
import sys
from datetime import date, datetime
from http.cookiejar import CookieJar
from urllib import error as uerr
from urllib import request as ureq

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required:  pip install pyyaml")

HERE = os.path.dirname(os.path.abspath(__file__))

SPECS = {
    "v4.0": "swagger-iam-v4.0-all.yaml",
    "v4.1.b2": "swagger-iam-v4.1.b2-all.yaml",
    "v4.1.b3": "swagger-iam-v4.1.b3-all.yaml",
}
DEFAULT_PORTS = {"v4.0": 9550, "v4.1.b2": 9551, "v4.1.b3": 9552}
ENV_PORTS = {"v4.0": "IAM_V40_PORT", "v4.1.b2": "IAM_V41_B2_PORT", "v4.1.b3": "IAM_V41_B3_PORT"}

UUID = "11111111-2222-3333-4444-555555555555"
UUID2 = "66666666-7777-8888-9999-aaaaaaaaaaaa"  # distinct value for {userExtId}
PATH_PARAM_VALUES = {"extId": UUID, "userExtId": UUID2, "id": UUID}

# Http methods, in the order the swagger lists them (get/post/put/patch/delete).
METHODS = ("get", "post", "put", "patch", "delete")

# ─── schema-driven example generator ─────────────────────────────────────────

class ExampleGen:
    def __init__(self, spec):
        self.spec = spec
        self.schemas = spec.get("components", {}).get("schemas", {})

    def resolve(self, node):
        while isinstance(node, dict) and "$ref" in node:
            ref = node["$ref"]
            if not ref.startswith("#/"):
                return {}  # external refs unsupported — treat as empty
            node = self.spec
            for part in ref[2:].split("/"):
                node = node[part] if isinstance(node, dict) else {}
        return node

    def flatten(self, schema):
        """Merge allOf members into one schema (properties + required)."""
        schema = self.resolve(schema)
        if not isinstance(schema, dict):
            return schema
        if "allOf" in schema:
            # Preserve the top-level properties/required before folding in the
            # allOf members (a required field often lives at the top level
            # while its schema lives in one of the members).
            props = dict(schema.get("properties", {}))
            required = list(schema.get("required", []))
            for sub in schema["allOf"]:
                sub = self.flatten(sub)
                if not isinstance(sub, dict):
                    continue
                props.update(sub.get("properties", {}))
                required += sub.get("required", [])
            merged = {k: v for k, v in schema.items()
                      if k not in ("allOf", "properties", "required")}
            if props:
                merged["properties"] = props
            if required:
                merged["required"] = list(dict.fromkeys(required))
            return merged
        return schema

    def gen(self, schema):
        schema = self.resolve(schema)
        if not isinstance(schema, dict):
            return None
        schema = self.flatten(schema)

        if "enum" in schema:
            vals = [v for v in schema["enum"] if not str(v).startswith("$")]
            if vals:
                return _scalar(vals[0])
        if "example" in schema:
            v = _scalar(schema["example"])
            # Honour minLength when the example is a too-short string (e.g.
            # clientCaChain in v4.1 has example "string" but minLength 64).
            if schema.get("type") == "string" and isinstance(v, str):
                ml = schema.get("minLength", 0)
                if len(v) < ml:
                    v = v.ljust(ml, "x")
            return v
        if "default" in schema:
            return _scalar(schema["default"])
        for key in ("oneOf", "anyOf"):
            if schema.get(key):
                return self.gen(schema[key][0])

        t = schema.get("type")
        if t == "object" or "properties" in schema:
            obj = {}
            props = schema.get("properties", {})
            for name in schema.get("required", []):
                prop = self.resolve(props.get(name, {}))
                if prop.get("readOnly"):
                    continue
                obj[name] = self.gen(prop)
            return obj
        if t == "array":
            n = max(1, schema.get("minItems") or 1)
            return [self.gen(schema.get("items", {})) for _ in range(n)]
        if t == "integer":
            return 0
        if t == "number":
            return 0
        if t == "boolean":
            return False
        if t == "string":
            fmt = schema.get("format", "")
            pat = schema.get("pattern", "")
            if fmt == "uuid" or "{8}" in pat:
                return UUID
            if fmt == "date-time":
                return "2026-01-01T00:00:00Z"
            if "minLength" in schema:
                return "x" * max(1, schema["minLength"])
            return "string"
        return None


def _scalar(v):
    if isinstance(v, (datetime, date)):
        return v.isoformat()
    return v


# ─── request plumbing ────────────────────────────────────────────────────────

def load_spec(version):
    path = os.path.join(HERE, SPECS[version])
    with open(path) as f:
        return yaml.safe_load(f)


def success_code(op):
    for code in op.get("responses", {}):
        cs = str(code)
        if cs.isdigit() and cs.startswith("2"):
            return int(cs)
    return 200


def header_params(op):
    """Return required header params as {name: value}."""
    out = {}
    for pr in op.get("parameters", []):
        if pr.get("in") == "header" and pr.get("required"):
            out[pr["name"]] = header_value(pr)
    return out


def header_value(pr):
    name = pr["name"]
    if name.lower() == "if-match":
        return 'W/"1"'
    sch = pr.get("schema", {})
    if sch.get("type") == "integer":
        return "0"
    return "string"


def build_path(path):
    def repl(m):
        return PATH_PARAM_VALUES.get(m.group(1), UUID)
    return re.sub(r"\{([^}]+)\}", repl, path)


def encode_multipart(fields):
    """Encode a dict as a multipart/form-data body (all parts as form fields)."""
    boundary = "----iam-mock-test-boundary"
    parts = []
    for k, v in fields.items():
        if isinstance(v, bool):
            v = "true" if v else "false"
        elif v is None:
            v = ""
        elif isinstance(v, (dict, list)):
            v = json.dumps(v, default=_scalar)
        else:
            v = str(v)
        parts.append(
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="{k}"\r\n'
            f"\r\n{v}"
        )
    body = "\r\n".join(parts) + f"\r\n--{boundary}--\r\n"
    return f"multipart/form-data; boundary={boundary}", body.encode("utf-8")


def request_payload(op, gen):
    """Return (content_type, body_bytes) for the operation's request, or
    (None, None) when it has no body."""
    rb = op.get("requestBody")
    if not rb:
        return None, None
    content = rb.get("content", {})
    for ct, v in content.items():
        schema = v.get("schema")
        value = gen.gen(schema) if schema is not None else None
        if ct == "multipart/form-data" and isinstance(value, dict):
            return encode_multipart(value)
        if value is not None:
            return ct, json.dumps(value, default=_scalar).encode()
    return None, None


def do_request(opener, base, method, path, content_type, data, headers):
    url = base + path
    headers = dict(headers)
    if data is not None:
        headers["Content-Type"] = content_type
    req = ureq.Request(url, data=data, headers=headers, method=method.upper())
    try:
        resp = opener.open(req, timeout=30)
        return resp.status, resp.read().decode(errors="replace")
    except uerr.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except uerr.URLError as e:
        return "ERR", str(e)


# ─── main ────────────────────────────────────────────────────────────────────

def port_for(version, explicit_port):
    if explicit_port is not None:
        return explicit_port
    env = ENV_PORTS[version]
    if env in os.environ:
        return int(os.environ[env])
    return DEFAULT_PORTS[version]


def run_spec(version, host, port, user, password, api_key, verbose, list_only, fail, total):
    spec = load_spec(version)
    gen = ExampleGen(spec)
    base = f"http://{host}:{port}"

    print(f"\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print(f"  {version}  →  {base}   ({SPECS[version]})")
    print(f"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    auth_headers = {}
    if api_key:
        auth_headers["X-ntnx-api-key"] = api_key
    else:
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        auth_headers["Authorization"] = f"Basic {token}"

    # Session-cookie plumbing: send the credential until the server issues a
    # session cookie, then replay the cookie alone and drop the credential.
    jar = CookieJar()
    opener = ureq.build_opener(ureq.HTTPCookieProcessor(jar))
    session = False  # True once the server has issued a session cookie

    for path in spec.get("paths", {}):
        ops = spec["paths"][path]
        for m in METHODS:
            if m not in ops:
                continue
            op = ops[m]
            url_path = build_path(path)
            headers = dict(auth_headers) if not session else {}
            headers.update(header_params(op))
            content_type, data = request_payload(op, gen)
            expected = success_code(op)
            total[0] += 1

            if list_only:
                print(f"  {m.upper():6} {url_path}")
                continue

            code, resp = do_request(opener, base, m, url_path, content_type, data, headers)
            if not session:
                session = bool(list(jar))
            if code == expected:
                mark, ok = "✓", True
            else:
                mark, ok = "✗", False
                fail[0] += 1
            line = f"  {mark} {m.upper():6} {url_path}"
            if verbose or not ok:
                print(f"{line}  → HTTP {code} (expected {expected})")
            else:
                print(line)
    return base


def main():
    ap = argparse.ArgumentParser(description="Test the Nutanix IAM Prism mocks.")
    ap.add_argument("--version", choices=list(SPECS) + ["all"], default="all",
                    help="which spec to test (default: all)")
    ap.add_argument("--host", default="localhost", help="mock host (default: localhost)")
    ap.add_argument("--port", type=int, default=None,
                    help="override the port (single --version only)")
    ap.add_argument("--user", default="admin", help="Basic-auth user (default: admin)")
    ap.add_argument("--password", default="admin", help="Basic-auth password (default: admin)")
    ap.add_argument("--api-key", default=None,
                    help="use X-ntnx-api-key instead of Basic auth")
    ap.add_argument("--list", action="store_true",
                    help="list endpoints without sending requests")
    ap.add_argument("-v", "--verbose", action="store_true", help="verbose output")
    args = ap.parse_args()

    versions = list(SPECS) if args.version == "all" else [args.version]
    if args.port is not None and len(versions) != 1:
        ap.error("--port requires a single --version")

    fail, total = [0], [0]
    for v in versions:
        run_spec(v, args.host, port_for(v, args.port), args.user, args.password,
                 args.api_key, args.verbose, args.list, fail, total)

    print(f"\n════════════════════════════════════════════════════════")
    if args.list:
        print(f"  Endpoints listed: {total[0]}")
    else:
        print(f"  Results: {total[0] - fail[0]} passed, {fail[0]} failed  "
              f"(of {total[0]} requests)")
    print(f"════════════════════════════════════════════════════════")
    sys.exit(fail[0])


if __name__ == "__main__":
    main()
