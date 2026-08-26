#!/usr/bin/env python3
"""Generate bash+curl scripts covering every endpoint of the Nutanix IAM
swagger documents (iam-v4.0-endpoints.json / iam-v4.1-endpoints.json).

Regenerate with:
    python3 extract_endpoints.py swagger-iam-v4.0-all.yaml iam-v4.0-endpoints.json
    python3 extract_bodies.py     swagger-iam-v4.0-all.yaml iam-v4.0-bodies.json
    python3 extract_endpoints.py swagger-iam-v4.1.b3-all.yaml iam-v4.1-endpoints.json
    python3 extract_bodies.py     swagger-iam-v4.1.b3-all.yaml iam-v4.1-bodies.json
    python3 generate_scripts.py
"""
import json
import sys

HEADER = """#!/usr/bin/env bash
# =============================================================================
# Nutanix IAM {ver_label} - every REST endpoint as a curl function.
# Generated from {yaml} ({n} endpoints).
#
# Authentication: cookie derived from IAM authentication.
#   iam_login() authenticates once with Basic auth (PC_USERNAME/PC_PASSWORD
#   from .env) and stores the NTNX_IGW_SESSION cookie; every request below is
#   then sent with ONLY that cookie for access control.
#
# Usage:
#   ./{script}                          list all endpoints
#   ./{script} <operationId> [args...]  run one endpoint
#   ./{script} all-readonly             run every GET endpoint
#   ./{script} all                      run ALL endpoints incl. DELETE/POST
#                                       (requires FORCE_ALL=yes)
#
# Function arguments:
#   * path parameters (extId, userExtId) are positional, in path order
#   * "name=value" extra args become URL query parameters, e.g.
#       listUsers '$page=0' '$limit=50' '$filter=userType eq "LOCAL"'
#   * DELETE/PUT take the If-Match etag as second arg (default ${ETAG:-0};
#     "0" = do not check, matching Nutanix convention)
#   * JSON payloads: override via PAYLOAD='{...}' environment variable
#   * CURL_DRY_RUN=1 prints the exact curl command instead of running it
#
# WARNING: create*/update*/delete*/reset*/revoke*/share* functions mutate
# your Prism Central. Review the payload placeholders before running them.
# =============================================================================

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

IAM_BASE_PATH="{iam_base}"   # probe endpoint used by iam_login()
"""


def esc_path(path: str) -> str:
    """Escape $ so bash double quotes don't expand $actions etc."""
    return path.replace("$", "\\$")


def path_params(path: str):
    """Return the {param} names in path order."""
    out = []
    for part in path.split("/"):
        if part.startswith("{") and part.endswith("}"):
            out.append(part[1:-1])
    return out


def bash_url(path: str, args, prefix_var="url"):
    """Build the bash expression for the full path with interpolated vars."""
    # replace {name} with ${name}, escape $
    out = esc_path(path)
    for p in path_params(path):
        out = out.replace("{" + p + "}", "${" + p + "}")
    return f'"{out}"'


def function_doc(e):
    lines = [f"# {e['method']} {e['path']}"]
    if e["summary"]:
        lines.append(f"#   {e['summary']}")
    qp = [p["name"] for p in e["parameters"] if p["in"] == "query"]
    hp = [p["name"] for p in e["parameters"] if p["in"] == "header"]
    pp = path_params(e["path"])
    if pp:
        lines.append(f"#   path args (positional): {' '.join(pp)}")
    if qp:
        lines.append(f"#   query params: {' '.join(qp)}")
    if hp:
        lines.append(f"#   headers: {' '.join(hp)}")
    return lines


def gen_function(e, body):
    """Generate the bash function for one endpoint."""
    lines = function_doc(e)
    op = e["operationId"]
    method = e["method"]
    path = e["path"]
    pp = path_params(path)
    n = len(pp)
    # positional declarations for all path params (1-based)
    decls = [f'    local {p}="${{{i+1}:?usage: {p} required}}"' for i, p in enumerate(pp)]
    rest = f'"${{@:{n + 1}}}"'  # remaining args after the path params
    has_ifmatch = any(p["name"] == "If-Match" for p in e["parameters"])
    url = bash_url(path, pp)

    lines.append(f"{op}() {{")
    if body is None:
        # -------- no request body --------
        lines.extend(decls)
        if method == "DELETE":
            etag_i = n + 1
            lines.append(f'    local etag="${{{etag_i}:-${{ETAG:-0}}}}"')
            lines.append(f'    _req DELETE {url} "" "@If-Match: ${{etag}}" "${{@:{etag_i + 1}}}"')
        elif method == "GET":
            lines.append(f'    _req GET {url} "" {rest}')
        elif method in ("POST", "PUT", "PATCH"):
            # action endpoints that declare no request body (e.g. $actions/revoke)
            lines.append(f'    _req {method} {url} "" {rest}')
        else:
            raise ValueError(f"no body for {method} {path}")
    else:
        # -------- request body --------
        ctype = body["contentType"]
        ex = body["example"]
        if ctype == "multipart/form-data":
            fields = []
            if isinstance(ex, dict):
                for k, v in ex.items():
                    if isinstance(v, bool):
                        v = str(v).lower()
                    if k == "caCertFileName":
                        fields.append(f'{k}=@${{CA_CERT_FILE:-{v}}}')
                    else:
                        fields.append(f"{k}={v}")
            lines[0] += "  # multipart/form-data (certificate upload)"
            fargs = " ".join(f'"{f}"' for f in fields)
            if has_ifmatch:
                etag_i = n + 1
                lines.extend(decls)
                lines.append(f'    local etag="${{{etag_i}:-${{ETAG:-0}}}}"')
                lines.append(f'    _req_multipart {method} {url} "@If-Match: ${{etag}}" {fargs}')
            else:
                lines.extend(decls)
                lines.append(f'    _req_multipart {method} {url} {fargs}')
            if any(k == "caCertFileName" for k in (ex or {})):
                lines.append("#   set CA_CERT_FILE=/path/to/your/ca-chain.pem to upload your own file")
        else:
            payload = json.dumps(ex) if not isinstance(ex, str) else ex
            # single-quote payload; it contains no single quotes
            qpayload = f"'{payload}'"
            lines.extend(decls)
            lines.append(f'    local payload="${{PAYLOAD:-{qpayload}}}"')
            if has_ifmatch:
                etag_i = n + 1
                lines.append(f'    local etag="${{{etag_i}:-${{ETAG:-0}}}}"')
                lines.append(f'    _req {method} {url} "$payload" "@If-Match: ${{etag}}" "${{@:{etag_i + 1}}}"')
            else:
                lines.append(f'    _req {method} {url} "$payload" {rest}')
    lines.append("}")
    return lines


def gen_usage(endpoints, script):
    """Generate the usage/help text."""
    by_tag = {}
    for e in endpoints:
        for t in e["tags"] or ["Other"]:
            by_tag.setdefault(t, []).append(e)
    out = [f"usage() {{", f"    cat <<'EOF'", ""]
    out.append(f"{script} - Nutanix IAM curl endpoints (one function per endpoint)")
    out.append("")
    out.append(f"Usage: ./{script} [operationId [args...] | all-readonly | all | help]")
    out.append("")
    for tag in sorted(by_tag):
        out.append(f"  {tag}")
        for e in by_tag[tag]:
            out.append(f"    {e['operationId']:<45} {e['method']:<6} {e['path']}")
        out.append("")
    out += ["EOF", "}", ""]
    return out


def gen_main(endpoints, script):
    get_funcs = [e["operationId"] for e in endpoints if e["method"] == "GET"]
    all_funcs = [e["operationId"] for e in endpoints]
    out = [
        f"ALL_FUNCS=( {' '.join(all_funcs)} )",
        f"READONLY_FUNCS=( {' '.join(get_funcs)} )",
        "",
        "case \"${1:-}\" in",
        "    \"\"|help|-h|--help)",
        "        usage",
        "        ;;",
        "    all-readonly)",
        "        iam_login",
        "        for fn in \"${READONLY_FUNCS[@]}\"; do",
        "            echo; echo \"===== ${fn} =====\"",
        "            # subshell: a missing required arg aborts only this call",
        "            ( \"${fn}\" ) || true",
        "        done",
        "        ;;",
        "    all)",
        "        if [[ \"${FORCE_ALL:-}\" != \"yes\" ]]; then",
        "            echo \"Refusing: 'all' includes DELETE/create/update actions.\" >&2",
        "            echo \"Run with FORCE_ALL=yes if you really mean it.\" >&2",
        "            exit 1",
        "        fi",
        "        iam_login",
        "        for fn in \"${ALL_FUNCS[@]}\"; do",
        "            echo; echo \"===== ${fn} =====\"",
        "            ( \"${fn}\" ) || true",
        "        done",
        "        ;;",
        "    *)",
        "        op=\"$1\"; shift",
        "        if declare -f \"${op}\" >/dev/null 2>&1; then",
        "            iam_login",
        "            \"${op}\" \"$@\"",
        "        else",
        "            echo \"Unknown operationId: ${op}\" >&2",
        "            usage",
        "            exit 1",
        "        fi",
        "        ;;",
        "esac",
    ]
    return out


def generate(endpoints_path, bodies_path, yaml, script, ver_label, iam_base):
    endpoints = json.load(open(endpoints_path))["endpoints"]
    bodies = json.load(open(bodies_path))
    n = len(endpoints)

    header = (HEADER.replace("{ver_label}", ver_label)
                   .replace("{yaml}", yaml)
                   .replace("{n}", str(n))
                   .replace("{script}", script)
                   .replace("{iam_base}", iam_base))
    parts = [header]
    for e in endpoints:
        key = f"{e['method']} {e['path']}"
        body = bodies.get(key)
        parts.append("\n".join(gen_function(e, body)))
        parts.append("")
    parts.append("\n".join(gen_usage(endpoints, script)))
    parts.append("\n".join(gen_main(endpoints, script)))

    with open(script, "w") as f:
        f.write("\n".join(parts))
    print(f"{script}: {n} endpoint functions")


if __name__ == "__main__":
    generate(
        "iam-v4.0-endpoints.json", "iam-v4.0-bodies.json",
        "swagger-iam-v4.0-all.yaml", "iam_v4.0_curl.sh",
        "v4.0", "/iam/v4.0/authn",
    )
    generate(
        "iam-v4.1-endpoints.json", "iam-v4.1-bodies.json",
        "swagger-iam-v4.1.b3-all.yaml", "iam_v4.1_curl.sh",
        "v4.1 (beta)", "/iam/v4.1.b3/authn",
    )
