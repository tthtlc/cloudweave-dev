#!/usr/bin/env bash
# Bootstrap OpenFGA (Postgres-backed) + Dex OIDC IdP + Vault and write
# generated/*.env for the provisioning scripts.
#
# This is the project's OpenFGA deployment (it supersedes the removed
# SQLite-backed openfga_my directory). Characteristics:
#   - OpenFGA's datastore is the `postgres` compose service (image postgres:16)
#     on the openfga-pg-data volume, reached at postgres:5432 on libcloud_net.
#   - `openfga migrate --datastore-engine=postgres` runs before `openfga run`.
#   - POSTGRES_PASSWORD is generated into generated/postgres.env and reused
#     across re-runs so the data volume stays usable.
#   - The `openfga-local:latest` image is built from ./Dockerfile in this
#     directory (multi-stage: downloads the official OpenFGA release tarball
#     from GitHub and verifies its checksum). No openfga binary is vendored;
#     bump OPENFGA_VERSION / OPENFGA_TARBALL_SHA256 in .env to upgrade.
# Everything above the storage layer (openfga_bootstrap.py, scripts/, Dex,
# Vault, LLDAP) lives in this directory — OpenFGA is datastore-agnostic.
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

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

DEX_DIR="${REPO_ROOT}/dex"
VAULT_DIR="${REPO_ROOT}/vault"
LLDAP_DIR="${REPO_ROOT}/lldap"
REST_DIR="${REPO_ROOT}/libcloud.rest"
# After the refactor the OpenFGA+Postgres compose stack and the bootstrap
# scripts (dex_bootstrap.py / openfga_bootstrap.py / vault_bootstrap.py) live
# in openfga_postgres/, and the operator scripts (superadmin_auth.sh,
# provision_*.sh, set_tenant_credentials.py, ...) live in test_script/scripts/.
# generated/fga.env is read by the test_script/scripts/ tools from
# ${REPO_ROOT}/openfga_postgres/generated/fga.env (see common.sh /
# openfga_pylib.py); the openfga-bootstrap container writes it there directly
# via the ./generated compose volume mount, and setup.sh reads/writes the same
# path.
OPENFGA_DIR="${REPO_ROOT}/openfga_postgres"
OPENFGA_COMPOSE="${OPENFGA_DIR}/docker-compose.yml"
SCRIPTS_DIR="${REPO_ROOT}/test_script/scripts"
SCRIPTS_REL="test_script/scripts"
DEX_ENV="${DEX_DIR}/generated/dex.env"
FGA_ENV="${OPENFGA_DIR}/generated/fga.env"
# Postgres credentials live next to the OpenFGA compose stack
# (openfga_postgres/generated/postgres.env): the openfga-pg-data volume is
# initialized with this password and it MUST be reused across re-runs (a fresh
# password would no longer authenticate against the existing data volume).
PG_ENV="${OPENFGA_DIR}/generated/postgres.env"
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

# Public hostname the browser uses to reach Dex (:5556) and the portal (:3000).
# dex_bootstrap.py derives the canonical OIDC issuer from this (the issuer MUST
# be browser-public so federated connector callbacks {issuer}/callback match
# the redirect URI registered in Google/GitHub OAuth apps). Override per-run
# with `DEX_PUBLIC_URL=https://your.host:5556 ./setup.sh`.
export DEX_PUBLIC_URL="${DEX_PUBLIC_URL:-http://login.quest4science.xyz:5556}"

mkdir -p generated "${DEX_DIR}/generated" "${VAULT_DIR}/generated" generated/tokens \
         "${OPENFGA_DIR}/generated"

# ---------------------------------------------------------------------------
# 0a. Persistent Postgres credentials (generated/reused across re-runs).
# ---------------------------------------------------------------------------
if [[ -z "${POSTGRES_PASSWORD:-}" && -f "${PG_ENV}" ]]; then
  POSTGRES_PASSWORD=$(grep -E '^POSTGRES_PASSWORD=' "${PG_ENV}" 2>/dev/null | cut -d= -f2- || true)
  if [[ -n "${POSTGRES_PASSWORD}" ]]; then
    echo "Reusing existing POSTGRES_PASSWORD from ${PG_ENV}."
  fi
fi
if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
  POSTGRES_PASSWORD=$(python3 -c "import secrets; print(secrets.token_urlsafe(24))")
  echo "Generated ephemeral POSTGRES_PASSWORD (also written to ${PG_ENV})."
fi
export POSTGRES_PASSWORD
export POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
export POSTGRES_DB="${POSTGRES_DB:-openfga}"
export POSTGRES_USER="${POSTGRES_USER:-openfga}"
export POSTGRES_SSLMODE="${POSTGRES_SSLMODE:-disable}"
# Persist for re-runs / inspection by operators.
cat > "${PG_ENV}" <<EOF
POSTGRES_HOST=${POSTGRES_HOST}
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_SSLMODE=${POSTGRES_SSLMODE}
EOF
chmod 600 "${PG_ENV}"

# ---------------------------------------------------------------------------
# 0b. Build the `openfga-local:latest` image from ./Dockerfile. The Dockerfile
#     is multi-stage: it downloads the official OpenFGA release tarball from
#     GitHub and verifies it against OPENFGA_TARBALL_SHA256, so this directory
#     is self-contained (no vendored binary, no ../openfga_my dependency).
#     Rebuild only when the Dockerfile or the pinned version/checksum changes
#     (tracked via a stamp file) to keep re-runs fast.
# ---------------------------------------------------------------------------
export OPENFGA_VERSION="${OPENFGA_VERSION:-v1.8.4}"
export OPENFGA_TARBALL_SHA256="${OPENFGA_TARBALL_SHA256:-189b18e5798332edc8f00f1da8ca93a763b5ef19f08e7a9673c4b9e61c85dbaa}"
IMG_STAMP="${REPO_ROOT}/generated/.openfga_image_stamp"
IMG_HASH=$(printf '%s|%s|' "${OPENFGA_VERSION}" "${OPENFGA_TARBALL_SHA256}" | cat - "${OPENFGA_DIR}/Dockerfile" 2>/dev/null | sha256sum | awk '{print $1}')
SAVED_HASH=""
[[ -f "$IMG_STAMP" ]] && SAVED_HASH=$(cat "$IMG_STAMP")
NEED_BUILD=0
if ! docker image inspect openfga-local:latest >/dev/null 2>&1; then
  NEED_BUILD=1
elif [[ "${IMG_HASH}" != "${SAVED_HASH}" ]]; then
  NEED_BUILD=1
fi
if [[ "${NEED_BUILD}" == "1" ]]; then
  echo "Building openfga-local:latest (openfga ${OPENFGA_VERSION}) from ${OPENFGA_DIR}/Dockerfile ..."
  docker compose -f "${OPENFGA_COMPOSE}" build openfga
  echo "${IMG_HASH}" > "$IMG_STAMP"
else
  echo "openfga-local:latest up to date (openfga ${OPENFGA_VERSION})."
fi

# Shared external network for cross-project container-name DNS.
if ! docker network inspect "${SHARED_NET}" >/dev/null 2>&1; then
  echo "Creating shared Docker network ${SHARED_NET} ..."
  docker network create "${SHARED_NET}"
fi

# ---------------------------------------------------------------------------
# 0c. This stack owns the `openfga` / `openfga-migrate` / `openfga-bootstrap`
#     container names + host ports 8080/8081/2112. If a previous run (or a
#     leftover from the removed openfga_my project) left exited containers
#     holding these names, `up --force-recreate` here would fail with
#     "container name already in use" — exited containers keep their name
#     globally. Remove any stale containers with these names that belong to a
#     different compose project.
# ---------------------------------------------------------------------------
for cname in openfga openfga-migrate openfga-bootstrap; do
  proj="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$cname" 2>/dev/null || true)"
  if [[ -n "$proj" && "$proj" != "openfga_postgres" ]]; then
    echo "Removing stale container '$cname' (owned by compose project '$proj') to free the name ..."
    docker rm -f "$cname" >/dev/null
  fi
done

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
DEX_WAIT=0 DEX_DIR="${DEX_DIR}" python3 "${OPENFGA_DIR}/dex_bootstrap.py"

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
# 3. Start Postgres + OpenFGA + Dex + Vault.
#    `up -d openfga` brings up postgres (healthcheck) → openfga-migrate
#    (one-shot, --datastore-engine=postgres) → openfga (run).
# ---------------------------------------------------------------------------
echo "Starting Postgres datastore ..."
docker compose -f "${OPENFGA_COMPOSE}" up -d postgres
echo "Waiting for Postgres healthcheck ..."
for i in $(seq 1 60); do
  if docker inspect --format '{{ .State.Health.Status }}' openfga-postgres 2>/dev/null | grep -qx healthy; then break; fi
  sleep 1
  [[ "$i" -eq 60 ]] && { echo "Postgres did not become healthy in time" >&2; exit 1; }
done

echo "Running OpenFGA migration (postgres) + starting OpenFGA ..."
docker compose -f "${OPENFGA_COMPOSE}" up -d --force-recreate openfga-migrate
# Wait for the one-shot migrate container to finish successfully.
for i in $(seq 1 60); do
  st=$(docker inspect --format '{{ .State.Status }} {{ .State.ExitCode }}' openfga-migrate 2>/dev/null || true)
  if [[ "$st" == "exited 0" ]]; then break; fi
  if [[ "$st" == exited* ]]; then
    echo "openfga-migrate failed (${st}). Logs:" >&2
    docker logs openfga-migrate >&2 || true
    exit 1
  fi
  sleep 1
  [[ "$i" -eq 60 ]] && { echo "openfga-migrate did not complete in time" >&2; exit 1; }
done
docker compose -f "${OPENFGA_COMPOSE}" up -d openfga

docker compose -f "${DEX_DIR}/docker-compose.yml" up -d dex
docker compose -f "${VAULT_DIR}/docker-compose.yml" up -d vault

echo "Waiting for Dex OIDC discovery ..."
DEX_WAIT=1 DEX_DIR="${DEX_DIR}" python3 "${OPENFGA_DIR}/dex_bootstrap.py"
docker compose -f "${DEX_DIR}/docker-compose.yml" up -d --force-recreate dex
for i in $(seq 1 30); do
  if curl -fsS "http://localhost:5556/dex/.well-known/openid-configuration" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Restart OpenFGA so its in-memory JWKS cache is cleared. `--force-recreate dex`
# above minted fresh Dex signing keys; OpenFGA's go-oidc client caches the JWKS
# from a previous Dex keyset and does NOT auto-refresh on an unknown `kid`, so a
# superadmin JWT signed by the new keys would be rejected with `invalid_claims`
# until OpenFGA is restarted. OpenFGA's --authn-oidc-issuer=http://dex:5556/dex
# is unchanged; only the cached keyset is invalidated.
echo "Restarting OpenFGA to refresh cached Dex JWKS ..."
docker compose -f "${OPENFGA_COMPOSE}" up -d --force-recreate openfga
for i in $(seq 1 60); do
  if docker inspect --format '{{ .State.Health.Status }}' openfga 2>/dev/null | grep -qx healthy; then break; fi
  sleep 1
  [[ "$i" -eq 60 ]] && { echo "OpenFGA did not become healthy after restart" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# 4. superadmin login -> SUPERADMIN_JWT. This is the gate for everything below.
#    Without a successful superadmin login, OpenFGA policy changes, Vault
#    seeding, and per-cloud user creation are all refused.
# ---------------------------------------------------------------------------
echo "Authenticating as superadmin (gating credential) ..."
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/superadmin_auth.sh"
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
# 6. OpenFGA bootstrap (policy + tuples), clean re-seed against Postgres.
#    Datastore-agnostic: openfga_bootstrap.py creates a fresh store + model
#    and writes INITIAL_TUPLES (per redesign_openfga_for_postgresql.md §7.9,
#    "clean re-seed" path). Gated on SUPERADMIN_JWT — the openfga-bootstrap
#    container refuses to run without it.
# ---------------------------------------------------------------------------
echo "Waiting for OpenFGA bootstrap (superadmin-gated, clean re-seed) ..."
docker compose -f "${OPENFGA_COMPOSE}" up --no-deps openfga-bootstrap

# ---------------------------------------------------------------------------
# 7. Vault bootstrap (seed backend cloud credentials). Gated on SUPERADMIN_JWT.
#    The credential values come from the superadmin's environment (exported
#    before running setup.sh), NOT from .env.
# ---------------------------------------------------------------------------
echo "Bootstrapping Vault (superadmin-gated; seeds cloud creds from env) ..."
docker compose -f "${VAULT_DIR}/docker-compose.yml" up --no-deps vault-bootstrap

# ---------------------------------------------------------------------------
# 8. Sync OpenFGA IDs + Vault token into ../libcloud.rest/.env.
#    The Postgres re-seed mints NEW store/model IDs (the SQLite store ID
#    01KW9EZ0Q706Y580FGQ2488THC does not carry over); sync_libcloud_rest_fga
#    updates libcloud.rest/.env and restarts the REST API so it points at the
#    Postgres-backed store.
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
echo "  Postgres env : ${PG_ENV}  (datastore: postgres://${POSTGRES_USER}@${POSTGRES_HOST}:5432/${POSTGRES_DB})"
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
echo "Datastore: PostgreSQL (container openfga-postgres, volume openfga_postgres-pg-data / openfga-pg-data)."
echo "Inspect tuples via SQL:"
echo "  docker exec -it openfga-postgres psql -U \${POSTGRES_USER} -d \${POSTGRES_DB} -c 'select count(*) from tuple;'"
echo
echo "OpenFGA image: openfga-local:latest, built from ${OPENFGA_DIR}/Dockerfile (openfga ${OPENFGA_VERSION})."
echo
echo "Cloud backend credentials are per-tenant and NOT set by setup.sh."
echo "Each tenant's OWNER writes its credentials to Vault (gated by OpenFGA"
echo "can_manage_credentials; admins/viewers cannot):"
echo "  TENANT=aws LIBCLOUD_USER=aws-owner LIBCLOUD_PASSWORD=\$LIBCLOUD_PASSWORD_AWS_OWNER \\"
echo "    LIBCLOUD_AWS_KEY=AKIA... LIBCLOUD_AWS_SECRET=... \\"
echo "    python3 ${SCRIPTS_REL}/set_tenant_credentials.py"
echo "  TENANT=nutanix LIBCLOUD_USER=ntnx-owner LIBCLOUD_PASSWORD=\$LIBCLOUD_PASSWORD_NTNX_OWNER \\"
echo "    LIBCLOUD_NTNX_USER=admin LIBCLOUD_NTNX_PASSWORD=... \\"
echo "    python3 ${SCRIPTS_REL}/set_tenant_credentials.py"
echo "superadmin (owner on both tenants) can set them too."
echo
echo "Then run:"
echo "  LIBCLOUD_USER=aws-admin   ./${SCRIPTS_REL}/provision_aws.sh"
echo "  LIBCLOUD_USER=aws-viewer  ./${SCRIPTS_REL}/provision_aws.sh"
echo "  LIBCLOUD_USER=ntnx-admin  ./${SCRIPTS_REL}/provision_nutanix.sh"
echo "  LIBCLOUD_USER=ntnx-viewer ./${SCRIPTS_REL}/provision_nutanix.sh"
