#!/usr/bin/env bash
# system_validate.sh
# ==================
# End-to-end validation harness for the libcloud security stack:
#
#   Client → Dex (OIDC) → LLDAP (user directory, via LDAP connector)
#         → libcloud REST (FastAPI, OIDC + OpenFGA)
#         → OpenFGA (authorization)
#         → Vault (backend cloud credentials) → AWS / Nutanix
#
# It captures every validation performed during the LLDAP migration:
#   A. Infrastructure: shared network + service health
#   B. LLDAP directory: superadmin + per-cloud owners/admins/viewers present + binds
#   C. Dex: no static users, LDAP connector wired to LLDAP, discovery + login path
#   D. superadmin gating: Dex login as superadmin yields a valid JWT; OpenFGA
#      bootstrap refuses without it
#   E. Tenant credentials: set_tenant_credentials denies non-owners (only
#      tenant owners / superadmin can update per-tenant AWS/Nutanix creds)
#   F. OIDC login: idp_login.py yields a JWT with the expected email claim
#   G. Provisioning: provision_aws.sh + provision_nutanix.sh for
#      aws-admin / ntnx-admin (allow), aws-viewer / ntnx-viewer (read-only),
#      cloud-denied (deny)
#
# Prerequisites: ./setup.sh has completed successfully.
#
# Usage:
#   ./system_validate.sh
#   VERBOSE=1 ./system_validate.sh        # surface captured command output
#   ONLY=lldap ./system_validate.sh       # run a single section (infra|lldap|dex|oidc|provision)
#   PROVISION_VMS=1 ./system_validate.sh  # LIVE: actually create EC2 + Nutanix VMs
#                                         # (requires reachable backends + valid Vault
#                                          auth_bindings; costs real cloud resources)
set -o pipefail

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
# (PROVISION=0) to live provisioning (PROVISION=1). The reader/denied paths are
# unaffected because they exit before the dry-run/provision branch.
PROVISION_VMS="${PROVISION_VMS:-0}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# --- load environment exactly like the provisioning scripts ---
# common.sh exports DEX_URL, FGA_API_URL, LIBCLOUD_REST_URL, OIDC client
# secret, and the per-role LIBCLOUD_PASSWORD_* values from generated/dex.env.
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/test_script/scripts/common.sh" >/dev/null 2>&1 || {
  echo "FATAL: cannot source scripts/common.sh — run ./setup.sh first." >&2
  exit 2
}
# LLDAP bind credentials (for the bindPW-match check). common.sh does not load these.
if [[ -f "${LLDAP_DIR}/.env" ]]; then
  set -a; source "${LLDAP_DIR}/.env"; set +a
fi
set +e +u   # validation harness: never abort on a single failed assertion

# --- counters / reporting ---
PASS=0; FAIL=0
SECTION_PASSES=0; SECTION_FAILS=0
CURRENT_SECTION=""

section() {
  local name="$1"; shift
  CURRENT_SECTION="$name"
  SECTION_PASSES=0; SECTION_FAILS=0
  if [[ -n "${ONLY}" && "${ONLY}" != "${name}" ]]; then return; fi
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

show_tail() {
  local f="$1"; local n="${2:-10}"
  if [[ "${VERBOSE}" == "1" ]]; then
    tail -n "${n}" "${f}" | sed 's/^/        | /' >&2
  fi
}

# assert_ok LABEL CMD...            -> PASS if CMD exits 0
assert_ok() {
  local label="$1"; shift
  [[ -z "${ONLY}" || "${ONLY}" == "${CURRENT_SECTION}" ]] || return
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
  [[ -z "${ONLY}" || "${ONLY}" == "${CURRENT_SECTION}" ]] || return
  if "$@" >"${TMP}/last.out" 2>&1 && grep -qF -- "${marker}" "${TMP}/last.out"; then
    ok "${label}"
  else
    no "${label}"
    show_tail "${TMP}/last.out"
  fi
}

# assert_deny_match LABEL MARKER CMD... -> PASS if CMD exits non-zero AND MARKER in output
assert_deny_match() {
  local label="$1" marker="$2"; shift 2
  [[ -z "${ONLY}" || "${ONLY}" == "${CURRENT_SECTION}" ]] || return
  "$@" >"${TMP}/last.out" 2>&1
  local rc=$?
  if [[ ${rc} -ne 0 ]] && grep -qF -- "${marker}" "${TMP}/last.out"; then
    ok "${label} (denied as expected, rc=${rc})"
  else
    no "${label} (expected denial+marker; rc=${rc})"
    show_tail "${TMP}/last.out"
  fi
}

# assert_fail LABEL CMD... -> PASS if CMD exits non-zero (marker-less variant)
assert_fail() {
  local label="$1"; shift
  [[ -z "${ONLY}" || "${ONLY}" == "${CURRENT_SECTION}" ]] || return
  if "$@" >"${TMP}/last.out" 2>&1; then
    no "${label} (expected non-zero exit)"
    show_tail "${TMP}/last.out"
  else
    ok "${label} (non-zero as expected)"
  fi
}

end_section() {
  if [[ -n "${ONLY}" && "${ONLY}" != "${CURRENT_SECTION}" ]]; then return; fi
  echo "  -- section ${CURRENT_SECTION}: ${SECTION_PASSES} pass, ${SECTION_FAILS} fail"
}

# --- preflight ---------------------------------------------------------------
preflight() {
  local missing=0
  for f in "${DEX_DIR}/generated/dex.env" "${REPO_ROOT}/openfga_postgres/generated/fga.env" "${VAULT_DIR}/generated/vault.env" "${DEX_DIR}/config.yaml"; do
    [[ -f "$f" ]] || { echo "  [MISS] required artifact not found: $f" >&2; missing=1; }
  done
  if [[ ${missing} -ne 0 ]]; then
    echo "FATAL: preflight failed — run ./setup.sh first." >&2
    exit 2
  fi
  # Ensure the lldap-tools management image exists (used by LLDAP bind checks).
  docker compose -f "${LLDAP_COMPOSE}" build lldap-tools >"${TMP}/lldap_build.out" 2>&1 || true
}

# --- helpers for checks ------------------------------------------------------
clear_tokens() { rm -f "${REPO_ROOT}/generated/tokens/"*.json 2>/dev/null || true; }

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
    "http://localhost:5556/dex/.well-known/openid-configuration" >/dev/null
}

dex_auth_redirects_to_lldap() {
  local auth="http://localhost:5556/dex/auth?client_id=libcloud-rest&redirect_uri=http%3A%2F%2F127.0.0.1%3A8766%2Foauth%2Fcallback&response_type=code&scope=openid+email+profile&state=sv"
  curl -s -i --max-time 10 "$auth" | grep -i '^Location:' | grep -q '/dex/auth/lldap'
}

# --- libcloud REST API: no local/static user directory -----------------------
rest_no_local_users() {
  docker exec libcloud-rest-api test ! -e /app/data/users.json 2>/dev/null
}

rest_auth_mode_oidc() {
  [[ "$(docker exec libcloud-rest-api sh -c 'echo "$AUTH_MODE"' 2>/dev/null | tr -d '\r\n')" == "oidc" ]]
}

rest_local_login_disabled() {
  local code body
  body=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' \
    -X POST "http://localhost:8765/v1/auth/login" \
    -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"changeme"}' 2>/dev/null)
  [[ "$body" == "404" ]] \
    && curl -s --max-time 10 -X POST "http://localhost:8765/v1/auth/login" \
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
# produce a valid JWT, and the privileged bootstraps must refuse to run without
# it.
superadmin_login_succeeds() {
  local pw="${LIBCLOUD_SUPERADMIN_PASSWORD:-${LIBCLOUD_PASSWORD_SUPERADMIN:-}}"
  [[ -n "$pw" ]] && pw="$(grep -E '^LIBCLOUD_SUPERADMIN_PASSWORD=' "${REPO_ROOT}/test_script/generated/dex.env" 2>/dev/null | cut -d= -f2- || true)"
  [[ -n "$pw" ]] || return 1
  LIBCLOUD_USER=superadmin LIBCLOUD_PASSWORD="$pw" \
    python3 "${REPO_ROOT}/test_script/scripts/idp_login.py" 2>/dev/null >"${TMP}/sa.jwt" || return 1
  [[ -s "${TMP}/sa.jwt" ]] || return 1
  SUPERADMIN_JWT="$(cat "${TMP}/sa.jwt")" python3 "${REPO_ROOT}/test_script/scripts/verify_superadmin_jwt.py" >/dev/null 2>&1
}

openfga_bootstrap_refuses_without_superadmin() {
  # Empty SUPERADMIN_JWT -> bootstrap exits 3 with the gating message.
  SUPERADMIN_JWT="" python3 "${REPO_ROOT}/test_script/openfga_bootstrap.py" >"${TMP}/ofg.out" 2>&1
  local rc=$?
  [[ ${rc} -eq 3 ]] && grep -q "SUPERADMIN_JWT is not set" "${TMP}/ofg.out"
}

# Per-tenant credential writes are owner-only. Non-owners must be denied by
# set_tenant_credentials.py (OpenFGA can_manage_credentials). These deny-path
# checks do NOT touch Vault (the script exits before the Vault write).
creds_refuses_non_owner() {
  local tenant="$1" user="$2" pass="$3"
  TENANT="${tenant}" LIBCLOUD_USER="${user}" LIBCLOUD_PASSWORD="${pass}" \
    LIBCLOUD_AWS_KEY=x LIBCLOUD_AWS_SECRET=y \
    python3 "${REPO_ROOT}/test_script/scripts/set_tenant_credentials.py" >"${TMP}/creds.out" 2>&1
  local rc=$?
  [[ ${rc} -eq 3 ]] && grep -q "not allowed to manage credentials" "${TMP}/creds.out"
}

run_aws()     { clear_tokens; LIBCLOUD_USER="$1" PROVISION="${PROVISION_VMS}" "${REPO_ROOT}/test_script/scripts/provision_aws.sh"; }
run_nutanix() { clear_tokens; LIBCLOUD_USER="$1" PROVISION="${PROVISION_VMS}" "${REPO_ROOT}/test_script/scripts/provision_nutanix.sh"; }

# =============================================================================
preflight

section "infra"
assert_ok "libcloud_net exists and contains all 5 services" net_has_all
for c in lldap dex openfga vault libcloud-rest-api; do
  assert_ok "container ${c} running+healthy" container_healthy "$c"
done
end_section

section "lldap"
assert_ok "LLDAP has superadmin + per-cloud owners/admins/viewers + denied" lldap_users_present
assert_ok "LDAP bind as superadmin"  lldap_bind superadmin  "${LIBCLOUD_SUPERADMIN_PASSWORD:-SuperAdmin123!}"
assert_ok "LDAP bind as aws-admin"   lldap_bind aws-admin   "${LIBCLOUD_PASSWORD_AWS_ADMIN:-AwsAdmin123!}"
assert_ok "LDAP bind as aws-viewer"  lldap_bind aws-viewer  "${LIBCLOUD_PASSWORD_AWS_VIEWER:-AwsView123!}"
assert_ok "LDAP bind as ntnx-admin"  lldap_bind ntnx-admin  "${LIBCLOUD_PASSWORD_NTNX_ADMIN:-NtnxAdmin123!}"
assert_ok "LDAP bind as ntnx-viewer" lldap_bind ntnx-viewer "${LIBCLOUD_PASSWORD_NTNX_VIEWER:-NtnxView123!}"
assert_ok "LDAP bind as cloud-denied" lldap_bind cloud-denied "${LIBCLOUD_PASSWORD_CLOUD_DENIED:-CloudDenied123!}"
end_section

section "dex"
assert_ok "Dex config has no staticPasswords/enablePasswordDB" dex_no_static_users
assert_ok "Dex config has LDAP connector -> lldap (idAttr=uid, emailAttr=mail)" dex_ldap_connector
assert_ok "Dex bindPW matches ../lldap/.env LLDAP_LDAP_USER_PASS" dex_bindpw_matches_lldap
assert_ok "Dex OIDC discovery endpoint reachable" dex_discovery
assert_ok "/dex/auth redirects to /dex/auth/lldap (LDAP connector)" dex_auth_redirects_to_lldap
end_section

section "rest"
assert_ok "libcloud REST API has no local/static users.json" rest_no_local_users
assert_ok "libcloud REST API AUTH_MODE=oidc" rest_auth_mode_oidc
assert_ok "libcloud REST API local password login disabled (admin/changeme -> 404)" rest_local_login_disabled
end_section

section "superadmin"
assert_ok "superadmin Dex login produces a valid JWT" superadmin_login_succeeds
assert_ok "openfga_bootstrap refuses to run without SUPERADMIN_JWT (gate)" \
  openfga_bootstrap_refuses_without_superadmin
end_section

section "tenant-creds"
assert_ok "set_tenant_credentials denies aws-admin (non-owner on tenant:aws)" \
  creds_refuses_non_owner aws aws-admin "${LIBCLOUD_PASSWORD_AWS_ADMIN:-AwsAdmin123!}"
assert_ok "set_tenant_credentials denies aws-viewer (non-owner on tenant:aws)" \
  creds_refuses_non_owner aws aws-viewer "${LIBCLOUD_PASSWORD_AWS_VIEWER:-AwsView123!}"
assert_ok "set_tenant_credentials denies ntnx-admin (non-owner on tenant:nutanix)" \
  creds_refuses_non_owner nutanix ntnx-admin "${LIBCLOUD_PASSWORD_NTNX_ADMIN:-NtnxAdmin123!}"
end_section

section "oidc"
assert_ok "idp_login.py: superadmin JWT has email=superadmin@libcloud.local" \
  jwt_has_email superadmin "${LIBCLOUD_SUPERADMIN_PASSWORD:-SuperAdmin123!}" superadmin@libcloud.local
end_section

section "provision"
if [[ "${PROVISION_VMS}" == "1" ]]; then
  AWS_ADMIN_MARKER="AWS provisioning flow completed."
  NTNX_ADMIN_MARKER="Nutanix provisioning flow completed."
  ADMIN_LABEL="allow + live provision"
  echo "  NOTE: PROVISION_VMS=1 — creating real EC2 + Nutanix VMs as cloud-admin."
else
  AWS_ADMIN_MARKER="Dry-run complete (set PROVISION=1 to create an EC2 instance)"
  NTNX_ADMIN_MARKER="Dry-run complete (set PROVISION=1 to create a Nutanix VM)"
  ADMIN_LABEL="allow + dry-run"
fi

assert_ok_match "provision_aws.sh aws-admin (${ADMIN_LABEL})" \
  "${AWS_ADMIN_MARKER}" run_aws aws-admin
assert_ok_match "provision_aws.sh aws-viewer (read-only skip)" \
  "Reader user — skipping mutating AWS provisioning calls" run_aws aws-viewer
assert_deny_match "provision_aws.sh cloud-denied (OpenFGA denies)" \
  "allowed=False" run_aws cloud-denied

assert_ok_match "provision_nutanix.sh ntnx-admin (${ADMIN_LABEL})" \
  "${NTNX_ADMIN_MARKER}" run_nutanix ntnx-admin
assert_ok_match "provision_nutanix.sh ntnx-viewer (read-only skip)" \
  "Reader user — skipping mutating Nutanix provisioning calls" run_nutanix ntnx-viewer
assert_deny_match "provision_nutanix.sh cloud-denied (OpenFGA denies)" \
  "allowed=False" run_nutanix cloud-denied
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
