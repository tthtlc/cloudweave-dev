#!/usr/bin/env bash
# ─── Nutanix Emulator Smoke Test ──────────────────────────────────────────────
# Verifies the emulator shim is running and correctly handling VM CRUD + tasks.
#
# Usage:
#   chmod +x scripts/smoke-test.sh
#   ./scripts/smoke-test.sh [emulator_url]
#
# Default URL: https://localhost:9440 (self-signed cert, use -k)

set -euo pipefail

EMULATOR="${1:-https://localhost:9440}"
CURL_OPTS="-k"  # --insecure: accept self-signed TLS cert
PASS=0
FAIL=0

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*"; ((FAIL++)); }
header() { printf '\n\033[1;36m── %s ──\033[0m\n' "$*"; }

check() {
  local desc="$1" method="$2" url="$3" expected_code="$4" body="${5:-}"
  local opts=(-sk -o /dev/null -w '%{http_code}')
  green "url: $url"
  if [[ -n "$body" ]]; then
    opts+=(-d "$body" -H 'Content-Type: application/json')
  fi
  local code
  code=$(curl "${opts[@]}" -X "$method" "$url" 2>&1) || true
  if [[ "$code" == "$expected_code" ]]; then
    green "$desc (HTTP $code)"
  else
    red "$desc — expected $expected_code, got $code"
  fi
}

check_json() {
  local desc="$1" method="$2" url="$3" expected_code="$4" body="${5:-}"
  local opts=(-s -H 'Accept: application/json')
  if [[ -n "$body" ]]; then
    opts+=(-d "$body" -H 'Content-Type: application/json')
  fi
  local resp
  resp=$(curl "${opts[@]}" -X "$method" "$url" 2>&1) || true
  local code
  code=$(echo "$resp" | tail -1)  # curl -w would be better but keep it simple
  # Actually letʼs do both code and body
  local code
  code=$(curl -sk -o /tmp/smoke_resp.json -w '%{http_code}' -H 'Accept: application/json' \
    ${body:+-d "$body"} ${body:+-H 'Content-Type: application/json'} \
    -X "$method" "$url" 2>&1) || true

  if [[ "$code" == "$expected_code" ]]; then
    local preview
    preview=$(python3 -m json.tool /tmp/smoke_resp.json 2>/dev/null | head -20 || cat /tmp/smoke_resp.json | head -20)
    green "$desc (HTTP $code)"
    echo "    ${preview//$'\n'/$'\n    '}"
  else
    red "$desc — expected $expected_code, got $code"
    cat /tmp/smoke_resp.json 2>/dev/null || true
  fi
}

echo "╔══════════════════════════════════════════════════════╗"
echo "║   Nutanix Emulator Smoke Test                       ║"
echo "║   Target: $EMULATOR"
echo "╚══════════════════════════════════════════════════════╝"

# ── 1. Health check ──────────────────────────────────────────────────────────
header "1. Health check"
check "Health endpoint" GET "$EMULATOR/health" 200

# ── 2. Reference data ────────────────────────────────────────────────────────
header "2. Reference data (seed)"
check "List clusters" GET "$EMULATOR/api/cluster-mgmt/v4.0.a1/config/clusters" 200
check "List subnets"  GET "$EMULATOR/api/networking/v4.0.a1/config/subnets" 200
check "List images"   GET "$EMULATOR/api/vmm/v4.0.a1/config/images" 200

# ── 3. VM CRUD flow ──────────────────────────────────────────────────────────
header "3. VM lifecycle"

# 3a. Create VM
CREATE_BODY='{
  "name": "smoke-test-vm",
  "description": "Created by smoke test",
  "num_sockets": 2,
  "num_cores_per_socket": 2,
  "memory_size_bytes": 8589934592,
  "cluster": { "ext_id": "00000000-0000-0000-0000-000000000001" },
  "nics": [{ "subnet": { "ext_id": "00000000-0000-0000-0000-000000000002" } }],
  "disks": [{ "size_bytes": 10737418240, "disk_address": "SCSI", "device_index": 0 }],
  "boot_config": { "boot_type": "LEGACY" }
}'

echo "  Creating VM..."
CREATE_RESP=$(curl -sk -X POST "$EMULATOR/api/vmm/v4.0.a1/config/vms" \
  -H 'Content-Type: application/json' \
  -d "$CREATE_BODY")
echo "  Response: $(echo "$CREATE_RESP" | python3 -m json.tool 2>/dev/null || echo "$CREATE_RESP")"

TASK_ID=$(echo "$CREATE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['extId'])" 2>/dev/null || echo "")
if [[ -n "$TASK_ID" ]]; then
  green "VM create accepted, task: $TASK_ID"
else
  red "Failed to get task ID from create response"
fi

# 3b. Poll task until SUCCEEDED
if [[ -n "$TASK_ID" ]]; then
  echo "  Polling task $TASK_ID ..."
  for i in $(seq 1 10); do
    TASK_RESP=$(curl -sk "$EMULATOR/api/prism/v4.0.a1/config/tasks/$TASK_ID")
    TASK_STATUS=$(echo "$TASK_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['status'])" 2>/dev/null || echo "UNKNOWN")
    echo "    poll $i: $TASK_STATUS"
    if [[ "$TASK_STATUS" == "SUCCEEDED" ]]; then
      green "Task $TASK_ID completed successfully"
      VM_ID=$(echo "$TASK_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(d['entitiesAffected'][0]['extId'])" 2>/dev/null || echo "")
      echo "    VM extId: $VM_ID"
      break
    fi
    sleep 0.5
  done
fi

# 3c. GET the VM
if [[ -n "${VM_ID:-}" ]]; then
  echo "  Reading VM $VM_ID ..."
  GET_RESP=$(curl -sk "$EMULATOR/api/vmm/v4.0.a1/config/vms/$VM_ID")
  VM_NAME=$(echo "$GET_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['name'])" 2>/dev/null || echo "")
  if [[ "$VM_NAME" == "smoke-test-vm" ]]; then
    green "GET VM returned correct name: $VM_NAME"
  else
    red "GET VM name mismatch: expected smoke-test-vm, got $VM_NAME"
  fi

  # 3d. Update VM
  UPDATE_BODY='{"name": "smoke-test-vm-updated", "num_sockets": 4}'
  echo "  Updating VM $VM_ID ..."
  UPDATE_RESP=$(curl -sk -X PUT "$EMULATOR/api/vmm/v4.0.a1/config/vms/$VM_ID" \
    -H 'Content-Type: application/json' \
    -d "$UPDATE_BODY")
  UPDATE_TASK_ID=$(echo "$UPDATE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['extId'])" 2>/dev/null || echo "")

  if [[ -n "$UPDATE_TASK_ID" ]]; then
    # Wait for update task
    for i in $(seq 1 10); do
      UTASK_RESP=$(curl -sk "$EMULATOR/api/prism/v4.0.a1/config/tasks/$UPDATE_TASK_ID")
      UTASK_STATUS=$(echo "$UTASK_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['status'])" 2>/dev/null || echo "UNKNOWN")
      if [[ "$UTASK_STATUS" == "SUCCEEDED" ]]; then
        green "Update task $UPDATE_TASK_ID completed"
        break
      fi
      sleep 0.5
    done

    # Verify update
    GET_RESP2=$(curl -sk "$EMULATOR/api/vmm/v4.0.a1/config/vms/$VM_ID")
    UPDATED_NAME=$(echo "$GET_RESP2" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['name'])" 2>/dev/null || echo "")
    UPDATED_SOCKETS=$(echo "$GET_RESP2" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['numSockets'])" 2>/dev/null || echo "")
    if [[ "$UPDATED_NAME" == "smoke-test-vm-updated" ]]; then
      green "VM name updated successfully: $UPDATED_NAME"
    else
      red "VM name update failed: $UPDATED_NAME"
    fi
    if [[ "$UPDATED_SOCKETS" == "4" ]]; then
      green "VM sockets updated successfully: $UPDATED_SOCKETS"
    else
      red "VM sockets update failed: $UPDATED_SOCKETS"
    fi
  fi

  # 3e. List VMs
  echo "  Listing VMs..."
  LIST_RESP=$(curl -sk "$EMULATOR/api/vmm/v4.0.a1/config/vms")
  LIST_COUNT=$(echo "$LIST_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['totalAvailableResults'])" 2>/dev/null || echo "0")
  green "List VMs returned $LIST_COUNT VM(s)"

  # 3f. Delete VM
  echo "  Deleting VM $VM_ID ..."
  DELETE_RESP=$(curl -sk -X DELETE "$EMULATOR/api/vmm/v4.0.a1/config/vms/$VM_ID")
  DELETE_TASK_ID=$(echo "$DELETE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['extId'])" 2>/dev/null || echo "")

  if [[ -n "$DELETE_TASK_ID" ]]; then
    for i in $(seq 1 10); do
      DTASK_RESP=$(curl -sk "$EMULATOR/api/prism/v4.0.a1/config/tasks/$DELETE_TASK_ID")
      DTASK_STATUS=$(echo "$DTASK_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['status'])" 2>/dev/null || echo "UNKNOWN")
      if [[ "$DTASK_STATUS" == "SUCCEEDED" ]]; then
        green "Delete task $DELETE_TASK_ID completed"
        break
      fi
      sleep 0.5
    done
  fi

  # Verify deletion
  check "GET deleted VM returns 404" GET "$EMULATOR/api/vmm/v4.0.a1/config/vms/$VM_ID" 404
fi

# ── 4. Path variant test ─────────────────────────────────────────────────────
header "4. Path variant (v4.0 without .a1 suffix)"
check "List VMs via v4.0 path" GET "$EMULATOR/api/vmm/v4.0/config/vms" 200

# ── 5. Summary ───────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
printf "  Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" $PASS $FAIL
echo "════════════════════════════════════════════════════════"

exit $FAIL
