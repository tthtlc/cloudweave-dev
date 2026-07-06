#!/usr/bin/env bash
# End-to-end AWS provisioning demo using Authentik (IdP) -> OpenFGA -> libcloud REST -> AWS.
#
# Usage:
#   LIBCLOUD_USER=provisioner ./scripts/provision_aws.sh
#   LIBCLOUD_USER=reader ./scripts/provision_aws.sh        # read-only path
#   PROVISION=1 ./scripts/provision_aws.sh                 # also create an EC2 instance
#   PROVISION=1 TEARDOWN_VMS=1 ./scripts/provision_aws.sh  # create then delete it
#   VERBOSE=1 ./scripts/provision_aws.sh                   # log HTTP headers/bodies to stderr
#   ./scripts/provision_aws.sh -v                            # same as VERBOSE=1
#   AWS_INSTANCE_ARCH=arm64 PROVISION=1 ./scripts/provision_aws.sh
#
# Prerequisites:
#   ./setup.sh
#   libcloud REST API running at LIBCLOUD_REST_URL (default http://localhost:8765)
#   The REST API holds the backend AWS identity itself (server-side IAM role /
#   auth_binding); the client never handles AWS credentials.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

AWS_REGION="${AWS_REGION:-ap-southeast-1}"
# Target tenant = auth_binding (defaults to "aws"). Each tenant maps to its
# own Vault secret (secret/libcloud/<binding>) and its own OpenFGA backend
# object (aws_region:<binding>), so different AWS tenants use different
# access keys. Override with LIBCLOUD_AWS_AUTH_BINDING or TENANT.
LIBCLOUD_AWS_AUTH_BINDING="${LIBCLOUD_AWS_AUTH_BINDING:-${TENANT:-aws}}"
AWS_BACKEND_OBJECT="aws_region:${LIBCLOUD_AWS_AUTH_BINDING}"
PROVISION="${PROVISION:-0}"
VM_NAME="${VM_NAME:-libcloud-demo-$(date +%s)}"
TEARDOWN_VMS="${TEARDOWN_VMS:-0}"
AWS_IMAGE_NAME_FILTER="${AWS_IMAGE_NAME_FILTER:-*Ubuntu*}"

# The provider connection (provider + region + auth_binding, NO credentials)
# is sent via the X-Provider-Connection header by libcloud_api. Endpoints below
# therefore carry only non-sensitive query parameters (e.g. image name filter).
aws_images_path() {
  local filter="${1:-$AWS_IMAGE_NAME_FILTER}"
  if [[ -z "$filter" || "$filter" == "*" ]]; then
    echo "/v1/compute/images?name=*"
  else
    local encoded
    encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${filter}'))")
    echo "/v1/compute/images?name=${encoded}"
  fi
}

idp_login
#openfga_authorization_flow "aws" "${AWS_BACKEND_OBJECT}"
build_aws_connection_param "${AWS_REGION}"

libcloud_me
libcloud_connection_test "$(connection_json)"

step "5" "Catalog discovery (locations, sizes, images)"
libcloud_api GET "/v1/compute/locations" | json_pretty
libcloud_api GET "/v1/compute/sizes" | json_pretty
libcloud_api GET "$(aws_images_path)" | json_pretty

step "6" "List existing compute nodes"
libcloud_api GET "/v1/compute/nodes" | json_pretty

#if [[ "${LIBCLOUD_USER}" == "reader" || "${LIBCLOUD_USER}" == "cloud-readonly" || "${LIBCLOUD_USER}" == *-viewer ]]; then
#  step "7" "Reader user — skipping mutating AWS provisioning calls"
#  exit 0
#fi

if [[ "${PROVISION}" != "1" ]]; then
  step "7" "Dry-run complete (set PROVISION=1 to create an EC2 instance)"
  exit 0
fi

AWS_INSTANCE_ARCH="${AWS_INSTANCE_ARCH:-x86_64}"
AWS_DEFAULT_SIZE_ID="${AWS_DEFAULT_SIZE_ID:-}"

if [[ -z "${IMAGE_ID:-}" || -z "${SIZE_ID:-}" ]]; then
  IMAGES_RESP=$(libcloud_api GET "$(aws_images_path)")
  SIZES_RESP=$(libcloud_api GET "/v1/compute/sizes")
  TMPDIR="${TMPDIR:-/tmp}"
  IMAGES_FILE="${TMPDIR}/libcloud-aws-images-$$.json"
  SIZES_FILE="${TMPDIR}/libcloud-aws-sizes-$$.json"
  printf '%s' "${IMAGES_RESP}" > "${IMAGES_FILE}"
  printf '%s' "${SIZES_RESP}" > "${SIZES_FILE}"
  RESOLVED=$(AWS_INSTANCE_ARCH="${AWS_INSTANCE_ARCH}" AWS_DEFAULT_SIZE_ID="${AWS_DEFAULT_SIZE_ID}" \
    python3 "${SCRIPT_DIR}/aws_resolve_catalog.py" "${IMAGES_FILE}" "${SIZES_FILE}")
  rm -f "${IMAGES_FILE}" "${SIZES_FILE}"
  eval "${RESOLVED}"
fi

SUBNET_ID="${SUBNET_ID:-$(libcloud_api GET "/v1/compute/subnets" | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",[]); print(d[0]["id"] if d else "")')}"

if [[ -z "${IMAGE_ID}" || -z "${SIZE_ID}" ]]; then
  echo "Could not resolve compatible IMAGE_ID/SIZE_ID (architecture=${AWS_INSTANCE_ARCH})." >&2
  exit 1
fi

step "7" "Provision AWS EC2 instance name=${VM_NAME} image=${IMAGE_ID} size=${SIZE_ID} arch=${AWS_INSTANCE_ARCH}"
CREATE_BODY=$(with_connection "$(python3 -c "
import json
body = {
    'name': '${VM_NAME}',
    'size': {'id': '${SIZE_ID}'},
    'image': {'id': '${IMAGE_ID}'},
    'network': {'public_ip': True},
}
if '${SUBNET_ID}':
    body['network']['subnet_id'] = '${SUBNET_ID}'
print(json.dumps(body))
")")
libcloud_api POST "/v1/compute/nodes" "${CREATE_BODY}" | json_pretty

if [[ "${TEARDOWN_VMS}" == "1" ]]; then
  teardown_libcloud_vms "${VM_NAME}"
fi

echo
echo "AWS provisioning flow completed."
