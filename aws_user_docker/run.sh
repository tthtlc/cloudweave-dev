#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run.sh  –  convenience wrapper (run from the host)
#
# Usage:
#   ./run.sh <username> [profile_name]
#
# Example:
#   ./run.sh ec2-admin
#   ./run.sh ec2-admin my-ec2-profile
#
# After it completes, the credentials are in ./aws_output/{credentials,config}.
# Merge them into your own files or use them via:
#   export AWS_SHARED_CREDENTIALS_FILE=$(pwd)/aws_output/credentials
#   export AWS_CONFIG_FILE=$(pwd)/aws_output/config
#   export AWS_PROFILE=my-ec2-profile
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

# Ensure the output directory exists *before* Docker mounts it (avoids
# Docker creating it as root).
mkdir -p ./aws_output

# Build the image (cached after first run)
docker compose build

# Run the container
docker compose run --rm aws-bootstrap "$@"
