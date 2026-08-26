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

# Vendored Apache libcloud source tree used by libcloud.rest. The REST API image
# (libcloud.rest/Dockerfile) does `COPY libcloud /libcloud` + `pip install /libcloud`,
# so this tree IS the libcloud version the REST API runs against — there is no
# PyPI pin in libcloud.rest/requirements.txt for libcloud itself. We pin it here
# to a known stable upstream release for reproducibility, mirroring how
# openfga_postgres pins the OpenFGA tarball checksum.
LIBCLOUD_DIR="${REPO_ROOT}/libcloud"
# Pinned to apache-libcloud v3.9.1 (latest stable on PyPI as of 2026-07),
# upstream commit 6c867a3ca299f1b16057fab96bff65564c0ac5fe (2026-04-16, "Fix ver
# num"). This is a tagged release, NOT the floating trunk dev snapshot
# (3.9.2.dev0) the tree was previously on. On top of v3.9.1 this repo carries a
# LOCAL Nutanix driver that is not upstream:
#   libcloud/common/nutanix.py
#   libcloud/compute/drivers/nutanix.py
#   libcloud/storage/drivers/nutanix.py
# plus its registration in libcloud/compute/types.py (Provider.NUTANIX) and
# libcloud/compute/providers.py (NutanixNodeDriver). The check below fails fast
# if the vendored tree has drifted off the pin (e.g. someone ran `git pull` or
# `git checkout trunk` inside libcloud/), so the REST API build is reproducible.
LIBCLOUD_PIN_TAG="v3.9.1"
LIBCLOUD_PIN_COMMIT="6c867a3ca299f1b16057fab96bff65564c0ac5fe"

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

# Public hostname the browser uses to reach the portal (:3000) and Dex through
# the portal nginx proxy (:3000/dex). Host-side scripts reach Dex directly at
# localhost:5556 (bound 127.0.0.1 — NOT reachable via the public hostname).
# dex_bootstrap.py derives the canonical OIDC issuer from DEX_INTERNAL_URL
# (http://dex:5556, the in-container URL); DEX_PUBLIC_URL is for HOST scripts only.
# Override per-run: DEX_PUBLIC_URL=http://your-host:3000 ./setup.sh
export PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME}"
export DEX_PUBLIC_URL="${DEX_PUBLIC_URL:-http://localhost:5556}"

mkdir -p generated "${DEX_DIR}/generated" "${VAULT_DIR}/generated" generated/tokens \
         "${OPENFGA_DIR}/generated"

# ---------------------------------------------------------------------------
# 0a0. Sync PUBLIC_HOSTNAME to sub-project .env files.
#   Docker Compose reads the .env file in its project directory when resolving
#   ${PUBLIC_HOSTNAME:-localhost} variable substitutions. When containers are
#   started outside of setup.sh (manual restart, system reboot), the shell
#   environment is absent and only the project-local .env is read. If it still
#   says localhost, browser-facing URLs (Dex authorize endpoint, OAuth
#   redirects) will point to localhost instead of the real public hostname.
#   This helper ensures every sub-project .env stays in sync with the root
#   .env's PUBLIC_HOSTNAME so the stack works regardless of how containers
#   were started.
# ---------------------------------------------------------------------------
sync_subproject_env() {
  local dir="$1"
  local env_file="${dir}/.env"
  local example="${dir}/.env.example"
  local created=0

  if [[ ! -f "${env_file}" ]]; then
    if [[ -f "${example}" ]]; then
      cp "${example}" "${env_file}"
      echo "  Created ${env_file} from .env.example"
    else
      touch "${env_file}"
      echo "  Created empty ${env_file}"
    fi
    created=1
  fi

  if grep -qE '^PUBLIC_HOSTNAME=' "${env_file}" 2>/dev/null; then
    local cur
    cur=$(grep -E '^PUBLIC_HOSTNAME=' "${env_file}" | head -1 | cut -d= -f2-)
    if [[ "${cur}" != "${PUBLIC_HOSTNAME}" ]]; then
      sed -i "s/^PUBLIC_HOSTNAME=.*/PUBLIC_HOSTNAME=${PUBLIC_HOSTNAME}/" "${env_file}"
      echo "  ${env_file}: PUBLIC_HOSTNAME=${cur} -> ${PUBLIC_HOSTNAME}"
    else
      echo "  ${env_file}: PUBLIC_HOSTNAME already ${PUBLIC_HOSTNAME}"
    fi
  else
    echo "PUBLIC_HOSTNAME=${PUBLIC_HOSTNAME}" >> "${env_file}"
    [[ "${created}" -eq 0 ]] && echo "  ${env_file}: added PUBLIC_HOSTNAME=${PUBLIC_HOSTNAME}"
  fi
}

# ---------------------------------------------------------------------------
# 0a1. Seed $REPO_ROOT/my.env from root .env (PUBLIC_HOSTNAME + NUTANIX_*).
#   my.env is bind-mounted into the identity-service/portal/visualizer
#   containers and re-read at request time (identity_service/app/hot_config.py),
#   so NUTANIX_* edits take effect live with NO container restart.
#   PUBLIC_HOSTNAME still requires a portal+dex recreate (baked into the JS
#   bundle + Dex redirect URIs). Seed once on first run; afterwards edit my.env
#   directly rather than root .env for these values.
# ---------------------------------------------------------------------------
sync_myenv() {
  local myenv="${REPO_ROOT}/my.env"
  if [[ -f "${myenv}" ]]; then
    echo "  ${myenv}: present — edit directly for live reload (NUTANIX_*)."
    return
  fi
  cat > "${myenv}" <<EOF
# AUTO-GENERATED by setup.sh from root .env on first run — edit this file
# directly for live reload (NUTANIX_*). See my.env.example for docs.
PUBLIC_HOSTNAME=${PUBLIC_HOSTNAME}
NUTANIX_HOST=${NUTANIX_HOST:-host.docker.internal}
NUTANIX_PORT=${NUTANIX_PORT:-9440}
NUTANIX_API_VERSION=${NUTANIX_API_VERSION:-v4.0}
NUTANIX_VERIFY_SSL=${NUTANIX_VERIFY_SSL:-false}
EOF
  echo "  ${myenv}: created from root .env"
}

echo "Syncing PUBLIC_HOSTNAME to sub-project .env files ..."
sync_subproject_env "${REPO_ROOT}/identity_service"
sync_subproject_env "${REPO_ROOT}/server"
sync_subproject_env "${REPO_ROOT}/openfga_visualized"
sync_myenv

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
# 0a. Verify the vendored Apache libcloud tree (./libcloud) is at the pinned
#     upstream release. libcloud.rest/Dockerfile does `COPY libcloud /libcloud`
#     and `pip install /libcloud`, so this tree IS the libcloud version the REST
#     API runs against. Fail fast if it has drifted off the pin so the REST API
#     image build stays reproducible. The local Nutanix driver additions (untracked
#     files + the Provider.NUTANIX registration in types.py/providers.py) sit on
#     top of the pin and are preserved across this check.
# ---------------------------------------------------------------------------
if [[ -d "${LIBCLOUD_DIR}/.git" ]]; then
  _libcloud_head=$(git -C "${LIBCLOUD_DIR}" rev-parse HEAD 2>/dev/null || true)
  _libcloud_desc=$(git -C "${LIBCLOUD_DIR}" describe --tags --always 2>/dev/null || true)
  if [[ "${_libcloud_head}" != "${LIBCLOUD_PIN_COMMIT}" ]]; then
    echo "ERROR: vendored libcloud is not at the pinned commit." >&2
    echo "  expected: ${LIBCLOUD_PIN_TAG} (${LIBCLOUD_PIN_COMMIT})" >&2
    echo "  actual:   ${_libcloud_desc:-unknown} (${_libcloud_head:-unknown})" >&2
    echo "  To fix: cd libcloud && git checkout ${LIBCLOUD_PIN_TAG} -- . && re-apply the Nutanix registration" >&2
    echo "  (see libcloud.rest/Dockerfile for the local Nutanix driver additions)." >&2
    exit 1
  fi
  echo "Vendored libcloud at pin ${LIBCLOUD_PIN_TAG} (${_libcloud_head:0:9})."
else
  echo "WARN: ${LIBCLOUD_DIR}/.git not found — cannot verify libcloud pin ${LIBCLOUD_PIN_TAG}." >&2
  echo "      Build will proceed but the libcloud version is unverified." >&2
fi

# ---------------------------------------------------------------------------
# 0b. Verify the `openfga-local:latest` image exists locally.  Image building
#     is handled by migrate2internal/backup-system.sh
#     on the internet-connected source machine; setup.sh only recreates containers
#     from pre-built images so it works in offline environments after restore.
# ---------------------------------------------------------------------------
if ! docker image inspect openfga-local:latest >/dev/null 2>&1; then
  echo "ERROR: openfga-local:latest image not found." >&2
  echo "  This image must be built before running setup.sh." >&2
  echo "  On an internet-connected machine, run:" >&2
  echo "    migrate2internal/backup-system.sh" >&2
  echo "  Then transfer ~/offline/ to this machine and run:" >&2
  echo "    migrate2internal/restore-system.sh" >&2
  exit 1
fi
echo "openfga-local:latest image found."

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

# dex_bootstrap.py may have regenerated dex/generated/dex.env. The identity-service
# container reads dex.env via env_file only at creation time — force-recreate it
# now so it picks up the current DEX_PORTAL_CLIENT_SECRET and other values.
if docker ps --filter name=^identity-service$ --format '{{.Names}}' 2>/dev/null | grep -qx identity-service; then
  echo "Recreating identity-service to pick up current dex.env ..."
  docker compose -f "${REPO_ROOT}/identity_service/docker-compose.yml" up -d --force-recreate identity-service
fi

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

# Verify the PostgreSQL password matches the data volume. POSTGRES_PASSWORD
# only takes effect on FIRST database init — if the volume was initialised
# with a different password, the env var is ignored and OpenFGA will fail to
# connect. Use local-socket (peer) auth to reset the password if needed.
echo "Verifying PostgreSQL password for openfga user ..."
if docker exec openfga-postgres psql -U openfga -d openfga -c "SELECT 1" >/dev/null 2>&1; then
  docker exec openfga-postgres psql -U openfga -d openfga \
    -c "ALTER USER openfga PASSWORD '${POSTGRES_PASSWORD}';" >/dev/null 2>&1 || true
  echo "  PostgreSQL password verified and synced."
else
  echo "  WARN: Cannot connect to PostgreSQL via local socket — OpenFGA may fail to authenticate."
fi

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

# dex_bootstrap.py may have regenerated dex.env again (e.g., to reconcile
# the portal client secret after Dex OIDC discovery). Force-recreate
# identity-service so its env_file values stay current.
if docker ps --filter name=^identity-service$ --format '{{.Names}}' 2>/dev/null | grep -qx identity-service; then
  echo "Recreating identity-service to pick up current dex.env ..."
  docker compose -f "${REPO_ROOT}/identity_service/docker-compose.yml" up -d --force-recreate identity-service
fi
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
# 7a. Seed per-tenant cloud credentials into Vault (superadmin-gated).
#     Reads credential values from the root .env (LIBCLOUD_AWS_KEY/SECRET,
#     LIBCLOUD_NTNX_USER/PASSWORD). When a value is empty, the tenant is
#     skipped with a clear warning so the operator knows to either set the
#     .env or run set_tenant_credentials.py manually later.
#     The set_tenant_credentials.py script does its own Dex login as the
#     tenant owner, so SUPERADMIN_JWT is not needed here — it uses the
#     owner's LLDAP password from dex/generated/dex.env.
# ---------------------------------------------------------------------------
echo "Seeding tenant cloud credentials into Vault ..."

# Ensure VAULT_ROOT_TOKEN is available for set_tenant_credentials.py (it reads
# vault/generated/vault.env directly, but also checks the env var).
set -a
# shellcheck source=/dev/null
source "${VAULT_ENV}"
set +a

_seed_tenant() {
  local tenant="$1" cloud="$2" owner_user="$3" owner_pw="$4"
  shift 4
  # Remaining args are the credential env vars to pass through (key=value pairs).
  echo "  Seeding tenant:${tenant} (cloud=${cloud}, owner=${owner_user}) ..."

  if [[ -z "${owner_pw}" ]]; then
    echo "    WARNING: no owner password for ${owner_user} — cannot seed tenant:${tenant}"
    echo "    Run manually: TENANT=${tenant} CLOUD=${cloud} LIBCLOUD_USER=${owner_user} LIBCLOUD_PASSWORD=... python3 ${SCRIPTS_REL}/set_tenant_credentials.py"
    return 0
  fi

  # Collect the credential env vars; bail if any required value is empty.
  local missing=0 extra_env=()
  for kv in "$@"; do
    local k="${kv%%=*}" v="${kv#*=}"
    extra_env+=("${k}=${v}")
    if [[ -z "${v}" ]]; then
      echo "    WARNING: ${k} is empty in .env"
      missing=1
    fi
  done
  if [[ "${missing}" -eq 1 ]]; then
    echo "    Skipping tenant:${tenant} — one or more credential values are empty."
    echo "    Run manually: TENANT=${tenant} CLOUD=${cloud} LIBCLOUD_USER=${owner_user} LIBCLOUD_PASSWORD=... python3 ${SCRIPTS_REL}/set_tenant_credentials.py"
    return 0
  fi

  TENANT="${tenant}" CLOUD="${cloud}" \
    LIBCLOUD_USER="${owner_user}" LIBCLOUD_PASSWORD="${owner_pw}" \
    "${extra_env[@]}" \
    python3 "${SCRIPTS_DIR}/set_tenant_credentials.py" && \
    echo "    tenant:${tenant} credentials seeded." || {
    echo "    ERROR: tenant:${tenant} credential seed failed (see above)."
    echo "    Run manually: TENANT=${tenant} CLOUD=${cloud} LIBCLOUD_USER=${owner_user} LIBCLOUD_PASSWORD=... python3 ${SCRIPTS_REL}/set_tenant_credentials.py"
  }
}

# AWS tenant — reads LIBCLOUD_AWS_KEY / LIBCLOUD_AWS_SECRET from root .env.
_seed_tenant aws aws aws-owner "${LIBCLOUD_PASSWORD_AWS_OWNER:-}" \
  "LIBCLOUD_AWS_KEY=${LIBCLOUD_AWS_KEY:-}" \
  "LIBCLOUD_AWS_SECRET=${LIBCLOUD_AWS_SECRET:-}"

# Nutanix tenant — reads LIBCLOUD_NTNX_USER / LIBCLOUD_NTNX_PASSWORD from root .env.
_seed_tenant nutanix nutanix ntnx-owner "${LIBCLOUD_PASSWORD_NTNX_OWNER:-}" \
  "LIBCLOUD_NTNX_USER=${LIBCLOUD_NTNX_USER:-}" \
  "LIBCLOUD_NTNX_PASSWORD=${LIBCLOUD_NTNX_PASSWORD:-}"

echo "Tenant credential seeding complete."

# ---------------------------------------------------------------------------
# 8. Restart REST API + visualizer so they pick up fresh OpenFGA state
#    (store / model IDs are now auto-discovered from the OpenFGA API at
#    runtime — no .env sync).  Containers are force-recreated to clear any
#    stale OPENFGA_STORE_ID / OPENFGA_MODEL_ID env vars from prior runs.
# ---------------------------------------------------------------------------
sync_libcloud_rest_fga() {
  # The REST API and identity-service now auto-discover FGA_STORE_ID /
  # FGA_MODEL_ID from the OpenFGA API at runtime (find store by name +
  # pick latest authorization model).  fga.env (written by
  # openfga_bootstrap.py) remains the authoritative source for host-side
  # shell scripts.  We still recreate the REST API container so it picks
  # up any cached state from a fresh bootstrap.
  echo "  OpenFGA store/model IDs are auto-discovered by the services — no .env sync needed"

  if docker compose -f "$REST_DIR/docker-compose.yml" ps --status running api 2>/dev/null | grep -q '\blibcloud-rest-api\b'; then
    echo "  Recreating libcloud-rest-api container to pick up fresh OpenFGA state"
    docker compose -f "$REST_DIR/docker-compose.yml" up -d --force-recreate api
  else
    echo "  libcloud-rest-api not running — start it with: docker compose -f $REST_DIR/docker-compose.yml up -d api"
  fi
}

echo "Restarting REST API for fresh OpenFGA state ..."
sync_libcloud_rest_fga

sync_visualizer_fga() {
  # The visualizer auto-discovers store / model IDs from OpenFGA at runtime.
  # --force-recreate ensures any stale OPENFGA_STORE_ID / OPENFGA_MODEL_ID
  # env vars from a previous run are cleared.  The image itself is built by
  # the backup scripts — setup.sh only recreates containers.
  local viz_compose="${REPO_ROOT}/openfga_visualized/docker-compose.yml"
  echo "  Visualizer auto-discovers store/model IDs — recreating container"
  if docker compose -f "$viz_compose" ps --status running 2>/dev/null | grep -q 'openfga-visualizer'; then
    echo "  Force-recreating openfga-visualizer for fresh OpenFGA state"
    docker compose -f "$viz_compose" up -d --force-recreate
  else
    echo "  openfga-visualizer not running — start it with: docker compose -f ${viz_compose} up -d"
  fi
}

echo "Restarting visualizer for fresh OpenFGA state ..."
sync_visualizer_fga

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
    docker compose -f "$REST_DIR/docker-compose.yml" up -d --force-recreate api
  else
    echo "  libcloud-rest-api not running — start it with: docker compose -f $REST_DIR/docker-compose.yml up -d api"
  fi
}

echo "Syncing Vault credentials -> libcloud.rest ..."
sync_libcloud_rest_vault

# ---------------------------------------------------------------------------
# 9. Recreate the portal container so it picks up any config changes.
#    The portal image is built by the backup scripts — setup.sh only
#    recreates containers from pre-built images.
#    (REACT_APP_* build args are baked at build time by backup scripts.)
# ---------------------------------------------------------------------------
echo "Recreating portal container ..."
docker compose -f "${REPO_ROOT}/server/docker-compose.yml" up -d --force-recreate portal

# ---------------------------------------------------------------------------
# 10. Host-side Python venv for libcloud.rest (best-effort, non-fatal).
#     test_script/test_all_rest_api_authenticated.py imports the FastAPI app
#     in-process, so the auth-gate audit needs the app's deps + httpx
#     (fastapi.testclient) + the vendored libcloud on the HOST — not just
#     inside the libcloud-rest-api container. The venv is normally PREBUILT on
#     the source and shipped by backup/restore as libcloud-rest-venv.tgz; this
#     step only (re)builds libcloud.rest/.venv as a best-effort fallback (e.g.
#     when the tarball was absent or its Python version mismatched this host).
#     On an air-gapped host with no network / pip mirror the step warns and
#     continues — system_validate.sh's authz section then skips the audit.
# ---------------------------------------------------------------------------
bootstrap_rest_venv() {
  local venv="${REST_DIR}/.venv"
  local vpython="${venv}/bin/python"
  if [[ -x "${vpython}" ]] && "${vpython}" -c 'import fastapi, httpx, libcloud' >/dev/null 2>&1; then
    echo "libcloud.rest host venv already present."
    return 0
  fi
  echo "Creating libcloud.rest host venv (for auth-gate audit) ..."
  if ! python3 -m venv "${venv}"; then
    echo "WARN: could not create ${venv} (is python3-venv installed?) — authz audit will be skipped." >&2
    return 0
  fi
  if ! "${vpython}" -m pip install -r "${REST_DIR}/requirements.txt" "httpx" "${LIBCLOUD_DIR}"; then
    echo "WARN: pip install into ${venv} failed (no network / pip mirror?) — authz audit will be skipped." >&2
    return 0
  fi
  echo "libcloud.rest host venv ready."
}

echo "Preparing libcloud.rest host venv ..."
bootstrap_rest_venv

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
echo "Cloud backend credentials are seeded into Vault from the root .env"
echo "(LIBCLOUD_AWS_KEY/SECRET, LIBCLOUD_NTNX_USER/PASSWORD). If a value is"
echo "empty, that tenant is skipped — the owner can seed it later manually:"
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
