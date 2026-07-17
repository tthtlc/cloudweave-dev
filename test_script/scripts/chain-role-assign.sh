#!/usr/bin/env bash
# chain-role-assign.sh — assign a user to a new role across LLDAP + OpenFGA.
#
# Cloud Admin tool. Atomic-or-compensating workflow:
#   1. lldap-group-add-member.sh --user <u> --group <g>
#      (this also triggers openfga-tuple-reconcile.py)
#   2. openfga-tuple-write.sh for the explicit role relation (so the tuple is
#      present even before the scheduled reconciler runs)
#   3. verify openfga-check returns allowed for a representative resource
#
# The role's OpenFGA (relation, object) tuple and the representative check
# target can be supplied explicitly. If omitted, the script tries to derive
# them from the LLDAP group name using openfga_pylib's group_to_tuple map
# (the same mapping the reconciler uses).
#
# Usage:
#   chain-role-assign.sh --user <uid> --group <g>
#       [--relation <r> --object <o>]
#       [--check-relation <r> --check-object <o>]
#       [--map-file <path>] [--actor <u>] [--dry-run]
#
# Options:
#   --user <uid>           LLDAP user id
#   --group <g>            LLDAP group (role) name
#   --relation <r>         OpenFGA relation to write (default: derived from group)
#   --object <o>           OpenFGA object to write   (default: derived from group)
#   --check-relation <r>   relation for the verify check (default: --relation)
#   --check-object <o>     object for the verify check   (default: --object)
#   --map-file <path>      explicit reconciler mapping (passed to openfga_pylib)
#   --actor <u>            audit actor
#   --dry-run              plan only
#   -h, --help
#
# Exit codes:
#   0  role assigned and verified allowed
#   3  a step failed (or verify returned denied — role NOT effectively granted)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AUDIT_LOG="${REPO_ROOT}/generated/chain_audit.log"
mkdir -p "$(dirname "$AUDIT_LOG")"

OPT_USER=""; OPT_GROUP=""
OPT_REL=""; OPT_OBJ=""
OPT_CHECK_REL=""; OPT_CHECK_OBJ=""
MAP_FILE=""
ACTOR="${USER:-cloud-admin}"
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)           OPT_USER="$2"; shift 2 ;;
    --group)          OPT_GROUP="$2"; shift 2 ;;
    --relation)       OPT_REL="$2"; shift 2 ;;
    --object)         OPT_OBJ="$2"; shift 2 ;;
    --check-relation) OPT_CHECK_REL="$2"; shift 2 ;;
    --check-object)   OPT_CHECK_OBJ="$2"; shift 2 ;;
    --map-file)       MAP_FILE="$2"; shift 2 ;;
    --actor)          ACTOR="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$OPT_USER" && -n "$OPT_GROUP" ]] || { echo "ERROR: --user and --group are required" >&2; exit 2; }

chain_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
chain_audit() { local line="$1"; echo "$line" >&2; echo "$line" >> "$AUDIT_LOG"; }

# Derive (relation, object) from the group name if not supplied, using the same
# mapping as the reconciler.
if [[ -z "$OPT_REL" || -z "$OPT_OBJ" ]]; then
  derived=$(G="$OPT_GROUP" MF="$MAP_FILE" PYTHONPATH="${SCRIPT_DIR}" python3 - <<'PY' 2>/dev/null || echo ""
import os, json
try:
    import openfga_pylib as lib
    lib.bootstrap_env()
    mf = os.environ.get("MF") or None
    explicit = lib.load_map_file(mf) if mf else None
    m = lib.group_to_tuple(os.environ["G"], explicit)
    if m: print(json.dumps({"relation": m[0], "object": m[1]}))
    else: print("")
except Exception:
    print("")
PY
)
  if [[ -n "$derived" ]]; then
    [[ -z "$OPT_REL" ]] && OPT_REL=$(printf '%s' "$derived" | python3 -c 'import json,sys; print(json.load(sys.stdin)["relation"])')
    [[ -z "$OPT_OBJ" ]] && OPT_OBJ=$(printf '%s' "$derived" | python3 -c 'import json,sys; print(json.load(sys.stdin)["object"])')
  fi
fi
[[ -n "$OPT_REL" && -n "$OPT_OBJ" ]] || {
  echo "ERROR: cannot derive (relation, object) for group '${OPT_GROUP}'." >&2
  echo "       Pass --relation and --object explicitly (or supply --map-file)." >&2
  exit 2
}
: "${OPT_CHECK_REL:=$OPT_REL}"
: "${OPT_CHECK_OBJ:=$OPT_OBJ}"

fga_user="user:${OPT_USER}"
echo "=== chain-role-assign: ${OPT_USER} -> ${OPT_GROUP} (${OPT_REL} ${OPT_OBJ}) ===" >&2

# Step 1: LLDAP group add (also triggers reconciler).
echo "[1/3] lldap-group-add-member" >&2
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  [dry-run] would add ${OPT_USER} to ${OPT_GROUP}" >&2
else
  if bash "${SCRIPT_DIR}/lldap-group-add-member.sh" --user "$OPT_USER" --group "$OPT_GROUP" >/tmp/chain_ra1.log 2>&1; then
    echo "  ok" >&2
  else
    rc=$?
    echo "  FAILED (rc=$rc):" >&2; tail -n 20 /tmp/chain_ra1.log >&2
    chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-role-assign\",\"user\":\"${OPT_USER}\",\"group\":\"${OPT_GROUP}\",\"step\":1,\"result\":\"error\",\"rc\":$rc}"
    exit 3
  fi
fi

# Step 2: OpenFGA tuple write.
echo "[2/3] openfga-tuple-write ${fga_user} ${OPT_REL} ${OPT_OBJ}" >&2
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  [dry-run] would write tuple" >&2
else
  if bash "${SCRIPT_DIR}/openfga-tuple-write.sh" "$fga_user" "$OPT_REL" "$OPT_OBJ" >/tmp/chain_ra2.log 2>&1; then
    echo "  ok" >&2
  else
    rc=$?
    echo "  WARN: tuple-write failed (rc=$rc):" >&2; tail -n 20 /tmp/chain_ra2.log >&2
    chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-role-assign\",\"user\":\"${OPT_USER}\",\"group\":\"${OPT_GROUP}\",\"step\":2,\"result\":\"error\",\"rc\":$rc}"
    # Continue: the reconciler may have already written it.
  fi
fi

# Step 3: verify openfga-check returns allowed.
echo "[3/3] verify openfga-check ${fga_user} ${OPT_CHECK_REL} ${OPT_CHECK_OBJ}" >&2
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  [dry-run] would run openfga-check" >&2
  chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-role-assign\",\"user\":\"${OPT_USER}\",\"group\":\"${OPT_GROUP}\",\"result\":\"dry-run\"}"
  exit 0
fi
check_out=$(bash "${SCRIPT_DIR}/openfga-check.sh" "$fga_user" "$OPT_CHECK_REL" "$OPT_CHECK_OBJ" 2>/tmp/chain_ra3.log)
check_rc=$?
echo "  ${check_out}" >&2
if [[ $check_rc -eq 0 ]]; then
  chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-role-assign\",\"user\":\"${OPT_USER}\",\"group\":\"${OPT_GROUP}\",\"result\":\"ok\",\"check\":\"allowed\"}"
  echo "=== chain-role-assign complete: ${OPT_USER} can ${OPT_CHECK_REL} ${OPT_CHECK_OBJ} ===" >&2
  exit 0
else
  chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-role-assign\",\"user\":\"${OPT_USER}\",\"group\":\"${OPT_GROUP}\",\"result\":\"verify-denied\",\"check_rc\":$check_rc}"
  echo "=== chain-role-assign FAILED verify: ${fga_user} ${OPT_CHECK_REL} ${OPT_CHECK_OBJ} returned denied/error (rc=$check_rc) ===" >&2
  tail -n 10 /tmp/chain_ra3.log >&2
  exit 3
fi
