#!/usr/bin/env bash
# cloud-network-list.sh — list networks + subnets via libcloud REST.
#
#   cloud-network-list.sh [--provider aws|nutanix] [--region R] [--format json|table]
#
# Columns (table): id, name, cidr, vpc, state, target.
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
NETS=$(cloud_api_or_die GET /v1/compute/networks)
SUBS=$(cloud_api_or_die GET /v1/compute/subnets 2>/dev/null || echo '{"data":[]}')

python3 - "$NETS" "$SUBS" "$FORMAT" "$(cloud_provider)" <<'PY'
import json, sys
nets, subs, fmt, provider = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
nets = json.loads(nets).get("data", []) or []
subs = json.loads(subs).get("data", []) or []
if fmt == "json":
    print(json.dumps({"networks": nets, "subnets": subs}, indent=2)); sys.exit(0)
if not nets and not subs:
    print(f"(no networks for provider={provider})"); sys.exit(0)
print("== networks ==")
print(f"{'id':<28} {'name':<28} {'cidr':<20} {'vpc':<20} target")
for n in nets:
    ex = n.get("extra") or {}
    cidr = n.get("cidr_block") or ex.get("cidr_block") or "-"
    vpc = n.get("vpc_id") or ex.get("vpc_id") or "-"
    print(f"{n.get('id',''):<28} {n.get('name',''):<28} {cidr:<20} {str(vpc):<20} {n.get('target','')}")
if subs:
    print("== subnets ==")
    print(f"{'id':<28} {'name':<28} {'cidr':<20} {'vpc':<20} target")
    for s in subs:
        ex = s.get("extra") or {}
        cidr = s.get("cidr_block") or ex.get("cidr_block") or "-"
        vpc = s.get("vpc_id") or ex.get("vpc_id") or "-"
        print(f"{s.get('id',''):<28} {s.get('name',''):<28} {cidr:<20} {str(vpc):<20} {s.get('target','')}")
PY
