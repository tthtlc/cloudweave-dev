#!/usr/bin/env bash
#
# setup-bastion-connection.sh
#
# Creates an SSH config for connecting to a private server through a bastion host,
# and copies the private key to ~/.ssh/ with correct permissions.
#
# Usage:
#   ./setup-bastion-connection.sh \
#       --bastion-ip 47.129.237.95 \
#       --private-ip 10.0.16.241 \
#       --key-file /path/to/private-key.pem \
#       [--bastion-user ubuntu] \
#       [--private-user ubuntu] \
#       [--bastion-name bastion] \
#       [--private-name internal] \
#       [--key-name libcloud-private-key.pem]
#
# Then connect with:
#   ssh internal
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
BASTION_USER="ubuntu"
PRIVATE_USER="ubuntu"
BASTION_NAME="bastion"
PRIVATE_NAME="internal"
KEY_NAME=""
SSH_DIR="$HOME/.ssh"
CONFIG_FILE="$SSH_DIR/config"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat << 'EOF'
Usage: setup-bastion-connection.sh [OPTIONS]

Required:
  --bastion-ip IP       Public IP of the bastion host
  --private-ip IP       Private IP of the internal server
  --key-file PATH       Path to the private key file to copy into ~/.ssh/

Optional:
  --bastion-user USER   Username for bastion (default: ubuntu)
  --private-user USER   Username for internal server (default: ubuntu)
  --bastion-name NAME   SSH Host alias for bastion (default: bastion)
  --private-name NAME   SSH Host alias for internal server (default: internal)
  --key-name NAME       Filename for the copied key in ~/.ssh/
                        (default: same as source filename)
  -h, --help            Show this help message
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
BASTION_IP=""
PRIVATE_IP=""
KEY_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bastion-ip)    BASTION_IP="$2";   shift 2 ;;
        --private-ip)    PRIVATE_IP="$2";   shift 2 ;;
        --key-file)      KEY_FILE="$2";     shift 2 ;;
        --bastion-user)  BASTION_USER="$2"; shift 2 ;;
        --private-user)  PRIVATE_USER="$2"; shift 2 ;;
        --bastion-name)  BASTION_NAME="$2"; shift 2 ;;
        --private-name)  PRIVATE_NAME="$2"; shift 2 ;;
        --key-name)      KEY_NAME="$2";     shift 2 ;;
        -h|--help)       usage ;;
        *) echo "ERROR: Unknown option: $1"; usage ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate required arguments
# ---------------------------------------------------------------------------
if [[ -z "$BASTION_IP" ]]; then
    echo "ERROR: --bastion-ip is required"
    usage
fi
if [[ -z "$PRIVATE_IP" ]]; then
    echo "ERROR: --private-ip is required"
    usage
fi
if [[ -z "$KEY_FILE" ]]; then
    echo "ERROR: --key-file is required"
    usage
fi

# ---------------------------------------------------------------------------
# Validate key file exists and is readable
# ---------------------------------------------------------------------------
if [[ ! -f "$KEY_FILE" ]]; then
    echo "ERROR: Key file not found: $KEY_FILE"
    exit 1
fi
if [[ ! -r "$KEY_FILE" ]]; then
    echo "ERROR: Key file is not readable: $KEY_FILE"
    exit 1
fi

# ---------------------------------------------------------------------------
# Determine key filename in ~/.ssh/
# ---------------------------------------------------------------------------
if [[ -z "$KEY_NAME" ]]; then
    KEY_NAME="$(basename "$KEY_FILE")"
fi
KEY_DEST="$SSH_DIR/$KEY_NAME"

# ---------------------------------------------------------------------------
# Ensure ~/.ssh/ exists with correct permissions
# ---------------------------------------------------------------------------
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# ---------------------------------------------------------------------------
# Copy the private key
# ---------------------------------------------------------------------------
echo ""
echo "============================================================================"
echo "  Bastion SSH Connection Setup"
echo "============================================================================"
echo ""
echo "  Bastion (jump):  $BASTION_USER@$BASTION_IP   → alias: $BASTION_NAME"
echo "  Private (dest):  $PRIVATE_USER@$PRIVATE_IP       → alias: $PRIVATE_NAME"
echo "  Key source:      $KEY_FILE"
echo "  Key destination: $KEY_DEST"
echo ""

# Copy the key if it's not already in place or is different
if [[ -f "$KEY_DEST" ]]; then
    if cmp -s "$KEY_FILE" "$KEY_DEST"; then
        echo "Key already in place and identical: $KEY_DEST"
    else
        echo "WARNING: $KEY_DEST already exists and differs."
        echo "Overwrite? [y/N] "
        read -r REPLY
        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
            cp "$KEY_FILE" "$KEY_DEST"
            echo "Key overwritten."
        else
            echo "Skipping key copy. Using existing key."
        fi
    fi
else
    cp "$KEY_FILE" "$KEY_DEST"
    echo "Key copied to $KEY_DEST"
fi

chmod 600 "$KEY_DEST"
echo "Permissions set to 600 on $KEY_DEST"

# ---------------------------------------------------------------------------
# Verify the key looks like a valid private key
# ---------------------------------------------------------------------------
if ! grep -q "PRIVATE KEY" "$KEY_DEST"; then
    echo "WARNING: $KEY_DEST does not appear to contain a private key"
fi

# ---------------------------------------------------------------------------
# Back up existing SSH config if present
# ---------------------------------------------------------------------------
if [[ -f "$CONFIG_FILE" ]]; then
    BACKUP="$CONFIG_FILE.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$CONFIG_FILE" "$BACKUP"
    echo "Backed up existing config to: $BACKUP"
fi

# ---------------------------------------------------------------------------
# Check if our host entries already exist
# ---------------------------------------------------------------------------
if [[ -f "$CONFIG_FILE" ]] && grep -q "^Host $BASTION_NAME$" "$CONFIG_FILE"; then
    echo ""
    echo "WARNING: Host '$BASTION_NAME' already exists in $CONFIG_FILE"
    echo "The existing config will be preserved. Manual review may be needed."
fi

if [[ -f "$CONFIG_FILE" ]] && grep -q "^Host $PRIVATE_NAME$" "$CONFIG_FILE"; then
    echo "WARNING: Host '$PRIVATE_NAME' already exists in $CONFIG_FILE"
    echo "The existing config will be preserved. Manual review may be needed."
fi

# ---------------------------------------------------------------------------
# Append the SSH config entries
# ---------------------------------------------------------------------------
echo ""
echo "Appending SSH config to $CONFIG_FILE ..."

cat >> "$CONFIG_FILE" << SSHCONFIG

# ---------------------------------------------------------------------------
# Bastion + private-server connection (generated $(date))
#   Docs: $(dirname "$0")/how_to_setup_bastion_private_connection.md
# ---------------------------------------------------------------------------
Host $BASTION_NAME
    HostName $BASTION_IP
    User $BASTION_USER
    IdentityFile $KEY_DEST
    IdentitiesOnly yes

Host $PRIVATE_NAME
    HostName $PRIVATE_IP
    User $PRIVATE_USER
    IdentityFile $KEY_DEST
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ProxyJump $BASTION_NAME
SSHCONFIG

chmod 600 "$CONFIG_FILE"

# ---------------------------------------------------------------------------
# Quick connectivity test (optional)
# ---------------------------------------------------------------------------
echo ""
echo "----------------------------------------------------------------------------"
echo "  Testing connection to bastion ($BASTION_NAME)..."
echo "----------------------------------------------------------------------------"

if ssh -o ConnectTimeout=10 -o BatchMode=yes "$BASTION_NAME" "echo OK" 2>/dev/null; then
    echo "✓ Bastion connection successful"
else
    echo "✗ Bastion connection FAILED"
    echo "  Run: ssh -vvvvvvvvvvv $BASTION_NAME"
    echo "  to debug."
fi

echo ""
echo "----------------------------------------------------------------------------"
echo "  Testing connection to private server ($PRIVATE_NAME) through bastion..."
echo "----------------------------------------------------------------------------"

if ssh -o ConnectTimeout=15 -o BatchMode=yes "$PRIVATE_NAME" "hostname" 2>/dev/null; then
    echo "✓ Private server connection successful"
else
    echo "✗ Private server connection FAILED"
    echo "  Run: ssh -vvvvvvvvvvv $PRIVATE_NAME"
    echo "  to debug."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "============================================================================"
echo "  Setup complete."
echo ""
echo "  Connect to bastion:        ssh $BASTION_NAME"
echo "  Connect to private server: ssh $PRIVATE_NAME"
echo ""
echo "  Reference: $SSH_DIR/how_to_setup_bastion_private_connection.md"
echo "============================================================================"
echo ""
