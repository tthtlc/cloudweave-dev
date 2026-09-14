#!/usr/bin/env bash
# create_users.sh
# ================
# Idempotently create a pool of generic provisioning users (user01..user30 by
# default) in LLDAP, each with a generated password. These users are inert —
# they hold no OpenFGA tuples — until a superadmin assigns them a company-admin
# or department role via the portal (design_company_department.md §5).
#
# Passwords are persisted to generated/users.env (mode 0600, gitignored) so a
# re-run reuses the same password instead of rotating it (lldap_ensure_user.sh
# resets the password when the user already exists, so re-using is required to
# stay stable).
#
# Usage:
#   ./scripts/create_users.sh
#   ./scripts/create_users.sh --count 30 --prefix user
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LLDAP_DIR="${REPO_ROOT}/lldap"
USERS_ENV="${SCRIPT_DIR}/generated/users.env"

COUNT="${COUNT:-30}"
PREFIX="${PREFIX:-user}"

# ---- helpers ----------------------------------------------------------------
gen_pw() { python3 -c "import secrets; print('PW-'+secrets.token_urlsafe(18))"; }
pw_var() { printf 'LIBCLOUD_%s_%02d_PASSWORD' "$(echo "$PREFIX" | tr '[:lower:]' '[:upper:]')" "$1"; }

ensure_user() {
  docker compose -f "${LLDAP_DIR}/docker-compose.yml" run --rm lldap-tools \
    /scripts/lldap_ensure_user.sh "$@" >/dev/null
}

mkdir -p "$(dirname "${USERS_ENV}")"

# Reuse previously generated passwords so re-runs don't rotate credentials.
if [ -f "${USERS_ENV}" ]; then
  set -a; . "${USERS_ENV}"; set +a
fi

# ---- generate + persist passwords -------------------------------------------
declare -A PW
: > "${USERS_ENV}"
for i in $(seq 1 "${COUNT}"); do
  nn=$(printf '%02d' "$i")
  var="$(pw_var "$i")"
  pw="${!var:-$(gen_pw)}"
  PW["$nn"]="$pw"
  printf '%s=%s\n' "$var" "$pw" >> "${USERS_ENV}"
done
chmod 600 "${USERS_ENV}"

# ---- create users -----------------------------------------------------------
created=0
for i in $(seq 1 "${COUNT}"); do
  nn=$(printf '%02d' "$i")
  uid="${PREFIX}${nn}"
  email="${uid}@libcloud.local"
  name="User ${nn}"
  if ensure_user "$uid" "$email" "$name" "pool" "member" "Provisioning pool user" "${PW[$nn]}"; then
    created=$((created + 1))
  fi
done

echo "Created/verified ${created}/${COUNT} users (${PREFIX}01..$(printf '%02d' "${COUNT}"))."
echo "Passwords persisted to ${USERS_ENV}"
