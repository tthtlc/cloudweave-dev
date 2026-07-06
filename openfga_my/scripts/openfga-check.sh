#!/usr/bin/env bash
# openfga-check.sh — single OpenFGA Check() call.
#
#   openfga-check.sh <user> <relation> <object>
#   openfga-check.sh user:aws-admin can_provision aws_region:aws
#
# Prints "allowed=true|false" and a one-line summary. Exit code:
#   0  allowed
#   1  denied
#   2  usage error
#   4  OpenFGA API error
#
# Options:
#   --json     print the raw {allowed, resolution} JSON instead of a summary
#   --context  optional contextual tuple(s) as extra triples (for ABAC/cond)
#   --actor <s> audit actor (default $LIBCLOUD_USER)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=openfga_common.sh
source "${SCRIPT_DIR}/openfga_common.sh"

JSON_OUT=0
ACTOR="${LIBCLOUD_USER}"
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON_OUT=1; shift;;
    --actor) ACTOR="$2"; shift 2;;
    -h|--help) sed -n '2,12p' "$0"; exit 0;;
    --*) echo "unknown option: $1" >&2; exit 2;;
    *) ARGS+=("$1"); shift;;
  esac
done

[[ ${#ARGS[@]} -eq 3 ]] || { echo "Usage: $0 [--json] <user> <relation> <object>" >&2; exit 2; }
U="${ARGS[0]}"; R="${ARGS[1]}"; O="${ARGS[2]}"
[[ "$U" == *:* && "$O" == *:* && -n "$R" ]] || { echo "invalid triple" >&2; exit 2; }

if fga_check "$U" "$R" "$O" >/tmp/fga_check_out 2>/tmp/fga_check_err; then
  ALLOWED=true; RC=0
else
  rc=$?
  if [[ -s /tmp/fga_check_err && "$(cat /tmp/fga_check_err)" == "fga_check: HTTP "* ]]; then
    fga_audit "{\"ts\":\"$(fga_now)\",\"actor\":\"${ACTOR}\",\"action\":\"check\",\"tuple\":{\"user\":\"${U}\",\"relation\":\"${R}\",\"object\":\"${O}\"},\"result\":\"error\",\"http\":\"$(cat /tmp/fga_check_err)\"}"
    cat /tmp/fga_check_err >&2; exit 4
  fi
  ALLOWED=false; RC=1
fi
RESULT=$(cat /tmp/fga_check_out)  # "allowed=true" or "allowed=false"
rm -f /tmp/fga_check_out /tmp/fga_check_err

fga_audit "{\"ts\":\"$(fga_now)\",\"actor\":\"${ACTOR}\",\"action\":\"check\",\"tuple\":{\"user\":\"${U}\",\"relation\":\"${R}\",\"object\":\"${O}\"},\"result\":\"${ALLOWED}\"}"

if [[ "$JSON_OUT" -eq 1 ]]; then
  echo "{\"user\":\"${U}\",\"relation\":\"${R}\",\"object\":\"${O}\",\"allowed\":${ALLOWED}}"
else
  echo "Check ${U} ${R} ${O} -> allowed=${ALLOWED}"
fi
exit $RC
