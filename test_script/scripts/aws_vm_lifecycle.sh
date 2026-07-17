#!/usr/bin/env bash
# aws_vm_lifecycle.sh
# ===================
# End-to-end AWS VM lifecycle demo using ONLY curl + jq for every operation
# performed by THIS script (token acquisition, OpenFGA checks, listing).
# There is no python anywhere in this file.
#
# Flow (all as the AWS tenant ADMIN, who holds can_provision):
#   1/4  Provision a new VM     -> calls ./scripts/provision_aws.sh (PROVISION=1)
#   2/4  List all VMs           -> curl GET  /v1/compute/nodes
#   3/4  Deprovision all VMs    -> calls ./scripts/deprovision_aws.sh (curl DELETE)
#   4/4  List all VMs again     -> curl GET  /v1/compute/nodes
#
# Step 1 calls the existing ./scripts/provision_aws.sh (which uses idp_login.py
# for the OIDC callback flow and caches the token to generated/tokens/<user>.json).
# Steps 2-4 then reuse that token via curl + jq — no python.
#
# The admin role is required: create (POST) and delete (DELETE) are write
# scopes, so libcloud REST requires `can_provision` on aws_region:<binding>.
# A viewer would be denied at the OpenFGA check and by the REST policy.
#
# Usage:
#   ./scripts/aws_vm_lifecycle.sh
#   LIBCLOUD_AWS_AUTH_BINDING=aws-dev LIBCLOUD_USER=aws-dev-admin ./scripts/aws_vm_lifecycle.sh
#   VM_NAME=my-vm AWS_REGION=ap-southeast-1 ./scripts/aws_vm_lifecycle.sh
#
# Prerequisites:
#   ./setup.sh
#   libcloud REST API running at LIBCLOUD_REST_URL
#   Tenant backend credentials set in Vault by the tenant owner
#     (TENANT=aws CLOUD=aws LIBCLOUD_USER=aws-owner ... python3 scripts/set_tenant_credentials.py)
set -euo pipefail

# Default to the AWS tenant ADMIN (can_provision). Set BEFORE sourcing common.sh
# so its env resolution picks up the right user.
export LIBCLOUD_USER="${LIBCLOUD_USER:-aws-admin}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"   # env vars only; we never call its python helpers

AWS_REGION="${AWS_REGION:-ap-southeast-1}"
LIBCLOUD_AWS_AUTH_BINDING="${LIBCLOUD_AWS_AUTH_BINDING:-${TENANT:-aws}}"
BACKEND_OBJECT="aws_region:${LIBCLOUD_AWS_AUTH_BINDING}"
VM_NAME="${VM_NAME:-libcloud-demo-$(date +%s)}"
DEX_TOKEN_URL="${DEX_TOKEN_URL:-${DEX_URL}/dex/token}"
ACCESS_TOKEN=""
CONNECTION_PARAM=""

export AWS_REGION LIBCLOUD_AWS_AUTH_BINDING VM_NAME

# --------------------------------------------------------------------------- #
# curl + jq helpers (no python)
# --------------------------------------------------------------------------- #

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
      echo "       Step 1 (provision_aws.sh) should have created it; check the provision output." >&2
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
    echo "FATAL: no usable access token for ${LIBCLOUD_USER}." >&2
    return 1
  fi
}

connection_param() {
  jq -nc --arg region "${AWS_REGION}" --arg binding "${LIBCLOUD_AWS_AUTH_BINDING}" \
    '{provider:"aws",config:{region:$region,secure:true},auth_binding:$binding}'
}

fga_check() {
  local u="$1" rel="$2" obj="$3" body allowed
  body=$(jq -nc --arg m "${FGA_MODEL_ID}" --arg u "${u}" --arg r "${rel}" --arg o "${obj}" \
    '{authorization_model_id:$m,tuple_key:{user:$u,relation:$r,object:$o}}')
  allowed=$(curl -sS -X POST "${FGA_API_URL}/stores/${FGA_STORE_ID}/check" \
    -H "Content-Type: application/json" -d "${body}" | jq -r '.allowed // false')
  echo "Check ${u} ${rel} ${obj} -> allowed=${allowed}"
  [[ "${allowed}" == "true" ]]
}

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

# Preflight (curl + jq): verify the tenant's backend credentials exist in Vault
# at secret/data/libcloud/<binding>. Uses the Vault root token from
# ../vault/generated/vault.env (dev/demo preflight only). If the secret is
# missing, every REST backend call would fail with server_credentials_missing,
# so fail fast with the exact owner command to fix it.
preflight_tenant_credentials() {
  local venv="${REPO_ROOT}/vault/generated/vault.env"
  local vaddr vtoken resp
  vaddr=$(grep -h '^VAULT_ADDR=' "${venv}" 2>/dev/null | cut -d= -f2-); vaddr=${vaddr:-http://localhost:8200}
  vtoken=$(grep -h '^VAULT_ROOT_TOKEN=' "${venv}" 2>/dev/null | cut -d= -f2-)
  if [[ -z "${vtoken}" ]]; then
    echo "PREFLIGHT: no VAULT_ROOT_TOKEN found; skipping Vault secret check." >&2
    return 0
  fi
  resp=$(curl -sS -H "X-Vault-Token: ${vtoken}" "${vaddr}/v1/secret/data/libcloud/${LIBCLOUD_AWS_AUTH_BINDING}" 2>/dev/null || true)
  if printf '%s' "${resp}" | jq -e '.data.data.key and .data.data.secret' >/dev/null 2>&1; then
    echo "PREFLIGHT: Vault secret for tenant '${LIBCLOUD_AWS_AUTH_BINDING}' present."
    return 0
  fi
  cat >&2 <<EOF
FATAL: AWS backend credentials for tenant '${LIBCLOUD_AWS_AUTH_BINDING}' are NOT in Vault
       (secret/data/libcloud/${LIBCLOUD_AWS_AUTH_BINDING} is missing). The REST API
       would return 'server_credentials_missing' for every backend call.

The tenant OWNER must set them first (OpenFGA can_manage_credentials = owner only,
so only aws-owner / superadmin can do this):

  TENANT=${LIBCLOUD_AWS_AUTH_BINDING} CLOUD=aws \\
    LIBCLOUD_USER=aws-owner LIBCLOUD_PASSWORD="\${LIBCLOUD_PASSWORD_AWS_OWNER}" \\
    LIBCLOUD_AWS_KEY=AKIA... LIBCLOUD_AWS_SECRET=... \\
    python3 scripts/set_tenant_credentials.py

Then re-run: ./scripts/aws_vm_lifecycle.sh
EOF
  return 1
}

# --------------------------------------------------------------------------- #
# Flow
# --------------------------------------------------------------------------- #

echo
echo "############################################################"
echo "# AWS VM lifecycle demo (curl + jq only)"
echo "#   user        : ${LIBCLOUD_USER} (admin role)"
echo "#   tenant      : ${LIBCLOUD_AWS_AUTH_BINDING}  (backend object ${BACKEND_OBJECT})"
echo "#   region      : ${AWS_REGION}"
echo "#   VM name     : ${VM_NAME}"
echo "#   REST API    : ${LIBCLOUD_REST_URL}"
echo "############################################################"

# Fail fast if the tenant's AWS credentials are not in Vault yet.
preflight_tenant_credentials

# 1/4 — Provision a new VM. provision_aws.sh does its own Dex login (OIDC
# callback flow) and caches the token to generated/tokens/<user>.json, which
# the steps below reuse via curl.
step "1/4" "Provision a new AWS VM via ./scripts/provision_aws.sh (PROVISION=1)"
PROVISION=1 bash "${SCRIPT_DIR}/provision_aws.sh"

# Obtain a token (from the cache provision_aws.sh just populated) + connection.
require_token
CONNECTION_PARAM=$(connection_param)

# 2/4 — List all VMs (curl GET).
step "2/4" "List all AWS VMs (curl GET /v1/compute/nodes)"
rest GET "/v1/compute/nodes" | jq .

# 3/4 — Deprovision all VMs created by the provision step (curl DELETE via
# deprovision_aws.sh). It deletes every libcloud-demo-* VM (or VM_NAME if set).
step "3/4" "Deprovision all created AWS VMs via ./scripts/deprovision_aws.sh"
VM_NAME="${VM_NAME}" bash "${SCRIPT_DIR}/deprovision_aws.sh"

# Re-acquire the token (the deprovision child may have refreshed/rotated it).
require_token

# 4/4 — List all VMs again (curl GET) to confirm teardown.
step "4/4" "List all AWS VMs again (curl GET /v1/compute/nodes)"
rest GET "/v1/compute/nodes" | jq .

echo
echo "AWS VM lifecycle demo completed (user=${LIBCLOUD_USER}, binding=${LIBCLOUD_AWS_AUTH_BINDING})."
