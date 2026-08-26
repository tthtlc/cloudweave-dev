#!/usr/bin/env bash
# =============================================================================
# sweep_write.sh — READ/WRITE sweep of the Nutanix v4 collection endpoints.
#
# The mutating counterpart of ./sweep_read.sh: same eight endpoints, same two
# auth input modes, same verbose/non-verbose output, same v4.0 → v4.3 version
# loop — but it walks a full create → task → get → update → delete lifecycle on
# each collection and verifies the resulting state.
#
#   vms             /api/vmm/${api_version}/ahv/config/vms
#   subnets         /api/networking/${api_version}/config/subnets
#   tasks           /api/prism/${api_version}/config/tasks
#   securitygroups  /api/microseg/${api_version}/config/policies
#   vpcs            /api/networking/${api_version}/config/vpcs
#   floatingips     /api/networking/${api_version}/config/floating-ips
#   volumegroups    /api/volumes/${api_version}/config/volume-groups
#   recoverypoints  /api/dataprotection/${api_version}/config/recovery-points
#
# ⚠  THIS MUTATES THE TARGET PRISM CENTRAL. Everything it creates is named
#    "sweep-<kind>-<version>-<pid>" and deleted again at the end of its section;
#    anything still outstanding is deleted on exit, including after Ctrl-C.
#    Use --dry-run to print the exact curl commands without sending them.
#
# Mutating requests carry the headers a real Prism Central requires: a fresh
# NTNX-Request-Id per call, and If-Match with the entity's ETag on PUT/DELETE.
#
# The request payloads are deliberately minimal and are the part most likely to
# need adapting to your cluster (required fields differ between environments).
# Each one can be replaced wholesale from the environment — see the *_BODY
# variables in the configuration block below.
#
# Two auth input modes:
#   auth=basic   USERNAME/PASSWORD are turned into a Basic header that is sent
#                on ALL URLs.
#   auth=cookie  USERNAME/PASSWORD are turned into a Basic header used only for
#                the first authentication; the session cookie it returns is
#                then reused as the header for every URL, and the Basic header
#                is never sent again.
#
# Two output modes:
#   verbose      full request and response headers + bodies for every call
#   non-verbose  the URL and the HTTP response only  (default)
#
# Usage:
#   ./sweep_write.sh auth=cookie --dry-run
#   ./sweep_write.sh auth=cookie api_version=v4.2
#   ./sweep_write.sh auth=basic verbose=1 --ip 166.6.100.1 --port 9440
#
# Exit code: number of failed checks (0 = all passed).
# =============================================================================

# ─── Configuration ───────────────────────────────────────────────────────────
# Override any of these on the command line or from the environment.
NUTANIX_HOST="${NUTANIX_HOST:-166.6.100.1}"
NUTANIX_PORT="${NUTANIX_PORT:-9440}"
api_version="${api_version:-}"        # empty = sweep every version, v4.0 → v4.3

USERNAME="${USERNAME:-admin}"
PASSWORD="${PASSWORD:-}"

auth="${auth:-cookie}"                # cookie | basic
verbose="${verbose:-0}"               # 1 = full headers + bodies

# Environment-specific knobs for the create payloads.
SWEEP_VLAN_ID="${SWEEP_VLAN_ID:-101}"                 # VLAN for the test subnet
SWEEP_VM_MEMORY="${SWEEP_VM_MEMORY:-4294967296}"      # 4 GiB
SWEEP_VG_DISK_BYTES="${SWEEP_VG_DISK_BYTES:-10737418240}"  # 10 GiB
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  awk 'NR==1 {next} { if (substr($0,1,1)=="#") { sub(/^# ?/, ""); print } else exit }' "$0"
}

SCRIPT_TITLE="Nutanix v4 READ/WRITE sweep"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sweep_lib.sh"

RUN_TAG="$$"

# ─── Cleanup of anything left behind ─────────────────────────────────────────
# Every created resource is tracked until its own delete succeeds, so an
# interrupted run does not orphan objects on a live cluster.
CREATED=()
CLEANUP_DONE=0

track()   { CREATED+=("$1|$2|$3"); }
untrack() {
  local id="$1" e out=()
  ((${#CREATED[@]})) || return 0
  for e in "${CREATED[@]}"; do
    [[ "$e" == *"|${id}" ]] && continue
    out+=("$e")
  done
  CREATED=()
  ((${#out[@]})) && CREATED=("${out[@]}")
  return 0
}

sweep_cleanup() {
  [[ "$CLEANUP_DONE" == "1" ]] && return 0
  CLEANUP_DONE=1
  is_dry_run && return 0
  ((${#CREATED[@]})) || return 0
  printf '\n\033[33m! %d resource(s) still outstanding — deleting them\033[0m\n' "${#CREATED[@]}" >&2
  local entry label base id
  for entry in "${CREATED[@]}"; do
    IFS='|' read -r label base id <<<"$entry"
    [[ -n "$id" ]] || continue
    printf '\033[2m  DELETE %s %s\033[0m\n' "$label" "${base}/${id}" >&2
    req DELETE "${base}/${id}" -H "NTNX-Request-Id: $(new_uuid)" --no-trace
  done
  return 0
}

trap 'sweep_cleanup; rm -rf "$TMP"' EXIT
trap 'exit 130' INT TERM

# ─── Mutating-request helpers ────────────────────────────────────────────────
IF_MATCH=""

# fetch_etag URL — GET the entity and remember its ETag for the next mutate.
fetch_etag() {
  IF_MATCH=""
  req GET "$1"
  [[ "$RESP_CODE" == "200" ]] && IF_MATCH="$RESP_ETAG"
  return 0
}

# mutate METHOD URL [BODY] [EXTRA...] — POST/PUT/DELETE with the headers a real
# Prism Central requires. Consumes IF_MATCH if fetch_etag set one.
mutate() {
  local method="$1" url="$2" body=""
  shift 2
  if [[ $# -gt 0 && "${1:-}" != -* ]]; then body="$1"; shift; fi
  local h=( -H "NTNX-Request-Id: $(new_uuid)" )
  [[ -n "$IF_MATCH" ]] && h+=( -H "If-Match: ${IF_MATCH}" )
  IF_MATCH=""
  req "$method" "$url" "$body" "${h[@]}" "$@"
}

# task_verdict LABEL TASK_ID — poll the task and report; sets TASK_ENTITY.
task_verdict() {
  local label="$1" tid="$2"
  if is_dry_run; then TASK_ENTITY="DRY-RUN-ENTITY-EXTID"; return 0; fi
  if [[ -z "$tid" ]]; then
    red "$(printf '%-16s POST returned no task extId' "$label")"
    return 1
  fi
  if poll_task "$tid"; then
    green "$(printf '%-16s task → SUCCEEDED%s' "$label" "${TASK_ENTITY:+ (extId ${TASK_ENTITY})}")"
    return 0
  fi
  red "$(printf '%-16s task → %s' "$label" "${TASK_STATUS:-timed out}")"
  return 1
}

# create_resource LABEL URL BODY → sets NEW_ID (and tracks it for cleanup).
create_resource() {
  local label="$1" url="$2" body="$3"
  NEW_ID=""
  mutate POST "$url" "$body"
  report "create ${label}" 202
  local tid; tid="$(printf '%s' "$RESP_BODY" | jget data.extId)"
  task_verdict "$label" "$tid" || return 1
  NEW_ID="$TASK_ENTITY"
  [[ -n "$NEW_ID" ]] || return 1
  track "$label" "$url" "$NEW_ID"
  return 0
}

# delete_resource LABEL URL ID — ETag-aware delete, then stop tracking it.
delete_resource() {
  local label="$1" url="$2" id="$3"
  if [[ -z "$id" ]]; then
    dim "    no ${label} extId — nothing to delete"
    return 1
  fi
  fetch_etag "${url}/${id}"
  mutate DELETE "${url}/${id}"
  report "delete ${label}" 202
  local tid; tid="$(printf '%s' "$RESP_BODY" | jget data.extId)"
  task_verdict "delete ${label}" "$tid" || { untrack "$id"; return 1; }
  untrack "$id"
  return 0
}

# ─── Seed discovery ──────────────────────────────────────────────────────────
# A VM needs a cluster and a subnet to attach to. Both are read off the subnets
# collection, so this stays within the endpoint set under test.
SEED_SUBNET=""
SEED_CLUSTER=""
resolve_seeds() {
  SEED_SUBNET=""; SEED_CLUSTER=""
  req GET "$subnets"
  if is_dry_run; then
    SEED_SUBNET="DRY-RUN-SUBNET-EXTID"; SEED_CLUSTER="DRY-RUN-CLUSTER-EXTID"; return 0
  fi
  [[ "$RESP_CODE" == "200" ]] || { warn "cannot list subnets (HTTP ${RESP_CODE}) — creating without cluster/NIC"; return 1; }
  SEED_SUBNET="$(printf '%s' "$RESP_BODY" | jget data.0.extId)"
  SEED_CLUSTER="$(printf '%s' "$RESP_BODY" | jget data.0.clusterReference)"
  dim "    seed subnet: ${SEED_SUBNET:-<none>}   seed cluster: ${SEED_CLUSTER:-<none>}"
  return 0
}

# ─── Payload builders ────────────────────────────────────────────────────────
# v4 field names (camelCase). Replace any of these wholesale by exporting the
# matching *_BODY variable before running.
vm_body() {
  local name="$1" extra=""
  [[ -n "$SEED_CLUSTER" ]] && extra+=",\"cluster\":{\"extId\":\"${SEED_CLUSTER}\"}"
  [[ -n "$SEED_SUBNET"  ]] && extra+=",\"nics\":[{\"networkInfo\":{\"subnet\":{\"extId\":\"${SEED_SUBNET}\"}}}]"
  printf '{"name":"%s","description":"created by sweep_write.sh","numSockets":2,"numCoresPerSocket":2,"memorySizeBytes":%s%s}' \
    "$name" "$SWEEP_VM_MEMORY" "$extra"
}

subnet_body() {
  local name="$1" extra=""
  [[ -n "$SEED_CLUSTER" ]] && extra=",\"clusterReference\":\"${SEED_CLUSTER}\""
  printf '{"name":"%s","subnetType":"VLAN","networkId":%s%s}' "$name" "$SWEEP_VLAN_ID" "$extra"
}

vpc_body()    { printf '{"name":"%s","vpcType":"REGULAR"}' "$1"; }

fip_body() {
  local name="$1" extra=""
  [[ -n "$SEED_SUBNET" ]] && extra=",\"externalSubnetReference\":\"${SEED_SUBNET}\""
  printf '{"name":"%s"%s}' "$name" "$extra"
}

nsp_body()    { printf '{"name":"%s","type":"ISOLATION","state":"MONITOR"}' "$1"; }

vg_body() {
  local name="$1" extra=""
  [[ -n "$SEED_CLUSTER" ]] && extra=",\"clusterReference\":\"${SEED_CLUSTER}\""
  printf '{"name":"%s","description":"created by sweep_write.sh"%s}' "$name" "$extra"
}

rp_body()     { printf '{"name":"%s","volumeGroupRecoveryPoints":[{"volumeGroupExtId":"%s"}]}' "$1" "$2"; }

# ─── Main ────────────────────────────────────────────────────────────────────
banner
printf '\033[33m⚠  MUTATING operations against %s — review before running.\033[0m\n' "${NUTANIX_HOST}:${NUTANIX_PORT}"

# One login for the whole run: in auth=cookie the cookie minted here is reused
# across every version below; in auth=basic this only verifies the credentials.
authenticate || exit 1

for v in "${VERSIONS[@]}"; do
  build_urls "$v"
  TAG="${v//./}-${RUN_TAG}"

  hdr "api_version=${v} — read/write sweep (auth in force: ${AUTH_MODE})"
  resolve_seeds

  # ── vms: create → task → get → update → power-off → $filter → delete ──────
  hdr "${v} · vms"
  VM_NAME="sweep-vm-${TAG}"
  VM_ID=""
  if create_resource "vm" "$vms" "$(vm_body "$VM_NAME")"; then
    VM_ID="$NEW_ID"

    req GET "${vms}/${VM_ID}"
    report "get vm" 200
    if ! is_dry_run; then
      NAME="$(printf '%s' "$RESP_BODY" | jget data.name)"
      [[ "$NAME" == "$VM_NAME" ]] && green "vm name round-trips ('${NAME}')" \
                                  || red "vm name is '${NAME}', expected '${VM_NAME}'"
    fi

    fetch_etag "${vms}/${VM_ID}"
    mutate PUT "${vms}/${VM_ID}" "{\"name\":\"${VM_NAME}-v2\",\"numSockets\":4}"
    report "update vm" 202
    task_verdict "update vm" "$(printf '%s' "$RESP_BODY" | jget data.extId)"

    req GET "${vms}/${VM_ID}"
    if ! is_dry_run; then
      NAME="$(printf '%s' "$RESP_BODY" | jget data.name)"
      [[ "$NAME" == "${VM_NAME}-v2" ]] && green "update persisted ('${NAME}')" \
                                       || red "update did not persist (name '${NAME}')"
    fi

    fetch_etag "${vms}/${VM_ID}"
    mutate POST "${vms}/${VM_ID}/"'$actions/power-off' '{}'
    report "power-off vm" 202
    task_verdict "power-off vm" "$(printf '%s' "$RESP_BODY" | jget data.extId)"

    req GET "${vms}/${VM_ID}"
    if ! is_dry_run; then
      PS="$(printf '%s' "$RESP_BODY" | jget data.powerState)"
      [[ "$PS" == "OFF" ]] && green "power state is OFF" || red "power state is '${PS}', expected OFF"
    fi

    req GET "$vms" "" --get --data-urlencode "\$filter=name eq '${VM_NAME}-v2'"
    if ! is_dry_run; then
      F="$(printf '%s' "$RESP_BODY" | jget metadata.totalAvailableResults)"
      [[ "$F" == "1" ]] && green "\$filter by name found the vm" \
                        || red "\$filter by name returned '${F}', expected 1"
    fi

    delete_resource "vm" "$vms" "$VM_ID"
    check "get deleted vm" GET "${vms}/${VM_ID}" 404
  fi

  # ── subnets ───────────────────────────────────────────────────────────────
  hdr "${v} · subnets"
  if create_resource "subnet" "$subnets" "$(subnet_body "sweep-subnet-${TAG}")"; then
    SUBNET_ID="$NEW_ID"
    check "list subnets" GET "$subnets" 200
    check "get subnet"   GET "${subnets}/${SUBNET_ID}" 200
    delete_resource "subnet" "$subnets" "$SUBNET_ID"
  fi

  # ── vpcs ──────────────────────────────────────────────────────────────────
  hdr "${v} · vpcs"
  if create_resource "vpc" "$vpcs" "$(vpc_body "sweep-vpc-${TAG}")"; then
    VPC_ID="$NEW_ID"
    check "list vpcs" GET "$vpcs" 200
    delete_resource "vpc" "$vpcs" "$VPC_ID"
  fi

  # ── floatingips ───────────────────────────────────────────────────────────
  hdr "${v} · floatingips"
  if create_resource "floatingip" "$floatingips" "$(fip_body "sweep-fip-${TAG}")"; then
    FIP_ID="$NEW_ID"
    check "list floatingips" GET "$floatingips" 200
    delete_resource "floatingip" "$floatingips" "$FIP_ID"
  fi

  # ── securitygroups ────────────────────────────────────────────────────────
  hdr "${v} · securitygroups"
  if create_resource "securitygroup" "$securitygroups" "$(nsp_body "sweep-nsp-${TAG}")"; then
    NSP_ID="$NEW_ID"
    check "list securitygroups" GET "$securitygroups" 200
    delete_resource "securitygroup" "$securitygroups" "$NSP_ID"
  fi

  # ── volumegroups + recoverypoints ─────────────────────────────────────────
  hdr "${v} · volumegroups / recoverypoints"
  if create_resource "volumegroup" "$volumegroups" "$(vg_body "sweep-vg-${TAG}")"; then
    VG_ID="$NEW_ID"
    check "list volumegroups" GET "$volumegroups" 200
    check "list vg disks"     GET "${volumegroups}/${VG_ID}/disks" 200

    if create_resource "recoverypoint" "$recoverypoints" "$(rp_body "sweep-rp-${TAG}" "$VG_ID")"; then
      RP_ID="$NEW_ID"
      req GET "$recoverypoints" "" --get --data-urlencode "\$filter=volumeGroupExtId eq '${VG_ID}'"
      if ! is_dry_run; then
        RF="$(printf '%s' "$RESP_BODY" | jget metadata.totalAvailableResults)"
        [[ "${RF:-0}" -ge 1 ]] && green "\$filter by volumeGroupExtId found the recovery point" \
                               || red "\$filter by volumeGroupExtId returned '${RF}'"
      fi
      delete_resource "recoverypoint" "$recoverypoints" "$RP_ID"
    fi
    delete_resource "volumegroup" "$volumegroups" "$VG_ID"
  fi

  # ── tasks ─────────────────────────────────────────────────────────────────
  hdr "${v} · tasks"
  get_list "tasks" "$tasks"
done

summary
