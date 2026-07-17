#!/usr/bin/env bash
# openapi_rest_test.sh
# ====================
# Thin wrapper that loads the same credentials overall_provision_test.sh uses
# (dex/generated/dex.env + openfga_postgres/generated/fga.env) and runs the
# OpenAPI-driven REST test harness (openapi_rest_test.py).
#
# Read-only by default (exercises every GET endpoint + auth/connection/providers
# + expected-denial checks). Set FULL=1 to also run the full CRUD lifecycle
# (create -> read -> update -> power -> delete) for every resource, with
# automatic cleanup — mirroring PROVISION=1 in provision_aws.sh /
# provision_nutanix.sh.
#
# Usage:
#   ./test_script/scripts/openapi_rest_test.sh
#   FULL=1 ./test_script/scripts/openapi_rest.sh
#   TENANTS=aws ./test_script/scripts/openapi_rest_test.sh
#   VERBOSE=1 FULL=1 ./test_script/scripts/openapi_rest_test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

load_env() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" != *=* ]] && continue
    local key="${line%%=*}"
    local val="${line#*=}"
    # Don't let empty placeholders (e.g. repo-root .env template) clobber real
    # values already exported from dex.env / fga.env.
    if [[ -n "$val" || -z "${!key+x}" ]]; then
      export "${key}=${val}"
    fi
  done < "$file"
}

# Same credentials overall_provision_test.sh sources on line 1.
load_env "${REPO_ROOT}/dex/generated/dex.env"
load_env "${REPO_ROOT}/openfga_postgres/generated/fga.env"
load_env "${REPO_ROOT}/.env"

# Token cache shared with the provision/deprovision scripts (idp_login.py
# defaults to a CWD-relative generated/tokens; pin it to the repo root so the
# cache is found regardless of where this wrapper is invoked from).
export IDP_TOKEN_CACHE_DIR="${IDP_TOKEN_CACHE_DIR:-${REPO_ROOT}/generated/tokens}"
export LIBCLOUD_REST_URL="${LIBCLOUD_REST_URL:-http://localhost:8765}"

exec python3 "${SCRIPT_DIR}/openapi_rest_test.py" "$@"
