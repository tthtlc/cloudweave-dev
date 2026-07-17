#!/usr/bin/env bash
# cloud-floatingip-allocate.sh — allocate a floating (elastic) IP via libcloud REST.
#
#   cloud-floatingip-allocate.sh [--domain vpc|standard]
#       [--provider aws|nutanix] [--region R] [--dry-run]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cloud_common.sh
source "${SCRIPT_DIR}/cloud_common.sh"

DOMAIN="vpc"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)   DOMAIN="$2"; shift 2;;
    --provider) CLOUD_PROVIDER="$2"; shift 2;;
    --region)   CLOUD_REGION="$2"; shift 2;;
    --dry-run)  CLOUD_DRY_RUN=1; shift;;
    -h|--help)  sed -n '2,6p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

cloud_setup >/dev/null 2>&1

BODY=$(DOMAIN="$DOMAIN" python3 -c '
import os, json
print(json.dumps({"domain": os.environ["DOMAIN"]}))
')
CREATE_BODY=$(with_connection "$BODY")

if [[ "${CLOUD_DRY_RUN}" == "1" ]]; then
  echo "[dry-run] POST /v1/compute/floating-ips domain=${DOMAIN}" >&2
  echo "$CREATE_BODY" >&2
  exit 0
fi

RESP=$(cloud_api POST /v1/compute/floating-ips "$CREATE_BODY") || { echo "floating IP allocate failed" >&2; exit 4; }
ADDR=$(echo "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("data",{}).get("address",""))' 2>/dev/null || echo "")
cloud_audit "{\"ts\":\"$(cloud_now)\",\"actor\":\"${LIBCLOUD_USER}\",\"action\":\"floatingip-allocate\",\"provider\":\"$(cloud_provider)\",\"domain\":\"${DOMAIN}\",\"address\":\"${ADDR}\",\"result\":\"ok\"}"
echo "$RESP" | json_pretty
