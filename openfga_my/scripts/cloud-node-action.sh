#!/usr/bin/env bash
# cloud-node-action.sh — lifecycle action on a compute node via libcloud REST.
#
#   cloud-node-action.sh --node <id|name> --action start|stop|reboot|destroy [--confirm]
#       [--provider aws|nutanix] [--region R]
#
# --confirm is REQUIRED for destroy (irreversible). For start/stop/reboot it is
# optional. --node may be a node id or a name (resolved via /v1/compute/nodes).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cloud_common.sh
source "${SCRIPT_DIR}/cloud_common.sh"

NODE="" ACTION="" CONFIRM=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) NODE="$2"; shift 2;;
    --action) ACTION="$2"; shift 2;;
    --confirm) CONFIRM=1; shift;;
    --provider) CLOUD_PROVIDER="$2"; shift 2;;
    --region) CLOUD_REGION="$2"; shift 2;;
    --dry-run) CLOUD_DRY_RUN=1; shift;;
    -h|--help) sed -n '2,8p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[[ -n "$NODE" && -n "$ACTION" ]] || { echo "--node and --action required" >&2; exit 2; }
case "$ACTION" in start|stop|reboot|destroy) ;; *) echo "--action must be start|stop|reboot|destroy" >&2; exit 2;; esac
if [[ "$ACTION" == "destroy" && "$CONFIRM" != "1" ]]; then
  echo "REFUSING destroy without --confirm (irreversible)." >&2; exit 3
fi

cloud_setup >/dev/null 2>&1

# Resolve node id if a name was given (not a pure id).
NODE_ID="$NODE"
if [[ "${CLOUD_DRY_RUN:-0}" != "1" ]]; then
  if ! [[ "$NODE" =~ ^[0-9a-fA-F-]{8,}$ && ! "$NODE" =~ [[:space:]] ]]; then
    NODE_ID=$(cloud_api_or_die GET /v1/compute/nodes | python3 -c '
import json, sys
d = json.load(sys.stdin).get("data", []) or []
m = [n for n in d if n.get("name") == sys.argv[1] or n.get("id") == sys.argv[1]]
print(m[0]["id"] if m else "")
' "$NODE" 2>/dev/null || echo "")
    [[ -n "$NODE_ID" ]] || { echo "node '${NODE}' not found" >&2; exit 4; }
  fi
fi

case "$ACTION" in
  start)   PATH_="/v1/compute/nodes/${NODE_ID}:start"; METHOD="POST"; BODY="";;
  stop)    PATH_="/v1/compute/nodes/${NODE_ID}:stop";  METHOD="POST"; BODY="";;
  reboot)  PATH_="/v1/compute/nodes/${NODE_ID}:reboot";METHOD="POST"; BODY="";;
  destroy) PATH_="/v1/compute/nodes/${NODE_ID}";       METHOD="DELETE"; BODY="";;
esac

if [[ "${CLOUD_DRY_RUN:-0}" == "1" ]]; then
  echo "[dry-run] ${METHOD} ${PATH_}" >&2; exit 0
fi

RESP=$(cloud_api "$METHOD" "$PATH_" "$BODY") || { echo "${ACTION} failed" >&2; exit 4; }
cloud_audit "{\"ts\":\"$(cloud_now)\",\"actor\":\"${LIBCLOUD_USER}\",\"action\":\"node-${ACTION}\",\"provider\":\"$(cloud_provider)\",\"node_id\":\"${NODE_ID}\",\"result\":\"ok\"}"
echo "${ACTION} ${NODE_ID}: $(echo "$RESP" | head -c 200)"
