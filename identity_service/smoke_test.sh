#!/usr/bin/env bash
# Smoke test: is the dockerized identity-service running correctly?
#
# Fast black-box checks against a running `identity-service` container —
# container state, liveness, Dex wiring, session guards, and the error
# contract — using curl (+ python3 for JSON parsing, same as verify_auth.sh).
# This is the quick "is it up and sane" script; for the deep auth-path
# guarantees run ./verify_auth.sh, for the role matrix ./verify_authz_matrix.sh.
#
# Usage:
#   ./smoke_test.sh                              # defaults to http://localhost:8766
#   BASE_URL=http://login.quest4science.xyz:8766 ./smoke_test.sh
#   CONTAINER_NAME=identity-service ./smoke_test.sh
#
# Exit status: 0 if all checks pass, 1 if any fail.

set -u

BASE_URL="${BASE_URL:-http://localhost:8766}"
BASE_URL="${BASE_URL%/}"  # strip trailing slash
CONTAINER_NAME="${CONTAINER_NAME:-identity-service}"

PASS=0
FAIL=0
SKIP=0
FAILURES=()

# --- helpers -----------------------------------------------------------------
pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); FAILURES+=("$1"); }
skip() { printf '  SKIP  %s\n' "$1"; SKIP=$((SKIP+1)); }

# json_field <field>: extract a top-level string field from a JSON body on stdin.
json_field() {
  python3 -c 'import sys,json
try:
  v = json.load(sys.stdin).get(sys.argv[1], "")
except Exception:
  v = ""
print("" if v is None else v)' "$1" 2>/dev/null
}

# check <name> <expected_http> <expected_error_code_or_""> <curl-args...>
check() {
  local name="$1" exp_http="$2" exp_err="$3"; shift 3
  local http body err
  http="$(curl -s -o /tmp/st_body -w '%{http_code}' --max-time 10 "$@")"
  body="$(cat /tmp/st_body)"
  err="$(printf '%s' "$body" | json_field error)"
  if [ "$http" = "$exp_http" ] && { [ -z "$exp_err" ] || [ "$err" = "$exp_err" ]; }; then
    pass "$name  [http=$http${err:+ error=$err}]"
  else
    fail "$name  [want http=$exp_http${exp_err:+ error=$exp_err}; got http=$http error=$err]"
    printf '        body: %s\n' "$body"
  fi
}

echo "=== identity-service smoke test ==="
echo "    BASE_URL=$BASE_URL  CONTAINER_NAME=$CONTAINER_NAME"
echo

# --- 0. container state --------------------------------------------------------
echo "[0] docker container"
if command -v docker >/dev/null 2>&1; then
  STATE="$(docker inspect -f '{{.State.Status}}{{if .State.Health}}/{{.State.Health.Status}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  case "$STATE" in
    running/healthy|running)
      pass "container '$CONTAINER_NAME' is $STATE" ;;
    "")
      fail "container '$CONTAINER_NAME' not found (run: docker compose up -d --build)" ;;
    *)
      fail "container '$CONTAINER_NAME' state is '$STATE' (want running/healthy)" ;;
  esac
else
  skip "docker CLI not available — container state not checked"
fi

# --- 1. liveness ---------------------------------------------------------------
echo "[1] liveness"
check "GET /health" 200 "" "$BASE_URL/health"
HEALTH_STATUS="$(curl -s --max-time 10 "$BASE_URL/health" | json_field status)"
if [ "$HEALTH_STATUS" = "ok" ]; then
  pass "GET /health body has status=ok"
else
  fail "GET /health body status (want 'ok', got '$HEALTH_STATUS')"
fi

# --- 2. Dex wiring: begin returns a usable authorize URL -----------------------
echo "[2] Dex wiring (/api/auth/begin)"
BEGIN_BODY="$(curl -s --max-time 10 "$BASE_URL/api/auth/begin?provider=google")"
STATE="$(printf '%s' "$BEGIN_BODY" | json_field state)"
AUTHZ_URL="$(printf '%s' "$BEGIN_BODY" | json_field authorizeUrl)"
if [ -n "$STATE" ] \
   && printf '%s' "$AUTHZ_URL" | grep -q '^http.*/auth?' \
   && printf '%s' "$AUTHZ_URL" | grep -q 'code_challenge=' \
   && printf '%s' "$AUTHZ_URL" | grep -q 'code_challenge_method=S256' \
   && printf '%s' "$AUTHZ_URL" | grep -q 'connector_id=google' \
   && printf '%s' "$AUTHZ_URL" | grep -q "state=$STATE"; then
  pass "begin returns state + S256 PKCE + connector_id=google authorizeUrl"
else
  fail "begin response malformed"
  printf '        body: %s\n' "$BEGIN_BODY"
fi

# --- 3. framework validation: provider is required -----------------------------
echo "[3] request validation"
check "GET /api/auth/begin without provider -> 422" 422 "" "$BASE_URL/api/auth/begin"

# --- 4. session guards on protected endpoints ----------------------------------
echo "[4] protected endpoints require a session cookie"
check "GET /api/session without cookie"            401 "auth_no_session" "$BASE_URL/api/session"
check "GET /api/users without cookie"              401 "auth_no_session" "$BASE_URL/api/users"
check "GET /api/resources/aws without cookie"      401 "auth_no_session" "$BASE_URL/api/resources/aws"
check "GET /api/resources/nutanix without cookie"  401 "auth_no_session" "$BASE_URL/api/resources/nutanix"
check "GET /api/session with forged cookie"        401 "auth_invalid_session" \
  -H 'Cookie: libcloud_portal_sid=forged-garbage' "$BASE_URL/api/session"

# --- 5. auth guards ------------------------------------------------------------
echo "[5] auth guards"
check "POST /api/auth/exchange unknown state" 400 "auth_bad_state" \
  -X POST "$BASE_URL/api/auth/exchange" -H 'Content-Type: application/json' \
  -d '{"code":"x","state":"definitely-not-issued","provider":"google"}'
check "POST /api/auth/collapse empty pendingToken" 400 "auth_missing_pending_token" \
  -X POST "$BASE_URL/api/auth/collapse" -H 'Content-Type: application/json' \
  -d '{"pendingToken":"","decision":"link"}'

# --- 6. logout is safe without a session ---------------------------------------
echo "[6] logout"
check "POST /api/logout without cookie" 200 "" -X POST "$BASE_URL/api/logout"
LOGOUT_BODY="$(curl -s --max-time 10 -X POST "$BASE_URL/api/logout")"
if [ "$(printf '%s' "$LOGOUT_BODY" | json_field logged_out)" = "True" ]; then
  pass "POST /api/logout returns logged_out=true"
else
  fail "POST /api/logout body (want logged_out=true)"
  printf '        body: %s\n' "$LOGOUT_BODY"
fi

# --- 7. unknown route -> clean 404, not a crash --------------------------------
echo "[7] unknown route"
check "GET /api/does-not-exist -> 404" 404 "" "$BASE_URL/api/does-not-exist"

# --- 8. OpenAPI metadata is served ----------------------------------------------
echo "[8] OpenAPI"
if curl -fsS --max-time 10 "$BASE_URL/openapi.json" -o /tmp/st_openapi.json \
   && grep -q '"/health"' /tmp/st_openapi.json \
   && grep -q '"/api/session"' /tmp/st_openapi.json \
   && grep -q '"/api/auth/exchange"' /tmp/st_openapi.json; then
  pass "openapi.json served and lists core routes"
else
  fail "openapi.json missing or lacks core routes"
fi

# --- summary -------------------------------------------------------------------
echo
echo "=== Summary: $PASS passed, $FAIL failed, $SKIP skipped ==="
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed checks:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
