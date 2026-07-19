#!/usr/bin/env bash
# openfga-breakglass-grant.sh — time-bounded elevated-access OpenFGA tuple.
#
# Grants a user an extra relation on an object for a limited TTL, then
# automatically deletes the tuple when the TTL elapses. Used for emergency
# ("break-glass") elevation with a mandatory reason + audit trail.
#
# The deployed OpenFGA model has no time-bounded condition rewriter, so the
# time bound is enforced operationally: the tuple is written now and a
# detached scheduler deletes it after TTL minutes. The grant + scheduled
# deletion are recorded in generated/openfga_breakglass.log (JSONL) and the
# standard OpenFGA audit log.
#
# Usage:
#   openfga-breakglass-grant.sh --user <user> --relation <rel> --object <obj> \
#       --ttl <minutes> --reason "<why>" [--actor <user>] [--dry-run]
#
# Example:
#   openfga-breakglass-grant.sh --user user:aws-viewer --relation admin \
#       --object tenant:aws --ttl 60 --reason "INC-123 prod hotfix"
#
# NOTE: the deployed model exposes only the documented four-role taxonomy
# (superadmin/owner/admin/viewer) plus the can_* verbs. There is no longer an
# out-of-band "operator" or provider "allowed" relation. For break-glass
# provisioning power, grant "admin" on the tenant (tenant-wide) or "admin" on
# a resource_class (per-class) for the TTL window.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=openfga_common.sh
source "${SCRIPT_DIR}/openfga_common.sh"

USER="" REL="" OBJ="" TTL="" REASON="" ACTOR="${LIBCLOUD_USER}" DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER="$2"; shift 2;;
    --relation) REL="$2"; shift 2;;
    --object) OBJ="$2"; shift 2;;
    --ttl) TTL="$2"; shift 2;;
    --reason) REASON="$2"; shift 2;;
    --actor) ACTOR="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) sed -n '2,18p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[[ "$USER" == *:* ]] || { echo "--user must be type:id (e.g. user:alice)" >&2; exit 2; }
[[ -n "$REL" && "$REL" =~ ^[a-z_]+$ ]] || { echo "--relation invalid" >&2; exit 2; }
[[ "$OBJ" == *:* ]] || { echo "--object must be type:id" >&2; exit 2; }
[[ -n "$TTL" && "$TTL" =~ ^[0-9]+$ ]] || { echo "--ttl <minutes> required (integer)" >&2; exit 2; }
(( TTL >= 1 && TTL <= 480 )) || { echo "--ttl must be 1..480 minutes" >&2; exit 2; }
[[ -n "$REASON" ]] || { echo "--reason is mandatory for break-glass grants" >&2; exit 2; }

GRANT_ID="bg-$(date +%s)-$RANDOM"
NOW_EPOCH=$(date +%s)
EXPIRY_EPOCH=$(( NOW_EPOCH + TTL * 60 ))
EXPIRY_ISO=$(date -u -d "@${EXPIRY_EPOCH}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$EXPIRY_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
BG_LOG="${REPO_ROOT}/generated/openfga_breakglass.log"
mkdir -p "$(dirname "$BG_LOG")" "$(dirname "$BG_LOG")"

grant_record() {  # <status>
  local status="$1"
  python3 - "$GRANT_ID" "$NOW_EPOCH" "$EXPIRY_EPOCH" "$EXPIRY_ISO" "$USER" "$REL" "$OBJ" "$TTL" "$REASON" "$ACTOR" "$status" <<'PY'
import json, sys
(gid, now, exp, expiso, u, r, o, ttl, reason, actor, status) = sys.argv[1:12]
print(json.dumps({"ts": __import__("datetime").datetime.utcnow().isoformat()+"Z",
  "grant_id": gid, "actor": actor, "user": u, "relation": r, "object": o,
  "ttl_minutes": int(ttl), "granted_at": int(now), "expires_at": int(exp),
  "expires_at_iso": expiso, "reason": reason, "status": status}))
PY
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] would grant ${USER} ${REL} ${OBJ} for ${TTL}m (expires ${EXPIRY_ISO})" >&2
  echo "reason: ${REASON}" >&2
  grant_record "dry-run" >&2
  fga_audit "{\"ts\":\"$(fga_now)\",\"actor\":\"${ACTOR}\",\"action\":\"breakglass-grant\",\"grant_id\":\"${GRANT_ID}\",\"tuple\":{\"user\":\"${USER}\",\"relation\":\"${REL}\",\"object\":\"${OBJ}\"},\"ttl_minutes\":${TTL},\"expires_at\":\"${EXPIRY_ISO}\",\"reason\":\"${REASON}\",\"result\":\"dry-run\"}"
  exit 0
fi

# 1. Write the elevated tuple.
if ! fga_write "$USER" "$REL" "$OBJ"; then
  grant_record "write-failed" >> "$BG_LOG"
  fga_audit "{\"ts\":\"$(fga_now)\",\"actor\":\"${ACTOR}\",\"action\":\"breakglass-grant\",\"grant_id\":\"${GRANT_ID}\",\"tuple\":{\"user\":\"${USER}\",\"relation\":\"${REL}\",\"object\":\"${OBJ}\"},\"ttl_minutes\":${TTL},\"result\":\"write-error\",\"http\":\"${FGA_HTTP_CODE:-?}\"}"
  exit 4
fi

# 2. Record the grant.
grant_record "granted" >> "$BG_LOG"
fga_audit "{\"ts\":\"$(fga_now)\",\"actor\":\"${ACTOR}\",\"action\":\"breakglass-grant\",\"grant_id\":\"${GRANT_ID}\",\"tuple\":{\"user\":\"${USER}\",\"relation\":\"${REL}\",\"object\":\"${OBJ}\"},\"ttl_minutes\":${TTL},\"expires_at\":\"${EXPIRY_ISO}\",\"reason\":\"${REASON}\",\"result\":\"ok\"}"

# 3. Schedule deletion: a detached process sleeps TTL then deletes the tuple.
#    It re-runs openfga-tuple-delete.sh (which self-resolves the FGA bearer).
PIDFILE="${REPO_ROOT}/generated/breakglass/${GRANT_ID}.pid"
mkdir -p "$(dirname "$PIDFILE")"
nohup bash -c '
set -euo pipefail
sleep "$(( '"${TTL}"' * 60 ))"
'"${SCRIPT_DIR}"'/openfga-tuple-delete.sh '"$USER"' '"$REL"' '"$OBJ"' >/dev/null 2>&1 || true
python3 - >> "'"${BG_LOG}"'" <<PY
import json,datetime
print(json.dumps({"ts":datetime.datetime.utcnow().isoformat()+"Z","grant_id":"'"${GRANT_ID}"'","status":"auto-deleted","tuple":{"user":"'"${USER}"'","relation":"'"${REL}"'","object":"'"$OBJ"'"}}))
PY
rm -f "'"${PIDFILE}"'"
' >/dev/null 2>&1 &
SCHED_PID=$!
echo "$SCHED_PID" > "$PIDFILE"
disown "$SCHED_PID" 2>/dev/null || true

echo "break-glass grant ${GRANT_ID}: ${USER} ${REL} ${OBJ} for ${TTL}m (expires ${EXPIRY_ISO})"
echo "scheduled auto-delete pid=${SCHED_PID} (pidfile ${PIDFILE})"
echo "reason: ${REASON}"
