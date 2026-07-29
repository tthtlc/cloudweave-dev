#!/usr/bin/env bash
# ─── Master System Test ──────────────────────────────────────────────────────
# Runs all component test suites in sequence against the live system.
#
# Sources: identity_test.md, libcloud_rest_api_test.md,
#          openfga_and_postgres_test.md, portal_dex_lldap_vault_test.md,
#          stoplight_emulator_test.md, stoplight_mock_test.md
#
# Usage:
#   chmod +x test_script/scripts/master_test.sh
#   ./test_script/scripts/master_test.sh                 # defaults: localhost
#   ./test_script/scripts/master_test.sh my-host.example.com
#
#   # Skip individual suites via env:
#   SKIP_INFRA=1 SKIP_IDENTITY=1 ./test_script/scripts/master_test.sh
#
#   # Generate FGA token before running (enables full FGA test coverage):
#   GEN_FGA_TOKEN=1 ./test_script/scripts/master_test.sh
#
#   # Override individual ports:
#   PORTAL_PORT=4000 DEX_PORT=5557 ./test_script/scripts/master_test.sh
#
# Exit code: total number of failed checks across all suites (0 = all pass).

set -uo pipefail

# ── Resolve repo root (works regardless of where the script is called from) ──
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

HOST="${1:-localhost}"

# ── Suite skip flags (set to 1 to skip) ─────────────────────────────────────
SKIP_INFRA="${SKIP_INFRA:-0}"
SKIP_FGA="${SKIP_FGA:-0}"
SKIP_LIBCLOUD="${LIBCLOUD_REST:-${SKIP_LIBCLOUD:-0}}"
SKIP_IDENTITY="${SKIP_IDENTITY:-0}"
SKIP_PRISM="${SKIP_PRISM:-0}"
SKIP_EMULATOR="${SKIP_EMULATOR:-0}"
GEN_FGA_TOKEN="${GEN_FGA_TOKEN:-0}"

# ── Port defaults (override via env) ────────────────────────────────────────
PORTAL_PORT="${PORTAL_PORT:-3000}"
DEX_PORT="${DEX_PORT:-5556}"
LLDAP_PORT="${LLDAP_PORT:-17170}"
VAULT_PORT="${VAULT_PORT:-8200}"
IDENTITY_PORT="${IDENTITY_PORT:-8766}"
FGA_PORT="${FGA_PORT:-8080}"
LIBCLOUD_PORT="${LIBCLOUD_PORT:-8765}"
PRISM_PORT="${PRISM_PORT:-4010}"
EMULATOR_PORT="${EMULATOR_PORT:-9440}"

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
SUITE_FAILURES=()

# ── Helpers ──────────────────────────────────────────────────────────────────

banner() {
  printf '\n\033[1;35m╔══════════════════════════════════════════════════════╗\033[0m\n'
  printf '\033[1;35m║  %-52s║\033[0m\n' "$1"
  printf '\033[1;35m╚══════════════════════════════════════════════════════╝\033[0m\n'
}

suite_header() {
  printf '\n\033[1;33m━━━ %s ━━━\033[0m\n' "$1"
}

run_suite() {
  local label="$1" script="$2"
  shift 2
  suite_header "$label"
  if [[ -x "$script" ]]; then
    "$script" "$@"
    return $?
  else
    echo "  ⚠ script not found or not executable: $script"
    return 0
  fi
}

# Parse "Results: N passed, M failed, K skipped" from suite output.
# Sets PASS_/FAIL_/SKIP_ vars for the caller.
capture_counts() {
  local output="$1"
  PASS_=$(echo "$output" | grep -oP '\d+(?= passed)' | tail -n1)
  FAIL_=$(echo "$output" | grep -oP '\d+(?= failed)' | tail -n1)
  SKIP_=$(echo "$output" | grep -oP '\d+(?= skipped)' | tail -n1)
  PASS_="${PASS_:-0}"
  FAIL_="${FAIL_:-0}"
  SKIP_="${SKIP_:-0}"
}

# ── Pre-flight: ensure all scripts are executable ────────────────────────────

cd "$REPO_ROOT"

SCRIPTS=(
  "test_script/scripts/infra-smoke-test.sh"
  "openfga_postgres/scripts/fga-test.sh"
  "libcloud.rest/scripts/rest-api-test.sh"
  "identity_service/smoke_test.sh"
  "stoplight_mock/scripts/prism-test.sh"
  "stoplight_mock/scripts/test-emulator.sh"
)

for s in "${SCRIPTS[@]}"; do
  if [[ -f "$s" ]]; then
    chmod +x "$s"
  fi
done

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Master System Test                                ║"
printf  "║   Host: %-44s║\n" "$HOST"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Suites: infra-smoke | fga | libcloud-rest | identity | prism | emulator"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# 1. Infrastructure smoke test (portal, dex, lldap, vault, identity-service)
#    Source: portal_dex_lldap_vault_test.md
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$SKIP_INFRA" -eq 0 ]]; then
  banner "1/6  Infrastructure Smoke Test"
  echo "  Services: portal(:$PORTAL_PORT) dex(:$DEX_PORT) lldap(:$LLDAP_PORT)"
  echo "            vault(:$VAULT_PORT) identity(:$IDENTITY_PORT)"
  echo ""

  # Usage from portal_dex_lldap_vault_test.md:
  #   ./test_script/scripts/infra-smoke-test.sh [host]
  #   PORTAL_PORT=4000 DEX_PORT=5557 ./test_script/scripts/infra-smoke-test.sh
  INFRA_OUTPUT=$(PORTAL_PORT="$PORTAL_PORT" \
                 DEX_PORT="$DEX_PORT" \
                 LLDAP_PORT="$LLDAP_PORT" \
                 VAULT_PORT="$VAULT_PORT" \
                 IDENTITY_PORT="$IDENTITY_PORT" \
                 "$REPO_ROOT/test_script/scripts/infra-smoke-test.sh" "$HOST" 2>&1)
  INFRA_RC=$?
  echo "$INFRA_OUTPUT"
  capture_counts "$INFRA_OUTPUT"
  TOTAL_PASS=$((TOTAL_PASS + PASS_))
  TOTAL_FAIL=$((TOTAL_FAIL + FAIL_))
  TOTAL_SKIP=$((TOTAL_SKIP + SKIP_))
  [[ "$INFRA_RC" -ne 0 ]] && SUITE_FAILURES+=("infra-smoke (rc=$INFRA_RC)")
else
  echo "  ⚠ Skipped: SKIP_INFRA=1"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 2. OpenFGA + Postgres test
#    Source: openfga_and_postgres_test.md
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$SKIP_FGA" -eq 0 ]]; then
  banner "2/6  OpenFGA + Postgres Test"
  echo "  FGA URL: http://${HOST}:${FGA_PORT}"
  echo ""

  # Optionally generate/refresh superadmin JWT for full test coverage.
  # From openfga_and_postgres_test.md:
  #   ./test_script/scripts/superadmin_auth.sh
  #   ./openfga_postgres/scripts/fga-test.sh
  if [[ "$GEN_FGA_TOKEN" -eq 1 ]]; then
    echo "  → Generating superadmin JWT..."
    if [[ -x "$REPO_ROOT/test_script/scripts/superadmin_auth.sh" ]]; then
      source "$REPO_ROOT/test_script/scripts/superadmin_auth.sh" 2>/dev/null || true
      echo "  → SUPERADMIN_JWT=${SUPERADMIN_JWT:+<set>}"
    else
      echo "  ⚠ superadmin_auth.sh not found — FGA auth'd tests may skip"
    fi
  fi

  # Usage from openfga_and_postgres_test.md:
  #   ./openfga_postgres/scripts/fga-test.sh [fga_url] [pg_container] [fga_container]
  #   FGA_API_TOKEN=<token> ./openfga_postgres/scripts/fga-test.sh
  #   SUPERADMIN_JWT=<jwt>  ./openfga_postgres/scripts/fga-test.sh
  FGA_OUTPUT=$(FGA_API_TOKEN="${FGA_API_TOKEN:-}" \
               SUPERADMIN_JWT="${SUPERADMIN_JWT:-}" \
               "$REPO_ROOT/openfga_postgres/scripts/fga-test.sh" \
                 "http://${HOST}:${FGA_PORT}" \
                 "openfga-postgres" \
                 "openfga" 2>&1)
  FGA_RC=$?
  echo "$FGA_OUTPUT"
  capture_counts "$FGA_OUTPUT"
  TOTAL_PASS=$((TOTAL_PASS + PASS_))
  TOTAL_FAIL=$((TOTAL_FAIL + FAIL_))
  TOTAL_SKIP=$((TOTAL_SKIP + SKIP_))
  [[ "$FGA_RC" -ne 0 ]] && SUITE_FAILURES+=("fga-test (rc=$FGA_RC)")
else
  echo "  ⚠ Skipped: SKIP_FGA=1"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 3. Libcloud REST API test
#    Source: libcloud_rest_api_test.md
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$SKIP_LIBCLOUD" -eq 0 ]]; then
  banner "3/6  Libcloud REST API Test"
  echo "  API URL: http://${HOST}:${LIBCLOUD_PORT}"
  echo ""

  # Usage from libcloud_rest_api_test.md:
  #   ./libcloud.rest/scripts/rest-api-test.sh [base_url] [container]
  #   BEARER_TOKEN="eyJ..." ./libcloud.rest/scripts/rest-api-test.sh
  #   SKIP_LOGIN_TEST=1 ./libcloud.rest/scripts/rest-api-test.sh
  LIBCLOUD_OUTPUT=$(SKIP_LOGIN_TEST="${SKIP_LOGIN_TEST:-1}" \
                    BEARER_TOKEN="${BEARER_TOKEN:-}" \
                    "$REPO_ROOT/libcloud.rest/scripts/rest-api-test.sh" \
                      "http://${HOST}:${LIBCLOUD_PORT}" \
                      "libcloud-rest-api" 2>&1)
  LIBCLOUD_RC=$?
  echo "$LIBCLOUD_OUTPUT"
  capture_counts "$LIBCLOUD_OUTPUT"
  TOTAL_PASS=$((TOTAL_PASS + PASS_))
  TOTAL_FAIL=$((TOTAL_FAIL + FAIL_))
  TOTAL_SKIP=$((TOTAL_SKIP + SKIP_))
  [[ "$LIBCLOUD_RC" -ne 0 ]] && SUITE_FAILURES+=("libcloud-rest (rc=$LIBCLOUD_RC)")
else
  echo "  ⚠ Skipped: SKIP_LIBCLOUD=1"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 4. Identity Service smoke test
#    Source: identity_test.md
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$SKIP_IDENTITY" -eq 0 ]]; then
  banner "4/6  Identity Service Smoke Test"
  echo "  URL: http://${HOST}:${IDENTITY_PORT}"
  echo ""

  # Usage from identity_test.md:
  #   identity_service/smoke_test.sh
  #   BASE_URL=http://login.quest4science.xyz:8766 identity_service/smoke_test.sh
  IDENTITY_OUTPUT=$(BASE_URL="http://${HOST}:${IDENTITY_PORT}" \
                    CONTAINER_NAME="identity-service" \
                    "$REPO_ROOT/identity_service/smoke_test.sh" 2>&1)
  IDENTITY_RC=$?
  echo "$IDENTITY_OUTPUT"
  capture_counts "$IDENTITY_OUTPUT"
  TOTAL_PASS=$((TOTAL_PASS + PASS_))
  TOTAL_FAIL=$((TOTAL_FAIL + FAIL_))
  TOTAL_SKIP=$((TOTAL_SKIP + SKIP_))
  [[ "$IDENTITY_RC" -ne 0 ]] && SUITE_FAILURES+=("identity-smoke (rc=$IDENTITY_RC)")
else
  echo "  ⚠ Skipped: SKIP_IDENTITY=1"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 5. Prism mock server test
#    Source: stoplight_mock_test.md
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$SKIP_PRISM" -eq 0 ]]; then
  banner "5/6  Prism Mock Server Test"
  echo "  URL: http://${HOST}:${PRISM_PORT}"
  echo ""

  # Usage from stoplight_mock_test.md:
  #   stoplight_mock/scripts/prism-test.sh [prism_url] [container_name]
  PRISM_OUTPUT=$("$REPO_ROOT/stoplight_mock/scripts/prism-test.sh" \
                   "http://${HOST}:${PRISM_PORT}" \
                   "stoplight_mock-prism-1" 2>&1)
  PRISM_RC=$?
  echo "$PRISM_OUTPUT"
  capture_counts "$PRISM_OUTPUT"
  TOTAL_PASS=$((TOTAL_PASS + PASS_))
  TOTAL_FAIL=$((TOTAL_FAIL + FAIL_))
  TOTAL_SKIP=$((TOTAL_SKIP + SKIP_))
  [[ "$PRISM_RC" -ne 0 ]] && SUITE_FAILURES+=("prism-test (rc=$PRISM_RC)")
else
  echo "  ⚠ Skipped: SKIP_PRISM=1"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 6. Emulator test
#    Source: stoplight_emulator_test.md
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$SKIP_EMULATOR" -eq 0 ]]; then
  banner "6/6  Nutanix Emulator Test"
  echo "  URL: https://${HOST}:${EMULATOR_PORT}"
  echo ""

  # Usage from stoplight_emulator_test.md:
  #   ./stoplight_mock/scripts/test-emulator.sh [base_url]
  EMULATOR_OUTPUT=$("$REPO_ROOT/stoplight_mock/scripts/test-emulator.sh" \
                      "https://${HOST}:${EMULATOR_PORT}" 2>&1)
  EMULATOR_RC=$?
  echo "$EMULATOR_OUTPUT"
  capture_counts "$EMULATOR_OUTPUT"
  TOTAL_PASS=$((TOTAL_PASS + PASS_))
  TOTAL_FAIL=$((TOTAL_FAIL + FAIL_))
  TOTAL_SKIP=$((TOTAL_SKIP + SKIP_))
  [[ "$EMULATOR_RC" -ne 0 ]] && SUITE_FAILURES+=("emulator-test (rc=$EMULATOR_RC)")
else
  echo "  ⚠ Skipped: SKIP_EMULATOR=1"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Grand Summary
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Master Test Summary                               ║"
echo "╚══════════════════════════════════════════════════════╝"
printf "  Total: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m" "$TOTAL_PASS" "$TOTAL_FAIL"
if [[ "$TOTAL_SKIP" -gt 0 ]]; then
  printf ", \033[33m%d skipped\033[0m" "$TOTAL_SKIP"
fi
echo ""

if [[ ${#SUITE_FAILURES[@]} -gt 0 ]]; then
  echo ""
  echo "  Suites with failures:"
  for s in "${SUITE_FAILURES[@]}"; do
    printf '    \033[31m✗\033[0m %s\n' "$s"
  done
fi

echo ""
echo "════════════════════════════════════════════════════════"
echo "  Scripts exercised:"
echo "    1. test_script/scripts/infra-smoke-test.sh"
echo "    2. openfga_postgres/scripts/fga-test.sh"
echo "    3. libcloud.rest/scripts/rest-api-test.sh"
echo "    4. identity_service/smoke_test.sh"
echo "    5. stoplight_mock/scripts/prism-test.sh"
echo "    6. stoplight_mock/scripts/test-emulator.sh"
echo "════════════════════════════════════════════════════════"

exit "$TOTAL_FAIL"
