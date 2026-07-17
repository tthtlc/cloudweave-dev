#!/usr/bin/env bash
# cloud-storage-object-upload.sh — upload an object to a bucket via libcloud REST.
#
# The file payload is base64-encoded and sent in the JSON body (data_b64); use
# --param-file to supply extra metadata/content_type from a JSON file.
#
#   cloud-storage-object-upload.sh --bucket <b> --key <k> --file <path>
#       [--content-type T] [--meta k=v ...] [--param-file path.json]
#       [--provider aws|nutanix] [--region R] [--dry-run]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cloud_common.sh
source "${SCRIPT_DIR}/cloud_common.sh"

BUCKET="" KEY="" FILE="" CTYPE="" PARAM_FILE=""
declare -a META=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)      BUCKET="$2"; shift 2;;
    --key)         KEY="$2"; shift 2;;
    --file)        FILE="$2"; shift 2;;
    --content-type)CTYPE="$2"; shift 2;;
    --meta)        META+=("$2"); shift 2;;
    --param-file)  PARAM_FILE="$2"; shift 2;;
    --provider)    CLOUD_PROVIDER="$2"; shift 2;;
    --region)      CLOUD_REGION="$2"; shift 2;;
    --dry-run)     CLOUD_DRY_RUN=1; shift;;
    -h|--help)     sed -n '2,9p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ -n "$BUCKET" && -n "$KEY" ]] || { echo "--bucket and --key are required" >&2; exit 2; }

if [[ "${CLOUD_DRY_RUN}" != "1" ]]; then
  [[ -n "$FILE" && -f "$FILE" ]] || { echo "--file <existing path> is required" >&2; exit 2; }
fi

cloud_setup >/dev/null 2>&1

DATA_B64="AA=="
[[ "${CLOUD_DRY_RUN}" != "1" ]] && DATA_B64=$(base64 -w 0 "$FILE")

BODY=$(BUCKET="$BUCKET" KEY="$KEY" CTYPE="$CTYPE" PARAM_FILE="$PARAM_FILE" META_JSON=$(printf '%s\n' "${META[@]}" | python3 -c '
import sys, json
m = {}
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    k, v = line.split("=", 1) if "=" in line else (line, "")
    m[k] = v
print(json.dumps(m))
') DATA_B64="$DATA_B64" python3 -c '
import os, json
body = {"bucket": os.environ["BUCKET"], "object_name": os.environ["KEY"], "data_b64": os.environ["DATA_B64"]}
pf = os.environ.get("PARAM_FILE")
if pf and os.path.exists(pf):
    extra = json.load(open(pf))
    if "content_type" in extra: os.environ.setdefault("CTYPE", extra["content_type"]) or None
    body.setdefault("metadata", extra.get("metadata", {}))
else:
    body.setdefault("metadata", {})
md = json.loads(os.environ["META_JSON"])
body["metadata"].update(md)
if os.environ.get("CTYPE"): body["content_type"] = os.environ["CTYPE"]
print(json.dumps(body))
')

CREATE_BODY=$(with_connection "$BODY")

if [[ "${CLOUD_DRY_RUN}" == "1" ]]; then
  echo "[dry-run] POST /v1/storage/buckets/${BUCKET}/objects key=${KEY} bytes=$(wc -c < "$FILE" 2>/dev/null || echo 0)" >&2
  exit 0
fi

RESP=$(cloud_api POST "/v1/storage/buckets/${BUCKET}/objects" "$CREATE_BODY") || { echo "object upload failed" >&2; exit 4; }
ONAME=$(echo "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("data",{}).get("name",""))' 2>/dev/null || echo "")
cloud_audit "{\"ts\":\"$(cloud_now)\",\"actor\":\"${LIBCLOUD_USER}\",\"action\":\"object-upload\",\"provider\":\"$(cloud_provider)\",\"bucket\":\"${BUCKET}\",\"key\":\"${ONAME}\",\"result\":\"ok\"}"
echo "$RESP" | json_pretty
