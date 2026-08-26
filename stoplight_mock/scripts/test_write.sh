#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# WRITE test suite — create / update / delete (mutating operations) only.
#
# Exercises the stateful emulator's mutation paths (VM, subnet, VPC, floating
# IP, NSP, volume group, recovery point) plus Prism's mutating-request
# validation, then verifies the resulting state (including task polling and
# post-delete 404s). The read-only GET/enumeration checks live in test_read.sh.
#
# Usage:
#   ./scripts/test_write.sh                          # v4.0, quiet
#   ./scripts/test_write.sh -v                       # v4.0, verbose
#   ./scripts/test_write.sh --version v4.3 --verbose
#   ./scripts/test_write.sh -V 4.1
#
# Versions map to ports (see docker-compose.yml):
#   v4.0 → Prism :4010  Emulator :9440   …   v4.3 → Prism :4013  Emulator :9443
#
# Target: --target auto|real|mock (default auto). auto targets the REAL Prism
# Central when NUTANIX_HOST is set in my.env (fallback .env); in that mode this
# script exits without issuing any mutating request (real-host mode is
# read-only).
#
# Exit code: number of failed checks (0 = all passed).
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  awk 'NR==1 {next} { if (substr($0,1,1)=="#") { sub(/^# ?/, ""); print } else exit }' "$0"
}

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

banner "WRITE"

# Full Nutanix v4 endpoints this suite exercises (emulator base URL + path).
print_endpoints vms subnets vpcs floating-ips security-groups volume-groups recovery-points tasks

# ─── 0. Real-host guard ───────────────────────────────────────────────────────
# Real-host mode is read-only by design: never issue create/update/delete
# against a live cluster. When auto-detection (or --target real) is active,
# bail out before any mutating request.
if [[ "$TARGET" == "real" ]]; then
  dim "real-host mode is read-only (${NUTANIX_HOST}:${NUTANIX_PORT}) — skipping the mutating write suite."
  echo ""
  exit 0
fi

# ─── 1. Prism — mutating-request validation ──────────────────────────────────
hdr "1. Prism — mutation request validation (POST)"
check "Create VM missing NTNX-Request-Id → 422" \
       POST "$PRISM$VM_LIST" 422 '{"name":"probe-vm"}'
check "Create VM with NTNX-Request-Id → 202" \
       POST "$PRISM$VM_LIST" 202 '{"name":"probe-vm"}' -H "NTNX-Request-Id: $REQ_ID"

# ─── 2. Emulator — VM lifecycle ──────────────────────────────────────────────
hdr "2. VM lifecycle (create → task → get → update → power → filter → delete)"
VM_BODY='{
  "name": "test-vm",
  "description": "created by test_write.sh",
  "num_sockets": 2,
  "num_cores_per_socket": 2,
  "memory_size_bytes": 4294967296,
  "nics": [{ "subnet": { "ext_id": "'$SEED_SUBNET'" } }]
}'

req POST "$EMU$VM_LIST" "$VM_BODY"
TASK_ID="$(echo "$RESP_BODY" | jget data.extId)"
[[ -n "$TASK_ID" ]] && green "POST create VM accepted (task $TASK_ID)" || red "POST create VM: no task id"

VM_ID=""
if [[ -n "$TASK_ID" ]]; then
  if poll_task "$TASK_ID"; then
    green "create task SUCCEEDED"
    VM_ID="$(echo "$RESP_BODY" | jget data.entitiesAffected.0.extId)"
  else
    red "create task did not reach SUCCEEDED (last: $TASK_STATUS)"
  fi
fi

if [[ -n "$VM_ID" ]]; then
  req GET "$EMU$VM_LIST/$VM_ID"
  NAME="$(echo "$RESP_BODY" | jget data.name)"
  [[ "$NAME" == "test-vm" ]] && green "GET VM name ok" || red "GET VM name: '$NAME'"

  # Update
  req PUT "$EMU$VM_LIST/$VM_ID" '{"name":"test-vm-v2","numSockets":4}'
  UTASK="$(echo "$RESP_BODY" | jget data.extId)"
  if [[ -n "$UTASK" ]] && poll_task "$UTASK"; then
    green "PUT update task SUCCEEDED"
  else
    red "PUT update failed"
  fi
  req GET "$EMU$VM_LIST/$VM_ID"
  NAME="$(echo "$RESP_BODY" | jget data.name)"
  [[ "$NAME" == "test-vm-v2" ]] && green "updated name persisted" || red "updated name: '$NAME'"

  # Power action ($actions URL)
  req POST "$EMU$VM_LIST/$VM_ID/\$actions/power-off" '{}'
  PTASK="$(echo "$RESP_BODY" | jget data.extId)"
  [[ -n "$PTASK" ]] && green "power-off accepted (task $PTASK)" || red "power-off: no task"
  sleep 1
  req GET "$EMU$VM_LIST/$VM_ID"
  PS="$(echo "$RESP_BODY" | jget data.powerState)"
  [[ "$PS" == "OFF" ]] && green "power state is OFF" || red "power state: '$PS' (expected OFF)"

  # List + $filter
  check "List VMs" GET "$EMU$VM_LIST" 200
  req GET "$EMU$VM_LIST" "" --get --data-urlencode "\$filter=name eq 'test-vm-v2'"
  F="$(echo "$RESP_BODY" | jget metadata.totalAvailableResults)"
  [[ "$F" == "1" ]] && green "\$filter by name works" || red "\$filter returned $F (expected 1)"

  # Delete
  req DELETE "$EMU$VM_LIST/$VM_ID"
  DTASK="$(echo "$RESP_BODY" | jget data.extId)"
  if [[ -n "$DTASK" ]] && poll_task "$DTASK"; then
    green "DELETE task SUCCEEDED"
  else
    red "DELETE failed"
  fi
  check "GET deleted VM → 404" GET "$EMU$VM_LIST/$VM_ID" 404
fi

# ─── 3. Emulator — networking resources ──────────────────────────────────────
hdr "3. Networking (subnet / VPC / floating IP / NSP)"

req POST "$EMU$SUBNETS" '{"name":"test-subnet","subnetType":"VLAN"}'
STASK="$(echo "$RESP_BODY" | jget data.extId)"
[[ -n "$STASK" ]] && green "create subnet accepted" || red "create subnet failed"
req GET "$EMU$TASKS/$STASK"
SUBNET_ID="$(echo "$RESP_BODY" | jget data.entitiesAffected.0.extId)"
[[ -n "$SUBNET_ID" ]] && green "subnet extId from task" || red "subnet extId missing"
check "List subnets after create" GET "$EMU$SUBNETS" 200

req POST "$EMU$VPCS" '{"name":"test-vpc"}'
VTASK="$(echo "$RESP_BODY" | jget data.extId)"
req GET "$EMU$TASKS/$VTASK"
VPC_ID="$(echo "$RESP_BODY" | jget data.entitiesAffected.0.extId)"
[[ -n "$VPC_ID" ]] && green "create VPC accepted ($VPC_ID)" || red "create VPC failed"
check "List VPCs" GET "$EMU$VPCS" 200
check "Delete VPC" DELETE "$EMU$VPCS/$VPC_ID" 202

req POST "$EMU$FIPS" '{"name":"test-fip"}'
FTASK="$(echo "$RESP_BODY" | jget data.extId)"
req GET "$EMU$TASKS/$FTASK"
FIP_ID="$(echo "$RESP_BODY" | jget data.entitiesAffected.0.extId)"
[[ -n "$FIP_ID" ]] && green "create floating IP accepted ($FIP_ID)" || red "create floating IP failed"
check "List floating IPs" GET "$EMU$FIPS" 200
check "Delete floating IP" DELETE "$EMU$FIPS/$FIP_ID" 202

req POST "$EMU$NSPS" '{"name":"test-nsp"}'
NTASK="$(echo "$RESP_BODY" | jget data.extId)"
req GET "$EMU$TASKS/$NTASK"
NSP_ID="$(echo "$RESP_BODY" | jget data.entitiesAffected.0.extId)"
[[ -n "$NSP_ID" ]] && green "create NSP accepted ($NSP_ID)" || red "create NSP failed"
check "List NSPs" GET "$EMU$NSPS" 200
check "Delete NSP" DELETE "$EMU$NSPS/$NSP_ID" 202

check "Delete subnet" DELETE "$EMU$SUBNETS/$SUBNET_ID" 202

# ─── 4. Emulator — volume groups & recovery points ───────────────────────────
hdr "4. Volume groups / recovery points"

req POST "$EMU$VGS" '{"name":"test-vg","disks":[{"diskSizeBytes":10737418240}]}'
GTASK="$(echo "$RESP_BODY" | jget data.extId)"
req GET "$EMU$TASKS/$GTASK"
VG_ID="$(echo "$RESP_BODY" | jget data.entitiesAffected.0.extId)"
[[ -n "$VG_ID" ]] && green "create volume group accepted ($VG_ID)" || red "create VG failed"
check "List volume groups" GET "$EMU$VGS" 200
check "List VG disks" GET "$EMU$VGS/$VG_ID/disks" 200

req POST "$EMU$RPS" "{\"name\":\"test-rp\",\"volumeGroupRecoveryPoints\":[{\"volumeGroupExtId\":\"$VG_ID\"}]}"
RTASK="$(echo "$RESP_BODY" | jget data.extId)"
req GET "$EMU$TASKS/$RTASK"
RP_ID="$(echo "$RESP_BODY" | jget data.entitiesAffected.0.extId)"
[[ -n "$RP_ID" ]] && green "create recovery point accepted ($RP_ID)" || red "create RP failed"
req GET "$EMU$RPS" "" --get --data-urlencode "\$filter=volumeGroupExtId eq '$VG_ID'"
RF="$(echo "$RESP_BODY" | jget metadata.totalAvailableResults)"
[[ "$RF" -ge 1 ]] && green "RP \$filter by volumeGroupExtId works" || red "RP \$filter returned $RF"
check "Delete recovery point" DELETE "$EMU$RPS/$RP_ID" 202
check "Delete volume group" DELETE "$EMU$VGS/$VG_ID" 202

summary
