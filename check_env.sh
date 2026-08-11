#!/usr/bin/env bash
# check_env.sh — Validate the full libcloud deployment configuration.
#
# Run after setup.sh or after any manual config changes to verify that
# browser-facing URLs, container environment, and service connectivity are
# all consistent. Exits 0 when everything passes; non-zero if any check fails.
#
# Usage:
#   ./check_env.sh              # full check (uses docker)
#   ./check_env.sh --quick      # skip slow health / API / OIDC checks
#   ./check_env.sh --public     # also verify the PUBLIC hostname is reachable
#
# The script pins a baseline PUBLIC_HOSTNAME from the root .env and compares
# every sub-project against it. If a sub-project still says "localhost", the
# OAuth redirect flow will break for remote users — this is the #1 failure mode
# this script catches.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASS=0
WARN=0
FAIL=0
SKIP=0

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
QUICK=0
CHECK_PUBLIC=0

for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    --public) CHECK_PUBLIC=1 ;;
  esac
done

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
ok()   { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS + 1)); }
warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL + 1)); }
skip() { echo -e "  ${YELLOW}SKIP${NC} $1"; SKIP=$((SKIP + 1)); }

assert() {
  local msg="$1"; shift
  if "$@"; then ok "$msg"; else fail "$msg"; fi
}

header() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  $1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ---------------------------------------------------------------------------
# 0. Baseline: read the canonical PUBLIC_HOSTNAME from root .env
# ---------------------------------------------------------------------------
header "0. Baseline PUBLIC_HOSTNAME"

ROOT_ENV="${REPO_ROOT}/.env"
if [[ ! -f "$ROOT_ENV" ]]; then
  fail "Root .env missing at $ROOT_ENV — run setup.sh first"
  echo ""
  echo "  Total:  ${GREEN}${PASS} pass${NC}  ${YELLOW}${WARN} warn${NC}  ${RED}${FAIL} fail${NC}  ${YELLOW}${SKIP} skip${NC}"
  exit 1
fi

# shellcheck source=/dev/null
source <(grep -E '^PUBLIC_HOSTNAME=' "$ROOT_ENV")
PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME:-}"
if [[ -z "$PUBLIC_HOSTNAME" ]]; then
  fail "PUBLIC_HOSTNAME not set in $ROOT_ENV"
  echo ""
  echo "  Total:  ${GREEN}${PASS} pass${NC}  ${YELLOW}${WARN} warn${NC}  ${RED}${FAIL} fail${NC}  ${YELLOW}${SKIP} skip${NC}"
  exit 1
fi
ok "Root .env PUBLIC_HOSTNAME = ${PUBLIC_HOSTNAME}"

# Warn if it still looks like localhost (edge case: deliberate local dev)
if [[ "$PUBLIC_HOSTNAME" == "localhost" || "$PUBLIC_HOSTNAME" == "127.0.0.1" ]]; then
  warn "PUBLIC_HOSTNAME is '$PUBLIC_HOSTNAME' — remote users WILL NOT be able to log in"
fi

# ---------------------------------------------------------------------------
# 1. Sub-project .env files
# ---------------------------------------------------------------------------
header "1. Sub-project .env files"

check_env_file() {
  local label="$1"
  local file="$2"
  if [[ ! -f "$file" ]]; then
    fail "${label}: $file does not exist"
    return
  fi
  local cur
  cur=$(grep -E '^PUBLIC_HOSTNAME=' "$file" 2>/dev/null | head -1 | cut -d= -f2- || true)
  if [[ -z "$cur" ]]; then
    fail "${label}: PUBLIC_HOSTNAME= not found in $file"
  elif [[ "$cur" != "$PUBLIC_HOSTNAME" ]]; then
    fail "${label}: PUBLIC_HOSTNAME=${cur} (expected ${PUBLIC_HOSTNAME}) — fix: run setup.sh"
  else
    ok "${label}: PUBLIC_HOSTNAME=${cur}"
  fi
}

check_env_file "identity-service " "${REPO_ROOT}/identity_service/.env"
check_env_file "portal (server)" "${REPO_ROOT}/server/.env"
check_env_file "openfga-viz    " "${REPO_ROOT}/openfga_visualized/.env"

# ---------------------------------------------------------------------------
# 2. Dex config — redirect URIs
# ---------------------------------------------------------------------------
header "2. Dex config.yaml redirect URIs"

DEX_CONFIG="${REPO_ROOT}/dex/config.yaml"
if [[ ! -f "$DEX_CONFIG" ]]; then
  fail "Dex config.yaml missing at $DEX_CONFIG"
else
  # The portal client must have the public-host redirect URI
  # We look for the libcloud-portal staticClient block and its redirectURIs
  if grep -q "http://${PUBLIC_HOSTNAME}:3000/auth/callback" "$DEX_CONFIG"; then
    ok "Dex config has portal redirect for ${PUBLIC_HOSTNAME}:3000"
  else
    fail "Dex config MISSING redirect URI http://${PUBLIC_HOSTNAME}:3000/auth/callback"
  fi

  # The localhost redirect should also exist (for local-dev fallback)
  if grep -q "http://localhost:3000/auth/callback" "$DEX_CONFIG"; then
    ok "Dex config has localhost:3000 redirect (local-dev fallback)"
  else
    warn "Dex config missing localhost:3000 redirect (local dev will break)"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Dex generated env
# ---------------------------------------------------------------------------
header "3. dex/generated/dex.env"

DEX_ENV="${REPO_ROOT}/dex/generated/dex.env"
if [[ ! -f "$DEX_ENV" ]]; then
  fail "dex.env missing at $DEX_ENV — run setup.sh"
else
  cur=$(grep -E '^DEX_PORTAL_REDIRECT_URI=' "$DEX_ENV" 2>/dev/null | cut -d= -f2- || true)
  if [[ "$cur" == "http://${PUBLIC_HOSTNAME}:3000/auth/callback" ]]; then
    ok "DEX_PORTAL_REDIRECT_URI=${cur}"
  else
    fail "DEX_PORTAL_REDIRECT_URI=${cur:-<unset>} (expected http://${PUBLIC_HOSTNAME}:3000/auth/callback)"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Docker containers — presence + health
# ---------------------------------------------------------------------------
header "4. Containers"

REQUIRED_CONTAINERS=(
  "dex"
  "identity-service"
  "openfga"
  "openfga-postgres"
  "lldap"
  "vault"
  "portal"
)

for cname in "${REQUIRED_CONTAINERS[@]}"; do
  cid=$(sudo docker ps --filter "name=^${cname}$" --format '{{.ID}}' 2>/dev/null || true)
  if [[ -z "$cid" ]]; then
    fail "Container '${cname}' is NOT running"
    continue
  fi
  health=$(sudo docker inspect --format '{{ if .State.Health }}{{ .State.Health.Status }}{{ else }}no-healthcheck{{ end }}' "$cid" 2>/dev/null || echo "no-healthcheck")
  if [[ "$health" == "healthy" ]]; then
    ok "${cname}  (healthy)"
  elif [[ "$health" == "no-healthcheck" ]]; then
    ok "${cname}  (running, no healthcheck)"
  elif [[ "$health" == "starting" ]]; then
    warn "${cname}  (still starting — re-run in a few seconds)"
  else
    fail "${cname}  (health: ${health})"
  fi
done

# ---------------------------------------------------------------------------
# 5. Identity service container env
# ---------------------------------------------------------------------------
header "5. Identity service container environment"

IS_CID=$(sudo docker ps --filter name=^identity-service$ --format '{{.ID}}' 2>/dev/null || true)
if [[ -z "$IS_CID" ]]; then
  skip "identity-service not running"
else
  check_container_env() {
    local key="$1"
    local expect="$2"
    local val
    val=$(sudo docker exec identity-service printenv "$key" 2>/dev/null || true)
    if [[ "$val" == "$expect" ]]; then
      ok "${key}=${val}"
    else
      fail "${key}=${val:-<unset>} (expected ${expect})"
    fi
  }

  check_container_env "PUBLIC_HOSTNAME"            "${PUBLIC_HOSTNAME}"
  check_container_env "DEX_BASE_URL"               "http://${PUBLIC_HOSTNAME}:3000/dex"
  check_container_env "DEX_PORTAL_REDIRECT_URI"    "http://${PUBLIC_HOSTNAME}:3000/auth/callback"
  check_container_env "DEX_PORTAL_CLIENT_ID"       "libcloud-portal"
fi

# ---------------------------------------------------------------------------
# 6. Portal nginx + JS bundle
# ---------------------------------------------------------------------------
header "6. Portal (React bundle + nginx)"

PORTAL_CID=$(sudo docker ps --filter name=^portal$ --format '{{.ID}}' 2>/dev/null || true)
if [[ -z "$PORTAL_CID" ]]; then
  skip "portal not running"
else
  # 6a. nginx config proxies /dex/ -> dex:5556
  if sudo docker exec portal grep -q "proxy_pass http://dex:5556" /etc/nginx/conf.d/default.conf 2>/dev/null; then
    ok "nginx proxies /dex/ → dex:5556"
  else
    fail "nginx config missing /dex/ proxy_pass to dex:5556"
  fi

  # 6b. nginx config proxies /api/ -> identity-service:8766
  if sudo docker exec portal grep -q "proxy_pass http://identity-service:8766" /etc/nginx/conf.d/default.conf 2>/dev/null; then
    ok "nginx proxies /api/ → identity-service:8766"
  else
    fail "nginx config missing /api/ proxy_pass to identity-service:8766"
  fi

  # 6c. JS bundle must NOT contain localhost Dex/auth URLs (the #1 build-time mistake)
  JS_DIR="/usr/share/nginx/html/static/js"
  LOCALHOST_COUNT=$(sudo docker exec portal sh -c "grep -oh 'http://localhost:3000/auth/callback\|http://localhost:3000/dex' ${JS_DIR}/*.js 2>/dev/null | wc -l" 2>/dev/null || echo "0")
  LOCALHOST_COUNT=$(echo "$LOCALHOST_COUNT" | tr -d ' ')
  if [[ "$LOCALHOST_COUNT" -eq 0 ]]; then
    ok "JS bundle has NO localhost:3000 URLs (redirect_uri / dex_base)"
  else
    fail "JS bundle has ${LOCALHOST_COUNT} localhost:3000 URL(s) — rebuild the portal image"
  fi

  # 6d. JS bundle SHOULD contain the correct hostname
  CORRECT_COUNT=$(sudo docker exec portal sh -c "grep -oh 'http://${PUBLIC_HOSTNAME}:3000/auth/callback\|http://${PUBLIC_HOSTNAME}:3000/dex' ${JS_DIR}/*.js 2>/dev/null | wc -l" 2>/dev/null || echo "0")
  CORRECT_COUNT=$(echo "$CORRECT_COUNT" | tr -d ' ')
  if [[ "$CORRECT_COUNT" -gt 0 ]]; then
    ok "JS bundle has ${CORRECT_COUNT} reference(s) to ${PUBLIC_HOSTNAME}:3000"
  else
    fail "JS bundle has ZERO references to ${PUBLIC_HOSTNAME}:3000 — rebuild the portal image"
  fi
fi

# ---------------------------------------------------------------------------
# 7. Dex OIDC discovery endpoint
# ---------------------------------------------------------------------------
header "7. Dex OIDC discovery"

DEX_DISC="http://localhost:5556/dex/.well-known/openid-configuration"
if curl -fsS --max-time 5 "$DEX_DISC" > /dev/null 2>&1; then
  ok "Dex OIDC discovery reachable at $DEX_DISC"
  issuer=$(curl -sS --max-time 5 "$DEX_DISC" | python3 -c "import sys,json; print(json.load(sys.stdin).get('issuer',''))" 2>/dev/null || true)
  if [[ -n "$issuer" ]]; then
    ok "Dex issuer = ${issuer}"
  else
    warn "Could not parse issuer from OIDC discovery"
  fi
else
  fail "Dex OIDC discovery NOT reachable at $DEX_DISC"
fi

# ---------------------------------------------------------------------------
# 8. Identity service /api/auth/begin — authorize URL
# ---------------------------------------------------------------------------
header "8. /api/auth/begin (authorize URL)"

AUTH_BEGIN="http://localhost:8766/api/auth/begin?provider=lldap&redirect_uri=http://${PUBLIC_HOSTNAME}:3000/auth/callback"
AUTH_JSON=$(curl -sS --max-time 5 "$AUTH_BEGIN" 2>/dev/null || true)
if [[ -z "$AUTH_JSON" ]]; then
  fail "Cannot reach /api/auth/begin — identity service not responding"
else
  authorize_url=$(echo "$AUTH_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('authorizeUrl',''))" 2>/dev/null || true)
  if [[ -z "$authorize_url" ]]; then
    fail "Could not parse authorizeUrl from /api/auth/begin response"
    echo "       raw: $(echo "$AUTH_JSON" | head -c 200)"
  elif echo "$authorize_url" | grep -q "localhost"; then
    fail "authorizeUrl still points to localhost: ${authorize_url}"
  elif echo "$authorize_url" | grep -q "${PUBLIC_HOSTNAME}"; then
    ok "authorizeUrl uses ${PUBLIC_HOSTNAME}"
  else
    warn "authorizeUrl hostname is neither localhost nor ${PUBLIC_HOSTNAME}: ${authorize_url}"
  fi

  # Also check the redirect_uri parameter inside the authorizeUrl
  decoded_redirect=$(echo "$authorize_url" | python3 -c "
import sys, urllib.parse
url = sys.stdin.read().strip()
params = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(url).query))
print(params.get('redirect_uri',''))
" 2>/dev/null || true)
  if [[ "$decoded_redirect" == "http://${PUBLIC_HOSTNAME}:3000/auth/callback" ]]; then
    ok "redirect_uri parameter = ${decoded_redirect}"
  elif [[ -n "$decoded_redirect" ]]; then
    fail "redirect_uri parameter = ${decoded_redirect} (expected http://${PUBLIC_HOSTNAME}:3000/auth/callback)"
  fi
fi

# Only run these when not in quick mode
if [[ "$QUICK" -eq 0 ]]; then
  # -------------------------------------------------------------------------
  # 9. OpenFGA health
  # -------------------------------------------------------------------------
  header "9. OpenFGA health"

  FGA_HEALTH=$(curl -sS --max-time 5 "http://localhost:8080/healthz" 2>/dev/null || true)
  # OpenFGA >= v1.16 returns JSON: {"status":"SERVING"}; older returns plain "OK"
  if echo "$FGA_HEALTH" | grep -qE '"status"\s*:\s*"SERVING"' || [[ "$FGA_HEALTH" == "OK" ]]; then
    ok "OpenFGA /healthz serving"
  else
    fail "OpenFGA /healthz returned: ${FGA_HEALTH:-<empty>}"
  fi

  # -------------------------------------------------------------------------
  # 10. Vault health
  # -------------------------------------------------------------------------
  header "10. Vault health"

  VAULT_HEALTH=$(curl -sS --max-time 5 "http://localhost:8200/v1/sys/health" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('initialized', False))" 2>/dev/null || echo "False")
  if [[ "$VAULT_HEALTH" == "True" ]]; then
    ok "Vault is initialized and reachable"
  else
    warn "Vault health check returned: ${VAULT_HEALTH:-<empty>} (may be unsealed by setup.sh)"
  fi

  # -------------------------------------------------------------------------
  # 11. libcloud REST API health
  # -------------------------------------------------------------------------
  header "11. libcloud REST API"

  REST_HEALTH=$(curl -sS --max-time 5 "http://localhost:8765/health" 2>/dev/null || true)
  if [[ -n "$REST_HEALTH" ]]; then
    ok "libcloud REST API /health reachable"
  else
    warn "libcloud REST API /health not responding"
  fi

  # -------------------------------------------------------------------------
  # 12. LLDAP reachability
  # -------------------------------------------------------------------------
  header "12. LLDAP"

  if curl -fsS --max-time 5 "http://localhost:17170/" > /dev/null 2>&1; then
    ok "LLDAP web UI reachable on port 17170"
  else
    warn "LLDAP web UI not reachable on port 17170"
  fi
fi

# ---------------------------------------------------------------------------
# 13. PUBLIC hostname reachability (optional)
# ---------------------------------------------------------------------------
if [[ "$CHECK_PUBLIC" -eq 1 ]]; then
  header "13. Public hostname reachability"
  if curl -fsS --max-time 5 "http://${PUBLIC_HOSTNAME}:3000/" > /dev/null 2>&1; then
    ok "${PUBLIC_HOSTNAME}:3000 is reachable"
  else
    warn "${PUBLIC_HOSTNAME}:3000 is NOT reachable — check DNS / firewall / /etc/hosts"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "══════════════════════════════════════════════════════════════════"
printf "  Total:  ${GREEN}%3d pass${NC}  ${YELLOW}%3d warn${NC}  ${RED}%3d fail${NC}  ${YELLOW}%3d skip${NC}\n" "$PASS" "$WARN" "$FAIL" "$SKIP"
echo "══════════════════════════════════════════════════════════════════"

if [[ "$FAIL" -gt 0 ]]; then
  echo ""
  echo "Fix the FAIL items above, then re-run this script."
  echo "Common fixes:"
  echo "  1. Run:  ./setup.sh       (regenerates configs + restarts containers)"
  echo "  2. Rebuild portal:  cd server && \\"
  echo "       PUBLIC_HOSTNAME=${PUBLIC_HOSTNAME} docker compose build --no-cache && \\"
  echo "       PUBLIC_HOSTNAME=${PUBLIC_HOSTNAME} docker compose up -d --force-recreate"
  echo "  3. Recreate identity-service:  cd identity_service && \\"
  echo "       PUBLIC_HOSTNAME=${PUBLIC_HOSTNAME} docker compose up -d --force-recreate"
  exit 1
fi

echo ""
echo "All checks passed. The stack is correctly configured for ${PUBLIC_HOSTNAME}."
exit 0
