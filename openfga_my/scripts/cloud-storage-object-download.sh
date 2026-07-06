#!/usr/bin/env bash
# cloud-storage-object-download.sh — download an object from a bucket via libcloud REST.
#
# The REST API returns the object payload base64-encoded (data_b64); this script
# decodes it to the --out path.
#
#   cloud-storage-object-download.sh --bucket <b> --key <k> --out <path>
#       [--provider aws|nutanix] [--region R] [--dry-run]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cloud_common.sh
source "${SCRIPT_DIR}/cloud_common.sh"

BUCKET="" KEY="" OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)  BUCKET="$2"; shift 2;;
    --key)     KEY="$2"; shift 2;;
    --out)     OUT="$2"; shift 2;;
    --provider)CLOUD_PROVIDER="$2"; shift 2;;
    --region)  CLOUD_REGION="$2"; shift 2;;
    --dry-run) CLOUD_DRY_RUN=1; shift;;
    -h|--help) sed -n '2,7p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ -n "$BUCKET" && -n "$KEY" && -n "$OUT" ]] || { echo "--bucket, --key and --out are required" >&2; exit 2; }

cloud_setup >/dev/null 2>&1

if [[ "${CLOUD_DRY_RUN}" == "1" ]]; then
  echo "[dry-run] POST /v1/storage/buckets/${BUCKET}/objects/${KEY}:download -> ${OUT}" >&2
  exit 0
fi

RESP=$(cloud_api POST "/v1/storage/buckets/${BUCKET}/objects/${KEY}:download" "") || { echo "object download failed" >&2; exit 4; }
B64=$(echo "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("data",{}).get("data_b64",""))' 2>/dev/null || echo "")
[[ -n "$B64" ]] || { echo "no payload in download response: ${RESP:0:200}" >&2; exit 4; }
python3 -c 'import base64,sys; sys.stdout.buffer.write(base64.b64decode(sys.argv[1]))' "$B64" > "$OUT"
cloud_audit "{\"ts\":\"$(cloud_now)\",\"actor\":\"${LIBCLOUD_USER}\",\"action\":\"object-download\",\"provider\":\"$(cloud_provider)\",\"bucket\":\"${BUCKET}\",\"key\":\"${KEY}\",\"out\":\"${OUT}\",\"result\":\"ok\"}"
echo "downloaded ${KEY} from ${BUCKET} -> ${OUT}"
