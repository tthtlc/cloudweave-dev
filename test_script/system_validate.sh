#!/usr/bin/env bash
# system_validate.sh
# ==================
# Consolidated end-to-end validation harness for the libcloud security stack:
#
#   Client → Dex (OIDC) → LLDAP (user directory, via LDAP connector)
#         → identity-service (portal backend)
#         → libcloud REST (FastAPI, OIDC + OpenFGA)
#         → OpenFGA (authorization) → Vault (backend cloud credentials)
#         → AWS / Nutanix (via Stoplight Prism + Nutanix emulator in dev)
#
# This is the single entry point that folds together every test layer that used
# to live in separate scripts:
#
#   * inline security-stack validation (formerly here in system_validate.sh):
#       A. infra        — shared network + container health
#       B. lldap        — superadmin + per-cloud owners/admins/viewers + binds
#       C. dex          — no static users, LDAP connector, discovery + login path
#       D. rest         — OIDC auth mode, no local/static user directory
#       E. superadmin   — Dex login as superadmin yields a valid JWT; OpenFGA
#                         bootstrap refuses without it
#       F. tenant-creds — set_tenant_credentials denies non-owners
#       G. oidc         — idp_login.py yields a JWT with the expected email
#       H. provision    — provision_aws/nutanix.sh: admin allow + viewer
#                         read-only short-circuit (deny is covered by F + fga)
#
#   * component suites (formerly orchestrated by scripts/master_test.sh):
#       smoke      — test_script/scripts/infra-smoke-test.sh
#       fga        — openfga_postgres/scripts/fga-test.sh
#       rest-api   — libcloud.rest/scripts/rest-api-test.sh
#       identity   — identity_service/smoke_test.sh
#       prism      — stoplight_mock/scripts/prism-test.sh
#       emulator   — stoplight_mock/scripts/test-emulator.sh
#
#   * REST API correctness (formerly run standalone):
#       authz      — test_script/test_all_rest_api_authenticated.py
#                    (every route must require auth)
#       openapi    — test_script/scripts/openapi_rest_test.py
#                    (OpenAPI-driven read pass; FULL=1 adds CRUD lifecycle)
#
#   * libcloud driver integration (optional, heavy; formerly nutanix_runtest.sh):
#       libcloud   — NUTANIX_INTEGRATION=1 runs the Nutanix libcloud driver tests
#
# Credentials are NEVER hardcoded here: every password and secret is read
# dynamically from the existing generated/env files written by ./setup.sh
# (dex/generated/dex.env, openfga_postgres/generated/fga.env,
#  vault/generated/vault.env, lldap/.env, .env).
#
# Prerequisites: ./setup.sh has completed successfully (the stack is up).
#
# Usage:
#   ./system_validate.sh                  # run every section
#   VERBOSE=1 ./system_validate.sh        # surface captured command output
#   ONLY=lldap ./system_validate.sh       # run a single section
#   PROVISION_VMS=1 ./system_validate.sh  # LIVE: actually create EC2 + Nutanix VMs
#   FULL=1 ./system_validate.sh           # openapi section runs full CRUD lifecycle
#   SKIP_EMULATOR=1 SKIP_PRISM=1 ./system_validate.sh   # skip specific suites
#   NUTANIX_INTEGRATION=1 ./system_validate.sh          # also run libcloud driver tests
#
# Section skip flags (any SKIP_<SECTION>=1 skips that section; hyphens in a
# section name become underscores in its flag, e.g. `rest-api` -> SKIP_REST_API):
#   infra smoke lldap dex rest fga superadmin tenantcreds oidc
#   authz openapi provision prism emulator libcloud rest_api
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LLDAP_DIR="${REPO_ROOT}/lldap"
DEX_DIR="${REPO_ROOT}/dex"
VAULT_DIR="${REPO_ROOT}/vault"
REST_DIR="${REPO_ROOT}/libcloud.rest"
LLDAP_COMPOSE="${LLDAP_DIR}/docker-compose.yml"

VERBOSE="${VERBOSE:-0}"
ONLY="${ONLY:-}"
# PROVISION_VMS=1 switches the cloud-admin provision assertions from dry-run
# (PROVISION=0) to live provisioning (PROVISION=1), which creates real EC2 +
# Nutanix VMs. The deny-on-mutation path is enforced server-side by OpenFGA and
# is exercised safely by the tenantcreds + fga sections instead.
PROVISION_VMS="${PROVISION_VMS:-0}"
# NUTANIX_INTEGRATION=1 additionally runs the heavy libcloud Nutanix driver
# integration tests (rebuilds the emulator). Off by default.
NUTANIX_INTEGRATION="${NUTANIX_INTEGRATION:-0}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# =============================================================================
# Dynamic environment / credential loading
# =============================================================================
# Read secrets from the files setup.sh wrote — never hardcode. Higher-priority
# files are loaded first and "set-if-unset" semantics keep the first value, so
# the precedence is: generated files > lldap/.env > repo .env > (any explicit
# shell export already set before this script ran, which always wins).
_load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    # Only set if not already set (earlier files / explicit exports win).
    [[ -z "${!key+x}" ]] && export "${key}=${val}"
  done < "$file"
}
_load_env_file "${DEX_DIR}/generated/dex.env"
_load_env_file "${REPO_ROOT}/openfga_postgres/generated/fga.env"
_load_env_file "${VAULT_DIR}/generated/vault.env"
_load_env_file "${LLDAP_DIR}/.env"
_load_env_file "${REPO_ROOT}/.env"
_load_env_file "${REPO_ROOT}/test_script/generated/dex.env"

# Resolve a per-user Dex/LLDAP password from the generated dex.env (the same
# mapping common.sh and openapi_rest_test.py use). Empty string if unknown.
password_for() {
  case "$1" in
    superadmin)   printf '%s' "${LIBCLOUD_SUPERADMIN_PASSWORD:-${LIBCLOUD_PASSWORD_SUPERADMIN:-}}" ;;
    aws-owner)    printf '%s' "${LIBCLOUD_PASSWORD_AWS_OWNER:-}" ;;
    aws-admin)    printf '%s' "${LIBCLOUD_PASSWORD_AWS_ADMIN:-}" ;;
    aws-viewer)   printf '%s' "${LIBCLOUD_PASSWORD_AWS_VIEWER:-}" ;;
    aws1-owner)   printf '%s' "${LIBCLOUD_PASSWORD_AWS1_OWNER:-}" ;;
    aws1-admin)   printf '%s' "${LIBCLOUD_PASSWORD_AWS1_ADMIN:-}" ;;
    aws1-viewer)  printf '%s' "${LIBCLOUD_PASSWORD_AWS1_VIEWER:-}" ;;
    aws2-owner)   printf '%s' "${LIBCLOUD_PASSWORD_AWS2_OWNER:-}" ;;
    aws2-admin)   printf '%s' "${LIBCLOUD_PASSWORD_AWS2_ADMIN:-}" ;;
    aws2-viewer)  printf '%s' "${LIBCLOUD_PASSWORD_AWS2_VIEWER:-}" ;;
    ntnx-owner)   printf '%s' "${LIBCLOUD_PASSWORD_NTNX_OWNER:-}" ;;
    ntnx-admin)   printf '%s' "${LIBCLOUD_PASSWORD_NTNX_ADMIN:-}" ;;
    ntnx-viewer)  printf '%s' "${LIBCLOUD_PASSWORD_NTNX_VIEWER:-}" ;;
    cloud-denied) printf '%s' "${LIBCLOUD_PASSWORD_CLOUD_DENIED:-}" ;;
    *)            printf '%s' "" ;;
  esac
}

# URLs / client config (from dex.env / .env, with sane localhost defaults).
DEX_URL="${DEX_URL:-http://localhost:5556}"
DEX_ISSUER_URL="${DEX_ISSUER_URL:-${DEX_URL}/dex}"
DEX_JWKS_URL="${DEX_JWKS_URL:-${DEX_ISSUER_URL}/keys}"
FGA_API_URL="${FGA_API_URL:-http://localhost:8080}"
LIBCLOUD_REST_URL="${LIBCLOUD_REST_URL:-http://localhost:8765}"
LIBCLOUD_OIDC_CLIENT_ID="${LIBCLOUD_OIDC_CLIENT_ID:-libcloud-rest}"

# Pin the idp_login.py token cache to the repo root so every sub-invocation
# (provision scripts, superadmin login, tenant creds) shares one cache.
export IDP_TOKEN_CACHE_DIR="${IDP_TOKEN_CACHE_DIR:-${REPO_ROOT}/generated/tokens}"

# =============================================================================
# Counters / reporting
# =============================================================================
PASS=0; FAIL=0
SECTION_PASSES=0; SECTION_FAILS=0
CURRENT_SECTION=""
CURRENT_ACTIVE=1

# section NAME — begin a named section (skipped if ONLY/SKIP_<NAME> excludes it).
section() {
  local name="$1"; shift
  CURRENT_SECTION="$name"
  SECTION_PASSES=0; SECTION_FAILS=0
  if [[ -n "${ONLY}" && "${ONLY}" != "${name}" ]]; then
    CURRENT_ACTIVE=0
    return
  fi
  local var="SKIP_${name^^}"
  var="${var//-/_}"   # section names with hyphens (e.g. "rest-api") -> SKIP_REST_API
  if [[ "${!var:-0}" == "1" ]]; then
    CURRENT_ACTIVE=0
    echo "  [skip] section ${name} (${var}=1)"
    return
  fi
  CURRENT_ACTIVE=1
  echo
  echo "############################################################"
  echo "# Section: ${name}"
  echo "############################################################"
}

ok() {
  local label="$1"
  PASS=$((PASS+1)); SECTION_PASSES=$((SECTION_PASSES+1))
  echo "  [PASS] ${label}"
}

no() {
  local label="$1"
  FAIL=$((FAIL+1)); SECTION_FAILS=$((SECTION_FAILS+1))
  echo "  [FAIL] ${label}"
}

skip() {
  local label="$1"
  echo "  [SKIP] ${label}"
}

show_tail() {
  local f="$1"; local n="${2:-10}"
  if [[ "${VERBOSE}" == "1" ]]; then
    tail -n "${n}" "${f}" | sed 's/^/        | /' >&2
  fi
}

# assert_ok LABEL CMD...            -> PASS if CMD exits 0
assert_ok() {
  local label="$1"; shift
  [[ "${CURRENT_ACTIVE}" == "1" ]] || return
  if "$@" >"${TMP}/last.out" 2>&1; then
    ok "${label}"
  else
    no "${label}"
    show_tail "${TMP}/last.out"
  fi
}

# assert_ok_match LABEL MARKER CMD... -> PASS if CMD exits 0 AND MARKER in output
assert_ok_match() {
  local label="$1" marker="$2"; shift 2
  [[ "${CURRENT_ACTIVE}" == "1" ]] || return
  if "$@" >"${TMP}/last.out" 2>&1 && grep -qF -- "${marker}" "${TMP}/last.out"; then
    ok "${label}"
  else
    no "${label}"
    show_tail "${TMP}/last.out"
  fi
}

end_section() {
  if [[ "${CURRENT_ACTIVE}" == "1" ]]; then
    echo "  -- section ${CURRENT_SECTION}: ${SECTION_PASSES} pass, ${SECTION_FAILS} fail"
  fi
  CURRENT_ACTIVE=1
}

# run_suite LABEL CMD... — run a component test script, stream its output, and
# fold its "N passed / M failed" counts into the global tally. Falls back to
# exit-code accounting for suites (openapi_rest_test.py) without that summary.
run_suite() {
  local label="$1"; shift
  [[ "${CURRENT_ACTIVE}" == "1" ]] || return
  echo
  echo "  ---- ${label} ----"
  local out rc p f
  out=$("$@" 2>&1); rc=$?
  echo "$out" | sed 's/^/    | /'
  p=$(printf '%s\n' "$out" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | tail -n1)
  f=$(printf '%s\n' "$out" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' | tail -n1)
  [[ -z "$p" ]] && p=$(printf '%s\n' "$out" | grep -oE 'PASS=[0-9]+' | grep -oE '[0-9]+' | tail -n1)
  [[ -z "$f" ]] && f=$(printf '%s\n' "$out" | grep -oE 'FAIL=[0-9]+' | grep -oE '[0-9]+' | tail -n1)
  if [[ -z "$p" && -z "$f" ]]; then
    # No parseable summary — account by exit code.
    if [[ "$rc" -eq 0 ]]; then p=1; else f=1; fi
  fi
  p="${p:-0}"; f="${f:-0}"
  PASS=$((PASS + p)); FAIL=$((FAIL + f))
  SECTION_PASSES=$((SECTION_PASSES + p)); SECTION_FAILS=$((SECTION_FAILS + f))
  if [[ "$rc" -ne 0 && "$f" -eq 0 ]]; then
    # Suite errored but reported no per-check failures; count one.
    FAIL=$((FAIL + 1)); SECTION_FAILS=$((SECTION_FAILS + 1))
    no "${label} exited non-zero (rc=${rc})"
  fi
}

# =============================================================================
# Preflight
# =============================================================================
preflight() {
  local missing=0
  for f in \
    "${DEX_DIR}/generated/dex.env" \
    "${REPO_ROOT}/openfga_postgres/generated/fga.env" \
    "${VAULT_DIR}/generated/vault.env" \
    "${DEX_DIR}/config.yaml"; do
    [[ -f "$f" ]] || { echo "  [MISS] required artifact not found: $f" >&2; missing=1; }
  done
  if [[ ${missing} -ne 0 ]]; then
    echo "FATAL: preflight failed — run ./setup.sh first." >&2
    exit 2
  fi
  # Ensure the lldap-tools management image exists (used by LLDAP bind checks).
  docker compose -f "${LLDAP_COMPOSE}" build lldap-tools >"${TMP}/lldap_build.out" 2>&1 || true
}

# =============================================================================
# Helpers for inline checks
# =============================================================================
clear_tokens() { rm -f "${IDP_TOKEN_CACHE_DIR}/"*.json 2>/dev/null || true; }

lldap_verify() {
  docker compose -f "${LLDAP_COMPOSE}" --profile tools run --rm lldap-tools \
    python3 /scripts/verify-ldap.py "$@"
}

container_healthy() {
  local c="$1"
  local state hs
  state=$(docker inspect "$c" --format '{{.State.Status}}' 2>/dev/null || echo "")
  hs=$(docker inspect "$c" --format '{{.State.Health.Status}}' 2>/dev/null || echo "")
  [[ "$state" == "running" ]] && { [[ -z "$hs" || "$hs" == "healthy" ]]; }
}

net_has_all() {
  local members
  members=$(docker network inspect libcloud_net --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || echo "")
  for c in lldap dex openfga vault libcloud-rest-api; do
    [[ " ${members} " == *" ${c} "* ]] || return 1
  done
}

dex_no_static_users() {
  # No staticPasswords / enablePasswordDB directives (comments mentioning them are fine).
  ! grep -qE '^[[:space:]]*(staticPasswords|enablePasswordDB):' "${DEX_DIR}/config.yaml"
}

dex_ldap_connector() {
  grep -qE 'type: ldap' "${DEX_DIR}/config.yaml" \
    && grep -q 'host: lldap:3890' "${DEX_DIR}/config.yaml" \
    && grep -q 'idAttr: uid' "${DEX_DIR}/config.yaml" \
    && grep -q 'emailAttr: mail' "${DEX_DIR}/config.yaml"
}

dex_bindpw_matches_lldap() {
  local bp
  bp=$(grep -E '^[[:space:]]*bindPW:' "${DEX_DIR}/config.yaml" | sed -E 's/.*bindPW:[[:space:]]*//' | head -n1)
  [[ -n "$bp" && "$bp" == "${LLDAP_LDAP_USER_PASS:-}" ]]
}

dex_discovery() {
  curl -fsS --max-time 10 \
    "${DEX_URL}/dex/.well-known/openid-configuration" >/dev/null
}

dex_auth_redirects_to_lldap() {
  local auth="${DEX_URL}/dex/auth?client_id=libcloud-rest&redirect_uri=http%3A%2F%2F127.0.0.1%3A8766%2Foauth%2Fcallback&response_type=code&scope=openid+email+profile&state=sv"
  curl -s -i --max-time 10 "$auth" | grep -i '^Location:' | grep -q '/dex/auth/lldap'
}

rest_no_local_users() {
  docker exec libcloud-rest-api test ! -e /app/data/users.json 2>/dev/null
}

rest_auth_mode_oidc() {
  [[ "$(docker exec libcloud-rest-api sh -c 'echo "$AUTH_MODE"' 2>/dev/null | tr -d '\r\n')" == "oidc" ]]
}

rest_local_login_disabled() {
  local code body
  code=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' \
    -X POST "${LIBCLOUD_REST_URL}/v1/auth/login" \
    -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"changeme"}' 2>/dev/null)
  [[ "$code" == "404" ]] \
    && curl -s --max-time 10 -X POST "${LIBCLOUD_REST_URL}/v1/auth/login" \
         -H 'Content-Type: application/json' \
         -d '{"username":"admin","password":"changeme"}' | grep -q 'auth_local_disabled'
}

lldap_users_present() {
  # superadmin + per-cloud owners/admins/viewers + denied demo user
  lldap_verify 2>/dev/null \
    | grep -E 'uid=(superadmin|aws-owner|aws-admin|aws-viewer|ntnx-owner|ntnx-admin|ntnx-viewer|cloud-denied)' \
    | sort -u | wc -l | grep -q '^8$'
}

lldap_bind() { lldap_verify "$1" "$2" >/dev/null 2>&1; }

jwt_has_email() {
  local user="$1" pass="$2" email="$3" tok payload
  clear_tokens
  tok=$(LIBCLOUD_USER="$user" LIBCLOUD_PASSWORD="$pass" \
        python3 "${REPO_ROOT}/test_script/scripts/idp_login.py" 2>/dev/null) || return 1
  [[ -n "$tok" ]] || return 1
  payload=$(python3 - "$tok" <<'PY'
import base64, json, sys
tok = sys.argv[1].strip()
seg = tok.split('.')[1]
seg += '=' * (-len(seg) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(seg))))
PY
)
  echo "$payload" | grep -q "\"email\": \"${email}\""
}

# superadmin gating: a successful Dex login as the LLDAP superadmin user must
# produce a valid JWT, and the privileged OpenFGA bootstrap must refuse to run
# without it.
superadmin_login_succeeds() {
  # superadmin_auth.sh performs the full Dex login + JWT verification and caches
  # the JWT. It runs signature verification inside the identity-service container
  # (which ships the `cryptography` package), so it has no host Python dependency
  # beyond the stdlib used by idp_login.py — unlike a host-side
  # verify_superadmin_jwt.py call, which fails on hosts without `cryptography`.
  bash "${REPO_ROOT}/test_script/scripts/superadmin_auth.sh" >/dev/null 2>&1
}

openfga_bootstrap_refuses_without_superadmin() {
  # Empty SUPERADMIN_JWT -> bootstrap exits 3 with the gating message.
  SUPERADMIN_JWT="" python3 "${REPO_ROOT}/openfga_postgres/openfga_bootstrap.py" >"${TMP}/ofg.out" 2>&1
  local rc=$?
  [[ ${rc} -eq 3 ]] && grep -q "SUPERADMIN_JWT is not set" "${TMP}/ofg.out"
}

# Per-tenant credential writes are owner-only. Non-owners must be denied by
# set_tenant_credentials.py (OpenFGA can_manage_credentials). These deny-path
# checks do NOT touch Vault (the script exits before the Vault write); they
# supply placeholder backend creds (aws vs nutanix) only to satisfy the
# script's input validation ahead of the OpenFGA gate.
creds_refuses_non_owner() {
  local tenant="$1" user="$2" pass="$3" cloud="${4:-$1}"
  local -a cred_args=()
  case "$cloud" in
    nutanix) cred_args=(LIBCLOUD_NTNX_USER=x LIBCLOUD_NTNX_PASSWORD=y) ;;
    *)       cred_args=(LIBCLOUD_AWS_KEY=x LIBCLOUD_AWS_SECRET=y) ;;
  esac
  env TENANT="${tenant}" LIBCLOUD_USER="${user}" LIBCLOUD_PASSWORD="${pass}" \
      "${cred_args[@]}" \
      python3 "${REPO_ROOT}/test_script/scripts/set_tenant_credentials.py" >"${TMP}/creds.out" 2>&1
  local rc=$?
  [[ ${rc} -eq 3 ]] && grep -q "not allowed to manage credentials" "${TMP}/creds.out"
}

run_aws()     { clear_tokens; LIBCLOUD_USER="$1" PROVISION="${PROVISION_VMS}" "${REPO_ROOT}/test_script/scripts/provision_aws.sh"; }
run_nutanix() { clear_tokens; LIBCLOUD_USER="$1" PROVISION="${PROVISION_VMS}" "${REPO_ROOT}/test_script/scripts/provision_nutanix.sh"; }

# =============================================================================
preflight
# Start from a clean token cache so no stale refresh token from a prior run
# (Dex stores refresh tokens in memory, so they are invalidated on every restart)
# short-circuits a login into a failed refresh attempt.
clear_tokens

# -----------------------------------------------------------------------------
section "infra"
assert_ok "libcloud_net exists and contains all 5 services" net_has_all
for c in lldap dex openfga vault libcloud-rest-api; do
  assert_ok "container ${c} running+healthy" container_healthy "$c"
done
end_section

# -----------------------------------------------------------------------------
section "smoke"
run_suite "Infrastructure smoke test (infra-smoke-test.sh)" \
  "${REPO_ROOT}/test_script/scripts/infra-smoke-test.sh" localhost
end_section

# -----------------------------------------------------------------------------
section "lldap"
assert_ok "LLDAP has superadmin + per-cloud owners/admins/viewers + denied" lldap_users_present
assert_ok "LDAP bind as superadmin"  lldap_bind superadmin  "$(password_for superadmin)"
assert_ok "LDAP bind as aws-admin"   lldap_bind aws-admin   "$(password_for aws-admin)"
assert_ok "LDAP bind as aws-viewer"  lldap_bind aws-viewer  "$(password_for aws-viewer)"
assert_ok "LDAP bind as ntnx-admin"  lldap_bind ntnx-admin  "$(password_for ntnx-admin)"
assert_ok "LDAP bind as ntnx-viewer" lldap_bind ntnx-viewer "$(password_for ntnx-viewer)"
assert_ok "LDAP bind as cloud-denied" lldap_bind cloud-denied "$(password_for cloud-denied)"
end_section

# -----------------------------------------------------------------------------
section "dex"
assert_ok "Dex config has no staticPasswords/enablePasswordDB" dex_no_static_users
assert_ok "Dex config has LDAP connector -> lldap (idAttr=uid, emailAttr=mail)" dex_ldap_connector
assert_ok "Dex bindPW matches ../lldap/.env LLDAP_LDAP_USER_PASS" dex_bindpw_matches_lldap
assert_ok "Dex OIDC discovery endpoint reachable" dex_discovery
assert_ok "/dex/auth redirects to /dex/auth/lldap (LDAP connector)" dex_auth_redirects_to_lldap
end_section

# -----------------------------------------------------------------------------
section "rest"
assert_ok "libcloud REST API has no local/static users.json" rest_no_local_users
assert_ok "libcloud REST API AUTH_MODE=oidc" rest_auth_mode_oidc
assert_ok "libcloud REST API local password login disabled (admin/changeme -> 404)" rest_local_login_disabled
end_section

# -----------------------------------------------------------------------------
section "fga"
run_suite "OpenFGA + Postgres test (fga-test.sh)" \
  "${REPO_ROOT}/openfga_postgres/scripts/fga-test.sh" \
  "${FGA_API_URL}" openfga-postgres openfga
end_section

# -----------------------------------------------------------------------------
section "rest-api"
run_suite "libcloud REST API RBAC test (rest-api-test.sh)" \
  env SKIP_LOGIN_TEST=1 BEARER_TOKEN="${BEARER_TOKEN:-}" \
  "${REPO_ROOT}/libcloud.rest/scripts/rest-api-test.sh" \
  "${LIBCLOUD_REST_URL}" libcloud-rest-api
end_section

# -----------------------------------------------------------------------------
section "identity"
run_suite "identity-service smoke test (smoke_test.sh)" \
  env BASE_URL="http://localhost:8766" CONTAINER_NAME="identity-service" \
  "${REPO_ROOT}/identity_service/smoke_test.sh"
end_section

# -----------------------------------------------------------------------------
section "superadmin"
assert_ok "superadmin Dex login produces a valid JWT" superadmin_login_succeeds
assert_ok "openfga_bootstrap refuses to run without SUPERADMIN_JWT (gate)" \
  openfga_bootstrap_refuses_without_superadmin
end_section

# -----------------------------------------------------------------------------
section "tenantcreds"
assert_ok "set_tenant_credentials denies aws-admin (non-owner on tenant:aws)" \
  creds_refuses_non_owner aws aws-admin "$(password_for aws-admin)"
assert_ok "set_tenant_credentials denies aws-viewer (non-owner on tenant:aws)" \
  creds_refuses_non_owner aws aws-viewer "$(password_for aws-viewer)"
assert_ok "set_tenant_credentials denies ntnx-admin (non-owner on tenant:nutanix)" \
  creds_refuses_non_owner nutanix ntnx-admin "$(password_for ntnx-admin)"
assert_ok "set_tenant_credentials denies cloud-denied (denied user on tenant:aws)" \
  creds_refuses_non_owner aws cloud-denied "$(password_for cloud-denied)"
end_section

# -----------------------------------------------------------------------------
section "oidc"
assert_ok "idp_login.py: superadmin JWT has email=superadmin@libcloud.local" \
  jwt_has_email superadmin "$(password_for superadmin)" superadmin@libcloud.local
end_section

# -----------------------------------------------------------------------------
section "authz"
if [[ "${CURRENT_ACTIVE}" == "1" ]]; then
  AUTHZ_PY=""
  # Prefer the project venv; otherwise fall back to any python3 that can import
  # the audit's real requirements — fastapi (the app), httpx (fastapi.testclient),
  # and libcloud (the vendored driver). Importing only fastapi here would pick a
  # python that then dies mid-audit on `from fastapi.testclient import TestClient`
  # or `import libcloud`. On hosts with neither, skip gracefully rather than fail.
  for cand in "${REST_DIR}/.venv/bin/python" "python3"; do
    if command -v "${cand}" >/dev/null 2>&1 && "${cand}" -c 'import fastapi, httpx, libcloud' >/dev/null 2>&1; then
      AUTHZ_PY="${cand}"
      break
    fi
  done
  if [[ -n "${AUTHZ_PY}" ]]; then
    run_suite "REST API auth-gate audit (test_all_rest_api_authenticated.py)" \
      "${AUTHZ_PY}" "${REPO_ROOT}/test_script/test_all_rest_api_authenticated.py"
  else
    skip "auth-gate audit: no Python with fastapi available (create libcloud.rest/.venv, or run inside the libcloud-rest-api container)"
  fi
fi
end_section

# -----------------------------------------------------------------------------
section "openapi"
run_suite "OpenAPI-driven REST API test (openapi_rest_test.py)" \
  "${REPO_ROOT}/test_script/scripts/openapi_rest_test.sh"
end_section

# -----------------------------------------------------------------------------
section "provision"
# The provision scripts (provision_aws.sh / provision_nutanix.sh) exercise the
# authenticated Dex -> OpenFGA -> libcloud REST -> cloud path. In dry-run mode
# (PROVISION=0, the default) they only issue READ calls — catalog discovery and
# listing — which every seeded user may perform, so the observable signal is
# that the admin read/connect path completes and the Nutanix reader short-
# circuits before any mutation. The *deny* on mutating calls (can_provision /
# can_connect) is enforced server-side by OpenFGA and only manifests once the
# script attempts a mutating call (PROVISION_VMS=1, live). That deny is covered
# safely here by the tenantcreds section (OpenFGA can_manage_credentials) and by
# the fga section (OpenFGA Check of cloud-denied), so no live provisioning is
# needed for the deny assertion.
if [[ "${PROVISION_VMS}" == "1" ]]; then
  AWS_ADMIN_MARKER="AWS provisioning flow completed."
  NTNX_ADMIN_MARKER="Nutanix provisioning flow completed."
  ADMIN_LABEL="allow + live provision"
  [[ "${CURRENT_ACTIVE}" == "1" ]] && echo "  NOTE: PROVISION_VMS=1 — creating real EC2 + Nutanix VMs as cloud-admin."
else
  AWS_ADMIN_MARKER="Dry-run complete (set PROVISION=1 to create an EC2 instance)"
  NTNX_ADMIN_MARKER="Dry-run complete (set PROVISION=1 to create a Nutanix VM)"
  ADMIN_LABEL="allow + dry-run"
fi

assert_ok_match "provision_aws.sh aws-admin (${ADMIN_LABEL})" \
  "${AWS_ADMIN_MARKER}" run_aws aws-admin
assert_ok_match "provision_nutanix.sh ntnx-admin (${ADMIN_LABEL})" \
  "${NTNX_ADMIN_MARKER}" run_nutanix ntnx-admin
# ntnx-viewer is read-only: the reader branch short-circuits before any mutating
# call regardless of PROVISION_VMS. (provision_aws.sh's equivalent reader branch
# is now enforced server-side rather than client-side, so there is no distinct
# AWS read-only marker to assert here.)
assert_ok_match "provision_nutanix.sh ntnx-viewer (read-only skip)" \
  "Reader user — skipping mutating Nutanix provisioning calls" run_nutanix ntnx-viewer
end_section

# -----------------------------------------------------------------------------
section "prism"
run_suite "Prism mock server test (prism-test.sh)" \
  "${REPO_ROOT}/stoplight_mock/scripts/prism-test.sh" \
  http://localhost:4010 stoplight_mock-prism-1
end_section

# -----------------------------------------------------------------------------
section "emulator"
run_suite "Nutanix emulator test (test-emulator.sh)" \
  "${REPO_ROOT}/stoplight_mock/scripts/test-emulator.sh" \
  https://localhost:9440
end_section

# -----------------------------------------------------------------------------
section "libcloud"
if [[ "${CURRENT_ACTIVE}" == "1" ]]; then
  if [[ "${NUTANIX_INTEGRATION}" == "1" ]]; then
    echo "  NOTE: running libcloud Nutanix driver integration tests (heavy)."
    run_suite "libcloud Nutanix driver integration tests" \
      bash -c "cd '${REPO_ROOT}/libcloud/contrib/docker/nutanix' && NUTANIX_INTEGRATION_TESTS=1 ./run_tests.sh integration"
  else
    echo "  [skip] libcloud driver integration tests (set NUTANIX_INTEGRATION=1 to run)"
  fi
fi
end_section

# =============================================================================
echo
echo "############################################################"
echo "# Validation summary"
echo "############################################################"
echo "  PASS: ${PASS}"
echo "  FAIL: ${FAIL}"
clear_tokens
if [[ ${FAIL} -eq 0 ]]; then
  echo "  RESULT: ALL VALIDATIONS PASSED"
  exit 0
else
  echo "  RESULT: ${FAIL} VALIDATION(S) FAILED"
  exit 1
fi
