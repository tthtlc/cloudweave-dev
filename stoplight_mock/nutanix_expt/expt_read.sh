#!/usr/bin/env bash
# =============================================================================
# expt_read.sh — Prism Central read-only sweep, authenticated via Nutanix IAM.
#
# Takes the Prism Central IP + port + API version + username + password as
# input, converts those human credentials into an IAM programmatic credential
# (see passwd2iam_convert.md / passwd2iam_convert0.md / passwd2iam_convert1.md),
# establishes the NTNX_IGW_SESSION session cookie, and then runs a read-only
# enumeration (List VMs first, then the remaining GET endpoints) against the
# real Nutanix server — the same set of read requests exercised by
# ../scripts/test_read.sh in real-host mode.
#
# Authentication model (mirrors common.sh):
#   1. Find the user's extId        GET  /iam/v4.0/authn/users  (Basic auth)
#   2. Generate an IAM API key      POST /iam/v4.0/authn/users/{extId}/keys
#      (keyType=API_KEY) — returned once in data.keyDetails.apiKey.
#   3. Log in once with Basic auth to capture the NTNX_IGW_SESSION session
#      cookie, then send ONLY that cookie (fallback: Basic auth) on every
#      subsequent request.
#
# Usage:
#   ./expt_read.sh --ip <PC_IP> --port <PORT> --api-version v4.2 \
#                  --username admin --password <secret> [--insecure]
#
#   Env fallbacks: PC_IP/NUTANIX_HOST, PC_PORT/NUTANIX_PORT,
#   API_VERSION/NUTANIX_API_VERSION, PC_USERNAME/LIBCLOUD_NTNX_USER,
#   PC_PASSWORD/LIBCLOUD_NTNX_PASSWORD, PC_INSECURE.
#   CURL_DRY_RUN=1 prints the curl commands without executing them.
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

usage() {
  cat <<'EOF'
Usage: ./expt_read.sh [options]

  --ip <host>            Prism Central IP/hostname          (env PC_IP / NUTANIX_HOST)
  --port <port>          Prism Central API port             (env PC_PORT / NUTANIX_PORT, default 9440)
  --api-version <v4.x>   Nutanix v4 API version             (env API_VERSION, default v4.0)
  --username <user>      Prism Central username             (env PC_USERNAME / LIBCLOUD_NTNX_USER)
  --password <pass>      Prism Central password             (env PC_PASSWORD / LIBCLOUD_NTNX_PASSWORD)
  --subnet <extId>       subnet extId for VM NIC (write script only, ignored here)
  --insecure             skip TLS verification (default)
  --verify-ssl           enforce TLS verification
  --dry-run              print curl commands instead of running (also CURL_DRY_RUN=1)
  --verbose, -v          show request/response headers + bodies
  -h, --help             this help

Exit code: number of failed checks (0 = all passed).
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

# Normalise the version token (accept "4.2" or "v4.2").
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

# IAM login/credential endpoints (IAM ships a v4.0 spec regardless of the
# resource API version used for the read sweep).
IAM_USERS="/iam/v4.0/authn/users"

# Resource endpoints for the read sweep (versioned by API_VERSION).
VM_LIST="/vmm/${API_VERSION}/ahv/config/vms"
CLUSTERS="/clustermgmt/${API_VERSION}/config/clusters"
SUBNETS="/networking/${API_VERSION}/config/subnets"
VPCS="/networking/${API_VERSION}/config/vpcs"
FIPS="/networking/${API_VERSION}/config/floating-ips"
IMAGES="/vmm/${API_VERSION}/content/images"
SCS="/clustermgmt/${API_VERSION}/config/storage-containers"
TASKS="/prism/${API_VERSION}/config/tasks"
IAM_ROLES="/iam/v4.0/authz/roles"

TMP="$(mktemp -d)"
COOKIE_JAR="${TMP}/cookie.txt"
AUTH_MODE="basic"
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

# _trace METHOD URL BODY AUTH [EXTRA...] — print full request/response detail (verbose).
_trace() {
  local method="$1" url="$2" body="${3:-}" auth="${4:-$AUTH_MODE}"
  shift 4
  {
    printf '────────────────────────────────────────────────────────────\n'
    printf '  REQUEST\n'
    printf '    method:  %s\n' "$method"
    printf '    url:     %s\n' "$url"
    printf '    headers:\n'
    printf '      Accept: application/json\n'
    if [[ "$auth" == "basic" ]]; then
      printf '      Authorization: Basic ******** (user %s)\n' "$PC_USERNAME"
    else
      local ck
      ck="$(awk -F'\t' 'NF >= 7 {printf "%s%s=%s", sep, $6, $7; sep="; "}' "$COOKIE_JAR" 2>/dev/null)"
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
#
# AUTH_MODE selects Basic (`-u`) or cookie (`-b`). Recognised EXTRA markers:
#   --auth-basic    force Basic auth for this call
#   --auth-cookie   force cookie auth for this call
#   --save-cookies  also write the session cookie jar (`-c`)
#   --no-body       discard the response body (probes)
req() {
  local method="$1" url="$2" body=""
  shift 2
  if [[ $# -gt 0 && "${1:-}" != -* ]]; then body="$1"; shift; fi

  local auth="$AUTH_MODE" save_cookies=0 no_body=0 extra=() a
  for a in "$@"; do
    case "$a" in
      --auth-basic)   auth="basic"   ;;
      --auth-cookie)  auth="cookie"  ;;
      --save-cookies) save_cookies=1 ;;
      --no-body)      no_body=1      ;;
      *)              extra+=( "$a" ) ;;
    esac
  done

  local out="$TMP/body"; [[ "$no_body" == "1" ]] && out="/dev/null"
  local args=( -s -o "$out" -D "$TMP/headers" -w '%{http_code}' -X "$method" "${CURL_K[@]}" \
               -H 'Accept: application/json' )
  if [[ "$auth" == "basic" ]]; then
    args+=( -u "${PC_USERNAME}:${PC_PASSWORD}" )
  else
    args+=( -b "${COOKIE_JAR}" )
  fi
  [[ "$save_cookies" == "1" ]] && args+=( -c "${COOKIE_JAR}" )
  [[ -n "$body" ]] && args+=( -H 'Content-Type: application/json' -d "$body" )
  args+=( "${extra[@]}" )

  if [[ "${CURL_DRY_RUN:-0}" == "1" ]]; then
    printf 'curl '; printf '%q ' "${args[@]}"; printf '%q\n' "$url"
    RESP_CODE=""; RESP_BODY=""; RESP_HEADERS=""; return 0
  fi

  if [[ "${REQ_SILENT:-0}" != "1" ]]; then
    printf '\033[2m  → %s %s\033[0m\n' "$method" "$url" >&2
  fi

  RESP_CODE="$(curl "${args[@]}" "$url" 2>&1)" || RESP_CODE="curl-error"
  RESP_BODY="$(cat "$TMP/body" 2>/dev/null)"
  RESP_HEADERS="$(cat "$TMP/headers" 2>/dev/null)"
  [[ "$no_body" == "1" ]] && RESP_BODY=""

  if [[ "$VERBOSE" == "1" && "${REQ_SILENT:-0}" != "1" ]]; then
    _trace "$method" "$url" "$body" "$auth" "${extra[@]}"
  fi
}

# ─── 1. Convert username/password → IAM programmatic credential ─────────────
# Step 1 (md): list users with Basic auth, find this user's extId.
# Step 2 (md): POST an API_KEY to generate the long-lived programmatic token.
generate_iam_key() {
  hdr "IAM credential — convert ${PC_USERNAME} password → API key"

  req GET "${API_BASE}${IAM_USERS}" --auth-basic
  local users_json="$RESP_BODY"
  if [[ "$RESP_CODE" != "200" ]]; then
    echo "ERROR: could not list IAM users (Basic auth, HTTP ${RESP_CODE})." >&2; return 1
  fi

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

  req POST "${API_BASE}${IAM_USERS}/${USER_EXT_ID}/keys" \
    '{"name":"automation_api_key","keyType":"API_KEY"}' --auth-basic
  local key_resp="$RESP_BODY"
  if [[ "$RESP_CODE" != "200" ]]; then
    echo "ERROR: could not create IAM API key (HTTP ${RESP_CODE})." >&2; return 1
  fi

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
    dim "    (usable later as:  Authorization: Basic ${IAM_API_KEY})"
  else
    dim "no apiKey/secretKey returned — the key may already exist or the response uses a different shape."
  fi
  return 0
}

# ─── 2. Session cookie login (Basic auth once → NTNX_IGW_SESSION cookie) ────
iam_login() {
  hdr "IAM session login — capture NTNX_IGW_SESSION cookie"
  local probe="${API_BASE}${IAM_USERS}?\$limit=1"
  local code

  echo "==> Basic auth as ${PC_USERNAME} @ ${BASE}" >&2
  req GET "$probe" --auth-basic --save-cookies --no-body
  code="$RESP_CODE"

  if [[ "$code" != "200" ]]; then
    echo "    IAM probe returned ${code}; trying PrismGateway session endpoint..." >&2
    req POST "${BASE}/PrismGateway/services/rest/v1/session" '{}' \
      --auth-basic --save-cookies --no-body
    code="$RESP_CODE"
  fi

  if [[ "$code" != "200" ]]; then
    echo "ERROR: authentication failed (HTTP ${code}). Check IP/port/username/password." >&2
    return 1
  fi

  req GET "$probe" --auth-cookie --no-body
  code="$RESP_CODE"

  if [[ "$code" != "200" ]]; then
    echo "WARNING: cookie-only request returned ${code}; falling back to Basic auth." >&2
    AUTH_MODE="basic"
  else
    echo "    OK - session cookie accepted (jar ${COOKIE_JAR})" >&2
    AUTH_MODE="cookie"
  fi
  return 0
}

# ─── 3. Read sweep ──────────────────────────────────────────────────────────
list_and_count() {
  local desc="$1" url="$2"
  req GET "$url"
  if [[ "$RESP_CODE" == "200" ]]; then
    local n
    n="$(echo "$RESP_BODY" | jget metadata.totalAvailableResults)"
    green "${desc} (HTTP 200, totalAvailableResults=${n})"
  else
    red "${desc} — expected 200, got ${RESP_CODE}"
    [[ -n "$RESP_BODY" ]] && dim "    body: ${RESP_BODY:0:300}"
  fi
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
printf '║   Nutanix IAM read sweep        %-26s║\n' "${API_VERSION}"
printf '║   Target:   %-45s║\n' "${PC_IP}:${PC_PORT}"
printf '║   User:     %-45s║\n' "${PC_USERNAME}"
printf '╚══════════════════════════════════════════════════════════╝\n'

generate_iam_key || exit 1
iam_login || exit 1

hdr "List VMs (primary)"
list_and_count "List VMs"       "${API_BASE}${VM_LIST}"

hdr "Read-only enumeration (as in ../scripts/test_read.sh real-host mode)"
list_and_count "List clusters"  "${API_BASE}${CLUSTERS}"
list_and_count "List subnets"   "${API_BASE}${SUBNETS}"
list_and_count "List VPCs"      "${API_BASE}${VPCS}"
list_and_count "List images"    "${API_BASE}${IMAGES}"
list_and_count "List floating IPs" "${API_BASE}${FIPS}"
list_and_count "List storage containers" "${API_BASE}${SCS}"
list_and_count "List tasks"     "${API_BASE}${TASKS}"
list_and_count "List IAM roles (v4.0)" "${API_BASE}${IAM_ROLES}"

summary
