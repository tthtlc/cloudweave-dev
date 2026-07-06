#!/usr/bin/env bash
# vault-lease-list.sh — list active Vault leases under a path prefix.
#
# Cloud Admin tool. Useful for understanding what dynamic credentials are
# currently live for a given role / engine path.
#
# Usage:
#   vault-lease-list.sh <prefix>
#   vault-lease-list.sh aws/creds/ec2-admin
#   vault-lease-list.sh aws/      # all AWS leases
#   vault-lease-list.sh --verbose aws/creds/ec2-admin
#
# Lists lease IDs (and, with --verbose, per-lease TTL + issue time + renewable
# flag) by walking /sys/leases/lookup/<prefix>. Vault LIST is recursive only
# one level at a time, so the script descends into key entries that end with
# "/" (sub-trees) until it reaches leaf lease IDs.
#
# Options:
#   --verbose, -v   fetch each leaf lease's lookup details
#   --vault-token <t>
#   --json          print raw JSON instead of a table
#   -h, --help
#
# Exit codes:
#   0  list produced (may be empty)
#   2  usage
#   3  no Vault token / Vault unreachable
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vault_common.sh
source "${SCRIPT_DIR}/vault_common.sh"

VERBOSE=0
JSON=0
PREFIX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose)  VERBOSE=1; shift ;;
    --json)        JSON=1; shift ;;
    --vault-token) VAULT_TOKEN_ARG="$2"; shift 2 ;;
    -h|--help)     sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)           echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$PREFIX" ]]; then PREFIX="$1"
      else echo "ERROR: unexpected argument: $1" >&2; exit 2; fi
      shift ;;
  esac
done

[[ -n "$PREFIX" ]] || { echo "ERROR: lease path prefix is required" >&2; exit 2; }
PREFIX="${PREFIX#/}"

# Recursively enumerate leases under the prefix. Done in one python pass so the
# recursion + per-leaf optional detail fetch is straightforward.
VAULT_TOKEN_RESOLVED="$(vault_resolve_token)" || exit $?
VAULT_TOKEN_RESOLVED="$VAULT_TOKEN_RESOLVED" \
VAULT_ADDR_E="$VAULT_ADDR" \
PREFIX_E="$PREFIX" \
VERBOSE_E="$VERBOSE" \
JSON_E="$JSON" \
python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request

addr = os.environ["VAULT_ADDR_E"].rstrip("/")
tok = os.environ["VAULT_TOKEN_RESOLVED"]
prefix = os.environ["PREFIX_E"]
verbose = os.environ["VERBOSE_E"] == "1"
as_json = os.environ["JSON_E"] == "1"

def call(method, path):
    url = addr + "/v1/" + path.lstrip("/")
    req = urllib.request.Request(url, method=method, headers={"X-Vault-Token": tok})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace") or ""
        try: p = json.loads(raw) if raw else {}
        except Exception: p = {"raw": raw}
        return e.code, p
    except Exception as e:
        return 0, {"error": str(e)}

def list_dir(path):
    code, body = call("LIST", "sys/leases/lookup/" + path)
    if code != 200:
        code, body = call("GET", "sys/leases/lookup/" + path + "?list=true")
    if code != 200:
        return []
    return (body.get("data") or {}).get("keys") or []

leaves = []
def walk(path):
    for k in list_dir(path):
        full = path + k
        if k.endswith("/"):
            walk(full)
        else:
            leaves.append(full)

walk(prefix + "/" if not prefix.endswith("/") else prefix)

rows = []
for lease in leaves:
    if not verbose:
        rows.append({"lease_id": lease})
        continue
    code, body = call("GET", "sys/leases/lookup/" + lease)
    d = body.get("data") or {}
    rows.append({
        "lease_id": lease,
        "ttl": d.get("ttl"),
        "issue_time": d.get("issue_time"),
        "renewable": d.get("renewable"),
        "data": d.get("data"),
    })

if as_json:
    print(json.dumps(rows, indent=2))
else:
    if verbose:
        print(f"{'lease_id':50}  {'ttl':>6}  {'renew':>6}  issue_time")
        for r in rows:
            print(f"{r['lease_id']:50}  {str(r.get('ttl')):>6}  {str(r.get('renewable')):>6}  {r.get('issue_time','')}")
    else:
        for r in rows:
            print(r["lease_id"])
print(f"({len(rows)} lease(s) under {prefix})", file=sys.stderr)
PY

vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"lease-list\",\"prefix\":\"${PREFIX}\",\"verbose\":${VERBOSE}}"
exit 0
