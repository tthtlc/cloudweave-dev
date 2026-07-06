#!/usr/bin/env bash
# cloud-storage-bucket-delete.sh — delete an object-storage bucket via libcloud REST.
#
# By default refuses a non-empty bucket (HTTP 409). --force empties it first by
# listing and deleting every object, then deletes the bucket.
#
#   cloud-storage-bucket-delete.sh --name <bucket> [--force] [--confirm]
#       [--provider aws|nutanix] [--region R] [--dry-run]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cloud_common.sh
source "${SCRIPT_DIR}/cloud_common.sh"

NAME="" FORCE=0 CONFIRM=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)     NAME="$2"; shift 2;;
    --force)    FORCE=1; shift;;
    --confirm)  CONFIRM=1; shift;;
    --provider) CLOUD_PROVIDER="$2"; shift 2;;
    --region)   CLOUD_REGION="$2"; shift 2;;
    --dry-run)  CLOUD_DRY_RUN=1; shift;;
    -h|--help)  sed -n '2,8p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ -n "$NAME" ]] || { echo "--name is required" >&2; exit 2; }
[[ "$CONFIRM" == "1" || "${CLOUD_DRY_RUN}" == "1" ]] || {
  echo "destructive operation: pass --confirm to delete bucket '${NAME}'" >&2; exit 2; }

cloud_setup >/dev/null 2>&1

if [[ "${CLOUD_DRY_RUN}" == "1" ]]; then
  echo "[dry-run] DELETE /v1/storage/buckets/${NAME} force=${FORCE}" >&2
  exit 0
fi

# --force: empty the bucket first (best-effort, ignore per-object failures).
if [[ "$FORCE" == "1" ]]; then
  OBJRESP=$(cloud_api_or_die GET "/v1/storage/buckets/${NAME}/objects")
  mapfile -t ONAMES < <(echo "$OBJRESP" | python3 -c '
import json, sys
d = json.load(sys.stdin).get("data", []) or []
for o in d: print(o.get("name",""))
')
  for on in "${ONAMES[@]}"; do
    [[ -z "$on" ]] && continue
    echo "deleting object ${on} from ${NAME} (--force)" >&2
    cloud_api DELETE "/v1/storage/buckets/${NAME}/objects/${on}" >/dev/null 2>&1 || true
  done
fi

RESP=$(cloud_api DELETE "/v1/storage/buckets/${NAME}") || {
  code=$(echo "$RESP" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("error",{}).get("code",""))' 2>/dev/null || echo "")
  if [[ "$code" == "bucket_not_empty" ]]; then
    echo "bucket '${NAME}' is not empty; pass --force to empty + delete it." >&2
  fi
  echo "bucket delete failed: ${RESP:0:200}" >&2; exit 4; }
cloud_audit "{\"ts\":\"$(cloud_now)\",\"actor\":\"${LIBCLOUD_USER}\",\"action\":\"bucket-delete\",\"provider\":\"$(cloud_provider)\",\"name\":\"${NAME}\",\"result\":\"ok\"}"
echo "$RESP" | json_pretty
