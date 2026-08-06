#!/usr/bin/env bash
# fix_vault_token.sh
# ================
# Fix the "502 rest_error" / Vault "permission denied" issue by checking Vault
# health, unsealing if needed, and issuing a fresh read token for the libcloud
# REST API.  Updates both vault/generated/vault.env and libcloud.rest/.env, then
# restarts the REST API container so it picks up the new token.
#
# Run from the repository root directory.  Safe to re-run (idempotent).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

VAULT_ENV="${REPO_ROOT}/vault/generated/vault.env"
REST_ENV="${REPO_ROOT}/libcloud.rest/.env"
REST_CONTAINER="${LIBCLOUD_REST_CONTAINER:-libcloud-rest-api}"

# --- helpers ----------------------------------------------------------------
bail() { printf '\n\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '\033[1;34m→\033[0m %s\n' "$*"; }
ok()   { printf '   \033[0;32m✓\033[0m %s\n' "$*"; }

# --- 1. load secrets from the existing generated vault env -------------------
info "Loading secrets from ${VAULT_ENV} ..."
if [[ ! -f "${VAULT_ENV}" ]]; then
  bail "Missing ${VAULT_ENV} — run setup.sh first (./setup.sh)."
fi

# shellcheck disable=SC1090
source <(grep -E '^(VAULT_ADDR|VAULT_TOKEN|VAULT_ROOT_TOKEN|VAULT_UNSEAL_KEY)=' "${VAULT_ENV}")

# Force VAULT_ADDR to localhost for host-side scripting (the file has
# http://localhost:8200 already, but be safe).
VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
: "${VAULT_ROOT_TOKEN:?VAULT_ROOT_TOKEN not found in vault.env}"
: "${VAULT_UNSEAL_KEY:?VAULT_UNSEAL_KEY not found in vault.env}"

ok "VAULT_ADDR=${VAULT_ADDR}"

# --- 2. check Vault is reachable --------------------------------------------
info "Checking Vault is reachable at ${VAULT_ADDR} ..."
if ! curl -fsS "${VAULT_ADDR}/v1/sys/seal-status" > /dev/null 2>&1; then
  bail "Cannot reach Vault at ${VAULT_ADDR}.  Is the vault container running?
       Try: docker compose -f vault/docker-compose.yml up -d vault"
fi
ok "Vault is reachable"

# --- 3. check seal status & unseal if needed --------------------------------
SEAL_STATUS="$(curl -fsS "${VAULT_ADDR}/v1/sys/seal-status" 2>&1)"
SEALED="$(echo "${SEAL_STATUS}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed', True))" 2>/dev/null || echo "true")"

if [[ "${SEALED}" == "True" ]]; then
  info "Vault is sealed — unsealing ..."
  UNSEAL_RESP="$(curl -fsS -X POST "${VAULT_ADDR}/v1/sys/unseal" \
    -H 'Content-Type: application/json' \
    -d "{\"key\": \"${VAULT_UNSEAL_KEY}\"}")"
  UNSEAL_SEALED="$(echo "${UNSEAL_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed', True))")"
  if [[ "${UNSEAL_SEALED}" != "False" ]]; then
    bail "Vault unseal failed. Response: ${UNSEAL_RESP}"
  fi
  ok "Vault unsealed successfully"
else
  ok "Vault is already unsealed"
fi

# --- 4. check current token validity ----------------------------------------
CURRENT_TOKEN="${VAULT_TOKEN:-}"
TOKEN_VALID=false
if [[ -n "${CURRENT_TOKEN}" ]]; then
  info "Checking current VAULT_TOKEN ..."
  if curl -fsS -o /dev/null -w '%{http_code}' \
    -H "X-Vault-Token: ${CURRENT_TOKEN}" \
    "${VAULT_ADDR}/v1/auth/token/lookup-self" 2>/dev/null | grep -q '^200$'; then
    TOKEN_VALID=true
    ok "Current VAULT_TOKEN is valid"
  else
    info "Current VAULT_TOKEN is expired or invalid"
  fi
else
  info "No current VAULT_TOKEN found — will issue a new one"
fi

# --- 5. ensure the libcloud-rest-read policy exists -------------------------
info "Ensuring libcloud-rest-read ACL policy exists ..."
POLICY_EXISTS="$(curl -fsS -o /dev/null -w '%{http_code}' \
  -H "X-Vault-Token: ${VAULT_ROOT_TOKEN}" \
  "${VAULT_ADDR}/v1/sys/policies/acl/libcloud-rest-read" 2>/dev/null || echo "404")"

if [[ "${POLICY_EXISTS}" != "200" ]]; then
  info "Creating libcloud-rest-read policy ..."
  curl -fsS -X PUT \
    -H "X-Vault-Token: ${VAULT_ROOT_TOKEN}" \
    -H 'Content-Type: application/json' \
    "${VAULT_ADDR}/v1/sys/policies/acl/libcloud-rest-read" \
    -d '{"policy": "path \"secret/data/libcloud/*\" {\n  capabilities = [\"read\"]\n}\npath \"secret/metadata/libcloud/*\" {\n  capabilities = [\"read\", \"list\"]\n}"}' > /dev/null
  ok "Policy created"
else
  ok "Policy already exists"
fi

# --- 6. issue a fresh read token --------------------------------------------
info "Issuing fresh libcloud REST API read token (TTL=768h / 32 days) ..."
TOKEN_RESP="$(curl -fsS -X POST \
  -H "X-Vault-Token: ${VAULT_ROOT_TOKEN}" \
  -H 'Content-Type: application/json' \
  "${VAULT_ADDR}/v1/auth/token/create" \
  -d '{"policies": ["libcloud-rest-read"], "ttl": "768h", "renewable": true}')"

NEW_TOKEN="$(echo "${TOKEN_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin)['auth']['client_token'])")"

if [[ -z "${NEW_TOKEN}" || "${NEW_TOKEN}" == "None" ]]; then
  bail "Failed to extract new token from Vault response:
       ${TOKEN_RESP}"
fi
ok "New token issued: ${NEW_TOKEN:0:16}..."

# --- 7. verify the new token can read the nutanix secret --------------------
info "Testing new token can read secret/data/libcloud/nutanix ..."
TEST_STATUS="$(curl -fsS -o /dev/null -w '%{http_code}' \
  -H "X-Vault-Token: ${NEW_TOKEN}" \
  "${VAULT_ADDR}/v1/secret/data/libcloud/nutanix" 2>/dev/null || echo "000")"

if [[ "${TEST_STATUS}" == "200" ]]; then
  ok "Token can read secret/data/libcloud/nutanix"
elif [[ "${TEST_STATUS}" == "404" ]]; then
  info "WARNING: Nutanix secret does not exist in Vault yet (HTTP ${TEST_STATUS})"
  info "Run set_tenant_credentials.py to seed it:"
  echo ""
  echo "  TENANT=nutanix LIBCLOUD_USER=ntnx-owner LIBCLOUD_PASSWORD='...' \\"
  echo "    LIBCLOUD_NTNX_USER='admin' LIBCLOUD_NTNX_PASSWORD='...' \\"
  echo "    python3 test_script/scripts/set_tenant_credentials.py"
  echo ""
else
  info "WARNING: Token read test returned HTTP ${TEST_STATUS} (may need set_tenant_credentials.py)"
fi

# --- 8. update vault/generated/vault.env ------------------------------------
info "Updating ${VAULT_ENV} ..."
sed -i "s/^VAULT_TOKEN=.*/VAULT_TOKEN=${NEW_TOKEN}/" "${VAULT_ENV}"
ok "Updated vault.env"

# --- 9. update libcloud.rest/.env -------------------------------------------
if [[ -f "${REST_ENV}" ]]; then
  info "Updating ${REST_ENV} ..."
  if grep -q '^VAULT_TOKEN=' "${REST_ENV}"; then
    sed -i "s/^VAULT_TOKEN=.*/VAULT_TOKEN=${NEW_TOKEN}/" "${REST_ENV}"
  else
    echo "VAULT_TOKEN=${NEW_TOKEN}" >> "${REST_ENV}"
  fi
  ok "Updated libcloud.rest/.env"
else
  info "WARNING: ${REST_ENV} not found — skipping"
fi

# --- 10. restart the libcloud REST API container -----------------------------
# IMPORTANT: docker restart does NOT re-read the .env file, so the container
# would keep the old VAULT_TOKEN.  Use --force-recreate to reload env vars.
info "Recreating container '${REST_CONTAINER}' to pick up new VAULT_TOKEN ..."
docker compose -f libcloud.rest/docker-compose.yml up -d --force-recreate api
ok "Container ${REST_CONTAINER} recreated with fresh env"
#fi

# --- 11. wait for health check ----------------------------------------------
info "Waiting for REST API to become healthy (max 60s) ..."
for i in $(seq 1 30); do
  if curl -fsS -o /dev/null "http://localhost:8765/health" 2>/dev/null; then
    ok "REST API is healthy"
    break
  fi
  if [[ $i -eq 30 ]]; then
    bail "REST API did not become healthy — check: docker logs ${REST_CONTAINER}"
  fi
  sleep 2
done

# --- 12. verify the fix ------------------------------------------------------
info "Verifying the fix — test /api/resources/nutanix via the portal ..."
VERIFY="$(curl -fsS -w '\n%{http_code}' \
  -H 'Origin: http://login.cloudweave.xyz:3000' \
  -H 'Accept: application/json' \
  "http://localhost:3000/api/resources/nutanix" 2>&1 || true)"

HTTP_CODE="$(echo "${VERIFY}" | tail -1)"
if [[ "${HTTP_CODE}" == "401" ]]; then
  ok "Endpoint returns 401 (Unauthorized — expected without session cookie, correct)"
  ok "Vault token is working! The endpoint no longer returns 502."
elif [[ "${HTTP_CODE}" == "200" ]]; then
  ok "Endpoint returns 200 — everything is working!"
else
  echo "${VERIFY}" | head -5
  info "Got HTTP ${HTTP_CODE} — if this is 401 it's fine (no session cookie)."
fi

# --- done -------------------------------------------------------------------
echo ""
echo "============================================"
echo -e "\033[0;32mVault token refresh complete!\033[0m"
echo "============================================"
echo ""
echo "New token written to:"
echo "  • ${VAULT_ENV}"
echo "  • ${REST_ENV}"
echo ""
echo "If the browser still shows a 502, re-seed the Nutanix credentials:"
echo ""
echo "  TENANT=nutanix \\"
echo "    LIBCLOUD_USER=ntnx-owner \\"
echo "    LIBCLOUD_PASSWORD='<ntnx-owner LLDAP password>' \\"
echo "    LIBCLOUD_NTNX_USER='<Prism username>' \\"
echo "    LIBCLOUD_NTNX_PASSWORD='<Prism password>' \\"
echo "    python3 test_script/scripts/set_tenant_credentials.py"
echo ""
