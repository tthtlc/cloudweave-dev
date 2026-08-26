#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Shared harness for test_read.sh / test_write.sh — SOURCE this file, don't
# execute it directly.
#
# Provides: arg parsing (-v/--verbose, -V/--version), per-version URL + path
# derivation, output helpers, the HTTP primitive (req), assertions (check /
# check_body), task polling, and the banner/summary helpers.
#
# The calling script must define usage() before sourcing this file.
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ─── Defaults / arg parsing ───────────────────────────────────────────────────
VERBOSE=0
VERSION="v4.0"
VERSION_EXPLICIT=0
TARGET_FLAG="auto"     # auto | real | mock

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) VERBOSE=1 ;;
    -V|--version) VERSION="${2:-}"; VERSION_EXPLICIT=1; shift ;;
    --target)     TARGET_FLAG="${2:-auto}"; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ─── Env-file loading & target selection ──────────────────────────────────────
# When NUTANIX_HOST is present in $REPO_ROOT/my.env (fallback .env), the scripts
# auto-target the REAL Nutanix Prism Central host instead of the local mock
# stack. Connection settings (host/port/API version/TLS) come from my.env/.env;
# the admin Basic-auth credentials come from test_script/tenant_vault_secret.env
# (fallback root tenant_vault_secret.env). Override detection with
# --target real|mock.

# Extract KEY=value from a dotenv file. Handles an optional `export` prefix and
# surrounding single/double quotes; ignores comments and blank lines. Prints the
# value only (empty + nonzero exit when absent).
_get_env() {
  local file="$1" key="$2"
  grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null \
    | head -n1 \
    | sed -E 's/^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=//' \
    | sed -E 's/^["'"'"']//; s/["'"'"'][[:space:]]*$//'
}

_load_conn_settings() {
  local f
  for f in "${REPO_ROOT}/my.env" "${REPO_ROOT}/.env"; do
    [[ -n "${NUTANIX_HOST:-}" ]]        || NUTANIX_HOST="$(_get_env "$f" NUTANIX_HOST)"
    [[ -n "${NUTANIX_PORT:-}" ]]        || NUTANIX_PORT="$(_get_env "$f" NUTANIX_PORT)"
    [[ -n "${NUTANIX_API_VERSION:-}" ]] || NUTANIX_API_VERSION="$(_get_env "$f" NUTANIX_API_VERSION)"
    [[ -n "${NUTANIX_VERIFY_SSL:-}" ]]  || NUTANIX_VERIFY_SSL="$(_get_env "$f" NUTANIX_VERIFY_SSL)"
  done
  for f in "${REPO_ROOT}/test_script/tenant_vault_secret.env" "${REPO_ROOT}/tenant_vault_secret.env"; do
    [[ -n "${LIBCLOUD_NTNX_USER:-}" ]]     || LIBCLOUD_NTNX_USER="$(_get_env "$f" LIBCLOUD_NTNX_USER)"
    [[ -n "${LIBCLOUD_NTNX_PASSWORD:-}" ]] || LIBCLOUD_NTNX_PASSWORD="$(_get_env "$f" LIBCLOUD_NTNX_PASSWORD)"
  done
  NUTANIX_PORT="${NUTANIX_PORT:-9440}"
  NUTANIX_API_VERSION="${NUTANIX_API_VERSION:-v4.0}"
  NUTANIX_VERIFY_SSL="${NUTANIX_VERIFY_SSL:-false}"
}

case "$TARGET_FLAG" in
  mock) TARGET="mock" ;;
  real) TARGET="real"; _load_conn_settings ;;
  *)    _load_conn_settings
        if [[ -n "${NUTANIX_HOST:-}" ]]; then TARGET="real"; else TARGET="mock"; fi ;;
esac

# In real-host mode the API version is authoritative from my.env (e.g. v4.2),
# unless the caller explicitly passed --version.
if [[ "$TARGET" == "real" && "$VERSION_EXPLICIT" != "1" ]]; then
  VERSION="${NUTANIX_API_VERSION:-v4.0}"
fi

# Normalise the version token and derive the per-version ports.
case "${VERSION#v}" in
  4.0) MINOR=0; VERSION="v4.0" ;;
  4.1) MINOR=1; VERSION="v4.1" ;;
  4.2) MINOR=2; VERSION="v4.2" ;;
  4.3) MINOR=3; VERSION="v4.3" ;;
  *) echo "Unsupported version: '$VERSION' (supported: v4.0, v4.1, v4.2, v4.3)" >&2; exit 2 ;;
esac

# HTTP Basic auth (real-host mode only); the mock Prism/emulator are unauth'd.
AUTH_USER=""
BASIC_AUTH=""
if [[ "$TARGET" == "real" ]]; then
  if [[ -z "${NUTANIX_HOST:-}" || -z "${LIBCLOUD_NTNX_USER:-}" || -z "${LIBCLOUD_NTNX_PASSWORD:-}" ]]; then
    echo "error: real-host mode needs NUTANIX_HOST (my.env/.env) and" >&2
    echo "       LIBCLOUD_NTNX_USER / LIBCLOUD_NTNX_PASSWORD (test_script/tenant_vault_secret.env)" >&2
    exit 2
  fi
  AUTH_USER="$LIBCLOUD_NTNX_USER"
  BASIC_AUTH="$(printf '%s:%s' "$LIBCLOUD_NTNX_USER" "$LIBCLOUD_NTNX_PASSWORD" | base64 | tr -d '\n')"
fi

if [[ "$TARGET" == "real" ]]; then
  PRISM="https://${NUTANIX_HOST}:${NUTANIX_PORT}"   # real Prism Central (no schema mock)
  EMU="https://${NUTANIX_HOST}:${NUTANIX_PORT}"     # same host; read-only endpoint checks
else
  PRISM="http://localhost:$((4010 + MINOR))"        # Prism   (schema-only mock)
  EMU="https://localhost:$((9440 + MINOR))"         # Emulator (stateful shim, self-signed)
fi

# ─── Per-version resource paths ──────────────────────────────────────────────
VM_LIST="/api/vmm/${VERSION}/ahv/config/vms"
TASKS="/api/prism/${VERSION}/config/tasks"
SUBNETS="/api/networking/${VERSION}/config/subnets"
VPCS="/api/networking/${VERSION}/config/vpcs"
FIPS="/api/networking/${VERSION}/config/floating-ips"
NSPS="/api/microseg/${VERSION}/config/policies"
CLUSTERS="/api/clustermgmt/${VERSION}/config/clusters"
IMAGES="/api/vmm/${VERSION}/content/images"
SCS="/api/clustermgmt/${VERSION}/config/storage-containers"
VGS="/api/volumes/${VERSION}/config/volume-groups"
RPS="/api/dataprotection/${VERSION}/config/recovery-points"

# ─── Resource key → full v4 API path ─────────────────────────────────────────
# Canonical map from a resource key to its versioned Nutanix v4 API path.
# Mirrors the per-version variables above (so paths track $VERSION).
path_for() {
  case "$1" in
    vms)             echo "$VM_LIST" ;;
    clusters)        echo "$CLUSTERS" ;;
    vpcs)            echo "$VPCS" ;;
    subnets)         echo "$SUBNETS" ;;
    images)          echo "$IMAGES" ;;
    floating-ips)    echo "$FIPS" ;;
    security-groups) echo "$NSPS" ;;
    storage)         echo "$SCS" ;;
    tasks)           echo "$TASKS" ;;
    volume-groups)   echo "$VGS" ;;
    recovery-points) echo "$RPS" ;;
    *)               echo "" ;;
  esac
}

# print_endpoints KEY... — dump the full v4 endpoint (base URL + path) for each
# resource key given, e.g. "vms  →  https://localhost:9440/api/vmm/v4.0/ahv/config/vms".
print_endpoints() {
  local key p
  for key in "$@"; do
    p="$(path_for "$key")"
    [[ -n "$p" ]] && dim "  $key  →  ${EMU}${p}"
  done
}

# Seed extIds (same across all versions in the emulator).
SEED_CLUSTER="00000000-0000-0000-0000-000000000001"
SEED_SUBNET="00000000-0000-0000-0000-000000000002"

REQ_ID="11111111-2222-3333-4444-555555555555"
VALID_UUID="${SEED_CLUSTER}"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ─── Output helpers ──────────────────────────────────────────────────────────
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; PASS=$((PASS+1)); }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*"; FAIL=$((FAIL+1)); }
hdr()   { printf '\n\033[1;36m── %s ──\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }

# jget DOTTED.PATH — extract a field from JSON on stdin ('' on failure).
jget() {
  python3 -c 'import sys, json
d = json.load(sys.stdin)
try:
    for k in sys.argv[1].split("."):
        d = d[int(k)] if isinstance(d, list) else d[k]
    print(d if d is not None else "")
except Exception:
    pass' "$1" 2>/dev/null
}

# ─── HTTP primitive ──────────────────────────────────────────────────────────
# req METHOD URL [BODY] [EXTRA_CURL_ARGS...]
#   Runs the request, sets RESP_CODE / RESP_BODY, and (in verbose mode) prints
#   the full request + response detail.
req() {
  local method="$1" url="$2" body=""
  shift 2
  # Optional 3rd positional is the request body; anything after that (or any
  # leading '-flag') is passed straight through to curl.
  if [[ $# -gt 0 && "${1:-}" != -* ]]; then body="$1"; shift; fi
  local args=(-s -o "$TMP/body" -w '%{http_code}' -X "$method")
  # -k (skip TLS verify): always for the self-signed mock emulator; for a real
  # host only when NUTANIX_VERIFY_SSL is not truthy.
  if [[ "$TARGET" == "mock" ]] || [[ "$NUTANIX_VERIFY_SSL" != "true" && "$NUTANIX_VERIFY_SSL" != "1" && "$NUTANIX_VERIFY_SSL" != "yes" ]]; then
    args+=(-k)
  fi
  # HTTP Basic auth header for real-host mode (mock services are unauthenticated).
  if [[ -n "${BASIC_AUTH:-}" ]]; then
    args+=(-H "Authorization: Basic ${BASIC_AUTH}")
  fi
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")
  args+=("$@")

  RESP_CODE="$(curl "${args[@]}" "$url" 2>&1)" || RESP_CODE="curl-error"
  RESP_BODY="$(cat "$TMP/body" 2>/dev/null)"

  # Print the full v4 endpoint for every call, to STDERR (so it never pollutes
  # a `$(req ...)` capture). Skipped for internal polling (REQ_SILENT) and in
  # verbose mode, where the detailed trace below already shows the URL.
  if [[ "${REQ_SILENT:-0}" != "1" && "$VERBOSE" != "1" ]]; then
    printf '\033[2m  → %s %s\033[0m\n' "$method" "$url" >&2
  fi

  # Verbose detail goes to STDERR (not stdout) so that `req` can be used inside
  # `$(...)` without the HTTP trace being captured into a variable.
  if [[ "$VERBOSE" == "1" ]]; then
    {
      printf '────────────────────────────────────────────────────────────\n'
      printf '  REQUEST\n'
      printf '    method:  %s\n' "$method"
      printf '    url:     %s\n' "$url"
      [[ -n "${AUTH_USER:-}" ]] && printf '    auth:    Basic %s (user %s)\n' "$BASIC_AUTH" "$AUTH_USER"
      [[ -n "$body" ]] && printf '    body:    %s\n' "$body"
      [[ $# -gt 0 ]] && printf '    headers: %s\n' "$*"
      printf '  RESPONSE\n'
      printf '    status:  %s\n' "$RESP_CODE"
      printf '    body:    %s\n' "${RESP_BODY:-<empty>}"
      printf '────────────────────────────────────────────────────────────\n'
    } >&2
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
    [[ "$VERBOSE" != "1" ]] && [[ -n "$RESP_BODY" ]] && dim "    body: ${RESP_BODY:0:300}"
  fi
}

# check_body DESC METHOD URL EXPECTED_CODE PATTERN [BODY] [EXTRA...]
check_body() {
  local desc="$1" method="$2" url="$3" expected="$4" pattern="$5" body=""
  shift 5
  if [[ $# -gt 0 && "${1:-}" != -* ]]; then body="$1"; shift; fi
  req "$method" "$url" "$body" "$@"
  if [[ "$RESP_CODE" == "$expected" ]] && grep -q "$pattern" <<<"$RESP_BODY"; then
    green "$desc (HTTP $RESP_CODE, body matches '$pattern')"
  elif [[ "$RESP_CODE" != "$expected" ]]; then
    red "$desc — expected $expected, got $RESP_CODE"
    [[ "$VERBOSE" != "1" ]] && [[ -n "$RESP_BODY" ]] && dim "    body: ${RESP_BODY:0:300}"
  else
    red "$desc — HTTP $RESP_CODE but body missing '$pattern'"
  fi
}

# poll_task TASK_ID → returns 0 when SUCCEEDED; sets TASK_STATUS
poll_task() {
  local tid="$1" i
  TASK_STATUS=""
  for i in $(seq 1 15); do
    REQ_SILENT=1 req GET "$EMU$TASKS/$tid"
    TASK_STATUS="$(echo "$RESP_BODY" | jget data.status)"
    [[ "$TASK_STATUS" == "SUCCEEDED" ]] && return 0
    sleep 0.4
  done
  return 1
}

# ─── Banner / summary ────────────────────────────────────────────────────────
banner() {
  local tag="$1"
  printf '╔══════════════════════════════════════════════════════════╗\n'
  printf '║   Nutanix v4 Mock-Stack Test   %-24s║\n' "$tag"
  printf '║   Version:  %-45s║\n' "$VERSION"
  printf '║   Target:   %-45s║\n' "$([[ "$TARGET" == "real" ]] && echo "real ${NUTANIX_HOST}:${NUTANIX_PORT}" || echo "mock (localhost)")"
  printf '║   Prism:    %-45s║\n' "$PRISM"
  printf '║   Emulator: %-45s║\n' "$EMU"
  printf '║   Mode:     %-45s║\n' "$([[ $VERBOSE == 1 ]] && echo verbose || echo quiet)"
  printf '╚══════════════════════════════════════════════════════════╝\n'
}

summary() {
  echo ""
  echo "════════════════════════════════════════════════════════"
  printf "  Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
  echo "════════════════════════════════════════════════════════"
  exit "$FAIL"
}
