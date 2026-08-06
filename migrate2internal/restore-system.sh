#!/usr/bin/env bash
# ============================================================================
# restore-system.sh — Full-system restore of the libcloud-nutanix Docker stack
#
# Run this on the DESTINATION (internal) machine after transferring the
# ~/offline/ directory from the source. It installs Docker, loads images,
# restores volumes, bind mounts, and project files, then starts the stack.
#
# PREREQUISITE: The ~/offline/ directory tree from backup-system.sh must be
# present on this machine (at /home/ubuntu/offline/).
#
# Usage:
#   chmod +x restore-system.sh
#   DRY_RUN=1 ./restore-system.sh    # Show what would happen, don't execute
#   ./restore-system.sh              # Run the actual restore
# ============================================================================

set -euo pipefail

OFFLINE_DIR="$HOME/offline"
DEB_DIR="$OFFLINE_DIR/docker-debs"
BACKUP_DIR="$OFFLINE_DIR/backup"
IMAGES_DIR="$BACKUP_DIR/images"
PROJECT_DIR="$BACKUP_DIR/project"
VOLUMES_DIR="$BACKUP_DIR/volumes"
BINDS_DIR="$BACKUP_DIR/binds"

# The original project root on the source machine.
# The backup tarball has paths like: libcloud_nutanix/.env
# so we extract with -C /home/ubuntu to get /home/ubuntu/libcloud_nutanix/.env
ORIG_PROJECT_ROOT="/home/ubuntu/libcloud_nutanix"
PROJECT_NAME="libcloud_nutanix"
PARENT_DIR="/home/ubuntu"

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
    err "Transfer the source machine's ~/offline/ here first (use transfer-backup.sh from source)."
    exit 1
fi

if [[ ! -f "$BACKUP_DIR/MANIFEST.txt" ]]; then
    err "Manifest not found: $BACKUP_DIR/MANIFEST.txt"
    err "The backup appears incomplete. Re-run backup-system.sh on the source."
    exit 1
fi

log "Manifest found. Source system details:"
head -10 "$BACKUP_DIR/MANIFEST.txt" | sed 's/^/  /'

if command -v docker &>/dev/null; then
    warn "Docker is already installed: $(docker --version 2>/dev/null || echo 'unknown')"
    warn "If this is a distro-packaged Docker, it will be replaced with the offline bundle."
    warn "Press Ctrl-C within 10s to abort, or wait to continue..."
    sleep 10
else
    info "Docker not installed — will install from offline .deb bundle"
fi

# ------------------------------------------------------------------
# 1. Remove conflicting distro Docker packages
# ------------------------------------------------------------------
log "=== Step 1: Remove conflicting distro packages (if any) ==="

run_sudo apt remove -y docker.io docker-compose docker-compose-v2 docker-doc \
    docker-buildx podman-docker containerd runc 2>/dev/null || true

# ------------------------------------------------------------------
# 2. Install Docker + Compose from offline .deb bundle
# ------------------------------------------------------------------
log "=== Step 2: Install Docker from offline .deb bundle ==="

if [[ ! -d "$DEB_DIR" ]] || ! ls "$DEB_DIR"/*.deb &>/dev/null; then
    err "No .deb packages found in $DEB_DIR"
    err "Make sure the docker-debs directory was transferred from the source."
    exit 1
fi

log "Verifying .deb checksums..."
if [[ -f "$DEB_DIR/SHA256SUMS" ]]; then
    (cd "$DEB_DIR" && sha256sum -c SHA256SUMS) || warn "Some .deb checksums failed — continuing anyway"
else
    warn "No SHA256SUMS for .deb packages — skipping verification"
fi

log "Installing Docker packages ($(ls "$DEB_DIR"/*.deb 2>/dev/null | wc -l) files)..."

# Use dpkg for the primary install — it does NOT contact remote repositories,
# so it works in fully-offline environments.  apt install on local .deb files
# still tries to resolve dependencies from remote repos (e.g., pigz from
# archive.ubuntu.com) and will fail when the machine has no internet access.
if run_sudo dpkg -i "$DEB_DIR"/*.deb 2>&1; then
    log "All packages installed successfully via dpkg"
else
    warn "dpkg reported issues (likely missing dependencies)"
    warn "Attempting to configure any partially-installed packages..."
    run_sudo dpkg --configure -a 2>/dev/null || true

    # If we ARE online, fix remaining dependency issues
    if run_sudo apt-get install -f -y --no-install-recommends 2>/dev/null; then
        log "Dependencies fixed via apt-get"
    else
        warn "Could not auto-resolve dependencies (expected if offline)"
        warn "If pigz or other packages are missing, install them manually later"
    fi
fi

log "Enabling and starting Docker..."
run_sudo systemctl enable --now docker

log "Docker version: $(docker --version 2>/dev/null || echo 'N/A')"
log "Compose version: $(docker compose version 2>/dev/null || echo 'N/A')"

# ------------------------------------------------------------------
# 3. Load Docker images
# ------------------------------------------------------------------
log "=== Step 3: Load Docker images ==="

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
# 4. Restore project files
# ------------------------------------------------------------------
log "=== Step 4: Restore project files ==="

PROJECT_TARBALL="$PROJECT_DIR/project-files.tgz"
if [[ ! -f "$PROJECT_TARBALL" ]]; then
    err "Project tarball not found: $PROJECT_TARBALL"
    exit 1
fi

# The tarball has paths like "libcloud_nutanix/.env" because the backup
# did:  tar -czf ... -C /home/ubuntu libcloud_nutanix
# So we extract with -C /home/ubuntu (PARENT_DIR) so files land at:
#   /home/ubuntu/libcloud_nutanix/.env
#   /home/ubuntu/libcloud_nutanix/dex/docker-compose.yml
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
# 4b. Sanitize public hostname references for internal/no-egress environment
# ------------------------------------------------------------------
# The backup archive may contain config files from a source machine that was
# deployed with a public hostname (e.g., login.quest4science.xyz). In the
# internal/no-egress environment, Docker containers cannot resolve public DNS
# and must use Docker network hostnames (dex, vault, postgres, …) for
# inter-container communication and localhost for host-accessible services.
#
# This step replaces any stale public hostname references with their internal
# equivalents. The OIDC issuer URL is the most critical — OpenFGA fetches the
# OIDC discovery document on startup, and if it points to an unresolvable
# public URL, OpenFGA panics and the health check never passes.
log "=== Step 4b: Sanitize public hostname references ==="

# Known public hostnames that must be replaced with internal equivalents.
# Add new public domains here as the project migrates across hostnames.
PUBLIC_DOMAINS=(
    "login.quest4science.xyz"
    "login.cloudweave.xyz"
)

CONFIG_EXTS="*.env *.yaml *.yml *.json *.hcl *.py *.toml *.cfg *.conf"

for domain in "${PUBLIC_DOMAINS[@]}"; do
    # Count occurrences before replacement (informational)
    COUNT=$(find "$ORIG_PROJECT_ROOT" -type f \( -false $(for ext in $CONFIG_EXTS; do echo "-o -name $ext"; done) \) \
        ! -path "*/node_modules/*" ! -path "*/.git/*" \
        ! -path "*/migrate2internal/*" ! -path "*/.claude/*" \
        -exec grep -lF "$domain" {} \; 2>/dev/null | wc -l)

    if [[ "$COUNT" -gt 0 ]]; then
        warn "Found $COUNT file(s) referencing $domain — sanitizing..."

        # Step 1: Fix OIDC issuer URLs (must use Docker network hostname, not localhost).
        #   From inside the openfga container, localhost:5556 is the container itself,
        #   not the host. Dex is reachable via the shared libcloud_net at dex:5556.
        find "$ORIG_PROJECT_ROOT" -type f \( -false $(for ext in $CONFIG_EXTS; do echo "-o -name $ext"; done) \) \
            ! -path "*/node_modules/*" ! -path "*/.git/*" \
            ! -path "*/migrate2internal/*" ! -path "*/.claude/*" \
            -exec sed -i "s|http://${domain}:5556/dex|http://dex:5556/dex|g" {} + 2>/dev/null

        # Step 2: Replace remaining occurrences with localhost (host-accessible services:
        #   portal on :3000, identity service on :8766, libcloud REST on :8765, etc.)
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
# 5. Restore SSH configuration
# ------------------------------------------------------------------
log "=== Step 5: Restore SSH configuration ==="

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
# 6. Recreate Docker networks
# ------------------------------------------------------------------
log "=== Step 6: Recreate Docker networks ==="

# Only create the shared external networks that are declared as
# `external: true` in compose files — they MUST exist before docker compose up.
# Compose-created networks (e.g., stoplight_mock_default) are managed
# automatically by docker compose and must NOT be created here manually —
# doing so would strip the compose labels and cause "network … was found but
# has incorrect label" errors.
EXTERNAL_NETWORKS=(
    "libcloud_net"                 # shared by most compose projects
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
# 7. Recreate named volumes and restore data
# ------------------------------------------------------------------
log "=== Step 7: Restore named volumes ==="

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
# 8. Restore bind-mount contents
# ------------------------------------------------------------------
log "=== Step 8: Restore bind mounts ==="

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
# 9. Verify .env and critical configs
# ------------------------------------------------------------------
log "=== Step 9: Verify critical files ==="

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
    warn "Check that backup-system.sh completed all steps successfully."
fi

# ------------------------------------------------------------------
# 9b. Secret Reconciliation — ensure dex config and env agree.
#
# Both dex_bootstrap.py (setup.sh) and the backup/restore cycle write
# OAuth client secrets into two places:
#   dex/config.yaml        — what Dex reads at startup
#   dex/generated/dex.env  — consumed by identity-service via env_file
#
# If they drift apart (e.g. a re-bootstrap after backup, or a partial
# restore), the identity-service token exchange fails with "invalid
# client_secret" in Dex logs.  dex.env is the authoritative source
# (dex_bootstrap.py writes it last); reconcile config.yaml to match.
# ------------------------------------------------------------------
log "=== Step 9b: Secret Reconciliation ==="

DEX_ENV_FILE="$ORIG_PROJECT_ROOT/dex/generated/dex.env"
DEX_CONFIG_FILE="$ORIG_PROJECT_ROOT/dex/config.yaml"

reconcile_secret() {
    local env_key="$1"   # env var key in dex.env
    local client_id="$2"  # client id in config.yaml (staticClients entry)
    local label="$3"      # human label for logging

    if [[ ! -f "$DEX_ENV_FILE" || ! -f "$DEX_CONFIG_FILE" ]]; then
        return 0
    fi

    local env_secret config_secret
    env_secret=$(grep -E "^${env_key}=" "$DEX_ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
    # Extract the secret line that follows the client id entry in config.yaml.
    # Dex config has the form:
    #   - id: <client_id>
    #     name: ...
    #     secret: <the-secret>
    config_secret=$(grep -A3 "id: ${client_id}" "$DEX_CONFIG_FILE" 2>/dev/null \
        | grep -E '^\s+secret:' | sed 's/.*secret:\s*//' || true)

    if [[ -z "$env_secret" || -z "$config_secret" ]]; then
        warn "  Cannot extract ${label} secret (env='${env_secret:-<missing>}' config='${config_secret:-<missing>}')"
        return 0
    fi

    if [[ "$env_secret" != "$config_secret" ]]; then
        warn "  MISMATCH on ${label}: dex.env ≠ config.yaml — syncing config.yaml ← dex.env"
        # Replace the secret line right after the client id block.
        # Use a range: find the line with "id: <client_id>", then replace the
        # next "secret:" line (within 3 lines) with the env value.
        sed -i "/id: ${client_id}/,/secret:/{s/secret:.*/secret: ${env_secret}/}" "$DEX_CONFIG_FILE"
        log "  ${label}: reconciled (config.yaml updated)."
    else
        log "  ${label}: OK (secrets match)"
    fi
}

reconcile_secret "DEX_PORTAL_CLIENT_SECRET"    "libcloud-portal" "portal-client"
reconcile_secret "LIBCLOUD_OIDC_CLIENT_SECRET" "libcloud-rest"   "libcloud-rest-client"

# ------------------------------------------------------------------

# ------------------------------------------------------------------
# 10. Start the stack — dependency order
# ------------------------------------------------------------------

# Helper: check that every image referenced in a compose file exists locally.
# On a machine with no internet access, docker compose tries to pull missing
# images from the registry and hangs until DNS/timeout.  This pre-check lets
# us skip the project gracefully instead.
#
# Usage:  compose_images_available <compose-file> [<extra-image>...]
# Returns 0 (success) if ALL referenced images are present locally,
#         1 (failure) if any are missing (with warnings to stderr).
compose_images_available() {
    local compose_file="$1"
    shift
    # Extra images to also require (e.g. local builds that use a different
    # tag than what the compose file references).
    local extra_images=("$@")

    local missing=0
    local -a imgs=()

    # Extract image: lines from the compose file
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

    # Append any extra images
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

log "=== Step 10: Start the stack ==="

# Startup order is critical — later services depend on earlier ones:
#   lldap           — no dependencies (LDAP user directory)
#   dex             — needs lldap (LDAP connector for user auth)
#   openfga_postgres — needs dex (OIDC issuer for JWT validation)
#   vault           — no hard dependencies
#   stoplight_mock  — no hard dependencies (Prism mock + emulator)
#   libcloud.rest   — needs openfga, dex, vault
#   identity_service — needs dex, openfga, libcloud.rest
#   server          — portal frontend; needs dex, identity_service
#   swagger-ui      — needs libcloud.rest's generated openapi.json
#   openfga_visualized — needs openfga, dex
#   infrastructure  — mock cloud SSH bastion + private droplet
COMPOSE_DIRS=(
    "$ORIG_PROJECT_ROOT/lldap"                                          # LLDAP user directory
    "$ORIG_PROJECT_ROOT/dex"                                            # Dex OIDC issuer
    "$ORIG_PROJECT_ROOT/openfga_postgres"                               # Postgres + OpenFGA + bootstrap
    "$ORIG_PROJECT_ROOT/vault"                                          # Vault secret store
    "$ORIG_PROJECT_ROOT/stoplight_mock"                                 # Prism mock + emulator
    "$ORIG_PROJECT_ROOT/libcloud.rest"                                  # Libcloud REST API
    "$ORIG_PROJECT_ROOT/identity_service"                               # Identity service (portal backend)
    "$ORIG_PROJECT_ROOT/server"                                         # Portal frontend
    "$ORIG_PROJECT_ROOT/openfga_visualized"                             # OpenFGA RBAC visualizer
)

# Additional compose files (same project, different compose file):
# Swagger UI uses a separate compose file in the libcloud.rest project
SWAGGER_COMPOSE="$ORIG_PROJECT_ROOT/libcloud.rest/docker-compose.swagger.yml"

STARTED=0
SKIPPED=0
FAILED=0

# Source generated/postgres.env before starting openfga_postgres so the
# password exported to the environment matches the hash in the restored
# PostgreSQL data volume.  Without this, docker-compose reads the empty
# POSTGRES_PASSWORD= from .env and falls back to the default "openfga",
# which does not authenticate against the restored volume's openfga role.
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
        # Pre-cleanup: if a previous restore run created a stale compose network
        # without the correct labels, docker compose up will fail with "network
        # … was found but has incorrect label".  Remove it so compose can
        # recreate it properly.
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

            # openfga_postgres: verify the PostgreSQL password matches the
            # restored data volume. POSTGRES_PASSWORD only takes effect on
            # FIRST database init — if the volume was initialised with a
            # different password, the env var is ignored. Use local-socket
            # (peer) auth to reset the openfga user's password so the
            # OpenFGA container can connect.
            if [[ "$dir" == *"openfga_postgres"* ]]; then
                log "  Verifying PostgreSQL password for openfga user ..."
                # Wait for postgres to be ready for socket connections
                sleep 3
                if docker exec openfga-postgres psql -U openfga -d openfga -c "SELECT 1" >/dev/null 2>&1; then
                    docker exec openfga-postgres psql -U openfga -d openfga \
                        -c "ALTER USER openfga PASSWORD '${POSTGRES_PASSWORD}';" >/dev/null 2>&1 || true
                    log "  PostgreSQL password verified and synced."
                else
                    warn "  Cannot connect to PostgreSQL via local socket — OpenFGA may fail."
                fi
                # Wait for openfga to become healthy before proceeding
                log "  Waiting for OpenFGA health check ..."
                for _i in $(seq 1 60); do
                    if docker inspect --format '{{ .State.Health.Status }}' openfga 2>/dev/null | grep -qx healthy; then break; fi
                    sleep 1
                done
            fi

            # identity_service: force-recreate so it picks up the current
            # dex/generated/dex.env values (DEX_PORTAL_CLIENT_SECRET, etc.).
            # The container reads env_file only at creation time — a stale
            # container from a previous restore run would hold old secrets.
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

# Start additional compose projects that use non-default compose filenames
log "Starting additional compose projects..."

# Swagger UI: uses a separate compose file in the libcloud.rest project.
# The helper checks that the swagger-ui image is available locally before
# attempting to start — without this, Docker would try to pull from Docker
# Hub and hang until timeout on a machine with no internet access.
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
# 11. Verify
# ------------------------------------------------------------------
log "=== Step 11: Verify ==="

echo ""
info "Docker containers:"
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null || true

echo ""
info "Docker volumes:"
docker volume ls 2>/dev/null || true

# ------------------------------------------------------------------
# 12. Targeted credential-integrity checks
#
# Verify the two credential-drift issues discovered during login
# debugging (DEX_PORTAL_CLIENT_SECRET mismatch, PostgreSQL password
# drift) are actually resolved in the running stack, not just on disk.
# ------------------------------------------------------------------
log "=== Step 12: Credential integrity checks ==="

CRED_OK=0
CRED_FAIL=0

# 12a. DEX_PORTAL_CLIENT_SECRET in identity-service container vs config.yaml
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

# 12b. OpenFGA container health
OPENFGA_STATUS=$(docker inspect --format '{{ .State.Health.Status }}' openfga 2>/dev/null || echo "not-found")
if [[ "$OPENFGA_STATUS" == "healthy" ]]; then
    log "  PASS: OpenFGA container is healthy"
    CRED_OK=$((CRED_OK + 1))
else
    warn "  FAIL: OpenFGA status is '$OPENFGA_STATUS' (expected 'healthy')"
    CRED_FAIL=$((CRED_FAIL + 1))
fi

# 12c. No PostgreSQL auth errors in recent logs
PG_AUTH_ERRORS=$(docker logs openfga-postgres --since 5m 2>&1 | grep -c "password authentication failed" || true)
if [[ "$PG_AUTH_ERRORS" -eq 0 ]]; then
    log "  PASS: No PostgreSQL auth failures in recent logs"
    CRED_OK=$((CRED_OK + 1))
else
    warn "  FAIL: $PG_AUTH_ERRORS PostgreSQL auth failure(s) in recent logs"
    CRED_FAIL=$((CRED_FAIL + 1))
fi

# 12d. No Dex client_secret errors in recent logs
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
