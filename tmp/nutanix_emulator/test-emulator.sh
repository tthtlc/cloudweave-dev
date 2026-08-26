#!/usr/bin/env bash
# DEPRECATED: superseded by scripts/test.sh (run `./scripts/test.sh` instead).
# ─── Emulator container test: stoplight_mock-emulator-1 ──────────────────────
# Verifies the Nutanix emulator shim (and its Prism upstream) is working:
#   health endpoint, seed data, VM lifecycle, networking resources,
#   volume groups, recovery points, and the catch-all proxy to Prism.
#
# Usage:
#   chmod +x scripts/test-emulator.sh
#   ./scripts/test-emulator.sh [base_url]
#
# Default base URL: https://localhost:9440 (self-signed cert, curl uses -k)
# Exit code: number of failed checks (0 = all good)

set -uo pipefail

BASE="${1:-https://localhost:9440}"
PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; PASS=$((PASS+1)); }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*"; FAIL=$((FAIL+1)); }
hdr()   { printf '\n\033[1;36m── %s ──\033[0m\n' "$*"; }

# Extract a dotted path from JSON on stdin; empty string on failure.
jget() { python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for k in sys.argv[1].split('.'):
        d = d[int(k)] if isinstance(d, list) else d[k]
    print(d if d is not None else '')
except Exception:
    print('')
" "$1" 2>/dev/null; }

# check <desc> <method> <path> <expected_status> [json_body]
check() {
  local desc="$1" method="$2" path="$3" expected="$4" body="${5:-}"
  local args=(-sk -o "$TMP/resp.json" -w '%{http_code}' -X "$method" "$BASE$path")
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")
  local code
  code=$(curl "${args[@]}" 2>&1) || code="curl-error"
  if [[ "$code" == "$expected" ]]; then
    green "$desc (HTTP $code)"
  else
    red "$desc — expected $expected, got $code"
    head -c 300 "$TMP/resp.json" 2>/dev/null; echo
  fi
}

# poll_task <task_id> -> echoes final status; returns 0 if SUCCEEDED
poll_task() {
  local tid="$1" status=""
  for _ in $(seq 1 15); do
    status=$(curl -sk "$BASE/api/prism/v4.0/config/tasks/$tid" | jget data.status)
    [[ "$status" == "SUCCEEDED" ]] && return 0
    sleep 0.5
  done
  echo "$status"
  return 1
}

echo "╔══════════════════════════════════════════════════════╗"
echo "║   Emulator test: stoplight_mock-emulator-1          ║"
echo "║   Target: $BASE"
echo "╚══════════════════════════════════════════════════════╝"

# ── 0. Container sanity (informational) ──────────────────────────────────────
hdr "0. Docker container"
if docker ps --filter name=stoplight_mock-emulator-1 --format '{{.Names}}' 2>/dev/null | grep -q stoplight_mock-emulator-1; then
  green "container stoplight_mock-emulator-1 is up"
else
  red "container stoplight_mock-emulator-1 not found in docker ps"
fi

# ── 1. Health ────────────────────────────────────────────────────────────────
hdr "1. Health"
check "GET /health" GET /health 200
H=$(curl -sk "$BASE/health" | jget status)
[[ "$H" == "ok" ]] && green "health status is 'ok'" || red "health status: '$H'"

# ── 2. Seed reference data ───────────────────────────────────────────────────
hdr "2. Seed data"
check "List clusters"           GET /api/cluster-mgmt/v4.0/config/clusters 200
check "List subnets"            GET /api/networking/v4.0/config/subnets 200
check "List images (config)"    GET /api/vmm/v4.0/config/images 200
check "List images (content)"   GET /api/vmm/v4.0/content/images 200
check "List storage containers" GET /api/vmm/v4.0/config/storage-containers 200
check "v4.0.a1 path variant"    GET /api/vmm/v4.0.a1/config/vms 200
check "ahv path variant"        GET /api/vmm/v4.0/ahv/config/vms 200

N=$(curl -sk "$BASE/api/networking/v4.0/config/subnets" | jget metadata.totalAvailableResults)
[[ "$N" -ge 1 ]] && green "seed subnet present ($N)" || red "seed subnet missing"
N=$(curl -sk "$BASE/api/vmm/v4.0/config/images" | jget metadata.totalAvailableResults)
[[ "$N" -ge 2 ]] && green "seed images present ($N)" || red "seed images missing ($N)"

# ── 3. VM lifecycle ──────────────────────────────────────────────────────────
hdr "3. VM lifecycle (create → task → get → update → power → delete)"
VM_BODY='{
  "name": "curl-test-vm",
  "description": "created by test-emulator.sh",
  "num_sockets": 2,
  "num_cores_per_socket": 2,
  "memory_size_bytes": 4294967296,
  "nics": [{ "subnet": { "ext_id": "00000000-0000-0000-0000-000000000002" } }]
}'

RESP=$(curl -sk -X POST "$BASE/api/vmm/v4.0/ahv/config/vms" -H 'Content-Type: application/json' -d "$VM_BODY")
TASK_ID=$(echo "$RESP" | jget data.extId)
[[ -n "$TASK_ID" ]] && green "POST create VM accepted (task $TASK_ID)" || red "POST create VM: no task id — $RESP"

VM_ID=""
if [[ -n "$TASK_ID" ]]; then
  if poll_task "$TASK_ID" >/dev/null; then
    green "create task SUCCEEDED"
    VM_ID=$(curl -sk "$BASE/api/prism/v4.0/config/tasks/$TASK_ID" | jget data.entitiesAffected.0.extId)
  else
    red "create task did not reach SUCCEEDED"
  fi
fi

if [[ -n "$VM_ID" ]]; then
  NAME=$(curl -sk "$BASE/api/vmm/v4.0/ahv/config/vms/$VM_ID" | jget data.name)
  [[ "$NAME" == "curl-test-vm" ]] && green "GET VM name ok" || red "GET VM name: '$NAME'"

  # Update
  RESP=$(curl -sk -X PUT "$BASE/api/vmm/v4.0/ahv/config/vms/$VM_ID" \
    -H 'Content-Type: application/json' -d '{"name":"curl-test-vm-v2","numSockets":4}')
  UTASK=$(echo "$RESP" | jget data.extId)
  [[ -n "$UTASK" ]] && poll_task "$UTASK" >/dev/null && green "PUT update task SUCCEEDED" || red "PUT update failed"
  NAME=$(curl -sk "$BASE/api/vmm/v4.0/ahv/config/vms/$VM_ID" | jget data.name)
  [[ "$NAME" == "curl-test-vm-v2" ]] && green "updated name persisted" || red "updated name: '$NAME'"

  # Power action (v4 $actions URL — single quotes protect the $)
  RESP=$(curl -sk -X POST "$BASE/api/vmm/v4.0/ahv/config/vms/$VM_ID/\$actions/power-off" -H 'Content-Type: application/json' -d '{}')
  PTASK=$(echo "$RESP" | jget data.extId)
  [[ -n "$PTASK" ]] && green "power-off accepted (task $PTASK)" || red "power-off: no task — $RESP"
  sleep 1
  PS=$(curl -sk "$BASE/api/vmm/v4.0/ahv/config/vms/$VM_ID" | jget data.powerState)
  [[ "$PS" == "OFF" ]] && green "power state is OFF" || red "power state: '$PS' (expected OFF)"

  # Legacy power-state URL
  check "legacy /power-state/power-on" POST "/api/vmm/v4.0/ahv/config/vms/$VM_ID/power-state/power-on" 202 '{}'

  # List + $filter
  check "List VMs" GET /api/vmm/v4.0/ahv/config/vms 200
  F=$(curl -sk --get --data-urlencode "\$filter=name eq 'curl-test-vm-v2'" "$BASE/api/vmm/v4.0/ahv/config/vms" | jget metadata.totalAvailableResults)
  [[ "$F" == "1" ]] && green "\$filter by name works" || red "\$filter returned $F results (expected 1)"

  # Delete
  RESP=$(curl -sk -X DELETE "$BASE/api/vmm/v4.0/ahv/config/vms/$VM_ID")
  DTASK=$(echo "$RESP" | jget data.extId)
  [[ -n "$DTASK" ]] && poll_task "$DTASK" >/dev/null && green "DELETE task SUCCEEDED" || red "DELETE failed"
  check "GET deleted VM → 404" GET "/api/vmm/v4.0/ahv/config/vms/$VM_ID" 404
fi

check "GET unknown VM → 404" GET /api/vmm/v4.0/ahv/config/vms/00000000-dead-beef-0000-000000000000 404
check "GET unknown task → 404" GET /api/prism/v4.0/config/tasks/00000000-dead-beef-0000-000000000000 404

# ── 4. Networking resources ──────────────────────────────────────────────────
hdr "4. Networking (subnet / VPC / floating IP / NSP)"

RESP=$(curl -sk -X POST "$BASE/api/networking/v4.0/config/subnets" -H 'Content-Type: application/json' \
  -d '{"name":"curl-test-subnet","subnetType":"VLAN"}')
STASK=$(echo "$RESP" | jget data.extId)
[[ -n "$STASK" ]] && green "create subnet accepted" || red "create subnet: $RESP"
SUBNET_ID=$(curl -sk "$BASE/api/prism/v4.0/config/tasks/$STASK" | jget data.entitiesAffected.0.extId)
[[ -n "$SUBNET_ID" ]] && green "subnet extId from task" || red "subnet extId missing"
check "List subnets after create" GET /api/networking/v4.0/config/subnets 200

RESP=$(curl -sk -X POST "$BASE/api/networking/v4.0/config/vpcs" -H 'Content-Type: application/json' \
  -d '{"name":"curl-test-vpc"}')
VTASK=$(echo "$RESP" | jget data.extId)
VPC_ID=$(curl -sk "$BASE/api/prism/v4.0/config/tasks/$VTASK" | jget data.entitiesAffected.0.extId)
[[ -n "$VPC_ID" ]] && green "create VPC accepted ($VPC_ID)" || red "create VPC failed"
check "List VPCs" GET /api/networking/v4.0/config/vpcs 200
check "Delete VPC" DELETE "/api/networking/v4.0/config/vpcs/$VPC_ID" 202

RESP=$(curl -sk -X POST "$BASE/api/networking/v4.0/config/floating-ips" -H 'Content-Type: application/json' \
  -d '{"name":"curl-test-fip"}')
FTASK=$(echo "$RESP" | jget data.extId)
FIP_ID=$(curl -sk "$BASE/api/prism/v4.0/config/tasks/$FTASK" | jget data.entitiesAffected.0.extId)
[[ -n "$FIP_ID" ]] && green "create floating IP accepted ($FIP_ID)" || red "create floating IP failed"
check "List floating IPs" GET /api/networking/v4.0/config/floating-ips 200
check "Delete floating IP" DELETE "/api/networking/v4.0/config/floating-ips/$FIP_ID" 202

RESP=$(curl -sk -X POST "$BASE/api/networking/v4.0/config/network-security-policies" -H 'Content-Type: application/json' \
  -d '{"name":"curl-test-nsp"}')
NTASK=$(echo "$RESP" | jget data.extId)
NSP_ID=$(curl -sk "$BASE/api/prism/v4.0/config/tasks/$NTASK" | jget data.entitiesAffected.0.extId)
[[ -n "$NSP_ID" ]] && green "create NSP accepted ($NSP_ID)" || red "create NSP failed"
check "List NSPs" GET /api/networking/v4.0/config/network-security-policies 200
check "Delete NSP" DELETE "/api/networking/v4.0/config/network-security-policies/$NSP_ID" 202

# Clean up the subnet created above
check "Delete subnet" DELETE "/api/networking/v4.0/config/subnets/$SUBNET_ID" 202

# ── 5. Volume groups + recovery points ───────────────────────────────────────
hdr "5. Volume groups / recovery points"

RESP=$(curl -sk -X POST "$BASE/api/volumes/v4.0/config/volume-groups" -H 'Content-Type: application/json' \
  -d '{"name":"curl-test-vg","disks":[{"diskSizeBytes":10737418240}]}')
GTASK=$(echo "$RESP" | jget data.extId)
VG_ID=$(curl -sk "$BASE/api/prism/v4.0/config/tasks/$GTASK" | jget data.entitiesAffected.0.extId)
[[ -n "$VG_ID" ]] && green "create volume group accepted ($VG_ID)" || red "create VG failed"
check "List volume groups" GET /api/volumes/v4.0/config/volume-groups 200
check "List VG disks" GET "/api/volumes/v4.0/config/volume-groups/$VG_ID/disks" 200

RESP=$(curl -sk -X POST "$BASE/api/dataprotection/v4.0/config/recovery-points" -H 'Content-Type: application/json' \
  -d "{\"name\":\"curl-test-rp\",\"volumeGroupRecoveryPoints\":[{\"volumeGroupExtId\":\"$VG_ID\"}]}")
RTASK=$(echo "$RESP" | jget data.extId)
RP_ID=$(curl -sk "$BASE/api/prism/v4.0/config/tasks/$RTASK" | jget data.entitiesAffected.0.extId)
[[ -n "$RP_ID" ]] && green "create recovery point accepted ($RP_ID)" || red "create RP failed"
RF=$(curl -sk --get --data-urlencode "\$filter=volumeGroupExtId eq '$VG_ID'" "$BASE/api/dataprotection/v4.0/config/recovery-points" | jget metadata.totalAvailableResults)
[[ "$RF" -ge 1 ]] && green "RP \$filter by volumeGroupExtId works" || red "RP \$filter returned $RF"
check "Delete recovery point" DELETE "/api/dataprotection/v4.0/config/recovery-points/$RP_ID" 202
check "Delete volume group" DELETE "/api/volumes/v4.0/config/volume-groups/$VG_ID" 202

# ── 6. Prism proxy passthrough ───────────────────────────────────────────────
hdr "6. Proxy to Prism (spec-covered, not emulated)"
check "GET /api/iam/v4.0/authz/roles via proxy" GET /api/iam/v4.0/authz/roles 200

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
printf "  Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
echo "════════════════════════════════════════════════════════"
exit "$FAIL"
