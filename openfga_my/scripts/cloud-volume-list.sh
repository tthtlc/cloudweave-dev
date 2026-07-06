#!/usr/bin/env bash
# cloud-volume-list.sh — list block-storage volumes via libcloud REST.
#
#   cloud-volume-list.sh [--provider aws|nutanix] [--region R] [--format json|table]
#
# Columns (table): id, name, state, size(GB), target.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cloud_common.sh
source "${SCRIPT_DIR}/cloud_common.sh"

FORMAT="table"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) CLOUD_PROVIDER="$2"; shift 2;;
    --region)   CLOUD_REGION="$2"; shift 2;;
    --format)   FORMAT="$2"; shift 2;;
    -h|--help)  sed -n '2,6p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

cloud_setup >/dev/null 2>&1
RESP=$(cloud_api_or_die GET /v1/compute/volumes)

python3 - "$RESP" "$FORMAT" "$(cloud_provider)" <<'PY'
import json, sys
resp, fmt, provider = sys.argv[1], sys.argv[2], sys.argv[3]
vols = json.loads(resp).get("data", []) or []
if fmt == "json":
    print(json.dumps(vols, indent=2)); sys.exit(0)
if not vols:
    print(f"(no volumes for provider={provider})"); sys.exit(0)
print(f"{'id':<28} {'name':<28} {'state':<12} {'size':<10} target")
for v in vols:
    sz = v.get("size") or "-"
    print(f"{v.get('id',''):<28} {v.get('name',''):<28} {v.get('state',''):<12} "
          f"{str(sz):<10} {v.get('target','')}")
PY
