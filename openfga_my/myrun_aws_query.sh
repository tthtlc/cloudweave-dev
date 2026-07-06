#!/usr/bin/env bash
# Sequentially query every GET endpoint listed in a URL file (default /tmp/oo)
# against the libcloud REST API as the aws-admin tenant user.
#
# Auth credential construction mirrors ./myrun_aws_admin.sh +
# ./scripts/provision_aws.sh:
#   1. aws-owner writes per-tenant AWS backend creds to Vault
#      (set_tenant_credentials.py, gated by OpenFGA can_manage_credentials).
#   2. aws-admin logs into Dex (idp_login), builds the AWS
#      X-Provider-Connection (region + auth_binding), validates its token and
#      the backend connection, then runs each GET from the URL file.
#
# Usage:
#   ./myrun_aws_query.sh               # reads /tmp/oo
#   ./myrun_aws_query.sh /path/to/urls # reads the given file
#   VERBOSE=1 ./myrun_aws_query.sh     # log HTTP headers/bodies to stderr
set -euo pipefail

cd "$(dirname "$0")"

URL_FILE="${1:-/tmp/oo}"
[[ -f "${URL_FILE}" ]] || { echo "URL file not found: ${URL_FILE}" >&2; exit 1; }

# Refresh OpenFGA's cached Dex JWKS before any OpenFGA-dependent call. Dex
# rotates its signing keys every 6h (storage: memory); a stale OpenFGA keyset
# makes every Check fail with `invalid_claims`. Throttled + skippable.
./scripts/openfga_ensure_fresh.sh

# --- Backend cloud credentials (per-tenant, written to Vault by the OWNER) ---
AWS_ACCESS_KEY=AKIAYHGEH2P7SNGEPLZH
AWS_SECRET_ACCESS_KEY=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
LIBCLOUD_PASSWORD_AWS_OWNER="SA-Jv07tZKzzFB85mKAL_rbphi_"  # owner of tenant:aws
# aws-admin (admin of tenant:aws -> provision/query AWS)
LIBCLOUD_PASSWORD_AWS_ADMIN="${LIBCLOUD_PASSWORD_AWS_ADMIN:-SA-YxB5zqiYyA8M0mscsjfOkuWd}"

# Step 1: aws-owner seeds AWS backend creds into Vault.
LIBCLOUD_OIDC_CLIENT_SECRET="HbpzexeVfU0STxDY9f14Td3-T2OfmhTsJIFwXxQrFVs" \
TENANT=aws LIBCLOUD_USER=aws-owner LIBCLOUD_PASSWORD="${LIBCLOUD_PASSWORD_AWS_OWNER}" \
    LIBCLOUD_AWS_KEY="${AWS_ACCESS_KEY}" LIBCLOUD_AWS_SECRET="${AWS_SECRET_ACCESS_KEY}" \
    python3 scripts/set_tenant_credentials.py

# Step 2: aws-admin runs the sequential query flow (read-only GETs).
export TENANT=aws
export CLOUD_PROVIDER=aws
export LIBCLOUD_USER=aws-admin
export LIBCLOUD_PASSWORD="${LIBCLOUD_PASSWORD_AWS_ADMIN}"
export VERBOSE="${VERBOSE:-0}"
export URL_FILE

./scripts/query_urls.sh

exit
