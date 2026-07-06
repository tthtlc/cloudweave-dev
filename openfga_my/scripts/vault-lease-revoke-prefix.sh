#!/usr/bin/env bash
# vault-lease-revoke-prefix.sh — revoke ALL Vault leases under a path prefix.
#
# Cloud Owner tool (high-impact). Use when a whole team is departing, a role is
# being retired, or a class of credentials must be invalidated at once (e.g.
# all AWS credentials issued under a compromised role).
#
# Revokes every lease whose ID starts with <prefix> by calling
# /sys/leases/revoke-prefix. Vault tears down each underlying cloud credential
# in the same call. This is destructive and not reversible — the script
# requires an explicit --confirm flag and, by default, prints the count of
# leases that will be revoked first (via /sys/leases/lookup) unless --force is
# also passed.
#
# Usage:
#   vault-lease-revoke-prefix.sh <prefix> --confirm
#   vault-lease-revoke-prefix.sh aws/creds/ec2-admin --confirm
#   vault-lease-revoke-prefix.sh aws/ --confirm --force
#
# Options:
#   --confirm        REQUIRED guard
#   --force          skip the pre-flight lease count (revoke immediately)
#   --vault-token <t>
#   -h, --help
#
# Exit codes:
#   0  all leases under prefix revoked
#   2  usage / missing --confirm
#   3  no Vault token / Vault unreachable
#   4  Vault rejected revoke-prefix
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vault_common.sh
source "${SCRIPT_DIR}/vault_common.sh"

CONFIRM=0
FORCE=0
PREFIX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm)     CONFIRM=1; shift ;;
    --force)       FORCE=1; shift ;;
    --vault-token) VAULT_TOKEN_ARG="$2"; shift 2 ;;
    -h|--help)     sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)           echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$PREFIX" ]]; then PREFIX="$1"
      else echo "ERROR: unexpected argument: $1" >&2; exit 2; fi
      shift ;;
  esac
done

[[ -n "$PREFIX" ]] || { echo "ERROR: prefix is required" >&2; exit 2; }
PREFIX="${PREFIX#/}"
if [[ "$CONFIRM" -ne 1 ]]; then
  echo "ERROR: --confirm is required to revoke a lease prefix (this destroys every matching credential)." >&2
  exit 2
fi

# Pre-flight: count the leases that will be revoked, unless --force.
if [[ "$FORCE" -ne 1 ]]; then
  count=$(PREFIX_E="$PREFIX" \
    VAULT_TOKEN_RESOLVED="$(vault_resolve_token)" \
    VAULT_ADDR_E="$VAULT_ADDR" \
    python3 - <<'PY'
import json, os, urllib.error, urllib.request
addr = os.environ["VAULT_ADDR_E"].rstrip("/")
tok = os.environ["VAULT_TOKEN_RESOLVED"]
prefix = os.environ["PREFIX_E"]
def call(m, p):
    url = addr + "/v1/" + p.lstrip("/")
    req = urllib.request.Request(url, method=m, headers={"X-Vault-Token": tok})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, {}
    except Exception:
        return 0, {}
def list_dir(path):
    c, b = call("LIST", "sys/leases/lookup/" + path)
    if c != 200:
        c, b = call("GET", "sys/leases/lookup/" + path + "?list=true")
    if c != 200: return []
    return (b.get("data") or {}).get("keys") or []
leaves = []
def walk(p):
    for k in list_dir(p):
        if k.endswith("/"): walk(p + k)
        else: leaves.append(p + k)
walk(prefix + "/" if not prefix.endswith("/") else prefix)
print(len(leaves))
PY
)
  echo "Pre-flight: ${count} lease(s) will be revoked under '${PREFIX}'." >&2
  if [[ "$count" -eq 0 ]]; then
    echo "No matching leases; nothing to do." >&2
    vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"lease-revoke-prefix\",\"prefix\":\"${PREFIX}\",\"result\":\"no-op\",\"count\":0}"
    exit 0
  fi
  echo "Re-run with --force to proceed, or use a more specific prefix." >&2
  exit 2
fi

body=$(P="$PREFIX" python3 -c '
import json, os
print(json.dumps({"prefix": os.environ["P"]}))
')
body_tmp=$(vault_body_file "$body")

echo "Revoking all leases under prefix '${PREFIX}' ..." >&2
vault_post "sys/leases/revoke-prefix" "$body_tmp"
http="$VAULT_HTTP_CODE"
resp=$(cat "$VAULT_OUT")
rm -f "$body_tmp"

if [[ "$http" != "200" && "$http" != "204" ]]; then
  echo "ERROR: Vault rejected revoke-prefix (http=${http}): ${resp}" >&2
  vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"lease-revoke-prefix\",\"prefix\":\"${PREFIX}\",\"result\":\"error\",\"http\":${http:-0}}"
  exit 4
fi

echo "OK: revoke-prefix issued for '${PREFIX}'." >&2
vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"lease-revoke-prefix\",\"prefix\":\"${PREFIX}\",\"result\":\"ok\",\"http\":${http:-0}}"
exit 0
