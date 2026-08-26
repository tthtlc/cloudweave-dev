#!/usr/bin/env bash
# ============================================================================
# backup-system.sh — Full-system backup of the libcloud-nutanix Docker stack
#
# Run this on the SOURCE machine. Docker is assumed to be already installed
# and running — no OS packages are downloaded or installed, so this works on
# any Linux distribution with Docker (Ubuntu, Rocky Linux, AlmaLinux, etc.).
#
# Produces ~/offline/backup/ containing: container images, project files,
# named volumes, bind mounts, and SSH config.  Transfer the entire ~/offline/
# directory to the destination machine, then run restore-system.sh there.
#
# Usage:
#   chmod +x backup-system.sh
#   ./backup-system.sh
# ============================================================================

set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$HOME/libcloud_nutanix}"
PARENT_DIR="$(dirname "$PROJECT_ROOT")"
PROJECT_NAME="$(basename "$PROJECT_ROOT")"

OFFLINE_DIR="${OFFLINE_DIR:-$HOME/offline}"
BACKUP_DIR="$OFFLINE_DIR/backup"
IMAGES_DIR="$BACKUP_DIR/images"
PROJECT_DIR="$BACKUP_DIR/project"
VOLUMES_DIR="$BACKUP_DIR/volumes"
BINDS_DIR="$BACKUP_DIR/binds"

# Helper image used to read/write named volumes without needing root access to
# /var/lib/docker/volumes/.  It is also saved into stack-images.tar so the
# offline restore can use the same helper.
HELPER_IMAGE="${HELPER_IMAGE:-alpine:latest}"

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
# 2b. Proactively build all locally-built images.
#     Services with a build: directive in their compose file are built
#     from source NOW so the resulting images are included in the
#     tarball.  After restore, setup.sh uses only --force-recreate
#     (no builds), so the offline machine never needs internet access.
# ------------------------------------------------------------------
log "=== Step 2b: Build locally-built images ==="

# Snapshot the local image store before building, so we can detect every image
# the builds create — including auto-named ones (services with a `build:` but no
# `image:` line, e.g. server/portal -> server-portal:latest and
# stoplight_mock/emulator -> stoplight_mock-emulator:latest). The `image:` scan
# below never sees those, so without this diff they'd be missing from the tarball
# and the offline restore would try to build (or pull) them.
docker images -q --no-trunc 2>/dev/null | sort -u > "$IMAGES_DIR/.images_before_build"

log "Scanning compose files for build: directives..."
BUILT_PROJECTS=0
while IFS= read -r compose_file; do
    if grep -q '^\s*build:' "$compose_file" 2>/dev/null; then
        project_label="$(basename "$(dirname "$compose_file")")/$(basename "$compose_file")"
        log "  Building images for ${project_label} ..."
        if docker compose -f "$compose_file" build 2>&1; then
            BUILT_PROJECTS=$((BUILT_PROJECTS + 1))
            log "  Build succeeded: ${project_label}"
        else
            warn "  Build FAILED for ${project_label} — some services may be missing from the backup"
        fi
    fi
done < <(find "$PROJECT_ROOT" -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' 2>/dev/null \
    | grep -v '/aws_user_docker/')

log "Proactively built ${BUILT_PROJECTS} compose project(s) from source"

# Refresh the image list after builds — newly built images may not have
# been referenced by any container (docker ps -a won't see them if the
# service was never started).  Re-scan compose files for any image tags
# that now exist locally thanks to the builds above.
log "Refreshing image list after builds..."
while IFS= read -r compose_file; do
    while IFS= read -r img; do
        [[ -z "$img" ]] && continue
        [[ "$img" == "&"* ]] && continue
        [[ "$img" == *'$'* ]] && continue
        if echo "$IMAGE_LIST" | grep -qwF "$img"; then
            continue
        fi
        if docker image inspect "$img" &>/dev/null; then
            log "  Post-build discovered: $img"
            IMAGE_LIST="$IMAGE_LIST $img"
        fi
    done < <(grep -h '^\s*image:' "$compose_file" 2>/dev/null \
        | grep -v '^\s*#' \
        | sed 's/.*image:\s*//; s/"//g' \
        | sort -u)
done < <(find "$PROJECT_ROOT" -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' 2>/dev/null \
    | grep -v '/aws_user_docker/')

echo "$IMAGE_LIST" | tr ' ' '\n' | grep -v '^$' | sort -u > "$IMAGES_DIR/images.txt"
log "Refreshed image list ($(wc -l < "$IMAGES_DIR/images.txt") images)"

# Capture auto-named images the builds created (build: without image:). Diff the
# image store against the pre-build snapshot and add any new repo:tag that the
# compose `image:` scans above missed.
log "Capturing auto-named built images..."
docker images -q --no-trunc 2>/dev/null | sort -u > "$IMAGES_DIR/.images_after_build"
while read -r _imgid; do
    _repo_tag="$(docker image inspect --format '{{index .RepoTags 0}}' "$_imgid" 2>/dev/null || true)"
    [[ -z "$_repo_tag" || "$_repo_tag" == "<none>" || "$_repo_tag" == "<none>:<none>" ]] && continue
    if echo "$IMAGE_LIST" | grep -qwF "$_repo_tag"; then
        continue
    fi
    log "  Built (auto-named): $_repo_tag"
    IMAGE_LIST="$IMAGE_LIST $_repo_tag"
done < <(comm -13 "$IMAGES_DIR/.images_before_build" "$IMAGES_DIR/.images_after_build" 2>/dev/null)
rm -f "$IMAGES_DIR/.images_before_build" "$IMAGES_DIR/.images_after_build"

echo "$IMAGE_LIST" | tr ' ' '\n' | grep -v '^$' | sort -u > "$IMAGES_DIR/images.txt"
log "Final image list after build capture ($(wc -l < "$IMAGES_DIR/images.txt") images)"

# ------------------------------------------------------------------
# 3. Save images to tarball
# ------------------------------------------------------------------
log "=== Step 3: Save images to tarball ==="

# Include the volume helper image in the tarball so the offline restore can
# use the same helper. It is referenced by `docker run` above (not by any
# compose `image:` line or container), so the scans in Steps 1–2b never see it.
if docker image inspect "$HELPER_IMAGE" &>/dev/null; then
    if echo "$IMAGE_LIST" | grep -qwF "$HELPER_IMAGE"; then
        info "Helper image already in list: $HELPER_IMAGE"
    else
        IMAGE_LIST="$IMAGE_LIST $HELPER_IMAGE"
        log "Including helper image: $HELPER_IMAGE"
    fi
elif docker pull "$HELPER_IMAGE" 2>/dev/null; then
    IMAGE_LIST="$IMAGE_LIST $HELPER_IMAGE"
    log "Pulled and including helper image: $HELPER_IMAGE"
else
    warn "Helper image $HELPER_IMAGE unavailable — the offline restore may lack a volume helper"
fi

# Keep images.txt (used by the MANIFEST count) in sync with the final list.
echo "$IMAGE_LIST" | tr ' ' '\n' | grep -v '^$' | sort -u > "$IMAGES_DIR/images.txt"

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

# Archive with -C "$HOME" so paths inside the tarball are:
#   libcloud_nutanix/.env
#   libcloud_nutanix/dex/docker-compose.yml
#   ...etc...
# The restore script extracts with: tar -xzf ... -C "$HOME"
# so files land at $HOME/libcloud_nutanix/...
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
# 5b. Back up the libcloud.rest host venv (prebuilt for the offline host)
# ------------------------------------------------------------------
# setup.sh runs the auth-gate audit in-process on the HOST, which needs
# libcloud.rest/.venv (fastapi + httpx + vendored libcloud). The offline
# destination has no pip mirror, so build the venv HERE (source has network)
# and ship it as a tarball. Best-effort: if it can't be built, setup.sh on the
# destination falls back to skipping the audit.
log "=== Step 5b: Back up libcloud.rest host venv ==="

REST_VENV="$PROJECT_ROOT/libcloud.rest/.venv"
VENV_TARBALL="$BACKUP_DIR/libcloud-rest-venv.tgz"

# Build on the source if not already usable (the one place the deps are
# fetchable). Output is NOT quiet so progress is visible in the backup log.
if [[ ! -x "$REST_VENV/bin/python" ]] || ! "$REST_VENV/bin/python" -c 'import fastapi, httpx, libcloud' >/dev/null 2>&1; then
    log "libcloud.rest host venv not usable — building it now..."
    python3 -m venv "$REST_VENV" || warn "could not create $REST_VENV — venv backup skipped"
    if [[ -x "$REST_VENV/bin/python" ]]; then
        "$REST_VENV/bin/python" -m pip install -r "$PROJECT_ROOT/libcloud.rest/requirements.txt" "httpx" "$PROJECT_ROOT/libcloud" \
            || warn "pip install into $REST_VENV failed — venv backup skipped"
    fi
fi

if [[ -x "$REST_VENV/bin/python" ]] && "$REST_VENV/bin/python" -c 'import fastapi, httpx, libcloud' >/dev/null 2>&1; then
    log "Archiving prebuilt venv -> $VENV_TARBALL"
    tar -czf "$VENV_TARBALL" -C "$PROJECT_ROOT/libcloud.rest" .venv
    log "Venv tarball: $(du -h "$VENV_TARBALL" | cut -f1)"
else
    warn "libcloud.rest host venv unavailable — not shipping (destination will skip the authz audit)."
fi

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
    # Use a temporary helper container to read the volume — avoids needing
    # root access to /var/lib/docker/volumes/ on the host filesystem.
    log "  Backing up volume: $v"
    docker run --rm \
        -v "${v}:/volume:ro" \
        -v "$VOLUMES_DIR:/backup" \
        "$HELPER_IMAGE" \
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
: > "$BINDS_DIR/bind-map.txt"
while read -r src; do
    [[ -z "$src" ]] && continue
    if [[ -e "$src" ]]; then
        idx=$((idx + 1))

        # Key the archive name and the bind-map entry on a path RELATIVE to the
        # project root (e.g. dex/config.yaml instead of
        # /home/ubuntu/libcloud_nutanix/dex/config.yaml) so the backup is
        # host/user-portable — restore re-anchors under its own $HOME.
        rel="${src#"$PROJECT_ROOT"/}"
        if [[ "$rel" == "$src" ]]; then
            # Bind source outside the project root — leave it absolute.
            rel="$src"
        fi
        safe_name=$(printf "%04d" "$idx")-$(echo "$rel" | tr '/' '_')

        if [[ -d "$src" ]]; then
            log "  Backing up directory: $src"
        else
            log "  Backing up file: $src"
        fi
        tar --numeric-owner -czf "$BINDS_DIR/${safe_name}.tgz" \
            -C "$(dirname "$src")" "$(basename "$src")"

        # Record idx|relative-path for the restore side (same idx counter used
        # for the archive name, so they can never drift apart).
        printf '%4d|%s\n' "$idx" "$rel" >> "$BINDS_DIR/bind-map.txt"
    else
        warn "  Bind source not found: $src (skipping)"
    fi
done < "$BACKUP_DIR/bind-sources.txt"

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
if [[ -f "$VENV_TARBALL" ]]; then
    echo "Venv tarball:   $VENV_TARBALL ($(du -h "$VENV_TARBALL" | cut -f1))"
fi
echo ""
echo "Next steps:"
echo "  1. Transfer ~/offline/ to the destination machine (scp/rsync)"
echo "  2. On the destination, run restore-system.sh to restore"
echo ""
echo "Manifest:  $BACKUP_DIR/MANIFEST.txt"
echo "Checksums: $BACKUP_DIR/SHA256SUMS"
