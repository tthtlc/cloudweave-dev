#!/usr/bin/env bash
# lldap-user-offboard.sh
# ======================
# Disable an LLDAP user account and remove them from all groups. Intended as
# step 1 of the full offboarding chain (chain-offboard-user.sh); the OpenFGA
# tuple cleanup and Vault lease revocation happen in later steps.
#
# LLDAP has no native "disabled" flag on User/UpdateUserInput in this version,
# so "disable" is implemented as: (1) remove the user from every group, and
# (2) scramble the account password to a random unknown value so the user can
# no longer authenticate. The account itself is NOT deleted (so audit trails
# and the uid are retained). Re-enable requires a password reset
# (lldap-user-password-reset.sh) plus re-adding groups.
#
# Usage:
#   lldap-user-offboard.sh --username <uid> [--keep-password] [--dry-run]
#
# --keep-password : only remove group memberships; do NOT scramble the password
#                   (use when the caller will reset the password themselves).
#
# Env (via scripts/lldap_common.sh -> .env / ../lldap/.env):
#   LLDAP_URL, LLDAP_ADMIN_USER, LLDAP_LDAP_USER_PASS, LLDAP_BASE_DN,
#   LLDAP_LDAP_HOST, LLDAP_LDAP_PORT, LLDAP_AUDIT_LOG, LLDAP_ACTOR
#
# Exit codes:
#   0  user offboarded (groups removed; password scrambled unless --keep-password)
#   2  input validation / missing user
#   3  LLDAP admin auth failed
#   4  GraphQL rejected an operation
#   5  network / unexpected error
#   6  groups removed but password scramble failed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lldap_common.sh
source "${SCRIPT_DIR}/lldap_common.sh"

OPT_USERNAME=""
OPT_KEEP_PASSWORD=0
OPT_DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --username)      OPT_USERNAME="$2"; shift 2 ;;
    --keep-password) OPT_KEEP_PASSWORD=1; shift ;;
    --dry-run)       OPT_DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "${OPT_USERNAME}" ]] || { echo "ERROR: --username is required" >&2; exit 2; }
if ! [[ "${OPT_USERNAME}" =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]]; then
  echo "ERROR: username must match LLDAP uid rules [a-z0-9._-]" >&2; exit 2
fi

lldap_login || exit 3

# Refuse to offboard the LLDAP directory admin (it would lock the admin out).
if [[ "${OPT_USERNAME}" == "${LLDAP_ADMIN_USER}" ]]; then
  echo "ERROR: refusing to offboard the LLDAP directory admin '${OPT_USERNAME}'" >&2
  exit 2
fi

if ! lldap_user_exists "${OPT_USERNAME}"; then
  echo "ERROR: user '${OPT_USERNAME}' does not exist in LLDAP" >&2
  exit 2
fi

# Fetch the user's current groups.
body=$(LLDAP_UID="${OPT_USERNAME}" python3 -c '
import json, os
print(json.dumps({"query": "{ user(userId: \"%s\") { groups { id displayName } } }" % os.environ["LLDAP_UID"]}))
')
out=$(mktemp); lldap_graphql "$body" "$out"; http="${LLDAP_HTTP_CODE}"
groups_json=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
gs = (d.get("data") or {}).get("user", {}).get("groups") or []
print(json.dumps(gs))
' "$out" 2>/dev/null || echo "[]")
rm -f "$out"

group_count=$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' <<<"${groups_json}")
echo "User '${OPT_USERNAME}' is in ${group_count} group(s)." >&2

if [[ "${OPT_DRY_RUN}" == "1" ]]; then
  echo "DRY-RUN: would remove from ${group_count} group(s) and" \
    "$( [[ "${OPT_KEEP_PASSWORD}" == "1" ]] && echo "keep password" || echo "scramble password" )" >&2
  echo "${groups_json}" | python3 -m json.tool >&2
  exit 0
fi

# Remove the user from each group.
removed=0; failed=0
while IFS=$'\t' read -r gid gname; do
  [[ -z "${gid}" ]] && continue
  echo "  removing from group '${gname}' (id=${gid}) ..." >&2
  rb=$(UID2="${OPT_USERNAME}" GID="${gid}" python3 -c '
import json, os
print(json.dumps({"query": "mutation { removeUserFromGroup(userId: \"%s\", groupId: %s) { ok } }" % (os.environ["UID2"], os.environ["GID"])}))
')
  rout=$(mktemp); lldap_graphql "$rb" "$rout"; rhttp="${LLDAP_HTTP_CODE}"
  ok=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
r = (d.get("data") or {}).get("removeUserFromGroup") or {}
print(r.get("ok"))
' "$rout" 2>/dev/null || echo "")
  rm -f "$rout"
  if [[ "${ok}" == "True" ]]; then removed=$((removed+1)); else failed=$((failed+1)); echo "  WARN: remove from ${gname} failed (http=${rhttp})" >&2; fi
done < <(python3 -c '
import json, sys
for g in json.load(sys.stdin):
    print(f"{g[\"id\"]}\t{g[\"displayName\"]}")
' <<<"${groups_json}")

# Scramble the password (the de-facto "disable").
scramble_status="skipped"
if [[ "${OPT_KEEP_PASSWORD}" == "0" ]]; then
  echo "Scrambling password for '${OPT_USERNAME}' (locking account) ..." >&2
  new_pw=$(python3 -c 'import secrets, string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(32)))')
  user_dn="uid=${OPT_USERNAME},ou=people,${LLDAP_BASE_DN}"
  if LLDAP_LDAP_HOST="${LLDAP_LDAP_HOST}" LLDAP_LDAP_PORT="${LLDAP_LDAP_PORT}" \
     LLDAP_BIND_DN="${LLDAP_BIND_DN}" LLDAP_BIND_PW="${LLDAP_ADMIN_PW}" \
     LLDAP_USER_DN="${user_dn}" LLDAP_NEW_PW="${new_pw}" \
     python3 "${SCRIPT_DIR}/lldap_set_password.py" >/dev/null 2>&1; then
    scramble_status="scrambled"
  else
    scramble_status="failed"
  fi
fi

ts="$(lldap_now)"
if [[ "${scramble_status}" == "failed" ]]; then
  echo "ERROR: removed ${removed} group(s) but password scramble FAILED for '${OPT_USERNAME}'." >&2
  lldap_audit "{\"ts\":\"${ts}\",\"event\":\"lldap_user_offboard\",\"actor\":\"${ACTOR}\",\"username\":\"${OPT_USERNAME}\",\"groups_removed\":${removed},\"groups_failed\":${failed},\"password\":\"scramble_failed\",\"result\":\"partial\"}"
  exit 6
fi

result="offboarded"
[[ "${failed}" -gt 0 ]] && result="partial"
echo "OK: ${result} '${OPT_USERNAME}': removed ${removed} group(s), password=${scramble_status}." >&2
lldap_audit "{\"ts\":\"${ts}\",\"event\":\"lldap_user_offboard\",\"actor\":\"${ACTOR}\",\"username\":\"${OPT_USERNAME}\",\"groups_removed\":${removed},\"groups_failed\":${failed},\"password\":\"${scramble_status}\",\"result\":\"${result}\"}"
exit 0
