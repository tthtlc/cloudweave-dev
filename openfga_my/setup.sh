#!/usr/bin/env bash
# Bootstrap OpenFGA + Dex OIDC IdP + Vault and write generated/*.env for the
# provisioning scripts.
#
# Identity model (per privilege.md / privilege0.md):
#   superadmin (LLDAP uid=superadmin) is the bootstrap identity. After a
#   successful Dex login as superadmin, the resulting JWT gates:
#     - Vault seeding of backend cloud credentials
#     - OpenFGA policy / privilege tuple changes
#     - LLDAP create / modify / delete of the per-cloud users
#   Per-cloud tenants: tenant:aws (owner/admin/viewer), tenant:nutanix
#   (owner/admin/viewer). admins can provision; viewers can only enumerate.
#
# Dex, Vault, and LLDAP live in sibling standalone compose projects (../dex,
# ../vault, ../lldap); OpenFGA stays in this project. All four (plus
# ../libcloud.rest) share the external `libcloud_net` Docker network so
# containers reach each other by name. Host-side scripts use published ports.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

DEX_DIR="${ROOT}/../dex"
VAULT_DIR="${ROOT}/../vault"
LLDAP_DIR="${ROOT}/../lldap"
REST_DIR="${ROOT}/../libcloud.rest"
DEX_ENV="${DEX_DIR}/generated/dex.env"
FGA_ENV="${ROOT}/generated/fga.env"
VAULT_ENV="${VAULT_DIR}/generated/vault.env"
SHARED_NET="libcloud_net"

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example — review the superadmin + user passwords."
fi

set -a
source .env
set +a

# LLDAP holds the user directory (Dex authenticates against LLDAP over LDAP).
source "${LLDAP_DIR}/.env" 2>/dev/null || true
export LLDAP_BASE_DN="${LLDAP_LDAP_BASE_DN:-dc=libcloud,dc=local}"
export LLDAP_ADMIN_USER="${LLDAP_ADMIN_USER:-admin}"
export LLDAP_BIND_DN="uid=${LLDAP_ADMIN_USER},ou=people,${LLDAP_BASE_DN}"
export LLDAP_BIND_PW="${LLDAP_LDAP_USER_PASS:-}"

export HOST_UID="$(id -u)"
export HOST_GID="$(id -g)"

mkdir -p generated "${DEX_DIR}/generated" "${VAULT_DIR}/generated" generated/tokens

# Shared external network for cross-project container-name DNS.
if ! docker network inspect "${SHARED_NET}" >/dev/null 2>&1; then
  echo "Creating shared Docker network ${SHARED_NET} ..."
  docker network create "${SHARED_NET}"
fi

# Reuse the existing OIDC client secret on re-runs / migration so the
# Dex issuer boundary stays stable and previously issued refresh tokens
# (generated/tokens/*.json) keep working. Only generate a new secret if
# neither .env nor an existing generated/dex.env provides one (first boot).
if [[ -z "${LIBCLOUD_OIDC_CLIENT_SECRET:-}" && -f "${DEX_ENV}" ]]; then
  LIBCLOUD_OIDC_CLIENT_SECRET=$(grep -E '^LIBCLOUD_OIDC_CLIENT_SECRET=' "${DEX_ENV}" 2>/dev/null | cut -d= -f2- || true)
  if [[ -n "${LIBCLOUD_OIDC_CLIENT_SECRET}" ]]; then
    echo "Reusing existing LIBCLOUD_OIDC_CLIENT_SECRET from ${DEX_ENV}."
  fi
fi
if [[ -z "${LIBCLOUD_OIDC_CLIENT_SECRET:-}" ]]; then
  LIBCLOUD_OIDC_CLIENT_SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
  echo "Generated ephemeral LIBCLOUD_OIDC_CLIENT_SECRET (also written to ${DEX_ENV})."
fi
export LIBCLOUD_OIDC_CLIENT_SECRET

# ---------------------------------------------------------------------------
# 1. Render Dex config + write generated/dex.env (with user passwords).
# ---------------------------------------------------------------------------
echo "Rendering Dex config (LDAP connector → LLDAP) ..."
DEX_WAIT=0 DEX_DIR="${DEX_DIR}" python3 dex_bootstrap.py

# dex_bootstrap.py generated/collected user passwords into generated/dex.env.
# Source them so setup.sh can create the matching LLDAP users.
set -a
# shellcheck source=/dev/null
source "${DEX_ENV}"
set +a

# ---------------------------------------------------------------------------
# 2. Ensure LLDAP is up + custom attributes exist, then create superadmin
#    (the break-glass bootstrap user, via the LLDAP admin account).
# ---------------------------------------------------------------------------
echo "Starting LLDAP ..."
docker compose -f "${LLDAP_DIR}/docker-compose.yml" up -d lldap
echo "Waiting for LLDAP web UI ..."
for i in $(seq 1 60); do
  if curl -fsS --max-time 3 "http://localhost:${LLDAP_HTTP_PORT:-17170}/" -o /dev/null 2>/dev/null; then break; fi
  sleep 1
  [[ "$i" -eq 60 ]] && { echo "LLDAP did not become ready in time" >&2; exit 1; }
done
docker compose -f "${LLDAP_DIR}/docker-compose.yml" --profile bootstrap up bootstrap

ensure_user() {
  docker compose -f "${LLDAP_DIR}/docker-compose.yml" run --rm lldap-tools \
    /scripts/lldap_ensure_user.sh "$@"
}

echo "Creating superadmin in LLDAP (break-glass via LLDAP admin) ..."
ensure_user superadmin superadmin@libcloud.local "Super Admin" platform superadmin "Platform Superadmin" "${LIBCLOUD_SUPERADMIN_PASSWORD}"

# ---------------------------------------------------------------------------
# 3. Start OpenFGA + Dex + Vault. Dex must be up before superadmin can log in.
# ---------------------------------------------------------------------------
echo "Starting OpenFGA + Dex + Vault ..."
STAMP="${ROOT}/generated/.openfga_image_stamp"
CURRENT_HASH=$(cat "${ROOT}/Dockerfile" "${ROOT}/openfga" 2>/dev/null | sha256sum | awk '{print $1}')
SAVED_HASH=""
[[ -f "$STAMP" ]] && SAVED_HASH=$(cat "$STAMP")
NEED_BUILD=0
if ! docker image inspect openfga-local:latest >/dev/null 2>&1; then
  NEED_BUILD=1
elif [[ "${CURRENT_HASH}" != "${SAVED_HASH}" ]]; then
  NEED_BUILD=1
fi
if [[ "${NEED_BUILD}" == "1" ]]; then
  echo "  Building openfga-local image (image missing or Dockerfile/binary changed) ..."
  docker compose up -d --build openfga
  echo "${CURRENT_HASH}" > "${STAMP}"
else
  docker compose up -d openfga
fi
docker compose -f "${DEX_DIR}/docker-compose.yml" up -d dex
docker compose -f "${VAULT_DIR}/docker-compose.yml" up -d vault

echo "Waiting for Dex OIDC discovery ..."
DEX_WAIT=1 DEX_DIR="${DEX_DIR}" python3 dex_bootstrap.py
docker compose -f "${DEX_DIR}/docker-compose.yml" up -d --force-recreate dex
for i in $(seq 1 30); do
  if curl -fsS "http://localhost:5556/dex/.well-known/openid-configuration" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# ---------------------------------------------------------------------------
# 4. superadmin login -> SUPERADMIN_JWT. This is the gate for everything below.
#    Without a successful superadmin login, OpenFGA policy changes, Vault
#    seeding, and per-cloud user creation are all refused.
# ---------------------------------------------------------------------------
echo "Authenticating as superadmin (gating credential) ..."
# shellcheck source=/dev/null
source "${ROOT}/scripts/superadmin_auth.sh"
export SUPERADMIN_JWT
echo "  superadmin JWT acquired and verified."

# ---------------------------------------------------------------------------
# 5. Create the per-cloud users (owners / admins / viewers). Gated by the
#    superadmin JWT obtained above — if superadmin login had failed, setup.sh
#    would have exited at step 4.
# ---------------------------------------------------------------------------
echo "Creating per-cloud tenant users in LLDAP (gated by superadmin) ..."
ensure_user aws-owner  aws-owner@libcloud.local  "AWS Owner"     aws    owner   "AWS Owner"     "${LIBCLOUD_PASSWORD_AWS_OWNER}"
ensure_user aws-admin  aws-admin@libcloud.local  "AWS Admin"     aws    admin    "AWS Admin"     "${LIBCLOUD_PASSWORD_AWS_ADMIN}"
ensure_user aws-viewer aws-viewer@libcloud.local "AWS Viewer"    aws    viewer   "AWS Viewer"    "${LIBCLOUD_PASSWORD_AWS_VIEWER}"
ensure_user ntnx-owner  ntnx-owner@libcloud.local  "Nutanix Owner"  nutanix owner   "Nutanix Owner"  "${LIBCLOUD_PASSWORD_NTNX_OWNER}"
ensure_user ntnx-admin  ntnx-admin@libcloud.local  "Nutanix Admin"  nutanix admin    "Nutanix Admin"  "${LIBCLOUD_PASSWORD_NTNX_ADMIN}"
ensure_user ntnx-viewer ntnx-viewer@libcloud.local "Nutanix Viewer" nutanix viewer   "Nutanix Viewer" "${LIBCLOUD_PASSWORD_NTNX_VIEWER}"
ensure_user cloud-denied cloud-denied@libcloud.local "Cloud Denied" none denied "Denied Demo" "${LIBCLOUD_PASSWORD_CLOUD_DENIED}"

# ---------------------------------------------------------------------------
# 6. OpenFGA bootstrap (policy + tuples). Gated on SUPERADMIN_JWT — the
#    openfga-bootstrap container refuses to run without it.
# ---------------------------------------------------------------------------
echo "Waiting for OpenFGA bootstrap (superadmin-gated) ..."
docker compose up --no-deps openfga-bootstrap

# ---------------------------------------------------------------------------
# 7. Vault bootstrap (seed backend cloud credentials). Gated on SUPERADMIN_JWT.
#    The credential values come from the superadmin's environment (exported
#    before running setup.sh), NOT from .env.
# ---------------------------------------------------------------------------
echo "Bootstrapping Vault (superadmin-gated; seeds cloud creds from env) ..."
docker compose -f "${VAULT_DIR}/docker-compose.yml" up --no-deps vault-bootstrap

# ---------------------------------------------------------------------------
# 8. Sync OpenFGA IDs + Vault token into ../libcloud.rest/.env.
# ---------------------------------------------------------------------------
sync_libcloud_rest_fga() {
  local rest_env="${REST_DIR}/.env"
  [[ -f "$FGA_ENV" && -f "$rest_env" ]] || return 0

  local store_id model_id
  store_id=$(grep -E '^FGA_STORE_ID=' "$FGA_ENV" | cut -d= -f2-)
  model_id=$(grep -E '^FGA_MODEL_ID=' "$FGA_ENV" | cut -d= -f2-)
  [[ -n "$store_id" && -n "$model_id" ]] || { echo "  ${FGA_ENV} missing IDs — skipping sync"; return 0; }

  local cur_store cur_model
  cur_store=$(grep -E '^FGA_STORE_ID=' "$rest_env" | cut -d= -f2-)
  cur_model=$(grep -E '^FGA_MODEL_ID=' "$rest_env" | cut -d= -f2-)

  if [[ "$cur_store" == "$store_id" && "$cur_model" == "$model_id" ]]; then
    echo "  libcloud.rest FGA IDs already current — no restart needed"
    return 0
  fi

  echo "  Updating libcloud.rest FGA_STORE_ID / FGA_MODEL_ID (OpenFGA IDs changed)"
  python3 - "$rest_env" "$store_id" "$model_id" <<'PY'
import re, sys
path, store_id, model_id = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as fh:
    text = fh.read()
text = re.sub(r"^FGA_STORE_ID=.*$", f"FGA_STORE_ID={store_id}", text, flags=re.M)
text = re.sub(r"^FGA_MODEL_ID=.*$", f"FGA_MODEL_ID={model_id}", text, flags=re.M)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(text)
PY

  if docker compose -f "$REST_DIR/docker-compose.yml" ps --status running api 2>/dev/null | grep -q '\blibcloud-rest-api\b'; then
    echo "  Recreating libcloud-rest-api container to apply new FGA env"
    docker compose -f "$REST_DIR/docker-compose.yml" up -d --build --force-recreate api
  else
    echo "  libcloud-rest-api not running — start it with: docker compose -f $REST_DIR/docker-compose.yml up -d --build api"
  fi
}

echo "Syncing OpenFGA IDs -> libcloud.rest ..."
sync_libcloud_rest_fga

sync_libcloud_rest_vault() {
  local rest_env="${REST_DIR}/.env"
  [[ -f "$VAULT_ENV" && -f "$rest_env" ]] || { echo "  ${VAULT_ENV} missing — skipping Vault sync"; return 0; }

  local vault_token
  vault_token=$(grep -E '^VAULT_TOKEN=' "$VAULT_ENV" | cut -d= -f2-)
  [[ -n "$vault_token" ]] || { echo "  ${VAULT_ENV} missing VAULT_TOKEN — skipping"; return 0; }

  local rest_vault_addr="http://vault:8200"
  python3 - "$rest_env" "$rest_vault_addr" "$vault_token" <<'PY'
import re, sys
path, addr, token = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as fh:
    text = fh.read()
def set_key(t, key, val):
    if re.search(rf"^{key}=.*$", t, flags=re.M):
        return re.sub(rf"^{key}=.*$", f"{key}={val}", t, flags=re.M)
    return t.rstrip("\n") + f"\n{key}={val}\n"
text = set_key(text, "VAULT_ADDR", addr)
text = set_key(text, "VAULT_TOKEN", token)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(text)
PY
  echo "  Updated libcloud.rest VAULT_ADDR / VAULT_TOKEN"

  if docker compose -f "$REST_DIR/docker-compose.yml" ps --status running api 2>/dev/null | grep -q '\blibcloud-rest-api\b'; then
    echo "  Recreating libcloud-rest-api container to apply Vault env"
    docker compose -f "$REST_DIR/docker-compose.yml" up -d --build --force-recreate api
  else
    echo "  libcloud-rest-api not running — start it with: docker compose -f $REST_DIR/docker-compose.yml up -d --build api"
  fi
}

echo "Syncing Vault credentials -> libcloud.rest ..."
sync_libcloud_rest_vault

echo
echo "Setup complete."
echo "  OpenFGA env  : ${FGA_ENV}"
echo "  Dex OIDC     : ${DEX_ENV}"
echo "  Vault        : ${VAULT_ENV}"
echo
echo "Identity model:"
echo "  superadmin   / ${LIBCLOUD_SUPERADMIN_PASSWORD}   (bootstrap: Vault/OpenFGA/LLDAP admin)"
echo "  aws-owner    / ${LIBCLOUD_PASSWORD_AWS_OWNER}    (owner  of tenant:aws)"
echo "  aws-admin    / ${LIBCLOUD_PASSWORD_AWS_ADMIN}    (admin  of tenant:aws -> provision AWS)"
echo "  aws-viewer   / ${LIBCLOUD_PASSWORD_AWS_VIEWER}   (viewer of tenant:aws -> enumerate only)"
echo "  ntnx-owner   / ${LIBCLOUD_PASSWORD_NTNX_OWNER}   (owner  of tenant:nutanix)"
echo "  ntnx-admin   / ${LIBCLOUD_PASSWORD_NTNX_ADMIN}   (admin  of tenant:nutanix -> provision Nutanix)"
echo "  ntnx-viewer  / ${LIBCLOUD_PASSWORD_NTNX_VIEWER}  (viewer of tenant:nutanix -> enumerate only)"
echo "  cloud-denied / ${LIBCLOUD_PASSWORD_CLOUD_DENIED} (authenticated but denied)"
echo
echo "Cloud backend credentials are per-tenant and NOT set by setup.sh."
echo "Each tenant's OWNER writes its credentials to Vault (gated by OpenFGA"
echo "can_manage_credentials; admins/viewers cannot):"
echo "  TENANT=aws LIBCLOUD_USER=aws-owner LIBCLOUD_PASSWORD=\$LIBCLOUD_PASSWORD_AWS_OWNER \\"
echo "    LIBCLOUD_AWS_KEY=AKIA... LIBCLOUD_AWS_SECRET=... \\"
echo "    python3 scripts/set_tenant_credentials.py"
echo "  TENANT=nutanix LIBCLOUD_USER=ntnx-owner LIBCLOUD_PASSWORD=\$LIBCLOUD_PASSWORD_NTNX_OWNER \\"
echo "    LIBCLOUD_NTNX_USER=admin LIBCLOUD_NTNX_PASSWORD=... \\"
echo "    python3 scripts/set_tenant_credentials.py"
echo "superadmin (owner on both tenants) can set them too."
echo
echo "Then run:"
echo "  LIBCLOUD_USER=aws-admin   ./scripts/provision_aws.sh"
echo "  LIBCLOUD_USER=aws-viewer  ./scripts/provision_aws.sh"
echo "  LIBCLOUD_USER=ntnx-admin  ./scripts/provision_nutanix.sh"
echo "  LIBCLOUD_USER=ntnx-viewer ./scripts/provision_nutanix.sh"
