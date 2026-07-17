#!/usr/bin/env bash
# cloud-storage-bucket-create.sh — create an object-storage bucket via libcloud REST.
#
# Idempotent: the REST API treats "already exists" as success (returns the
# existing bucket), so re-running is safe.
#
#   cloud-storage-bucket-create.sh --name <bucket> [--location R] [--tag k=v ...]
#       [--provider aws|nutanix] [--region R] [--dry-run]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cloud_common.sh
source "${SCRIPT_DIR}/cloud_common.sh"

NAME="" LOCATION=""
declare -a TAGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)     NAME="$2"; shift 2;;
    --location) LOCATION="$2"; shift 2;;
    --tag)      TAGS+=("$2"); shift 2;;
    --provider) CLOUD_PROVIDER="$2"; shift 2;;
    --region)   CLOUD_REGION="$2"; shift 2;;
    --dry-run)  CLOUD_DRY_RUN=1; shift;;
    -h|--help)  sed -n '2,8p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ -n "$NAME" ]] || { echo "--name is required" >&2; exit 2; }

cloud_setup >/dev/null 2>&1

BODY=$(NAME="$NAME" LOCATION="$LOCATION" TAGS_JSON=$(printf '%s\n' "${TAGS[@]}" | python3 -c '
import sys, json
tags = {}
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    if "=" in line:
        k, v = line.split("=", 1)
    else:
        k, v = line, ""
    tags[k] = v
print(json.dumps(tags))
') python3 -c '
import os, json
body = {"name": os.environ["NAME"]}
if os.environ.get("LOCATION"): body["location"] = os.environ["LOCATION"]
body["tags"] = json.loads(os.environ["TAGS_JSON"])
print(json.dumps(body))
')

CREATE_BODY=$(with_connection "$BODY")

if [[ "${CLOUD_DRY_RUN}" == "1" ]]; then
  echo "[dry-run] POST /v1/storage/buckets name=${NAME} location=${LOCATION}" >&2
  echo "$CREATE_BODY" >&2
  exit 0
fi

RESP=$(cloud_api POST /v1/storage/buckets "$CREATE_BODY") || { echo "bucket create failed" >&2; exit 4; }
BNAME=$(echo "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("data",{}).get("name",""))' 2>/dev/null || echo "")
cloud_audit "{\"ts\":\"$(cloud_now)\",\"actor\":\"${LIBCLOUD_USER}\",\"action\":\"bucket-create\",\"provider\":\"$(cloud_provider)\",\"name\":\"${NAME}\",\"result\":\"ok\",\"bucket\":\"${BNAME}\"}"
echo "$RESP" | json_pretty
