#!/usr/bin/env bash
# lldap-user-create.sh
# ====================
# Create a new LLDAP user with a password in one shot.
#
# This is a simplified wrapper: it creates the user via the LLDAP GraphQL
# `createUser` mutation, then sets the password over LDAP via the pure-stdlib
# client (`lldap_set_password.py`). It sources `lldap_common.sh` for the admin
# login, GraphQL helpers, and audit logging.
#
# Usage:
#   lldap-user-create.sh --username <uid> --email <email> \
#       --display-name "Display Name" --password <pw>
#       [--first-name <fn>] [--last-name <ln>]
#       [--skip-if-exists] [--dry-run] [--verbose]
#
# Exit codes:
#   0  user created + password set (or already existed with --skip-if-exists)
#   2  input validation / missing required field
#   3  LLDAP admin authentication failed
#   4  user creation rejected by LLDAP (e.g. already exists)
#   5  network / unexpected error
#   6  user created but password set failed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lldap_common.sh
source "${SCRIPT_DIR}/lldap_common.sh"

# ---------- arg parsing ------------------------------------------------------
OPT_USERNAME=""
OPT_EMAIL=""
OPT_DISPLAY_NAME=""
OPT_PASSWORD=""
OPT_FIRST_NAME=""
OPT_LAST_NAME=""
OPT_SKIP_IF_EXISTS=0
OPT_DRY_RUN=0
VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --username)      OPT_USERNAME="$2";      shift 2 ;;
    --email)         OPT_EMAIL="$2";         shift 2 ;;
    --display-name)  OPT_DISPLAY_NAME="$2";  shift 2 ;;
    --password)      OPT_PASSWORD="$2";      shift 2 ;;
    --first-name)    OPT_FIRST_NAME="$2";    shift 2 ;;
    --last-name)     OPT_LAST_NAME="$2";     shift 2 ;;
    --skip-if-exists) OPT_SKIP_IF_EXISTS=1;  shift ;;
    --dry-run)       OPT_DRY_RUN=1;          shift ;;
    -v|--verbose)    VERBOSE=1;              shift ;;
    -h|--help)
      sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ---------- validation -------------------------------------------------------
err=0
[[ -n "${OPT_USERNAME}"     ]] || { echo "ERROR: --username is required"     >&2; err=1; }
[[ -n "${OPT_EMAIL}"        ]] || { echo "ERROR: --email is required"        >&2; err=1; }
[[ -n "${OPT_DISPLAY_NAME}" ]] || { echo "ERROR: --display-name is required" >&2; err=1; }
[[ -n "${OPT_PASSWORD}"     ]] || { echo "ERROR: --password is required"     >&2; err=1; }
[[ "$err" == "1" ]] && { echo "  Hint: supply via CLI flags; see --help" >&2; exit 2; }

# LLDAP uid rules: lowercase, start with alnum, [a-z0-9._-], 1..63 chars.
if ! [[ "${OPT_USERNAME}" =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]]; then
  echo "ERROR: username must be lowercase, start with alnum, [a-z0-9._-] only" >&2
  exit 2
fi
if ! [[ "${OPT_EMAIL}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
  echo "ERROR: --email does not look valid: ${OPT_EMAIL}" >&2
  exit 2
fi
if [[ ${#OPT_PASSWORD} -lt 8 ]]; then
  echo "ERROR: --password must be at least 8 characters (LLDAP minimum)" >&2
  exit 2
fi

# ---------- authenticate -----------------------------------------------------
lldap_login || exit 3

# ---------- check if user already exists -------------------------------------
if lldap_user_exists "${OPT_USERNAME}"; then
  if [[ "${OPT_SKIP_IF_EXISTS}" == "1" ]]; then
    echo "NOTE: user '${OPT_USERNAME}' already exists; --skip-if-exists set, exiting 0." >&2
    lldap_audit "{\"ts\":\"$(lldap_now)\",\"event\":\"lldap_user_create\",\"actor\":\"${ACTOR}\",\"result\":\"already_exists_skipped\",\"username\":\"${OPT_USERNAME}\",\"email\":\"${OPT_EMAIL}\"}"
    exit 0
  fi
  echo "ERROR: user '${OPT_USERNAME}' already exists (use --skip-if-exists to tolerate)." >&2
  exit 4
fi

# ---------- build createUser mutation ----------------------------------------
echo "Creating LLDAP user '${OPT_USERNAME}' ..." >&2

GRAPHQL_BODY=$(USERNAME="${OPT_USERNAME}" DISPLAY="${OPT_DISPLAY_NAME}" \
  EMAIL="${OPT_EMAIL}" FN="${OPT_FIRST_NAME}" LN="${OPT_LAST_NAME}" \
  python3 - <<'PY'
import json, os
query = """
mutation CreateUser($user: CreateUserInput!) {
  createUser(user: $user) {
    id
    email
    displayName
    firstName
    lastName
    creationDate
  }
}
"""
variables = {
    "user": {
        "id": os.environ["USERNAME"],
        "email": os.environ["EMAIL"],
        "displayName": os.environ["DISPLAY"],
        "firstName": os.environ.get("FN") or "",
        "lastName": os.environ.get("LN") or "",
    },
}
print(json.dumps({"query": query, "variables": variables}))
PY
)

if [[ "${OPT_DRY_RUN}" == "1" ]]; then
  echo "DRY-RUN: would create user then set password via LDAP" >&2
  echo "${GRAPHQL_BODY}" | python3 -m json.tool >&2
  exit 0
fi

# ---------- send createUser mutation -----------------------------------------
RESP_FILE=$(mktemp)
lldap_graphql "${GRAPHQL_BODY}" "${RESP_FILE}"
HTTP="${LLDAP_HTTP_CODE}"
TS="$(lldap_now)"

# ---------- parse response ---------------------------------------------------
PARSED=$(python3 -c '
import json, os, sys
resp = open(sys.argv[1]).read()
try:
    data = json.loads(resp)
except Exception as e:
    print(json.dumps({"_parse_error": str(e)}))
    sys.exit(0)

created = bool(data.get("data", {}).get("createUser"))
errors = data.get("errors")
already = False
if errors:
    msg = " ".join(str(e.get("message","")) for e in errors).lower()
    if any(kw in msg for kw in ("already exists","409","duplicate","unique constraint","uniqueness")):
        already = True

print(json.dumps({"created": created, "already_exists": already, "errors": errors,
    "user": (data.get("data") or {}).get("createUser")}))
' "${RESP_FILE}")

CREATED=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("created"))' <<<"${PARSED}")
ALREADY=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("already_exists"))' <<<"${PARSED}")
ERRORS=$(python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("errors")))' <<<"${PARSED}")
rm -f "${RESP_FILE}"

if [[ "${CREATED}" != "True" ]]; then
  if [[ "${ALREADY}" == "True" ]]; then
    if [[ "${OPT_SKIP_IF_EXISTS}" == "1" ]]; then
      echo "NOTE: user '${OPT_USERNAME}' already exists; --skip-if-exists set." >&2
      lldap_audit "{\"ts\":\"${TS}\",\"event\":\"lldap_user_create\",\"actor\":\"${ACTOR}\",\"result\":\"already_exists_skipped\",\"username\":\"${OPT_USERNAME}\",\"email\":\"${OPT_EMAIL}\"}"
      exit 0
    fi
    echo "ERROR: user '${OPT_USERNAME}' already exists." >&2
    exit 4
  fi
  echo "ERROR: createUser rejected (HTTP ${HTTP})." >&2
  echo "${ERRORS}" >&2
  lldap_audit "{\"ts\":\"${TS}\",\"event\":\"lldap_user_create\",\"actor\":\"${ACTOR}\",\"result\":\"rejected\",\"username\":\"${OPT_USERNAME}\",\"email\":\"${OPT_EMAIL}\",\"http\":${HTTP}}"
  exit 4
fi

NEW_ID=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("user",{}).get("id",""))' <<<"${PARSED}")
echo "OK: created LLDAP user id=${NEW_ID} username=${OPT_USERNAME} email=${OPT_EMAIL}" >&2

# ---------- set password via LDAP --------------------------------------------
echo "Setting initial password via LDAP ..." >&2

user_dn="uid=${OPT_USERNAME},ou=people,${LLDAP_BASE_DN}"
if LLDAP_LDAP_HOST="${LLDAP_LDAP_HOST}" LLDAP_LDAP_PORT="${LLDAP_LDAP_PORT}" \
   LLDAP_BIND_DN="${LLDAP_BIND_DN}" LLDAP_BIND_PW="${LLDAP_ADMIN_PW}" \
   LLDAP_USER_DN="${user_dn}" LLDAP_NEW_PW="${OPT_PASSWORD}" \
   python3 "${SCRIPT_DIR}/lldap_set_password.py" >/dev/null 2>&1; then
  echo "OK: password set for ${OPT_USERNAME}" >&2
  lldap_audit "{\"ts\":\"${TS}\",\"event\":\"lldap_user_create\",\"actor\":\"${ACTOR}\",\"result\":\"created\",\"username\":\"${OPT_USERNAME}\",\"email\":\"${OPT_EMAIL}\",\"display_name\":\"${OPT_DISPLAY_NAME}\",\"password_set\":true,\"http\":${HTTP}}"
  exit 0
else
  echo "ERROR: user ${OPT_USERNAME} was created but password set FAILED." >&2
  echo "       Re-run the password set with lldap-user-password-reset.sh." >&2
  lldap_audit "{\"ts\":\"${TS}\",\"event\":\"lldap_user_create\",\"actor\":\"${ACTOR}\",\"result\":\"created_password_set_failed\",\"username\":\"${OPT_USERNAME}\",\"email\":\"${OPT_EMAIL}\",\"password_set\":false,\"http\":${HTTP}}"
  exit 6
fi
