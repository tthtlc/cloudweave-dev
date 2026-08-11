#!/usr/bin/env bash
# ============================================================================
# restore-docker-images.sh — Distro-agnostic Docker-stack restore (images-first)
#
# Simplified version of restore-system.sh.  Assumes Docker is already installed
# on the destination machine — no OS packages are installed.  Works on any Linux
# distribution with Docker (Ubuntu, Rocky Linux, AlmaLinux, etc.).
#
# PREREQUISITE: The ~/offline/ directory tree from backup-docker-images.sh must
# be present on this machine (at /home/$USER/offline/).
#
# Usage:
#   chmod +x restore-docker-images.sh
#   DRY_RUN=1 ./restore-docker-images.sh    # Show what would happen, don't execute
#   ./restore-docker-images.sh              # Run the actual restore
# ============================================================================

set -euo pipefail

OFFLINE_DIR="${OFFLINE_DIR:-$HOME/offline}"
BACKUP_DIR="$OFFLINE_DIR/backup"
IMAGES_DIR="$BACKUP_DIR/images"
PROJECT_DIR="$BACKUP_DIR/project"
VOLUMES_DIR="$BACKUP_DIR/volumes"
BINDS_DIR="$BACKUP_DIR/binds"

# The original project root on the source machine.
# The backup tarball has paths like: libcloud_nutanix/.env
# so we extract with -C /home/$USER to get /home/$USER/libcloud_nutanix/.env
ORIG_PROJECT_ROOT="/home/${USER}/libcloud_nutanix"
PROJECT_NAME="libcloud_nutanix"
PARENT_DIR="/home/${USER}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DRY_RUN="${DRY_RUN:-0}"

log()  { echo -e "${GREEN}[RESTORE]${NC} $(date '+%H:%M:%S') $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*" >&2; }
info() { echo -e "${BLUE}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }

run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        info "[DRY-RUN] $*"
    else
        "$@"
    fi
}

run_sudo() {
    if [[ "$DRY_RUN" == "1" ]]; then
        info "[DRY-RUN] sudo $*"
    else
        sudo "$@"
    fi
}

# ------------------------------------------------------------------
# 0. Preflight
# ------------------------------------------------------------------
log "=== Preflight checks ==="

if [[ "$DRY_RUN" == "1" ]]; then
    warn "DRY_RUN=1 — commands will be shown but not executed"
fi

if [[ ! -d "$OFFLINE_DIR" ]]; then
    err "Offline directory not found: $OFFLINE_DIR"
    err "Transfer the source machine's ~/offline/ here first."
    exit 1
fi

if [[ ! -f "$BACKUP_DIR/MANIFEST.txt" ]]; then
    err "Manifest not found: $BACKUP_DIR/MANIFEST.txt"
    err "The backup appears incomplete. Re-run backup-docker-images.sh on the source."
    exit 1
fi

log "Manifest found. Source system details:"
head -10 "$BACKUP_DIR/MANIFEST.txt" | sed 's/^/  /'

if ! command -v docker &>/dev/null; then
    err "Docker is not installed. Please install Docker first, then re-run."
    exit 1
fi

DOCKER_VERSION=$(docker --version 2>/dev/null || echo 'unknown')
COMPOSE_VERSION=$(docker compose version 2>/dev/null || echo 'unknown')
log "Docker:  $DOCKER_VERSION"
log "Compose: $COMPOSE_VERSION"

# Ensure Docker daemon is running
if ! docker info &>/dev/null; then
    log "Docker daemon not running — attempting to start..."
    if run_sudo systemctl enable --now docker 2>/dev/null; then
        log "Docker daemon started."
    else
        err "Failed to start Docker daemon. Start it manually and re-run."
        exit 1
    fi
fi

# ------------------------------------------------------------------
# 1. Load Docker images
# ------------------------------------------------------------------
log "=== Step 1: Load Docker images ==="

if [[ -f "$IMAGES_DIR/stack-images.tar" ]]; then
    log "Loading images from stack-images.tar ($(du -h "$IMAGES_DIR/stack-images.tar" | cut -f1))..."
    run docker load -i "$IMAGES_DIR/stack-images.tar"
    log "Images loaded successfully"
    docker images --format '  {{.Repository}}:{{.Tag}}' | sort
else
    err "Images tarball not found: $IMAGES_DIR/stack-images.tar"
    exit 1
fi

# ------------------------------------------------------------------
# 2. Restore project files
# ------------------------------------------------------------------
log "=== Step 2: Restore project files ==="

PROJECT_TARBALL="$PROJECT_DIR/project-files.tgz"
if [[ ! -f "$PROJECT_TARBALL" ]]; then
    err "Project tarball not found: $PROJECT_TARBALL"
    exit 1
fi

# The tarball has paths like "libcloud_nutanix/.env" because the backup
# did:  tar -czf ... -C /home/$USER libcloud_nutanix
# So we extract with -C PARENT_DIR so files land at:
#   /home/$USER/libcloud_nutanix/.env
#   /home/$USER/libcloud_nutanix/dex/docker-compose.yml
#   ...etc...

# Clean up stale extraction from a previous failed restore (old script used -C /)
if [[ -d "/${PROJECT_NAME}" ]] && [[ "/${PROJECT_NAME}" != "$ORIG_PROJECT_ROOT" ]]; then
    warn "Found stale project files at /${PROJECT_NAME} (from a previous restore bug)."
    warn "Removing /${PROJECT_NAME} before extracting to the correct path..."
    run_sudo rm -rf "/${PROJECT_NAME}"
fi

log "Extracting project files to $PARENT_DIR (restores to $ORIG_PROJECT_ROOT)..."
run_sudo tar -xzf "$PROJECT_TARBALL" -C "$PARENT_DIR"

# Verify key files landed correctly
log "Verifying extracted files..."
FAIL=0
for f in ".env" \
         "dex/docker-compose.yml" \
         "lldap/docker-compose.yml" \
         "openfga_postgres/docker-compose.yml" \
         "server/docker-compose.yml" \
         "vault/docker-compose.yml" \
         "identity_service/docker-compose.yml" \
         "libcloud.rest/docker-compose.yml" \
         "stoplight_mock/docker-compose.yml" \
         "openfga_visualized/docker-compose.yml"; do
    if [[ -f "$ORIG_PROJECT_ROOT/$f" ]]; then
        log "  OK: $f"
    else
        warn "  MISSING: $ORIG_PROJECT_ROOT/$f"
        FAIL=1
    fi
done

if [[ "$FAIL" == "1" ]]; then
    warn "Some expected files are missing from $ORIG_PROJECT_ROOT."
    warn "Check that the backup tarball was complete (see backup MANIFEST.txt)."
fi

# Fix ownership
log "Setting ownership on project files..."
run_sudo chown -R "$USER:$USER" "$ORIG_PROJECT_ROOT" 2>/dev/null || true

# ------------------------------------------------------------------
# 2b. Sanitize public hostname references for internal/no-egress environment
# ------------------------------------------------------------------
log "=== Step 2b: Sanitize public hostname references ==="

PUBLIC_DOMAINS=(
    "login.quest4science.xyz"
    "login.cloudweave.xyz"
)

CONFIG_EXTS="*.env *.yaml *.yml *.json *.hcl *.py *.toml *.cfg *.conf"

for domain in "${PUBLIC_DOMAINS[@]}"; do
    COUNT=$(find "$ORIG_PROJECT_ROOT" -type f \( -false $(for ext in $CONFIG_EXTS; do echo "-o -name $ext"; done) \) \
        ! -path "*/node_modules/*" ! -path "*/.git/*" \
        ! -path "*/migrate2internal/*" ! -path "*/.claude/*" \
        -exec grep -lF "$domain" {} \; 2>/dev/null | wc -l)

    if [[ "$COUNT" -gt 0 ]]; then
        warn "Found $COUNT file(s) referencing $domain — sanitizing..."

        # Fix OIDC issuer URLs (must use Docker network hostname, not localhost)
        find "$ORIG_PROJECT_ROOT" -type f \( -false $(for ext in $CONFIG_EXTS; do echo "-o -name $ext"; done) \) \
            ! -path "*/node_modules/*" ! -path "*/.git/*" \
            ! -path "*/migrate2internal/*" ! -path "*/.claude/*" \
            -exec sed -i "s|http://${domain}:5556/dex|http://dex:5556/dex|g" {} + 2>/dev/null

        # Replace remaining occurrences with localhost
        find "$ORIG_PROJECT_ROOT" -type f \( -false $(for ext in $CONFIG_EXTS; do echo "-o -name $ext"; done) \) \
            ! -path "*/node_modules/*" ! -path "*/.git/*" \
            ! -path "*/migrate2internal/*" ! -path "*/.claude/*" \
            -exec sed -i "s|${domain}|localhost|g" {} + 2>/dev/null

        # Verify no references remain
        LEFTOVER=$(find "$ORIG_PROJECT_ROOT" -type f \( -false $(for ext in $CONFIG_EXTS; do echo "-o -name $ext"; done) \) \
            ! -path "*/node_modules/*" ! -path "*/.git/*" \
            ! -path "*/migrate2internal/*" ! -path "*/.claude/*" \
            -exec grep -lF "$domain" {} \; 2>/dev/null | wc -l)
        if [[ "$LEFTOVER" -gt 0 ]]; then
            warn "$LEFTOVER file(s) still reference $domain after sanitization (check manually)"
        else
            log "All $domain references sanitized ($COUNT file(s) fixed)"
        fi
    else
        log "No $domain references found — already clean"
    fi
done

# ------------------------------------------------------------------
# 3. Restore SSH configuration
# ------------------------------------------------------------------
log "=== Step 3: Restore SSH configuration ==="

if [[ -f "$BACKUP_DIR/libcloud-private-key.pem" ]]; then
    mkdir -p "$HOME/.ssh"
    cp "$BACKUP_DIR/libcloud-private-key.pem" "$HOME/.ssh/libcloud-private-key.pem"
    chmod 600 "$HOME/.ssh/libcloud-private-key.pem"
    log "SSH key restored: ~/.ssh/libcloud-private-key.pem"
fi

if [[ -f "$BACKUP_DIR/ssh-config" ]]; then
    if [[ ! -f "$HOME/.ssh/config" ]]; then
        cp "$BACKUP_DIR/ssh-config" "$HOME/.ssh/config"
        chmod 600 "$HOME/.ssh/config"
        log "SSH config restored: ~/.ssh/config"
    else
        warn "~/.ssh/config already exists — saved as ~/.ssh/config.from-backup"
        cp "$BACKUP_DIR/ssh-config" "$HOME/.ssh/config.from-backup"
    fi
fi

# ------------------------------------------------------------------
# 4. Recreate Docker networks
# ------------------------------------------------------------------
log "=== Step 4: Recreate Docker networks ==="

EXTERNAL_NETWORKS=(
    "libcloud_net"
)
for net in "${EXTERNAL_NETWORKS[@]}"; do
    if docker network ls --format '{{.Name}}' | grep -qxF "$net"; then
        info "Network $net already exists — skipping"
    else
        log "Creating external network: $net"
        run docker network create --driver bridge "$net"
    fi
done

# ------------------------------------------------------------------
# 5. Recreate named volumes and restore data
# ------------------------------------------------------------------
log "=== Step 5: Restore named volumes ==="

VOLUME_NAMES_FILE="$BACKUP_DIR/volume-names.txt"
if [[ ! -f "$VOLUME_NAMES_FILE" ]]; then
    warn "volume-names.txt not found — skipping volume restore"
else
    VOLUMES_RESTORED=0
    while read v; do
        [[ -z "$v" ]] && continue
        # Create volume if needed
        if docker volume ls --format '{{.Name}}' | grep -qxF "$v"; then
            info "Volume $v already exists"
        else
            log "Creating volume: $v"
            run docker volume create "$v"
        fi

        # Restore data if archive exists
        VOL_ARCHIVE="$VOLUMES_DIR/${v}.tgz"
        VOL_PATH=$(docker volume inspect -f '{{.Mountpoint}}' "$v" 2>/dev/null) || true
        if [[ -f "$VOL_ARCHIVE" ]]; then
            if [[ -n "$VOL_PATH" && -d "$VOL_PATH" ]]; then
                log "Restoring volume data: $v"
                run_sudo tar --numeric-owner -xzf "$VOL_ARCHIVE" \
                    -C "$VOL_PATH"
                VOLUMES_RESTORED=$((VOLUMES_RESTORED + 1))
            else
                warn "Volume mountpoint not found: ${VOL_PATH:-"<inspect failed>"}"
                warn "  Volume $v was created but data could not be restored"
            fi
        else
            warn "Volume archive not found: $VOL_ARCHIVE"
            warn "  Volume $v was created but has no data (will be populated by bootstrap)"
        fi
    done < "$VOLUME_NAMES_FILE"
    log "Restored data for $VOLUMES_RESTORED volume(s)"
fi

# ------------------------------------------------------------------
# 6. Restore bind-mount contents
# ------------------------------------------------------------------
log "=== Step 6: Restore bind mounts ==="

BIND_MAP="$BINDS_DIR/bind-map.txt"
if [[ ! -f "$BIND_MAP" ]]; then
    warn "bind-map.txt not found — skipping bind-mount restore"
else
    BINDS_RESTORED=0
    while IFS='|' read idx src; do
        [[ -z "$src" ]] && continue
        safe_name=$(printf "%04d" "$idx")-$(echo "$src" | tr '/' '_')
        BIND_ARCHIVE="$BINDS_DIR/${safe_name}.tgz"

        if [[ -f "$BIND_ARCHIVE" ]]; then
            run_sudo mkdir -p "$(dirname "$src")"
            log "Restoring bind mount: $src"
            run_sudo tar --numeric-owner -xzf "$BIND_ARCHIVE" \
                -C "$(dirname "$src")"
            BINDS_RESTORED=$((BINDS_RESTORED + 1))
        else
            warn "Bind archive not found: $BIND_ARCHIVE"
        fi
    done < <(sort -t'|' -k1 -n "$BIND_MAP" 2>/dev/null)
    log "Restored $BINDS_RESTORED bind mount(s)"
fi

# ------------------------------------------------------------------
# 7. Verify .env and critical configs
# ------------------------------------------------------------------
log "=== Step 7: Verify critical files ==="

CRITICAL_OK=0
CRITICAL_FAIL=0

check_file() {
    if [[ -f "$1" ]]; then
        log "  OK: $1"
        CRITICAL_OK=$((CRITICAL_OK + 1))
    else
        warn "  MISSING: $1"
        CRITICAL_FAIL=$((CRITICAL_FAIL + 1))
    fi
}

check_file "$ORIG_PROJECT_ROOT/.env"
check_file "$ORIG_PROJECT_ROOT/dex/config.yaml"
check_file "$ORIG_PROJECT_ROOT/vault/config.hcl"
check_file "$ORIG_PROJECT_ROOT/openfga_postgres/generated/postgres.env"
check_file "$ORIG_PROJECT_ROOT/openfga_postgres/generated/fga.env"
check_file "$ORIG_PROJECT_ROOT/openfga_postgres/generated/tokens"

if [[ "$CRITICAL_FAIL" -gt 0 ]]; then
    warn "$CRITICAL_FAIL critical file(s) missing. The stack may not start."
    warn "Check that backup-docker-images.sh completed all steps successfully."
fi

# ------------------------------------------------------------------
# 7b. Secret Reconciliation — ensure dex config and env agree
# ------------------------------------------------------------------
log "=== Step 7b: Secret Reconciliation ==="

DEX_ENV_FILE="$ORIG_PROJECT_ROOT/dex/generated/dex.env"
DEX_CONFIG_FILE="$ORIG_PROJECT_ROOT/dex/config.yaml"

reconcile_secret() {
    local env_key="$1"
    local client_id="$2"
    local label="$3"

    if [[ ! -f "$DEX_ENV_FILE" || ! -f "$DEX_CONFIG_FILE" ]]; then
        return 0
    fi

    local env_secret config_secret
    env_secret=$(grep -E "^${env_key}=" "$DEX_ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
    config_secret=$(grep -A3 "id: ${client_id}" "$DEX_CONFIG_FILE" 2>/dev/null \
        | grep -E '^\s+secret:' | sed 's/.*secret:\s*//' || true)

    if [[ -z "$env_secret" || -z "$config_secret" ]]; then
        warn "  Cannot extract ${label} secret (env='${env_secret:-<missing>}' config='${config_secret:-<missing>}')"
        return 0
    fi

    if [[ "$env_secret" != "$config_secret" ]]; then
        warn "  MISMATCH on ${label}: dex.env ≠ config.yaml — syncing config.yaml ← dex.env"
        sed -i "/id: ${client_id}/,/secret:/{s/secret:.*/secret: ${env_secret}/}" "$DEX_CONFIG_FILE"
        log "  ${label}: reconciled (config.yaml updated)."
    else
        log "  ${label}: OK (secrets match)"
    fi
}

reconcile_secret "DEX_PORTAL_CLIENT_SECRET"    "libcloud-portal" "portal-client"
reconcile_secret "LIBCLOUD_OIDC_CLIENT_SECRET" "libcloud-rest"   "libcloud-rest-client"

# ------------------------------------------------------------------
# 8. Start the stack — dependency order
# ------------------------------------------------------------------
log "=== Step 8: Start the stack ==="

# Helper: check that every image referenced in a compose file exists locally
compose_images_available() {
    local compose_file="$1"
    shift
    local extra_images=("$@")

    local missing=0
    local -a imgs=()

    if [[ -f "$compose_file" ]]; then
        while IFS= read -r img; do
            [[ -z "$img" ]] && continue
            [[ "$img" == "&"* ]] && continue
            [[ "$img" == *'$'* ]] && continue
            imgs+=("$img")
        done < <(grep -h '^\s*image:' "$compose_file" 2>/dev/null \
            | grep -v '^\s*#' \
            | sed 's/.*image:\s*//; s/"//g' \
            | sort -u)
    fi

    for extra in "${extra_images[@]}"; do
        [[ -z "$extra" ]] && continue
        imgs+=("$extra")
    done

    for img in "${imgs[@]}"; do
        if ! docker image inspect "$img" &>/dev/null; then
            warn "  Missing image: $img"
            missing=$((missing + 1))
        fi
    done

    if [[ "$missing" -gt 0 ]]; then
        warn "  $missing image(s) not available locally — skipping this project"
        warn "  (Docker would try to pull from the internet and hang indefinitely)"
        return 1
    fi
    return 0
}

COMPOSE_DIRS=(
    "$ORIG_PROJECT_ROOT/lldap"
    "$ORIG_PROJECT_ROOT/dex"
    "$ORIG_PROJECT_ROOT/openfga_postgres"
    "$ORIG_PROJECT_ROOT/vault"
    "$ORIG_PROJECT_ROOT/stoplight_mock"
    "$ORIG_PROJECT_ROOT/libcloud.rest"
    "$ORIG_PROJECT_ROOT/identity_service"
    "$ORIG_PROJECT_ROOT/server"
    "$ORIG_PROJECT_ROOT/openfga_visualized"
)

SWAGGER_COMPOSE="$ORIG_PROJECT_ROOT/libcloud.rest/docker-compose.swagger.yml"

STARTED=0
SKIPPED=0
FAILED=0

# Source generated/postgres.env before starting openfga_postgres
PG_ENV_FILE="$ORIG_PROJECT_ROOT/openfga_postgres/generated/postgres.env"
if [[ -f "$PG_ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$PG_ENV_FILE"
    set +a
    log "Sourced Postgres credentials from $PG_ENV_FILE"
else
    warn "$PG_ENV_FILE not found — OpenFGA may fail to connect to Postgres"
fi

for dir in "${COMPOSE_DIRS[@]}"; do
    COMPOSE_FILE="$dir/docker-compose.yml"
    if [[ -f "$COMPOSE_FILE" ]]; then
        # Pre-cleanup: remove stale compose networks without correct labels
        if [[ "$dir" == *"stoplight_mock"* ]]; then
            STALE_NET="stoplight_mock_default"
            if docker network inspect "$STALE_NET" &>/dev/null; then
                LABEL=$(docker network inspect "$STALE_NET" --format '{{index .Labels "com.docker.compose.network"}}' 2>/dev/null || true)
                if [[ "$LABEL" == "" ]]; then
                    warn "Removing stale network $STALE_NET (missing compose labels)"
                    run docker network rm "$STALE_NET" || true
                fi
            fi
        fi

        log "Starting: $dir"
        if compose_images_available "$COMPOSE_FILE" && run docker compose -f "$COMPOSE_FILE" up -d; then
            STARTED=$((STARTED + 1))
            sleep 2

            # --- Post-start self-healing hooks ---

            # openfga_postgres: sync PostgreSQL password with restored data volume
            if [[ "$dir" == *"openfga_postgres"* ]]; then
                log "  Verifying PostgreSQL password for openfga user ..."
                sleep 3
                if docker exec openfga-postgres psql -U openfga -d openfga -c "SELECT 1" >/dev/null 2>&1; then
                    docker exec openfga-postgres psql -U openfga -d openfga \
                        -c "ALTER USER openfga PASSWORD '${POSTGRES_PASSWORD}';" >/dev/null 2>&1 || true
                    log "  PostgreSQL password verified and synced."
                else
                    warn "  Cannot connect to PostgreSQL via local socket — OpenFGA may fail."
                fi
                # Wait for OpenFGA to become healthy
                log "  Waiting for OpenFGA health check ..."
                for _i in $(seq 1 60); do
                    if docker inspect --format '{{ .State.Health.Status }}' openfga 2>/dev/null | grep -qx healthy; then break; fi
                    sleep 1
                done
            fi

            # identity_service: force-recreate to pick up current dex.env values
            if [[ "$dir" == *"identity_service"* ]]; then
                log "  Force-recreating identity-service to pick up current dex.env ..."
                run docker compose -f "$COMPOSE_FILE" up -d --force-recreate identity-service
            fi
        else
            warn "Failed to start: $dir"
            FAILED=$((FAILED + 1))
        fi
    else
        info "No compose file: $dir — skipping"
        SKIPPED=$((SKIPPED + 1))
    fi
done

# Start additional compose projects (Swagger UI)
log "Starting additional compose projects..."

if [[ -f "$SWAGGER_COMPOSE" ]]; then
    log "Starting: swagger-ui ($SWAGGER_COMPOSE)"
    if compose_images_available "$SWAGGER_COMPOSE" && run docker compose -f "$SWAGGER_COMPOSE" up -d; then
        STARTED=$((STARTED + 1))
        sleep 1
    else
        warn "Failed to start: swagger-ui (image missing or compose error)"
        FAILED=$((FAILED + 1))
    fi
else
    warn "Swagger compose not found: $SWAGGER_COMPOSE"
    SKIPPED=$((SKIPPED + 1))
fi

# ------------------------------------------------------------------
# 9. Verify
# ------------------------------------------------------------------
log "=== Step 9: Verify ==="

echo ""
info "Docker containers:"
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null || true

echo ""
info "Docker volumes:"
docker volume ls 2>/dev/null || true

# ------------------------------------------------------------------
# 10. Targeted credential-integrity checks
# ------------------------------------------------------------------
log "=== Step 10: Credential integrity checks ==="

CRED_OK=0
CRED_FAIL=0

# 10a. DEX_PORTAL_CLIENT_SECRET in identity-service container vs config.yaml
if docker ps --filter name=^identity-service$ --format '{{.Names}}' 2>/dev/null | grep -qx identity-service; then
    CONTAINER_SECRET=$(docker exec identity-service printenv DEX_PORTAL_CLIENT_SECRET 2>/dev/null || true)
    DEX_ENV_SECRET=$(grep -E '^DEX_PORTAL_CLIENT_SECRET=' "$DEX_ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
    if [[ -n "$CONTAINER_SECRET" && -n "$DEX_ENV_SECRET" ]]; then
        if [[ "$CONTAINER_SECRET" == "$DEX_ENV_SECRET" ]]; then
            log "  PASS: identity-service DEX_PORTAL_CLIENT_SECRET matches dex.env"
            CRED_OK=$((CRED_OK + 1))
        else
            warn "  FAIL: identity-service DEX_PORTAL_CLIENT_SECRET ($(printf '%.12s' "$CONTAINER_SECRET")...) != dex.env ($(printf '%.12s' "$DEX_ENV_SECRET")...)"
            CRED_FAIL=$((CRED_FAIL + 1))
        fi
    fi
else
    warn "  SKIP: identity-service container not running"
fi

# 10b. OpenFGA container health
OPENFGA_STATUS=$(docker inspect --format '{{ .State.Health.Status }}' openfga 2>/dev/null || echo "not-found")
if [[ "$OPENFGA_STATUS" == "healthy" ]]; then
    log "  PASS: OpenFGA container is healthy"
    CRED_OK=$((CRED_OK + 1))
else
    warn "  FAIL: OpenFGA status is '$OPENFGA_STATUS' (expected 'healthy')"
    CRED_FAIL=$((CRED_FAIL + 1))
fi

# 10c. No PostgreSQL auth errors in recent logs
PG_AUTH_ERRORS=$(docker logs openfga-postgres --since 5m 2>&1 | grep -c "password authentication failed" || true)
if [[ "$PG_AUTH_ERRORS" -eq 0 ]]; then
    log "  PASS: No PostgreSQL auth failures in recent logs"
    CRED_OK=$((CRED_OK + 1))
else
    warn "  FAIL: $PG_AUTH_ERRORS PostgreSQL auth failure(s) in recent logs"
    CRED_FAIL=$((CRED_FAIL + 1))
fi

# 10d. No Dex client_secret errors in recent logs
DEX_SECRET_ERRORS=$(docker logs dex --since 5m 2>&1 | grep -c "invalid client_secret" || true)
if [[ "$DEX_SECRET_ERRORS" -eq 0 ]]; then
    log "  PASS: No Dex client_secret errors in recent logs"
    CRED_OK=$((CRED_OK + 1))
else
    warn "  FAIL: $DEX_SECRET_ERRORS Dex client_secret error(s) in recent logs"
    CRED_FAIL=$((CRED_FAIL + 1))
fi

echo ""
if [[ "$CRED_FAIL" -eq 0 ]]; then
    log "Credential integrity: ALL $CRED_OK checks passed."
else
    warn "Credential integrity: $CRED_OK passed, $CRED_FAIL FAILED."
    warn "Login may fail until these are resolved."
    warn "To fix manually:"
    warn "  1) Recreate identity-service: docker compose -f $ORIG_PROJECT_ROOT/identity_service/docker-compose.yml up -d --force-recreate"
    warn "  2) Reset postgres password: docker exec openfga-postgres psql -U openfga -d openfga -c \"ALTER USER openfga PASSWORD '\$POSTGRES_PASSWORD';\""
fi

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
echo ""
log "=== Restore complete ==="
echo ""
echo "Started:  $STARTED compose projects"
echo "Skipped:  $SKIPPED (missing compose file)"
echo "Failed:   $FAILED (compose up error)"
echo ""
echo "Health-check commands:"
echo "  docker compose -f $ORIG_PROJECT_ROOT/openfga_postgres/docker-compose.yml ps"
echo "  curl -s http://localhost:8766/health           # identity service"
echo "  curl -s http://localhost:8765/health           # libcloud REST API"
echo "  curl -s http://localhost:3000                  # portal"
echo "  curl -s http://localhost:8081/healthz          # OpenFGA"
echo "  curl -s http://localhost:8200/v1/sys/health    # Vault"
echo "  curl -s http://localhost:5556/dex/healthz      # Dex"
echo "  curl -s http://localhost:9898                  # Swagger UI"
