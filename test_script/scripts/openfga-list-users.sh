#!/usr/bin/env bash
# openfga-list-users.sh — list all users who have a relation to an object.
#
#   openfga-list-users.sh <relation> <object> [user_type]
#   openfga-list-users.sh owner tenant:aws user
#
# Prints a JSON array of users on stdout. user_type defaults to "user".
# Options:
#   --table   print a newline-separated, unquoted list instead of JSON
#   --actor <s> audit actor (default $LIBCLOUD_USER)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=openfga_common.sh
source "${SCRIPT_DIR}/openfga_common.sh"

TABLE=0
ACTOR="${LIBCLOUD_USER}"
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --table) TABLE=1; shift;;
    --actor) ACTOR="$2"; shift 2;;
    -h|--help) sed -n '2,10p' "$0"; exit 0;;
    --*) echo "unknown option: $1" >&2; exit 2;;
    *) ARGS+=("$1"); shift;;
  esac
done

[[ ${#ARGS[@]} -ge 2 && ${#ARGS[@]} -le 3 ]] || { echo "Usage: $0 [--table] <relation> <object> [user_type]" >&2; exit 2; }
R="${ARGS[0]}"; O="${ARGS[1]}"; UTYPE="${ARGS[2]:-user}"
[[ "$O" == *:* && -n "$R" && -n "$UTYPE" ]] || { echo "invalid args" >&2; exit 2; }

OUT=$(fga_list_users "$R" "$O" "$UTYPE") || { echo "fga_list_users failed" >&2; exit 4; }
fga_audit "{\"ts\":\"$(fga_now)\",\"actor\":\"${ACTOR}\",\"action\":\"list-users\",\"relation\":\"${R}\",\"object\":\"${O}\",\"user_type\":\"${UTYPE}\",\"result\":\"ok\",\"count\":$(echo "$OUT" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')}"

if [[ "$TABLE" -eq 1 ]]; then
  echo "$OUT" | python3 -c '
import json, sys
for u in json.load(sys.stdin):
    o = u.get("object") or {}
    t, i = o.get("type",""), o.get("id","")
    print(f"{t}:{i}" if t and i else (i or t or u))
'
else
  echo "$OUT"
fi
