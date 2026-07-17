#!/usr/bin/env bash
# lldap-group-create.sh
# =====================
# Create a new LLDAP group following the agreed naming convention
# (e.g. cloud-admin-aws, cloud-ro-gcp). Idempotent: if a group with the same
# displayName already exists, it is left untouched and the script exits 0.
#
# LLDAP groups are keyed by an integer id; the human name is the `displayName`.
# `createGroup(name: String!)` sets the displayName to the supplied name.
#
# Usage:
#   lldap-group-create.sh --name <group-name> [--force] [--dry-run]
#
# --force : create even if the name does not match the recommended convention.
#
# Naming convention enforced (unless --force): the role-prefix convention
#   <scope>-<role>-<provider>   e.g. cloud-admin-aws, cloud-ro-gcp
# where the first segment indicates the governance scope. The regex below is
# permissive on the tail so project-specific suffixes are allowed.
#
# Env (via scripts/lldap_common.sh):
#   LLDAP_URL, LLDAP_ADMIN_USER, LLDAP_LDAP_USER_PASS, LLDAP_AUDIT_LOG, LLDAP_ACTOR
#
# Exit codes:
#   0  group created, or already existed (idempotent)
#   2  input validation
#   3  LLDAP admin auth failed
#   4  GraphQL rejected createGroup
#   5  network / unexpected error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lldap_common.sh
source "${SCRIPT_DIR}/lldap_common.sh"

OPT_NAME=""; OPT_FORCE=0; OPT_DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)    OPT_NAME="$2"; shift 2 ;;
    --force)   OPT_FORCE=1; shift ;;
    --dry-run) OPT_DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "${OPT_NAME}" ]] || { echo "ERROR: --name is required" >&2; exit 2; }
# Basic charset: lowercase alnum, dash, underscore; 1..63 chars; start with alnum.
if ! [[ "${OPT_NAME}" =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]]; then
  echo "ERROR: --name must be lowercase, start with alnum, use only [a-z0-9._-]" >&2; exit 2
fi
# Recommended convention: <scope>-<role>-<provider-or-suffix> (at least 2 dashes).
if [[ "${OPT_FORCE}" == "0" ]]; then
  dashes=$(awk -v s="${OPT_NAME}" 'BEGIN{n=0; for(i=1;i<length(s);i++) if(substr(s,i,1)=="-") n++; print n}')
  if [[ "${dashes}" -lt 1 ]]; then
    echo "ERROR: --name '${OPT_NAME}' does not follow the <scope>-<role>-<provider> convention" >&2
    echo "       (expected at least one dash, e.g. cloud-admin-aws). Use --force to override." >&2
    exit 2
  fi
fi

lldap_login || exit 3

# Idempotency: skip if the group already exists.
existing="$(lldap_group_id_by_name "${OPT_NAME}")"
if [[ -n "${existing}" ]]; then
  echo "NOTE: group '${OPT_NAME}' already exists (id=${existing}); nothing to do." >&2
  lldap_audit "{\"ts\":\"$(lldap_now)\",\"event\":\"lldap_group_create\",\"actor\":\"${ACTOR}\",\"group\":\"${OPT_NAME}\",\"result\":\"already_exists\",\"group_id\":${existing}}"
  exit 0
fi

echo "Creating LLDAP group '${OPT_NAME}' ..." >&2
if [[ "${OPT_DRY_RUN}" == "1" ]]; then echo "DRY-RUN: would call createGroup" >&2; exit 0; fi

body=$(NAME="${OPT_NAME}" python3 -c '
import json, os
print(json.dumps({"query": "mutation { createGroup(name: \"%s\") { id displayName } }" % os.environ["NAME"]}))
')
out=$(mktemp); lldap_graphql "$body" "$out"; http="${LLDAP_HTTP_CODE}"
created_id=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
errs = d.get("errors")
if errs: print("ERR:" + " ".join(str(e.get("message","")) for e in errs)[:300])
else: print(((d.get("data") or {}).get("createGroup") or {}).get("id",""))
' "$out" 2>/dev/null || echo "ERR:parse")
rm -f "$out"

ts="$(lldap_now)"
if [[ "${created_id}" == ERR* || -z "${created_id}" ]]; then
  echo "ERROR: createGroup rejected: ${created_id:-<empty>} (http=${http})" >&2
  lldap_audit "{\"ts\":\"${ts}\",\"event\":\"lldap_group_create\",\"actor\":\"${ACTOR}\",\"group\":\"${OPT_NAME}\",\"result\":\"rejected\",\"http\":${http}}"
  [[ "${http}" =~ ^(2|3) ]] && exit 4 || exit 5
fi

echo "OK: created group '${OPT_NAME}' (id=${created_id})." >&2
lldap_audit "{\"ts\":\"${ts}\",\"event\":\"lldap_group_create\",\"actor\":\"${ACTOR}\",\"group\":\"${OPT_NAME}\",\"result\":\"created\",\"group_id\":${created_id},\"http\":${http}}"
exit 0
