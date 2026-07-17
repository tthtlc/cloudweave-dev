#!/usr/bin/env bash
# vault-dynamic-cred-request.sh — manually request a dynamic credential from
# a Vault cloud secrets engine for a one-off operation.
#
# Cloud Admin tool. The credential is printed once to stdout (as JSON) and is
# time-limited per the role's TTL. It is the caller's responsibility to use the
# credential before it expires and to revoke the lease when done
# (vault-lease-revoke.sh using the returned lease_id).
#
# Usage:
#   vault-dynamic-cred-request.sh <mount> <role>
#   vault-dynamic-cred-request.sh aws ec2-admin
#   vault-dynamic-cred-request.sh gcp gcs-admin
#
# Options:
#   --vault-token <t>
#   --renewable     (informational; the role's config controls renewability)
#   -h, --help
#
# Exit codes:
#   0  credential issued (JSON printed to stdout)
#   2  usage
#   3  no Vault token / Vault unreachable
#   4  Vault rejected the credential request
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vault_common.sh
source "${SCRIPT_DIR}/vault_common.sh"

MOUNT=""
ROLE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault-token) VAULT_TOKEN_ARG="$2"; shift 2 ;;
    -h|--help)     sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)           echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$MOUNT" ]]; then MOUNT="$1"
      elif [[ -z "$ROLE" ]]; then ROLE="$1"
      else echo "ERROR: unexpected argument: $1" >&2; exit 2; fi
      shift ;;
  esac
done

[[ -n "$MOUNT" ]] || { echo "ERROR: mount is required" >&2; exit 2; }
[[ -n "$ROLE" ]]  || { echo "ERROR: role is required" >&2; exit 2; }
MOUNT="${MOUNT%/}"
if ! [[ "$MOUNT" =~ ^[a-zA-Z0-9._/-]+$ && "$ROLE" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "ERROR: mount/role contains invalid characters" >&2; exit 2
fi

echo "Requesting dynamic credential from ${MOUNT}/creds/${ROLE} ..." >&2
vault_get "${MOUNT}/creds/${ROLE}"
http="$VAULT_HTTP_CODE"
resp=$(cat "$VAULT_OUT")

if [[ "$http" != "200" ]]; then
  echo "ERROR: Vault rejected credential request (http=${http}): ${resp}" >&2
  vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"dynamic-cred-request\",\"mount\":\"${MOUNT}\",\"role\":\"${ROLE}\",\"result\":\"error\",\"http\":${http:-0}}"
  exit 4
fi

lease_id=$(printf '%s' "$resp" | vault_json_field /dev/stdin "lease_id" 2>/dev/null || echo "")
echo "OK: credential issued (lease_id=${lease_id:-?}). Revoke with: vault-lease-revoke.sh '${lease_id}'" >&2
vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"dynamic-cred-request\",\"mount\":\"${MOUNT}\",\"role\":\"${ROLE}\",\"lease\":\"${lease_id}\",\"result\":\"ok\",\"http\":${http:-0}}"

# Print the credential body to stdout (caller captures it). Redact nothing here
# — the caller explicitly asked for the credential. The audit log records the
# lease id, not the secret material.
printf '%s\n' "$resp"
exit 0
