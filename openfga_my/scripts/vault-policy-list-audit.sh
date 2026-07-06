#!/usr/bin/env bash
# vault-policy-list-audit.sh — audit Vault ACL policies and their bindings.
#
# Cloud Owner compliance tool. Lists every ACL policy in Vault and, for each,
# the LDAP groups and AppRoles that bind to it. Produces a dated CSV under
# generated/audit/ (default) or a path supplied via --out. Also prints a
# summary to stderr and emits a JSONL audit record.
#
# Bindings are discovered by listing the LDAP auth groups and the AppRole
# roles, then reading each one's `policies` field. The LDAP auth path defaults
# to `ldap` (override with --auth-path); AppRole path defaults to `approle`.
#
# Usage:
#   vault-policy-list-audit.sh [--out PATH] [--stdout] [--auth-path ldap]
#                              [--approle-path approle] [--vault-token <t>]
#
# Output CSV columns: timestamp, policy, ldap_groups, approle_roles, has_hcl
#
# Exit codes:
#   0  report written
#   2  usage
#   3  no Vault token / Vault unreachable
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vault_common.sh
source "${SCRIPT_DIR}/vault_common.sh"

OUT=""
STDOUT=0
AUTH_PATH="ldap"
APPROLE_PATH="approle"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)          OUT="$2"; shift 2 ;;
    --stdout)       STDOUT=1; shift ;;
    --auth-path)    AUTH_PATH="$2"; shift 2 ;;
    --approle-path) APPROLE_PATH="$2"; shift 2 ;;
    --vault-token)  VAULT_TOKEN_ARG="$2"; shift 2 ;;
    -h|--help)      sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

ts="$(vault_now)"
date_tag=$(date -u +%Y%m%d_%H%M%S)
[[ -n "$OUT" ]] || OUT="${ROOT}/generated/audit/vault_policy_bindings_${date_tag}.csv"
mkdir -p "$(dirname "$OUT")"

# Single Python pass over the Vault HTTP API: enumerate policies, ldap groups,
# approle roles, then emit the CSV. Doing it in one process avoids many small
# bash subshells and keeps the binding map in memory.
VAULT_TOKEN_RESOLVED="$(vault_resolve_token)" || exit $?
VAULT_TOKEN_RESOLVED="$VAULT_TOKEN_RESOLVED" \
VAULT_ADDR_E="$VAULT_ADDR" \
AUTH_PATH_E="$AUTH_PATH" \
APPROLE_PATH_E="$APPROLE_PATH" \
OUT_E="$OUT" \
STDOUT_E="$STDOUT" \
TS_E="$ts" \
ACTOR_E="$ACTOR" \
python3 - <<'PY'
import csv, json, os, sys, urllib.error, urllib.request

addr = os.environ["VAULT_ADDR_E"].rstrip("/")
tok = os.environ["VAULT_TOKEN_RESOLVED"]
auth_path = os.environ["AUTH_PATH_E"]
approle_path = os.environ["APPROLE_PATH_E"]
out_path = os.environ["OUT_E"]
stdout = os.environ["STDOUT_E"] == "1"
ts = os.environ["TS_E"]

def call(method, path, *, list_mode=False):
    if not path.startswith("/v1/"):
        path = "/v1/" + path.lstrip("/")
    url = addr + path
    if list_mode:
        # Prefer the LIST verb; fall back to GET ?list=true handled by caller.
        req = urllib.request.Request(url, method="LIST",
                                     headers={"X-Vault-Token": tok})
    else:
        req = urllib.request.Request(url, method=method,
                                     headers={"X-Vault-Token": tok})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read().decode("utf-8") or "{}"
            return r.status, json.loads(raw)
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace") or ""
        try: payload = json.loads(raw) if raw else {}
        except Exception: payload = {"raw": raw}
        return e.code, payload
    except Exception as e:
        return 0, {"error": str(e)}

def list_keys(path):
    code, body = call("LIST", path, list_mode=True)
    if code != 200:
        code, body = call("GET", path + "?list=true")
    if code != 200:
        return []
    return (body.get("data") or {}).get("keys") or []

# 1. All ACL policies.
policies = sorted(list_keys("sys/policies/acl"))
# Built-in policies (root, default) are always present; include them.

# 2. LDAP groups -> policies.
ldap_groups = list_keys(f"auth/{auth_path}/groups")
ldap_map = {}  # policy -> [group names]
for g in ldap_groups:
    code, body = call("GET", f"auth/{auth_path}/groups/{g}")
    if code != 200: continue
    pols = (body.get("data") or {}).get("policies") or []
    if isinstance(pols, str):
        pols = [p.strip() for p in pols.split(",") if p.strip()]
    for p in pols:
        ldap_map.setdefault(p, []).append(g)

# 3. AppRole roles -> policies.
approle_roles = list_keys(f"auth/{approle_path}/role")
approle_map = {}
for r in approle_roles:
    code, body = call("GET", f"auth/{approle_path}/role/{r}")
    if code != 200: continue
    pols = (body.get("data") or {}).get("policies") or []
    if isinstance(pols, str):
        pols = [p.strip() for p in pols.split(",") if p.strip()]
    for p in pols:
        approle_map.setdefault(p, []).append(r)

rows = []
for p in policies:
    # has_hcl: read the policy body.
    code, body = call("GET", f"sys/policies/acl/{p}")
    has_hcl = "1" if (code == 200 and (body.get("data") or {}).get("policy")) else "0"
    rows.append({
        "timestamp": ts,
        "policy": p,
        "ldap_groups": ";".join(sorted(ldap_map.get(p, []))),
        "approle_roles": ";".join(sorted(approle_map.get(p, []))),
        "has_hcl": has_hcl,
    })

# Also record bindings to policies that don't exist (stale binding -> orphan).
for p in set(list(ldap_map) + list(approle_map)):
    if p in policies: continue
    rows.append({
        "timestamp": ts,
        "policy": p,
        "ldap_groups": ";".join(sorted(ldap_map.get(p, []))),
        "approle_roles": ";".join(sorted(approle_map.get(p, []))),
        "has_hcl": "stale-binding",
    })

with open(out_path, "w", newline="", encoding="utf-8") as fh:
    w = csv.DictWriter(fh, fieldnames=["timestamp","policy","ldap_groups","approle_roles","has_hcl"])
    w.writeheader()
    w.writerows(rows)

if stdout:
    with open(out_path, encoding="utf-8") as fh:
        sys.stdout.write(fh.read())

summary = {"policies": len(policies), "ldap_groups": len(ldap_groups),
           "approle_roles": len(approle_roles), "rows": len(rows), "out": out_path}
print(json.dumps(summary), file=sys.stderr)
PY

echo "audit CSV written: ${OUT}" >&2
vault_audit "{\"ts\":\"${ts}\",\"actor\":\"${ACTOR}\",\"action\":\"policy-list-audit\",\"result\":\"ok\",\"out\":\"${OUT}\"}"
exit 0
