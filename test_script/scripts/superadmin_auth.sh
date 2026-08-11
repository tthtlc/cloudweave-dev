#!/usr/bin/env bash
# superadmin_auth.sh
# ==================
# Perform a real Dex OIDC login as the LLDAP user `superadmin` and export the
# resulting JWT as SUPERADMIN_JWT. The JWT is the bootstrap credential that
# gates Vault seeding, OpenFGA policy/privilege changes, and LLDAP user
# create/modify/delete.
#
# Usage (source it so SUPERADMIN_JWT is exported into your shell):
#   source ./scripts/superadmin_auth.sh
#
# Or run it directly to print the JWT on stdout (also exports into a temp env
# file the caller can `source`):
#   ./scripts/superadmin_auth.sh   # prints JWT + verifies it
#
# Requires: ./setup.sh has run (generated/dex.env with LIBCLOUD_SUPERADMIN_PASSWORD).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIBCLOUD_USER=superadmin
export LIBCLOUD_USER

# Self-contained: load .env + generated/dex.env so LIBCLOUD_SUPERADMIN_PASSWORD
# (and Dex client creds used by idp_login.py) are available. This used to rely on
# ../scripts/common.sh, but that file is not present in the Postgres project and
# its hard FGA_STORE_ID/FGA_MODEL_ID guards make it unusable here anyway —
# setup.sh calls this script BEFORE OpenFGA bootstrap writes those IDs.
_load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" != *=* ]] && continue
    local key="${line%%=*}"
    local val="${line#*=}"
    if [[ -z "${!key:-}" ]]; then
      export "${key}=${val}"
    fi
  done < "$file"
}
_load_env_file "${REPO_ROOT}/.env"
_load_env_file "${REPO_ROOT}/dex/generated/dex.env"
_load_env_file "${REPO_ROOT}/test_script/generated/dex.env"

SA_PW="${LIBCLOUD_SUPERADMIN_PASSWORD:-${LIBCLOUD_PASSWORD_SUPERADMIN:-}}"
if [[ -z "${SA_PW}" && -f "${REPO_ROOT}/test_script/generated/dex.env" ]]; then
  SA_PW="$(grep -E '^LIBCLOUD_SUPERADMIN_PASSWORD=' "${REPO_ROOT}/test_script/generated/dex.env" | cut -d= -f2- || true)"
fi
if [[ -z "${SA_PW}" ]]; then
  echo "FATAL: superadmin password not found. Run ./setup.sh first (it creates the" >&2
  echo "       LLDAP superadmin user and writes the password to generated/dex.env)." >&2
  exit 2
fi

echo "Logging in to Dex as superadmin ..." >&2
LIBCLOUD_USER=superadmin LIBCLOUD_PASSWORD="${SA_PW}" \
  python3 "${SCRIPT_DIR}/idp_login.py" >"${REPO_ROOT}/generated/tokens/superadmin.jwt" 2>"${REPO_ROOT}/generated/tokens/superadmin.login.err" || {
    echo "FATAL: superadmin Dex login failed:" >&2
    cat "${REPO_ROOT}/generated/tokens/superadmin.login.err" >&2
    exit 1
  }

export SUPERADMIN_JWT="$(cat "${REPO_ROOT}/generated/tokens/superadmin.jwt")"
if [[ -z "${SUPERADMIN_JWT}" ]]; then
  echo "FATAL: superadmin login produced an empty token" >&2
  exit 1
fi

echo "Verifying superadmin JWT ..." >&2
# Run JWT verification inside identity-service (which has the `cryptography`
# package) rather than on the host, so setup.sh has no host Python dependency
# beyond the stdlib used by idp_login.py.
if ! echo "${SUPERADMIN_JWT}" | docker exec -i \
    -e SUPERADMIN_JWT="${SUPERADMIN_JWT}" \
    identity-service \
    python3 /opt/libcloud-scripts/scripts/verify_superadmin_jwt.py; then
  exit 1
fi

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Run directly: print the JWT so callers can capture it.
  echo "${SUPERADMIN_JWT}"
else
  echo "SUPERADMIN_JWT exported (length=${#SUPERADMIN_JWT})." >&2
fi
