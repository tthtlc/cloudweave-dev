#!/usr/bin/env bash
# openfga-tuple-write.sh — write one or more OpenFGA relationship tuples.
#
# Cloud Admin tool. Each triple is "<user> <relation> <object>", e.g.
#   openfga-tuple-write.sh user:alice admin tenant:aws
#   openfga-tuple-write.sh user:bob viewer tenant:nutanix user:carol owner tenant:aws
#
# Idempotent: re-writing an existing tuple is a no-op (HTTP 200/204, or a 400
# "already exists" treated as success). Validates the user/relation/object
# syntax, writes via /stores/{id}/write, and emits a JSONL audit record per
# triple to generated/openfga_audit.log.
#
# Options:
#   --dry-run   validate + print the would-be write payload, do not call FGA
#   --actor <s> override the audit actor (default $LIBCLOUD_USER)
#   -h, --help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=openfga_common.sh
source "${SCRIPT_DIR}/openfga_common.sh"

DRY_RUN=0
ACTOR="${LIBCLOUD_USER}"
TRIPLES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift;;
    --actor) ACTOR="$2"; shift 2;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0;;
    --*) echo "unknown option: $1" >&2; exit 2;;
    *) TRIPLES+=("$1"); shift;;
  esac
done

[[ ${#TRIPLES[@]} -ge 3 && $(( ${#TRIPLES[@]} % 3 )) -eq 0 ]] || {
  echo "Usage: $0 [--dry-run] [--actor <user>] <user> <relation> <object> [...]" >&2
  exit 2
}

validate_triple() {
  local u="$1" r="$2" o="$3"
  [[ "$u" == *:* ]] || { echo "invalid user (need type:id): $u" >&2; return 2; }
  [[ -n "$r" && "$r" =~ ^[a-z_]+$ ]] || { echo "invalid relation: $r" >&2; return 2; }
  [[ "$o" == *:* ]] || { echo "invalid object (need type:id): $o" >&2; return 2; }
}

# Build the batched write payload for audit/dry-run.
PAYLOAD=$(python3 - "${TRIPLES[@]}" <<'PY'
import json, os, sys
args = sys.argv[1:]
tk = [{"user":args[i],"relation":args[i+1],"object":args[i+2]} for i in range(0,len(args),3)]
print(json.dumps({"authorization_model_id": os.environ["FGA_MODEL_ID"],
                  "writes": {"tuple_keys": tk}}, indent=2))
PY
)

i=0
while [[ $i -lt ${#TRIPLES[@]} ]]; do
  u="${TRIPLES[$i]}"; r="${TRIPLES[$((i+1))]}"; o="${TRIPLES[$((i+2))]}"
  validate_triple "$u" "$r" "$o"
  i=$((i+3))
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] would write to /stores/${FGA_STORE_ID}/write:" >&2
  echo "$PAYLOAD" >&2
  i=0
  while [[ $i -lt ${#TRIPLES[@]} ]]; do
    u="${TRIPLES[$i]}"; r="${TRIPLES[$((i+1))]}"; o="${TRIPLES[$((i+2))]}"
    fga_audit "{\"ts\":\"$(fga_now)\",\"actor\":\"${ACTOR}\",\"action\":\"tuple-write\",\"tuple\":{\"user\":\"${u}\",\"relation\":\"${r}\",\"object\":\"${o}\"},\"result\":\"dry-run\"}"
    i=$((i+3))
  done
  exit 0
fi

if fga_write "${TRIPLES[@]}"; then
  i=0
  while [[ $i -lt ${#TRIPLES[@]} ]]; do
    u="${TRIPLES[$i]}"; r="${TRIPLES[$((i+1))]}"; o="${TRIPLES[$((i+2))]}"
    fga_audit "{\"ts\":\"$(fga_now)\",\"actor\":\"${ACTOR}\",\"action\":\"tuple-write\",\"tuple\":{\"user\":\"${u}\",\"relation\":\"${r}\",\"object\":\"${o}\"},\"result\":\"ok\"}"
    echo "wrote: ${u} ${r} ${o}"
    i=$((i+3))
  done
else
  rc=$?
  i=0
  while [[ $i -lt ${#TRIPLES[@]} ]]; do
    u="${TRIPLES[$i]}"; r="${TRIPLES[$((i+1))]}"; o="${TRIPLES[$((i+2))]}"
    fga_audit "{\"ts\":\"$(fga_now)\",\"actor\":\"${ACTOR}\",\"action\":\"tuple-write\",\"tuple\":{\"user\":\"${u}\",\"relation\":\"${r}\",\"object\":\"${o}\"},\"result\":\"error\",\"http\":\"${FGA_HTTP_CODE:-?}\"}"
    i=$((i+3))
  done
  exit $rc
fi
