#!/usr/bin/env bash
# lldap-group-add-member.sh
# =========================
# Add an existing LLDAP user to a named LLDAP group (role). Emits a structured
# audit entry. After completion, triggers the OpenFGA tuple reconciler so the
# new membership is reflected as relationship tuples (idempotent: re-adding an
# existing member is a no-op).
#
# Usage:
#   lldap-group-add-member.sh --user <uid> --group <group-name> [--dry-run]
#
# Env (via scripts/lldap_common.sh):
#   LLDAP_URL, LLDAP_ADMIN_USER, LLDAP_LDAP_USER_PASS, LLDAP_AUDIT_LOG, LLDAP_ACTOR
#   LLDAP_RECONCILE_CMD  optional; command to run after a successful add
#                        (default: python3 scripts/openfga-tuple-reconcile.py)
#                        Set LLDAP_RECONCILE_CMD= (empty) to skip reconciliation.
#
# Exit codes:
#   0  member added (or already a member)
#   2  input validation / unknown user or group
#   3  LLDAP admin auth failed
#   4  GraphQL rejected the add
#   5  network / unexpected error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lldap_common.sh
source "${SCRIPT_DIR}/lldap_common.sh"

OPT_USER=""; OPT_GROUP=""; OPT_DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)     OPT_USER="$2"; shift 2 ;;
    --group)    OPT_GROUP="$2"; shift 2 ;;
    --dry-run)  OPT_DRY_RUN=1; shift ;;
    -h|--help)  sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "${OPT_USER}"  ]] || { echo "ERROR: --user is required" >&2; exit 2; }
[[ -n "${OPT_GROUP}" ]] || { echo "ERROR: --group is required" >&2; exit 2; }
if ! [[ "${OPT_USER}" =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]]; then
  echo "ERROR: --user must match LLDAP uid rules [a-z0-9._-]" >&2; exit 2
fi
if ! [[ "${OPT_GROUP}" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; then
  echo "ERROR: --group must match LLDAP group naming [a-z0-9._-]" >&2; exit 2
fi

lldap_login || exit 3

if ! lldap_user_exists "${OPT_USER}"; then
  echo "ERROR: user '${OPT_USER}' does not exist in LLDAP" >&2; exit 2
fi
gid="$(lldap_group_id_by_name "${OPT_GROUP}")"
if [[ -z "${gid}" ]]; then
  echo "ERROR: group '${OPT_GROUP}' does not exist in LLDAP" >&2; exit 2
fi

echo "Adding '${OPT_USER}' to group '${OPT_GROUP}' (id=${gid}) ..." >&2
if [[ "${OPT_DRY_RUN}" == "1" ]]; then echo "DRY-RUN: would call addUserToGroup" >&2; exit 0; fi

body=$(UID2="${OPT_USER}" GID="${gid}" python3 -c '
import json, os
print(json.dumps({"query": "mutation { addUserToGroup(userId: \"%s\", groupId: %s) { ok } }" % (os.environ["UID2"], os.environ["GID"])}))
')
out=$(mktemp); lldap_graphql "$body" "$out"; http="${LLDAP_HTTP_CODE}"
ok=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
errs = d.get("errors")
if errs:
    print("ERR:" + " ".join(str(e.get("message","")) for e in errs)[:300])
else:
    print(((d.get("data") or {}).get("addUserToGroup") or {}).get("ok"))
' "$out" 2>/dev/null || echo "ERR:parse")
rm -f "$out"

ts="$(lldap_now)"
if [[ "${ok}" == "True" ]]; then
  result="added"
elif [[ "${ok}" == ERR* ]]; then
  # LLDAP returns an error if the user is already a member; treat as already-member.
  if [[ "${ok}" == *"already"* ]] || [[ "${ok}" == *"UNIQUE"* ]] || [[ "${ok}" == *"duplicate"* ]]; then
    result="already_member"
  else
    echo "ERROR: addUserToGroup rejected: ${ok}" >&2
    lldap_audit "{\"ts\":\"${ts}\",\"event\":\"lldap_group_add_member\",\"actor\":\"${ACTOR}\",\"user\":\"${OPT_USER}\",\"group\":\"${OPT_GROUP}\",\"result\":\"rejected\",\"http\":${http}}"
    exit 4
  fi
else
  echo "ERROR: addUserToGroup returned unexpected result: '${ok}' (http=${http})" >&2
  exit 5
fi

echo "OK: ${result} — '${OPT_USER}' in '${OPT_GROUP}'." >&2
lldap_audit "{\"ts\":\"${ts}\",\"event\":\"lldap_group_add_member\",\"actor\":\"${ACTOR}\",\"user\":\"${OPT_USER}\",\"group\":\"${OPT_GROUP}\",\"result\":\"${result}\",\"http\":${http}}"

# Trigger the OpenFGA tuple reconciler so the new membership becomes tuples.
reconcile_cmd="${LLDAP_RECONCILE_CMD:-python3 ${SCRIPT_DIR}/openfga-tuple-reconcile.py}"
if [[ -n "${reconcile_cmd}" ]]; then
  echo "Triggering OpenFGA tuple reconciler: ${reconcile_cmd}" >&2
  if ! bash -lc "${reconcile_cmd}" >/dev/null 2>&1; then
    echo "WARN: reconciler command failed or not implemented yet (openfga-tuple-reconcile.py)." >&2
    echo "      The LLDAP membership is updated; tuples will sync on the next scheduled run." >&2
  fi
fi
exit 0
