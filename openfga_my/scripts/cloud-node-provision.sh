#!/usr/bin/env bash
# cloud-node-provision.sh — provision a compute instance via libcloud REST.
#
# Idempotent by name: if a node with the same name already exists, prints its id
# and exits 0 (use --force to attempt a fresh create regardless).
#
# Parameters come from CLI flags or --param-file (a JSON file whose top-level
# keys are name/size/image/location/network/provider_options; connection is
# injected by the script).
#
# Usage:
#   cloud-node-provision.sh --name vm1 --image <id> --size <id> [--subnet <id>]
#       [--location <id>] [--no-public-ip] [--param-file path.json]
#       [--provider aws|nutanix] [--region R] [--force] [--dry-run]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cloud_common.sh
source "${SCRIPT_DIR}/cloud_common.sh"

NAME="" IMAGE="" SIZE="" SUBNET="" LOCATION="" PARAM_FILE="" PUBLIC_IP=1 FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2;;
    --image) IMAGE="$2"; shift 2;;
    --size) SIZE="$2"; shift 2;;
    --subnet) SUBNET="$2"; shift 2;;
    --location) LOCATION="$2"; shift 2;;
    --param-file) PARAM_FILE="$2"; shift 2;;
    --no-public-ip) PUBLIC_IP=0; shift;;
    --provider) CLOUD_PROVIDER="$2"; shift 2;;
    --region) CLOUD_REGION="$2"; shift 2;;
    --force) FORCE=1; shift;;
    --dry-run) CLOUD_DRY_RUN=1; shift;;
    -h|--help) sed -n '2,12p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

cloud_setup >/dev/null 2>&1

# Idempotency by name (skip in dry-run).
if [[ "${CLOUD_DRY_RUN}" != "1" && "$FORCE" != "1" && -n "$NAME" ]]; then
  EXIST=$(cloud_api_or_die GET /v1/compute/nodes | python3 -c '
import json, sys
d = json.load(sys.stdin).get("data", []) or []
m = [n for n in d if n.get("name") == sys.argv[1]]
print(m[0]["id"] if m else "")
' "$NAME" 2>/dev/null || echo "")
  if [[ -n "$EXIST" ]]; then
    echo "node '${NAME}' already exists (id=${EXIST}); skipping (use --force to ignore)." >&2
    cloud_audit "{\"ts\":\"$(cloud_now)\",\"actor\":\"${LIBCLOUD_USER}\",\"action\":\"node-provision\",\"provider\":\"$(cloud_provider)\",\"name\":\"${NAME}\",\"result\":\"already-exists\",\"node_id\":\"${EXIST}\"}"
    echo "$EXIST"; exit 0
  fi
fi

# Build request body from --param-file or CLI flags.
BODY=$(python3 - "$PARAM_FILE" "$NAME" "$IMAGE" "$SIZE" "$SUBNET" "$LOCATION" "$PUBLIC_IP" <<'PY'
import json, os, sys
pf, name, image, size, subnet, location, pub = sys.argv[1:8]
body = {}
if pf and os.path.exists(pf):
    body = json.load(open(pf))
body.setdefault("name", name or body.get("name",""))
if image: body["image"] = {"id": image}
elif "image" not in body: body["image"] = {"id": ""}
if size: body["size"] = {"id": size}
elif "size" not in body: body["size"] = {"id": ""}
if location: body["location"] = {"id": location}
net = body.get("network", {}) or {}
if subnet: net["subnet_id"] = subnet
net.setdefault("public_ip", pub == "1")
body["network"] = net
body.setdefault("provider_options", {})
print(json.dumps(body))
PY
)
CREATE_BODY=$(with_connection "$BODY")

if [[ "${CLOUD_DRY_RUN}" == "1" ]]; then
  echo "[dry-run] POST /v1/compute/nodes name=${NAME} image=${IMAGE} size=${SIZE}" >&2
  echo "$CREATE_BODY" >&2
  exit 0
fi

RESP=$(cloud_api POST /v1/compute/nodes "$CREATE_BODY") || { echo "provision failed" >&2; exit 4; }
NODE_ID=$(echo "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("data",{}).get("id",""))' 2>/dev/null || echo "")
cloud_audit "{\"ts\":\"$(cloud_now)\",\"actor\":\"${LIBCLOUD_USER}\",\"action\":\"node-provision\",\"provider\":\"$(cloud_provider)\",\"name\":\"${NAME}\",\"result\":\"ok\",\"node_id\":\"${NODE_ID}\"}"
echo "$RESP" | json_pretty
