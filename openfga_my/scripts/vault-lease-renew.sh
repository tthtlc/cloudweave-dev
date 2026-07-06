#!/usr/bin/env bash
# vault-lease-renew.sh — renew a specific Vault lease by ID.
#
# Cloud Admin tool. Use when automated renewal (Vault Agent) has failed and a
# service is about to lose access. Renews the lease for an additional increment
# (default: Vault role's default_ttl; override with --increment <seconds>).
#
# Usage:
#   vault-lease-renew.sh <lease-id>
#   vault-lease-renew.sh aws/creds/ec2-admin/abc123...
#   vault-lease-renew.sh <lease-id> --increment 3600
#
# Options:
#   --increment <s>   renew for this many seconds (else role default)
#   --vault-token <t>
#   -h, --help
#
# Exit codes:
#   0  lease renewed
#   2  usage
#   3  no Vault token / Vault unreachable
#   4  Vault rejected the renew (e.g. lease not renewable / already revoked)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vault_common.sh
source "${SCRIPT_DIR}/vault_common.sh"

INCREMENT=""
LEASE_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --increment)   INCREMENT="$2"; shift 2 ;;
    --vault-token) VAULT_TOKEN_ARG="$2"; shift 2 ;;
    -h|--help)     sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)           echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$LEASE_ID" ]]; then LEASE_ID="$1"
      else echo "ERROR: unexpected argument: $1" >&2; exit 2; fi
      shift ;;
  esac
done

[[ -n "$LEASE_ID" ]] || { echo "ERROR: lease ID is required" >&2; exit 2; }
LEASE_ID="${LEASE_ID#/}"

body=$(L="$LEASE_ID" INC="$INCREMENT" python3 -c '
import json, os
b = {"lease_id": os.environ["L"]}
if os.environ["INC"]: b["increment"] = int(os.environ["INC"])
print(json.dumps(b))
')
body_tmp=$(vault_body_file "$body")

echo "Rotating lease '${LEASE_ID}' ..." >&2
vault_put "sys/leases/renew" "$body_tmp"
http="$VAULT_HTTP_CODE"
resp=$(cat "$VAULT_OUT")
rm -f "$body_tmp"

if [[ "$http" != "200" ]]; then
  echo "ERROR: Vault rejected lease renew (http=${http}): ${resp}" >&2
  vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"lease-renew\",\"lease\":\"${LEASE_ID}\",\"result\":\"error\",\"http\":${http:-0}}"
  exit 4
fi

new_ttl=$(printf '%s' "$resp" | vault_json_field /dev/stdin "data.ttl" \
  | python3 -c 'import sys; v=sys.stdin.read().strip(); print(v if v else "?")' 2>/dev/null || echo "?")
lease_id_resp=$(printf '%s' "$resp" | vault_json_field /dev/stdin "data.id" 2>/dev/null || echo "")
echo "OK: lease renewed. lease_id=${lease_id_resp:-${LEASE_ID}} ttl=${new_ttl}s" >&2
vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"lease-renew\",\"lease\":\"${LEASE_ID}\",\"result\":\"ok\",\"http\":${http:-0}}"
exit 0
