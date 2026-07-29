#!/usr/bin/env bash
# ─── OpenFGA + Postgres Container Test ─────────────────────────────────────────
# Verifies the OpenFGA containers (openfga-postgres, openfga) are healthy and
# serving correct responses on http://localhost:8080.
#
# Usage:
#   chmod +x scripts/fga-test.sh
#   ./scripts/fga-test.sh [fga_url] [pg_container] [fga_container]
#
# Defaults:
#   FGA URL:        http://localhost:8080
#   PG container:   openfga-postgres
#   FGA container:  openfga
#
# Auth:
#   Some tests (tuple read/write, check) require a valid bearer token.
#   The script auto-resolves a token using the same logic as fga_auth.sh:
#     1. $FGA_API_TOKEN (preshared-key / explicit override)
#     2. $SUPERADMIN_JWT (from superadmin_auth.sh)
#     3. openfga_postgres/generated/tokens/superadmin.jwt (if unexpired)
#   If no token is found, authenticated tests are skipped with a warning.
#
# Notes on OpenFGA REST API:
#   - /healthz  and /readyz are unauthenticated.
#   - /stores/* endpoints require a bearer token when authn-method=oidc.
#   - Write/Check/Read use POST with a JSON body; page_size max ~100.
#   - List endpoints (GET /stores, GET /authorization-models) accept
#     ?page_size=N&continuation_token=... for pagination.

set -uo pipefail

FGA_URL="${1:-http://localhost:8080}"
PG_CONTAINER="${2:-openfga-postgres}"
FGA_CONTAINER="${3:-openfga}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PROJ_DIR}/.." && pwd)"
FGA_ENV_FILE="${PROJ_DIR}/generated/fga.env"
FGA_TOKEN_FILE="${PROJ_DIR}/generated/tokens/superadmin.jwt"
TMP_RESP="${TMPDIR:-/tmp}/fga_test_resp.json"

PASS=0
FAIL=0
SKIP=0

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; ((PASS++)); }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*"; ((FAIL++)); }
yellow() { printf '\033[33m⚠ %s\033[0m\n' "$*"; ((SKIP++)); }
header() { printf '\n\033[1;36m── %s ──\033[0m\n' "$*"; }

# check <desc> <expected_code> [curl args...]
# Runs curl; expects exact HTTP status match.
check() {
  local desc="$1" expected="$2"
  shift 2
  local code
  code=$(curl -s -o "${TMP_RESP}" -w '%{http_code}' "$@" 2>&1) || true
  if [[ "$code" == "$expected" ]]; then
    green "$desc (HTTP $code)"
  else
    red "$desc — expected $expected, got $code"
    head -c 400 "${TMP_RESP}" 2>/dev/null || true
    echo ""
  fi
}

# check_body <desc> <expected_code> <grep_pattern> [curl args...]
# Expects both status match AND a grep pattern in the response body.
check_body() {
  local desc="$1" expected="$2" pattern="$3"
  shift 3
  local code
  code=$(curl -s -o "${TMP_RESP}" -w '%{http_code}' "$@" 2>&1) || true
  if [[ "$code" == "$expected" ]] && grep -q "$pattern" "${TMP_RESP}"; then
    green "$desc (HTTP $code, body matches '$pattern')"
  elif [[ "$code" != "$expected" ]]; then
    red "$desc — expected HTTP $expected, got $code"
  else
    red "$desc — HTTP $code but body missing '$pattern'"
    head -c 400 "${TMP_RESP}"; echo ""
  fi
}

# ── Auth resolution (mirrors fga_auth.sh) ──────────────────────────────────────

_fga_jwt_exp() {  # print exp epoch or ""
  python3 - "$1" <<'PY' 2>/dev/null
import sys, json, base64
t = sys.argv[1].strip()
try:
    p = t.split('.')[1]; p += '=' * (-len(p) % 4)
    print(int(json.loads(base64.urlsafe_b64decode(p)).get('exp', 0)))
except Exception:
    print("")
PY
}

_resolve_token() {
  if [[ -n "${FGA_API_TOKEN:-}" ]]; then echo "${FGA_API_TOKEN}"; return 0; fi
  if [[ -n "${SUPERADMIN_JWT:-}" ]]; then echo "${SUPERADMIN_JWT}"; return 0; fi
  if [[ -s "${FGA_TOKEN_FILE}" ]]; then
    local tok exp now
    tok=$(cat "${FGA_TOKEN_FILE}")
    exp=$(_fga_jwt_exp "$tok")
    now=$(date +%s)
    if [[ -n "$exp" && "$exp" -gt "$now" ]]; then echo "$tok"; return 0; fi
  fi
  return 1
}

FGA_BEARER=""
HAS_AUTH=false
if tok=$(_resolve_token 2>/dev/null); then
  FGA_BEARER="$tok"
  HAS_AUTH=true
fi

# ── Store/model IDs from generated/fga.env ─────────────────────────────────────

_fga_env_val() {
  [[ -f "${FGA_ENV_FILE}" ]] || { echo ""; return 0; }
  local line
  line=$(grep -E "^$1=" "${FGA_ENV_FILE}" | tail -n1 || true)
  echo "${line#*=}"
}

FGA_STORE_ID="${FGA_STORE_ID:-$(_fga_env_val FGA_STORE_ID)}"
FGA_MODEL_ID="${FGA_MODEL_ID:-$(_fga_env_val FGA_MODEL_ID)}"

echo "╔══════════════════════════════════════════════════════╗"
echo "║   OpenFGA + Postgres Container Test                 ║"
printf  "║   FGA URL: %-42s║\n" "$FGA_URL"
printf  "║   PG: %-34s %-13s║\n" "$PG_CONTAINER" "$FGA_CONTAINER"
if $HAS_AUTH; then
  printf  "║   Auth: %-15s (store=%s)║\n" "bearer token" "${FGA_STORE_ID:-none}"
else
  printf  "║   Auth: %-44s║\n" "none (auth'd tests skipped)"
fi
echo "╚══════════════════════════════════════════════════════╝"

# ═══════════════════════════════════════════════════════════════════════════════
# 0. Container checks
# ═══════════════════════════════════════════════════════════════════════════════
header "0. Docker containers"

for c in "$PG_CONTAINER" "$FGA_CONTAINER"; do
  if docker ps --filter "name=^/${c}$" --filter status=running -q 2>/dev/null | grep -q .; then
    green "Container $c is running"
  else
    red "Container $c is NOT running (docker ps found nothing)"
  fi
done

# ═══════════════════════════════════════════════════════════════════════════════
# 1. Health / readiness (unauthenticated)
# ═══════════════════════════════════════════════════════════════════════════════
header "1. Health & readiness (unauthenticated)"

check      "GET /healthz → 200"                    200 "${FGA_URL}/healthz"
# /readyz is not present in OpenFGA ≤ v1.16.0 (added later).
# Accept either 200 (available) or 404 (not yet implemented).
_rdyz_code=$(curl -s -o /dev/null -w '%{http_code}' "${FGA_URL}/readyz")
if [[ "$_rdyz_code" == "200" ]]; then
  green "GET /readyz → 200 (available)"
elif [[ "$_rdyz_code" == "404" ]]; then
  green "GET /readyz → 404 (not yet available in this version — acceptable)"
else
  red "GET /readyz → unexpected $_rdyz_code (expected 200 or 404)"
fi

# ── 1a. Healthz response should be valid JSON ─────────────────────────────────
check_body "GET /healthz returns valid JSON"       200 'status' "${FGA_URL}/healthz"

# ═══════════════════════════════════════════════════════════════════════════════
# 2. Unauthenticated → 401 (when OIDC authn is enabled)
# ═══════════════════════════════════════════════════════════════════════════════
header "2. Authentication enforcement"

check_body "GET /stores without token → 401 or 200" 401 "code" \
  "${FGA_URL}/stores"
# 200 is also acceptable (preshared-key mode or authn=none).

# ═══════════════════════════════════════════════════════════════════════════════
# 3. Authenticated store & model queries
# ═══════════════════════════════════════════════════════════════════════════════
if $HAS_AUTH; then
  header "3. Store & model (authenticated)"

  # 3a. List stores
  check_body "GET /stores → 200 + 'stores' key"  200 '"stores"' \
    "${FGA_URL}/stores" \
    -H "Authorization: Bearer ${FGA_BEARER}"

  # 3b. List stores with pagination
  check_body "GET /stores?page_size=1 → 200"     200 '"stores"' \
    "${FGA_URL}/stores?page_size=1" \
    -H "Authorization: Bearer ${FGA_BEARER}"

  # 3c. Get a specific store (if FGA_STORE_ID is known)
  if [[ -n "${FGA_STORE_ID}" ]]; then
    check_body "GET /stores/$FGA_STORE_ID → 200" 200 '"name"' \
      "${FGA_URL}/stores/${FGA_STORE_ID}" \
      -H "Authorization: Bearer ${FGA_BEARER}"

    # 3d. Get a non-existent store → 404 or 400
    check "GET /stores/doesnotexist → 404"       404 \
      "${FGA_URL}/stores/doesnotexist" \
      -H "Authorization: Bearer ${FGA_BEARER}"

    # 3e. List authorization models
    check_body "GET authorization-models → 200"  200 '"authorization_models"' \
      "${FGA_URL}/stores/${FGA_STORE_ID}/authorization-models?page_size=1" \
      -H "Authorization: Bearer ${FGA_BEARER}"

    # 3f. Get a specific authorization model
    if [[ -n "${FGA_MODEL_ID}" ]]; then
      check_body "GET auth model by id → 200"    200 '"type_definitions"' \
        "${FGA_URL}/stores/${FGA_STORE_ID}/authorization-models/${FGA_MODEL_ID}" \
        -H "Authorization: Bearer ${FGA_BEARER}"
    else
      yellow "GET auth model by id — skipped (no FGA_MODEL_ID in fga.env)"
    fi
  else
    yellow "GET /stores/{id} — skipped (no FGA_STORE_ID in fga.env)"
  fi
else
  header "3. Store & model (authenticated) — skipped, no auth token"
  yellow "Skipped: authenticated tests require FGA_API_TOKEN, SUPERADMIN_JWT,"
  yellow "  or an unexpired generated/tokens/superadmin.jwt"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 4. Tuple operations (authenticated)
# ═══════════════════════════════════════════════════════════════════════════════
if $HAS_AUTH && [[ -n "${FGA_STORE_ID}" ]]; then
  header "4. Tuple read / check (authenticated)"

  AUTH_H=(-H "Authorization: Bearer ${FGA_BEARER}" -H "Content-Type: application/json")

  # 4a. Read all tuples (empty filter returns everything, paginated)
  check_body "POST read tuples → 200 + 'tuples'" 200 '"tuples"' \
    "${FGA_URL}/stores/${FGA_STORE_ID}/read" \
    "${AUTH_H[@]}" \
    -d '{"page_size":5}'

  # 4b. Read with a specific tuple filter (superadmin membership)
  check_body "POST read superadmin tuple → 200"   200 '"tuples"' \
    "${FGA_URL}/stores/${FGA_STORE_ID}/read" \
    "${AUTH_H[@]}" \
    -d '{"tuple_key":{"user":"user:superadmin","relation":"superadmin","object":"platform:main"}}'

  # 4c. Check: superadmin → can_manage_platform → platform:main → allowed=true
  if [[ -n "${FGA_MODEL_ID}" ]]; then
    check_body "Check superadmin platform → allowed" 200 '"allowed":true' \
      "${FGA_URL}/stores/${FGA_STORE_ID}/check" \
      "${AUTH_H[@]}" \
      -d "{\"authorization_model_id\":\"${FGA_MODEL_ID}\",\"tuple_key\":{\"user\":\"user:superadmin\",\"relation\":\"can_manage_platform\",\"object\":\"platform:main\"}}"

    # 4d. Check: superadmin → can_provision → aws_region:aws → allowed=false
    check_body "Check superadmin aws provision → denied" 200 '"allowed":false' \
      "${FGA_URL}/stores/${FGA_STORE_ID}/check" \
      "${AUTH_H[@]}" \
      -d "{\"authorization_model_id\":\"${FGA_MODEL_ID}\",\"tuple_key\":{\"user\":\"user:superadmin\",\"relation\":\"can_provision\",\"object\":\"aws_region:aws\"}}"

    # 4e. Check: cloud-denied → can_connect → libcloud_api:main → allowed=false
    check_body "Check cloud-denied → denied" 200 '"allowed":false' \
      "${FGA_URL}/stores/${FGA_STORE_ID}/check" \
      "${AUTH_H[@]}" \
      -d "{\"authorization_model_id\":\"${FGA_MODEL_ID}\",\"tuple_key\":{\"user\":\"user:cloud-denied\",\"relation\":\"can_connect\",\"object\":\"libcloud_api:main\"}}"

    # 4f. Check: ntnx-owner → can_manage_credentials → tenant:nutanix → allowed=true
    check_body "Check ntnx-owner creds → allowed" 200 '"allowed":true' \
      "${FGA_URL}/stores/${FGA_STORE_ID}/check" \
      "${AUTH_H[@]}" \
      -d "{\"authorization_model_id\":\"${FGA_MODEL_ID}\",\"tuple_key\":{\"user\":\"user:ntnx-owner\",\"relation\":\"can_manage_credentials\",\"object\":\"tenant:nutanix\"}}"
  else
    yellow "Check tests — skipped (no FGA_MODEL_ID in fga.env)"
  fi

  # 4g. Check without authorization_model_id → error
  check "POST check without model_id → 400 or 422" 400 \
    "${FGA_URL}/stores/${FGA_STORE_ID}/check" \
    "${AUTH_H[@]}" \
    -d '{"tuple_key":{"user":"user:superadmin","relation":"can_read","object":"tenant:aws"}}'

  # 4h. write: empty write → 200 (no-op, validates write endpoint is reachable)
  check_body "POST write (empty) → 200"             200 "" \
    "${FGA_URL}/stores/${FGA_STORE_ID}/write" \
    "${AUTH_H[@]}" \
    -d "{\"writes\":{\"tuple_keys\":[]}}"
else
  header "4. Tuple operations (authenticated) — skipped"
  if ! $HAS_AUTH; then
    yellow "Skipped: no auth token available"
  else
    yellow "Skipped: no FGA_STORE_ID in fga.env"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 5. Expand / List-Objects (authenticated)
# ═══════════════════════════════════════════════════════════════════════════════
if $HAS_AUTH && [[ -n "${FGA_STORE_ID}" ]] && [[ -n "${FGA_MODEL_ID}" ]]; then
  header "5. Expand & list-objects (authenticated)"

  AUTH_H=(-H "Authorization: Bearer ${FGA_BEARER}" -H "Content-Type: application/json")

  # 5a. Expand a relation (who has can_read on tenant:aws?)
  check_body "POST expand can_read tenant:aws → 200" 200 '"tree"' \
    "${FGA_URL}/stores/${FGA_STORE_ID}/expand" \
    "${AUTH_H[@]}" \
    -d "{\"authorization_model_id\":\"${FGA_MODEL_ID}\",\"tuple_key\":{\"relation\":\"can_read\",\"object\":\"tenant:aws\"}}"

  # 5b. List objects that user:aws-owner can read
  check_body "POST list-objects aws-owner can_read → 200" 200 '"objects"' \
    "${FGA_URL}/stores/${FGA_STORE_ID}/list-objects" \
    "${AUTH_H[@]}" \
    -d "{\"authorization_model_id\":\"${FGA_MODEL_ID}\",\"user\":\"user:aws-owner\",\"relation\":\"can_read\",\"type\":\"tenant\"}"

elif $HAS_AUTH; then
  header "5. Expand & list-objects (authenticated) — skipped"
  yellow "Skipped: need FGA_STORE_ID + FGA_MODEL_ID from fga.env"
else
  header "5. Expand & list-objects (authenticated) — skipped"
  yellow "Skipped: no auth token available"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 6. Response format validation
# ═══════════════════════════════════════════════════════════════════════════════
header "6. Response format"

CTYPE=$(curl -s -o /dev/null -w '%{content_type}' "${FGA_URL}/healthz")
if [[ "$CTYPE" == application/json* ]]; then
  green "Content-Type is $CTYPE (healthz)"
else
  red "Content-Type unexpected: $CTYPE"
fi

if curl -s "${FGA_URL}/healthz" | python3 -m json.tool >/dev/null 2>&1; then
  green "Response body is valid JSON (healthz)"
else
  red "Response body is not valid JSON (healthz)"
fi

# Validate invalid JSON body → 400
check "POST /stores/{id}/check with bad JSON → 400" 400 \
  "${FGA_URL}/stores/doesnotexist/check" \
  -H 'Content-Type: application/json' \
  -d 'not-json'

# ═══════════════════════════════════════════════════════════════════════════════
# 7. Metrics endpoint (port 2112) — unauthenticated
# ═══════════════════════════════════════════════════════════════════════════════
header "7. Metrics endpoint"

# Derive metrics URL from FGA_URL: replace :8080 with :2112
METRICS_URL="${FGA_URL%:8080}:2112"

check_body "GET /metrics → 200 + openfga metrics"  200 'openfga' \
  "${METRICS_URL}/metrics"

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════"
printf "  Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m" "$PASS" "$FAIL"
if [[ "$SKIP" -gt 0 ]]; then
  printf ", \033[33m%d skipped\033[0m" "$SKIP"
fi
echo ""
echo "════════════════════════════════════════════════════════"

exit "$FAIL"
