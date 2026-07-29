#!/usr/bin/env bash
# Provision a private (internal) Nutanix VM via Dex (IdP) -> libcloud REST -> Nutanix.
#
# Implements the "internal server" part of nutanix_bastion_internal_server.md:
# the VM lives on an isolated VLAN (default vlan200-internal, 10.1.200.0/24)
# with an IPAM pool, gets its OS disk cloned from a base image, an extra 20GB
# SCSI data disk, and a NIC with an assigned (or static) private IP.
#
# Usage:
#   PROVISION=1 ./scripts/provision_nutanix_private.sh
#   PROVISION=1 VM_NAME=internal-server-2 STATIC_IP=10.1.200.12 ./scripts/provision_nutanix_private.sh
#   PROVISION=1 TEARDOWN_VMS=1 ./scripts/provision_nutanix_private.sh  # create then delete it
#   VERBOSE=1 ./scripts/provision_nutanix_private.sh                   # log HTTP headers/bodies
#
# Prerequisites: same as provision_nutanix.sh (setup.sh + libcloud REST at
# LIBCLOUD_REST_URL; the REST API holds the backend Nutanix identity via
# server-side auth_binding).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# Target tenant = auth_binding (defaults to "nutanix"); see provision_nutanix.sh.
LIBCLOUD_NTNX_AUTH_BINDING="${LIBCLOUD_NTNX_AUTH_BINDING:-${TENANT:-nutanix}}"
PROVISION="${PROVISION:-0}"
TEARDOWN_VMS="${TEARDOWN_VMS:-0}"

# VM shape (nutanix_bastion_internal_server.md step 4: 2 vCPUs, 4GB RAM, 20GB data disk).
VM_NAME="${VM_NAME:-internal-server-1}"
SIZE_ID="${SIZE_ID:-medium}" # synthetic size: 2 vcpus x 1 core, 4096 MiB
DATA_DISK_SIZE_MIB="${DATA_DISK_SIZE_MIB:-20480}"

# Internal network (nutanix_bastion_internal_server.md step 1: VLAN 200, isolated).
INTERNAL_SUBNET_NAME="${INTERNAL_SUBNET_NAME:-vlan200-internal}"
INTERNAL_VLAN_ID="${INTERNAL_VLAN_ID:-200}"
INTERNAL_NETWORK="${INTERNAL_NETWORK:-10.1.200.0}"
INTERNAL_PREFIX_LENGTH="${INTERNAL_PREFIX_LENGTH:-24}"
INTERNAL_GATEWAY="${INTERNAL_GATEWAY:-10.1.200.1}"
INTERNAL_POOL_START="${INTERNAL_POOL_START:-10.1.200.10}"
INTERNAL_POOL_END="${INTERNAL_POOL_END:-10.1.200.50}"
# Empty -> request an IP from the subnet IPAM pool (acli request_ip=true).
STATIC_IP="${STATIC_IP:-}"

idp_login
build_nutanix_connection_param

libcloud_me
libcloud_connection_test "$(connection_json)"

step "5" "Catalog discovery (locations/clusters, images, subnets, storage)"
libcloud_api GET "/v1/compute/locations" | json_pretty
libcloud_api GET "/v1/compute/images" | json_pretty
libcloud_api GET "/v1/compute/subnets" | json_pretty
libcloud_api GET "/v1/compute/storage-containers" | json_pretty

step "6" "List existing Nutanix VMs"
libcloud_api GET "/v1/compute/nodes" | json_pretty

if [[ "${LIBCLOUD_USER}" == "reader" || "${LIBCLOUD_USER}" == "cloud-readonly" || "${LIBCLOUD_USER}" == *-viewer ]]; then
  step "7" "Reader user — skipping mutating Nutanix provisioning calls"
  exit 0
fi

if [[ "${PROVISION}" != "1" ]]; then
  step "7" "Dry-run complete (set PROVISION=1 to create the private VM ${VM_NAME})"
  exit 0
fi

CLUSTER_ID="${CLUSTER_ID:-$(libcloud_api GET "/v1/compute/locations" | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",[]); print(d[0]["id"] if d else "")')}"
IMAGE_ID="${IMAGE_ID:-$(libcloud_api GET "/v1/compute/images" | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",[]); print(d[0]["id"] if d else "")')}"
STORAGE_CONTAINER_ID="${STORAGE_CONTAINER_ID:-$(libcloud_api GET "/v1/compute/storage-containers" | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",[]); print(d[0]["id"] if d else "")')}"

if [[ -z "${CLUSTER_ID}" || -z "${IMAGE_ID}" ]]; then
  echo "Could not resolve CLUSTER_ID/IMAGE_ID from catalog listings." >&2
  exit 1
fi

# Resolve the internal subnet by name; create the VLAN + IPAM pool if missing
# (nutanix_bastion_internal_server.md step 1: net.create vlan200-internal vlan=200
# plus the 10.1.200.0/24 ip_config with pool 10.1.200.10-10.1.200.50).
SUBNET_ID="${SUBNET_ID:-$(libcloud_api GET "/v1/compute/subnets" | SUBNET_NAME="${INTERNAL_SUBNET_NAME}" python3 -c '
import json, os, sys
d = json.load(sys.stdin).get("data", [])
match = [s for s in d if s.get("name") == os.environ["SUBNET_NAME"]]
print(match[0]["id"] if match else "")
')}"

if [[ -z "${SUBNET_ID}" ]]; then
  step "7" "Create internal subnet ${INTERNAL_SUBNET_NAME} (vlan=${INTERNAL_VLAN_ID}, ${INTERNAL_NETWORK}/${INTERNAL_PREFIX_LENGTH})"
  SUBNET_BODY=$(with_connection "$(python3 -c "
import json
body = {
    'name': '${INTERNAL_SUBNET_NAME}',
    'subnet_type': 'VLAN',
    'cluster_id': '${CLUSTER_ID}',
    'network_id': int('${INTERNAL_VLAN_ID}'),
    'description': 'Isolated internal segment (no external routing)',
    'ip_address': '${INTERNAL_NETWORK}',
    'prefix_length': int('${INTERNAL_PREFIX_LENGTH}'),
    'gateway_ip': '${INTERNAL_GATEWAY}',
    'ip_pool': ['${INTERNAL_POOL_START}-${INTERNAL_POOL_END}'],
}
print(json.dumps(body))
")")
  libcloud_api POST "/v1/compute/subnets" "${SUBNET_BODY}" | json_pretty
  SUBNET_ID="$(libcloud_api GET "/v1/compute/subnets" | SUBNET_NAME="${INTERNAL_SUBNET_NAME}" python3 -c '
import json, os, sys
d = json.load(sys.stdin).get("data", [])
match = [s for s in d if s.get("name") == os.environ["SUBNET_NAME"]]
print(match[0]["id"] if match else "")
')"
fi

if [[ -z "${SUBNET_ID}" ]]; then
  echo "Could not resolve or create subnet ${INTERNAL_SUBNET_NAME}." >&2
  exit 1
fi
echo "Internal subnet ${INTERNAL_SUBNET_NAME} id=${SUBNET_ID}"

# Create the private VM (nutanix_bastion_internal_server.md step 4):
# OS disk cloned from the base image, extra SCSI data disk, NIC on the
# internal VLAN with an IP from the pool (or STATIC_IP), powered on.
step "8" "Provision private Nutanix VM name=${VM_NAME} subnet=${INTERNAL_SUBNET_NAME}"
CREATE_BODY=$(with_connection "$(python3 -c "
import json
provider_options = {
    'ex_description': 'Internal (private) server on ${INTERNAL_SUBNET_NAME}; reachable via bastion only',
    'ex_power_on': True,
}
if '${STATIC_IP}':
    provider_options['ex_ip_address'] = '${STATIC_IP}'
    provider_options['ex_ip_prefix_length'] = int('${INTERNAL_PREFIX_LENGTH}')
else:
    provider_options['ex_assign_ip'] = True
data_disk = {'size_mib': int('${DATA_DISK_SIZE_MIB}'), 'bus': 'SCSI'}
if '${STORAGE_CONTAINER_ID}':
    data_disk['storage_container_ext_id'] = '${STORAGE_CONTAINER_ID}'
provider_options['ex_data_disks'] = [data_disk]
body = {
    'name': '${VM_NAME}',
    'size': {'id': '${SIZE_ID}'},
    'image': {'id': '${IMAGE_ID}'},
    'location': {'id': '${CLUSTER_ID}'},
    'network': {'subnet_id': '${SUBNET_ID}'},
    'provider_options': provider_options,
}
print(json.dumps(body))
")")
CREATE_RESP=$(libcloud_api POST "/v1/compute/nodes" "${CREATE_BODY}")
echo "${CREATE_RESP}" | json_pretty

NODE_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("data",{}).get("id",""))' <<<"${CREATE_RESP}")"

if [[ -n "${NODE_ID}" ]]; then
  step "9" "Verify private VM (expect an IP on ${INTERNAL_NETWORK}/${INTERNAL_PREFIX_LENGTH} only)"
  libcloud_api GET "/v1/compute/nodes/${NODE_ID}" | json_pretty
fi

if [[ "${TEARDOWN_VMS}" == "1" ]]; then
  teardown_libcloud_vms "${VM_NAME}"
fi

echo
echo "Private Nutanix VM provisioning flow completed."
