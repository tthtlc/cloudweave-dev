#!/usr/bin/env bash
# ============================================================================
# backup-docker-images.sh — Distro-agnostic Docker-stack backup (images-first)
#
# Simplified version of backup-system.sh.  Assumes Docker is already installed
# on the source machine — no OS packages are downloaded or installed.  Works on
# any Linux distribution with Docker (Ubuntu, Rocky Linux, AlmaLinux, etc.).
#
# Run this on the SOURCE machine, then transfer ~/offline/ to the destination
# and run restore-docker-images.sh there.
#
# Usage:
#   chmod +x backup-docker-images.sh
#   ./backup-docker-images.sh
# ============================================================================

set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(dirname "$(dirname "$(readlink -f "$0")")")}"
PARENT_DIR="$(dirname "$PROJECT_ROOT")"
PROJECT_NAME="$(basename "$PROJECT_ROOT")"

OFFLINE_DIR="${OFFLINE_DIR:-$HOME/offline}"
BACKUP_DIR="$OFFLINE_DIR/backup"
IMAGES_DIR="$BACKUP_DIR/images"
PROJECT_DIR="$BACKUP_DIR/project"
VOLUMES_DIR="$BACKUP_DIR/volumes"
BINDS_DIR="$BACKUP_DIR/binds"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[BACKUP]${NC} $(date '+%H:%M:%S') $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*" >&2; }

# ------------------------------------------------------------------
# 0. Preflight
# ------------------------------------------------------------------
log "=== Preflight checks ==="

if ! command -v docker &>/dev/null; then
    err "Docker is not installed. Please install Docker first, then re-run."
    exit 1
fi

DOCKER_VERSION=$(docker --version 2>/dev/null || echo 'unknown')
COMPOSE_VERSION=$(docker compose version 2>/dev/null || echo 'unknown')
log "Docker:  $DOCKER_VERSION"
log "Compose: $COMPOSE_VERSION"

RUNNING_COUNT=$(docker ps -q 2>/dev/null | wc -l)
ALL_COUNT=$(docker ps -a -q 2>/dev/null | wc -l)
log "$RUNNING_COUNT containers running ($ALL_COUNT total including stopped)"

mkdir -p "$IMAGES_DIR" "$PROJECT_DIR" "$VOLUMES_DIR" "$BINDS_DIR"

# Clean out old tarballs from previous runs (which may be root-owned if a
# prior invocation used sudo — the current user would be unable to overwrite
# them, causing "Permission denied").
log "Cleaning old backup archives..."
rm -f "$BINDS_DIR"/*.tgz "$BINDS_DIR"/*.tar.gz "$VOLUMES_DIR"/*.tgz "$VOLUMES_DIR"/*.tar.gz 2>/dev/null || true

# ------------------------------------------------------------------
# 1. Save all container images (running + exited)
# ------------------------------------------------------------------
log "=== Step 1: Save all container images ==="

# Capture every image referenced by any container (including exited one-shot
# bootstrap containers like vault-bootstrap, openfga-bootstrap, etc.).
docker inspect -f '{{.Config.Image}}' $(docker ps -a -q) 2>/dev/null \
    | sort -u > "$IMAGES_DIR/images.txt"

log "Candidate images from containers ($(wc -l < "$IMAGES_DIR/images.txt")):"
cat "$IMAGES_DIR/images.txt"

# Filter to only images that actually exist on disk — exited containers may
# reference pruned images, and docker save fails hard on any missing image.
IMAGE_LIST=""
SKIPPED=0
while IFS= read -r img; do
    [[ -z "$img" ]] && continue
    if docker image inspect "$img" &>/dev/null; then
        IMAGE_LIST="$IMAGE_LIST $img"
    else
        warn "  Skipping (image not found locally): $img"
        SKIPPED=$((SKIPPED + 1))
    fi
done < "$IMAGES_DIR/images.txt"

# Overwrite with the verified list
echo "$IMAGE_LIST" | tr ' ' '\n' | grep -v '^$' > "$IMAGES_DIR/images.txt"

if [[ -z "$IMAGE_LIST" ]]; then
    err "No images found to save."
    exit 1
fi

# ------------------------------------------------------------------
# 2. Pull compose-file images not already captured
# ------------------------------------------------------------------
log "=== Step 2: Scan compose files for additional images ==="

FOUND_EXTRA=0
while IFS= read -r compose_file; do
    while IFS= read -r img; do
        [[ -z "$img" ]] && continue
        [[ "$img" == "&"* ]] && continue        # YAML anchor
        [[ "$img" == *'$'* ]] && continue       # variable substitution
        # Already tracked from container inspection
        if echo "$IMAGE_LIST" | grep -qwF "$img"; then
            continue
        fi
        # Already present locally?
        if docker image inspect "$img" &>/dev/null; then
            log "  Already present: $img"
            IMAGE_LIST="$IMAGE_LIST $img"
            FOUND_EXTRA=$((FOUND_EXTRA + 1))
        elif docker pull "$img" 2>/dev/null; then
            log "  Pulled: $img"
            IMAGE_LIST="$IMAGE_LIST $img"
            FOUND_EXTRA=$((FOUND_EXTRA + 1))
        else
            # Pull failed — try local build if compose file has build: directive
            if grep -q '^\s*build:' "$compose_file" 2>/dev/null; then
                log "  Pull failed for $img — attempting local build via compose..."
                if docker compose -f "$compose_file" build 2>&1; then
                    log "  Built: $img"
                    IMAGE_LIST="$IMAGE_LIST $img"
                    FOUND_EXTRA=$((FOUND_EXTRA + 1))
                else
                    warn "  UNAVAILABLE: $img (from $(basename "$compose_file"))"
                    warn "    Not present locally, cannot pull, build failed."
                fi
            else
                warn "  UNAVAILABLE: $img (from $(basename "$compose_file"))"
                warn "    Not present locally and cannot be pulled."
            fi
        fi
    done < <(grep -h '^\s*image:' "$compose_file" 2>/dev/null \
        | grep -v '^\s*#' \
        | sed 's/.*image:\s*//; s/"//g' \
        | sort -u)
done < <(find "$PROJECT_ROOT" -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' 2>/dev/null \
    | grep -v '/aws_user_docker/')

if [[ "$FOUND_EXTRA" -gt 0 ]]; then
    log "Added $FOUND_EXTRA compose-only image(s)"
fi

# Rebuild images.txt from the final list
echo "$IMAGE_LIST" | tr ' ' '\n' | grep -v '^$' | sort -u > "$IMAGES_DIR/images.txt"

log "Final image list ($(wc -l < "$IMAGES_DIR/images.txt") images):"
cat "$IMAGES_DIR/images.txt"

# ------------------------------------------------------------------
# 3. Save images to tarball
# ------------------------------------------------------------------
log "=== Step 3: Save images to tarball ==="

log "Saving $(echo "$IMAGE_LIST" | wc -w) image(s) ($SKIPPED skipped)..."
# shellcheck disable=SC2086
docker save -o "$IMAGES_DIR/stack-images.tar" $IMAGE_LIST
SAVE_SIZE=$(du -h "$IMAGES_DIR/stack-images.tar" | cut -f1)
log "Saved images tarball: $SAVE_SIZE"

# ------------------------------------------------------------------
# 4. Record mounts for all running containers
# ------------------------------------------------------------------
log "=== Step 4: Record container mounts ==="

docker ps -q 2>/dev/null | while read -r c; do
    echo "=== $c $(docker inspect -f '{{.Name}}' "$c")"
    docker inspect -f '{{range .Mounts}}{{printf "%s|%s|%s|%s\n" .Type .Name .Source .Destination}}{{end}}' "$c"
done | tee "$BACKUP_DIR/mounts.txt"

# ------------------------------------------------------------------
# 5. Back up project files (compose directories + configs)
# ------------------------------------------------------------------
log "=== Step 5: Back up project files ==="

PROJECT_TARBALL="$PROJECT_DIR/project-files.tgz"

EXCLUDES=(
    --exclude='.git'
    --exclude='*.log'
    --exclude='__pycache__'
    --exclude='*.pyc'
    --exclude='node_modules'
    --exclude='.venv'
    --exclude='venv'
    --exclude='*.tar'
    --exclude='*.tgz'
    --exclude='*.tar.gz'
    --exclude='libcloud/.tox'
    --exclude='libcloud/uv.lock'
    --exclude='.claude'
)

tar -czf "$PROJECT_TARBALL" "${EXCLUDES[@]}" \
    -C "$PARENT_DIR" \
    "$PROJECT_NAME"

log "Project tarball: $(du -h "$PROJECT_TARBALL" | cut -f1)"

# Verify key files
log "Verifying key files in project tarball..."
for f in ".env" "dex/docker-compose.yml" "lldap/docker-compose.yml" \
         "openfga_postgres/docker-compose.yml" "server/docker-compose.yml"; do
    if tar -tzf "$PROJECT_TARBALL" "${PROJECT_NAME}/${f}" &>/dev/null; then
        log "  OK: ${PROJECT_NAME}/${f}"
    else
        warn "  MISSING: ${PROJECT_NAME}/${f}"
    fi
done

# ------------------------------------------------------------------
# 6. Back up Docker named volumes
# ------------------------------------------------------------------
log "=== Step 6: Back up Docker named volumes ==="

# From running containers
awk -F'|' '$1=="volume" && $2!="" {print $2}' "$BACKUP_DIR/mounts.txt" \
    | sort -u > "$BACKUP_DIR/volume-names.txt"

# Also capture orphaned volumes
docker volume ls -q 2>/dev/null >> "$BACKUP_DIR/volume-names.txt" || true
sort -u "$BACKUP_DIR/volume-names.txt" -o "$BACKUP_DIR/volume-names.txt"

log "Named volumes to back up ($(wc -l < "$BACKUP_DIR/volume-names.txt")):"
cat "$BACKUP_DIR/volume-names.txt"

VOLUMES_BACKED_UP=0
while read -r v; do
    [[ -z "$v" ]] && continue
    # Use a temporary Alpine container to read the volume — avoids needing
    # root access to /var/lib/docker/volumes/ on the host filesystem.
    log "  Backing up volume: $v"
    docker run --rm \
        -v "${v}:/volume:ro" \
        -v "$VOLUMES_DIR:/backup" \
        alpine:latest \
        tar --numeric-owner -czf "/backup/${v}.tgz" -C /volume . 2>/dev/null && {
        VOLUMES_BACKED_UP=$((VOLUMES_BACKED_UP + 1))
    } || {
        warn "  Failed to back up volume: $v (skipping)"
    }
done < "$BACKUP_DIR/volume-names.txt"

log "Backed up $VOLUMES_BACKED_UP volumes"
ls -lh "$VOLUMES_DIR/" 2>/dev/null || warn "No volume archives created"

# ------------------------------------------------------------------
# 7. Back up bind-mounted host paths
# ------------------------------------------------------------------
log "=== Step 7: Back up bind-mounted host paths ==="

awk -F'|' '$1=="bind" && $3!="" {print $3}' "$BACKUP_DIR/mounts.txt" \
    | sort -u > "$BACKUP_DIR/bind-sources.txt"

log "Bind-mount sources ($(wc -l < "$BACKUP_DIR/bind-sources.txt")):"
cat "$BACKUP_DIR/bind-sources.txt"

idx=0
while read -r src; do
    [[ -z "$src" ]] && continue
    if [[ -e "$src" ]]; then
        idx=$((idx + 1))
        safe_name=$(printf "%04d" "$idx")-$(echo "$src" | tr '/' '_')
        if [[ -d "$src" ]]; then
            log "  Backing up directory: $src"
            tar --numeric-owner -czf "$BINDS_DIR/${safe_name}.tgz" \
                -C "$(dirname "$src")" "$(basename "$src")"
        else
            log "  Backing up file: $src"
            tar --numeric-owner -czf "$BINDS_DIR/${safe_name}.tgz" \
                -C "$(dirname "$src")" "$(basename "$src")"
        fi
    else
        warn "  Bind source not found: $src (skipping)"
    fi
done < "$BACKUP_DIR/bind-sources.txt"

# Save a map for restore
awk -F'|' '$1=="bind" && $3!="" {print $3}' "$BACKUP_DIR/mounts.txt" \
    | sort -u | nl -w4 -s'|' > "$BINDS_DIR/bind-map.txt"

log "Bind-mount archives: $(ls "$BINDS_DIR"/*.tgz 2>/dev/null | wc -l)"

# ------------------------------------------------------------------
# 8. Back up SSH key + config
# ------------------------------------------------------------------
log "=== Step 8: Back up SSH key ==="

SSH_KEY="$HOME/.ssh/libcloud-private-key.pem"
SSH_CONFIG="$HOME/.ssh/config"

if [[ -f "$SSH_KEY" ]]; then
    cp "$SSH_KEY" "$BACKUP_DIR/libcloud-private-key.pem"
    chmod 600 "$BACKUP_DIR/libcloud-private-key.pem"
    log "SSH key copied: libcloud-private-key.pem"
else
    warn "SSH key not found: $SSH_KEY"
fi

if [[ -f "$SSH_CONFIG" ]]; then
    cp "$SSH_CONFIG" "$BACKUP_DIR/ssh-config"
    log "SSH config copied"
fi

# ------------------------------------------------------------------
# 9. Record Docker networks
# ------------------------------------------------------------------
log "=== Step 9: Record Docker networks ==="

docker network ls --format '{{.Name}} {{.Driver}}' \
    | grep -v -E '^(bridge|host|none) ' \
    > "$BACKUP_DIR/network-names.txt" || true

log "Custom networks ($(wc -l < "$BACKUP_DIR/network-names.txt" 2>/dev/null || echo 0)):"
cat "$BACKUP_DIR/network-names.txt" 2>/dev/null || true

# ------------------------------------------------------------------
# 10. Generate manifest and checksums
# ------------------------------------------------------------------
log "=== Step 10: Generate manifest ==="

cat > "$BACKUP_DIR/MANIFEST.txt" <<EOF
Backup manifest — $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Hostname:        $(hostname)
Project root:    $PROJECT_ROOT
Docker version:  $DOCKER_VERSION
Compose version: $COMPOSE_VERSION

--- Images saved ($(wc -l < "$IMAGES_DIR/images.txt")) ---
$(sed 's/^/  /' "$IMAGES_DIR/images.txt")

--- Named volumes ($(wc -l < "$BACKUP_DIR/volume-names.txt")) ---
$(sed 's/^/  /' "$BACKUP_DIR/volume-names.txt")

--- Bind mounts ($(wc -l < "$BACKUP_DIR/bind-sources.txt")) ---
$(sed 's/^/  /' "$BACKUP_DIR/bind-sources.txt")

--- Docker networks ---
$(cat "$BACKUP_DIR/network-names.txt" 2>/dev/null || echo '  (none)')

--- Running containers at backup time ---
$(docker ps --format '  {{.Names}}  {{.Image}}  {{.Status}}')
EOF

# SHA256SUMS for everything in the backup (excluding manifest + checksum itself)
(cd "$BACKUP_DIR" && find . -type f \
    -not -name SHA256SUMS \
    -not -name MANIFEST.txt \
    -exec sha256sum {} \;) > "$BACKUP_DIR/SHA256SUMS"

# ------------------------------------------------------------------
# 11. Summary
# ------------------------------------------------------------------
log "=== Backup complete ==="
echo ""
echo "Backup location: $OFFLINE_DIR"
echo ""
echo "Contents:"
du -sh "$OFFLINE_DIR"/*/ 2>/dev/null || true
echo ""
echo "Images tarball: $IMAGES_DIR/stack-images.tar ($SAVE_SIZE)"
echo ""
echo "Next steps:"
echo "  1. Transfer ~/offline/ to the destination machine (scp/rsync)"
echo "  2. On the destination, run restore-docker-images.sh to restore"
echo ""
echo "Manifest:  $BACKUP_DIR/MANIFEST.txt"
echo "Checksums: $BACKUP_DIR/SHA256SUMS"
