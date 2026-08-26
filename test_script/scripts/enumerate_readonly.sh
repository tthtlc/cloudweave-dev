#!/usr/bin/env bash
# enumerate_readonly.sh — enumerate every read-only (GET) resource for AWS and Nutanix.
#
# Sends only GET requests (no create/update/delete). Iterates the read-only
# endpoints of the libcloud REST API and pretty-prints the JSON response for
# each provider, skipping endpoints that a provider does not support.
#
# Usage:
#   enumerate_readonly.sh [--provider aws|nutanix|all] [--with-detail] [--dry-run]
#
#   --provider      which backend(s) to enumerate (default: all)
#   --with-detail   also GET the single-item detail endpoint for the first id
#                   returned by each list (e.g. /v1/compute/nodes/{id})
#   --dry-run       print the requests without executing them (still needs a token)
#
# Auth: reuses the cloud-* token resolution (SUPERADMIN_JWT > cached
# generated/tokens/superadmin.jwt > fresh Dex idp_login). Override with
# LIBCLOUD_USER / LIBCLOUD_ACCESS_TOKEN as needed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cloud_common.sh
source "${SCRIPT_DIR}/cloud_common.sh"

# ── arguments ────────────────────────────────────────────────────────────────
PROVIDERS="all"
WITH_DETAIL=0
DRY_RUN="${CLOUD_DRY_RUN:-0}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) PROVIDERS="$2"; shift 2 ;;
    --with-detail) WITH_DETAIL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "${PROVIDERS}" in
  all)     RUN_PROVIDERS=(aws nutanix) ;;
  aws)     RUN_PROVIDERS=(aws) ;;
  nutanix) RUN_PROVIDERS=(nutanix) ;;
  *) echo "FATAL: --provider must be aws|nutanix|all (got '${PROVIDERS}')" >&2; exit 2 ;;
esac

# ── read-only endpoint inventory (list endpoints; no path params) ───────────
# Shared endpoints need no X-Provider-Connection header.
SHARED=(/health /v1/auth/me /v1/providers)

# Applicable to both providers.
BOTH=(
  /v1/compute/locations
  /v1/compute/images
  /v1/compute/sizes
  /v1/compute/nodes
  /v1/compute/volumes
  /v1/compute/snapshots
  /v1/compute/networks
  /v1/compute/subnets
  /v1/compute/security-groups
  /v1/compute/load-balancers
  /v1/compute/floating-ips
)

# AWS-only (EC2/VPC/S3 concepts).
AWS_ONLY=(
  /v1/compute/key-pairs
  /v1/compute/internet-gateways
  /v1/compute/route-tables
  /v1/compute/network-interfaces
  /v1/storage/buckets
)

# Nutanix-only (Prism Central concepts).
NTNX_ONLY=(
  /v1/compute/storage-containers
)

# ── helpers ──────────────────────────────────────────────────────────────────
# http_get <path> [use_conn] — perform a GET; sets ENUM_BODY (raw body) and
# ENUM_CODE (HTTP status) in the current shell, so callers can read both without
# a command-substitution subshell losing the status code.
http_get() {
  local path="$1" use_conn="${2:-1}" tmp_body
  tmp_body=$(mktemp)
  local -a args=(-sS -w '%{http_code}' -o "${tmp_body}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Accept: application/json")
  if [[ "$use_conn" == "1" ]]; then
    args+=(-H "X-Provider-Connection: ${CONNECTION_PARAM}")
  fi
  ENUM_CODE=$(curl "${args[@]}" "${LIBCLOUD_REST_URL}${path}" 2>/dev/null || echo "000")
  ENUM_BODY=$(cat "${tmp_body}")
  rm -f "${tmp_body}"
}

# do_get <path> [use_conn] — pretty-printed GET, non-fatal on errors.
do_get() {
  local path="$1" use_conn="${2:-1}"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'GET %s%s\n' "${LIBCLOUD_REST_URL}" "${path}"
    return 0
  fi
  http_get "$path" "$use_conn"
  printf '── GET %s  [HTTP %s]\n' "${path}" "${ENUM_CODE}"
  if [[ "$ENUM_CODE" == "200" ]]; then
    printf '%s' "${ENUM_BODY}" | json_pretty || true
  else
    echo "${ENUM_BODY:0:400}"
  fi
  echo
}

# Map a list path -> "detail-template|id-field" (empty if no detail endpoint).
detail_spec_for() {
  case "$1" in
    /v1/compute/nodes)            echo "/v1/compute/nodes/{id}|id" ;;
    /v1/compute/images)           echo "/v1/compute/images/{id}|id" ;;
    /v1/compute/volumes)          echo "/v1/compute/volumes/{id}|id" ;;
    /v1/compute/snapshots)        echo "/v1/compute/snapshots/{id}|id" ;;
    /v1/compute/networks)         echo "/v1/compute/networks/{id}|id" ;;
    /v1/compute/subnets)          echo "/v1/compute/subnets/{id}|id" ;;
    /v1/compute/security-groups)  echo "/v1/compute/security-groups/{id}|id" ;;
    /v1/compute/load-balancers)   echo "/v1/compute/load-balancers/{id}|id" ;;
    /v1/compute/floating-ips)     echo "/v1/compute/floating-ips/{id}|address" ;;
    /v1/compute/key-pairs)        echo "/v1/compute/key-pairs/{id}|name" ;;
    /v1/compute/route-tables)     echo "/v1/compute/route-tables/{id}/routes|id" ;;
    /v1/storage/buckets)          echo "/v1/storage/buckets/{id}/objects|name" ;;
    *)                            echo "" ;;
  esac
}

# first_value <json> <field> — first non-empty value of `field` in a
# success_response body's data[0]. Exits 1 if there is no data / no field.
first_value() {
  local json="$1" field="$2"
  FIELD="$field" python3 -c '
import json, os, sys
d = json.loads(sys.argv[1])
data = d.get("data", []) if isinstance(d, dict) else d
if not isinstance(data, list) or not data:
    sys.exit(1)
first = data[0] if isinstance(data[0], dict) else {}
v = first.get(os.environ["FIELD"], "")
if not v:
    sys.exit(1)
sys.stdout.write(str(v))
' "$json"
}

# enumerate_endpoint <path> — list the resource; with --with-detail, also GET the
# first item's detail endpoint when one exists.
enumerate_endpoint() {
  local path="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'GET %s%s\n' "${LIBCLOUD_REST_URL}" "${path}"
    return 0
  fi
  http_get "$path" 1
  printf '── GET %s  [HTTP %s]\n' "${path}" "${ENUM_CODE}"
  if [[ "$ENUM_CODE" == "200" ]]; then
    printf '%s' "${ENUM_BODY}" | json_pretty || true
    echo
    if [[ "$WITH_DETAIL" == "1" ]]; then
      detail_from_resp "$path" "${ENUM_BODY}"
    fi
  else
    echo "${ENUM_BODY:0:400}"
    echo
  fi
}

# detail_from_resp <list_path> <list_body> — resolve + GET the first item's detail.
detail_from_resp() {
  local list_path="$1" resp="$2" spec detail field id
  spec=$(detail_spec_for "$list_path")
  [[ -n "$spec" ]] || return 0
  detail="${spec%%|*}"
  field="${spec##*|}"
  id=$(first_value "$resp" "$field" 2>/dev/null || true)
  if [[ -z "$id" ]]; then
    echo "   (no '${field}' in response; cannot resolve detail ${detail})"
    return 0
  fi
  do_get "${detail/\{id\}/$id}" 1
}

# ── main ─────────────────────────────────────────────────────────────────────
print_shared() {
  local p
  echo "════════════════════════════════════════════════════════════════════"
  echo " SHARED endpoints (no provider connection required)"
  echo "════════════════════════════════════════════════════════════════════"
  for p in "${SHARED[@]}"; do
    do_get "$p" 0
  done
}

run_provider() {
  local provider="$1" ep
  case "$provider" in
    aws)     build_aws_connection_param ;;
    nutanix) build_nutanix_connection_param ;;
  esac

  echo
  echo "════════════════════════════════════════════════════════════════════"
  echo " PROVIDER: ${provider}"
  echo "════════════════════════════════════════════════════════════════════"
  connection_json
  echo

  local -a eps=("${BOTH[@]}")
  case "$provider" in
    aws)     eps+=("${AWS_ONLY[@]}") ;;
    nutanix) eps+=("${NTNX_ONLY[@]}") ;;
  esac

  for ep in "${eps[@]}"; do
    enumerate_endpoint "$ep"
  done
}

print_shared
for provider in "${RUN_PROVIDERS[@]}"; do
  run_provider "$provider"
done

echo "Note: GET /v1/jobs/{job_id} is read-only but needs a job id from a prior"
echo "async (execution.mode=async) call, so it is not enumerated here."
