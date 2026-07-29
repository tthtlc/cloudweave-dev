#!/usr/bin/env bash
# Provision the AWS bastion + internal private server scenario from
# aws_bastion_internal_server.md via Dex (IdP) -> OpenFGA -> libcloud REST -> AWS.
#
# Creates (all through the libcloud REST API; the client NEVER handles AWS
# credentials — the REST API resolves the per-tenant Vault secret
# secret/libcloud/<auth_binding> server-side):
#
#   * dedicated VPC            10.0.0.0/16   (libcloud-private-vpc)
#   * public subnet            10.0.0.0/24   (auto-assign public IP)
#   * private subnet           10.0.16.0/24  (NO route to internet)
#   * internet gateway + public route table (0.0.0.0/0 -> IGW, public subnet)
#   * bastion security group   (SSH/22 from BASTION_SSH_CIDR)
#   * internal security group  (SSH/22 from the bastion SG, app port from VPC)
#   * key pair                 (private key saved to KEY_FILE on first create)
#   * bastion VM               (public subnet, public IP, bastion SG)
#   * internal VM              (private subnet, NO public IP, internal SG)
# VM names derive from VM_PREFIX (default libcloud-aws-pair-<ts>): -bastion /
# -internal, same convention as provision_nutanix_bastion_private.sh.
#
# Unlike the reference document, NO NAT gateway is created: the internal
# server must have NO internet access, so the private subnet keeps the VPC's
# local-only main route table.
#
# The scenario is idempotent: every network object is looked up by name first
# and reused when it already exists, so re-running only re-creates the VMs.
#
# Usage:
#   PROVISION=1 ./scripts/provision_aws_private.sh
#   PROVISION=1 BASTION_SSH_CIDR=203.0.113.7/32 ./scripts/provision_aws_private.sh
#   PROVISION=1 TEARDOWN_VMS=1 ./scripts/provision_aws_private.sh  # create then delete the 2 VMs
#   VERBOSE=1 ./scripts/provision_aws_private.sh                   # log HTTP headers/bodies
#   LIBCLOUD_AWS_AUTH_BINDING=aws-dev PROVISION=1 ./scripts/provision_aws_private.sh
#
# Prerequisites:
#   ./setup.sh
#   libcloud REST API running at LIBCLOUD_REST_URL (default http://localhost:8765)
#   The REST API holds the backend AWS identity itself (server-side IAM role /
#   auth_binding); the client never handles AWS credentials.
#
# Authorization: every write call below is gated by the REST API on OpenFGA
# can_provision over aws_region:<binding> — only the tenant owner/admin hold
# it. The portal's "Provision Private VM Machine" button runs this script via
# POST /api/provision/aws/private after the same can_provision check.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

AWS_REGION="${AWS_REGION:-ap-southeast-1}"
# Target tenant = auth_binding (defaults to "aws"); see provision_aws.sh. The
# tenant selects BOTH the OpenFGA backend object (aws_region:<binding>) and the
# Vault secret (secret/libcloud/<binding>) the REST API uses — tenant credentials
# are picked up automatically, never handled here.
LIBCLOUD_AWS_AUTH_BINDING="${LIBCLOUD_AWS_AUTH_BINDING:-${TENANT:-aws}}"
AWS_BACKEND_OBJECT="aws_region:${LIBCLOUD_AWS_AUTH_BINDING}"
PROVISION="${PROVISION:-0}"
TEARDOWN_VMS="${TEARDOWN_VMS:-0}"
AWS_IMAGE_NAME_FILTER="${AWS_IMAGE_NAME_FILTER:-*ubuntu*24.04*amd64*}"

# --- Scenario topology (aws_bastion_internal_server.md) ----------------------
VPC_NAME="${VPC_NAME:-libcloud-private-vpc}"
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
PUBLIC_SUBNET_NAME="${PUBLIC_SUBNET_NAME:-libcloud-public-subnet}"
PUBLIC_SUBNET_CIDR="${PUBLIC_SUBNET_CIDR:-10.0.0.0/24}"
PRIVATE_SUBNET_NAME="${PRIVATE_SUBNET_NAME:-libcloud-private-subnet}"
PRIVATE_SUBNET_CIDR="${PRIVATE_SUBNET_CIDR:-10.0.16.0/24}"
AWS_AVAILABILITY_ZONE="${AWS_AVAILABILITY_ZONE:-${AWS_REGION}a}"
IGW_NAME="${IGW_NAME:-libcloud-private-igw}"
PUBLIC_RT_NAME="${PUBLIC_RT_NAME:-libcloud-public-rtb}"
BASTION_SG_NAME="${BASTION_SG_NAME:-libcloud-bastion-sg}"
INTERNAL_SG_NAME="${INTERNAL_SG_NAME:-libcloud-internal-sg}"
# Scenario step 6 restricts bastion SSH to YOUR_CORPORATE_IP/32; default open
# for the demo. Always pin this to your own IP outside of a throwaway lab.
BASTION_SSH_CIDR="${BASTION_SSH_CIDR:-0.0.0.0/0}"
INTERNAL_APP_PORT="${INTERNAL_APP_PORT:-8080}"
KEY_PAIR_NAME="${KEY_PAIR_NAME:-libcloud-private-key}"
KEY_FILE="${KEY_FILE:-${TMPDIR:-/tmp}/${KEY_PAIR_NAME}.pem}"
# Pair naming: one prefix, two VM names (same convention as
# provision_nutanix_bastion_private.sh so the identity service drives both
# scripts with the same VM_PREFIX/BASTION_NAME/INTERNAL_NAME env).
VM_PREFIX="${VM_PREFIX:-libcloud-aws-pair-$(date +%s)}"
BASTION_NAME="${BASTION_NAME:-${VM_PREFIX}-bastion}"
INTERNAL_NAME="${INTERNAL_NAME:-${VM_PREFIX}-internal}"

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

# Print the id of the first .data[] entry whose .name matches $1 ($2 = list JSON).
find_id_by_name() {
  python3 -c '
import json, sys
data = json.load(sys.stdin).get("data", [])
name = sys.argv[1]
match = [x for x in data if x and x.get("name") == name]
print(match[0].get("id", "") if match else "")
' "$1" <<<"$2"
}

# Id of the first entry in a list response ("" if empty).
first_id() {
  python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",[]); print(d[0].get("id","") if d else "")'
}

idp_login
openfga_authorization_flow "aws" "${AWS_BACKEND_OBJECT}"
build_aws_connection_param "${AWS_REGION}"

libcloud_me
libcloud_connection_test "$(connection_json)"

step "5" "Catalog discovery (locations, sizes, images)"
libcloud_api GET "/v1/compute/locations" | json_pretty
libcloud_api GET "/v1/compute/sizes" | json_pretty
libcloud_api GET "$(aws_images_path)" | json_pretty

step "6" "List existing compute nodes"
libcloud_api GET "/v1/compute/nodes" | json_pretty

if [[ "${PROVISION}" != "1" ]]; then
  step "7" "Dry-run complete (set PROVISION=1 to create the bastion + private VM stack)"
  exit 0
fi

# Resolve an architecture-compatible AMI + instance type (same resolver as
# provision_aws.sh).
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
if [[ -z "${IMAGE_ID}" || -z "${SIZE_ID}" ]]; then
  echo "Could not resolve compatible IMAGE_ID/SIZE_ID (architecture=${AWS_INSTANCE_ARCH})." >&2
  exit 1
fi

# --------------------------------------------------------------------------- #
# Step 7: network stack (VPC, subnets, IGW, public route table, SGs, key pair)
# --------------------------------------------------------------------------- #

step "7" "VPC ${VPC_NAME} (${VPC_CIDR}) — find or create"
VPC_ID="$(find_id_by_name "${VPC_NAME}" "$(libcloud_api GET "/v1/compute/networks")")"
if [[ -z "${VPC_ID}" ]]; then
  CREATE_VPC_BODY=$(with_connection "$(python3 -c "
import json
print(json.dumps({'name': '${VPC_NAME}', 'cidr_block': '${VPC_CIDR}'}))
")")
  libcloud_api POST "/v1/compute/networks" "${CREATE_VPC_BODY}" | json_pretty
  VPC_ID="$(find_id_by_name "${VPC_NAME}" "$(libcloud_api GET "/v1/compute/networks")")"
fi
if [[ -z "${VPC_ID}" ]]; then
  echo "Could not resolve or create VPC ${VPC_NAME}." >&2
  exit 1
fi
echo "VPC ${VPC_NAME} id=${VPC_ID}"

# Public subnet (10.0.0.0/24) + auto-assign public IP (scenario step 2).
step "8" "Public subnet ${PUBLIC_SUBNET_NAME} (${PUBLIC_SUBNET_CIDR}) — find or create"
PUBLIC_SUBNET_ID="$(VPC_ID="${VPC_ID}" SUBNET_NAME="${PUBLIC_SUBNET_NAME}" python3 -c '
import json, os, sys
d = json.load(sys.stdin).get("data", [])
m = [s for s in d if s.get("name") == os.environ["SUBNET_NAME"] and s.get("vpc_id") == os.environ["VPC_ID"]]
print(m[0]["id"] if m else "")
' <<<"$(libcloud_api GET "/v1/compute/subnets?vpc_id=${VPC_ID}")")"
if [[ -z "${PUBLIC_SUBNET_ID}" ]]; then
  CREATE_SUBNET_BODY=$(with_connection "$(python3 -c "
import json
print(json.dumps({
    'name': '${PUBLIC_SUBNET_NAME}',
    'vpc_id': '${VPC_ID}',
    'cidr_block': '${PUBLIC_SUBNET_CIDR}',
    'availability_zone': '${AWS_AVAILABILITY_ZONE}',
}))
")")
  libcloud_api POST "/v1/compute/subnets" "${CREATE_SUBNET_BODY}" | json_pretty
  PUBLIC_SUBNET_ID="$(find_id_by_name "${PUBLIC_SUBNET_NAME}" "$(libcloud_api GET "/v1/compute/subnets?vpc_id=${VPC_ID}")")"
fi
if [[ -z "${PUBLIC_SUBNET_ID}" ]]; then
  echo "Could not resolve or create subnet ${PUBLIC_SUBNET_NAME}." >&2
  exit 1
fi
echo "Public subnet ${PUBLIC_SUBNET_NAME} id=${PUBLIC_SUBNET_ID} — enabling auto-assign public IP"
AUTO_IP_BODY=$(with_connection "$(python3 -c "import json; print(json.dumps({'action':'auto_public_ip','value':True}))")")
libcloud_api PATCH "/v1/compute/subnets/${PUBLIC_SUBNET_ID}" "${AUTO_IP_BODY}" | json_pretty

# Private subnet (10.0.16.0/24). Stays on the VPC main route table (local
# routes only) and gets NO public IPs -> instances here have no internet access.
step "9" "Private subnet ${PRIVATE_SUBNET_NAME} (${PRIVATE_SUBNET_CIDR}) — find or create"
PRIVATE_SUBNET_ID="$(VPC_ID="${VPC_ID}" SUBNET_NAME="${PRIVATE_SUBNET_NAME}" python3 -c '
import json, os, sys
d = json.load(sys.stdin).get("data", [])
m = [s for s in d if s.get("name") == os.environ["SUBNET_NAME"] and s.get("vpc_id") == os.environ["VPC_ID"]]
print(m[0]["id"] if m else "")
' <<<"$(libcloud_api GET "/v1/compute/subnets?vpc_id=${VPC_ID}")")"
if [[ -z "${PRIVATE_SUBNET_ID}" ]]; then
  CREATE_SUBNET_BODY=$(with_connection "$(python3 -c "
import json
print(json.dumps({
    'name': '${PRIVATE_SUBNET_NAME}',
    'vpc_id': '${VPC_ID}',
    'cidr_block': '${PRIVATE_SUBNET_CIDR}',
    'availability_zone': '${AWS_AVAILABILITY_ZONE}',
}))
")")
  libcloud_api POST "/v1/compute/subnets" "${CREATE_SUBNET_BODY}" | json_pretty
  PRIVATE_SUBNET_ID="$(find_id_by_name "${PRIVATE_SUBNET_NAME}" "$(libcloud_api GET "/v1/compute/subnets?vpc_id=${VPC_ID}")")"
fi
if [[ -z "${PRIVATE_SUBNET_ID}" ]]; then
  echo "Could not resolve or create subnet ${PRIVATE_SUBNET_NAME}." >&2
  exit 1
fi
echo "Private subnet ${PRIVATE_SUBNET_NAME} id=${PRIVATE_SUBNET_ID}"

# Internet gateway attached to the VPC (scenario step 3).
step "10" "Internet gateway ${IGW_NAME} — find or create+attach"
IGW_ID="$(libcloud_api GET "/v1/compute/internet-gateways?vpc_id=${VPC_ID}" | first_id)"
if [[ -z "${IGW_ID}" ]]; then
  CREATE_IGW_BODY=$(with_connection "$(python3 -c "
import json
print(json.dumps({'name': '${IGW_NAME}', 'vpc_id': '${VPC_ID}'}))
")")
  libcloud_api POST "/v1/compute/internet-gateways" "${CREATE_IGW_BODY}" | json_pretty
  IGW_ID="$(libcloud_api GET "/v1/compute/internet-gateways?vpc_id=${VPC_ID}" | first_id)"
fi
if [[ -z "${IGW_ID}" ]]; then
  echo "Could not resolve or create internet gateway for VPC ${VPC_ID}." >&2
  exit 1
fi
echo "Internet gateway id=${IGW_ID} (attached to VPC ${VPC_ID})"

# Public route table: 0.0.0.0/0 -> IGW, associated with the public subnet
# (scenario step 5, public half; the private half — NAT — is intentionally
# omitted so internal servers keep no internet route).
step "11" "Public route table ${PUBLIC_RT_NAME} — find or create, route + associate"
PUBLIC_RT_ID="$(VPC_ID="${VPC_ID}" RT_NAME="${PUBLIC_RT_NAME}" python3 -c '
import json, os, sys
d = json.load(sys.stdin).get("data", [])
m = [t for t in d if t.get("name") == os.environ["RT_NAME"]]
print(m[0]["id"] if m else "")
' <<<"$(libcloud_api GET "/v1/compute/route-tables?vpc_id=${VPC_ID}")")"
if [[ -z "${PUBLIC_RT_ID}" ]]; then
  CREATE_RT_BODY=$(with_connection "$(python3 -c "
import json
print(json.dumps({'name': '${PUBLIC_RT_NAME}', 'vpc_id': '${VPC_ID}'}))
")")
  libcloud_api POST "/v1/compute/route-tables" "${CREATE_RT_BODY}" | json_pretty
  PUBLIC_RT_ID="$(VPC_ID="${VPC_ID}" RT_NAME="${PUBLIC_RT_NAME}" python3 -c '
import json, os, sys
d = json.load(sys.stdin).get("data", [])
m = [t for t in d if t.get("name") == os.environ["RT_NAME"]]
print(m[0]["id"] if m else "")
' <<<"$(libcloud_api GET "/v1/compute/route-tables?vpc_id=${VPC_ID}")")"
fi
if [[ -z "${PUBLIC_RT_ID}" ]]; then
  echo "Could not resolve or create route table ${PUBLIC_RT_NAME}." >&2
  exit 1
fi

RT_STATE="$(libcloud_api GET "/v1/compute/route-tables?id=${PUBLIC_RT_ID}")"
# Add the default route only when missing (re-running must not duplicate it).
if [[ "$(python3 -c '
import json, sys
d = json.load(sys.stdin).get("data", [])
routes = d[0].get("routes", []) if d else []
print("yes" if any(r.get("cidr") == "0.0.0.0/0" for r in routes) else "no")
' <<<"${RT_STATE}")" == "no" ]]; then
  CREATE_ROUTE_BODY=$(with_connection "$(python3 -c "
import json
print(json.dumps({'cidr_block': '0.0.0.0/0', 'internet_gateway_id': '${IGW_ID}'}))
")")
  libcloud_api POST "/v1/compute/route-tables/${PUBLIC_RT_ID}/routes" "${CREATE_ROUTE_BODY}" | json_pretty
else
  echo "Route 0.0.0.0/0 -> ${IGW_ID} already present."
fi
# Associate with the public subnet only when not already associated.
if [[ "$(PUB_SUBNET="${PUBLIC_SUBNET_ID}" python3 -c '
import json, os, sys
d = json.load(sys.stdin).get("data", [])
assocs = d[0].get("subnet_associations", []) if d else []
print("yes" if any(a.get("subnet_id") == os.environ["PUB_SUBNET"] for a in assocs) else "no")
' <<<"${RT_STATE}")" == "no" ]]; then
  ASSOC_BODY=$(with_connection "$(python3 -c "
import json
print(json.dumps({'subnet_id': '${PUBLIC_SUBNET_ID}'}))
")")
  libcloud_api POST "/v1/compute/route-tables/${PUBLIC_RT_ID}:associate" "${ASSOC_BODY}" | json_pretty
else
  echo "Route table already associated with subnet ${PUBLIC_SUBNET_ID}."
fi
echo "Public route table ${PUBLIC_RT_NAME} id=${PUBLIC_RT_ID} (0.0.0.0/0 -> ${IGW_ID}, subnet ${PUBLIC_SUBNET_ID})"

# Security groups (scenario step 6). Rules are added only when missing — the
# GET response carries the parsed ingress rules so re-runs stay idempotent.
# Egress is NOT authorized explicitly: AWS VPC security groups already ship a
# default allow-all egress rule, and authorizing a duplicate errors out.
find_sg() {
  local name="$1"
  VPC_ID="${VPC_ID}" SG_NAME="${name}" python3 -c '
import json, os, sys
d = json.load(sys.stdin).get("data", [])
m = [g for g in d if g.get("name") == os.environ["SG_NAME"]]
print(m[0]["id"] if m else "")
' <<<"$(libcloud_api GET "/v1/compute/security-groups?vpc_id=${VPC_ID}")"
}

# sg_rule_present <sg_id> <port> <cidr-or-empty> <source-sg-id-or-empty>
sg_rule_present() {
  local sg_id="$1" port="$2" cidr="$3" src_sg="$4"
  SG_ID="${sg_id}" PORT="${port}" CIDR="${cidr}" SRC_SG="${src_sg}" python3 -c '
import json, os, sys
d = json.load(sys.stdin).get("data", [])
rules = d[0].get("ingress_rules", []) if d else []
port = os.environ["PORT"]
cidr = os.environ["CIDR"]
src_sg = os.environ["SRC_SG"]
for r in rules:
    if str(r.get("from_port")) != port or str(r.get("to_port")) != port:
        continue
    if cidr and cidr in (r.get("cidr_ips") or []):
        print("yes"); break
    if src_sg and any(p.get("group_id") == src_sg for p in (r.get("group_pairs") or [])):
        print("yes"); break
else:
    print("no")
' <<<"$(libcloud_api GET "/v1/compute/security-groups?id=${sg_id}")"
}

step "12" "Security groups ${BASTION_SG_NAME} / ${INTERNAL_SG_NAME} — find or create + rules"
BASTION_SG_ID="$(find_sg "${BASTION_SG_NAME}")"
if [[ -z "${BASTION_SG_ID}" ]]; then
  CREATE_SG_BODY=$(with_connection "$(python3 -c "
import json
print(json.dumps({'name': '${BASTION_SG_NAME}', 'description': 'Security group for bastion host', 'vpc_id': '${VPC_ID}'}))
")")
  libcloud_api POST "/v1/compute/security-groups" "${CREATE_SG_BODY}" | json_pretty
  BASTION_SG_ID="$(find_sg "${BASTION_SG_NAME}")"
fi
if [[ -z "${BASTION_SG_ID}" ]]; then
  echo "Could not resolve or create security group ${BASTION_SG_NAME}." >&2
  exit 1
fi
# Inbound SSH from the operator CIDR only (scenario: YOUR_CORPORATE_IP/32).
if [[ "$(sg_rule_present "${BASTION_SG_ID}" 22 "${BASTION_SSH_CIDR}" "")" == "no" ]]; then
  RULE_BODY=$(with_connection "$(python3 -c "
import json
print(json.dumps({
    'direction': 'ingress', 'protocol': 'tcp', 'from_port': 22, 'to_port': 22,
    'cidr_ips': ['${BASTION_SSH_CIDR}'], 'description': 'SSH from operator CIDR',
}))
")")
  libcloud_api POST "/v1/compute/security-groups/${BASTION_SG_ID}:authorize" "${RULE_BODY}" | json_pretty
fi
echo "Bastion SG ${BASTION_SG_NAME} id=${BASTION_SG_ID} (tcp/22 <- ${BASTION_SSH_CIDR})"

INTERNAL_SG_ID="$(find_sg "${INTERNAL_SG_NAME}")"
if [[ -z "${INTERNAL_SG_ID}" ]]; then
  CREATE_SG_BODY=$(with_connection "$(python3 -c "
import json
print(json.dumps({'name': '${INTERNAL_SG_NAME}', 'description': 'Security group for internal servers', 'vpc_id': '${VPC_ID}'}))
")")
  libcloud_api POST "/v1/compute/security-groups" "${CREATE_SG_BODY}" | json_pretty
  INTERNAL_SG_ID="$(find_sg "${INTERNAL_SG_NAME}")"
fi
if [[ -z "${INTERNAL_SG_ID}" ]]; then
  echo "Could not resolve or create security group ${INTERNAL_SG_NAME}." >&2
  exit 1
fi
# Inbound SSH from the bastion SG only (no direct internet path exists anyway).
if [[ "$(sg_rule_present "${INTERNAL_SG_ID}" 22 "" "${BASTION_SG_ID}")" == "no" ]]; then
  RULE_BODY=$(with_connection "$(python3 -c "
import json
print(json.dumps({
    'direction': 'ingress', 'protocol': 'tcp', 'from_port': 22, 'to_port': 22,
    'source_group_id': '${BASTION_SG_ID}', 'description': 'SSH from bastion SG',
}))
")")
  libcloud_api POST "/v1/compute/security-groups/${INTERNAL_SG_ID}:authorize" "${RULE_BODY}" | json_pretty
fi
# App port from inside the VPC only (scenario step 6, internal SG).
if [[ "$(sg_rule_present "${INTERNAL_SG_ID}" "${INTERNAL_APP_PORT}" "${VPC_CIDR}" "")" == "no" ]]; then
  RULE_BODY=$(with_connection "$(python3 -c "
import json
print(json.dumps({
    'direction': 'ingress', 'protocol': 'tcp',
    'from_port': int('${INTERNAL_APP_PORT}'), 'to_port': int('${INTERNAL_APP_PORT}'),
    'cidr_ips': ['${VPC_CIDR}'], 'description': 'App traffic from VPC',
}))
")")
  libcloud_api POST "/v1/compute/security-groups/${INTERNAL_SG_ID}:authorize" "${RULE_BODY}" | json_pretty
fi
echo "Internal SG ${INTERNAL_SG_NAME} id=${INTERNAL_SG_ID} (tcp/22 <- ${BASTION_SG_ID}, tcp/${INTERNAL_APP_PORT} <- ${VPC_CIDR})"

# Key pair (scenario step 7). The private key material is returned only at
# creation time; persist it chmod 400 when we create the pair.
step "13" "Key pair ${KEY_PAIR_NAME} — find or create"
KEY_EXISTS="$(KP_NAME="${KEY_PAIR_NAME}" python3 -c '
import json, os, sys
d = json.load(sys.stdin).get("data", [])
print("yes" if any(k.get("name") == os.environ["KP_NAME"] for k in d) else "no")
' <<<"$(libcloud_api GET "/v1/compute/key-pairs")")"
if [[ "${KEY_EXISTS}" == "no" ]]; then
  CREATE_KEY_BODY=$(with_connection "$(python3 -c "
import json
print(json.dumps({'name': '${KEY_PAIR_NAME}'}))
")")
  KEY_RESP="$(libcloud_api POST "/v1/compute/key-pairs" "${CREATE_KEY_BODY}")"
  echo "${KEY_RESP}" | json_pretty
  if KEY_RESP="${KEY_RESP}" KEY_FILE="${KEY_FILE}" python3 -c '
import json, os, sys
key = json.loads(os.environ["KEY_RESP"]).get("data", {}).get("private_key") or ""
if not key:
    sys.exit(1)
with open(os.environ["KEY_FILE"], "w", encoding="utf-8") as fh:
    fh.write(key if key.endswith("\n") else key + "\n")
os.chmod(os.environ["KEY_FILE"], 0o400)
print(os.environ["KEY_FILE"])
' >/dev/null; then
    echo "Private key saved to ${KEY_FILE} (chmod 400)."
  else
    echo "WARNING: could not persist the private key to ${KEY_FILE}." >&2
  fi
fi
echo "Key pair ${KEY_PAIR_NAME} ready."

# --------------------------------------------------------------------------- #
# Steps 14-15: the two VMs (scenario steps 9-10, one internal server)
# --------------------------------------------------------------------------- #
NODE_COMMON=$(python3 -c "
import json
print(json.dumps({'size': {'id': '${SIZE_ID}'}, 'image': {'id': '${IMAGE_ID}'},
                  'auth': {'type': 'key_pair', 'key_name': '${KEY_PAIR_NAME}'},
                  'execution': {'wait_until_running': True, 'timeout_seconds': 300}}))
")

step "14" "Bastion VM ${BASTION_NAME} (public subnet + public IP, SG ${BASTION_SG_NAME})"
BASTION_BODY=$(with_connection "$(NODE_COMMON="${NODE_COMMON}" python3 -c "
import json, os
body = json.loads(os.environ['NODE_COMMON'])
body['name'] = '${BASTION_NAME}'
body['network'] = {
    'public_ip': True,
    'subnet_id': '${PUBLIC_SUBNET_ID}',
    'security_group': '${BASTION_SG_ID}',
}
print(json.dumps(body))
")")
libcloud_api POST "/v1/compute/nodes" "${BASTION_BODY}" | json_pretty

step "15" "Internal VM ${INTERNAL_NAME} (private subnet, NO public IP, SG ${INTERNAL_SG_NAME})"
INTERNAL_BODY=$(with_connection "$(NODE_COMMON="${NODE_COMMON}" python3 -c "
import json, os
body = json.loads(os.environ['NODE_COMMON'])
body['name'] = '${INTERNAL_NAME}'
body['network'] = {
    'public_ip': False,
    'subnet_id': '${PRIVATE_SUBNET_ID}',
    'security_group': '${INTERNAL_SG_ID}',
}
print(json.dumps(body))
")")
libcloud_api POST "/v1/compute/nodes" "${INTERNAL_BODY}" | json_pretty

step "16" "Summary"
libcloud_api GET "/v1/compute/nodes" | json_pretty
cat <<EOF

Bastion + private stack ready (tenant binding=${LIBCLOUD_AWS_AUTH_BINDING}, region=${AWS_REGION}):
  VPC            ${VPC_NAME} (${VPC_CIDR})            ${VPC_ID}
  Public subnet  ${PUBLIC_SUBNET_NAME} (${PUBLIC_SUBNET_CIDR})  ${PUBLIC_SUBNET_ID}
  Private subnet ${PRIVATE_SUBNET_NAME} (${PRIVATE_SUBNET_CIDR}) ${PRIVATE_SUBNET_ID}  (no internet route, no NAT)
  Bastion VM     ${BASTION_NAME}  SG=${BASTION_SG_NAME} (ssh/22 from ${BASTION_SSH_CIDR})
  Internal VM    ${INTERNAL_NAME} SG=${INTERNAL_SG_NAME} (ssh/22 from bastion SG only)

SSH once the VMs report running (key: ${KEY_FILE}):
  ssh -i ${KEY_FILE} ubuntu@<BASTION_PUBLIC_IP>
  ssh -i ${KEY_FILE} -J ubuntu@<BASTION_PUBLIC_IP> ubuntu@<INTERNAL_PRIVATE_IP>
EOF

# --------------------------------------------------------------------------- #
# Copy the private key to the caller's host /tmp via base64 in the output.
# The caller can copy the base64 block from the browser and decode it locally:
#   base64 -d > /tmp/libcloud-private-key.pem << 'KEY_EOF'
#   <paste block>
#   KEY_EOF
#   chmod 400 /tmp/libcloud-private-key.pem
# --------------------------------------------------------------------------- #
if [[ -f "${KEY_FILE}" ]]; then
  echo
  echo "=== Private Key (base64-encoded — copy to host /tmp) =========="
  echo "# On your local host, run:"
  echo "#   mkdir -p /tmp"
  echo "#   base64 -d > /tmp/${KEY_PAIR_NAME}.pem << 'KEY_EOF'"
  base64 "${KEY_FILE}"
  echo "KEY_EOF"
  echo "#   chmod 400 /tmp/${KEY_PAIR_NAME}.pem"
  echo "=== End Private Key ============================================"
else
  echo
  echo "WARNING: Private key file ${KEY_FILE} not found — it may already exist from a previous run."
  echo "Re-run with a fresh KEY_PAIR_NAME or delete the existing key on the server to regenerate."
fi

if [[ "${TEARDOWN_VMS}" == "1" ]]; then
  teardown_libcloud_vms "${BASTION_NAME}"
  teardown_libcloud_vms "${INTERNAL_NAME}"
fi

echo
echo "AWS bastion + private VM provisioning flow completed."
