#!/usr/bin/env bash
# cloud-node-list.sh — list compute nodes for a provider+region via libcloud REST.
#
#   cloud-node-list.sh [--provider aws|nutanix] [--region R] [--filter NAME] [--format json|table]
#
# Columns (table): id, name, state, size, public_ip, private_ip.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cloud_common.sh
source "${SCRIPT_DIR}/cloud_common.sh"

FILTER=""
FORMAT="table"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) CLOUD_PROVIDER="$2"; shift 2;;
    --region) CLOUD_REGION="$2"; shift 2;;
    --filter) FILTER="$2"; shift 2;;
    --format) FORMAT="$2"; shift 2;;
    -h|--help) sed -n '2,6p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

cloud_setup >/dev/null 2>&1
RESP=$(cloud_api_or_die GET /v1/compute/nodes)

python3 - "$RESP" "$FILTER" "$FORMAT" "$(cloud_provider)" <<'PY'
import json, sys
resp, filt, fmt, provider = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
nodes = json.loads(resp).get("data", []) or []
if filt:
    nodes = [n for n in nodes if filt in (n.get("name") or "")]
if fmt == "json":
    print(json.dumps(nodes, indent=2)); sys.exit(0)
if not nodes:
    print(f"(no nodes for provider={provider})"); sys.exit(0)
print(f"{'id':<28} {'name':<28} {'state':<12} {'size':<16} {'public_ip':<18} private_ip")
for n in nodes:
    pub = ",".join(n.get("public_ips") or []) or "-"
    priv = ",".join(n.get("private_ips") or []) or "-"
    print(f"{n.get('id',''):<28} {n.get('name',''):<28} {n.get('state',''):<12} "
          f"{n.get('size','') or '-':<16} {pub:<18} {priv}")
PY
