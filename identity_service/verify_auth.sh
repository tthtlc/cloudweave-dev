#!/usr/bin/env bash
# Verification script for Path 1 (state/PKCE + pending-identity hardening).
#
# Exercises the identity-service auth path against a running service and
# asserts each hardening guarantee holds. Run it any time after
# `docker compose up -d --build` from the identity_service/ directory.
#
# Usage:
#   ./verify_auth.sh                              # defaults to http://localhost:8766
#   BASE_URL=http://login.cloudweave.xyz:8766 ./verify_auth.sh
#   BASE_URL=http://localhost:8766 ./verify_auth.sh
#
# Exit status: 0 if all checks pass, 1 if any fail.

set -u

BASE_URL="${BASE_URL:-http://localhost:8766}"
BASE_URL="${BASE_URL%/}"  # strip trailing slash

PASS=0
FAIL=0
FAILURES=()

# --- helpers -----------------------------------------------------------------
# http_code + body error code check. Usage: check <name> <expected_http> <expected_error_code> <curl-args...>
check() {
  local name="$1" exp_http="$2" exp_err="$3"; shift 3
  local body http err
  body="$(curl -s -o /tmp/v_body -w '%{http_code}' "$@")"
  http="$body"
  body="$(cat /tmp/v_body)"
  err="$(printf '%s' "$body" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("error",""))
except Exception: print("")' 2>/dev/null)"
  local ok=1
  if [ "$http" != "$exp_http" ]; then ok=0; fi
  if [ -n "$exp_err" ] && [ "$err" != "$exp_err" ]; then ok=0; fi
  if [ "$ok" = "1" ]; then
    printf '  PASS  %s  [http=%s error=%s]\n' "$name" "$http" "$err"
    PASS=$((PASS+1))
  else
    printf '  FAIL  %s  [want http=%s error=%s; got http=%s error=%s]\n' \
      "$name" "$exp_http" "$exp_err" "$http" "$err"
    FAIL=$((FAIL+1))
    FAILURES+=("$name")
    printf '        body: %s\n' "$body"
  fi
}

# GET that returns parsed JSON field. Usage: json_get <url> <python-expr>
json_get() {
  curl -fsS "$1" | python3 -c 'import sys,json; d=json.load(sys.stdin); print('"$2"')'
}

echo "=== Path 1 verification: state/PKCE + pending-identity hardening ==="
echo "    BASE_URL=$BASE_URL"
echo

# --- 1. health ---------------------------------------------------------------
echo "[1] health"
check "GET /health" 200 "" "$BASE_URL/health"

# --- 2. /api/auth/begin returns a proper PKCE authorize URL ------------------
echo "[2] /api/auth/begin (google)"
BEGIN_BODY="$(curl -fsS "$BASE_URL/api/auth/begin?provider=google")"
STATE_GOOGLE="$(printf '%s' "$BEGIN_BODY" | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])')"
AUTHZ_URL="$(printf '%s' "$BEGIN_BODY" | python3 -c 'import sys,json;print(json.load(sys.stdin)["authorizeUrl"])')"
if [ -n "$STATE_GOOGLE" ] && printf '%s' "$AUTHZ_URL" | grep -q 'code_challenge=' \
   && printf '%s' "$AUTHZ_URL" | grep -q 'code_challenge_method=S256' \
   && printf '%s' "$AUTHZ_URL" | grep -q 'connector_id=google' \
   && printf '%s' "$AUTHZ_URL" | grep -q "state=$STATE_GOOGLE"; then
  printf '  PASS  begin returns state + S256 code_challenge + connector_id\n'
  PASS=$((PASS+1))
else
  printf '  FAIL  begin response missing PKCE/connector_id/state\n        %s\n' "$BEGIN_BODY"
  FAIL=$((FAIL+1)); FAILURES+=("begin google shape")
fi

echo "[3] /api/auth/begin (github)"
BEGIN_BODY="$(curl -fsS "$BASE_URL/api/auth/begin?provider=github")"
STATE_GITHUB="$(printf '%s' "$BEGIN_BODY" | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])')"
AUTHZ_URL="$(printf '%s' "$BEGIN_BODY" | python3 -c 'import sys,json;print(json.load(sys.stdin)["authorizeUrl"])')"
if printf '%s' "$AUTHZ_URL" | grep -q 'connector_id=github' && [ -n "$STATE_GITHUB" ]; then
  printf '  PASS  begin github returns connector_id=github + state\n'
  PASS=$((PASS+1))
else
  printf '  FAIL  begin github missing connector_id/state\n        %s\n' "$BEGIN_BODY"
  FAIL=$((FAIL+1)); FAILURES+=("begin github shape")
fi

# --- 4. exchange with bogus state -> 400 auth_bad_state ----------------------
echo "[4] exchange rejects unknown state (CSRF)"
check "POST /api/auth/exchange bogus state" 400 "auth_bad_state" \
  -X POST "$BASE_URL/api/auth/exchange" -H 'Content-Type: application/json' \
  -d '{"code":"x","state":"definitely-not-issued","provider":"google"}'

# --- 5. state is single-use --------------------------------------------------
echo "[5] state is single-use (begin -> consume -> reuse rejected)"
FRESH_STATE="$(curl -fsS "$BASE_URL/api/auth/begin?provider=google" | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])')"
# 1st exchange: real state + bogus code -> reaches Dex, which rejects the code;
# the state is consumed (popped) regardless.
check "  1st exchange (real state, bogus code -> Dex rejects)" 400 "auth_dex_exchange_failed" \
  -X POST "$BASE_URL/api/auth/exchange" -H 'Content-Type: application/json' \
  -d "{\"code\":\"bogus\",\"state\":\"$FRESH_STATE\",\"provider\":\"google\"}"
# 2nd exchange: same state must now be rejected as reused/unknown.
check "  2nd exchange (same state reused -> rejected)" 400 "auth_bad_state" \
  -X POST "$BASE_URL/api/auth/exchange" -H 'Content-Type: application/json' \
  -d "{\"code\":\"bogus\",\"state\":\"$FRESH_STATE\",\"provider\":\"google\"}"

# --- 6. collapse requires a pending token -----------------------------------
echo "[6] collapse requires server-issued pending token"
check "POST /api/auth/collapse empty pendingToken" 400 "auth_missing_pending_token" \
  -X POST "$BASE_URL/api/auth/collapse" -H 'Content-Type: application/json' \
  -d '{"pendingToken":"","decision":"link"}'
check "POST /api/auth/collapse bad pendingToken" 401 "auth_bad_pending_token" \
  -X POST "$BASE_URL/api/auth/collapse" -H 'Content-Type: application/json' \
  -d '{"pendingToken":"not-a-jwt","decision":"link"}'

# --- 7. cookie-auth on protected endpoints ----------------------------------
echo "[7] protected endpoints require a session cookie"
check "GET /api/session without cookie" 401 "auth_no_session" "$BASE_URL/api/session"
check "GET /api/users without cookie" 401 "auth_no_session" "$BASE_URL/api/users"
check "GET /api/resources/aws without cookie" 401 "auth_no_session" "$BASE_URL/api/resources/aws"
check "GET /api/resources/nutanix without cookie" 401 "auth_no_session" "$BASE_URL/api/resources/nutanix"

# --- 8. all 10 contract routes are registered --------------------------------
echo "[8] OpenAPI lists all 10 contract routes + /health"
curl -fsS "$BASE_URL/openapi.json" -o /tmp/v_openapi.json
ROUTES="$(python3 - /tmp/v_openapi.json <<'PY'
import sys, json
with open(sys.argv[1]) as f:
    d = json.load(f)
expected = [
    "/api/session", "/api/auth/exchange", "/api/auth/collapse", "/api/logout",
    "/api/users", "/api/users/{internal_id}/role",
    "/api/resources/aws", "/api/resources/nutanix",
    "/api/provision/aws", "/api/provision/nutanix", "/health",
]
have = set(d["paths"])
missing = [r for r in expected if r not in have]
print("OK" if not missing else "MISSING:" + ",".join(missing))
PY
)"
if [ "$ROUTES" = "OK" ]; then
  printf '  PASS  all 11 routes present\n'
  PASS=$((PASS+1))
else
  printf '  FAIL  %s\n' "$ROUTES"
  FAIL=$((FAIL+1)); FAILURES+=("openapi routes")
fi

# --- summary -----------------------------------------------------------------
echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed checks:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
