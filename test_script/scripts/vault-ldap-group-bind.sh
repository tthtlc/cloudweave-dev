#!/usr/bin/env bash
# vault-ldap-group-bind.sh — bind a Vault ACL policy to an LLDAP group via the
# Vault LDAP auth method.
#
# Cloud Owner tool. Should be run whenever a new LLDAP group is created so that
# members of that group, when they authenticate to Vault through the LDAP auth
# method, receive the bound policies.
#
# Usage:
#   vault-ldap-group-bind.sh <lldap-group> <policy> [<policy> ...]
#   vault-ldap-group-bind.sh cloud-admin-aws cloud-admin-aws
#   vault-ldap-group-bind.sh cloud-ro-gcp gcp-readonly gcp-list-only
#
# Options:
#   --auth-path <p>    LDAP auth mount path (default: ldap)
#   --vault-token <t>  use this Vault token (else VAULT_ROOT_TOKEN/VAULT_TOKEN)
#   --dry-run          print the would-be request, do not POST
#   -h, --help
#
# Exit codes:
#   0  binding applied (idempotent)
#   2  usage / validation
#   3  no Vault token / Vault unreachable
#   4  Vault rejected the write
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vault_common.sh
source "${SCRIPT_DIR}/vault_common.sh"

AUTH_PATH="ldap"
DRY_RUN=0
GROUP=""
POLICIES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auth-path)   AUTH_PATH="$2"; shift 2 ;;
    --vault-token) VAULT_TOKEN_ARG="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)           echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$GROUP" ]]; then GROUP="$1"
      else POLICIES+=("$1"); fi
      shift ;;
  esac
done

[[ -n "$GROUP" ]] || { echo "ERROR: LLDAP group name is required" >&2; exit 2; }
[[ ${#POLICIES[@]} -ge 1 ]] || { echo "ERROR: at least one policy is required" >&2; exit 2; }
if ! [[ "$GROUP" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "ERROR: group name must match [a-zA-Z0-9._-]" >&2; exit 2
fi
if ! [[ "$AUTH_PATH" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "ERROR: auth path must match [a-zA-Z0-9._-]" >&2; exit 2
fi

# Vault LDAP group binding expects policies as a comma-separated string.
policies_csv="$(IFS=,; echo "${POLICIES[*]}")"
body_file=$(P="$policies_csv" python3 -c '
import json, os
print(json.dumps({"policies": os.environ["P"]}))
')
body_tmp=$(vault_body_file "$body_file")

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] would POST /auth/${AUTH_PATH}/groups/${GROUP} policies=${policies_csv}" >&2
  vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"ldap-group-bind\",\"group\":\"${GROUP}\",\"policies\":\"${policies_csv}\",\"auth_path\":\"${AUTH_PATH}\",\"result\":\"dry-run\"}"
  rm -f "$body_tmp"
  exit 0
fi

echo "Binding LLDAP group '${GROUP}' -> policies [${policies_csv}] at auth/${AUTH_PATH} ..." >&2
vault_post "auth/${AUTH_PATH}/groups/${GROUP}" "$body_tmp"
http="$VAULT_HTTP_CODE"
resp=$(cat "$VAULT_OUT")
rm -f "$body_tmp"

if [[ "$http" != "200" && "$http" != "204" ]]; then
  echo "ERROR: Vault rejected LDAP group binding (http=${http}): ${resp}" >&2
  vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"ldap-group-bind\",\"group\":\"${GROUP}\",\"policies\":\"${policies_csv}\",\"auth_path\":\"${AUTH_PATH}\",\"result\":\"error\",\"http\":${http:-0}}"
  exit 4
fi

# Read-back: confirm the binding round-trips.
vault_get "auth/${AUTH_PATH}/groups/${GROUP}"
read_body=$(cat "$VAULT_OUT")
read_policies=$(printf '%s' "$read_body" | vault_json_field /dev/stdin "data.policies")
echo "OK: '${GROUP}' bound to policies: ${read_policies:-${policies_csv}} (http=${http})." >&2
vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"ldap-group-bind\",\"group\":\"${GROUP}\",\"policies\":\"${policies_csv}\",\"auth_path\":\"${AUTH_PATH}\",\"result\":\"ok\",\"http\":${http:-0}}"
exit 0
