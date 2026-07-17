#!/usr/bin/env bash
# cloud-floatingip-list.sh — list floating (elastic) IPs via libcloud REST.
#
#   cloud-floatingip-list.sh [--provider aws|nutanix] [--region R]
#                            [--address A] [--format json|table]
#
# Columns (table): address, domain, associated, instance_id, target.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cloud_common.sh
source "${SCRIPT_DIR}/cloud_common.sh"

ADDRESS="" FORMAT="table"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) CLOUD_PROVIDER="$2"; shift 2;;
    --region)   CLOUD_REGION="$2"; shift 2;;
    --address)  ADDRESS="$2"; shift 2;;
    --format)   FORMAT="$2"; shift 2;;
    -h|--help)  sed -n '2,7p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

cloud_setup >/dev/null 2>&1
PATH_="/v1/compute/floating-ips"
[[ -n "$ADDRESS" ]] && PATH_="${PATH_}?address=${ADDRESS}"
RESP=$(cloud_api_or_die GET "$PATH_")

python3 - "$RESP" "$FORMAT" "$(cloud_provider)" <<'PY'
import json, sys
resp, fmt, provider = sys.argv[1], sys.argv[2], sys.argv[3]
ips = json.loads(resp).get("data", []) or []
if fmt == "json":
    print(json.dumps(ips, indent=2)); sys.exit(0)
if not ips:
    print(f"(no floating IPs for provider={provider})"); sys.exit(0)
print(f"{'address':<18} {'domain':<10} {'associated':<12} {'instance_id':<22} target")
for ip in ips:
    assoc = "yes" if ip.get("associated") else "no"
    print(f"{ip.get('address',''):<18} {str(ip.get('domain') or '-'):<10} "
          f"{assoc:<12} {str(ip.get('instance_id') or '-'):<22} {ip.get('target','')}")
PY
