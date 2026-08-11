#!/usr/bin/env bash
# ─── Libcloud REST API RBAC + Provisioning Test ──────────────────────────────
# Comprehensive role-based access control verification for the libcloud REST API.
# Tests every pre-configured user from dex/generated/dex.env against both AWS and
# Nutanix endpoints, validates cross-tenant isolation, and optionally performs
# actual cloud provisioning using Vault-backed credentials.
#
# Usage:
#   chmod +x scripts/rest-api-test.sh
#   ./scripts/rest-api-test.sh [base_url] [container_name]
#
# Defaults: URL http://localhost:8765, container libcloud-rest-api
#
# Env vars (all optional):
#   BEARER_TOKEN       If set and SKIP_RBAC=1, runs legacy single-token test.
#   SKIP_LOGIN_TEST    Set to 1 to skip the login-attempt test.
#   SKIP_RBAC          Set to 1 to skip multi-user RBAC matrix (sections 5-8).
#   SKIP_PROVISION     Set to 1 to skip provisioning + Vault checks.
#   PROVISION          Set to 1 to actually create cloud resources.
#   TEARDOWN_VMS       Set to 1 to clean up provisioned VMs after test.
#   VERBOSE            Set to 1 for detailed HTTP request/response logging.
#   LIBCLOUD_USER      Override the default user for legacy single-token mode.
#   LIBCLOUD_PASSWORD  Override the default password for legacy single-token mode.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Auto-detect repo root: walk up until we find .env (or stay at SCRIPT_DIR if we
# are already there). This makes the script location-independent — it works whether
# invoked via a symlink at the repo root, or directly from libcloud.rest/scripts/.
_REPO_ROOT="$SCRIPT_DIR"
while [[ "$_REPO_ROOT" != "/" ]]; do
  if [[ -f "${_REPO_ROOT}/.env" ]]; then
    break
  fi
  _REPO_ROOT="$(dirname "$_REPO_ROOT")"
done
REPO_ROOT="$_REPO_ROOT"
unset _REPO_ROOT

# ── Resolve common.sh (test_script/scripts/common.sh) ────────────────────────
# common.sh loads .env + dex/generated/dex.env + openfga_postgres/generated/fga.env
# and provides idp_login, build_aws_connection_param, build_nutanix_connection_param,
# libcloud_api, libcloud_me, libcloud_connection_test, connection_json, curl_http,
# teardown_libcloud_vms, json_pretty, and the password resolver.
COMMON_SH="${REPO_ROOT}/test_script/scripts/common.sh"
if [[ -f "$COMMON_SH" ]]; then
  # shellcheck source=../../test_script/scripts/common.sh
  source "$COMMON_SH"
else
  # Fallback: load env files ourselves when common.sh is not available.
  _load_env_file() {
    local file="$1"
    local force="${2:-0}"
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      [[ "$line" != *=* ]] && continue
      local key="${line%%=*}"
      local val="${line#*=}"
      if [[ "$force" == "1" ]] || [[ -z "${!key:-}" ]]; then
        export "${key}=${val}"
      fi
    done < "$file"
  }
  _load_env_file "${REPO_ROOT}/.env"
  _load_env_file "${REPO_ROOT}/dex/generated/dex.env" 1
  _load_env_file "${REPO_ROOT}/openfga_postgres/generated/fga.env" 1
fi

# Also load Vault env for credential checks.
_vault_env="${REPO_ROOT}/vault/generated/vault.env"
if [[ -f "$_vault_env" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" != *=* ]] && continue
    _key="${line%%=*}"
    _val="${line#*=}"
    [[ -z "${!_key:-}" ]] && export "${_key}=${_val}"
  done < "$_vault_env"
fi

BASE="${1:-http://localhost:8765}"
CONTAINER="${2:-libcloud-rest-api}"

# ── Skip / feature flags ─────────────────────────────────────────────────────
SKIP_LOGIN_TEST="${SKIP_LOGIN_TEST:-0}"
SKIP_RBAC="${SKIP_RBAC:-0}"
SKIP_PROVISION="${SKIP_PROVISION:-0}"
PROVISION="${PROVISION:-0}"
TEARDOWN_VMS="${TEARDOWN_VMS:-0}"

# ── Output helpers ───────────────────────────────────────────────────────────
PASS=0
FAIL=0
SKIP=0

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; (( ++PASS )); }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*"; (( ++FAIL )); }
header() { printf '\n\033[1;36m── %s ──\033[0m\n' "$*"; }
skip()   { printf '\033[33m⊘ %s\033[0m\n' "$*"; (( ++SKIP )); }

# check <desc> <expected_code> [curl args...]
check() {
  local desc="$1" expected="$2"
  shift 2
  local code
  code=$(curl -s -o /tmp/rest_test_resp.json -w '%{http_code}' "$@" 2>&1) || true
  if [[ "$code" == "$expected" ]]; then
    green "$desc (HTTP $code)"
  else
    red "$desc — expected $expected, got $code"
    head -c 400 /tmp/rest_test_resp.json 2>/dev/null || true
    echo ""
  fi
}

# check_body <desc> <expected_code> <grep pattern> [curl args...]
check_body() {
  local desc="$1" expected="$2" pattern="$3"
  shift 3
  local code
  code=$(curl -s -o /tmp/rest_test_resp.json -w '%{http_code}' "$@" 2>&1) || true
  if [[ "$code" == "$expected" ]] && grep -q "$pattern" /tmp/rest_test_resp.json; then
    green "$desc (HTTP $code, body matches '$pattern')"
  elif [[ "$code" != "$expected" ]]; then
    red "$desc — expected HTTP $expected, got $code"
  else
    red "$desc — HTTP $code but body missing '$pattern'"
    head -c 400 /tmp/rest_test_resp.json; echo ""
  fi
}

# check_code_pattern <desc> <expected_pattern> [curl args...]
# expected_pattern is a grep -E regex matched against the HTTP status code.
check_code_pattern() {
  local desc="$1" expected_pattern="$2"
  shift 2
  local code
  code=$(curl -s -o /tmp/rest_test_resp.json -w '%{http_code}' "$@" 2>&1) || true
  echo "$code" > /tmp/rest_rbac_http_code
  if echo "$code" | grep -qE "^(${expected_pattern})$"; then
    green "$desc (HTTP $code)"
  else
    red "$desc — expected pattern [$expected_pattern], got $code"
    head -c 400 /tmp/rest_test_resp.json 2>/dev/null || true
    echo ""
  fi
}

# ── RBAC helpers ─────────────────────────────────────────────────────────────

# Authenticate a specific user via Dex OIDC. Sets global ACCESS_TOKEN.
# Reuses common.sh's idp_login function if available; otherwise calls idp_login.py directly.
auth_user() {
  local user="$1" password="$2"
  : "${password:?Password required for user ${user}}"

  export LIBCLOUD_USER="$user"
  export LIBCLOUD_PASSWORD="$password"

  if declare -f idp_login >/dev/null 2>&1; then
    # Use common.sh's idp_login which handles caching + refresh.
    if idp_login "$user" "$password" 2>/dev/null && [[ -n "${ACCESS_TOKEN:-}" ]]; then
      green "Authenticated as ${user} (token ${#ACCESS_TOKEN} chars)"
      return 0
    fi
    # Retry once with fresh login (clear cache).
    local cache_file="${REPO_ROOT}/generated/tokens/${user}.json"
    rm -f "$cache_file" 2>/dev/null || true
    if idp_login "$user" "$password" 2>/dev/null && [[ -n "${ACCESS_TOKEN:-}" ]]; then
      green "Authenticated as ${user} (token ${#ACCESS_TOKEN} chars, retry)"
      return 0
    fi
  else
    # Direct call to idp_login.py (fallback when common.sh not sourced).
    local token
    token=$(LIBCLOUD_USER="$user" LIBCLOUD_PASSWORD="$password" \
      python3 "${REPO_ROOT}/test_script/scripts/idp_login.py" 2>/dev/null) || true
    if [[ -n "$token" ]]; then
      ACCESS_TOKEN="$token"
      green "Authenticated as ${user} (token ${#ACCESS_TOKEN} chars)"
      return 0
    fi
  fi

  red "Authentication failed for ${user}"
  ACCESS_TOKEN=""
  return 1
}

# Build provider connection param. Sets CONNECTION_PARAM.
build_provider_connection() {
  local provider="$1"
  if declare -f build_aws_connection_param >/dev/null 2>&1; then
    case "$provider" in
      aws)     build_aws_connection_param "${AWS_REGION:-ap-southeast-1}" ;;
      nutanix) build_nutanix_connection_param ;;
      *)       echo "ERROR: unknown provider $provider" >&2; return 1 ;;
    esac
  else
    # Fallback: build connection JSON directly.
    case "$provider" in
      aws)
        local binding="${LIBCLOUD_AWS_AUTH_BINDING:-aws}"
        CONNECTION_PARAM=$(AWS_REGION_VAL="${AWS_REGION:-ap-southeast-1}" AWS_BINDING_VAL="$binding" python3 -c "
import json, os
print(json.dumps({
    'provider': 'aws',
    'config': {'region': os.environ['AWS_REGION_VAL'], 'secure': True},
    'auth_binding': os.environ['AWS_BINDING_VAL'],
}, separators=(',', ':')))
") ;;
      nutanix)
        local binding="${LIBCLOUD_NTNX_AUTH_BINDING:-nutanix}"
        CONNECTION_PARAM=$(NTNX_HOST="${NUTANIX_HOST:-host.docker.internal}" \
          NTNX_PORT="${NUTANIX_PORT:-9440}" \
          NTNX_API_VERSION="${NUTANIX_API_VERSION:-v4.0}" \
          NTNX_VERIFY_SSL="${NUTANIX_VERIFY_SSL:-false}" \
          NTNX_BINDING_VAL="$binding" python3 -c "
import json, os
print(json.dumps({
    'provider': 'nutanix',
    'config': {
        'host': os.environ['NTNX_HOST'],
        'port': int(os.environ['NTNX_PORT']),
        'secure': True,
        'api_version': os.environ['NTNX_API_VERSION'],
        'verify_ssl_cert': os.environ['NTNX_VERIFY_SSL'].lower() in ('1','true','yes'),
    },
    'auth_binding': os.environ['NTNX_BINDING_VAL'],
}, separators=(',', ':')))
") ;;
      *) echo "ERROR: unknown provider $provider" >&2; return 1 ;;
    esac
  fi
  export CONNECTION_PARAM
}

# rbac_get <desc> <provider> <path> <expected_code_pattern>
rbac_get() {
  local desc="$1" provider="$2" path="$3" expected_pattern="$4"
  build_provider_connection "$provider" || { red "$desc — failed to build connection"; return 1; }

  check_code_pattern "$desc" "$expected_pattern" \
    -H "Authorization: Bearer ${ACCESS_TOKEN:-}" \
    -H "Accept: application/json" \
    -H "X-Provider-Connection: ${CONNECTION_PARAM}" \
    "$BASE$path"
}

# rbac_post <desc> <provider> <path> <body> <expected_code_pattern>
rbac_post() {
  local desc="$1" provider="$2" path="$3" body="$4" expected_pattern="$5"
  build_provider_connection "$provider" || { red "$desc — failed to build connection"; return 1; }

  check_code_pattern "$desc" "$expected_pattern" \
    -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN:-}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "X-Provider-Connection: ${CONNECTION_PARAM}" \
    -d "$body" \
    "$BASE$path"
}

# rbac_delete <desc> <provider> <path> <expected_code_pattern>
rbac_delete() {
  local desc="$1" provider="$2" path="$3" expected_pattern="$4"
  build_provider_connection "$provider" || { red "$desc — failed to build connection"; return 1; }

  check_code_pattern "$desc" "$expected_pattern" \
    -X DELETE \
    -H "Authorization: Bearer ${ACCESS_TOKEN:-}" \
    -H "Accept: application/json" \
    -H "X-Provider-Connection: ${CONNECTION_PARAM}" \
    "$BASE$path"
}

# rbac_connection_test <desc> <provider> <expected_code_pattern>
rbac_connection_test() {
  local desc="$1" provider="$2" expected_pattern="$3"
  build_provider_connection "$provider" || { red "$desc — failed to build connection"; return 1; }

  local conn_json
  if declare -f connection_json >/dev/null 2>&1; then
    conn_json=$(connection_json)
  else
    conn_json="$CONNECTION_PARAM"
  fi

  check_code_pattern "$desc" "$expected_pattern" \
    -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN:-}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "X-Provider-Connection: ${CONNECTION_PARAM}" \
    -d "$conn_json" \
    "$BASE/v1/connections:test"
}

# rbac_with_retry <user> <function> [args...]
# If a test gets 401 unexpectedly, re-login and retry once.
rbac_with_retry() {
  local user="$1"; shift

  "$@"
  local last_code
  last_code=$(cat /tmp/rest_rbac_http_code 2>/dev/null || echo "")

  if [[ "$last_code" == "401" ]]; then
    # Token may have expired — re-authenticate and retry.
    local pass_var
    case "$user" in
      superadmin)   pass_var="${LIBCLOUD_SUPERADMIN_PASSWORD:-}" ;;
      aws-owner)    pass_var="${LIBCLOUD_PASSWORD_AWS_OWNER:-}" ;;
      aws-admin)    pass_var="${LIBCLOUD_PASSWORD_AWS_ADMIN:-}" ;;
      aws-viewer)   pass_var="${LIBCLOUD_PASSWORD_AWS_VIEWER:-}" ;;
      ntnx-owner)   pass_var="${LIBCLOUD_PASSWORD_NTNX_OWNER:-}" ;;
      ntnx-admin)   pass_var="${LIBCLOUD_PASSWORD_NTNX_ADMIN:-}" ;;
      ntnx-viewer)  pass_var="${LIBCLOUD_PASSWORD_NTNX_VIEWER:-}" ;;
      cloud-denied) pass_var="${LIBCLOUD_PASSWORD_CLOUD_DENIED:-}" ;;
      *)            pass_var="${LIBCLOUD_PASSWORD:-}" ;;
    esac

    if [[ -n "$pass_var" ]]; then
      auth_user "$user" "$pass_var" && "$@"
      return $?
    fi
  fi
  return 0
}

# ── Vault helpers ────────────────────────────────────────────────────────────

check_vault_credentials() {
  local provider="$1"
  local vault_addr="${VAULT_ADDR:-http://localhost:8200}"
  local vault_token="${VAULT_ROOT_TOKEN:-${VAULT_TOKEN:-}}"

  if [[ -z "$vault_token" ]]; then
    skip "Vault check ($provider): no VAULT_ROOT_TOKEN or VAULT_TOKEN available"
    return 1
  fi

  local code
  code=$(curl -s -o /tmp/vault_check.json -w '%{http_code}' \
    -H "X-Vault-Token: ${vault_token}" \
    "${vault_addr}/v1/secret/data/libcloud/${provider}" 2>&1) || true

  if [[ "$code" == "200" ]]; then
    green "Vault has credentials for provider=${provider}"
    return 0
  elif [[ "$code" == "404" ]]; then
    red "Vault missing credentials for provider=${provider} (HTTP 404 — run set_tenant_credentials.py)"
    return 1
  else
    red "Vault unreachable or error for provider=${provider} (HTTP $code)"
    return 1
  fi
}

# ── User role → expected HTTP code patterns ──────────────────────────────────
# READ_OK: 200 for allowed, 403 for denied (cross-tenant or no tenant binding)
# WRITE_OK: 200|201|202|422|404 for allowed (422 = validation of bad body, 404 = not found, both mean auth passed), 403 for denied
# CONN_OK: 200 for allowed, 403 for denied. For Nutanix emulator may also be 502|503.

aws_role_expect() {
  local user="$1" what="$2"
  case "$user" in
    superadmin)
      case "$what" in read) echo "200";; write) echo "403";; conn) echo "200";; esac ;;
    aws-owner|aws-admin)
      case "$what" in read) echo "200";; write) echo "200|201|202|422|404|400";; conn) echo "200";; esac ;;
    aws-viewer)
      case "$what" in read) echo "200";; write) echo "403";; conn) echo "200";; esac ;;
    ntnx-owner|ntnx-admin|ntnx-viewer|cloud-denied)
      case "$what" in read) echo "403";; write) echo "403";; conn) echo "403";; esac ;;
    *)  echo "403" ;;
  esac
}

nutanix_role_expect() {
  local user="$1" what="$2"
  case "$user" in
    superadmin)
      case "$what" in read) echo "200";; write) echo "403";; conn) echo "200|502|503";; esac ;;
    ntnx-owner|ntnx-admin)
      case "$what" in read) echo "200";; write) echo "200|201|202|422|404|400";; conn) echo "200|502|503";; esac ;;
    ntnx-viewer)
      case "$what" in read) echo "200";; write) echo "403";; conn) echo "200|502|503";; esac ;;
    aws-owner|aws-admin|aws-viewer|cloud-denied)
      case "$what" in read) echo "403";; write) echo "403";; conn) echo "403";; esac ;;
    *)  echo "403" ;;
  esac
}

# ═══════════════════════════════════════════════════════════════════════════════
#  BEGIN TEST SECTIONS
# ═══════════════════════════════════════════════════════════════════════════════

echo "╔══════════════════════════════════════════════════════╗"
echo "║   Libcloud REST API Test (RBAC + Provisioning)      ║"
printf  "║   Target: %-43s║\n" "$BASE"
echo "╚══════════════════════════════════════════════════════╝"

# ── 0. Container check ───────────────────────────────────────────────────────
header "0. Docker container"
if docker ps --filter "name=^/${CONTAINER}$" --filter status=running -q 2>/dev/null | grep -q .; then
  green "Container $CONTAINER is running"
else
  red "Container $CONTAINER is NOT running (docker ps found nothing)"
fi

# ── 1. Public endpoints (no auth required) ───────────────────────────────────
header "1. Public endpoints (no auth)"

check_body "Health endpoint"          200 '"status"' "$BASE/health"
check_body "Health returns 'ok'"     200 '"ok"'     "$BASE/health"

check_body "List providers"          200 '"data"'   "$BASE/v1/providers"
check_body "Providers has AWS"       200 '"ec2"'    "$BASE/v1/providers"
check_body "Providers has Nutanix"   200 '"nutanix"' "$BASE/v1/providers"

# ── 2. Auth: unauthenticated requests (expect 401) ───────────────────────────
header "2. Authorized routes reject unauthenticated requests"

check "GET /v1/compute/nodes — no token"  401 "$BASE/v1/compute/nodes"
check "GET /v1/compute/images — no token" 401 "$BASE/v1/compute/images"
check "GET /v1/compute/sizes — no token"  401 "$BASE/v1/compute/sizes"
check "GET /v1/compute/locations — no token" 401 "$BASE/v1/compute/locations"
check "GET /v1/compute/volumes — no token"   401 "$BASE/v1/compute/volumes"
check "GET /v1/compute/snapshots — no token" 401 "$BASE/v1/compute/snapshots"
check "GET /v1/compute/key-pairs — no token" 401 "$BASE/v1/compute/key-pairs"
check "GET /v1/compute/networks — no token"  401 "$BASE/v1/compute/networks"
check "GET /v1/compute/subnets — no token"   401 "$BASE/v1/compute/subnets"
check "GET /v1/compute/security-groups — no token" 401 "$BASE/v1/compute/security-groups"
check "GET /v1/compute/storage-containers — no token" 401 "$BASE/v1/compute/storage-containers"
check "POST /v1/connections:test — no token" 401 "$BASE/v1/connections:test" -X POST
check "GET /v1/storage/buckets — no token"   401 "$BASE/v1/storage/buckets"

# ── 3. Auth: /v1/auth/me with bogus token ────────────────────────────────────
header "3. /v1/auth/me (invalid token)"

check "GET /v1/auth/me — no token"           401 \
  -H 'Accept: application/json' "$BASE/v1/auth/me"
check "GET /v1/auth/me — bogus Bearer"        401 \
  -H 'Authorization: Bearer not-a-real-token' \
  -H 'Accept: application/json' "$BASE/v1/auth/me"

# ── 4. /v1/auth/login (local password auth; may be disabled) ─────────────────
header "4. /v1/auth/login"

if [[ "${SKIP_LOGIN_TEST:-0}" == "1" ]]; then
  skip "SKIP_LOGIN_TEST=1 — skipping login tests"
else
  LOGIN_CODE=$(curl -s -o /tmp/rest_test_resp.json -w '%{http_code}' \
    -X POST "$BASE/v1/auth/login" -H 'Content-Type: application/json' -d '{}' 2>&1) || true
  if [[ "$LOGIN_CODE" == "422" ]]; then
    green "/v1/auth/login — local auth enabled, rejected empty body (HTTP 422)"
  elif [[ "$LOGIN_CODE" == "404" ]]; then
    skip "/v1/auth/login — auth_mode is OIDC, login returned 404 (expected)"
  elif [[ "$LOGIN_CODE" == "200" ]]; then
    red "/v1/auth/login — accepted empty body (unexpected 200)"
  else
    green "/v1/auth/login — endpoint alive (HTTP $LOGIN_CODE)"
  fi

  check_body "Login with no fields → 422" 422 '"detail"' \
    -X POST "$BASE/v1/auth/login" \
    -H 'Content-Type: application/json' \
    -d '{}'
fi

# ── 4b. Legacy single-token authenticated test (backward compat) ─────────────
# When BEARER_TOKEN is explicitly set and RBAC is skipped (or no RBAC users
# are available), run the old-style single-token authenticated test so existing
# workflows (e.g. manual token injection) continue to work.
header "4b. Authenticated endpoints (legacy single-token mode)"

if [[ -n "${BEARER_TOKEN:-}" ]]; then
  if [[ "${SKIP_RBAC:-0}" == "1" ]] || [[ -z "${LIBCLOUD_SUPERADMIN_PASSWORD:-}${LIBCLOUD_PASSWORD_AWS_OWNER:-}" ]]; then
    ACCESS_TOKEN="$BEARER_TOKEN"
    AUTH=(-H "Authorization: Bearer $BEARER_TOKEN")

    check_body "GET /v1/auth/me" 200 '"username"' \
      "${AUTH[@]}" "$BASE/v1/auth/me"

    check "POST /v1/auth/logout" 200 \
      "${AUTH[@]}" -X POST "$BASE/v1/auth/logout"

    check_body "GET /v1/compute/nodes" 200 '"data"' \
      "${AUTH[@]}" -H 'Accept: application/json' "$BASE/v1/compute/nodes"

    check_body "GET /v1/compute/images" 200 '"data"' \
      "${AUTH[@]}" "$BASE/v1/compute/images"

    check_body "GET /v1/compute/sizes" 200 '"data"' \
      "${AUTH[@]}" "$BASE/v1/compute/sizes"

    check_body "GET /v1/compute/locations" 200 '"data"' \
      "${AUTH[@]}" "$BASE/v1/compute/locations"

    # Connection test with provider header (using env-default auth_binding).
    check "POST /v1/connections:test with connection header" 200 \
      "${AUTH[@]}" \
      -H 'Content-Type: application/json' \
      -H 'X-Provider-Connection: {"provider":"aws","auth_binding":"aws"}' \
      -X POST "$BASE/v1/connections:test"
  else
    skip "BEARER_TOKEN set but SKIP_RBAC=0 with RBAC users available — using multi-user RBAC instead"
  fi
elif [[ "${SKIP_RBAC:-0}" == "1" ]]; then
  skip "BEARER_TOKEN not set and SKIP_RBAC=1 — skipping authenticated endpoint tests"
  echo "       Set BEARER_TOKEN or use SKIP_RBAC=0 for multi-user RBAC testing."
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  RBAC MATRIX SECTIONS (5-8): multi-user auth + per-role endpoint verification
# ═══════════════════════════════════════════════════════════════════════════════

# ── 5. Multi-user authentication ─────────────────────────────────────────────
header "5. Multi-user authentication (Dex OIDC)"

declare -A USER_TOKENS
declare -a RBAC_USERS=(
  "superadmin:${LIBCLOUD_SUPERADMIN_PASSWORD:-}"
  "aws-owner:${LIBCLOUD_PASSWORD_AWS_OWNER:-}"
  "aws-admin:${LIBCLOUD_PASSWORD_AWS_ADMIN:-}"
  "aws-viewer:${LIBCLOUD_PASSWORD_AWS_VIEWER:-}"
  "ntnx-owner:${LIBCLOUD_PASSWORD_NTNX_OWNER:-}"
  "ntnx-admin:${LIBCLOUD_PASSWORD_NTNX_ADMIN:-}"
  "ntnx-viewer:${LIBCLOUD_PASSWORD_NTNX_VIEWER:-}"
  "cloud-denied:${LIBCLOUD_PASSWORD_CLOUD_DENIED:-}"
)

if [[ "${SKIP_RBAC:-0}" == "1" ]]; then
  skip "SKIP_RBAC=1 — skipping multi-user RBAC authentication"
else
  AUTH_OK=0
  AUTH_FAIL=0
  for entry in "${RBAC_USERS[@]}"; do
    user="${entry%%:*}"
    pass="${entry#*:}"
    if [[ -z "$pass" ]]; then
      skip "User ${user}: no password available (run ./setup.sh)"
      continue
    fi
    # Save the current ACCESS_TOKEN so we can restore it.
    _saved_token="${ACCESS_TOKEN:-}"
    if auth_user "$user" "$pass"; then
      USER_TOKENS["$user"]="${ACCESS_TOKEN}"
      (( ++AUTH_OK ))
    else
      (( ++AUTH_FAIL ))
    fi
    ACCESS_TOKEN="${_saved_token}"
  done
  echo ""
  printf "  Auth summary: %d succeeded, %d failed\n" "$AUTH_OK" "$AUTH_FAIL"
  if [[ "$AUTH_FAIL" -gt 0 ]]; then
    echo "  (Some users could not authenticate — their RBAC tests will be skipped)"
  fi
fi

# ── 6. AWS RBAC matrix ───────────────────────────────────────────────────────
header "6. AWS RBAC matrix (per-user endpoint access verification)"

# Endpoints to test for AWS read access.
AWS_READ_ENDPOINTS=(
  "/v1/compute/nodes"
  "/v1/compute/images"
  "/v1/compute/sizes"
  "/v1/compute/locations"
)

if [[ "${SKIP_RBAC:-0}" == "1" ]]; then
  skip "SKIP_RBAC=1 — skipping AWS RBAC matrix"
else
  for entry in "${RBAC_USERS[@]}"; do
    user="${entry%%:*}"
    token="${USER_TOKENS[$user]:-}"

    if [[ -z "$token" ]]; then
      skip "AWS RBAC: ${user} (no token — skipping)"
      continue
    fi

    ACCESS_TOKEN="$token"
    read_exp=$(aws_role_expect "$user" "read")
    write_exp=$(aws_role_expect "$user" "write")
    conn_exp=$(aws_role_expect "$user" "conn")

    echo ""
    echo "  ── ${user} (AWS read=${read_exp} write=${write_exp} conn=${conn_exp}) ──"

    # Read endpoints
    for ep in "${AWS_READ_ENDPOINTS[@]}"; do
      rbac_with_retry "$user" rbac_get "${user} GET ${ep}" "aws" "$ep" "$read_exp"
    done

    # Additional AWS read endpoints
    rbac_with_retry "$user" rbac_get "${user} GET /v1/compute/volumes" "aws" "/v1/compute/volumes" "$read_exp"
    rbac_with_retry "$user" rbac_get "${user} GET /v1/compute/networks" "aws" "/v1/compute/networks" "$read_exp"
    rbac_with_retry "$user" rbac_get "${user} GET /v1/compute/subnets" "aws" "/v1/compute/subnets" "$read_exp"
    rbac_with_retry "$user" rbac_get "${user} GET /v1/compute/security-groups" "aws" "/v1/compute/security-groups" "$read_exp"
    rbac_with_retry "$user" rbac_get "${user} GET /v1/compute/key-pairs" "aws" "/v1/compute/key-pairs" "$read_exp"
    rbac_with_retry "$user" rbac_get "${user} GET /v1/compute/snapshots" "aws" "/v1/compute/snapshots" "$read_exp"

    # /v1/auth/me should always return 200 for valid tokens.
    if declare -f libcloud_me >/dev/null 2>&1; then
      check_code_pattern "${user} GET /v1/auth/me" "200" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Accept: application/json" \
        "$BASE/v1/auth/me"
    fi

    # Write endpoint: POST /v1/compute/nodes with minimal body (auth check only).
    aws_min_body='{"name":"rbac-test-aws","size":{"id":"t3.micro"},"image":{"id":"ami-test"}}'
    rbac_with_retry "$user" rbac_post "${user} POST /v1/compute/nodes (AWS)" \
      "aws" "/v1/compute/nodes" "$aws_min_body" "$write_exp"

    # Write endpoint: DELETE non-existent node.
    rbac_with_retry "$user" rbac_delete "${user} DELETE /v1/compute/nodes/nonexistent (AWS)" \
      "aws" "/v1/compute/nodes/rbac-test-nonexistent" "$write_exp"

    # Connection test.
    rbac_with_retry "$user" rbac_connection_test "${user} POST /v1/connections:test (AWS)" \
      "aws" "$conn_exp"
  done
fi

# ── 7. Nutanix RBAC matrix ───────────────────────────────────────────────────
header "7. Nutanix RBAC matrix (per-user endpoint access verification)"

NTNX_READ_ENDPOINTS=(
  "/v1/compute/nodes"
  "/v1/compute/images"
  "/v1/compute/sizes"
  "/v1/compute/locations"
)

if [[ "${SKIP_RBAC:-0}" == "1" ]]; then
  skip "SKIP_RBAC=1 — skipping Nutanix RBAC matrix"
else
  for entry in "${RBAC_USERS[@]}"; do
    user="${entry%%:*}"
    token="${USER_TOKENS[$user]:-}"

    if [[ -z "$token" ]]; then
      skip "Nutanix RBAC: ${user} (no token — skipping)"
      continue
    fi

    ACCESS_TOKEN="$token"
    read_exp=$(nutanix_role_expect "$user" "read")
    write_exp=$(nutanix_role_expect "$user" "write")
    conn_exp=$(nutanix_role_expect "$user" "conn")

    echo ""
    echo "  ── ${user} (Nutanix read=${read_exp} write=${write_exp} conn=${conn_exp}) ──"

    # Read endpoints
    for ep in "${NTNX_READ_ENDPOINTS[@]}"; do
      rbac_with_retry "$user" rbac_get "${user} GET ${ep}" "nutanix" "$ep" "$read_exp"
    done

    # Additional Nutanix read endpoints
    rbac_with_retry "$user" rbac_get "${user} GET /v1/compute/volumes" "nutanix" "/v1/compute/volumes" "$read_exp"
    rbac_with_retry "$user" rbac_get "${user} GET /v1/compute/networks" "nutanix" "/v1/compute/networks" "$read_exp"
    rbac_with_retry "$user" rbac_get "${user} GET /v1/compute/subnets" "nutanix" "/v1/compute/subnets" "$read_exp"
    rbac_with_retry "$user" rbac_get "${user} GET /v1/compute/storage-containers" "nutanix" "/v1/compute/storage-containers" "$read_exp"
    rbac_with_retry "$user" rbac_get "${user} GET /v1/compute/security-groups" "nutanix" "/v1/compute/security-groups" "$read_exp"
    rbac_with_retry "$user" rbac_get "${user} GET /v1/compute/snapshots" "nutanix" "/v1/compute/snapshots" "$read_exp"

    # /v1/auth/me should always return 200 for valid tokens.
    if declare -f libcloud_me >/dev/null 2>&1; then
      check_code_pattern "${user} GET /v1/auth/me" "200" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Accept: application/json" \
        "$BASE/v1/auth/me"
    fi

    # Write endpoint: POST /v1/compute/nodes with minimal body.
    ntnx_min_body='{"name":"rbac-test-ntnx","size":{"id":"small"},"image":{"id":"test-image"},"location":{"id":"test-cluster"}}'
    rbac_with_retry "$user" rbac_post "${user} POST /v1/compute/nodes (Nutanix)" \
      "nutanix" "/v1/compute/nodes" "$ntnx_min_body" "$write_exp"

    # Write endpoint: DELETE non-existent node.
    rbac_with_retry "$user" rbac_delete "${user} DELETE /v1/compute/nodes/nonexistent (Nutanix)" \
      "nutanix" "/v1/compute/nodes/rbac-test-nonexistent" "$write_exp"

    # Connection test.
    rbac_with_retry "$user" rbac_connection_test "${user} POST /v1/connections:test (Nutanix)" \
      "nutanix" "$conn_exp"
  done
fi

# ── 8. Cross-tenant isolation ────────────────────────────────────────────────
header "8. Cross-tenant isolation (aws users → nutanix, ntnx users → aws)"

if [[ "${SKIP_RBAC:-0}" == "1" ]]; then
  skip "SKIP_RBAC=1 — skipping cross-tenant isolation tests"
else
  # AWS tenant users should be denied on Nutanix.
  aws_tenant_users=("aws-owner" "aws-admin" "aws-viewer")
  for user in "${aws_tenant_users[@]}"; do
    token="${USER_TOKENS[$user]:-}"
    if [[ -z "$token" ]]; then
      skip "Cross-tenant: ${user} → nutanix (no token)"
      continue
    fi
    ACCESS_TOKEN="$token"
    echo ""
    echo "  ── ${user} → Nutanix (expect 403) ──"
    rbac_get "${user} → nutanix GET /v1/compute/nodes" "nutanix" "/v1/compute/nodes" "403"
    rbac_connection_test "${user} → nutanix connections:test" "nutanix" "403"
    rbac_post "${user} → nutanix POST /v1/compute/nodes" "nutanix" \
      "/v1/compute/nodes" '{"name":"x-tenant","size":{"id":"s"},"image":{"id":"i"}}' "403"
  done

  # Nutanix tenant users should be denied on AWS.
  ntnx_tenant_users=("ntnx-owner" "ntnx-admin" "ntnx-viewer")
  for user in "${ntnx_tenant_users[@]}"; do
    token="${USER_TOKENS[$user]:-}"
    if [[ -z "$token" ]]; then
      skip "Cross-tenant: ${user} → aws (no token)"
      continue
    fi
    ACCESS_TOKEN="$token"
    echo ""
    echo "  ── ${user} → AWS (expect 403) ──"
    rbac_get "${user} → aws GET /v1/compute/nodes" "aws" "/v1/compute/nodes" "403"
    rbac_connection_test "${user} → aws connections:test" "aws" "403"
    rbac_post "${user} → aws POST /v1/compute/nodes" "aws" \
      "/v1/compute/nodes" '{"name":"x-tenant","size":{"id":"t"},"image":{"id":"i"}}' "403"
  done

  # cloud-denied should be denied on both providers.
  denied_token="${USER_TOKENS[cloud-denied]:-}"
  if [[ -n "$denied_token" ]]; then
    ACCESS_TOKEN="$denied_token"
    echo ""
    echo "  ── cloud-denied → both providers (expect 403) ──"
    rbac_get "cloud-denied → aws GET /v1/compute/nodes" "aws" "/v1/compute/nodes" "403"
    rbac_get "cloud-denied → nutanix GET /v1/compute/nodes" "nutanix" "/v1/compute/nodes" "403"
    rbac_post "cloud-denied → aws POST /v1/compute/nodes" "aws" \
      "/v1/compute/nodes" '{"name":"no-access","size":{"id":"t"},"image":{"id":"i"}}' "403"
    rbac_post "cloud-denied → nutanix POST /v1/compute/nodes" "nutanix" \
      "/v1/compute/nodes" '{"name":"no-access","size":{"id":"s"},"image":{"id":"i"}}' "403"
  else
    skip "Cross-tenant: cloud-denied (no token)"
  fi
fi

# ── 9. Provisioning tests ────────────────────────────────────────────────────
header "9. Provisioning tests (AWS + Nutanix)"

if [[ "${SKIP_PROVISION:-0}" == "1" ]]; then
  skip "SKIP_PROVISION=1 — skipping provisioning tests"
elif [[ "${SKIP_RBAC:-0}" == "1" ]]; then
  skip "SKIP_RBAC=1 — provisioning needs RBAC auth, skipping"
else
  # Check Vault credentials first.
  header "9a. Vault credential verification"
  check_vault_credentials "aws" || true
  check_vault_credentials "nutanix" || true

  if [[ "${PROVISION:-0}" != "1" ]]; then
    skip "PROVISION=0 — skipping actual cloud provisioning (set PROVISION=1 to enable)"
    echo "       Provisioning readiness verified; use PROVISION=1 to create resources."
  else
    # ── AWS provisioning (as aws-owner) ─────────────────────────────────────
    header "9b. AWS provisioning (aws-owner)"
    aws_token="${USER_TOKENS[aws-owner]:-}"
    if [[ -z "$aws_token" ]]; then
      skip "AWS provisioning: aws-owner not authenticated"
    else
      ACCESS_TOKEN="$aws_token"
      build_provider_connection "aws"

      # Verify connection works.
      rbac_connection_test "provision-aws: connection test" "aws" "200"

      # Catalog discovery.
      rbac_get "provision-aws: list nodes" "aws" "/v1/compute/nodes" "200"
      rbac_get "provision-aws: list images" "aws" "/v1/compute/images" "200"
      rbac_get "provision-aws: list sizes" "aws" "/v1/compute/sizes" "200"
      rbac_get "provision-aws: list locations" "aws" "/v1/compute/locations" "200"

      # Resolve image + size for provisioning.
      AWS_VM_NAME="${AWS_VM_NAME:-libcloud-demo-rbac-$(date +%s)}"
      AWS_IMAGE_NAME_FILTER="${AWS_IMAGE_NAME_FILTER:-*ubuntu*24.04*amd64*}"
      AWS_INSTANCE_ARCH="${AWS_INSTANCE_ARCH:-x86_64}"
      AWS_DEFAULT_SIZE_ID="${AWS_DEFAULT_SIZE_ID:-}"
      AWS_REGION="${AWS_REGION:-ap-southeast-1}"

      # Resolve image ID and size ID.
      IMAGES_RESP=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Accept: application/json" \
        -H "X-Provider-Connection: ${CONNECTION_PARAM}" \
        "$BASE/v1/compute/images?name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${AWS_IMAGE_NAME_FILTER}'))")")
      SIZES_RESP=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Accept: application/json" \
        -H "X-Provider-Connection: ${CONNECTION_PARAM}" \
        "$BASE/v1/compute/sizes")

      IMAGE_ID=$(python3 -c "import json,sys; d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')" <<<"$IMAGES_RESP" 2>/dev/null || echo "")
      SIZE_ID=$(python3 -c "import json,sys; d=json.load(sys.stdin).get('data',[]); v='${AWS_DEFAULT_SIZE_ID}'; arch='${AWS_INSTANCE_ARCH}'; matches=[s for s in d if (not v or s['id']==v)]; print(matches[0]['id'] if matches else (d[0]['id'] if d else ''))" <<<"$SIZES_RESP" 2>/dev/null || echo "")

      if [[ -z "$IMAGE_ID" || -z "$SIZE_ID" ]]; then
        red "provision-aws: could not resolve IMAGE_ID or SIZE_ID from catalog"
      else
        green "provision-aws: resolved IMAGE_ID=${IMAGE_ID} SIZE_ID=${SIZE_ID}"
        SUBNET_ID=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
          -H "Accept: application/json" \
          -H "X-Provider-Connection: ${CONNECTION_PARAM}" \
          "$BASE/v1/compute/subnets" | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",[]); print(d[0]["id"] if d else "")' 2>/dev/null || echo "")

        CREATE_BODY=$(python3 -c "
import json
body = {'name': '${AWS_VM_NAME}', 'size': {'id': '${SIZE_ID}'}, 'image': {'id': '${IMAGE_ID}'}, 'network': {'public_ip': True}}
if '${SUBNET_ID}':
    body['network']['subnet_id'] = '${SUBNET_ID}'
conn = json.loads('${CONNECTION_PARAM}')
body['connection'] = conn
print(json.dumps(body))
")
        echo "  Provisioning AWS VM: ${AWS_VM_NAME} ..."
        PROV_RESP=$(curl -s -X POST \
          -H "Authorization: Bearer ${ACCESS_TOKEN}" \
          -H "Accept: application/json" \
          -H "Content-Type: application/json" \
          -H "X-Provider-Connection: ${CONNECTION_PARAM}" \
          -d "$CREATE_BODY" \
          "$BASE/v1/compute/nodes")
        PROV_CODE=$?
        PROV_HTTP=$(echo "$PROV_RESP" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id",""))' 2>/dev/null || echo "")
        if [[ -n "$PROV_HTTP" ]]; then
          green "provision-aws: created VM id=${PROV_HTTP}"
        else
          red "provision-aws: VM creation may have failed — check response: $(echo "$PROV_RESP" | head -c 200)"
        fi
      fi

      # Teardown if requested.
      if [[ "${TEARDOWN_VMS:-0}" == "1" ]]; then
        echo "  Tearing down AWS VM: ${AWS_VM_NAME} ..."
        if declare -f teardown_libcloud_vms >/dev/null 2>&1; then
          teardown_libcloud_vms "${AWS_VM_NAME}"
        else
          # Manual teardown.
          NODES=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Accept: application/json" \
            -H "X-Provider-Connection: ${CONNECTION_PARAM}" \
            "$BASE/v1/compute/nodes")
          NODE_ID=$(python3 -c "import json,sys; d=json.load(sys.stdin).get('data',[]); matches=[n for n in d if n.get('name')=='${AWS_VM_NAME}']; print(matches[0]['id'] if matches else '')" <<<"$NODES" 2>/dev/null || echo "")
          if [[ -n "$NODE_ID" ]]; then
            curl -s -X DELETE \
              -H "Authorization: Bearer ${ACCESS_TOKEN}" \
              -H "Accept: application/json" \
              -H "X-Provider-Connection: ${CONNECTION_PARAM}" \
              "$BASE/v1/compute/nodes/${NODE_ID}" >/dev/null
            green "provision-aws: deleted VM id=${NODE_ID}"
          else
            skip "provision-aws: VM ${AWS_VM_NAME} not found for teardown"
          fi
        fi
      fi
    fi

    # ── Nutanix provisioning (as ntnx-owner) ────────────────────────────────
    header "9c. Nutanix provisioning (ntnx-owner)"
    ntnx_token="${USER_TOKENS[ntnx-owner]:-}"
    if [[ -z "$ntnx_token" ]]; then
      skip "Nutanix provisioning: ntnx-owner not authenticated"
    else
      ACCESS_TOKEN="$ntnx_token"
      build_provider_connection "nutanix"

      rbac_connection_test "provision-ntnx: connection test" "nutanix" "200|502|503"

      rbac_get "provision-ntnx: list nodes" "nutanix" "/v1/compute/nodes" "200"
      rbac_get "provision-ntnx: list images" "nutanix" "/v1/compute/images" "200"
      rbac_get "provision-ntnx: list sizes" "nutanix" "/v1/compute/sizes" "200"
      rbac_get "provision-ntnx: list locations" "nutanix" "/v1/compute/locations" "200"

      NTNX_VM_NAME="${NTNX_VM_NAME:-libcloud-ntnx-rbac-$(date +%s)}"

      # Resolve cluster, image, size, subnet for Nutanix.
      CLUSTER_ID=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Accept: application/json" \
        -H "X-Provider-Connection: ${CONNECTION_PARAM}" \
        "$BASE/v1/compute/locations" | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",[]); print(d[0]["id"] if d else "")' 2>/dev/null || echo "")
      IMAGE_ID=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Accept: application/json" \
        -H "X-Provider-Connection: ${CONNECTION_PARAM}" \
        "$BASE/v1/compute/images" | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",[]); print(d[0]["id"] if d else "")' 2>/dev/null || echo "")
      NTNX_SUBNET=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Accept: application/json" \
        -H "X-Provider-Connection: ${CONNECTION_PARAM}" \
        "$BASE/v1/compute/subnets" | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",[]); print(d[0]["id"] if d else "")' 2>/dev/null || echo "")

      if [[ -z "$CLUSTER_ID" || -z "$IMAGE_ID" ]]; then
        red "provision-ntnx: could not resolve CLUSTER_ID or IMAGE_ID from catalog"
      else
        green "provision-ntnx: resolved CLUSTER_ID=${CLUSTER_ID} IMAGE_ID=${IMAGE_ID}"
        ntnx_size="${NTNX_DEFAULT_SIZE_ID:-small}"
        CREATE_BODY=$(python3 -c "
import json
body = {'name': '${NTNX_VM_NAME}', 'size': {'id': '${ntnx_size}'}, 'image': {'id': '${IMAGE_ID}'}, 'location': {'id': '${CLUSTER_ID}'}}
if '${NTNX_SUBNET}':
    body['network'] = {'subnet_id': '${NTNX_SUBNET}'}
conn = json.loads('${CONNECTION_PARAM}')
body['connection'] = conn
print(json.dumps(body))
")
        echo "  Provisioning Nutanix VM: ${NTNX_VM_NAME} ..."
        PROV_RESP=$(curl -s -X POST \
          -H "Authorization: Bearer ${ACCESS_TOKEN}" \
          -H "Accept: application/json" \
          -H "Content-Type: application/json" \
          -H "X-Provider-Connection: ${CONNECTION_PARAM}" \
          -d "$CREATE_BODY" \
          "$BASE/v1/compute/nodes")
        PROV_ID=$(echo "$PROV_RESP" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id",""))' 2>/dev/null || echo "")
        if [[ -n "$PROV_ID" ]]; then
          green "provision-ntnx: created VM id=${PROV_ID}"
        else
          red "provision-ntnx: VM creation may have failed — check response: $(echo "$PROV_RESP" | head -c 200)"
        fi
      fi

      # Teardown if requested.
      if [[ "${TEARDOWN_VMS:-0}" == "1" ]]; then
        echo "  Tearing down Nutanix VM: ${NTNX_VM_NAME} ..."
        if declare -f teardown_libcloud_vms >/dev/null 2>&1; then
          teardown_libcloud_vms "${NTNX_VM_NAME}"
        else
          NODES=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Accept: application/json" \
            -H "X-Provider-Connection: ${CONNECTION_PARAM}" \
            "$BASE/v1/compute/nodes")
          NODE_ID=$(python3 -c "import json,sys; d=json.load(sys.stdin).get('data',[]); matches=[n for n in d if n.get('name')=='${NTNX_VM_NAME}']; print(matches[0]['id'] if matches else '')" <<<"$NODES" 2>/dev/null || echo "")
          if [[ -n "$NODE_ID" ]]; then
            curl -s -X DELETE \
              -H "Authorization: Bearer ${ACCESS_TOKEN}" \
              -H "Accept: application/json" \
              -H "X-Provider-Connection: ${CONNECTION_PARAM}" \
              "$BASE/v1/compute/nodes/${NODE_ID}" >/dev/null
            green "provision-ntnx: deleted VM id=${NODE_ID}"
          else
            skip "provision-ntnx: VM ${NTNX_VM_NAME} not found for teardown"
          fi
        fi
      fi
    fi
  fi
fi

# ── 10. Response format & JSON validity ──────────────────────────────────────
header "10. Response format"

CTYPE=$(curl -s -o /dev/null -w '%{content_type}' "$BASE/health")
if [[ "$CTYPE" == application/json* ]]; then
  green "Content-Type is $CTYPE"
else
  red "Content-Type unexpected: $CTYPE"
fi

if curl -s "$BASE/health" | python3 -m json.tool >/dev/null 2>&1; then
  green "Health response is valid JSON"
else
  red "Health response is not valid JSON"
fi

if curl -s "$BASE/v1/providers" | python3 -m json.tool >/dev/null 2>&1; then
  green "Providers response is valid JSON"
else
  red "Providers response is not valid JSON"
fi

# ── 11. Error handling ───────────────────────────────────────────────────────
header "11. Error handling"

check "Unknown GET path → 404"     404 "$BASE/v1/does/not/exist"
check "Unknown POST path → 404"    404 -X POST "$BASE/v1/does/not/exist"

check_body "404 returns proper error body" 404 '"detail"' \
  "$BASE/v1/does/not/exist"

check "POST to /health → 405" 405 \
  -X POST "$BASE/health" -H 'Content-Type: application/json' -d '{}'

# ── 12. Request validation ───────────────────────────────────────────────────
header "12. Request validation"

POST_CODE=$(curl -s -o /tmp/rest_test_resp.json -w '%{http_code}' \
  -X POST "$BASE/v1/compute/nodes" -d '{}' 2>&1) || true
if [[ "$POST_CODE" == "422" ]]; then
  green "POST /v1/compute/nodes without Content-Type → 422 (validation)"
elif [[ "$POST_CODE" == "401" ]]; then
  green "POST /v1/compute/nodes without Content-Type → 401 (auth, expected)"
elif [[ "$POST_CODE" == "400" ]]; then
  green "POST /v1/compute/nodes without Content-Type → 400 (bad request)"
else
  red "POST /v1/compute/nodes without Content-Type — unexpected HTTP $POST_CODE"
fi

# ── 13. Summary ──────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
printf "  Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m" "$PASS" "$FAIL"
if [[ "$SKIP" -gt 0 ]]; then
  printf ", \033[33m%d skipped\033[0m" "$SKIP"
fi
echo ""
echo "════════════════════════════════════════════════════════"

exit "$FAIL"
