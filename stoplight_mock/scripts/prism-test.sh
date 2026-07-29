#!/usr/bin/env bash
# ─── Prism Mock Server Test (stoplight_mock-prism-1) ──────────────────────────
# Verifies the Stoplight Prism container is up and serving schema-valid mock
# responses on http://localhost:4010.
#
# Usage:
#   chmod +x scripts/prism-test.sh
#   ./scripts/prism-test.sh [prism_url] [container_name]
#
# Defaults: URL http://localhost:4010, container stoplight_mock-prism-1
#
# Notes on the Nutanix v4 spec (enforced by Prism request validation):
#   - Mutating calls (POST/PUT/DELETE) require the  Ntnx-Request-Id  header.
#   - $actions and DELETE calls additionally require the  If-Match  header.
#   - Path extIds must match the UUID pattern, else Prism replies 422.

set -uo pipefail

PRISM="${1:-http://localhost:4010}"
CONTAINER="${2:-stoplight_mock-prism-1}"

REQ_ID="11111111-2222-3333-4444-555555555555"
VM_ID="00000000-0000-0000-0000-000000000001"

PASS=0
FAIL=0

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; ((PASS++)); }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*"; ((FAIL++)); }
header() { printf '\n\033[1;36m── %s ──\033[0m\n' "$*"; }

# check <desc> <expected_code> [curl args...]
check() {
  local desc="$1" expected="$2"
  shift 2
  local code
  code=$(curl -s -o /tmp/prism_test_resp.json -w '%{http_code}' "$@" 2>&1) || true
  if [[ "$code" == "$expected" ]]; then
    green "$desc (HTTP $code)"
  else
    red "$desc — expected $expected, got $code"
    head -c 300 /tmp/prism_test_resp.json 2>/dev/null || true
    echo ""
  fi
}

# check_body <desc> <expected_code> <grep pattern> [curl args...]
check_body() {
  local desc="$1" expected="$2" pattern="$3"
  shift 3
  local code
  code=$(curl -s -o /tmp/prism_test_resp.json -w '%{http_code}' "$@" 2>&1) || true
  if [[ "$code" == "$expected" ]] && grep -q "$pattern" /tmp/prism_test_resp.json; then
    green "$desc (HTTP $code, body matches '$pattern')"
  elif [[ "$code" != "$expected" ]]; then
    red "$desc — expected HTTP $expected, got $code"
  else
    red "$desc — HTTP $code but body missing '$pattern'"
    head -c 300 /tmp/prism_test_resp.json; echo ""
  fi
}

echo "╔══════════════════════════════════════════════════════╗"
echo "║   Prism Mock Server Test                            ║"
printf  "║   Target: %-43s║\n" "$PRISM"
echo "╚══════════════════════════════════════════════════════╝"

# ── 0. Container check ───────────────────────────────────────────────────────
header "0. Docker container"
if docker ps --filter "name=^/${CONTAINER}$" --filter status=running -q 2>/dev/null | grep -q .; then
  green "Container $CONTAINER is running"
else
  red "Container $CONTAINER is NOT running (docker ps found nothing)"
fi

# ── 1. Basic reachability / list endpoints ───────────────────────────────────
header "1. List endpoints (GET, expect 200 + JSON body)"
check_body "List AHV VMs"        200 '"data"' "$PRISM/api/vmm/v4.0/ahv/config/vms"
check_body "List ESXi VM stats (\$startTime/\$endTime required)" 200 '"data"' \
  "$PRISM/api/vmm/v4.0/esxi/stats/vms?\$startTime=2026-07-01T00:00:00Z&\$endTime=2026-07-02T00:00:00Z"
check_body "List images"         200 '"data"' "$PRISM/api/vmm/v4.0/content/images"
check_body "List templates"      200 '"data"' "$PRISM/api/vmm/v4.0/content/templates"
check_body "List subnets"        200 '"data"' "$PRISM/api/networking/v4.0/config/subnets"
check_body "List VPCs"           200 '"data"' "$PRISM/api/networking/v4.0/config/vpcs"
check_body "List clusters"       200 '"data"' "$PRISM/api/clustermgmt/v4.0/config/clusters"
check      "List VMs with \$page/\$limit" 200 "$PRISM/api/vmm/v4.0/ahv/config/vms?\$page=0&\$limit=10"

# ── 2. Single resource & validation ──────────────────────────────────────────
header "2. Single resource / request validation"
check_body "Get VM by valid UUID"  200 '"extId"' "$PRISM/api/vmm/v4.0/ahv/config/vms/$VM_ID"
check      "Get VM with invalid UUID → 422" 422 "$PRISM/api/vmm/v4.0/ahv/config/vms/not-a-uuid"
check_body "Unknown path → 404 (Prism NO_PATH_MATCHED)" 404 'NO_PATH_MATCHED_ERROR' \
  "$PRISM/api/does/not/exist"

# ── 3. Mutations (need Ntnx-Request-Id) ──────────────────────────────────────
header "3. Mutations (Ntnx-Request-Id required)"
check "Create VM without Ntnx-Request-Id → 422" 422 \
  -X POST "$PRISM/api/vmm/v4.0/ahv/config/vms" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"probe-vm\",\"cluster\":{\"extId\":\"$VM_ID\"}}"

check "Create VM with Ntnx-Request-Id → 202" 202 \
  -X POST "$PRISM/api/vmm/v4.0/ahv/config/vms" \
  -H "Ntnx-Request-Id: $REQ_ID" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"probe-vm\",\"cluster\":{\"extId\":\"$VM_ID\"}}"

# ── 4. Actions / delete (also need If-Match) ─────────────────────────────────
header "4. \$actions and DELETE (If-Match also required)"
check "Power-on missing If-Match → 422" 422 \
  -X POST "$PRISM/api/vmm/v4.0/ahv/config/vms/$VM_ID/\$actions/power-on" \
  -H "Ntnx-Request-Id: $REQ_ID"

check "Power-on with both headers → 202" 202 \
  -X POST "$PRISM/api/vmm/v4.0/ahv/config/vms/$VM_ID/\$actions/power-on" \
  -H "Ntnx-Request-Id: $REQ_ID" -H 'If-Match: *'

check "Power-off with both headers → 202" 202 \
  -X POST "$PRISM/api/vmm/v4.0/ahv/config/vms/$VM_ID/\$actions/power-off" \
  -H "Ntnx-Request-Id: $REQ_ID" -H 'If-Match: *'

check "Delete VM with both headers → 202" 202 \
  -X DELETE "$PRISM/api/vmm/v4.0/ahv/config/vms/$VM_ID" \
  -H "Ntnx-Request-Id: $REQ_ID" -H 'If-Match: *'

# ── 5. Response format ───────────────────────────────────────────────────────
header "5. Response format"
CTYPE=$(curl -s -o /dev/null -w '%{content_type}' "$PRISM/api/vmm/v4.0/ahv/config/vms")
if [[ "$CTYPE" == application/json* ]]; then
  green "Content-Type is $CTYPE"
else
  red "Content-Type unexpected: $CTYPE"
fi

if curl -s "$PRISM/api/vmm/v4.0/ahv/config/vms" | python3 -m json.tool >/dev/null 2>&1; then
  green "Response body is valid JSON"
else
  red "Response body is not valid JSON"
fi

# ── 6. Summary ───────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
printf "  Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
echo "════════════════════════════════════════════════════════"

exit "$FAIL"
