#!/usr/bin/env bash
# =============================================================================
# expt_write.sh — Prism Central mutating sweep, authenticated via Nutanix IAM.
#
# Same IAM conversion as expt_read.sh: takes Prism Central IP + port + API
# version + username + password, converts them into an IAM programmatic
# credential (passwd2iam_convert.md) and an NTNX_IGW_SESSION session cookie,
# then passes that cookie (fallback: Basic auth) into the mutating requests —
# the same set of create/update/delete operations exercised by
# ../scripts/test_write.sh (VM lifecycle, networking, volume groups/recovery
# points).
#
# ⚠  THIS MUTATES THE TARGET PRISM CENTRAL.  Review before running against a
#    live cluster.  Payload bodies mirror ../scripts/test_write.sh verbatim;
#    adapt field names / required fields to your real v4 environment as needed.
#    Use --dry-run (or CURL_DRY_RUN=1) to preview the exact curl commands.
#
# Usage:
#   ./expt_write.sh --ip <PC_IP> --port <PORT> --api-version v4.2 \
#                   --username admin --password <secret> [--subnet <extId>] [--insecure]
#
#   Env fallbacks: PC_IP/NUTANIX_HOST, PC_PORT/NUTANIX_PORT,
#   API_VERSION/NUTANIX_API_VERSION, PC_USERNAME/LIBCLOUD_NTNX_USER,
#   PC_PASSWORD/LIBCLOUD_NTNX_PASSWORD, SUBNET_EXT_ID, PC_INSECURE.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Inputs (CLI flags, then env fallbacks, then defaults) ───────────────────
PC_IP="${PC_IP:-${NUTANIX_HOST:-}}"
PC_PORT="${PC_PORT:-${NUTANIX_PORT:-9440}}"
API_VERSION="${API_VERSION:-${NUTANIX_API_VERSION:-v4.0}}"
PC_USERNAME="${PC_USERNAME:-${LIBCLOUD_NTNX_USER:-}}"
PC_PASSWORD="${PC_PASSWORD:-${LIBCLOUD_NTNX_PASSWORD:-}}"
PC_INSECURE="${PC_INSECURE:-true}"
VERBOSE=0
SUBNET_EXT_ID="${SUBNET_EXT_ID:-}"

usage() {
  cat <<'EOF'
Usage: ./expt_write.sh [options]

  --ip <host>            Prism Central IP/hostname          (env PC_IP / NUTANIX_HOST)
  --port <port>          Prism Central API port             (env PC_PORT / NUTANIX_PORT, default 9440)
  --api-version <v4.x>   Nutanix v4 API version             (env API_VERSION, default v4.0)
  --username <user>      Prism Central username             (env PC_USERNAME / LIBCLOUD_NTNX_USER)
  --password <pass>      Prism Central password             (env PC_PASSWORD / LIBCLOUD_NTNX_PASSWORD)
  --subnet <extId>       subnet extId for the test VM NIC   (env SUBNET_EXT_ID; auto-discovered if unset)
  --insecure             skip TLS verification (default)
  --verify-ssl           enforce TLS verification
  --dry-run              print curl commands instead of running (also CURL_DRY_RUN=1)
  --verbose, -v          show request/response headers + bodies
  -h, --help             this help

⚠  Mutates the target cluster.  Exit code: number of failed checks.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip)            PC_IP="$2";          shift 2 ;;
    --ip=*)          PC_IP="${1#*=}";     shift ;;
    --port)          PC_PORT="$2";        shift 2 ;;
    --port=*)        PC_PORT="${1#*=}";   shift ;;
    --api-version)   API_VERSION="$2";    shift 2 ;;
    --api-version=*) API_VERSION="${1#*=}"; shift ;;
    --username)      PC_USERNAME="$2";    shift 2 ;;
    --username=*)    PC_USERNAME="${1#*=}"; shift ;;
    --password)      PC_PASSWORD="$2";    shift 2 ;;
    --password=*)    PC_PASSWORD="${1#*=}"; shift ;;
    --subnet)        SUBNET_EXT_ID="$2";  shift 2 ;;
    --subnet=*)      SUBNET_EXT_ID="${1#*=}"; shift ;;
    --insecure)      PC_INSECURE="true";  shift ;;
    --verify-ssl)    PC_INSECURE="false"; shift ;;
    --dry-run)       CURL_DRY_RUN=1;      shift ;;
    -v|--verbose)    VERBOSE=1;           shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$API_VERSION" == v* ]] || API_VERSION="v${API_VERSION}"
case "$API_VERSION" in
  v4.0|v4.1|v4.2|v4.3) ;;
  *) echo "Unsupported API version: '$API_VERSION' (supported: v4.0..v4.3)" >&2; exit 2 ;;
esac

if [[ -z "$PC_IP" ]];       then echo "ERROR: --ip / PC_IP is required" >&2; exit 2; fi
if [[ -z "$PC_USERNAME" ]]; then echo "ERROR: --username / PC_USERNAME is required" >&2; exit 2; fi
if [[ -z "$PC_PASSWORD" ]]; then echo "ERROR: --password / PC_PASSWORD is required" >&2; exit 2; fi

BASE="https://${PC_IP}:${PC_PORT}"
API_BASE="${BASE}/api"

CURL_K=()
[[ "$PC_INSECURE" == "true" ]] && CURL_K+=(-k)

IAM_USERS="/iam/v4.0/authn/users"

VM_LIST="/vmm/${API_VERSION}/ahv/config/vms"
TASKS="/prism/${API_VERSION}/config/tasks"
SUBNETS="/networking/${API_VERSION}/config/subnets"
VPCS="/networking/${API_VERSION}/config/vpcs"
FIPS="/networking/${API_VERSION}/config/floating-ips"
NSPS="/microseg/${API_VERSION}/config/policies"
VGS="/volumes/${API_VERSION}/config/volume-groups"
RPS="/dataprotection/${API_VERSION}/config/recovery-points"

TMP="$(mktemp -d)"
COOKIE_JAR="${TMP}/cookie.txt"
AUTH_MODE="cookie"
PASS=0
FAIL=0
trap 'rm -rf "$TMP"' EXIT

# ─── Helpers ────────────────────────────────────────────────────────────────
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; PASS=$((PASS+1)); }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*"; FAIL=$((FAIL+1)); }
hdr()   { printf '\n\033[1;36m── %s ──\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }

jget() {
  python3 -c 'import sys, json
d = json.load(sys.stdin)
try:
    for k in sys.argv[1].split("."):
        d = d[int(k)] if isinstance(d, list) else d[k]
    print("" if d is None else d)
except Exception:
    pass' "$1" 2>/dev/null
}

# _trace METHOD URL BODY [EXTRA...] — print full request/response detail (verbose).
_trace() {
  local method="$1" url="$2" body="${3:-}"
  shift 3
  {
    printf '────────────────────────────────────────────────────────────\n'
    printf '  REQUEST\n'
    printf '    method:  %s\n' "$method"
    printf '    url:     %s\n' "$url"
    printf '    headers:\n'
    printf '      Accept: application/json\n'
    if [[ "$AUTH_MODE" == "basic" ]]; then
      printf '      Authorization: Basic ******** (user %s)\n' "$PC_USERNAME"
    else
      local ck
      ck="$(grep -v '^#' "$COOKIE_JAR" 2>/dev/null | awk 'NF >= 7 {printf "%s%s=%s", sep, $6, $7; sep="; "}')"
      printf '      Cookie: %s\n' "${ck:-<none>}"
    fi
    [[ -n "$body" ]] && printf '      Content-Type: application/json\n'
    [[ $# -gt 0 ]] && printf '    extra-args: %s\n' "$*"
    [[ -n "$body" ]] && printf '    body:     %s\n' "$body"
    printf '  RESPONSE\n'
    printf '    status:  %s\n' "$RESP_CODE"
    if [[ -n "$RESP_HEADERS" ]]; then
      printf '    headers:\n'
      sed 's/^/      /' <<<"$RESP_HEADERS"
    fi
    printf '    body:\n'
    if [[ -n "$RESP_BODY" ]]; then
      if command -v jq >/dev/null 2>&1; then
        local pretty
        pretty="$(printf '%s' "$RESP_BODY" | jq . 2>/dev/null)"
        if [[ -n "$pretty" ]]; then
          printf '%s\n' "$pretty" | sed 's/^/      /'
        else
          printf '      %s\n' "$RESP_BODY"
        fi
      else
        printf '      %s\n' "$RESP_BODY"
      fi
    else
      printf '      <empty>\n'
    fi
    printf '────────────────────────────────────────────────────────────\n'
  } >&2
}

# req METHOD URL [BODY] [EXTRA...] — authenticated request; sets RESP_CODE/RESP_BODY
# (and RESP_HEADERS). With --verbose, prints the full request/response trace.
req() {
  local method="$1" url="$2" body=""
  shift 2
  if [[ $# -gt 0 && "${1:-}" != -* ]]; then body="$1"; shift; fi

  local args=( -s -o "$TMP/body" -D "$TMP/headers" -w '%{http_code}' -X "$method" "${CURL_K[@]}" \
               -H 'Accept: application/json' )
  if [[ "$AUTH_MODE" == "basic" ]]; then
    args+=( -u "${PC_USERNAME}:${PC_PASSWORD}" )
  else
    args+=( -b "${COOKIE_JAR}" )
  fi
  [[ -n "$body" ]] && args+=( -H 'Content-Type: application/json' -d "$body" )
  args+=( "$@" )

  if [[ "${CURL_DRY_RUN:-0}" == "1" ]]; then
    printf 'curl '; printf '%q ' "${args[@]}"; printf '%q\n' "$url"
    RESP_CODE=""; RESP_BODY=""; RESP_HEADERS=""; return 0
  fi

  RESP_CODE="$(curl "${args[@]}" "$url" 2>&1)" || RESP_CODE="curl-error"
  RESP_BODY="$(cat "$TMP/body" 2>/dev/null)"
  RESP_HEADERS="$(cat "$TMP/headers" 2>/dev/null)"

  if [[ "${REQ_SILENT:-0}" != "1" ]]; then
    printf '\033[2m  → %s %s\033[0m\n' "$method" "$url" >&2
  fi

  if [[ "$VERBOSE" == "1" && "${REQ_SILENT:-0}" != "1" ]]; then
    _trace "$method" "$url" "$body" "$@"
  fi
}

# check DESC METHOD URL EXPECTED_CODE [BODY] [EXTRA...]
check() {
  local desc="$1" method="$2" url="$3" expected="$4" body=""
  shift 4
  if [[ $# -gt 0 && "${1:-}" != -* ]]; then body="$1"; shift; fi
  req "$method" "$url" "$body" "$@"
  if [[ "$RESP_CODE" == "$expected" ]]; then
    green "$desc (HTTP $RESP_CODE)"
  else
    red "$desc — expected $expected, got $RESP_CODE"
    [[ -n "$RESP_BODY" ]] && dim "    body: ${RESP_BODY:0:300}"
  fi
}

# ─── 1. Convert username/password → IAM programmatic credential ─────────────
generate_iam_key() {
  hdr "IAM credential — convert ${PC_USERNAME} password → API key"

  local users_json
  users_json="$(curl "${CURL_K[@]}" -sS \
    -u "${PC_USERNAME}:${PC_PASSWORD}" \
    -H 'Accept: application/json' \
    "${API_BASE}${IAM_USERS}")" || {
      echo "ERROR: could not list IAM users (Basic auth)." >&2; return 1; }

  USER_EXT_ID="$(printf '%s' "$users_json" | python3 -c '
import sys, json
try:
    doc = json.load(sys.stdin)
    want = sys.argv[1]
    for u in doc.get("data") or []:
        if (u.get("username") or "") == want:
            print(u.get("extId") or ""); break
except Exception:
    pass' "$PC_USERNAME")"

  if [[ -z "$USER_EXT_ID" ]]; then
    echo "WARNING: user '$PC_USERNAME' not found in IAM user list; skipping key generation." >&2
    return 0
  fi
  green "found user '$PC_USERNAME' → extId ${USER_EXT_ID}"

  local key_resp
  key_resp="$(curl "${CURL_K[@]}" -sS \
    -u "${PC_USERNAME}:${PC_PASSWORD}" \
    -H 'Content-Type: application/json' -H 'Accept: application/json' \
    -d '{"name":"automation_api_key","keyType":"API_KEY"}' \
    "${API_BASE}${IAM_USERS}/${USER_EXT_ID}/keys")" || {
      echo "ERROR: could not create IAM API key." >&2; return 1; }

  IAM_API_KEY="$(printf '%s' "$key_resp" | python3 -c '
import sys, json
try:
    doc = json.load(sys.stdin)
    d = doc.get("data") or doc
    kd = d.get("keyDetails") or {}
    print(kd.get("apiKey") or kd.get("secretKey") or d.get("apiKey") or d.get("secretKey") or "")
except Exception:
    pass')"

  if [[ -n "$IAM_API_KEY" ]]; then
    green "generated IAM API key (shown once, save it):"
    dim "    ${IAM_API_KEY}"
  else
    dim "no apiKey/secretKey returned — the key may already exist or the response uses a different shape."
  fi
  return 0
}

# ─── 2. Session cookie login ────────────────────────────────────────────────
iam_login() {
  hdr "IAM session login — capture NTNX_IGW_SESSION cookie"
  local probe="${API_BASE}${IAM_USERS}?\$limit=1"
  local code

  echo "==> Basic auth as ${PC_USERNAME} @ ${BASE}" >&2
  code=$(curl "${CURL_K[@]}" -sS -o /dev/null -w "%{http_code}" \
    -u "${PC_USERNAME}:${PC_PASSWORD}" \
    -c "${COOKIE_JAR}" \
    -H 'Accept: application/json' \
    "${probe}")

  if [[ "$code" != "200" ]]; then
    echo "    IAM probe returned ${code}; trying PrismGateway session endpoint..." >&2
    code=$(curl "${CURL_K[@]}" -sS -o /dev/null -w "%{http_code}" \
      -u "${PC_USERNAME}:${PC_PASSWORD}" \
      -c "${COOKIE_JAR}" \
      -H 'Content-Type: application/json' -d '{}' \
      "${BASE}/PrismGateway/services/rest/v1/session")
  fi

  if [[ "$code" != "200" ]]; then
    echo "ERROR: authentication failed (HTTP ${code}). Check IP/port/username/password." >&2
    return 1
  fi

  code=$(curl "${CURL_K[@]}" -sS -o /dev/null -w "%{http_code}" \
    -b "${COOKIE_JAR}" \
    -H 'Accept: application/json' \
    "${probe}")

  if [[ "$code" != "200" ]]; then
    echo "WARNING: cookie-only request returned ${code}; falling back to Basic auth." >&2
    AUTH_MODE="basic"
  else
    echo "    OK - session cookie accepted (jar ${COOKIE_JAR})" >&2
    AUTH_MODE="cookie"
  fi
  return 0
}

# ─── Task polling ───────────────────────────────────────────────────────────
poll_task() {
  local tid="$1" i
  TASK_STATUS=""
  for i in $(seq 1 30); do
    REQ_SILENT=1 req GET "${API_BASE}${TASKS}/${tid}"
    TASK_STATUS="$(echo "$RESP_BODY" | jget data.status)"
    [[ "$TASK_STATUS" == "SUCCEEDED" ]] && return 0
    sleep 2
  done
  return 1
}

# Discover a subnet extId for the test VM NIC (override via --subnet / env).
resolve_subnet() {
  if [[ -n "$SUBNET_EXT_ID" ]]; then
    SEED_SUBNET="$SUBNET_EXT_ID"; return 0
  fi
  req GET "${API_BASE}${SUBNETS}"
  SEED_SUBNET="$(echo "$RESP_BODY" | jget data.0.extId)"
  [[ -n "$SEED_SUBNET" ]] && return 0 || return 1
}

summary() {
  echo ""
  echo "════════════════════════════════════════════════════════"
  printf "  Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
  echo "════════════════════════════════════════════════════════"
  exit "$FAIL"
}

# ─── Main ───────────────────────────────────────────────────────────────────
printf '╔══════════════════════════════════════════════════════════╗\n'
printf '║   Nutanix IAM write sweep       %-26s║\n' "${API_VERSION}"
printf '║   Target:   %-45s║\n' "${PC_IP}:${PC_PORT}"
printf '║   User:     %-45s║\n' "${PC_USERNAME}"
printf '╚══════════════════════════════════════════════════════════╝\n'
printf '\033[33m⚠  MUTATING operations against %s — review before running.\033[0m\n' "${PC_IP}:${PC_PORT}"

generate_iam_key || exit 1
iam_login || exit 1

# ─── 2. VM lifecycle (create → task → get → update → power → filter → delete)
hdr "VM lifecycle"

if resolve_subnet; then
  VM_BODY='{"name":"test-vm","description":"created by expt_write.sh","num_sockets":2,"num_cores_per_socket":2,"memory_size_bytes":4294967296,"nics":[{"subnet":{"ext_id":"'"$SEED_SUBNET"'"}}]}'
  dim "    using subnet ${SEED_SUBNET} for the VM NIC"
else
  dim "    no subnet discovered — creating VM without nics"
  VM_BODY='{"name":"test-vm","description":"created by expt_write.sh","num_sockets":2,"num_cores_per_socket":2,"memory_size_bytes":4294967296}'
fi

req POST "${API_BASE}${VM_LIST}" "$VM_BODY"
TASK_ID="$(echo "$RESP_BODY" | jget data.extId)"
[[ -n "$TASK_ID" ]] && green "POST create VM accepted (task ${TASK_ID})" || red "POST create VM: no task id"

VM_ID=""
if [[ -n "$TASK_ID" ]]; then
  if poll_task "$TASK_ID"; then
    green "create task SUCCEEDED"
    VM_ID="$(echo "$RESP_BODY" | jget data.entitiesAffected.0.extId)"
  else
    red "create task did not reach SUCCEEDED (last: ${TASK_STATUS})"
  fi
fi

if [[ -n "$VM_ID" ]]; then
  req GET "${API_BASE}${VM_LIST}/${VM_ID}"
  NAME="$(echo "$RESP_BODY" | jget data.name)"
  [[ "$NAME" == "test-vm" ]] && green "GET VM name ok" || red "GET VM name: '$NAME'"

  req PUT "${API_BASE}${VM_LIST}/${VM_ID}" '{"name":"test-vm-v2","numSockets":4}'
  UTASK="$(echo "$RESP_BODY" | jget data.extId)"
  if [[ -n "$UTASK" ]] && poll_task "$UTASK"; then
    green "PUT update task SUCCEEDED"
  else
    red "PUT update failed"
  fi
  req GET "${API_BASE}${VM_LIST}/${VM_ID}"
  NAME="$(echo "$RESP_BODY" | jget data.name)"
  [[ "$NAME" == "test-vm-v2" ]] && green "updated name persisted" || red "updated name: '$NAME'"

  req POST "${API_BASE}${VM_LIST}/${VM_ID}/\$actions/power-off" '{}'
  PTASK="$(echo "$RESP_BODY" | jget data.extId)"
  [[ -n "$PTASK" ]] && green "power-off accepted (task ${PTASK})" || red "power-off: no task"
  sleep 1
  req GET "${API_BASE}${VM_LIST}/${VM_ID}"
  PS="$(echo "$RESP_BODY" | jget data.powerState)"
  [[ "$PS" == "OFF" ]] && green "power state is OFF" || red "power state: '$PS' (expected OFF)"

  check "List VMs" GET "${API_BASE}${VM_LIST}" 200
  req GET "${API_BASE}${VM_LIST}" "" --get --data-urlencode "\$filter=name eq 'test-vm-v2'"
  F="$(echo "$RESP_BODY" | jget metadata.totalAvailableResults)"
  [[ "$F" == "1" ]] && green "\$filter by name works" || red "\$filter returned ${F} (expected 1)"

  req DELETE "${API_BASE}${VM_LIST}/${VM_ID}"
  DTASK="$(echo "$RESP_BODY" | jget data.extId)"
  if [[ -n "$DTASK" ]] && poll_task "$DTASK"; then
    green "DELETE task SUCCEEDED"
  else
    red "DELETE failed"
  fi
  check "GET deleted VM → 404" GET "${API_BASE}${VM_LIST}/${VM_ID}" 404
fi

# ─── 3. Networking (subnet / VPC / floating IP / NSP) ───────────────────────
hdr "Networking"

req POST "${API_BASE}${SUBNETS}" '{"name":"test-subnet","subnetType":"VLAN"}'
STASK="$(echo "$RESP_BODY" | jget data.extId)"
[[ -n "$STASK" ]] && green "create subnet accepted" || red "create subnet failed"
req GET "${API_BASE}${TASKS}/${STASK}"
SUBNET_ID="$(echo "$RESP_BODY" | jget data.entitiesAffected.0.extId)"
[[ -n "$SUBNET_ID" ]] && green "subnet extId from task" || red "subnet extId missing"
check "List subnets after create" GET "${API_BASE}${SUBNETS}" 200

req POST "${API_BASE}${VPCS}" '{"name":"test-vpc"}'
VTASK="$(echo "$RESP_BODY" | jget data.extId)"
req GET "${API_BASE}${TASKS}/${VTASK}"
VPC_ID="$(echo "$RESP_BODY" | jget data.entitiesAffected.0.extId)"
[[ -n "$VPC_ID" ]] && green "create VPC accepted (${VPC_ID})" || red "create VPC failed"
check "List VPCs" GET "${API_BASE}${VPCS}" 200
check "Delete VPC" DELETE "${API_BASE}${VPCS}/${VPC_ID}" 202

req POST "${API_BASE}${FIPS}" '{"name":"test-fip"}'
FTASK="$(echo "$RESP_BODY" | jget data.extId)"
req GET "${API_BASE}${TASKS}/${FTASK}"
FIP_ID="$(echo "$RESP_BODY" | jget data.entitiesAffected.0.extId)"
[[ -n "$FIP_ID" ]] && green "create floating IP accepted (${FIP_ID})" || red "create floating IP failed"
check "List floating IPs" GET "${API_BASE}${FIPS}" 200
check "Delete floating IP" DELETE "${API_BASE}${FIPS}/${FIP_ID}" 202

req POST "${API_BASE}${NSPS}" '{"name":"test-nsp"}'
NTASK="$(echo "$RESP_BODY" | jget data.extId)"
req GET "${API_BASE}${TASKS}/${NTASK}"
NSP_ID="$(echo "$RESP_BODY" | jget data.entitiesAffected.0.extId)"
[[ -n "$NSP_ID" ]] && green "create NSP accepted (${NSP_ID})" || red "create NSP failed"
check "List NSPs" GET "${API_BASE}${NSPS}" 200
check "Delete NSP" DELETE "${API_BASE}${NSPS}/${NSP_ID}" 202

check "Delete subnet" DELETE "${API_BASE}${SUBNETS}/${SUBNET_ID}" 202

# ─── 4. Volume groups / recovery points ─────────────────────────────────────
hdr "Volume groups / recovery points"

req POST "${API_BASE}${VGS}" '{"name":"test-vg","disks":[{"diskSizeBytes":10737418240}]}'
GTASK="$(echo "$RESP_BODY" | jget data.extId)"
req GET "${API_BASE}${TASKS}/${GTASK}"
VG_ID="$(echo "$RESP_BODY" | jget data.entitiesAffected.0.extId)"
[[ -n "$VG_ID" ]] && green "create volume group accepted (${VG_ID})" || red "create VG failed"
check "List volume groups" GET "${API_BASE}${VGS}" 200
check "List VG disks" GET "${API_BASE}${VGS}/${VG_ID}/disks" 200

req POST "${API_BASE}${RPS}" "{\"name\":\"test-rp\",\"volumeGroupRecoveryPoints\":[{\"volumeGroupExtId\":\"${VG_ID}\"}]}"
RTASK="$(echo "$RESP_BODY" | jget data.extId)"
req GET "${API_BASE}${TASKS}/${RTASK}"
RP_ID="$(echo "$RESP_BODY" | jget data.entitiesAffected.0.extId)"
[[ -n "$RP_ID" ]] && green "create recovery point accepted (${RP_ID})" || red "create RP failed"
req GET "${API_BASE}${RPS}" "" --get --data-urlencode "\$filter=volumeGroupExtId eq '${VG_ID}'"
RF="$(echo "$RESP_BODY" | jget metadata.totalAvailableResults)"
[[ "$RF" -ge 1 ]] && green "RP \$filter by volumeGroupExtId works" || red "RP \$filter returned ${RF}"
check "Delete recovery point" DELETE "${API_BASE}${RPS}/${RP_ID}" 202
check "Delete volume group" DELETE "${API_BASE}${VGS}/${VG_ID}" 202

summary
