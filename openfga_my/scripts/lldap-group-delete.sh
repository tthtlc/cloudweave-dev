#!/usr/bin/env bash
# lldap-group-delete.sh
# =====================
# Delete an LLDAP group after verifying it has zero members. Prevents
# accidental deletion of populated groups: if the group has any members the
# script refuses unless --force is supplied (and --force still requires the
# caller to type the group name for confirmation).
#
# Refuses to delete LLDAP's built-in management groups (lldap_admin,
# lldap_password_manager, lldap_strict_readonly) even with --force — those are
# infrastructure and must not be removed by an admin script.
#
# Usage:
#   lldap-group-delete.sh --name <group-name> [--force] [--dry-run]
#
# Env (via scripts/lldap_common.sh):
#   LLDAP_URL, LLDAP_ADMIN_USER, LLDAP_LDAP_USER_PASS, LLDAP_AUDIT_LOG, LLDAP_ACTOR
#
# Exit codes:
#   0  group deleted (or did not exist)
#   2  input validation / refusal (populated or protected group)
#   3  LLDAP admin auth failed
#   4  GraphQL rejected deleteGroup
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
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "${OPT_NAME}" ]] || { echo "ERROR: --name is required" >&2; exit 2; }
if ! [[ "${OPT_NAME}" =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]]; then
  echo "ERROR: --name must match LLDAP group naming [a-z0-9._-]" >&2; exit 2
fi

# Protect LLDAP's built-in management groups.
case "${OPT_NAME}" in
  lldap_admin|lldap_password_manager|lldap_strict_readonly)
    echo "ERROR: refusing to delete built-in LLDAP management group '${OPT_NAME}'" >&2; exit 2 ;;
esac

lldap_login || exit 3

gid="$(lldap_group_id_by_name "${OPT_NAME}")"
if [[ -z "${gid}" ]]; then
  echo "NOTE: group '${OPT_NAME}' does not exist; nothing to do." >&2
  lldap_audit "{\"ts\":\"$(lldap_now)\",\"event\":\"lldap_group_delete\",\"actor\":\"${ACTOR}\",\"group\":\"${OPT_NAME}\",\"result\":\"not_found\"}"
  exit 0
fi

# Fetch members to enforce the zero-members guard.
body=$(GID="${gid}" python3 -c '
import json, os
print(json.dumps({"query": "{ group(groupId: %s) { id displayName users { id } } }" % os.environ["GID"]}))
')
out=$(mktemp); lldap_graphql "$body" "$out"; http="${LLDAP_HTTP_CODE}"
member_count=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
us = (d.get("data") or {}).get("group", {}).get("users") or []
print(len(us))
' "$out" 2>/dev/null || echo 0)
rm -f "$out"

if [[ "${member_count}" -gt 0 ]]; then
  if [[ "${OPT_FORCE}" == "0" ]]; then
    echo "ERROR: group '${OPT_NAME}' has ${member_count} member(s); refusing to delete." >&2
    echo "       Remove all members first (lldap-group-remove-member.sh), or re-run with --force" >&2
    echo "       (you will be asked to type the group name to confirm)." >&2
    lldap_audit "{\"ts\":\"$(lldap_now)\",\"event\":\"lldap_group_delete\",\"actor\":\"${ACTOR}\",\"group\":\"${OPT_NAME}\",\"result\":\"refused_populated\",\"members\":${member_count}}"
    exit 2
  fi
  echo "WARNING: group '${OPT_NAME}' has ${member_count} member(s); --force in effect." >&2
  printf "Type the group name '%s' to confirm forced deletion: " "${OPT_NAME}" >&2
  read -r confirm
  if [[ "${confirm}" != "${OPT_NAME}" ]]; then
    echo "ERROR: confirmation did not match; aborting." >&2
    exit 2
  fi
fi

echo "Deleting LLDAP group '${OPT_NAME}' (id=${gid}) ..." >&2
if [[ "${OPT_DRY_RUN}" == "1" ]]; then echo "DRY-RUN: would call deleteGroup" >&2; exit 0; fi

body=$(GID="${gid}" python3 -c '
import json, os
print(json.dumps({"query": "mutation { deleteGroup(groupId: %s) { ok } }" % os.environ["GID"]}))
')
out=$(mktemp); lldap_graphql "$body" "$out"; http="${LLDAP_HTTP_CODE}"
ok=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
errs = d.get("errors")
if errs: print("ERR:" + " ".join(str(e.get("message","")) for e in errs)[:300])
else: print(((d.get("data") or {}).get("deleteGroup") or {}).get("ok"))
' "$out" 2>/dev/null || echo "ERR:parse")
rm -f "$out"

ts="$(lldap_now)"
if [[ "${ok}" != "True" ]]; then
  echo "ERROR: deleteGroup rejected: ${ok} (http=${http})" >&2
  lldap_audit "{\"ts\":\"${ts}\",\"event\":\"lldap_group_delete\",\"actor\":\"${ACTOR}\",\"group\":\"${OPT_NAME}\",\"group_id\":${gid},\"result\":\"rejected\",\"http\":${http}}"
  [[ "${http}" =~ ^(2|3) ]] && exit 4 || exit 5
fi

echo "OK: deleted group '${OPT_NAME}' (id=${gid})." >&2
lldap_audit "{\"ts\":\"${ts}\",\"event\":\"lldap_group_delete\",\"actor\":\"${ACTOR}\",\"group\":\"${OPT_NAME}\",\"group_id\":${gid},\"members_at_delete\":${member_count},\"result\":\"deleted\",\"http\":${http}}"
exit 0
