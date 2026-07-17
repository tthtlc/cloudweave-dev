#!/usr/bin/env bash
# Sequentially query every GET endpoint listed in a URL file against the
# libcloud REST API. Provider-agnostic: set CLOUD_PROVIDER=aws|nutanix and the
# corresponding tenant env (TENANT, LIBCLOUD_USER, LIBCLOUD_PASSWORD*).
#
# Auth credential construction mirrors ./scripts/provision_aws.sh and
# ./scripts/provision_nutanix.sh:
#   idp_login  -> Dex OIDC access token (bearer for libcloud REST)
#   build_*_connection_param -> X-Provider-Connection header (auth_binding
#                               selects the per-tenant Vault backend identity)
#   libcloud_api GET <path> -> the actual query, with the bearer + connection
#
# Usage:
#   URL_FILE=/tmp/oo CLOUD_PROVIDER=aws    LIBCLOUD_USER=aws-admin  ./scripts/query_urls.sh
#   URL_FILE=/tmp/oo CLOUD_PROVIDER=nutanix LIBCLOUD_USER=ntnx-admin ./scripts/query_urls.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

URL_FILE="${URL_FILE:-/tmp/oo}"
PROVIDER="${CLOUD_PROVIDER:-aws}"
[[ -f "${URL_FILE}" ]] || { echo "URL file not found: ${URL_FILE}" >&2; exit 1; }

# Step 1: OIDC login (Dex, LLDAP-backed) for the calling tenant user.
idp_login

# Step 2-3: build the provider connection selector (no secrets on the client).
case "${PROVIDER}" in
  aws)
    AWS_REGION="${AWS_REGION:-ap-southeast-1}"
    build_aws_connection_param "${AWS_REGION}"
    ;;
  nutanix)
    build_nutanix_connection_param
    ;;
  *)
    echo "Unknown CLOUD_PROVIDER='${PROVIDER}' (expected aws|nutanix)" >&2
    exit 1
    ;;
esac

# Validate the bearer token and backend connectivity before querying.
libcloud_me
libcloud_connection_test "$(connection_json)"

# Extract every "GET /v1/..." path from the URL file, strip trailing commas,
# and de-duplicate while preserving first-seen order.
extract_get_paths() {
  grep -oE 'GET[[:space:]]+/v1/[^[:space:],]+' "${URL_FILE}" \
    | awk '{print $2}' \
    | awk '!seen[$0]++'
}

# Resolve {node_id}-style placeholders against a live listing so the per-node
# GET endpoint can still be exercised. Returns "" when no live id exists.
resolve_path() {
  local path="$1"
  if [[ "${path}" == *'{node_id}'* ]]; then
    local first_id
    first_id=$(libcloud_api GET "/v1/compute/nodes" \
      | python3 -c 'import json,sys
d=json.load(sys.stdin)
nodes=d.get("data",[]) if isinstance(d,dict) else d
print(nodes[0]["id"] if nodes else "")' 2>/dev/null || true)
    if [[ -z "${first_id}" ]]; then
      echo ""
      return
    fi
    echo "${path/\{node_id\}/${first_id}}"
    return
  fi
  echo "${path}"
}

mapfile -t PATHS < <(extract_get_paths)

if [[ ${#PATHS[@]} -eq 0 ]]; then
  echo "No GET /v1/... endpoints found in ${URL_FILE}" >&2
  exit 1
fi

step "Q" "Sequentially querying ${#PATHS[@]} GET endpoint(s) from ${URL_FILE} (provider=${PROVIDER}, user=${LIBCLOUD_USER})"

for p in "${PATHS[@]}"; do
  resolved="$(resolve_path "${p}")"
  if [[ -z "${resolved}" ]]; then
    echo "skip (no live id to substitute for placeholder): ${p}"
    continue
  fi
  if [[ "${resolved}" == *'{'*'}'* ]]; then
    echo "skip (unresolved placeholder): ${resolved}"
    continue
  fi
  step ">" "GET ${resolved}"
  libcloud_api GET "${resolved}" | json_pretty
done

echo
echo "Sequential query flow completed (provider=${PROVIDER})."
