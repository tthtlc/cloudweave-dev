#!/usr/bin/env bash
# cloud-size-list.sh — list instance sizes/flavours via libcloud REST.
#
#   cloud-size-list.sh [--provider aws|nutanix] [--region R] [--format json|table]
#
# Columns (table): id, name, cpu, ram_mib, disk_gb, price.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cloud_common.sh
source "${SCRIPT_DIR}/cloud_common.sh"

FORMAT="table"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) CLOUD_PROVIDER="$2"; shift 2;;
    --region) CLOUD_REGION="$2"; shift 2;;
    --format) FORMAT="$2"; shift 2;;
    --dry-run) CLOUD_DRY_RUN=1; shift;;
    -h|--help) sed -n '2,6p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

cloud_setup >/dev/null 2>&1
RESP=$(cloud_api_or_die GET /v1/compute/sizes) || exit $?

python3 - "$RESP" "$FORMAT" <<'PY'
import json, sys
resp, fmt = sys.argv[1], sys.argv[2]
sizes = json.loads(resp).get("data", []) or []
if fmt == "json":
    print(json.dumps(sizes, indent=2)); sys.exit(0)
if not sizes: print("(no sizes)"); sys.exit(0)
print(f"{'id':<24} {'name':<28} {'cpu':<6} {'ram_mib':<10} {'disk_gb':<10} {'price':<10}")
for s in sizes:
    price = s.get("price") or "-"
    if isinstance(price, (int, float)): price = f"{price}"
    print(f"{s.get('id',''):<24} {(s.get('name') or '')[:26]:<28} "
          f"{s.get('cpu','') or '-':<6} {s.get('ram','') or '-':<10} "
          f"{s.get('disk','') or '-':<10} {str(price):<10}")
PY
