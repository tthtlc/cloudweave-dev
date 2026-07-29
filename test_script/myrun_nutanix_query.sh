#!/usr/bin/env bash
# Sequentially query every GET endpoint listed in a URL file (default /tmp/oo)
# against the libcloud REST API as the ntnx-admin tenant user.
#
# Auth credential construction mirrors ./myrun_nutanix.sh +
# ./scripts/provision_nutanix.sh:
#   1. ntnx-owner writes per-tenant Nutanix backend creds to Vault
#      (set_tenant_credentials.py, gated by OpenFGA can_manage_credentials).
#   2. ntnx-admin logs into Dex (idp_login), builds the Nutanix
#      X-Provider-Connection (host/port/api_version + auth_binding), validates
#      its token and the backend connection, then runs each GET from the URL
#      file.
#
# Usage:
#   ./myrun_nutanix_query.sh               # reads /tmp/oo
#   ./myrun_nutanix_query.sh /path/to/urls # reads the given file
#   VERBOSE=1 ./myrun_nutanix_query.sh     # log HTTP headers/bodies to stderr
set -euo pipefail

cd "$(dirname "$0")"

URL_FILE="${1:-/tmp/oo}"
[[ -f "${URL_FILE}" ]] || { echo "URL file not found: ${URL_FILE}" >&2; exit 1; }

# --- Backend cloud credentials (per-tenant, written to Vault by the OWNER) ---
# ntnx-owner (owner of tenant:nutanix)
LIBCLOUD_PASSWORD_NTNX_OWNER="SA-9HXuDFerBkabyaDw2tG-t7O-"
# ntnx-admin (admin of tenant:nutanix -> provision/query Nutanix)
LIBCLOUD_PASSWORD_NTNX_ADMIN="${LIBCLOUD_PASSWORD_NTNX_ADMIN:-SA-4ckgB21zNYj4B_cRlh2BFQp-}"

# Step 1: ntnx-owner seeds Nutanix backend creds into Vault.
LIBCLOUD_OIDC_CLIENT_SECRET="HbpzexeVfU0STxDY9f14Td3-T2OfmhTsJIFwXxQrFVs" \
TENANT=nutanix LIBCLOUD_USER=ntnx-owner LIBCLOUD_PASSWORD="${LIBCLOUD_PASSWORD_NTNX_OWNER}" \
    LIBCLOUD_NTNX_USER=admin LIBCLOUD_NTNX_PASSWORD=admin \
    python3 scripts/set_tenant_credentials.py

# Step 2: ntnx-admin runs the sequential query flow (read-only GETs).
export TENANT=nutanix
export CLOUD_PROVIDER=nutanix
export LIBCLOUD_USER=ntnx-admin
export LIBCLOUD_PASSWORD="${LIBCLOUD_PASSWORD_NTNX_ADMIN}"
export VERBOSE="${VERBOSE:-0}"
export URL_FILE

./scripts/query_urls.sh

exit
