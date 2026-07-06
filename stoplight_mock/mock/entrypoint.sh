#!/bin/sh
set -e

echo "Waiting for Prism on ${PRISM_URL:-http://prism:4010} ..."
for i in $(seq 1 30); do
  # Prism mock returns 404 on / and non-existent paths, so check the spec root
  # or any well-known API path that exists in the served OpenAPI document
  if curl -s -o /dev/null "${PRISM_URL:-http://prism:4010}/api/iam/v4.0/authz/roles" 2>/dev/null; then
    echo "Prism is ready (API path ok)!"
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
