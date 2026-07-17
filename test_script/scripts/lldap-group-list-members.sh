#!/usr/bin/env bash
# lldap-group-list-members.sh
# ===========================
# List all members of a given LLDAP group. Used for access reviews. Output is
# JSON (default, for pipeline use) or a human-readable table.
#
# Usage:
#   lldap-group-list-members.sh --group <group-name> [--format json|table]
#
# Env (via scripts/lldap_common.sh):
#   LLDAP_URL, LLDAP_ADMIN_USER, LLDAP_LDAP_USER_PASS
#
# Exit codes:
#   0  members listed (group may be empty)
#   2  input validation / unknown group
#   3  LLDAP admin auth failed
#   5  network / unexpected error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lldap_common.sh
source "${SCRIPT_DIR}/lldap_common.sh"

OPT_GROUP=""; OPT_FORMAT="json"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --group)  OPT_GROUP="$2"; shift 2 ;;
    --format) OPT_FORMAT="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "${OPT_GROUP}" ]] || { echo "ERROR: --group is required" >&2; exit 2; }
case "${OPT_FORMAT}" in
  json|table) ;;
  *) echo "ERROR: --format must be json or table" >&2; exit 2 ;;
esac

lldap_login || exit 3

gid="$(lldap_group_id_by_name "${OPT_GROUP}")"
if [[ -z "${gid}" ]]; then
  echo "ERROR: group '${OPT_GROUP}' does not exist in LLDAP" >&2; exit 2
fi

body=$(GID="${gid}" python3 -c '
import json, os
print(json.dumps({"query": "{ group(groupId: %s) { id displayName users { id email displayName } } }" % os.environ["GID"]}))
')
out=$(mktemp); lldap_graphql "$body" "$out"; http="${LLDAP_HTTP_CODE}"
python3 - "$out" "${OPT_FORMAT}" "${OPT_GROUP}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
g = (d.get("data") or {}).get("group") or {}
fmt, gname = sys.argv[2], sys.argv[3]
members = g.get("users") or []
if fmt == "json":
    print(json.dumps({"group": gname, "group_id": g.get("id"), "count": len(members),
                      "members": members}, indent=2))
else:
    print(f"Group: {gname} (id={g.get('id')})  members={len(members)}")
    print(f"{'USERNAME':<24} {'EMAIL':<32} DISPLAY NAME")
    for m in members:
        print(f"{m.get('id',''):<24} {m.get('email',''):<32} {m.get('displayName','')}")
PY
rm -f "$out"

if [[ "${http}" =~ ^2 ]]; then exit 0; else echo "ERROR: GraphQL query http=${http}" >&2; exit 5; fi
