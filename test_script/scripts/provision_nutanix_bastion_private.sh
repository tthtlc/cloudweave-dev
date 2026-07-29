#!/usr/bin/env bash
# Provision the bastion + internal private VM pair on Nutanix via
# Dex (IdP) -> libcloud REST -> Nutanix Prism Central.
#
# Implements the full 2-VM scenario of nutanix_bastion_internal_server.md:
#   * bastion host    — NIC on the external VLAN (default vlan100-external,
#                       10.1.100.0/24 with IPAM pool), the SSH jump server;
#   * internal server — NIC on the isolated VLAN (default vlan200-internal,
#                       10.1.200.0/24 with IPAM pool), no external routing
#                       (no internet access; reachable via the bastion only).
# Both VMs: 2 vCPUs, 4 GiB RAM (synthetic size "medium"), OS disk cloned from
# the base image, an extra 20 GiB SCSI data disk, powered on. The two subnets
# (VLANs + IPAM pools) are created first when missing (doc step 1).
#
# This is the script behind the portal's "Provision Private VM Machine" button:
# the identity service shells out to it after the OpenFGA can_provision gate
# (Nutanix tenant owner/admin only), and the libcloud REST API resolves the
# tenant's Nutanix credentials from Vault (secret/libcloud/<auth_binding>)
# server-side — the client never handles cloud credentials.
#
# Standalone usage:
#   PROVISION=1 ./scripts/provision_nutanix_bastion_private.sh
#   PROVISION=1 VM_PREFIX=my-pair ./scripts/provision_nutanix_bastion_private.sh
#   PROVISION=1 TEARDOWN_VMS=1 ./scripts/provision_nutanix_bastion_private.sh  # create then delete both
#   VERBOSE=1 ./scripts/provision_nutanix_bastion_private.sh                   # log HTTP headers/bodies
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

# Pair naming: one prefix, two VM names. The default prefix matches the
# libcloud-ntnx-* family so teardown_libcloud_vms can find both VMs.
VM_PREFIX="${VM_PREFIX:-libcloud-ntnx-pair-$(date +%s)}"
BASTION_NAME="${BASTION_NAME:-${VM_PREFIX}-bastion}"
INTERNAL_NAME="${INTERNAL_NAME:-${VM_PREFIX}-internal}"

# VM shape (nutanix_bastion_internal_server.md steps 3+4: 2 vCPUs, 4GB RAM, 20GB data disk).
SIZE_ID="${SIZE_ID:-medium}" # synthetic size: 2 vcpus x 1 core, 4096 MiB
DATA_DISK_SIZE_MIB="${DATA_DISK_SIZE_MIB:-20480}"

# External network for the bastion (doc step 1: VLAN 100, with external routing).
EXTERNAL_SUBNET_NAME="${EXTERNAL_SUBNET_NAME:-vlan100-external}"
EXTERNAL_VLAN_ID="${EXTERNAL_VLAN_ID:-100}"
EXTERNAL_NETWORK="${EXTERNAL_NETWORK:-10.1.100.0}"
EXTERNAL_PREFIX_LENGTH="${EXTERNAL_PREFIX_LENGTH:-24}"
EXTERNAL_GATEWAY="${EXTERNAL_GATEWAY:-10.1.100.1}"
EXTERNAL_POOL_START="${EXTERNAL_POOL_START:-10.1.100.10}"
EXTERNAL_POOL_END="${EXTERNAL_POOL_END:-10.1.100.50}"

# Internal network for the private server (doc step 1: VLAN 200, isolated).
INTERNAL_SUBNET_NAME="${INTERNAL_SUBNET_NAME:-vlan200-internal}"
INTERNAL_VLAN_ID="${INTERNAL_VLAN_ID:-200}"
INTERNAL_NETWORK="${INTERNAL_NETWORK:-10.1.200.0}"
INTERNAL_PREFIX_LENGTH="${INTERNAL_PREFIX_LENGTH:-24}"
INTERNAL_GATEWAY="${INTERNAL_GATEWAY:-10.1.200.1}"
INTERNAL_POOL_START="${INTERNAL_POOL_START:-10.1.200.10}"
INTERNAL_POOL_END="${INTERNAL_POOL_END:-10.1.200.50}"

# Empty -> request an IP from the subnet IPAM pool (acli request_ip=true).
BASTION_IP="${BASTION_IP:-}"
INTERNAL_IP="${INTERNAL_IP:-}"

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
  step "7" "Dry-run complete (set PROVISION=1 to create the pair ${BASTION_NAME} + ${INTERNAL_NAME})"
  exit 0
fi

CLUSTER_ID="${CLUSTER_ID:-$(libcloud_api GET "/v1/compute/locations" | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",[]); print(d[0]["id"] if d else "")')}"
IMAGE_ID="${IMAGE_ID:-$(libcloud_api GET "/v1/compute/images" | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",[]); print(d[0]["id"] if d else "")')}"
STORAGE_CONTAINER_ID="${STORAGE_CONTAINER_ID:-$(libcloud_api GET "/v1/compute/storage-containers" | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",[]); print(d[0]["id"] if d else "")')}"

if [[ -z "${CLUSTER_ID}" || -z "${IMAGE_ID}" ]]; then
  echo "Could not resolve CLUSTER_ID/IMAGE_ID from catalog listings." >&2
  exit 1
fi

# resolve_subnet_id <name> — print the id of the named subnet (empty if missing).
resolve_subnet_id() {
  local name="$1"
  libcloud_api GET "/v1/compute/subnets" | SUBNET_NAME="${name}" python3 -c '
import json, os, sys
d = json.load(sys.stdin).get("data", [])
match = [s for s in d if s.get("name") == os.environ["SUBNET_NAME"]]
print(match[0]["id"] if match else "")
'
}

# ensure_subnet <name> <vlan_id> <network> <prefix_len> <gateway> <pool_start> <pool_end> <description>
# Print the subnet id; create the VLAN + IPAM pool first when missing
# (nutanix_bastion_internal_server.md step 1: net.create + net.update ip_config).
# Human-readable output goes to stderr so the id stays alone on stdout.
ensure_subnet() {
  local name="$1" vlan="$2" network="$3" prefix="$4" gateway="$5" pool_start="$6" pool_end="$7" desc="$8"
  local subnet_id body
  subnet_id="$(resolve_subnet_id "${name}")"
  if [[ -z "${subnet_id}" ]]; then
    echo "Creating subnet ${name} (vlan=${vlan}, ${network}/${prefix}, pool ${pool_start}-${pool_end})" >&2
    body=$(with_connection "$(python3 -c "
import json
body = {
    'name': '${name}',
    'subnet_type': 'VLAN',
    'cluster_id': '${CLUSTER_ID}',
    'network_id': int('${vlan}'),
    'description': '${desc}',
    'ip_address': '${network}',
    'prefix_length': int('${prefix}'),
    'gateway_ip': '${gateway}',
    'ip_pool': ['${pool_start}-${pool_end}'],
}
print(json.dumps(body))
")")
    libcloud_api POST "/v1/compute/subnets" "${body}" | json_pretty >&2
    subnet_id="$(resolve_subnet_id "${name}")"
  fi
  if [[ -z "${subnet_id}" ]]; then
    echo "Could not resolve or create subnet ${name}." >&2
    return 1
  fi
  echo "${subnet_id}"
}

# create_vm <name> <subnet_id> <static_ip> <prefix_len> <description>
# Create + power on one VM of the pair (nutanix_bastion_internal_server.md
# steps 3+4): OS disk cloned from the base image, extra SCSI data disk, NIC on
# the given subnet with an IP from the pool (or the given static IP).
# Prints the new node id; human-readable output goes to stderr.
create_vm() {
  local name="$1" subnet_id="$2" static_ip="$3" prefix_len="$4" desc="$5"
  local body resp node_id
  body=$(with_connection "$(python3 -c "
import json
provider_options = {
    'ex_description': '${desc}',
    'ex_power_on': True,
}
if '${static_ip}':
    provider_options['ex_ip_address'] = '${static_ip}'
    provider_options['ex_ip_prefix_length'] = int('${prefix_len}')
else:
    provider_options['ex_assign_ip'] = True
data_disk = {'size_mib': int('${DATA_DISK_SIZE_MIB}'), 'bus': 'SCSI'}
if '${STORAGE_CONTAINER_ID}':
    data_disk['storage_container_ext_id'] = '${STORAGE_CONTAINER_ID}'
provider_options['ex_data_disks'] = [data_disk]
body = {
    'name': '${name}',
    'size': {'id': '${SIZE_ID}'},
    'image': {'id': '${IMAGE_ID}'},
    'location': {'id': '${CLUSTER_ID}'},
    'network': {'subnet_id': '${subnet_id}'},
    'provider_options': provider_options,
}
print(json.dumps(body))
")")
  resp=$(libcloud_api POST "/v1/compute/nodes" "${body}")
  echo "${resp}" | json_pretty >&2
  node_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("data",{}).get("id",""))' <<<"${resp}")"
  if [[ -z "${node_id}" ]]; then
    echo "Could not resolve node id for VM ${name}." >&2
    return 1
  fi
  echo "${node_id}"
}

step "7" "Ensure external subnet ${EXTERNAL_SUBNET_NAME} (bastion segment, routed)"
EXTERNAL_SUBNET_ID="$(ensure_subnet "${EXTERNAL_SUBNET_NAME}" "${EXTERNAL_VLAN_ID}" "${EXTERNAL_NETWORK}" "${EXTERNAL_PREFIX_LENGTH}" "${EXTERNAL_GATEWAY}" "${EXTERNAL_POOL_START}" "${EXTERNAL_POOL_END}" "External segment for bastion hosts (external routing)")"
echo "External subnet ${EXTERNAL_SUBNET_NAME} id=${EXTERNAL_SUBNET_ID}"

step "8" "Ensure internal subnet ${INTERNAL_SUBNET_NAME} (isolated private segment)"
INTERNAL_SUBNET_ID="$(ensure_subnet "${INTERNAL_SUBNET_NAME}" "${INTERNAL_VLAN_ID}" "${INTERNAL_NETWORK}" "${INTERNAL_PREFIX_LENGTH}" "${INTERNAL_GATEWAY}" "${INTERNAL_POOL_START}" "${INTERNAL_POOL_END}" "Isolated internal segment (no external routing)")"
echo "Internal subnet ${INTERNAL_SUBNET_NAME} id=${INTERNAL_SUBNET_ID}"

# Bastion host (doc step 3): NIC on the external VLAN.
step "9" "Provision bastion host VM name=${BASTION_NAME} subnet=${EXTERNAL_SUBNET_NAME}"
BASTION_ID="$(create_vm "${BASTION_NAME}" "${EXTERNAL_SUBNET_ID}" "${BASTION_IP}" "${EXTERNAL_PREFIX_LENGTH}" "Bastion (jump) host on ${EXTERNAL_SUBNET_NAME}; SSH entry point for the private segment")"
echo "Bastion VM ${BASTION_NAME} id=${BASTION_ID}"

# Internal private server (doc step 4): NIC on the isolated VLAN, no internet.
step "10" "Provision internal private VM name=${INTERNAL_NAME} subnet=${INTERNAL_SUBNET_NAME}"
INTERNAL_ID="$(create_vm "${INTERNAL_NAME}" "${INTERNAL_SUBNET_ID}" "${INTERNAL_IP}" "${INTERNAL_PREFIX_LENGTH}" "Internal (private) server on ${INTERNAL_SUBNET_NAME}; no internet, reachable via bastion only")"
echo "Internal VM ${INTERNAL_NAME} id=${INTERNAL_ID}"

step "11" "Verify both VMs (bastion on ${EXTERNAL_NETWORK}/${EXTERNAL_PREFIX_LENGTH}, internal on ${INTERNAL_NETWORK}/${INTERNAL_PREFIX_LENGTH} only)"
libcloud_api GET "/v1/compute/nodes/${BASTION_ID}" | json_pretty
libcloud_api GET "/v1/compute/nodes/${INTERNAL_ID}" | json_pretty

if [[ "${TEARDOWN_VMS}" == "1" ]]; then
  teardown_libcloud_vms "${BASTION_NAME}"
  teardown_libcloud_vms "${INTERNAL_NAME}"
fi

echo
echo "Bastion + internal private VM provisioning flow completed."
echo "  bastion : ${BASTION_NAME} (id=${BASTION_ID}, ${EXTERNAL_SUBNET_NAME})"
echo "  internal: ${INTERNAL_NAME} (id=${INTERNAL_ID}, ${INTERNAL_SUBNET_NAME}, no external routing)"
