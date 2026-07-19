#!/usr/bin/env bash
# deprovision_aws.sh
# ==================
# Deprovision (delete) the AWS VMs created by provision_aws.sh.
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
# REST requires `can_provision` on aws_region:<binding>. Only the tenant
# owner/admin hold that — viewers are denied by OpenFGA and by the REST policy.
#
# By default it deletes every VM whose name starts with "libcloud-demo-"
# (exactly the VMs provision_aws.sh creates). Set VM_NAME to delete one VM by
# name, or VM_ID to delete one VM by its libcloud REST node id (precise: no
# list+filter pass, the DELETE is issued directly against that id). VM_ID takes
# precedence over VM_NAME when both are set.
#
# Usage:
#   LIBCLOUD_USER=aws-admin ./scripts/deprovision_aws.sh
#   LIBCLOUD_AWS_AUTH_BINDING=aws-dev LIBCLOUD_USER=aws-dev-admin ./scripts/deprovision_aws.sh
#   VM_NAME=libcloud-demo-1234567890 LIBCLOUD_USER=aws-admin ./scripts/deprovision_aws.sh
#   VM_ID=i-0abc123            LIBCLOUD_USER=aws-admin ./scripts/deprovision_aws.sh
#
# Prerequisites:
#   ./setup.sh  and  a token cache for the user at generated/tokens/<user>.json
#   (created by ./scripts/provision_aws.sh or scripts/idp_login.py).
set -euo pipefail

# Default to the AWS tenant admin (can_provision). Set BEFORE sourcing common.sh
# so its password/env resolution picks up the right user.
export LIBCLOUD_USER="${LIBCLOUD_USER:-aws-admin}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"   # env vars only; we never call its python helpers

AWS_REGION="${AWS_REGION:-ap-southeast-1}"
LIBCLOUD_AWS_AUTH_BINDING="${LIBCLOUD_AWS_AUTH_BINDING:-${TENANT:-aws}}"
BACKEND_OBJECT="aws_region:${LIBCLOUD_AWS_AUTH_BINDING}"
DEX_TOKEN_URL="${DEX_TOKEN_URL:-${DEX_URL}/dex/token}"
ACCESS_TOKEN=""
CONNECTION_PARAM=""

# --------------------------------------------------------------------------- #
# curl + jq helpers (no python)
# --------------------------------------------------------------------------- #

# Acquire an OIDC access token using curl + jq. Reads the token cache that
# provision_aws.sh / idp_login.py wrote, refreshes it via a curl POST to the
# Dex token endpoint, and persists the refreshed token. Falls back to the
# cached access_token if refresh is unavailable.
require_token() {
  # Mirror idp_login.py: cache dir is IDP_TOKEN_CACHE_DIR (default
  # "generated/tokens"), resolved relative to CWD so the cache written by
  # provision_aws.sh / idp_login.py (run from the repo root) is found here too.
  local cache_dir="${IDP_TOKEN_CACHE_DIR:-generated/tokens}"
  local cache="${cache_dir}/${LIBCLOUD_USER}.json"
  if [[ ! -f "${cache}" ]]; then
    # Fall back to the legacy script-relative location for backwards compat.
    local legacy="${REPO_ROOT}/generated/tokens/${LIBCLOUD_USER}.json"
    if [[ -f "${legacy}" ]]; then
      cache="${legacy}"
    else
      echo "FATAL: no token cache at ${cache}." >&2
      echo "       Run ./scripts/provision_aws.sh (or scripts/idp_login.py) as ${LIBCLOUD_USER} first." >&2
      return 1
    fi
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
    echo "FATAL: no usable access token for ${LIBCLOUD_USER}; re-run ./scripts/provision_aws.sh." >&2
    return 1
  fi
}

# Build the X-Provider-Connection header value (provider + region + auth_binding,
# NO credentials) with jq.
connection_param() {
  jq -nc --arg region "${AWS_REGION}" --arg binding "${LIBCLOUD_AWS_AUTH_BINDING}" \
    '{provider:"aws",config:{region:$region,secure:true},auth_binding:$binding}'
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
fga_check "user:${LIBCLOUD_USER}" "can_use" "provider:aws"
fga_check "user:${LIBCLOUD_USER}" "can_provision" "${BACKEND_OBJECT}"

step "3" "List compute nodes (curl GET /v1/compute/nodes)"
NODES=$(rest GET "/v1/compute/nodes")
printf '%s\n' "${NODES}" | jq .

# VM_ID: precise single-VM delete — skip the list/filter pass and DELETE the
# exact id the caller supplied. This is what the portal's per-row Deprovision
# button uses (it already has the VM id from GET /v1/compute/nodes). VM_ID takes
# precedence over VM_NAME when both are set.
VM_ID_FILTER="${VM_ID:-}"
if [[ -n "${VM_ID_FILTER}" ]]; then
  step "4" "Delete libcloud VM by id (curl DELETE /v1/compute/nodes/${VM_ID_FILTER})"
  echo "Deleting node id=${VM_ID_FILTER}"
  rest DELETE "/v1/compute/nodes/${VM_ID_FILTER}" | jq . 2>/dev/null || true
  echo "Deleted 1 libcloud VM by id (${VM_ID_FILTER})."
else
  step "4" "Delete libcloud demo VMs (curl DELETE /v1/compute/nodes/{id})"
  VM_NAME_FILTER="${VM_NAME:-}"
  IDS=$(printf '%s\n' "${NODES}" | jq -r --arg filter "${VM_NAME_FILTER}" '
    (.data // .) | .[] | select(.id and .name) |
    if ($filter | length) > 0
    then select(.name == $filter)
    else select(.name | startswith("libcloud-demo-"))
    end | "\(.id)\t\(.name)"' 2>/dev/null || true)

  if [[ -z "${IDS}" ]]; then
    echo "No matching libcloud demo VMs found to delete."
  else
    count=0
    while IFS=$'\t' read -r id name; do
      [[ -z "${id}" ]] && continue
      count=$((count + 1))
      echo "Deleting node id=${id} name=${name}"
      rest DELETE "/v1/compute/nodes/${id}" | jq . 2>/dev/null || true
    done <<<"${IDS}"
    echo "Deleted ${count} libcloud demo VM(s)."
  fi
fi

echo
echo "AWS deprovisioning flow completed (user=${LIBCLOUD_USER}, binding=${LIBCLOUD_AWS_AUTH_BINDING})."
