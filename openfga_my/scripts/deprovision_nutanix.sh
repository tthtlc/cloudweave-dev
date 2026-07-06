#!/usr/bin/env bash
# deprovision_nutanix.sh
# ======================
# Deprovision (delete) the Nutanix VMs created by provision_nutanix.sh.
#
# This script uses ONLY curl + jq. There is no python anywhere in this file:
#   * access token  -> curl POST to the Dex token endpoint (refresh) + jq
#   * OpenFGA check -> curl POST + jq
#   * list nodes    -> curl GET  /v1/compute/nodes           + jq
#   * delete node   -> curl DELETE /v1/compute/nodes/{id}
# common.sh is sourced ONLY to load environment variables (.env / generated
# env); none of its python-based helpers are called.
#
# Authorization: DELETE is a write scope (compute:node:delete), so libcloud
# REST requires `can_provision` on nutanix_cluster:<binding>. Only the tenant
# owner/admin hold that — viewers are denied by OpenFGA and by the REST policy.
#
# By default it deletes every VM whose name starts with "libcloud-ntnx-"
# (exactly the VMs provision_nutanix.sh creates). Set VM_NAME to delete one VM.
#
# Usage:
#   LIBCLOUD_USER=ntnx-admin ./scripts/deprovision_nutanix.sh
#   LIBCLOUD_NTNX_AUTH_BINDING=nutanix-dev LIBCLOUD_USER=ntnx-dev-admin ./scripts/deprovision_nutanix.sh
#   VM_NAME=libcloud-ntnx-1234567890 LIBCLOUD_USER=ntnx-admin ./scripts/deprovision_nutanix.sh
#
# Prerequisites:
#   ./setup.sh  and  a token cache for the user at generated/tokens/<user>.json
#   (created by ./scripts/provision_nutanix.sh or scripts/idp_login.py).
set -euo pipefail

# Default to the Nutanix tenant admin (can_provision). Set BEFORE sourcing
# common.sh so its password/env resolution picks up the right user.
export LIBCLOUD_USER="${LIBCLOUD_USER:-ntnx-admin}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"   # env vars only; we never call its python helpers

LIBCLOUD_NTNX_AUTH_BINDING="${LIBCLOUD_NTNX_AUTH_BINDING:-${TENANT:-nutanix}}"
NUTANIX_BACKEND_OBJECT="nutanix_cluster:${LIBCLOUD_NTNX_AUTH_BINDING}"
DEX_TOKEN_URL="${DEX_TOKEN_URL:-${DEX_URL}/dex/token}"
ACCESS_TOKEN=""
CONNECTION_PARAM=""

# --------------------------------------------------------------------------- #
# curl + jq helpers (no python)
# --------------------------------------------------------------------------- #

# Acquire an OIDC access token using curl + jq. Reads the token cache that
# provision_nutanix.sh / idp_login.py wrote, refreshes it via a curl POST to
# the Dex token endpoint, and persists the refreshed token. Falls back to the
# cached access_token if refresh is unavailable.
require_token() {
  local cache="${ROOT}/generated/tokens/${LIBCLOUD_USER}.json"
  if [[ ! -f "${cache}" ]]; then
    echo "FATAL: no token cache at ${cache}." >&2
    echo "       Run ./scripts/provision_nutanix.sh (or scripts/idp_login.py) as ${LIBCLOUD_USER} first." >&2
    return 1
  fi

  local refresh resp fresh fresh_refresh
  refresh=$(jq -r '.refresh_token // empty' "${cache}" 2>/dev/null || true)
  if [[ -n "${refresh}" ]]; then
    resp=$(curl -sS -X POST "${DEX_TOKEN_URL}" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-urlencode "grant_type=refresh_token" \
      --data-urlencode "refresh_token=${refresh}" \
      --data-urlencode "client_id=${LIBCLOUD_OIDC_CLIENT_ID}" \
      --data-urlencode "client_secret=${LIBCLOUD_OIDC_CLIENT_SECRET}" 2>/dev/null || true)
    fresh=$(printf '%s' "${resp}" | jq -r '.access_token // empty' 2>/dev/null || true)
    if [[ -n "${fresh}" ]]; then
      fresh_refresh=$(printf '%s' "${resp}" | jq -r '.refresh_token // empty' 2>/dev/null || true)
      jq --arg a "${fresh}" --arg r "${fresh_refresh:-${refresh}}" \
        '.access_token=$a | .refresh_token=$r' "${cache}" > "${cache}.tmp" && mv "${cache}.tmp" "${cache}"
      ACCESS_TOKEN="${fresh}"
      return 0
    fi
  fi

  ACCESS_TOKEN=$(jq -r '.access_token // empty' "${cache}" 2>/dev/null || true)
  if [[ -z "${ACCESS_TOKEN}" ]]; then
    echo "FATAL: no usable access token for ${LIBCLOUD_USER}; re-run ./scripts/provision_nutanix.sh." >&2
    return 1
  fi
}

# Build the X-Provider-Connection header value (provider + nutanix config +
# auth_binding, NO credentials) with jq. The REST API resolves the backend
# Nutanix credentials server-side from Vault using auth_binding.
connection_param() {
  local host="${NUTANIX_HOST:-host.docker.internal}"
  local port="${NUTANIX_PORT:-9440}"
  local api_version="${NUTANIX_API_VERSION:-v4.0}"
  local verify_ssl="${NUTANIX_VERIFY_SSL:-false}"
  local ssl_bool="false"
  case "${verify_ssl}" in
    1|true|True|TRUE|yes|Yes|YES) ssl_bool="true" ;;
  esac
  jq -nc --arg host "${host}" --argjson port "${port}" --arg api_version "${api_version}" \
       --argjson ssl "${ssl_bool}" --arg binding "${LIBCLOUD_NTNX_AUTH_BINDING}" \
    '{provider:"nutanix",config:{host:$host,port:$port,secure:true,api_version:$api_version,verify_ssl_cert:$ssl},auth_binding:$binding}'
}

# OpenFGA check: curl POST + jq parse. Returns 0 if allowed, 1 otherwise.
fga_check() {
  local u="$1" rel="$2" obj="$3" body allowed
  body=$(jq -nc --arg m "${FGA_MODEL_ID}" --arg u "${u}" --arg r "${rel}" --arg o "${obj}" \
    '{authorization_model_id:$m,tuple_key:{user:$u,relation:$r,object:$o}}')
  local -a hdrs=(-H "Content-Type: application/json" -H "Accept: application/json")
  if [[ -n "${ACCESS_TOKEN:-}" ]]; then
    hdrs+=(-H "Authorization: Bearer ${ACCESS_TOKEN}")
  fi
  allowed=$(curl -sS -X POST "${FGA_API_URL}/stores/${FGA_STORE_ID}/check" \
    "${hdrs[@]}" -d "${body}" | jq -r '.allowed // false')
  echo "Check ${u} ${rel} ${obj} -> allowed=${allowed}"
  [[ "${allowed}" == "true" ]]
}

# libcloud REST call: curl with Bearer + X-Provider-Connection headers.
rest() {
  local method="$1" path="$2" body="${3:-}"
  local -a args=(
    -sS -X "${method}" "${LIBCLOUD_REST_URL}${path}"
    -H "Authorization: Bearer ${ACCESS_TOKEN}"
    -H "Accept: application/json"
    -H "X-Provider-Connection: ${CONNECTION_PARAM}"
  )
  if [[ -n "${body}" ]]; then
    args+=(-H "Content-Type: application/json" -d "${body}")
  fi
  curl "${args[@]}"
}

# --------------------------------------------------------------------------- #
# Flow
# --------------------------------------------------------------------------- #

step "1" "Acquire access token for ${LIBCLOUD_USER} (curl + jq, from token cache)"
require_token
echo "access_token acquired (${#ACCESS_TOKEN} chars)"
CONNECTION_PARAM=$(connection_param)

step "2" "OpenFGA authorization checks (curl)"
fga_check "user:${LIBCLOUD_USER}" "can_connect" "${FGA_API_OBJECT}"
fga_check "user:${LIBCLOUD_USER}" "can_use" "provider:nutanix"
fga_check "user:${LIBCLOUD_USER}" "can_provision" "${NUTANIX_BACKEND_OBJECT}"

step "3" "List compute nodes (curl GET /v1/compute/nodes)"
NODES=$(rest GET "/v1/compute/nodes")
printf '%s\n' "${NODES}" | jq .

step "4" "Delete libcloud Nutanix VMs (curl DELETE /v1/compute/nodes/{id})"
VM_NAME_FILTER="${VM_NAME:-}"
IDS=$(printf '%s' "${NODES}" | jq -r --arg filter "${VM_NAME_FILTER}" '
  (.data // .) | .[] | select(.id and .name) |
  if ($filter | length) > 0
  then select(.name == $filter)
  else select(.name | startswith("libcloud-ntnx-"))
  end | "\(.id)\t\(.name)"' 2>/dev/null || true)

if [[ -z "${IDS}" ]]; then
  echo "No matching libcloud Nutanix VMs found to delete."
else
  count=0
  while IFS=$'\t' read -r id name; do
    [[ -z "${id}" ]] && continue
    count=$((count + 1))
    echo "Deleting node id=${id} name=${name}"
    rest DELETE "/v1/compute/nodes/${id}" | jq . 2>/dev/null || true
  done <<<"${IDS}"
  echo "Deleted ${count} libcloud Nutanix VM(s)."
fi

echo
echo "Nutanix deprovisioning flow completed (user=${LIBCLOUD_USER}, binding=${LIBCLOUD_NTNX_AUTH_BINDING})."
