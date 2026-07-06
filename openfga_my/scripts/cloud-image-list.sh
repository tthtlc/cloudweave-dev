#!/usr/bin/env bash
# cloud-image-list.sh — list OS images via libcloud REST.
#
#   cloud-image-list.sh [--provider aws|nutanix] [--region R] [--family SUBSTR]
#       [--arch x86_64|arm64] [--name-filter GLOB] [--format json|table]
#
# --family filters by image name substring; --arch filters by extra.architecture
# (where the driver exposes it). --name-filter is passed as the ?name= query for
# AWS DescribeImages name filtering (supports * wildcards).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cloud_common.sh
source "${SCRIPT_DIR}/cloud_common.sh"

FAMILY="" ARCH="" NAME_FILTER="" FORMAT="table"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) CLOUD_PROVIDER="$2"; shift 2;;
    --region) CLOUD_REGION="$2"; shift 2;;
    --family) FAMILY="$2"; shift 2;;
    --arch) ARCH="$2"; shift 2;;
    --name-filter) NAME_FILTER="$2"; shift 2;;
    --format) FORMAT="$2"; shift 2;;
    --dry-run) CLOUD_DRY_RUN=1; shift;;
    -h|--help) sed -n '2,8p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

cloud_setup >/dev/null 2>&1

# Build path; AWS supports ?name=<glob>.
PATH_="/v1/compute/images"
if [[ "$(cloud_provider)" == "aws" && -n "$NAME_FILTER" ]]; then
  ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$NAME_FILTER")
  PATH_="/v1/compute/images?name=${ENC}"
fi

RESP=$(cloud_api_or_die GET "$PATH_") || exit $?

python3 - "$RESP" "$FAMILY" "$ARCH" "$FORMAT" <<'PY'
import json, sys
resp, fam, arch, fmt = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
imgs = json.loads(resp).get("data", []) or []
if fam:
    imgs = [i for i in imgs if fam.lower() in (i.get("name") or "").lower()]
if arch:
    imgs = [i for i in imgs if (i.get("extra") or {}).get("architecture","").lower() == arch.lower()]
if fmt == "json":
    print(json.dumps(imgs, indent=2)); sys.exit(0)
if not imgs: print("(no images)"); sys.exit(0)
print(f"{'id':<36} {'name':<40} {'os':<14} {'arch':<10} {'size_gb':<8}")
for i in imgs:
    ex = i.get("extra") or {}
    print(f"{i.get('id',''):<36} {(i.get('name') or '')[:38]:<40} "
          f"{(ex.get('os') or ex.get('architecture') or '-'):<14} "
          f"{(ex.get('architecture') or '-'):<10} "
          f"{(i.get('size') or '-'):<8}")
PY
