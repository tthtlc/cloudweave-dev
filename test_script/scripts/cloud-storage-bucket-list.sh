#!/usr/bin/env bash
# cloud-storage-bucket-list.sh — list object-storage buckets via libcloud REST.
#
#   cloud-storage-bucket-list.sh [--provider aws|nutanix] [--region R] [--format json|table]
#
# Columns (table): name, provider, target, created.
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
RESP=$(cloud_api_or_die GET /v1/storage/buckets)

python3 - "$RESP" "$FORMAT" "$(cloud_provider)" <<'PY'
import json, sys
resp, fmt, provider = sys.argv[1], sys.argv[2], sys.argv[3]
buckets = json.loads(resp).get("data", []) or []
if fmt == "json":
    print(json.dumps(buckets, indent=2)); sys.exit(0)
if not buckets:
    print(f"(no buckets for provider={provider})"); sys.exit(0)
print(f"{'name':<32} {'provider':<10} {'target':<24} created")
for b in buckets:
    ex = b.get("extra") or {}
    print(f"{b.get('name',''):<32} {b.get('provider',''):<10} "
          f"{b.get('target',''):<24} {ex.get('date_created') or ex.get('creation_date') or '-'}")
PY
