#!/usr/bin/env bash
# lldap-user-password-reset.sh
# ============================
# Reset an LLDAP user's password to a generated value and print it once to
# stdout for secure hand-off. The password is NOT written to the audit log.
#
# By default a strong random password is generated (32 chars, urlsafe). Supply
# --password to set a specific value instead. The password is set via the
# pure-stdlib LDAP client (scripts/lldap_set_password.py) — no ldappasswd /
# openldap-clients dependency — binding as the LLDAP admin and replacing the
# user's `userPassword` (LLDAP hashes the plaintext server-side).
#
# Usage:
#   lldap-user-password-reset.sh --username <uid> [--password <pw>] [--dry-run]
#
# Env (via scripts/lldap_common.sh):
#   LLDAP_URL, LLDAP_ADMIN_USER, LLDAP_LDAP_USER_PASS, LLDAP_BASE_DN,
#   LLDAP_LDAP_HOST, LLDAP_LDAP_PORT, LLDAP_AUDIT_LOG, LLDAP_ACTOR
#
# Exit codes:
#   0  password reset; new password printed on stdout
#   2  input validation / unknown user
#   3  LLDAP admin auth failed
#   4  password set rejected by LDAP (e.g. bind / modify failure)
#   5  network / unexpected error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lldap_common.sh
source "${SCRIPT_DIR}/lldap_common.sh"

OPT_USERNAME=""; OPT_PASSWORD=""; OPT_DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --username) OPT_USERNAME="$2"; shift 2 ;;
    --password) OPT_PASSWORD="$2"; shift 2 ;;
    --dry-run)  OPT_DRY_RUN=1; shift ;;
    -h|--help)  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "${OPT_USERNAME}" ]] || { echo "ERROR: --username is required" >&2; exit 2; }
if ! [[ "${OPT_USERNAME}" =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]]; then
  echo "ERROR: --username must match LLDAP uid rules [a-z0-9._-]" >&2; exit 2
fi

# Generate a password if one was not supplied.
generated=0
if [[ -z "${OPT_PASSWORD}" ]]; then
  OPT_PASSWORD=$(python3 -c 'import secrets, string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(32)))')
  generated=1
fi
if [[ ${#OPT_PASSWORD} -lt 8 ]]; then
  echo "ERROR: --password must be at least 8 characters (LLDAP minimum)" >&2; exit 2
fi

lldap_login || exit 3

if ! lldap_user_exists "${OPT_USERNAME}"; then
  echo "ERROR: user '${OPT_USERNAME}' does not exist in LLDAP" >&2; exit 2
fi

if [[ "${OPT_DRY_RUN}" == "1" ]]; then
  echo "DRY-RUN: would set password for '${OPT_USERNAME}' (generated=${generated})" >&2
  exit 0
fi

user_dn="uid=${OPT_USERNAME},ou=people,${LLDAP_BASE_DN}"
if ! LLDAP_LDAP_HOST="${LLDAP_LDAP_HOST}" LLDAP_LDAP_PORT="${LLDAP_LDAP_PORT}" \
     LLDAP_BIND_DN="${LLDAP_BIND_DN}" LLDAP_BIND_PW="${LLDAP_ADMIN_PW}" \
     LLDAP_USER_DN="${user_dn}" LLDAP_NEW_PW="${OPT_PASSWORD}" \
     python3 "${SCRIPT_DIR}/lldap_set_password.py" >/dev/null 2>&1; then
  echo "ERROR: password set failed for '${OPT_USERNAME}' (see scripts/lldap_set_password.py)" >&2
  lldap_audit "{\"ts\":\"$(lldap_now)\",\"event\":\"lldap_user_password_reset\",\"actor\":\"${ACTOR}\",\"username\":\"${OPT_USERNAME}\",\"result\":\"failed\"}"
  exit 4
fi

lldap_audit "{\"ts\":\"$(lldap_now)\",\"event\":\"lldap_user_password_reset\",\"actor\":\"${ACTOR}\",\"username\":\"${OPT_USERNAME}\",\"generated\":${generated},\"result\":\"success\"}"
echo "OK: password reset for '${OPT_USERNAME}' (generated=${generated})." >&2
# Print the new password ONCE to stdout for secure hand-off. Caller must capture.
printf '%s\n' "${OPT_PASSWORD}"
exit 0
