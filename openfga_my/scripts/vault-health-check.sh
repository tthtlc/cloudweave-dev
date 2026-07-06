#!/usr/bin/env bash
# vault-health-check.sh — Vault health + seal + HA + replication pre-flight.
#
# Cloud Admin tool. Calls /sys/health, /sys/seal-status, /sys/leader, and (if
# replication is configured) /sys/replication/status. Used in monitoring and
# as a pre-flight before provisioning operations. Exits non-zero if Vault is
# sealed, uninitialized, or not the leader (on a standby node).
#
# Note: /sys/health returns non-2xx codes for degraded states by design
# (200 = leader, 429 = standby, 472 = sealed, 473 = recovery mode, 505 =
# uninitialized). curl is invoked with `-sS` but the script tolerates those
# codes by reading them from the response body when available.
#
# Usage:
#   vault-health-check.sh
#   vault-health-check.sh --quiet
#   vault-health-check.sh --json
#
# Options:
#   --json           print a single JSON summary object on stdout
#   --quiet          only print problems (exit 0 if healthy)
#   --vault-token <t>  /sys/health is unauthenticated; token only needed for
#                      /sys/replication/status
#   -h, --help
#
# Exit codes:
#   0  Vault healthy (initialized, unsealed, leader)
#   1  sealed / uninitialized / standby (degraded)
#   2  usage
#   3  Vault unreachable
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vault_common.sh
source "${SCRIPT_DIR}/vault_common.sh"

JSON=0
QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)        JSON=1; shift ;;
    --quiet)       QUIET=1; shift ;;
    --vault-token) VAULT_TOKEN_ARG="$2"; shift 2 ;;
    -h|--help)     sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

ts="$(vault_now)"

# /sys/health is unauthenticated. Use a raw curl so we can read non-2xx bodies.
health_raw=$(curl -sS "${VAULT_ADDR}/v1/sys/health" -o /tmp/vh_health -w "%{http_code}" 2>/dev/null) || health_raw="000"
health_body="$(cat /tmp/vh_health 2>/dev/null || echo '')"; rm -f /tmp/vh_health
seal_raw=$(curl -sS "${VAULT_ADDR}/v1/sys/seal-status" -o /tmp/vh_seal -w "%{http_code}" 2>/dev/null) || seal_raw="000"
seal_body="$(cat /tmp/vh_seal 2>/dev/null || echo '')"; rm -f /tmp/vh_seal
leader_raw=$(curl -sS "${VAULT_ADDR}/v1/sys/leader" -o /tmp/vh_leader -w "%{http_code}" 2>/dev/null) || leader_raw="000"
leader_body="$(cat /tmp/vh_leader 2>/dev/null || echo '')"; rm -f /tmp/vh_leader

# Parse the three responses in one python pass.
SUMMARY=$(H_RAW="$health_raw" H_BODY="$health_body" S_RAW="$seal_raw" S_BODY="$seal_body" \
  L_RAW="$leader_raw" L_BODY="$leader_body" TS="$ts" python3 - <<'PY'
import json, os, sys
def load(raw, body):
    try: return int(raw), json.loads(body or "{}")
    except Exception: return 0, {}
h_code, h = load(os.environ["H_RAW"], os.environ["H_BODY"])
s_code, s = load(os.environ["S_RAW"], os.environ["S_BODY"])
l_code, l = load(os.environ["L_RAW"], os.environ["L_BODY"])
out = {
    "timestamp": os.environ["TS"],
    "vault_addr": os.environ.get("VAULT_ADDR"),
    "initialized": h.get("initialized", s.get("initialized")),
    "sealed": h.get("sealed", s.get("sealed")),
    "standby": h.get("standby", False),
    "performance_standby": h.get("performance_standby", False),
    "recovery": h.get("recovery", False),
    "leader_address": l.get("leader_address") if l_code == 200 else None,
    "is_leader": bool(l.get("ha_enabled", False) is False or l.get("is_leader", False)),
    "health_http": h_code,
    "seal_http": s_code,
    "leader_http": l_code,
}
# Overall status string.
if h_code == 505 or not out["initialized"]:
    out["status"] = "uninitialized"
elif out["sealed"]:
    out["status"] = "sealed"
elif h_code == 429 or out["standby"]:
    out["status"] = "standby"
elif h_code == 200:
    out["status"] = "ok"
else:
    out["status"] = f"http-{h_code}"
print(json.dumps(out))
PY
)

status=$(printf '%s' "$SUMMARY" | vault_json_field /dev/stdin "status")
init=$(printf '%s' "$SUMMARY" | vault_json_field /dev/stdin "initialized")
sealed=$(printf '%s' "$SUMMARY" | vault_json_field /dev/stdin "sealed")
leader=$(printf '%s' "$SUMMARY" | vault_json_field /dev/stdin "leader_address")

# Replication status (best-effort, needs auth).
repl_body=""
if tok=$(vault_resolve_token 2>/dev/null); then
  repl_body=$(curl -sS "${VAULT_ADDR}/v1/sys/replication/status" -H "X-Vault-Token: ${tok}" 2>/dev/null || echo "")
fi

if [[ "$JSON" -eq 1 ]]; then
  if [[ -n "$repl_body" ]]; then
    python3 -c '
import json, sys
s = json.loads(sys.argv[1])
try:
    r = json.loads(sys.argv[2] or "{}").get("data", {})
    s["replication"] = r
except Exception:
    s["replication"] = None
print(json.dumps(s, indent=2))
' "$SUMMARY" "$repl_body"
  else
    printf '%s\n' "$SUMMARY" | vault_json_pretty
  fi
else
  if [[ "$QUIET" -eq 0 ]]; then
    echo "Vault health: ${status} (addr=${VAULT_ADDR})"
    echo "  initialized=${init} sealed=${sealed} leader=${leader:-n/a}"
    [[ -n "$repl_body" ]] && echo "  replication: $(printf '%s' "$repl_body" | vault_json_pretty | tr '\n' ' ' | sed 's/  */ /g')"
  fi
  if [[ "$status" != "ok" ]]; then
    echo "PROBLEM: Vault status is '${status}'." >&2
  fi
fi

vault_audit "{\"ts\":\"${ts}\",\"actor\":\"${ACTOR}\",\"action\":\"health-check\",\"status\":\"${status}\",\"initialized\":${init:-null},\"sealed\":${sealed:-null}}"

case "$status" in
  ok) exit 0 ;;
  uninitialized|sealed|standby) exit 1 ;;
  *) exit 1 ;;
esac
