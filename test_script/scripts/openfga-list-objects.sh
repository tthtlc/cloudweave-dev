#!/usr/bin/env bash
# openfga-list-objects.sh — list all objects of a type that a user has a relation to.
#
#   openfga-list-objects.sh <user> <relation> <type>
#   openfga-list-objects.sh user:aws-admin can_provision aws_region
#
# Prints a JSON array of object ids (e.g. ["aws_region:aws"]) on stdout.
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

[[ ${#ARGS[@]} -eq 3 ]] || { echo "Usage: $0 [--table] <user> <relation> <type>" >&2; exit 2; }
U="${ARGS[0]}"; R="${ARGS[1]}"; T="${ARGS[2]}"
[[ "$U" == *:* && -n "$R" && -n "$T" ]] || { echo "invalid args" >&2; exit 2; }

OUT=$(fga_list_objects "$U" "$R" "$T") || { echo "fga_list_objects failed" >&2; exit 4; }
fga_audit "{\"ts\":\"$(fga_now)\",\"actor\":\"${ACTOR}\",\"action\":\"list-objects\",\"user\":\"${U}\",\"relation\":\"${R}\",\"type\":\"${T}\",\"result\":\"ok\",\"count\":$(echo "$OUT" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')}"

if [[ "$TABLE" -eq 1 ]]; then
  echo "$OUT" | python3 -c 'import json,sys;[print(o) for o in json.load(sys.stdin)]'
else
  echo "$OUT"
fi
