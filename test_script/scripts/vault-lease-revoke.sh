#!/usr/bin/env bash
# vault-lease-revoke.sh — immediately revoke a specific Vault lease.
#
# Cloud Admin tool. Use during incident response to invalidate a dynamic
# credential that has been exposed. The cloud-side credential is revoked by
# Vault's secrets engine (e.g. AWS access key deleted) at the same time as the
# lease is destroyed.
#
# Usage:
#   vault-lease-revoke.sh <lease-id>
#   vault-lease-revoke.sh aws/creds/ec2-admin/abc123...
#
# Options:
#   --vault-token <t>
#   --sync          wait for revoke to complete (default: async is fine for
#                   most engines; pass --sync to force /sys/leases/revoke which
#                   is synchronous)
#   -h, --help
#
# Exit codes:
#   0  lease revoked
#   2  usage
#   3  no Vault token / Vault unreachable
#   4  Vault rejected the revoke
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vault_common.sh
source "${SCRIPT_DIR}/vault_common.sh"

SYNC=0
LEASE_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sync)        SYNC=1; shift ;;
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

body=$(L="$LEASE_ID" python3 -c '
import json, os
print(json.dumps({"lease_id": os.environ["L"]}))
')
body_tmp=$(vault_body_file "$body")

# /sys/leases/revoke is synchronous; /sys/leases/revoke-prefix is for prefixes.
path="sys/leases/revoke"
echo "Revoking lease '${LEASE_ID}' (sync=${SYNC}) ..." >&2
vault_put "$path" "$body_tmp"
http="$VAULT_HTTP_CODE"
resp=$(cat "$VAULT_OUT")
rm -f "$body_tmp"

if [[ "$http" != "200" && "$http" != "204" ]]; then
  echo "ERROR: Vault rejected lease revoke (http=${http}): ${resp}" >&2
  vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"lease-revoke\",\"lease\":\"${LEASE_ID}\",\"result\":\"error\",\"http\":${http:-0}}"
  exit 4
fi

echo "OK: lease '${LEASE_ID}' revoked." >&2
vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"lease-revoke\",\"lease\":\"${LEASE_ID}\",\"result\":\"ok\",\"http\":${http:-0}}"
exit 0
