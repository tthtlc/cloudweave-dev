#!/bin/sh
set -e

# A well-known GET path in the served spec, used only as a readiness probe.
# v4.0 and v4.1+ all expose the AHV VM list at /api/vmm/v{ver}/ahv/config/vms.
READY_PATH="${PRISM_READY_PATH:-/api/vmm/${API_VERSION:-v4.0}/ahv/config/vms}"

echo "Waiting for Prism on ${PRISM_URL:-http://prism:4010} ..."
for i in $(seq 1 30); do
  # -f fails the request on 4xx/5xx, so this only passes once Prism is actually
  # serving the right spec (not merely listening on the TCP port).
  if curl -sf -o /dev/null "${PRISM_URL:-http://prism:4010}${READY_PATH}" 2>/dev/null; then
    echo "Prism is ready (${READY_PATH} -> 200)!"
    break
  fi
  echo "  attempt ${i}/30 - waiting..."
  sleep 2
done

# Generate self-signed TLS certificate for HTTPS
if [ ! -f /app/cert.pem ] || [ ! -f /app/key.pem ]; then
  echo "Generating self-signed TLS certificate..."
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /app/key.pem \
    -out /app/cert.pem \
    -days 3650 \
    -subj "/CN=emulator/O=NutanixEmulator/C=US" 2>/dev/null
  chmod 600 /app/key.pem
  echo "Self-signed cert created (CN=emulator, 10yr validity)"
fi

echo "Starting Nutanix VM emulator shim (HTTPS)..."
exec node /app/server.js
