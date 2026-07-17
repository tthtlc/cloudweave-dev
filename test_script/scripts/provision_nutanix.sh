#!/usr/bin/env bash
# End-to-end Nutanix provisioning demo using Dex (IdP) -> OpenFGA -> libcloud REST -> Nutanix.
#
# Usage:
#   LIBCLOUD_USER=provisioner ./scripts/provision_nutanix.sh
#   LIBCLOUD_USER=reader ./scripts/provision_nutanix.sh
#   PROVISION=1 ./scripts/provision_nutanix.sh
#   PROVISION=1 TEARDOWN_VMS=1 ./scripts/provision_nutanix.sh  # create then delete it
#   VERBOSE=1 ./scripts/provision_nutanix.sh               # log HTTP headers/bodies to stderr
#   ./scripts/provision_nutanix.sh -v                        # same as VERBOSE=1
#
# Prerequisites:
#   ./setup.sh
#   libcloud REST API running at LIBCLOUD_REST_URL
#   The REST API holds the backend Nutanix identity itself (server-side
#   auth_binding); the client never handles Nutanix credentials.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# Target tenant = auth_binding (defaults to "nutanix"). Each tenant maps to
# its own Vault secret (secret/libcloud/<binding>) and its own OpenFGA backend
# object (nutanix_cluster:<binding>), so different Nutanix tenants use
# different credentials. Override with LIBCLOUD_NTNX_AUTH_BINDING or TENANT.
LIBCLOUD_NTNX_AUTH_BINDING="${LIBCLOUD_NTNX_AUTH_BINDING:-${TENANT:-nutanix}}"
NUTANIX_CLUSTER="${FGA_NUTANIX_CLUSTER:-${LIBCLOUD_NTNX_AUTH_BINDING}}"
NUTANIX_BACKEND_OBJECT="nutanix_cluster:${LIBCLOUD_NTNX_AUTH_BINDING}"
PROVISION="${PROVISION:-0}"
VM_NAME="${VM_NAME:-libcloud-ntnx-$(date +%s)}"
TEARDOWN_VMS="${TEARDOWN_VMS:-0}"

idp_login
#openfga_authorization_flow "nutanix" "${NUTANIX_BACKEND_OBJECT}"
build_nutanix_connection_param

libcloud_me
libcloud_connection_test "$(connection_json)"

step "5" "Catalog discovery (locations/clusters, sizes, images, storage)"
libcloud_api GET "/v1/compute/locations" | json_pretty
libcloud_api GET "/v1/compute/sizes" | json_pretty
libcloud_api GET "/v1/compute/images" | json_pretty
libcloud_api GET "/v1/compute/storage-containers" | json_pretty

step "6" "List existing Nutanix VMs"
libcloud_api GET "/v1/compute/nodes" | json_pretty

if [[ "${LIBCLOUD_USER}" == "reader" || "${LIBCLOUD_USER}" == "cloud-readonly" || "${LIBCLOUD_USER}" == *-viewer ]]; then
  step "7" "Reader user — skipping mutating Nutanix provisioning calls"
  exit 0
fi

if [[ "${PROVISION}" != "1" ]]; then
  step "7" "Dry-run complete (set PROVISION=1 to create a Nutanix VM)"
  exit 0
fi

CLUSTER_ID="${CLUSTER_ID:-$(libcloud_api GET "/v1/compute/locations" | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",[]); print(d[0]["id"] if d else "")')}"
IMAGE_ID="${IMAGE_ID:-$(libcloud_api GET "/v1/compute/images" | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",[]); print(d[0]["id"] if d else "")')}"
SIZE_ID="${SIZE_ID:-small}"
SUBNET_ID="${SUBNET_ID:-$(libcloud_api GET "/v1/compute/subnets" | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",[]); print(d[0]["id"] if d else "")')}"

if [[ -z "${CLUSTER_ID}" || -z "${IMAGE_ID}" ]]; then
  echo "Could not resolve CLUSTER_ID/IMAGE_ID from catalog listings." >&2
  exit 1
fi

step "7" "Provision Nutanix VM name=${VM_NAME}"
CREATE_BODY=$(with_connection "$(python3 -c "
import json
body = {
    'name': '${VM_NAME}',
    'size': {'id': '${SIZE_ID}'},
    'image': {'id': '${IMAGE_ID}'},
    'location': {'id': '${CLUSTER_ID}'},
    'provider_options': {},
}
if '${SUBNET_ID}':
    body['network'] = {'subnet_id': '${SUBNET_ID}'}
print(json.dumps(body))
")")
libcloud_api POST "/v1/compute/nodes" "${CREATE_BODY}" | json_pretty

if [[ "${TEARDOWN_VMS}" == "1" ]]; then
  teardown_libcloud_vms "${VM_NAME}"
fi

echo
echo "Nutanix provisioning flow completed."
