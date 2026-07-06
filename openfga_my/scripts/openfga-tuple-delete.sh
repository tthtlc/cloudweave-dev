#!/usr/bin/env bash
# openfga-tuple-delete.sh — delete one or more OpenFGA relationship tuples.
#
# Cloud Admin tool. Each triple is "<user> <relation> <object>", e.g.
#   openfga-tuple-delete.sh user:alice admin tenant:aws
#
# Idempotent: deleting a non-existent tuple is treated as success (OpenFGA
# returns 200/204; a 400 is also accepted). Validates syntax, deletes via
# /stores/{id}/write (deletes block), and emits a JSONL audit record per triple.
#
# Safety: a --confirm flag is required for deletes that target structural /
# infra tuples (parent/provider/tenant relations on backends, platform superadmin)
# which the reconciler does not own. Direct user→role tuples on tenant:/platform:
# are always allowed (they are the membership-derived set).
#
# Options:
#   --dry-run   validate + print the would-be delete payload, do not call FGA
#   --confirm   allow deletion of protected/structural tuples
#   --actor <s> override the audit actor (default $LIBCLOUD_USER)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=openfga_common.sh
source "${SCRIPT_DIR}/openfga_common.sh"

DRY_RUN=0
CONFIRM=0
ACTOR="${LIBCLOUD_USER}"
TRIPLES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift;;
    --confirm) CONFIRM=1; shift;;
    --actor) ACTOR="$2"; shift 2;;
    -h|--help) sed -n '2,18p' "$0"; exit 0;;
    --*) echo "unknown option: $1" >&2; exit 2;;
    *) TRIPLES+=("$1"); shift;;
  esac
done

[[ ${#TRIPLES[@]} -ge 3 && $(( ${#TRIPLES[@]} % 3 )) -eq 0 ]] || {
  echo "Usage: $0 [--dry-run] [--confirm] [--actor <u>] <user> <relation> <object> [...]" >&2
  exit 2
}

# Relations/objects the reconciler does NOT own (infra/structural). Deleting
# these can break can_connect/can_use/can_provision propagation; require --confirm.
PROTECTED_RELATIONS="parent provider tenant"
is_protected() {
  local r="$1" o="$2"
  for pr in $PROTECTED_RELATIONS; do [[ "$r" == "$pr" ]] && return 0; done
  [[ "$o" == platform:* ]] && return 0
  return 1
}

i=0
while [[ $i -lt ${#TRIPLES[@]} ]]; do
  u="${TRIPLES[$i]}"; r="${TRIPLES[$((i+1))]}"; o="${TRIPLES[$((i+2))]}"
  [[ "$u" == *:* ]] || { echo "invalid user: $u" >&2; exit 2; }
  [[ -n "$r" && "$r" =~ ^[a-z_]+$ ]] || { echo "invalid relation: $r" >&2; exit 2; }
  [[ "$o" == *:* ]] || { echo "invalid object: $o" >&2; exit 2; }
  if is_protected "$r" "$o" && [[ "$CONFIRM" -ne 1 ]]; then
    echo "REFUSING to delete protected tuple '${u} ${r} ${o}' (structural/infra)." >&2
    echo "Pass --confirm to override (breaks can_connect/can_use/can_provision propagation)." >&2
    exit 3
  fi
  i=$((i+3))
done

PAYLOAD=$(python3 - "${TRIPLES[@]}" <<'PY'
import json, os, sys
args = sys.argv[1:]
tk = [{"user":args[i],"relation":args[i+1],"object":args[i+2]} for i in range(0,len(args),3)]
print(json.dumps({"authorization_model_id": os.environ["FGA_MODEL_ID"],
                  "deletes": {"tuple_keys": tk}}, indent=2))
PY
)

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] would delete via /stores/${FGA_STORE_ID}/write:" >&2
  echo "$PAYLOAD" >&2
  i=0
  while [[ $i -lt ${#TRIPLES[@]} ]]; do
    u="${TRIPLES[$i]}"; r="${TRIPLES[$((i+1))]}"; o="${TRIPLES[$((i+2))]}"
    fga_audit "{\"ts\":\"$(fga_now)\",\"actor\":\"${ACTOR}\",\"action\":\"tuple-delete\",\"tuple\":{\"user\":\"${u}\",\"relation\":\"${r}\",\"object\":\"${o}\"},\"result\":\"dry-run\"}"
    i=$((i+3))
  done
  exit 0
fi

if fga_delete "${TRIPLES[@]}"; then
  i=0
  while [[ $i -lt ${#TRIPLES[@]} ]]; do
    u="${TRIPLES[$i]}"; r="${TRIPLES[$((i+1))]}"; o="${TRIPLES[$((i+2))]}"
    fga_audit "{\"ts\":\"$(fga_now)\",\"actor\":\"${ACTOR}\",\"action\":\"tuple-delete\",\"tuple\":{\"user\":\"${u}\",\"relation\":\"${r}\",\"object\":\"${o}\"},\"result\":\"ok\"}"
    echo "deleted: ${u} ${r} ${o}"
    i=$((i+3))
  done
else
  rc=$?
  i=0
  while [[ $i -lt ${#TRIPLES[@]} ]]; do
    u="${TRIPLES[$i]}"; r="${TRIPLES[$((i+1))]}"; o="${TRIPLES[$((i+2))]}"
    fga_audit "{\"ts\":\"$(fga_now)\",\"actor\":\"${ACTOR}\",\"action\":\"tuple-delete\",\"tuple\":{\"user\":\"${u}\",\"relation\":\"${r}\",\"object\":\"${o}\"},\"result\":\"error\",\"http\":\"${FGA_HTTP_CODE:-?}\"}"
    i=$((i+3))
  done
  exit $rc
fi
