#!/usr/bin/env bash
# =============================================================================
# sweep_lib.sh — shared harness for sweep_read.sh / sweep_write.sh.
#
# SOURCE this file from those scripts; do not execute it directly.
#
# What it provides:
#
#   • Argument parsing in both spellings — the key=value form
#     (auth=cookie | auth=basic, verbose=1, api_version=v4.2) and the --flag
#     form used by the sibling expt_read.sh / expt_write.sh scripts.
#
#   • build_urls <version> — (re)computes the eight endpoint variables for one
#     API version:  vms subnets tasks securitygroups vpcs floatingips
#                   volumegroups recoverypoints
#
#   • authenticate() — implements the two input modes:
#       auth=basic   USERNAME/PASSWORD form a Basic header that is sent on
#                    EVERY URL.
#       auth=cookie  USERNAME/PASSWORD form a Basic header used ONCE, for the
#                    first authentication; the session cookie returned by that
#                    login is then reused as the header for every subsequent
#                    URL and the Basic header is never sent again.
#
#   • req() — the single HTTP primitive. It runs curl with -v and captures the
#     stderr trace, so --verbose prints the headers that actually went on the
#     wire (request and response) rather than a reconstruction.
#
#   • Task polling, result assertions, banner/summary.
#
# The calling script must define usage() and SCRIPT_TITLE before sourcing, and
# must set NUTANIX_HOST / NUTANIX_PORT / api_version in its own configuration
# block above the source line.
# =============================================================================

set -uo pipefail

# ─── Argument parsing ────────────────────────────────────────────────────────
# Collected into _a_* first so that a flag always beats the script's built-in
# default, and the built-in default always beats nothing.
_a_auth=""; _a_verbose=""; _a_host=""; _a_port=""
_a_ver=""; _a_user=""; _a_pass=""

SHOW_SECRETS=0
CURL_DRY_RUN="${CURL_DRY_RUN:-0}"
NUTANIX_INSECURE="${NUTANIX_INSECURE:-true}"
MAX_BODY_LINES="${MAX_BODY_LINES:-60}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    auth=*)                 _a_auth="${1#*=}" ;;
    --auth)                 _a_auth="${2:-}"; shift ;;
    --auth=*)               _a_auth="${1#*=}" ;;

    verbose=*)              _a_verbose="${1#*=}" ;;
    -v|--verbose)           _a_verbose=1 ;;
    -q|--quiet)             _a_verbose=0 ;;

    api_version=*)          _a_ver="${1#*=}" ;;
    --api-version)          _a_ver="${2:-}"; shift ;;
    --api-version=*)        _a_ver="${1#*=}" ;;
    --all-versions)         _a_ver="all" ;;

    NUTANIX_HOST=*|host=*)  _a_host="${1#*=}" ;;
    --host|--ip)            _a_host="${2:-}"; shift ;;
    --host=*|--ip=*)        _a_host="${1#*=}" ;;

    NUTANIX_PORT=*|port=*)  _a_port="${1#*=}" ;;
    --port)                 _a_port="${2:-}"; shift ;;
    --port=*)               _a_port="${1#*=}" ;;

    username=*|USERNAME=*)  _a_user="${1#*=}" ;;
    --username)             _a_user="${2:-}"; shift ;;
    --username=*)           _a_user="${1#*=}" ;;

    password=*|PASSWORD=*)  _a_pass="${1#*=}" ;;
    --password)             _a_pass="${2:-}"; shift ;;
    --password=*)           _a_pass="${1#*=}" ;;

    --insecure)             NUTANIX_INSECURE="true" ;;
    --verify-ssl)           NUTANIX_INSECURE="false" ;;
    --show-secrets)         SHOW_SECRETS=1 ;;
    --dry-run)              CURL_DRY_RUN=1 ;;
    -h|--help)              usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ─── Resolve inputs: flag > script default > env ─────────────────────────────
NUTANIX_HOST="${_a_host:-${NUTANIX_HOST:-}}"
NUTANIX_PORT="${_a_port:-${NUTANIX_PORT:-9440}}"
USERNAME="${_a_user:-${USERNAME:-}}"
PASSWORD="${_a_pass:-${PASSWORD:-}}"

# auth=cookie | auth=basic
auth="${_a_auth:-${auth:-cookie}}"
case "${auth,,}" in
  cookie|session) AUTH_REQUESTED="cookie" ;;
  basic)          AUTH_REQUESTED="basic"  ;;
  *) echo "ERROR: auth must be 'cookie' or 'basic' (got '$auth')" >&2; exit 2 ;;
esac

# verbose / non-verbose
verbose="${_a_verbose:-${verbose:-0}}"
case "${verbose,,}" in
  1|true|yes|on|verbose) VERBOSE=1 ;;
  *)                     VERBOSE=0 ;;
esac

# api_version: a single version, or every version from v4.0 through v4.3.
API_VERSIONS_ALL=(v4.0 v4.1 v4.2 v4.3)
_ver="${_a_ver:-${api_version:-}}"
if [[ -z "$_ver" || "${_ver,,}" == "all" ]]; then
  VERSIONS=("${API_VERSIONS_ALL[@]}")
else
  [[ "$_ver" == v* ]] || _ver="v${_ver}"
  case "$_ver" in
    v4.0|v4.1|v4.2|v4.3) ;;
    *) echo "ERROR: unsupported api_version '$_ver' (supported: v4.0 .. v4.3)" >&2; exit 2 ;;
  esac
  VERSIONS=("$_ver")
fi

[[ -n "$NUTANIX_HOST" ]] || { echo "ERROR: NUTANIX_HOST is required (--ip / host=)"     >&2; exit 2; }
[[ -n "$USERNAME"     ]] || { echo "ERROR: USERNAME is required (--username / username=)" >&2; exit 2; }
[[ -n "$PASSWORD"     ]] || { echo "ERROR: PASSWORD is required (--password / password=)" >&2; exit 2; }

BASE="https://${NUTANIX_HOST}:${NUTANIX_PORT}"

CURL_K=()
[[ "$NUTANIX_INSECURE" == "true" ]] && CURL_K+=(-k)

TMP="$(mktemp -d)"
COOKIE_JAR="${TMP}/cookies.txt"
trap 'rm -rf "$TMP"' EXIT

AUTH_MODE="basic"     # the mode actually in force; authenticate() sets it
PASS=0
FAIL=0

# ─── Endpoint table ──────────────────────────────────────────────────────────
# The eight URLs under test, rebuilt for each API version in the sweep.
build_urls() {
  local v="$1"
  vms="${BASE}/api/vmm/${v}/ahv/config/vms"
  subnets="${BASE}/api/networking/${v}/config/subnets"
  tasks="${BASE}/api/prism/${v}/config/tasks"
  securitygroups="${BASE}/api/microseg/${v}/config/policies"
  vpcs="${BASE}/api/networking/${v}/config/vpcs"
  floatingips="${BASE}/api/networking/${v}/config/floating-ips"
  volumegroups="${BASE}/api/volumes/${v}/config/volume-groups"
  recoverypoints="${BASE}/api/dataprotection/${v}/config/recovery-points"
}

# The login probe lives in IAM, which ships a v4.0 spec regardless of the
# resource API version being swept.
IAM_PROBE="${BASE}/api/iam/v4.0/authn/users?\$limit=1"
PRISM_SESSION="${BASE}/PrismGateway/services/rest/v1/session"

# ─── Output helpers ──────────────────────────────────────────────────────────
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; PASS=$((PASS+1)); }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*"; FAIL=$((FAIL+1)); }
hdr()   { printf '\n\033[1;36m── %s ──\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }
warn()  { printf '\033[33m! %s\033[0m\n' "$*"; }

is_dry_run() { [[ "$CURL_DRY_RUN" == "1" ]]; }

# jget DOTTED.PATH — pull a field out of the JSON arriving on stdin ('' if absent).
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

new_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}

# Hide credential material in the verbose trace unless --show-secrets.
_mask() {
  if [[ "$SHOW_SECRETS" == "1" ]]; then
    cat
  else
    sed -E '
      /^[Aa]uthorization:/ s/(:[[:space:]]*[A-Za-z]+[[:space:]]+).*/\1********/
      /^[Cc]ookie:/        s/=[^;[:space:]]+/=********/g
      /^[Ss]et-[Cc]ookie:/ s/=[^;[:space:]]+/=********/
    '
  fi
}

# Pretty-print a JSON string, capped at MAX_BODY_LINES lines.
_pretty() {
  local doc="$1" out
  if command -v jq >/dev/null 2>&1; then
    out="$(printf '%s' "$doc" | jq . 2>/dev/null)"
  else
    out="$(printf '%s' "$doc" | python3 -m json.tool 2>/dev/null)"
  fi
  [[ -n "$out" ]] || out="$doc"
  if [[ "$MAX_BODY_LINES" -gt 0 ]]; then
    local n; n="$(printf '%s\n' "$out" | wc -l)"
    if [[ "$n" -gt "$MAX_BODY_LINES" ]]; then
      printf '%s\n' "$out" | head -n "$MAX_BODY_LINES"
      printf '... (%d more lines; raise MAX_BODY_LINES to see all)\n' "$((n - MAX_BODY_LINES))"
      return
    fi
  fi
  printf '%s\n' "$out"
}

# Echo a curl command for --dry-run, with the password blanked out.
_print_curl() {
  local s
  s="$(printf 'curl '; printf '%q ' "$@")"
  if [[ "$SHOW_SECRETS" != "1" && -n "$PASSWORD" ]]; then
    s="${s//$PASSWORD/********}"
  fi
  printf '%s\n' "$s"
}

# ─── HTTP primitive ──────────────────────────────────────────────────────────
# req METHOD URL [BODY] [EXTRA...]
#   Sets RESP_CODE / RESP_BODY / RESP_HEADERS / RESP_ETAG.
#   Auth follows $AUTH_MODE. Recognised EXTRA markers (everything else is
#   passed through to curl):
#     --auth-basic     force Basic auth for this one call
#     --auth-cookie    force cookie auth for this one call
#     --save-cookies   also write the cookie jar (-c), i.e. this is the login
#     --no-trace       suppress the verbose trace (used by task polling)
req() {
  local method="$1" url="$2" body=""
  shift 2
  if [[ $# -gt 0 && "${1:-}" != -* ]]; then body="$1"; shift; fi

  local auth="$AUTH_MODE" save=0 no_trace=0 extra=() a
  for a in "$@"; do
    case "$a" in
      --auth-basic)   auth="basic"  ;;
      --auth-cookie)  auth="cookie" ;;
      --save-cookies) save=1        ;;
      --no-trace)     no_trace=1    ;;
      *)              extra+=("$a") ;;
    esac
  done

  local args=( -sS -o "$TMP/body" -D "$TMP/rsphdr" -w '%{http_code}' -v
               -X "$method" -H 'Accept: application/json' )
  ((${#CURL_K[@]})) && args+=("${CURL_K[@]}")

  if [[ "$auth" == "basic" ]]; then
    # auth=basic — the Basic header goes out on this (and every) request.
    args+=( -u "${USERNAME}:${PASSWORD}" )
  else
    # auth=cookie — cookie jar only; no Authorization header is produced.
    args+=( -b "$COOKIE_JAR" )
  fi
  [[ "$save" == "1" ]] && args+=( -c "$COOKIE_JAR" )
  [[ -n "$body" ]] && args+=( -H 'Content-Type: application/json' -d "$body" )
  ((${#extra[@]})) && args+=("${extra[@]}")

  REQ_METHOD="$method"; REQ_URL="$url"; REQ_BODY="$body"; REQ_AUTH="$auth"

  if is_dry_run; then
    _print_curl "${args[@]}" "$url"
    RESP_CODE="000"
    # A synthetic task document so the write flow keeps walking its steps and
    # prints every command instead of stopping at the first missing extId.
    RESP_BODY='{"data":{"extId":"DRY-RUN-TASK-EXTID","status":"SUCCEEDED","entitiesAffected":[{"extId":"DRY-RUN-ENTITY-EXTID"}]}}'
    RESP_HEADERS=""; RESP_ETAG=""
    return 0
  fi

  : >"$TMP/trace"
  RESP_CODE="$(curl "${args[@]}" "$url" 2>"$TMP/trace")" || RESP_CODE="curl-error"
  RESP_BODY="$(cat "$TMP/body" 2>/dev/null)"
  RESP_HEADERS="$(tr -d '\r' <"$TMP/rsphdr" 2>/dev/null)"
  RESP_ETAG="$(printf '%s\n' "$RESP_HEADERS" | sed -n 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//p' | tail -n1)"

  [[ "$no_trace" == "1" ]] && return 0
  [[ "$VERBOSE" == "1" ]] && _trace
  return 0
}

# Full request/response detail, straight from curl's own -v trace.
_trace() {
  {
    printf '  ┌─ REQUEST ──────────────────────────────────────────────────\n'
    printf '  │ %s %s\n' "$REQ_METHOD" "$REQ_URL"
    printf '  │ auth: %s\n' "$REQ_AUTH"
    printf '  │ headers:\n'
    sed -n 's/^> //p' "$TMP/trace" | tr -d '\r' | grep -v '^[[:space:]]*$' \
      | _mask | sed 's/^/  │   /'
    if [[ -n "$REQ_BODY" ]]; then
      printf '  │ body:\n'
      _pretty "$REQ_BODY" | sed 's/^/  │   /'
    fi
    printf '  ├─ RESPONSE ─────────────────────────────────────────────────\n'
    printf '  │ status: %s\n' "$RESP_CODE"
    printf '  │ headers:\n'
    if [[ -n "$RESP_HEADERS" ]]; then
      printf '%s\n' "$RESP_HEADERS" | grep -v '^[[:space:]]*$' | _mask | sed 's/^/  │   /'
    else
      printf '  │   <none>\n'
    fi
    printf '  │ body:\n'
    if [[ -n "$RESP_BODY" ]]; then
      _pretty "$RESP_BODY" | sed 's/^/  │   /'
    else
      printf '  │   <empty>\n'
    fi
    printf '  └────────────────────────────────────────────────────────────\n'
  } >&2
}

# ─── Result reporting ────────────────────────────────────────────────────────
# Non-verbose mode shows exactly the URL and the HTTP response; verbose mode
# has already dumped the full exchange above, so this stays the one-line verdict.
_line() { printf '%-16s %-6s %s → HTTP %s%s' "$1" "$2" "$3" "$4" "${5:-}"; }

# report LABEL EXPECTED [EXTRA] — verdict for the request req() just made.
report() {
  local label="$1" expected="$2" extra="${3:-}"
  if is_dry_run; then return 0; fi
  if [[ "$RESP_CODE" == "$expected" ]]; then
    green "$(_line "$label" "$REQ_METHOD" "$REQ_URL" "$RESP_CODE" "$extra")"
  else
    red "$(_line "$label" "$REQ_METHOD" "$REQ_URL" "$RESP_CODE" " (expected ${expected})")"
    [[ "$VERBOSE" != "1" && -n "$RESP_BODY" ]] && dim "                 ${RESP_BODY:0:220}"
  fi
}

# check LABEL METHOD URL EXPECTED [BODY] [EXTRA...]
check() {
  local label="$1" method="$2" url="$3" expected="$4" body=""
  shift 4
  if [[ $# -gt 0 && "${1:-}" != -* ]]; then body="$1"; shift; fi
  req "$method" "$url" "$body" "$@"
  report "$label" "$expected"
}

# get_list LABEL URL — GET a collection, report status plus the item count.
get_list() {
  local label="$1" url="$2" n=""
  req GET "$url"
  if is_dry_run; then return 0; fi
  if [[ "$RESP_CODE" == "200" ]]; then
    n="$(printf '%s' "$RESP_BODY" | jget metadata.totalAvailableResults)"
    report "$label" 200 "${n:+ (n=${n})}"
  else
    report "$label" 200
  fi
}

# ─── Authentication ──────────────────────────────────────────────────────────
# Names of the cookies currently in the jar (values are never printed here).
cookie_names() {
  awk -F'\t' 'NF >= 7 {printf "%s%s", sep, $6; sep=", "}' "$COOKIE_JAR" 2>/dev/null
}

authenticate() {
  hdr "Authentication — auth=${AUTH_REQUESTED}"

  if is_dry_run; then
    AUTH_MODE="$AUTH_REQUESTED"
    dim "  dry-run: skipping the live login; requests below use auth=${AUTH_MODE}"
    return 0
  fi

  # ── auth=basic: USERNAME/PASSWORD form the Basic header sent on ALL URLs ──
  if [[ "$AUTH_REQUESTED" == "basic" ]]; then
    AUTH_MODE="basic"
    req GET "$IAM_PROBE" --auth-basic
    if [[ "$RESP_CODE" == "200" ]]; then
      green "Basic auth accepted for '${USERNAME}' — Basic header sent on every request"
    else
      red "Basic auth probe failed (HTTP ${RESP_CODE}) — check host/port/username/password"
      return 1
    fi
    return 0
  fi

  # ── auth=cookie: Basic ONCE to mint the session cookie, cookie-only after ──
  AUTH_MODE="basic"
  dim "  step 1/2: Basic auth login as '${USERNAME}' @ ${BASE}"
  req GET "$IAM_PROBE" --auth-basic --save-cookies
  local code="$RESP_CODE"

  if [[ "$code" != "200" ]]; then
    dim "  IAM probe returned ${code}; retrying via the PrismGateway session endpoint"
    req POST "$PRISM_SESSION" '{}' --auth-basic --save-cookies
    code="$RESP_CODE"
  fi

  if [[ "$code" != "200" ]]; then
    red "login failed (HTTP ${code}) — check host/port/username/password"
    return 1
  fi

  local names; names="$(cookie_names)"
  if [[ -z "$names" ]]; then
    red "login returned HTTP 200 but no session cookie was set — cannot run auth=cookie"
    return 1
  fi
  green "session cookie acquired: ${names}"

  # From here on the Basic header is never sent again.
  AUTH_MODE="cookie"
  dim "  step 2/2: re-probing with the cookie only (no Authorization header)"
  req GET "$IAM_PROBE"
  if [[ "$RESP_CODE" == "200" ]]; then
    green "cookie-only request accepted — Basic header retired for the rest of the run"
  else
    red "cookie-only probe returned HTTP ${RESP_CODE}"
    warn "staying in cookie-only mode (no Basic fallback) so the results below"
    warn "reflect what cookie auth actually does on this cluster"
  fi
  return 0
}

# ─── Task polling ────────────────────────────────────────────────────────────
# poll_task TASK_EXT_ID → 0 on SUCCEEDED; sets TASK_STATUS and TASK_ENTITY.
poll_task() {
  local tid="$1" i
  TASK_STATUS=""; TASK_ENTITY=""
  if is_dry_run; then
    TASK_STATUS="SUCCEEDED"; TASK_ENTITY="DRY-RUN-ENTITY-EXTID"; return 0
  fi
  for i in $(seq 1 "${TASK_POLL_TRIES:-30}"); do
    req GET "${tasks}/${tid}" --no-trace
    TASK_STATUS="$(printf '%s' "$RESP_BODY" | jget data.status)"
    case "$TASK_STATUS" in
      SUCCEEDED)
        TASK_ENTITY="$(printf '%s' "$RESP_BODY" | jget data.entitiesAffected.0.extId)"
        return 0 ;;
      FAILED|CANCELED|CANCELLED)
        return 1 ;;
    esac
    sleep "${TASK_POLL_INTERVAL:-2}"
  done
  return 1
}

# ─── Banner / summary ────────────────────────────────────────────────────────
banner() {
  printf '╔══════════════════════════════════════════════════════════╗\n'
  printf '║   %-55s║\n' "${SCRIPT_TITLE}"
  printf '║   Target:   %-45s║\n' "${NUTANIX_HOST}:${NUTANIX_PORT}"
  printf '║   User:     %-45s║\n' "${USERNAME}"
  printf '║   Auth:     %-45s║\n' "${AUTH_REQUESTED}"
  printf '║   Versions: %-45s║\n' "${VERSIONS[*]}"
  printf '║   Mode:     %-45s║\n' "$([[ "$VERBOSE" == 1 ]] && echo verbose || echo non-verbose)"
  printf '╚══════════════════════════════════════════════════════════╝\n'
  is_dry_run && dim "  dry-run: printing curl commands, issuing no requests"
}

summary() {
  echo ""
  echo "════════════════════════════════════════════════════════"
  printf "  Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m  (auth=%s, versions: %s)\n" \
    "$PASS" "$FAIL" "$AUTH_REQUESTED" "${VERSIONS[*]}"
  echo "════════════════════════════════════════════════════════"
  exit "$FAIL"
}
