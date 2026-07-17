#!/usr/bin/env bash
# cloud-floatingip-release.sh — release a floating (elastic) IP via libcloud REST.
#
#   cloud-floatingip-release.sh --address <ip> [--domain vpc|standard] [--confirm]
#       [--provider aws|nutanix] [--region R] [--dry-run]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cloud_common.sh
source "${SCRIPT_DIR}/cloud_common.sh"

ADDRESS="" DOMAIN="" CONFIRM=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --address)  ADDRESS="$2"; shift 2;;
    --domain)   DOMAIN="$2"; shift 2;;
    --confirm)  CONFIRM=1; shift;;
    --provider) CLOUD_PROVIDER="$2"; shift 2;;
    --region)   CLOUD_REGION="$2"; shift 2;;
    --dry-run)  CLOUD_DRY_RUN=1; shift;;
    -h|--help)  sed -n '2,6p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ -n "$ADDRESS" ]] || { echo "--address is required" >&2; exit 2; }
[[ "$CONFIRM" == "1" || "${CLOUD_DRY_RUN}" == "1" ]] || {
  echo "destructive operation: pass --confirm to release '${ADDRESS}'" >&2; exit 2; }

cloud_setup >/dev/null 2>&1

PATH_="/v1/compute/floating-ips/${ADDRESS}"
[[ -n "$DOMAIN" ]] && PATH_="${PATH_}?domain=${DOMAIN}"

if [[ "${CLOUD_DRY_RUN}" == "1" ]]; then
  echo "[dry-run] DELETE ${PATH_}" >&2
  exit 0
fi

RESP=$(cloud_api DELETE "$PATH_") || { echo "floating IP release failed: ${RESP:0:200}" >&2; exit 4; }
cloud_audit "{\"ts\":\"$(cloud_now)\",\"actor\":\"${LIBCLOUD_USER}\",\"action\":\"floatingip-release\",\"provider\":\"$(cloud_provider)\",\"address\":\"${ADDRESS}\",\"result\":\"ok\"}"
echo "$RESP" | json_pretty
