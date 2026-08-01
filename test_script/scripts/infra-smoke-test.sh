#!/usr/bin/env bash
# ─── Infrastructure Smoke Test ────────────────────────────────────────────────
# Verifies that the core infrastructure containers (portal, dex, lldap, vault,
# and identity-service) are running and responding correctly via curl.
#
# Usage:
#   chmod +x test_script/scripts/infra-smoke-test.sh
#   ./test_script/scripts/infra-smoke-test.sh [host]
#
# Defaults: host = localhost
#
# Notes:
#   - All containers are expected to be on the shared `libcloud_net` network.
#   - Port defaults: portal=3000, dex=5556, lldap=17170, vault=8200, identity=8766.
#   - Vault /v1/sys/seal-status returns 200 in EVERY state (uninit/sealed/unsealed),
#     so it reliably confirms the listener is up; a 200 does NOT mean Vault is
#     ready for secrets — for that, also check /v1/sys/health.

set -uo pipefail

HOST="${1:-localhost}"

# ── port defaults (override via env) ─────────────────────────────────────────
PORTAL_PORT="${PORTAL_PORT:-3000}"
DEX_PORT="${DEX_PORT:-5556}"
LLDAP_PORT="${LLDAP_PORT:-17170}"
VAULT_PORT="${VAULT_PORT:-8200}"
IDENTITY_PORT="${IDENTITY_PORT:-8766}"

PASS=0
FAIL=0

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; ((PASS++)); }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*"; ((FAIL++)); }
header() { printf '\n\033[1;36m── %s ──\033[0m\n' "$*"; }

# ── helpers ──────────────────────────────────────────────────────────────────

# check_container <container_name>
# Verifies a Docker container is running.
check_container() {
  local name="$1"
  if docker ps --filter "name=^/${name}$" --filter status=running -q 2>/dev/null | grep -q .; then
    green "Container $name is running"
  else
    red "Container $name is NOT running (docker ps found nothing)"
  fi
}

# check_code <desc> <expected_code> [curl args...]
# Checks only the HTTP status code. Returns 0 on pass, 1 on fail.
check_code() {
  local desc="$1" expected="$2"
  shift 2
  local code
  code=$(curl -s -o /tmp/infra_smoke_resp.txt -w '%{http_code}' "$@" 2>&1) || true
  if [[ "$code" == "$expected" ]]; then
    green "$desc (HTTP $code)"
    return 0
  else
    red "$desc — expected HTTP $expected, got $code"
    head -c 300 /tmp/infra_smoke_resp.txt 2>/dev/null || true
    echo ""
    return 1
  fi
}

# check_body <desc> <expected_code> <grep_pattern> [curl args...]
# Checks HTTP status code AND that the response body contains <grep_pattern>.
# Returns 0 on pass, 1 on fail.
check_body() {
  local desc="$1" expected="$2" pattern="$3"
  shift 3
  local code
  code=$(curl -s -o /tmp/infra_smoke_resp.txt -w '%{http_code}' "$@" 2>&1) || true
  if [[ "$code" == "$expected" ]] && grep -q "$pattern" /tmp/infra_smoke_resp.txt; then
    green "$desc (HTTP $code, body matches '$pattern')"
    return 0
  elif [[ "$code" != "$expected" ]]; then
    red "$desc — expected HTTP $expected, got $code"
    head -c 300 /tmp/infra_smoke_resp.txt 2>/dev/null || true
    echo ""
    return 1
  else
    red "$desc — HTTP $code but body missing '$pattern'"
    head -c 300 /tmp/infra_smoke_resp.txt 2>/dev/null || true
    echo ""
    return 1
  fi
}

# check_json <desc> <expected_code> [curl args...]
# Checks HTTP status code AND that the response body is valid JSON.
# Returns 0 on pass, 1 on fail.
check_json() {
  local desc="$1" expected="$2"
  shift 2
  local code
  code=$(curl -s -o /tmp/infra_smoke_resp.txt -w '%{http_code}' "$@" 2>&1) || true
  if [[ "$code" == "$expected" ]]; then
    if python3 -c "import json; json.load(open('/tmp/infra_smoke_resp.txt'))" 2>/dev/null; then
      green "$desc (HTTP $code, valid JSON)"
      return 0
    else
      red "$desc — HTTP $code but body is not valid JSON"
      head -c 300 /tmp/infra_smoke_resp.txt 2>/dev/null || true
      echo ""
      return 1
    fi
  else
    red "$desc — expected HTTP $expected, got $code"
    head -c 300 /tmp/infra_smoke_resp.txt 2>/dev/null || true
    echo ""
    return 1
  fi
}

# check_ctype <desc> <expected_mime_prefix> [curl url...]
# Validates the Content-Type response header starts with the expected MIME prefix.
check_ctype() {
  local desc="$1" expected_prefix="$2"
  shift 2
  local ctype
  ctype=$(curl -s -o /dev/null -w '%{content_type}' "$@" 2>&1) || true
  if [[ "$ctype" == "${expected_prefix}"* ]]; then
    green "$desc (Content-Type: $ctype)"
  else
    red "$desc — expected Content-Type starting with '$expected_prefix', got '$ctype'"
  fi
}

# ── header ───────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Infrastructure Smoke Test                         ║"
printf  "║   Host: %-46s║\n" "$HOST"
printf  "║   Portal: %-43s║\n" ":${PORTAL_PORT}"
printf  "║   Dex:    %-43s║\n" ":${DEX_PORT}"
printf  "║   LLDAP:  %-43s║\n" ":${LLDAP_PORT}"
printf  "║   Vault:  %-43s║\n" ":${VAULT_PORT}"
printf  "║   Identity: %-41s║\n" ":${IDENTITY_PORT}"
echo "╚══════════════════════════════════════════════════════╝"

# ═══════════════════════════════════════════════════════════════════════════════
# 0. Container health (docker ps)
# ═══════════════════════════════════════════════════════════════════════════════
header "0. Docker containers — running check"
check_container "portal"
check_container "dex"
check_container "lldap"
check_container "vault"
check_container "identity-service"

# ═══════════════════════════════════════════════════════════════════════════════
# 1. Portal (React SPA served by nginx, port 3000)
# ═══════════════════════════════════════════════════════════════════════════════
header "1. Portal (nginx / React SPA) — http://${HOST}:${PORTAL_PORT}"
check_code "Portal root (GET /) → 200" 200 \
  "http://${HOST}:${PORTAL_PORT}/"
check_body "Portal root returns HTML" 200 '<html' \
  "http://${HOST}:${PORTAL_PORT}/"
check_ctype "Portal serves HTML" "text/html" \
  "http://${HOST}:${PORTAL_PORT}/"
check_code "Portal static JS bundle" 200 \
  "http://${HOST}:${PORTAL_PORT}/static/js/main.js" || true

# ═══════════════════════════════════════════════════════════════════════════════
# 2. Dex (OIDC issuer, port 5556)
# ═══════════════════════════════════════════════════════════════════════════════
header "2. Dex OIDC — http://${HOST}:${DEX_PORT}"

DEX_DISCOVERY="http://${HOST}:${DEX_PORT}/dex/.well-known/openid-configuration"
DEX_KEYS="http://${HOST}:${DEX_PORT}/dex/keys"

check_json "OIDC discovery (GET /.well-known/openid-configuration) → 200" 200 \
  "$DEX_DISCOVERY"
check_ctype "OIDC discovery Content-Type is JSON" "application/json" \
  "$DEX_DISCOVERY"

# Verify key claims in discovery document
check_body "Discovery doc contains 'issuer'" 200 '"issuer"' \
  "$DEX_DISCOVERY"
check_body "Discovery doc contains 'jwks_uri'" 200 '"jwks_uri"' \
  "$DEX_DISCOVERY"
check_body "Discovery doc contains 'authorization_endpoint'" 200 '"authorization_endpoint"' \
  "$DEX_DISCOVERY"
check_body "Discovery doc contains 'token_endpoint'" 200 '"token_endpoint"' \
  "$DEX_DISCOVERY"

check_json "JWKS keys (GET /dex/keys) → 200" 200 \
  "$DEX_KEYS"
check_body "JWKS contains keys array" 200 '"keys"' \
  "$DEX_KEYS"

# Dex /dex/auth without query params renders the login page (200 HTML)
check_body "Auth endpoint (GET /dex/auth) → login page (200)" 200 '<html' \
  "http://${HOST}:${DEX_PORT}/dex/auth"

# Dex healthz (dex v2.41 has a /dex/healthz endpoint)
check_code "Dex healthz (GET /dex/healthz) → 200" 200 \
  "http://${HOST}:${DEX_PORT}/dex/healthz"

# ═══════════════════════════════════════════════════════════════════════════════
# 3. LLDAP (user directory, Web UI on port 17170)
# ═══════════════════════════════════════════════════════════════════════════════
header "3. LLDAP — http://${HOST}:${LLDAP_PORT}"

check_code "LLDAP Web UI root (GET /) → 200" 200 \
  "http://${HOST}:${LLDAP_PORT}/"
check_body "LLDAP returns HTML" 200 '<!doctype html>' \
  "http://${HOST}:${LLDAP_PORT}/"
check_ctype "LLDAP serves HTML" "text/html" \
  "http://${HOST}:${LLDAP_PORT}/"

# LLDAP login page (static asset)
check_code "LLDAP static assets reachable" 200 \
  "http://${HOST}:${LLDAP_PORT}/assets/main.js" || true

# ═══════════════════════════════════════════════════════════════════════════════
# 4. Vault (secret store, API on port 8200)
# ═══════════════════════════════════════════════════════════════════════════════
header "4. Vault — http://${HOST}:${VAULT_PORT}"

check_code "Vault seal-status (GET /v1/sys/seal-status) → 200" 200 \
  "http://${HOST}:${VAULT_PORT}/v1/sys/seal-status"
check_json "Seal-status returns JSON" 200 \
  "http://${HOST}:${VAULT_PORT}/v1/sys/seal-status"
check_body "Seal-status contains 'sealed' field" 200 '"sealed"' \
  "http://${HOST}:${VAULT_PORT}/v1/sys/seal-status"

# /v1/sys/health: 200 = initialized+unsealed+active, 429 if unsealed+standby,
# 501 if uninitialized, 503 if sealed. ANY code means the listener is alive.
check_code "Vault health (GET /v1/sys/health) → listener alive" 200 \
  "http://${HOST}:${VAULT_PORT}/v1/sys/health" || \
check_code "Vault health → 429 (standby), 501 (uninit), or 503 (sealed) are also alive" 429 \
  "http://${HOST}:${VAULT_PORT}/v1/sys/health" || \
check_code "Vault health → 501 = uninitialized (alive)" 501 \
  "http://${HOST}:${VAULT_PORT}/v1/sys/health" || \
check_code "Vault health → 503 = sealed (alive)" 503 \
  "http://${HOST}:${VAULT_PORT}/v1/sys/health"

# Vault UI
check_code "Vault UI (GET /ui/) → 200" 200 \
  "http://${HOST}:${VAULT_PORT}/ui/"

# ═══════════════════════════════════════════════════════════════════════════════
# 5. Identity Service (portal backend, port 8766)
# ═══════════════════════════════════════════════════════════════════════════════
header "5. Identity Service — http://${HOST}:${IDENTITY_PORT}"

check_code "Health endpoint (GET /health) → 200" 200 \
  "http://${HOST}:${IDENTITY_PORT}/health"
check_json "Health response is JSON" 200 \
  "http://${HOST}:${IDENTITY_PORT}/health"

# The identity service serves the /api/* contract documented in server/README.md.
# Protected routes return 401 (JSON with auth_no_session error) when no session
# cookie is present — this is correct behavior.

# /api/users — requires auth session; 401 expected without cookies
check_json "API users (GET /api/users) → 401 (protected, no session)" 401 \
  "http://${HOST}:${IDENTITY_PORT}/api/users"

# /api/session — session info; also protected
check_json "API session (GET /api/session) → 401 (protected, no session)" 401 \
  "http://${HOST}:${IDENTITY_PORT}/api/session"

# /api/auth/begin — starts the OAuth flow; returns JSON with authorizeUrl
# When provider=google is passed, returns 200 with the Dex authorize URL in JSON body
check_json "OAuth begin (GET /api/auth/begin?provider=google) → 200 + authorizeUrl" 200 \
  "http://${HOST}:${IDENTITY_PORT}/api/auth/begin?provider=google"
check_body "OAuth begin returns Dex authorizeUrl" 200 'authorizeUrl' \
  "http://${HOST}:${IDENTITY_PORT}/api/auth/begin?provider=google"

# /api/auth/begin — endpoint exists (bare GET returns 422 = missing provider param)
check_code "OAuth begin no provider → 422 (validation, endpoint exists)" 422 \
  "http://${HOST}:${IDENTITY_PORT}/api/auth/begin"

# ═══════════════════════════════════════════════════════════════════════════════
# 6. Cross-service connectivity checks
# ═══════════════════════════════════════════════════════════════════════════════
header "6. Cross-service connectivity"

# Dex → LLDAP: The discovery doc issuer should match. Just confirm Dex is
# serving the discovery doc (the issuer URL in it references LLDAP-backed Dex).
check_body "Dex issuer matches public hostname" 200 'cloudweave' \
  "$DEX_DISCOVERY"

# Vault seal-status → confirms Vault is listening (even if sealed)
check_json "Vault seal-status is valid JSON (cross-check)" 200 \
  "http://${HOST}:${VAULT_PORT}/v1/sys/seal-status"

# Portal → should reference the API base URL (check it's a React app)
check_body "Portal SPA has react root div" 200 '<div id="root"' \
  "http://${HOST}:${PORTAL_PORT}/"

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════"
printf "  Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
echo "════════════════════════════════════════════════════════"

exit "$FAIL"
