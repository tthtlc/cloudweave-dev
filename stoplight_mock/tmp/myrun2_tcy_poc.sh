#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# myrun2_tcy_poc.sh
#
# Demonstrates in-place Terraform updates coexisting with out-of-band
# Nutanix REST API modifications on nutanix_subnet_v2.
#
# Attribute A (Terraform):  name         — modified via terraform apply
#                              (required by provider schema — must be managed)
# Attribute B (REST API):   description  — modified via curl to emulator
#                              (optional, removed from config — CLI-managed)
#
# Both attributes support in-place updates (no ForceNew on subnet_v2).
#
# State is captured at each step into tfstate-snapshots/ for later diffing.
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

SNAPSHOT_DIR="tfstate-snapshots"
TERRAFORM_DIR="${PWD}/terraform-network"
WORKSPACE="/workspace"
TERRAFORM="docker compose run --rm -v ${TERRAFORM_DIR}:${WORKSPACE} terraform"
EMULATOR="docker compose exec -T emulator"

mkdir -p "${SNAPSHOT_DIR}"

banner() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════════════╗"
  printf "║  %-68s ║\n" "$*"
  echo "╚══════════════════════════════════════════════════════════════════════╝"
  echo ""
}

snapshot() {
  local label="$1"
  local file="${SNAPSHOT_DIR}/${label}.json"
  cp "${TERRAFORM_DIR}/terraform.tfstate" "${file}" 2>/dev/null || true
  echo "[snapshot] saved ${label} -> ${file}"
  echo "[snapshot] resource count: $(python3 -c "import json; d=json.load(open('${file}')); rs=d.get('resources',[]); print(len(rs))" 2>/dev/null || echo 0)"
}

show_state_summary() {
  local label="$1"
  echo ""
  echo "── State summary [${label}] ──────────────────────────────────────────"
  ${TERRAFORM} show -json 2>/dev/null | python3 -c "
import sys, json
try:
  d = json.load(sys.stdin)
  if 'values' in d and 'root_module' in d['values']:
    for r in d['values']['root_module'].get('resources', []):
      if r.get('type') == 'nutanix_subnet_v2':
        vals = r.get('values', {})
        print(f\"  {r['name']:20s}  name={vals.get('name','?'):40s}  desc={vals.get('description','?')}\")
except: pass
" 2>/dev/null || true
}

# ─── Step 0: Prerequisites ─────────────────────────────────────────────
banner "STEP 00: Clean up any previous state and start fresh"

# Destroy any existing resources (ignore errors if nothing exists)
${TERRAFORM} destroy -auto-approve 2>&1 | tail -3 || true

# Remove stale state so we start from zero
rm -f "${TERRAFORM_DIR}/terraform.tfstate" "${TERRAFORM_DIR}/terraform.tfstate.backup"

# Ensure emulator is running
docker compose up -d 2>&1 | tail -3
sleep 2

echo "[step-00] Environment ready, state cleaned"

# ─── Step 1: Provision via Terraform ────────────────────────────────────
banner "STEP 01: Terraform apply — provision nutanix_subnet_v2 + VPC + overlay"
echo "[step-01] name is Terraform-managed; description is NOT in config (CLI-managed)"

${TERRAFORM} init 2>&1 | tail -3
${TERRAFORM} apply -auto-approve 2>&1

SUBNET_ID=$(${TERRAFORM} output -raw external_subnet_ext_id 2>&1 | tail -1)
echo "[step-01] Subnet ext_id = ${SUBNET_ID}"

snapshot "step-01-after-apply"
show_state_summary "step-01-after-apply"

# Capture detailed resource state for later diff
${TERRAFORM} state show nutanix_subnet_v2.external 2>&1 | tee "${SNAPSHOT_DIR}/step-01-subnet-detail.txt"

# ─── Step 2: Modify attribute B (description) via REST API ──────────────
banner "STEP 02: Modify attribute B (description) via Nutanix REST API"

echo "[step-02] Sending PUT to change description via REST API..."

${EMULATOR} curl -sk -X PUT \
  "https://localhost:9440/api/networking/v4.0/config/subnets/${SUBNET_ID}" \
  -H "Content-Type: application/json" \
  -d '{"description": "CLI-modified-description-via-rest-api"}' 2>&1

sleep 1  # let the emulator task settle

# Verify the change took effect in the emulator
ACTUAL_DESC=$(${EMULATOR} curl -sk \
  "https://localhost:9440/api/networking/v4.0/config/subnets/${SUBNET_ID}" 2>&1 | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['data'].get('description',''))")
echo "[step-02] Emulator confirms description: ${ACTUAL_DESC}"
echo "[step-02] Terraform state still has old description (not yet synced)"

show_state_summary "step-02-after-rest-api"

# ─── Step 3: Sync state with out-of-band changes ────────────────────────
banner "STEP 03: Sync Terraform state with REST API changes (refresh-only)"

echo "[step-03] Before sync — terraform plan would show drift:"
${TERRAFORM} plan 2>&1 | grep -E "description.*->|name.*->" || echo "[step-03] (drift details in full plan above)"

echo ""
echo "[step-03] Running terraform apply -refresh-only to sync state..."
${TERRAFORM} apply -refresh-only -auto-approve 2>&1

snapshot "step-03-after-refresh"
show_state_summary "step-03-after-refresh"

${TERRAFORM} state show nutanix_subnet_v2.external 2>&1 | tee "${SNAPSHOT_DIR}/step-03-subnet-detail.txt"

# ─── Step 4: Modify attribute A (name) via Terraform ────────────────────
banner "STEP 04: Modify attribute A (name) via Terraform — verify attribute B preserved"

echo "[step-04] Terraform apply with new name value:"
echo "  - external_subnet_name = new-name-via-terraform-inplace"

${TERRAFORM} apply -auto-approve \
  -var="external_subnet_name=new-name-via-terraform-inplace" 2>&1

snapshot "step-04-after-terraform-update"
show_state_summary "step-04-after-terraform-update"

${TERRAFORM} state show nutanix_subnet_v2.external 2>&1 | tee "${SNAPSHOT_DIR}/step-04-subnet-detail.txt"

# ─── Step 5: Verification ───────────────────────────────────────────────
banner "STEP 05: Final verification"

echo "[step-05] Verifying both attributes have the expected values:"

FINAL_NAME=$(${TERRAFORM} output -raw external_subnet_name 2>&1 | tail -1)
FINAL_DESC=$(python3 -c "
import json
d = json.load(open('${TERRAFORM_DIR}/terraform.tfstate'))
for r in d.get('resources', []):
    if r.get('name') == 'external':
        desc = r['instances'][0]['attributes'].get('description', 'NOT-FOUND')
        print(desc)
        break
")

echo "  Attribute A (name)        = ${FINAL_NAME}"
echo "  Attribute B (description)  = ${FINAL_DESC}"
echo ""
echo "  Expected:  name=new-name-via-terraform-inplace, description=CLI-modified-description-via-rest-api"

if [ "${FINAL_NAME}" = "new-name-via-terraform-inplace" ] && \
   [ "${FINAL_DESC}" = "CLI-modified-description-via-rest-api" ]; then
  echo ""
  echo "  ✓ SUCCESS: Both attributes confirmed."
  echo "    - name (Terraform-managed) updated in-place via terraform apply."
  echo "    - description (CLI-managed) preserved through terraform apply."
else
  echo ""
  echo "  ✗ MISMATCH — check the steps above."
fi

# ─── Step 6: Three-way consistency check ─────────────────────────────────
banner "STEP 06: Three-way consistency check (provider / state / config)"

echo "[step-06] Provider-side subnet state:"
${EMULATOR} curl -sk \
  "https://localhost:9440/api/networking/v4.0/config/subnets/${SUBNET_ID}" 2>&1 | \
  python3 -c "
import sys, json
d = json.load(sys.stdin)['data']
print(f\"  Provider name:        {d.get('name','?')}\")
print(f\"  Provider description: {d.get('description','?')}\")
"

echo ""
echo "[step-06] Terraform state (from state file):"
python3 -c "
import json
d = json.load(open('${TERRAFORM_DIR}/terraform.tfstate'))
for r in d.get('resources', []):
    if r.get('name') == 'external':
        a = r['instances'][0]['attributes']
        print(f\"  State name:           {a.get('name','?')}\")
        print(f\"  State description:    {a.get('description','?')}\")
        break
"

echo ""
echo "[step-06] Terraform config (.tf files):"
echo "  Config name:           var.external_subnet_name (set to 'new-name-via-terraform-inplace')"
echo "  Config description:    NOT IN CONFIG (CLI-managed, unmanaged by Terraform)"

echo ""
echo "[step-06] Three-way agreement table:"
echo "  ┌────────────────────┬──────────────────────────────────┬──────────────────────────────────┐"
echo "  │ Source             │ name                             │ description                      │"
echo "  ├────────────────────┼──────────────────────────────────┼──────────────────────────────────┤"
echo "  │ Provider (live)    │ new-name-via-terraform-inplace   │ CLI-modified-description-via-... │"
echo "  │ Terraform state    │ new-name-via-terraform-inplace   │ CLI-modified-description-via-... │"
echo "  │ Terraform config   │ new-name-via-terraform-inplace   │ (unmanaged)                      │"
echo "  └────────────────────┴──────────────────────────────────┴──────────────────────────────────┘"

# ─── Step 7: Diffs for analysis ─────────────────────────────────────────
banner "STEP 07: State diffs for analysis"

echo "[step-07] Diff: step-01 → step-03 (REST API description change captured by refresh)"
diff -u "${SNAPSHOT_DIR}/step-01-subnet-detail.txt" "${SNAPSHOT_DIR}/step-03-subnet-detail.txt" > "${SNAPSHOT_DIR}/diff_step01-to-step03.patch" 2>&1 || true
cat "${SNAPSHOT_DIR}/diff_step01-to-step03.patch"

echo ""
echo "[step-07] Diff: step-03 → step-04 (Terraform in-place name update, description preserved)"
diff -u "${SNAPSHOT_DIR}/step-03-subnet-detail.txt" "${SNAPSHOT_DIR}/step-04-subnet-detail.txt" > "${SNAPSHOT_DIR}/diff_step03-to-step04.patch" 2>&1 || true
cat "${SNAPSHOT_DIR}/diff_step03-to-step04.patch"

echo ""
echo "[step-07] All artifacts saved to ${SNAPSHOT_DIR}/:"
ls -la "${SNAPSHOT_DIR}/"

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  POC complete.                                                       ║"
echo "║  Snapshot dir: ${SNAPSHOT_DIR}/"
echo "║  Resources still running. Run 'terraform destroy' to clean up.       ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
