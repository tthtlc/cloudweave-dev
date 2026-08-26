#!/usr/bin/env bash
# recover_vault.sh
# ===============
# Vault was re-initialized and the new root token / unseal key were not saved.
# The old credentials in vault/generated/vault.env are permanently invalid.
# This script wipes Vault data, re-initializes it fresh, and re-seeds
# credentials so the 502 rest_error resolves.
#
# Prerequisites (all must be running — the usual state after ./setup.sh):
#   - LLDAP   (docker compose -f lldap/docker-compose.yml up -d)
#   - Dex     (docker compose -f dex/docker-compose.yml up -d)
#   - OpenFGA (docker compose -f openfga_postgres/docker-compose.yml up -d)
#
# Run from the repository root directory.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

VAULT_DIR="${REPO_ROOT}/vault"
VAULT_ENV="${VAULT_DIR}/generated/vault.env"
REST_DIR="${REPO_ROOT}/libcloud.rest"
REST_ENV="${REST_DIR}/.env"
SCRIPTS_DIR="${REPO_ROOT}/test_script/scripts"
REST_CONTAINER="libcloud-rest-api"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[1;34m'
NC='\033[0m'

bail()  { printf "${RED}FATAL: %s${NC}\n" "$*" >&2; exit 1; }
info()  { printf "${CYAN}→${NC} %s\n" "$*"; }
ok()    { printf "   ${GREEN}✓${NC} %s\n" "$*"; }
warn()  { printf "   ${RED}⚠${NC} %s\n" "$*"; }

# ── 0. safety check ─────────────────────────────────────────────────────────
info "This will DESTROY the Vault data volume and re-initialize."
info "All existing Vault secrets will be LOST (they're already unreachable)."
echo ""
read -rp "Continue? [y/N] " CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || bail "Aborted by user."

# ── 1. stop & wipe vault ───────────────────────────────────────────────────
info "Stopping Vault and removing data volume ..."
docker compose -f "${VAULT_DIR}/docker-compose.yml" down -v vault 2>/dev/null || true
ok "Vault stopped and data volume removed"

# ── 2. start fresh vault ───────────────────────────────────────────────────
info "Starting fresh Vault ..."
docker compose -f "${VAULT_DIR}/docker-compose.yml" up -d vault
ok "Vault starting"

# Wait for Vault to be reachable (uninitialized state)
info "Waiting for Vault to become reachable ..."
for i in $(seq 1 30); do
  if curl -fsS -o /dev/null http://localhost:8200/v1/sys/seal-status 2>/dev/null; then
    ok "Vault is reachable"
    break
  fi
  [[ $i -eq 30 ]] && bail "Vault did not become reachable — check: docker logs vault"
  sleep 2
done

# ── 3. get superadmin JWT ──────────────────────────────────────────────────
info "Authenticating as superadmin to gate Vault bootstrap ..."

# Load env files needed by superadmin_auth.sh (same logic it uses internally)
_load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" != *=* ]] && continue
    local key="${line%%=*}"
    local val="${line#*=}"
    [[ -z "${!key:-}" ]] && export "${key}=${val}"
  done < "$file"
}
_load_env_file "${REPO_ROOT}/.env"
_load_env_file "${REPO_ROOT}/dex/generated/dex.env"
_load_env_file "${REPO_ROOT}/test_script/generated/dex.env" 2>/dev/null || true

SA_PW="${LIBCLOUD_SUPERADMIN_PASSWORD:-${LIBCLOUD_PASSWORD_SUPERADMIN:-}}"
if [[ -z "${SA_PW}" ]]; then
  # Try reading from generated dex.env directly
  for f in "${REPO_ROOT}/dex/generated/dex.env" "${REPO_ROOT}/test_script/generated/dex.env"; do
    if [[ -f "$f" ]]; then
      SA_PW="$(grep -E '^LIBCLOUD_SUPERADMIN_PASSWORD=' "$f" | cut -d= -f2- || true)"
      [[ -n "${SA_PW}" ]] && break
    fi
  done
fi
[[ -n "${SA_PW}" ]] || bail "Cannot find superadmin password. Check .env or dex/generated/dex.env"

# Log in as superadmin to get the gating JWT
LIBCLOUD_USER=superadmin LIBCLOUD_PASSWORD="${SA_PW}" \
  python3 "${SCRIPTS_DIR}/idp_login.py" \
  >"${REPO_ROOT}/generated/tokens/superadmin.jwt" \
  2>"${REPO_ROOT}/generated/tokens/superadmin.login.err" || {
    echo "Dex login failed:" >&2
    cat "${REPO_ROOT}/generated/tokens/superadmin.login.err" >&2
    bail "superadmin login failed. Is Dex + LLDAP running?"
  }

export SUPERADMIN_JWT
SUPERADMIN_JWT="$(cat "${REPO_ROOT}/generated/tokens/superadmin.jwt")"
[[ -n "${SUPERADMIN_JWT}" ]] || bail "superadmin login produced an empty token"
ok "superadmin JWT acquired (length=${#SUPERADMIN_JWT})"

# ── 4. run vault bootstrap ──────────────────────────────────────────────────
info "Running Vault bootstrap (init, unseal, KV v2, read policy + token) ..."
docker compose -f "${VAULT_DIR}/docker-compose.yml" up --no-deps vault-bootstrap
ok "Vault bootstrap complete"

# Verify vault.env was written
[[ -f "${VAULT_ENV}" ]] || bail "Vault bootstrap did not write ${VAULT_ENV}"
ok "vault.env written"

# ── 5. sync VAULT_TOKEN to libcloud.rest/.env ──────────────────────────────
info "Syncing Vault token to libcloud.rest/.env ..."
VAULT_TOKEN="$(grep -E '^VAULT_TOKEN=' "${VAULT_ENV}" | cut -d= -f2-)"
[[ -n "${VAULT_TOKEN}" ]] || bail "No VAULT_TOKEN found in ${VAULT_ENV}"

if [[ -f "${REST_ENV}" ]]; then
  if grep -q '^VAULT_TOKEN=' "${REST_ENV}"; then
    sed -i "s/^VAULT_TOKEN=.*/VAULT_TOKEN=${VAULT_TOKEN}/" "${REST_ENV}"
  else
    echo "VAULT_TOKEN=${VAULT_TOKEN}" >> "${REST_ENV}"
  fi
  if grep -q '^VAULT_ADDR=' "${REST_ENV}"; then
    sed -i 's/^VAULT_ADDR=.*/VAULT_ADDR=http:\/\/vault:8200/' "${REST_ENV}"
  else
    echo "VAULT_ADDR=http://vault:8200" >> "${REST_ENV}"
  fi
  ok "Updated libcloud.rest/.env"
fi

# ── 6. recreate libcloud REST API (force-recreate to re-read .env) ──────────
info "Recreating libcloud REST API container to pick up new VAULT_TOKEN ..."
docker compose -f "${REST_DIR}/docker-compose.yml" up -d --force-recreate api
ok "Container recreated with fresh env"

# Wait for healthy
info "Waiting for REST API health check ..."
for i in $(seq 1 30); do
  if curl -fsS -o /dev/null "http://localhost:8765/health" 2>/dev/null; then
    ok "REST API is healthy"
    break
  fi
  [[ $i -eq 30 ]] && warn "REST API health check timed out — check: docker logs ${REST_CONTAINER}"
  sleep 2
done

# ── 7. re-seed Nutanix credentials ─────────────────────────────────────────
echo ""
info "Vault is ready. Now seed the Nutanix credentials."
info "The set_nutanix_admin_vault.sh script requires these env vars:"
echo ""
echo "  TENANT=nutanix"
echo "  LIBCLOUD_USER=ntnx-owner"
echo "  LIBCLOUD_PASSWORD='<ntnx-owner LLDAP password>'"
echo "  LIBCLOUD_NTNX_USER='<Prism Central username>'"
echo "  LIBCLOUD_NTNX_PASSWORD='<Prism Central password>'"
echo ""

# Try to auto-detect the ntnx-owner password from .env
NTNX_OWNER_PW="${LIBCLOUD_PASSWORD_NTNX_OWNER:-}"
if [[ -z "${NTNX_OWNER_PW}" ]]; then
  NTNX_OWNER_PW="$(grep -E '^LIBCLOUD_PASSWORD_NTNX_OWNER=' "${REPO_ROOT}/.env" 2>/dev/null | cut -d= -f2- || true)"
fi

if [[ -n "${NTNX_OWNER_PW}" ]]; then
  info "Found ntnx-owner password in .env — running credential seed automatically ..."
  TENANT=nutanix \
    LIBCLOUD_USER=ntnx-owner \
    LIBCLOUD_PASSWORD="${NTNX_OWNER_PW}" \
    LIBCLOUD_NTNX_USER="${LIBCLOUD_NTNX_USER:-admin}" \
    LIBCLOUD_NTNX_PASSWORD="${LIBCLOUD_NTNX_PASSWORD:-}" \
    python3 "${SCRIPTS_DIR}/set_tenant_credentials.py" || {
    warn "Credential seed returned an error. You may need to run it manually:"
    echo ""
    echo "  TENANT=nutanix \\"
    echo "    LIBCLOUD_USER=ntnx-owner \\"
    echo "    LIBCLOUD_PASSWORD='...' \\"
    echo "    LIBCLOUD_NTNX_USER='admin' \\"
    echo "    LIBCLOUD_NTNX_PASSWORD='...' \\"
    echo "    python3 test_script/scripts/set_tenant_credentials.py"
    echo ""
  }
else
  warn "Could not find ntnx-owner password. Run this manually:"
  echo ""
  echo "  TENANT=nutanix \\"
  echo "    LIBCLOUD_USER=ntnx-owner \\"
  echo "    LIBCLOUD_PASSWORD='<ntnx-owner LLDAP password>' \\"
  echo "    LIBCLOUD_NTNX_USER='admin' \\"
  echo "    LIBCLOUD_NTNX_PASSWORD='...' \\"
  echo "    python3 test_script/scripts/set_tenant_credentials.py"
  echo ""
fi

# ── 8. re-seed AWS credentials ──────────────────────────────────────────────
echo ""
info "Now seed the AWS tenant credentials."
info "The set_tenant_credentials.py script requires these env vars:"
echo ""
echo "  TENANT=aws"
echo "  LIBCLOUD_USER=aws-owner"
echo "  LIBCLOUD_PASSWORD='<aws-owner LLDAP password>'"
echo "  LIBCLOUD_AWS_KEY='<AWS access key>'"
echo "  LIBCLOUD_AWS_SECRET='<AWS secret key>'"
echo ""

# Try to auto-detect the aws-owner password from .env
AWS_OWNER_PW="${LIBCLOUD_PASSWORD_AWS_OWNER:-}"
if [[ -z "${AWS_OWNER_PW}" ]]; then
  AWS_OWNER_PW="$(grep -E '^LIBCLOUD_PASSWORD_AWS_OWNER=' "${REPO_ROOT}/.env" 2>/dev/null | cut -d= -f2- || true)"
fi

# Try to auto-detect AWS key/secret from env or .env
AWS_KEY="${LIBCLOUD_AWS_KEY:-}"
if [[ -z "${AWS_KEY}" ]]; then
  AWS_KEY="$(grep -E '^LIBCLOUD_AWS_KEY=' "${REPO_ROOT}/.env" 2>/dev/null | cut -d= -f2- || true)"
fi
AWS_SECRET="${LIBCLOUD_AWS_SECRET:-}"
if [[ -z "${AWS_SECRET}" ]]; then
  AWS_SECRET="$(grep -E '^LIBCLOUD_AWS_SECRET=' "${REPO_ROOT}/.env" 2>/dev/null | cut -d= -f2- || true)"
fi

if [[ -n "${AWS_OWNER_PW}" && -n "${AWS_KEY}" && -n "${AWS_SECRET}" ]]; then
  info "Found aws-owner password, AWS key, and AWS secret — running credential seed automatically ..."
  TENANT=aws \
    LIBCLOUD_USER=aws-owner \
    LIBCLOUD_PASSWORD="${AWS_OWNER_PW}" \
    LIBCLOUD_AWS_KEY="${AWS_KEY}" \
    LIBCLOUD_AWS_SECRET="${AWS_SECRET}" \
    python3 "${SCRIPTS_DIR}/set_tenant_credentials.py" || {
    warn "AWS credential seed returned an error. You may need to run it manually:"
    echo ""
    echo "  TENANT=aws \\"
    echo "    LIBCLOUD_USER=aws-owner \\"
    echo "    LIBCLOUD_PASSWORD='...' \\"
    echo "    LIBCLOUD_AWS_KEY='...' \\"
    echo "    LIBCLOUD_AWS_SECRET='...' \\"
    echo "    python3 test_script/scripts/set_tenant_credentials.py"
    echo ""
  }
else
  warn "Could not auto-detect all AWS credentials. Run this manually:"
  echo ""
  echo "  TENANT=aws \\"
  echo "    LIBCLOUD_USER=aws-owner \\"
  echo "    LIBCLOUD_PASSWORD='<aws-owner LLDAP password>' \\"
  echo "    LIBCLOUD_AWS_KEY='<AWS access key>' \\"
  echo "    LIBCLOUD_AWS_SECRET='<AWS secret key>' \\"
  echo "    python3 test_script/scripts/set_tenant_credentials.py"
  echo ""
  [[ -z "${AWS_OWNER_PW}" ]] && warn "  → Missing: LIBCLOUD_PASSWORD_AWS_OWNER"
  [[ -z "${AWS_KEY}" ]] && warn "  → Missing: LIBCLOUD_AWS_KEY"
  [[ -z "${AWS_SECRET}" ]] && warn "  → Missing: LIBCLOUD_AWS_SECRET"
fi

# ── 9. verify ───────────────────────────────────────────────────────────────
info "Verifying the fix ..."
VERIFY="$(curl -fsS -w '\n%{http_code}' \
  -H 'Origin: http://${PUBLIC_HOSTNAME}:3000' \
  -H 'Accept: application/json' \
  "http://localhost:3000/api/resources/nutanix" 2>&1 || true)"

HTTP_CODE="$(echo "${VERIFY}" | tail -1)"
if [[ "${HTTP_CODE}" == "401" ]]; then
  ok "Endpoint returns 401 (Unauthorized without session — correct!)"
  ok "Vault is working — the 502 is gone."
elif [[ "${HTTP_CODE}" == "200" ]]; then
  ok "Endpoint returns 200 — everything is working!"
else
  warn "Unexpected HTTP ${HTTP_CODE}. Response:"
  echo "${VERIFY}" | head -10
fi

echo ""
echo "============================================"
echo -e "${GREEN}Vault recovery complete!${NC}"
echo "============================================"
echo ""
echo "New credentials written to:"
echo "  • ${VAULT_ENV}"
echo "  • ${REST_ENV}"
echo ""
echo "Test in browser: http://${PUBLIC_HOSTNAME}:3000/admin"
echo "Log in and click 'View Nutanix Resources'"
echo ""
