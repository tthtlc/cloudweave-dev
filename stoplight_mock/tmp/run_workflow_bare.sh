#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────
# run_workflow_bare.sh
#
# Minimal reproduction: REST API description change → state sync → Terraform
# name change.  Assumes infrastructure is already provisioned.
#
# Usage:  ./run_workflow_bare.sh
#
# Records state snapshots to tfstate-snapshots/ for post-hoc analysis.
# ──────────────────────────────────────────────────────────────────────────
set -e

TERRAFORM_DIR="${PWD}/terraform-network"
WORKSPACE="/workspace"
TERRAFORM="docker compose run --rm -v ${TERRAFORM_DIR}:${WORKSPACE} terraform"
EMULATOR="docker compose exec -T emulator"
SNAPSHOT_DIR="tfstate-snapshots"

mkdir -p "${SNAPSHOT_DIR}"

# ── Provision (if not already done) ─────────────────────────────────────
${TERRAFORM} init 2>&1 | tail -1
${TERRAFORM} apply -auto-approve 2>&1 | tail -5

SUBNET_ID=$(${TERRAFORM} output -raw external_subnet_ext_id 2>&1 | tail -1)
echo "SUBNET_ID=${SUBNET_ID}"

# Record initial state
${TERRAFORM} state show nutanix_subnet_v2.external 2>&1 | tee "${SNAPSHOT_DIR}/bare-01-before-cli.txt"

# ── 1. Modify description via REST API (out-of-band) ────────────────────
${EMULATOR} curl -sk -X PUT \
  "https://localhost:9440/api/networking/v4.0/config/subnets/${SUBNET_ID}" \
  -H "Content-Type: application/json" \
  -d '{"description": "CLI-modified-description-via-rest-api"}' 2>&1

sleep 1

# Verify provider-side
${EMULATOR} curl -sk \
  "https://localhost:9440/api/networking/v4.0/config/subnets/${SUBNET_ID}" 2>&1 | \
  python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(f'provider name={d[\"name\"]} desc={d.get(\"description\",\"\")}')"

# ── 2. Sync Terraform state with out-of-band change ─────────────────────
${TERRAFORM} apply -refresh-only -auto-approve 2>&1 | tail -5

# Record post-sync state
${TERRAFORM} state show nutanix_subnet_v2.external 2>&1 | tee "${SNAPSHOT_DIR}/bare-02-after-refresh.txt"

# ── 3. Modify name via Terraform (in-place) ─────────────────────────────
${TERRAFORM} apply -auto-approve \
  -var="external_subnet_name=new-name-via-terraform-inplace" 2>&1 | tail -5

# Record final state
${TERRAFORM} state show nutanix_subnet_v2.external 2>&1 | tee "${SNAPSHOT_DIR}/bare-03-after-terraform.txt"

# ── 4. Record full state for analysis ───────────────────────────────────
${TERRAFORM} show -json 2>&1 > "${SNAPSHOT_DIR}/bare-final-state.json"

# Provider-side final
${EMULATOR} curl -sk \
  "https://localhost:9440/api/networking/v4.0/config/subnets/${SUBNET_ID}" 2>&1 > "${SNAPSHOT_DIR}/bare-final-provider.json"

# ── 5. Summary ──────────────────────────────────────────────────────────
echo ""
echo "=== COMPLETE ==="
echo "Snapshots: ${SNAPSHOT_DIR}/bare-*.{txt,json}"
echo "Subnet:    ${SUBNET_ID}"
${TERRAFORM} output -raw external_subnet_name 2>&1 | tail -1 | xargs -I{} echo "Name:      {}"
python3 -c "
import json
d = json.load(open('${TERRAFORM_DIR}/terraform.tfstate'))
for r in d.get('resources', []):
    if r.get('name') == 'external':
        print('Description:', r['instances'][0]['attributes'].get('description','?'))
        break
"
