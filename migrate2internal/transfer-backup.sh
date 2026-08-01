#!/usr/bin/env bash
# ============================================================================
# transfer-backup.sh — Copy the ~/offline/ backup set from the source machine
# to the isolated destination (internal) machine through the bastion host.
#
# Run this on the SOURCE machine (167.172.94.123) AFTER backup-system.sh
# completes successfully.
#
# This uses the SSH ProxyJump from ~/.ssh/config:
#   source → bastion (13.212.232.220) → internal (10.0.16.227)
#
# Usage:
#   chmod +x transfer-backup.sh
#   ./transfer-backup.sh
#
# Options:
#   ./transfer-backup.sh --dry-run    Show what would be transferred
#   ./transfer-backup.sh --resume     Resume interrupted transfer (rsync)
# ============================================================================

set -euo pipefail

OFFLINE_DIR="$HOME/offline"
DEST_HOST="internal"          # Matches Host alias in ~/.ssh/config
DEST_USER="ubuntu"
DEST_PATH="/home/ubuntu/offline"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[XFER]${NC} $(date '+%H:%M:%S') $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%H:%M:%S') $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*" >&2; }

DRY_RUN=0
RESUME=0
RSYNC_OPTS="-avzP --progress"

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1; RSYNC_OPTS="$RSYNC_OPTS --dry-run" ;;
        --resume)  RESUME=1 ;;
        *) err "Unknown argument: $arg"; exit 1 ;;
    esac
done

# ------------------------------------------------------------------
# 0. Preflight
# ------------------------------------------------------------------
log "=== Transfer preflight ==="

if [[ "$DRY_RUN" == "1" ]]; then
    warn "DRY-RUN mode — nothing will actually be transferred"
fi

if [[ ! -d "$OFFLINE_DIR/docker-debs" ]]; then
    err "docker-debs directory not found — run backup-system.sh first"
    exit 1
fi

if [[ ! -d "$OFFLINE_DIR/backup" ]]; then
    err "backup directory not found — run backup-system.sh first"
    exit 1
fi

log "Testing SSH connectivity to destination through bastion..."
if ssh -o ConnectTimeout=10 -o BatchMode=yes "$DEST_HOST" 'echo OK' 2>/dev/null; then
    log "SSH to $DEST_HOST successful"
else
    err "Cannot reach $DEST_HOST via SSH."
    err ""
    err "Check:"
    err "  1. ~/.ssh/config has 'Host bastion' and 'Host internal' entries"
    err "  2. ~/.ssh/libcloud-private-key.pem exists and has correct permissions (600)"
    err "  3. The bastion host is reachable: ssh bastion echo OK"
    err ""
    exit 1
fi

# ------------------------------------------------------------------
# Transfer function (defined before use — bash reads sequentially)
# ------------------------------------------------------------------
run_rsync() {
    rsync $RSYNC_OPTS \
        -e "ssh" \
        "$OFFLINE_DIR/" \
        "${DEST_HOST}:${DEST_PATH}/"
}

# ------------------------------------------------------------------
# 1. Show what will be transferred
# ------------------------------------------------------------------
log "=== Backup set size ==="
du -sh "$OFFLINE_DIR"
echo ""
du -sh "$OFFLINE_DIR"/*/  2>/dev/null || true
echo ""

# ------------------------------------------------------------------
# 2. Create destination directory
# ------------------------------------------------------------------
log "=== Creating destination directory ==="
if [[ "$DRY_RUN" != "1" ]]; then
    ssh "$DEST_HOST" "mkdir -p $DEST_PATH"
fi
log "Destination: $DEST_USER@$DEST_HOST:$DEST_PATH"

# ------------------------------------------------------------------
# 3. Transfer using rsync (resumable, compressed)
# ------------------------------------------------------------------
log "=== Transferring backup files ==="

if [[ "$RESUME" == "1" ]]; then
    log "Resume mode: partial files will be kept and resumed"
    RSYNC_OPTS="$RSYNC_OPTS --partial"
fi

log "Transfer started at $(date)"
log "This may take a while depending on image/volume sizes..."

if run_rsync; then
    log "=== Transfer complete ==="
    log ""
    log "Files transferred to: $DEST_USER@$DEST_HOST:$DEST_PATH"
    log ""
    log "Next step — on the destination machine ($DEST_HOST), run:"
    log "  ssh $DEST_HOST"
    log "  cd ~/offline"
    log "  # Copy restore-system.sh to the destination, then:"
    log "  chmod +x restore-system.sh"
    log "  ./restore-system.sh"
else
    err "Transfer failed (exit code $?)."
    err "Re-run with --resume to continue an interrupted transfer."
    exit 1
fi

