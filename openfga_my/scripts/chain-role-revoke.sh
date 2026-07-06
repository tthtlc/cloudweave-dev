#!/usr/bin/env bash
# chain-role-revoke.sh — revoke a role from a user across LLDAP + OpenFGA + Vault.
#
# Cloud Admin tool. Atomic-or-compensating workflow:
#   1. lldap-group-remove-member.sh --user <u> --group <g>
#      (this also triggers openfga-tuple-reconcile.py to delete stale tuples)
#   2. openfga-tuple-delete.sh for the explicit role relation
#   3. vault-lease-revoke-prefix.sh for any leases tied to that role path
#      (best-effort: the prefix is derived from the engine/role; pass
#      --lease-prefix explicitly to override; skip with --skip-vault-revoke)
#   4. verify openfga-check returns denied for a representative resource
#
# Usage:
#   chain-role-revoke.sh --user <uid> --group <g>
#       [--relation <r> --object <o>]
#       [--check-relation <r> --check-object <o>]
#       [--lease-prefix <prefix>]
#       [--map-file <path>] [--actor <u>] [--dry-run]
#       [--skip-vault-revoke] [--confirm-vault]
#
# Options:
#   --user, --group, --relation, --object, --check-relation, --check-object,
#   --map-file, --actor, --dry-run  : as in chain-role-assign.sh
#   --lease-prefix <p>     Vault lease prefix to revoke (e.g. aws/creds/ec2-admin)
#   --skip-vault-revoke    skip step 3
#   --confirm-vault        REQUIRED to actually revoke Vault leases (high-impact);
#                          without it step 3 only lists the affected leases.
#   -h, --help
#
# Exit codes:
#   0  role revoked and verify returns denied
#   3  a step failed (or verify still returns allowed — role NOT effectively revoked)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AUDIT_LOG="${ROOT}/generated/chain_audit.log"
mkdir -p "$(dirname "$AUDIT_LOG")"

OPT_USER=""; OPT_GROUP=""
OPT_REL=""; OPT_OBJ=""
OPT_CHECK_REL=""; OPT_CHECK_OBJ=""
LEASE_PREFIX=""
MAP_FILE=""
ACTOR="${USER:-cloud-admin}"
DRY_RUN=0
SKIP_VAULT_REVOKE=0
CONFIRM_VAULT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)           OPT_USER="$2"; shift 2 ;;
    --group)          OPT_GROUP="$2"; shift 2 ;;
    --relation)       OPT_REL="$2"; shift 2 ;;
    --object)         OPT_OBJ="$2"; shift 2 ;;
    --check-relation) OPT_CHECK_REL="$2"; shift 2 ;;
    --check-object)   OPT_CHECK_OBJ="$2"; shift 2 ;;
    --lease-prefix)   LEASE_PREFIX="$2"; shift 2 ;;
    --map-file)       MAP_FILE="$2"; shift 2 ;;
    --actor)          ACTOR="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --skip-vault-revoke) SKIP_VAULT_REVOKE=1; shift ;;
    --confirm-vault)  CONFIRM_VAULT=1; shift ;;
    -h|--help)        sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$OPT_USER" && -n "$OPT_GROUP" ]] || { echo "ERROR: --user and --group are required" >&2; exit 2; }

chain_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
chain_audit() { local line="$1"; echo "$line" >&2; echo "$line" >> "$AUDIT_LOG"; }

# Derive (relation, object) from the group name if not supplied.
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
echo "=== chain-role-revoke: ${OPT_USER} <- ${OPT_GROUP} (${OPT_REL} ${OPT_OBJ}) ===" >&2

# Step 1: LLDAP group remove.
echo "[1/4] lldap-group-remove-member" >&2
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  [dry-run] would remove ${OPT_USER} from ${OPT_GROUP}" >&2
else
  if bash "${SCRIPT_DIR}/lldap-group-remove-member.sh" --user "$OPT_USER" --group "$OPT_GROUP" >/tmp/chain_rr1.log 2>&1; then
    echo "  ok" >&2
  else
    rc=$?
    echo "  WARN (rc=$rc):" >&2; tail -n 20 /tmp/chain_rr1.log >&2
    chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-role-revoke\",\"user\":\"${OPT_USER}\",\"group\":\"${OPT_GROUP}\",\"step\":1,\"result\":\"error\",\"rc\":$rc}"
  fi
fi

# Step 2: OpenFGA tuple delete.
echo "[2/4] openfga-tuple-delete ${fga_user} ${OPT_REL} ${OPT_OBJ}" >&2
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  [dry-run] would delete tuple" >&2
else
  if bash "${SCRIPT_DIR}/openfga-tuple-delete.sh" "$fga_user" "$OPT_REL" "$OPT_OBJ" >/tmp/chain_rr2.log 2>&1; then
    echo "  ok" >&2
  else
    rc=$?
    echo "  WARN: tuple-delete failed (rc=$rc):" >&2; tail -n 20 /tmp/chain_rr2.log >&2
    chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-role-revoke\",\"user\":\"${OPT_USER}\",\"group\":\"${OPT_GROUP}\",\"step\":2,\"result\":\"error\",\"rc\":$rc}"
  fi
fi

# Step 3: Vault lease revoke-prefix for leases tied to the role path.
echo "[3/4] vault-lease-revoke-prefix (prefix=${LEASE_PREFIX:-none})" >&2
if [[ "$SKIP_VAULT_REVOKE" -eq 1 || -z "$LEASE_PREFIX" ]]; then
  echo "  skipped (no --lease-prefix or --skip-vault-revoke)" >&2
  chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-role-revoke\",\"user\":\"${OPT_USER}\",\"group\":\"${OPT_GROUP}\",\"step\":3,\"result\":\"skipped\"}"
else
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  [dry-run] would revoke prefix ${LEASE_PREFIX}" >&2
  elif [[ "$CONFIRM_VAULT" -ne 1 ]]; then
    # Without --confirm-vault, only list the affected leases (safe pre-flight).
    echo "  --confirm-vault not set; listing affected leases only:" >&2
    bash "${SCRIPT_DIR}/vault-lease-list.sh" "$LEASE_PREFIX" >&2 || true
    chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-role-revoke\",\"user\":\"${OPT_USER}\",\"group\":\"${OPT_GROUP}\",\"step\":3,\"result\":\"listed-only\"}"
  else
    if bash "${SCRIPT_DIR}/vault-lease-revoke-prefix.sh" "$LEASE_PREFIX" --confirm --force >/tmp/chain_rr3.log 2>&1; then
      echo "  ok" >&2
    else
      rc=$?
      echo "  WARN: vault-lease-revoke-prefix failed (rc=$rc):" >&2; tail -n 20 /tmp/chain_rr3.log >&2
      chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-role-revoke\",\"user\":\"${OPT_USER}\",\"group\":\"${OPT_GROUP}\",\"step\":3,\"result\":\"error\",\"rc\":$rc}"
    fi
  fi
fi

# Step 4: verify openfga-check returns denied.
echo "[4/4] verify openfga-check ${fga_user} ${OPT_CHECK_REL} ${OPT_CHECK_OBJ} -> denied" >&2
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  [dry-run] would run openfga-check" >&2
  chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-role-revoke\",\"user\":\"${OPT_USER}\",\"group\":\"${OPT_GROUP}\",\"result\":\"dry-run\"}"
  exit 0
fi
check_out=$(bash "${SCRIPT_DIR}/openfga-check.sh" "$fga_user" "$OPT_CHECK_REL" "$OPT_CHECK_OBJ" 2>/tmp/chain_rr4.log)
check_rc=$?
echo "  ${check_out}" >&2
if [[ $check_rc -eq 1 ]]; then
  chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-role-revoke\",\"user\":\"${OPT_USER}\",\"group\":\"${OPT_GROUP}\",\"result\":\"ok\",\"check\":\"denied\"}"
  echo "=== chain-role-revoke complete: ${fga_user} can no longer ${OPT_CHECK_REL} ${OPT_CHECK_OBJ} ===" >&2
  exit 0
elif [[ $check_rc -eq 0 ]]; then
  chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-role-revoke\",\"user\":\"${OPT_USER}\",\"group\":\"${OPT_GROUP}\",\"result\":\"verify-still-allowed\"}"
  echo "=== chain-role-revoke FAILED verify: ${fga_user} ${OPT_CHECK_REL} ${OPT_CHECK_OBJ} STILL allowed ===" >&2
  exit 3
else
  chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-role-revoke\",\"user\":\"${OPT_USER}\",\"group\":\"${OPT_GROUP}\",\"result\":\"verify-error\",\"check_rc\":$check_rc}"
  echo "=== chain-role-revoke verify returned error (rc=$check_rc) ===" >&2
  tail -n 10 /tmp/chain_rr4.log >&2
  exit 3
fi
