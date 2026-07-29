#!/usr/bin/env bash
# lldap-user-list.sh
# ==================
# List all existing LLDAP users. Output is JSON (default, for pipeline use) or a
# human-readable table.
#
# Usage:
#   lldap-user-list.sh [--format json|table] [--group <group-name>]
#
# Env (via scripts/lldap_common.sh):
#   LLDAP_URL, LLDAP_ADMIN_USER, LLDAP_LDAP_USER_PASS
#
# Exit codes:
#   0  users listed (catalog may be empty)
#   2  input validation / unknown group
#   3  LLDAP admin auth failed
#   5  network / unexpected error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lldap_common.sh
source "${SCRIPT_DIR}/lldap_common.sh"

OPT_FORMAT="json"
OPT_GROUP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --format) OPT_FORMAT="$2"; shift 2 ;;
    --group)  OPT_GROUP="$2";  shift 2 ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "${OPT_FORMAT}" in
  json|table) ;;
  *) echo "ERROR: --format must be json or table" >&2; exit 2 ;;
esac

lldap_login || exit 3

# If --group is given, resolve the group id and query users via the group edge.
# Otherwise list every user via the top-level `users` query.
if [[ -n "${OPT_GROUP}" ]]; then
  gid="$(lldap_group_id_by_name "${OPT_GROUP}")"
  if [[ -z "${gid}" ]]; then
    echo "ERROR: group '${OPT_GROUP}' does not exist in LLDAP" >&2; exit 2
  fi
  body=$(GID="${gid}" python3 -c '
import json, os
print(json.dumps({"query": "{ group(groupId: %s) { id displayName users { id email displayName firstName lastName creationDate } } }" % os.environ["GID"]}))
')
else
  body=$(python3 -c '
import json
print(json.dumps({"query": "{ users { id email displayName firstName lastName creationDate } }"}))
')
fi

out=$(mktemp); lldap_graphql "$body" "$out"; http="${LLDAP_HTTP_CODE}"

python3 - "$out" "${OPT_FORMAT}" "${OPT_GROUP:-}" <<'PY'
import json, sys

d = json.load(open(sys.argv[1]))
fmt   = sys.argv[2]
group = sys.argv[3]  # empty string when no --group was given

users = []
if group:
    g = (d.get("data") or {}).get("group") or {}
    users = g.get("users") or []
    label = f"group={group} (id={g.get('id')})"
else:
    users = (d.get("data") or {}).get("users") or []
    label = "all"

if fmt == "json":
    print(json.dumps({"scope": label, "count": len(users), "users": users}, indent=2))
else:
    print(f"Scope: {label}  users={len(users)}")
    if not users:
        exit(0)
    print(f"{'USERNAME':<24} {'EMAIL':<36} {'DISPLAY NAME':<28} {'FIRST':<16} {'LAST':<16} CREATED")
    for u in users:
        cdate = (u.get("creationDate") or "")[:10]
        print(f"{u.get('id',''):<24} {u.get('email',''):<36} {u.get('displayName',''):<28} "
              f"{u.get('firstName',''):<16} {u.get('lastName',''):<16} {cdate}")
PY
rm -f "$out"

if [[ "${http}" =~ ^2 ]]; then exit 0; else echo "ERROR: GraphQL query http=${http}" >&2; exit 5; fi
