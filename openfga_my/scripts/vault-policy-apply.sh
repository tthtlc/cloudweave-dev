#!/usr/bin/env bash
# vault-policy-apply.sh — apply a Vault ACL policy from an HCL file.
#
# Cloud Owner tool. Idempotent: re-applying the same policy overwrites it with
# the current HCL content. Intended to be called from a GitOps pipeline that
# renders the HCL, but also runnable ad hoc.
#
# Usage:
#   vault-policy-apply.sh <name> <policy-file.hcl>
#   vault-policy-apply.sh cloud-admin-aws policy-files/cloud-admin-aws.hcl
#
# Options:
#   --vault-token <t>  use this Vault token (else VAULT_ROOT_TOKEN/VAULT_TOKEN)
#   --dry-run          validate file + print the would-be request, do not PUT
#   -h, --help
#
# Exit codes:
#   0  policy applied (or dry-run ok)
#   2  usage / missing file
#   3  no Vault token / Vault unreachable
#   4  Vault rejected the PUT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vault_common.sh
source "${SCRIPT_DIR}/vault_common.sh"

DRY_RUN=0
NAME=""
POLICY_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault-token) VAULT_TOKEN_ARG="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)
      if [[ -z "$NAME" ]]; then NAME="$1"
      elif [[ -z "$POLICY_FILE" ]]; then POLICY_FILE="$1"
      else echo "ERROR: unexpected argument: $1" >&2; exit 2; fi
      shift ;;
  esac
done

[[ -n "$NAME" ]] || { echo "ERROR: policy name is required" >&2; exit 2; }
[[ -n "$POLICY_FILE" ]] || { echo "ERROR: policy HCL file is required" >&2; exit 2; }
[[ -f "$POLICY_FILE" ]] || { echo "ERROR: policy file not found: $POLICY_FILE" >&2; exit 2; }

if ! [[ "$NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "ERROR: policy name must match [a-zA-Z0-9._-]" >&2; exit 2
fi

POLICY_HCL="$(cat "$POLICY_FILE")"

body_file=$(HCL="$POLICY_HCL" python3 -c '
import json, os
print(json.dumps({"policy": os.environ["HCL"]}))
')
body_tmp=$(vault_body_file "$body_file")

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] would PUT /sys/policies/acl/${NAME} with HCL from ${POLICY_FILE} (${#POLICY_HCL} bytes)" >&2
  vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"policy-apply\",\"policy\":\"${NAME}\",\"file\":\"${POLICY_FILE}\",\"result\":\"dry-run\"}"
  rm -f "$body_tmp"
  exit 0
fi

echo "Applying Vault ACL policy '${NAME}' from ${POLICY_FILE} ..." >&2
vault_put "sys/policies/acl/${NAME}" "$body_tmp"
http="$VAULT_HTTP_CODE"
resp=$(cat "$VAULT_OUT")
rm -f "$body_tmp"

if [[ "$http" != "200" && "$http" != "204" ]]; then
  echo "ERROR: Vault rejected policy PUT (http=${http}): ${resp}" >&2
  vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"policy-apply\",\"policy\":\"${NAME}\",\"result\":\"error\",\"http\":${http:-0}}"
  exit 4
fi

# Read-back to confirm.
vault_get "sys/policies/acl/${NAME}"
read_body=$(cat "$VAULT_OUT")
read_http="$VAULT_HTTP_CODE"
if [[ "$read_http" == "200" ]]; then
  echo "OK: policy '${NAME}' applied and read-back verified (http=${read_http})." >&2
else
  echo "WARN: policy '${NAME}' PUT returned ${http} but read-back returned ${read_http}." >&2
fi
vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"policy-apply\",\"policy\":\"${NAME}\",\"file\":\"${POLICY_FILE}\",\"result\":\"ok\",\"http\":${http:-0}}"
exit 0
