#!/usr/bin/env bash
# list_users.sh — curl-based ListUsers: "which users have relation X with
# object Y?" (the API announced in
# https://openfga.dev/blog/list-users-announcement; OpenFGA >= v1.5.4, server
# started with --experimentals enable-list-users).
#
#   list_users.sh <relation> <type:id> [user_type] [options]
#   list_users.sh owner tenant:aws user
#
# Options:
#   --store-id ID    override FGA_STORE_ID from generated/fga.env
#   --model-id ID    override FGA_MODEL_ID from generated/fga.env
#   --raw            print the full raw API response body
#   --table          print one rendered user per line instead of a JSON array
#
# All authentication is extracted into ./fga_auth.sh (sourced below): it
# exports FGA_API_URL / FGA_STORE_ID / FGA_MODEL_ID (from generated/fga.env,
# env overrides win) and resolves the FGA_BEARER token from $FGA_API_TOKEN /
# $SUPERADMIN_JWT / ../generated/tokens/superadmin.jwt.
#
# Output: JSON array of user entries on stdout. Each entry is one of
#   {"object":   {"type": "user", "id": "alice"}}
#   {"userset":  {"type": "group", "id": "eng", "relation": "member"}}
#   {"typed_wildcard": {"type": "user"}}            (i.e. user:*)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fga_auth.sh
source "${SCRIPT_DIR}/fga_auth.sh"

RAW=0
TABLE=0
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --store-id) FGA_STORE_ID="$2"; shift 2;;
    --model-id) FGA_MODEL_ID="$2"; shift 2;;
    --raw)      RAW=1; shift;;
    --table)    TABLE=1; shift;;
    -h|--help)  sed -n '2,25p' "$0"; exit 0;;
    --*) echo "unknown option: $1" >&2; exit 2;;
    *) ARGS+=("$1"); shift;;
  esac
done

[[ ${#ARGS[@]} -ge 2 && ${#ARGS[@]} -le 3 ]] || {
  echo "Usage: $0 [--raw|--table] [--store-id ID] [--model-id ID] <relation> <type:id> [user_type]" >&2
  exit 2
}
REL="${ARGS[0]}"; OBJ="${ARGS[1]}"; UTYPE="${ARGS[2]:-user}"
[[ "$OBJ" == *:* && -n "$REL" && -n "$UTYPE" && -n "$FGA_STORE_ID" ]] || {
  echo "invalid args (need <relation> <type:id> and a store id)" >&2; exit 2
}
OTYPE="${OBJ%%:*}"; OID="${OBJ#*:}"

BODY=$(python3 - "$FGA_MODEL_ID" "$OTYPE" "$OID" "$REL" "$UTYPE" <<'PY'
import json, sys
model_id, otype, oid, rel, utype = sys.argv[1:6]
body = {"object": {"type": otype, "id": oid},
        "relation": rel,
        "user_filters": [{"type": utype}]}
if model_id:
    body["authorization_model_id"] = model_id
print(json.dumps(body))
PY
)

RESP=$(mktemp); trap 'rm -f "$RESP"' EXIT
HTTP=$(curl -sS -X POST "${FGA_API_URL}/stores/${FGA_STORE_ID}/list-users" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -H "Authorization: Bearer ${FGA_BEARER}" \
  --data-binary "${BODY}" -o "${RESP}" -w "%{http_code}") || HTTP="000"

if [[ "$HTTP" != "200" ]]; then
  echo "list-users: HTTP $HTTP" >&2
  cat "$RESP" >&2
  exit 4
fi

if [[ "$RAW" -eq 1 ]]; then
  cat "$RESP"; echo
  exit 0
fi

python3 - "$TABLE" "$RESP" <<'PY'
import json, sys
with open(sys.argv[2]) as f:
    users = json.load(f).get("users", [])
def render(u):
    if "object" in u:
        o = u["object"]; return f"{o.get('type')}:{o.get('id')}"
    if "userset" in u:
        s = u["userset"]; return f"{s.get('type')}:{s.get('id')}#{s.get('relation')}"
    if "typed_wildcard" in u:
        return f"{u['typed_wildcard'].get('type')}:*"
    return json.dumps(u)
if sys.argv[1] == "1":
    for u in users:
        print(render(u))
else:
    print(json.dumps(users))
PY
