#!/usr/bin/env bash
# lldap-user-list-groups.sh
# =========================
# List all groups an LLDAP user belongs to. Used during access review or to
# diagnose unexpected permissions. Output is JSON (default) or a human-readable
# table.
#
# Usage:
#   lldap-user-list-groups.sh --username <uid> [--format json|table]
#
# Env (via scripts/lldap_common.sh):
#   LLDAP_URL, LLDAP_ADMIN_USER, LLDAP_LDAP_USER_PASS
#
# Exit codes:
#   0  groups listed (user may belong to none)
#   2  input validation / unknown user
#   3  LLDAP admin auth failed
#   5  network / unexpected error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lldap_common.sh
source "${SCRIPT_DIR}/lldap_common.sh"

OPT_USERNAME=""; OPT_FORMAT="json"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --username) OPT_USERNAME="$2"; shift 2 ;;
    --format)   OPT_FORMAT="$2"; shift 2 ;;
    -h|--help)  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "${OPT_USERNAME}" ]] || { echo "ERROR: --username is required" >&2; exit 2; }
if ! [[ "${OPT_USERNAME}" =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]]; then
  echo "ERROR: --username must match LLDAP uid rules [a-z0-9._-]" >&2; exit 2
fi
case "${OPT_FORMAT}" in
  json|table) ;;
  *) echo "ERROR: --format must be json or table" >&2; exit 2 ;;
esac

lldap_login || exit 3

if ! lldap_user_exists "${OPT_USERNAME}"; then
  echo "ERROR: user '${OPT_USERNAME}' does not exist in LLDAP" >&2; exit 2
fi

body=$(LLDAP_UID="${OPT_USERNAME}" python3 -c '
import json, os
print(json.dumps({"query": "{ user(userId: \"%s\") { id email displayName groups { id displayName } } }" % os.environ["LLDAP_UID"]}))
')
out=$(mktemp); lldap_graphql "$body" "$out"; http="${LLDAP_HTTP_CODE}"
python3 - "$out" "${OPT_FORMAT}" "${OPT_USERNAME}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
u = (d.get("data") or {}).get("user") or {}
fmt, uname = sys.argv[2], sys.argv[3]
groups = u.get("groups") or []
if fmt == "json":
    print(json.dumps({"user": uname, "email": u.get("email"), "count": len(groups),
                      "groups": groups}, indent=2))
else:
    print(f"User: {uname} ({u.get('email','')})  groups={len(groups)}")
    print(f"{'GROUP_ID':<10} GROUP NAME")
    for g in groups:
        print(f"{g.get('id',''):<10} {g.get('displayName','')}")
PY
rm -f "$out"

if [[ "${http}" =~ ^2 ]]; then exit 0; else echo "ERROR: GraphQL query http=${http}" >&2; exit 5; fi
