#!/usr/bin/env bash
# ============================================================================
# backup-system.sh — Full-system backup of the libcloud-nutanix Docker stack
#
# Run this on the SOURCE machine (IP 167.172.94.123) as the user with sudo
# access (ubuntu). It produces ~/offline/docker-debs/ (Docker packages) and
# ~/offline/backup/ (images, project files, volumes, bind mounts).
#
# Transfer the entire ~/offline/ directory to the destination machine, then
# run restore-system.sh there.
#
# Usage:
#   chmod +x backup-system.sh
#   ./backup-system.sh
# ============================================================================

set -euo pipefail

SRC_IP="167.172.94.123"
PROJECT_ROOT="/home/ubuntu/libcloud_nutanix"
PARENT_DIR="$(dirname "$PROJECT_ROOT")"
PROJECT_NAME="$(basename "$PROJECT_ROOT")"

OFFLINE_DIR="$HOME/offline"
DEB_DIR="$OFFLINE_DIR/docker-debs"
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

if [[ "$(hostname -I 2>/dev/null | grep -o "$SRC_IP" || true)" == "" ]]; then
    warn "This machine does not appear to be $SRC_IP (the documented source)."
    warn "If you are NOT on the source machine, abort now (Ctrl-C)."
    sleep 3
fi

if ! command -v docker &>/dev/null; then
    err "Docker is not installed. This script must run on the source machine."
    exit 1
fi

RUNNING_COUNT=$(docker ps -q 2>/dev/null | wc -l)
log "$RUNNING_COUNT containers running"

mkdir -p "$DEB_DIR" "$IMAGES_DIR" "$PROJECT_DIR" "$VOLUMES_DIR" "$BINDS_DIR"

# ------------------------------------------------------------------
# 1. Download Docker + Compose .deb packages (offline install bundle)
# ------------------------------------------------------------------
log "=== Step 1: Download Docker .deb packages ==="

if [[ -f "$DEB_DIR/SHA256SUMS" ]]; then
    warn "docker-debs/SHA256SUMS already exists — skipping download."
else
    log "Setting up Docker apt repository..."

    # Remove any pre-existing Docker apt sources to avoid Signed-By conflicts
    sudo rm -f /etc/apt/keyrings/docker.gpg /etc/apt/keyrings/docker.asc
    sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.sources

    sudo apt update -qq
    sudo apt install -y -qq ca-certificates curl

    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    # Detect the Ubuntu codename and architecture from the running OS
    # so the script works on any supported Ubuntu release and CPU arch.
    UBUNTU_CODENAME=$(. /etc/os-release && echo "$UBUNTU_CODENAME")
    DPKG_ARCH=$(dpkg --print-architecture)
    log "Detected: Ubuntu $UBUNTU_CODENAME / $DPKG_ARCH"

    sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME}
Components: stable
Architectures: ${DPKG_ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    sudo apt update -qq

    log "Downloading docker-ce, docker-ce-cli, containerd.io, docker-buildx-plugin, docker-compose-plugin..."
    sudo apt clean
    sudo apt install --download-only -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Also capture transitive dependencies that the Docker packages need
    # (e.g., pigz).  --reinstall is required here because --download-only
    # alone skips packages already installed on the source machine — they
    # would never land in the cache and the offline restore would fail
    # trying to fetch them from archive.ubuntu.com.
    log "Downloading extra dependencies (pigz)..."
    sudo apt install --reinstall --download-only -y pigz 2>/dev/null || true

    cp /var/cache/apt/archives/*.deb "$DEB_DIR/"
    (cd "$DEB_DIR" && sha256sum *.deb > SHA256SUMS)
    log "Downloaded $(ls "$DEB_DIR"/*.deb 2>/dev/null | wc -l) .deb packages"
fi

# ------------------------------------------------------------------
# 2. Save all container images
# ------------------------------------------------------------------
log "=== Step 2: Save all container images ==="

# All containers (running + exited), not just running ones, because one-shot
# bootstrap containers (openfga-bootstrap, vault-bootstrap) run once during
# setup.sh and exit immediately.  Without -a, their image (python:3.12-slim)
# is never saved, and the offline restore fails trying to pull from Docker Hub.
docker inspect -f '{{.Config.Image}}' $(docker ps -a -q) 2>/dev/null \
    | sort -u > "$IMAGES_DIR/images.txt"

log "Candidate images from containers ($(wc -l < "$IMAGES_DIR/images.txt")):"
cat "$IMAGES_DIR/images.txt"

# Filter to only images that actually exist on disk.  Exited containers may
# reference images that were pruned (e.g. swagger-ui), and docker save fails
# hard on any missing image.
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

# Overwrite images.txt with the verified list so the manifest is accurate
echo "$IMAGE_LIST" | tr ' ' '\n' | grep -v '^$' > "$IMAGES_DIR/images.txt"

if [[ -z "$IMAGE_LIST" ]]; then
    err "No images found to save."
    exit 1
fi

log "Saving $(wc -w <<< "$IMAGE_LIST") image(s) ($SKIPPED skipped)..."
# shellcheck disable=SC2086
docker save -o "$IMAGES_DIR/stack-images.tar" $IMAGE_LIST
SAVE_SIZE=$(du -h "$IMAGES_DIR/stack-images.tar" | cut -f1)
log "Saved images tarball: $SAVE_SIZE"

# ------------------------------------------------------------------
# 3. Record mounts for all containers
# ------------------------------------------------------------------
log "=== Step 3: Record container mounts ==="

# Only running containers (docker ps without -a excludes stopped ones)
docker ps -q | while read c; do
    echo "=== $c $(docker inspect -f '{{.Name}}' "$c")"
    docker inspect -f '{{range .Mounts}}{{printf "%s|%s|%s|%s\n" .Type .Name .Source .Destination}}{{end}}' "$c"
done | tee "$BACKUP_DIR/mounts.txt"

# ------------------------------------------------------------------
# 4. Back up project files (all compose directories + configs)
# ------------------------------------------------------------------
log "=== Step 4: Back up project files ==="

PROJECT_TARBALL="$PROJECT_DIR/project-files.tgz"

# Exclude patterns — avoid duplicating volume/bind payloads and garbage
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

# Archive with -C parent so paths inside the tarball are:
#   libcloud_nutanix/.env
#   libcloud_nutanix/dex/docker-compose.yml
#   libcloud_nutanix/dex/config.yaml
#   ...etc...
# The restore script must extract with: tar -xzf ... -C /home/ubuntu
# so files land at /home/ubuntu/libcloud_nutanix/...
tar -czf "$PROJECT_TARBALL" "${EXCLUDES[@]}" \
    -C "$PARENT_DIR" \
    "$PROJECT_NAME"

log "Project tarball: $(du -h "$PROJECT_TARBALL" | cut -f1)"

# Quick verification: check key files are inside the tarball
log "Verifying key files in project tarball..."
MISSING_FILES=()
for f in ".env" "dex/docker-compose.yml" "lldap/docker-compose.yml" \
         "openfga_postgres/docker-compose.yml" "server/docker-compose.yml"; do
    if tar -tzf "$PROJECT_TARBALL" "${PROJECT_NAME}/${f}" &>/dev/null; then
        log "  OK: ${PROJECT_NAME}/${f}"
    else
        warn "  MISSING: ${PROJECT_NAME}/${f}"
        MISSING_FILES+=("$f")
    fi
done
if [[ ${#MISSING_FILES[@]} -gt 0 ]]; then
    warn "Some expected files are missing from the project archive."
    warn "The stack may not start correctly on restore."
fi

# ------------------------------------------------------------------
# 5. Back up Docker named volumes
# ------------------------------------------------------------------
log "=== Step 5: Back up Docker named volumes ==="

# Extract named volumes from mounts.txt
awk -F'|' '$1=="volume" && $2!="" {print $2}' "$BACKUP_DIR/mounts.txt" \
    | sort -u > "$BACKUP_DIR/volume-names.txt"

# Also capture any volumes not referenced by running containers (orphaned)
docker volume ls -q 2>/dev/null >> "$BACKUP_DIR/volume-names.txt" || true
sort -u "$BACKUP_DIR/volume-names.txt" -o "$BACKUP_DIR/volume-names.txt"

log "Named volumes to back up ($(wc -l < "$BACKUP_DIR/volume-names.txt")):"
cat "$BACKUP_DIR/volume-names.txt"

VOLUMES_BACKED_UP=0
while read v; do
    [[ -z "$v" ]] && continue
    # Use 'docker volume inspect' to get the real Mountpoint —
    # this works regardless of Docker's configured data-root.
    VOL_PATH=$(docker volume inspect -f '{{.Mountpoint}}' "$v" 2>/dev/null) || true
    if [[ -n "$VOL_PATH" && -d "$VOL_PATH" ]]; then
        log "  Backing up volume: $v"
        sudo tar --numeric-owner -czf "$VOLUMES_DIR/${v}.tgz" \
            -C "$VOL_PATH" .
        VOLUMES_BACKED_UP=$((VOLUMES_BACKED_UP + 1))
    else
        warn "  Volume path not found: ${VOL_PATH:-"<inspect failed>"} (skipping)"
    fi
done < "$BACKUP_DIR/volume-names.txt"

log "Backed up $VOLUMES_BACKED_UP volumes"
ls -lh "$VOLUMES_DIR/" 2>/dev/null || warn "No volume archives created"

# ------------------------------------------------------------------
# 6. Back up bind-mounted host paths
# ------------------------------------------------------------------
log "=== Step 6: Back up bind-mounted host paths ==="

awk -F'|' '$1=="bind" && $3!="" {print $3}' "$BACKUP_DIR/mounts.txt" \
    | sort -u > "$BACKUP_DIR/bind-sources.txt"

log "Bind-mount sources to back up ($(wc -l < "$BACKUP_DIR/bind-sources.txt")):"
cat "$BACKUP_DIR/bind-sources.txt"

idx=0
while read src; do
    [[ -z "$src" ]] && continue
    if [[ -e "$src" ]]; then
        idx=$((idx + 1))
        safe_name=$(printf "%04d" "$idx")-$(echo "$src" | tr '/' '_')
        if [[ -d "$src" ]]; then
            log "  Backing up directory: $src"
            sudo tar --numeric-owner -czf "$BINDS_DIR/${safe_name}.tgz" \
                -C "$(dirname "$src")" "$(basename "$src")"
        else
            log "  Backing up file: $src"
            sudo tar --numeric-owner -czf "$BINDS_DIR/${safe_name}.tgz" \
                -C "$(dirname "$src")" "$(basename "$src")"
        fi
    else
        warn "  Bind source not found: $src (skipping)"
    fi
done < "$BACKUP_DIR/bind-sources.txt"

# Save a map file so restore knows what each archive maps to
awk -F'|' '$1=="bind" && $3!="" {print $3}' "$BACKUP_DIR/mounts.txt" \
    | sort -u | nl -w4 -s'|' > "$BINDS_DIR/bind-map.txt"

log "Bind-mount archives: $(ls "$BINDS_DIR"/*.tgz 2>/dev/null | wc -l)"

# ------------------------------------------------------------------
# 7. Back up SSH key + config
# ------------------------------------------------------------------
log "=== Step 7: Back up SSH key ==="

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
# 8. Save Docker network names (for informational purposes)
# ------------------------------------------------------------------
log "=== Step 8: Record Docker networks ==="

docker network ls --format '{{.Name}} {{.Driver}}' \
    | grep -v -E '^(bridge|host|none) ' \
    > "$BACKUP_DIR/network-names.txt" || true

log "Custom networks ($(wc -l < "$BACKUP_DIR/network-names.txt" 2>/dev/null || echo 0)):"
cat "$BACKUP_DIR/network-names.txt" 2>/dev/null || true

# ------------------------------------------------------------------
# 9. Generate manifest and checksums
# ------------------------------------------------------------------
log "=== Step 9: Generate manifest ==="

cat > "$BACKUP_DIR/MANIFEST.txt" <<EOF
Backup manifest — $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Source machine:  $SRC_IP
Hostname:        $(hostname)
Project root:    $PROJECT_ROOT
Docker version:  $(docker --version 2>/dev/null || echo 'N/A')
Compose version: $(docker compose version 2>/dev/null || echo 'N/A')

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

# SHA256SUMS
(cd "$BACKUP_DIR" && find . -type f \
    -not -name SHA256SUMS \
    -not -name MANIFEST.txt \
    -exec sha256sum {} \;) > "$BACKUP_DIR/SHA256SUMS"

# ------------------------------------------------------------------
# 10. Summary
# ------------------------------------------------------------------
log "=== Backup complete ==="
echo ""
echo "Backup location: $OFFLINE_DIR"
echo ""
echo "Contents:"
du -sh "$OFFLINE_DIR"/*/ 2>/dev/null || true
echo ""
echo "Volume archives:"
ls -lh "$VOLUMES_DIR/" 2>/dev/null || echo "  (none)"
echo ""
echo "Next steps:"
echo "  1. Copy ~/offline/ to the destination (internal) machine:"
echo "     cd $(dirname "$0") && ./transfer-backup.sh"
echo ""
echo "  2. On the destination machine, run:"
echo "     ./restore-system.sh"
echo ""
echo "Manifest:  $BACKUP_DIR/MANIFEST.txt"
echo "Checksums: $BACKUP_DIR/SHA256SUMS"
