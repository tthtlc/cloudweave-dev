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
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# common.sh resolves LIBCLOUD_PASSWORD from LIBCLOUD_USER via a case statement
# during sourcing. Set the principal BEFORE sourcing so the `superadmin)` branch
# applies (it pulls LIBCLOUD_SUPERADMIN_PASSWORD from ../dex/generated/dex.env).
# Without this, LIBCLOUD_USER defaults to cloud-admin, which has no case branch,
# and common.sh exits with "Password required for user cloud-admin".
LIBCLOUD_USER=superadmin
export LIBCLOUD_USER

# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh" >/dev/null 2>&1 || {
  echo "FATAL: cannot source scripts/common.sh — run ./setup.sh first." >&2
  exit 2
}

SA_PW="${LIBCLOUD_SUPERADMIN_PASSWORD:-${LIBCLOUD_PASSWORD_SUPERADMIN:-}}"
if [[ -z "${SA_PW}" && -f "${ROOT}/generated/dex.env" ]]; then
  SA_PW="$(grep -E '^LIBCLOUD_SUPERADMIN_PASSWORD=' "${ROOT}/generated/dex.env" | cut -d= -f2- || true)"
fi
if [[ -z "${SA_PW}" ]]; then
  echo "FATAL: superadmin password not found. Run ./setup.sh first (it creates the" >&2
  echo "       LLDAP superadmin user and writes the password to generated/dex.env)." >&2
  exit 2
fi

echo "Logging in to Dex as superadmin ..." >&2
LIBCLOUD_USER=superadmin LIBCLOUD_PASSWORD="${SA_PW}" \
  python3 "${SCRIPT_DIR}/idp_login.py" >"${ROOT}/generated/tokens/superadmin.jwt" 2>"${ROOT}/generated/tokens/superadmin.login.err" || {
    echo "FATAL: superadmin Dex login failed:" >&2
    cat "${ROOT}/generated/tokens/superadmin.login.err" >&2
    exit 1
  }

export SUPERADMIN_JWT="$(cat "${ROOT}/generated/tokens/superadmin.jwt")"
if [[ -z "${SUPERADMIN_JWT}" ]]; then
  echo "FATAL: superadmin login produced an empty token" >&2
  exit 1
fi

echo "Verifying superadmin JWT ..." >&2
if ! SUPERADMIN_JWT="${SUPERADMIN_JWT}" python3 "${SCRIPT_DIR}/verify_superadmin_jwt.py"; then
  exit 1
fi

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Run directly: print the JWT so callers can capture it.
  echo "${SUPERADMIN_JWT}"
else
  echo "SUPERADMIN_JWT exported (length=${#SUPERADMIN_JWT})." >&2
fi
