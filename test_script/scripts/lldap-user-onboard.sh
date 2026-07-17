#!/usr/bin/env bash
# lldap-user-onboard.sh
# =====================
# Create a new LLDAP user account (username, display name, email, initial
# password) via the LLDAP GraphQL `createUser` mutation, then set the initial
# password via an LDAP `userPassword` modify.
#
# Why two steps: this LLDAP version's `createUser` mutation takes only a
# `CreateUserInput` (id/email/displayName/firstName/lastName) — there is no
# password argument and no GraphQL password mutation. The initial password is
# therefore set with a tiny stdlib-only LDAP client
# (scripts/lldap_set_password.py) that binds as the LLDAP admin and issues a
# ModifyRequest replacing `userPassword` (LLDAP hashes the plaintext value
# server-side). No `ldappasswd` / `openldap-clients` / `docker exec` needed —
# only `curl` + `python3`, which the GraphQL step already requires.
#
# Run as a Cloud Admin (a principal holding the LLDAP directory-admin credential
# — i.e. the LLDAP `admin` user or a member of the `lldap_admin` /
# `lldap_password_manager` group). The script authenticates to LLDAP's own JWT
# endpoint (`/auth/simple/login`) and uses the returned JWT as a Bearer token
# against `/api/graphql`. This is the LLDAP management credential, separate from
# the Dex OIDC token used by the libcloud REST / OpenFGA flows.
#
# Inputs (any of):
#   * A parameter file via --file PATH  (key=value lines, or JSON object)
#   * CLI flags: --username --display-name --email --password
#                [--first-name] [--last-name]
#
# This script ONLY creates the account + initial password. Group / role
# assignment is deliberately performed by a separate script
# (`lldap-group-add-member.sh`) so that account creation and role grant can be
# audited independently.
#
# Env (loaded from .env / ../lldap/.env / generated/dex.env):
#   LLDAP_URL                 default http://localhost:${LLDAP_HTTP_PORT:-17170}
#   LLDAP_ADMIN_USER          default admin
#   LLDAP_LDAP_USER_PASS      LLDAP admin password (required)
#   LLDAP_LDAP_BASE_DN        default dc=libcloud,dc=local
#   LLDAP_LDAP_HOST           default localhost
#   LLDAP_LDAP_PORT           default 3890
#   LLDAP_AUDIT_LOG           optional path; structured JSONL audit line appended
#   LLDAP_ONBOARD_ACTOR       optional; defaults to ${LLDAP_ADMIN_USER}
#
# Exit codes:
#   0  user created + initial password set (or already existed with --skip-if-exists)
#   2  input validation / missing required field
#   3  LLDAP admin authentication failed
#   4  createUser rejected by LLDAP (e.g. user already exists)
#   5  network / unexpected error
#   6  user created but initial-password set failed (retry just the password set)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Load env without sourcing common.sh: common.sh's password resolver exits when
# LIBCLOUD_USER has no matching case (the LLDAP `admin` user is not a libcloud
# principal), and this script never needs a libcloud/Dex login. We only need the
# LLDAP settings from .env / ../lldap/.env / generated/dex.env.
_load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" != *=* ]] && continue
    local key="${line%%=*}" val="${line#*=}"
    # Use a full if/then (not `[[ ... ]] && export`) so the statement always
    # returns 0; otherwise a key that is already set leaves the loop body's
    # last status non-zero and `set -e` aborts the whole script.
    if [[ -z "${!key:-}" ]]; then export "${key}=${val}"; fi
  done < "$file"
}
_load_env_file "${REPO_ROOT}/.env"
_load_env_file "${REPO_ROOT}/lldap/.env" 1 2>/dev/null || true
_load_env_file "${REPO_ROOT}/test_script/generated/dex.env" 1 2>/dev/null || true

LLDAP_URL="${LLDAP_URL:-http://localhost:${LLDAP_HTTP_PORT:-17170}}"
LLDAP_ADMIN_USER="${LLDAP_ADMIN_USER:-admin}"
LLDAP_ADMIN_PW="${LLDAP_LDAP_USER_PASS:-${LLDAP_ADMIN_PASSWORD:-}}"
LLDAP_BASE_DN="${LLDAP_LDAP_BASE_DN:-${LLDAP_BASE_DN:-dc=libcloud,dc=local}}"
LLDAP_LDAP_HOST="${LLDAP_LDAP_HOST:-localhost}"
LLDAP_LDAP_PORT="${LLDAP_LDAP_PORT:-3890}"
LLDAP_AUDIT_LOG="${LLDAP_AUDIT_LOG:-${REPO_ROOT}/generated/lldap_audit.log}"
ACTOR="${LLDAP_ONBOARD_ACTOR:-${LLDAP_ADMIN_USER}}"
LLDAP_BIND_DN="uid=${LLDAP_ADMIN_USER},ou=people,${LLDAP_BASE_DN}"

# ---------- arg parsing ------------------------------------------------------
PARAM_FILE=""
OPT_USERNAME=""
OPT_DISPLAY_NAME=""
OPT_EMAIL=""
OPT_PASSWORD=""
OPT_FIRST_NAME=""
OPT_LAST_NAME=""
OPT_SKIP_IF_EXISTS=0
OPT_DRY_RUN=0
VERBOSE_FLAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)          PARAM_FILE="$2"; shift 2 ;;
    --username)      OPT_USERNAME="$2"; shift 2 ;;
    --display-name)  OPT_DISPLAY_NAME="$2"; shift 2 ;;
    --email)         OPT_EMAIL="$2"; shift 2 ;;
    --password)      OPT_PASSWORD="$2"; shift 2 ;;
    --first-name)    OPT_FIRST_NAME="$2"; shift 2 ;;
    --last-name)     OPT_LAST_NAME="$2"; shift 2 ;;
    --skip-if-exists) OPT_SKIP_IF_EXISTS=1; shift ;;
    --dry-run)       OPT_DRY_RUN=1; shift ;;
    -v|--verbose)    VERBOSE_FLAG="--verbose"; VERBOSE=1; shift ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ---------- parameter file merge ---------------------------------------------
# A --file may provide any of the same keys. CLI flags win over the file.
if [[ -n "${PARAM_FILE}" ]]; then
  [[ -f "${PARAM_FILE}" ]] || { echo "ERROR: parameter file not found: ${PARAM_FILE}" >&2; exit 2; }
  FILE_USERNAME="" FILE_DISPLAY_NAME="" FILE_EMAIL="" FILE_PASSWORD=""
  FILE_FIRST_NAME="" FILE_LAST_NAME=""
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${PARAM_FILE}" >/dev/null 2>&1; then
    eval "$(USERNAME="${PARAM_FILE}" python3 - <<'PY'
import json, os, shlex
d = json.load(open(os.environ['USERNAME']))
def emit(k, v):
    if v is None: return
    print(f"FILE_{k}={shlex.quote(str(v))}")
emit("USERNAME",      d.get("username") or d.get("uid") or d.get("id"))
emit("DISPLAY_NAME",  d.get("display_name") or d.get("displayName"))
emit("EMAIL",         d.get("email") or d.get("mail"))
emit("PASSWORD",      d.get("password") or d.get("initial_password"))
emit("FIRST_NAME",    d.get("first_name") or d.get("firstName"))
emit("LAST_NAME",     d.get("last_name") or d.get("lastName"))
PY
)"
  else
    # key=value file
    while IFS='=' read -r k v; do
      [[ "$k" =~ ^[[:space:]]*# ]] && continue
      [[ -z "$k" ]] && continue
      case "$k" in
        username|uid|id)            FILE_USERNAME="$v" ;;
        display_name|displayName)   FILE_DISPLAY_NAME="$v" ;;
        email|mail)                 FILE_EMAIL="$v" ;;
        password|initial_password)  FILE_PASSWORD="$v" ;;
        first_name|firstName)       FILE_FIRST_NAME="$v" ;;
        last_name|lastName)         FILE_LAST_NAME="$v" ;;
      esac
    done < "${PARAM_FILE}"
  fi
  [[ -z "${OPT_USERNAME}"     ]] && OPT_USERNAME="${FILE_USERNAME}"
  [[ -z "${OPT_DISPLAY_NAME}" ]] && OPT_DISPLAY_NAME="${FILE_DISPLAY_NAME}"
  [[ -z "${OPT_EMAIL}"        ]] && OPT_EMAIL="${FILE_EMAIL}"
  [[ -z "${OPT_PASSWORD}"     ]] && OPT_PASSWORD="${FILE_PASSWORD}"
  [[ -z "${OPT_FIRST_NAME}"   ]] && OPT_FIRST_NAME="${FILE_FIRST_NAME}"
  [[ -z "${OPT_LAST_NAME}"    ]] && OPT_LAST_NAME="${FILE_LAST_NAME}"
fi

# ---------- validation -------------------------------------------------------
err=0
[[ -n "${OPT_USERNAME}"     ]] || { echo "ERROR: --username is required" >&2; err=1; }
[[ -n "${OPT_DISPLAY_NAME}" ]] || { echo "ERROR: --display-name is required" >&2; err=1; }
[[ -n "${OPT_EMAIL}"        ]] || { echo "ERROR: --email is required" >&2; err=1; }
[[ -n "${OPT_PASSWORD}"     ]] || { echo "ERROR: --password is required" >&2; err=1; }
[[ "$err" == "1" ]] && { echo "  (supply via CLI flags or --file PATH; see --help)" >&2; exit 2; }

# LLDAP uid constraints: lowercase alphanumeric + dash/underscore, 1..63 chars.
if ! [[ "${OPT_USERNAME}" =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]]; then
  echo "ERROR: username must be lowercase, start with alnum, and use only [a-z0-9._-]" >&2
  exit 2
fi
if ! [[ "${OPT_EMAIL}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
  echo "ERROR: --email does not look like a valid address: ${OPT_EMAIL}" >&2
  exit 2
fi
if [[ ${#OPT_PASSWORD} -lt 8 ]]; then
  echo "ERROR: --password must be at least 8 characters (LLDAP minimum)" >&2
  exit 2
fi

[[ -n "${LLDAP_ADMIN_PW}" ]] || {
  echo "ERROR: LLDAP_LDAP_USER_PASS is empty — source ../lldap/.env or run ./setup.sh" >&2
  exit 2
}

# ---------- helpers ----------------------------------------------------------
graphql_post() {
  # $1 = JSON body, $2 = output file for response body.
  # Sets LLDAP_HTTP_CODE in the CURRENT shell (caller must NOT invoke us via
  # command substitution, or the variable won't propagate).
  local body="$1" out="$2"
  LLDAP_HTTP_CODE=$(curl -sS -X POST "${LLDAP_URL}/api/graphql" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${LLDAP_JWT}" \
    -d "${body}" \
    -o "${out}" -w "%{http_code}") || LLDAP_HTTP_CODE="000"
}

emit_audit() {
  # $1 = JSON object string
  local line="$1"
  echo "${line}" >&2
  mkdir -p "$(dirname "${LLDAP_AUDIT_LOG}")"
  echo "${line}" >> "${LLDAP_AUDIT_LOG}"
}

# Set the user's initial password by binding as the LLDAP admin and issuing an
# LDAP ModifyRequest that replaces the user's `userPassword` attribute. This is
# implemented in pure-stdlib Python (scripts/lldap_set_password.py) so the
# script has NO dependency on `ldappasswd` / `openldap-clients` / `docker exec`
# — only `curl` + `python3`, which the GraphQL step already requires. LLDAP
# hashes the plaintext value server-side on write (same as `ldappasswd -s`).
# Prints nothing on success; returns non-zero on failure.
set_initial_password() {
  local user_dn="uid=${OPT_USERNAME},ou=people,${LLDAP_BASE_DN}"
  LLDAP_LDAP_HOST="${LLDAP_LDAP_HOST}" LLDAP_LDAP_PORT="${LLDAP_LDAP_PORT}" \
    LLDAP_BIND_DN="${LLDAP_BIND_DN}" LLDAP_BIND_PW="${LLDAP_ADMIN_PW}" \
    LLDAP_USER_DN="${user_dn}" LLDAP_NEW_PW="${OPT_PASSWORD}" \
    python3 "${SCRIPT_DIR}/lldap_set_password.py"
}

# ---------- step 1: authenticate to LLDAP ------------------------------------
echo "Authenticating to LLDAP as ${LLDAP_ADMIN_USER} ..." >&2
LOGIN_BODY=$(USERNAME="${LLDAP_ADMIN_USER}" PW="${LLDAP_ADMIN_PW}" python3 -c '
import json, os
print(json.dumps({"username": os.environ["USERNAME"], "password": os.environ["PW"]}))
')
LOGIN_RESP=$(mktemp)
LOGIN_CODE=$(curl -sS -X POST "${LLDAP_URL}/auth/simple/login" \
  -H "Content-Type: application/json" -d "${LOGIN_BODY}" \
  -o "${LOGIN_RESP}" -w "%{http_code}") || LOGIN_CODE="000"
if [[ "${LOGIN_CODE}" != "200" ]]; then
  echo "ERROR: LLDAP admin login failed (HTTP ${LOGIN_CODE}):" >&2
  cat "${LOGIN_RESP}" >&2
  rm -f "${LOGIN_RESP}"
  exit 3
fi
LLDAP_JWT=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' < "${LOGIN_RESP}")
rm -f "${LOGIN_RESP}"
[[ -n "${LLDAP_JWT}" ]] || { echo "ERROR: LLDAP login response had no token" >&2; exit 3; }

# ---------- step 2: build + send createUser mutation -------------------------
echo "Creating LLDAP user '${OPT_USERNAME}' (no groups will be assigned) ..." >&2

GRAPHQL_BODY=$(USERNAME="${OPT_USERNAME}" DISPLAY="${OPT_DISPLAY_NAME}" \
  EMAIL="${OPT_EMAIL}" FN="${OPT_FIRST_NAME}" LN="${OPT_LAST_NAME}" \
  python3 - <<'PY'
import json, os
# This LLDAP version: createUser(user: CreateUserInput!) — no password arg.
# The initial password is set separately via LDAP (see set_initial_password).
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
  echo "DRY-RUN: would POST createUser mutation to ${LLDAP_URL}/api/graphql, then" >&2
  echo "         LDAP ModifyRequest uid=${OPT_USERNAME},ou=people,${LLDAP_BASE_DN}" >&2
  echo "${GRAPHQL_BODY}" | python3 -m json.tool >&2
  exit 0
fi

RESP_FILE=$(mktemp)
graphql_post "${GRAPHQL_BODY}" "${RESP_FILE}"
HTTP="${LLDAP_HTTP_CODE}"
RESP=$(cat "${RESP_FILE}")
rm -f "${RESP_FILE}"

# ---------- step 3: parse response -------------------------------------------
PARSED=$(RESP="${RESP}" python3 - <<'PY'
import json, os, sys
resp = os.environ["RESP"]
try:
    data = json.loads(resp)
except Exception as e:
    print(json.dumps({"_parse_error": str(e), "_raw": resp[:500]}))
    sys.exit(0)
out = {
    "created": None,
    "errors": None,
    "already_exists": False,
    "user": None,
}
if isinstance(data, dict) and data.get("errors"):
    errs = data["errors"]
    out["errors"] = errs
    msg = " ".join(str(e.get("message", "")) for e in errs).lower()
    # LLDAP reports a duplicate as a database UNIQUE-constraint violation
    # (e.g. "UNIQUE constraint failed: users.lowercase_email" / "...users.id"),
    # or in some builds as "user already exists" / HTTP 409.
    if ("already exists" in msg or "409" in msg or "duplicate" in msg
            or "unique constraint" in msg or "uniqueness" in msg):
        out["already_exists"] = True
data2 = data.get("data") if isinstance(data, dict) else None
if isinstance(data2, dict) and data2.get("createUser"):
    out["created"] = True
    out["user"] = data2["createUser"]
print(json.dumps(out))
PY
)

CREATED=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("created"))' <<<"${PARSED}")
ALREADY=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("already_exists"))' <<<"${PARSED}")
ERRORS=$(python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("errors")))' <<<"${PARSED}")

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ "${CREATED}" == "True" ]]; then
  NEW_ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("user",{}).get("id",""))' <<<"${PARSED}")
  echo "OK: created LLDAP user id=${NEW_ID} username=${OPT_USERNAME} email=${OPT_EMAIL}" >&2
  echo "Setting initial password via LDAP ModifyRequest (pure-stdlib client) ..." >&2
  if set_initial_password; then
    echo "OK: initial password set for ${OPT_USERNAME}" >&2
    emit_audit "{\"ts\":\"${TS}\",\"event\":\"lldap_create_user\",\"actor\":\"${ACTOR}\",\"result\":\"created\",\"username\":\"${OPT_USERNAME}\",\"email\":\"${OPT_EMAIL}\",\"display_name\":\"${OPT_DISPLAY_NAME}\",\"password_set\":true,\"groups_assigned\":false,\"http\":${HTTP}}"
    exit 0
  else
    echo "ERROR: user ${OPT_USERNAME} was created but the initial-password set FAILED." >&2
    echo "       The account exists with no usable password. Re-run the password set with" >&2
    echo "       lldap-user-password-reset.sh, or re-run this script with --skip-if-exists." >&2
    emit_audit "{\"ts\":\"${TS}\",\"event\":\"lldap_create_user\",\"actor\":\"${ACTOR}\",\"result\":\"created_password_set_failed\",\"username\":\"${OPT_USERNAME}\",\"email\":\"${OPT_EMAIL}\",\"display_name\":\"${OPT_DISPLAY_NAME}\",\"password_set\":false,\"groups_assigned\":false,\"http\":${HTTP}}"
    exit 6
  fi
fi

if [[ "${ALREADY}" == "True" ]]; then
  if [[ "${OPT_SKIP_IF_EXISTS}" == "1" ]]; then
    echo "NOTE: user '${OPT_USERNAME}' already exists; --skip-if-exists set, exiting 0." >&2
    emit_audit "{\"ts\":\"${TS}\",\"event\":\"lldap_create_user\",\"actor\":\"${ACTOR}\",\"result\":\"already_exists_skipped\",\"username\":\"${OPT_USERNAME}\",\"email\":\"${OPT_EMAIL}\",\"groups_assigned\":false,\"http\":${HTTP}}"
    exit 0
  fi
  echo "ERROR: user '${OPT_USERNAME}' already exists in LLDAP (use --skip-if-exists to tolerate)." >&2
  echo "${ERRORS}" >&2
  emit_audit "{\"ts\":\"${TS}\",\"event\":\"lldap_create_user\",\"actor\":\"${ACTOR}\",\"result\":\"already_exists\",\"username\":\"${OPT_USERNAME}\",\"email\":\"${OPT_EMAIL}\",\"groups_assigned\":false,\"http\":${HTTP}}"
  exit 4
fi

echo "ERROR: createUser rejected by LLDAP (HTTP ${HTTP})." >&2
echo "${ERRORS}" >&2
echo "${RESP}" >&2
emit_audit "{\"ts\":\"${TS}\",\"event\":\"lldap_create_user\",\"actor\":\"${ACTOR}\",\"result\":\"rejected\",\"username\":\"${OPT_USERNAME}\",\"email\":\"${OPT_EMAIL}\",\"groups_assigned\":false,\"http\":${HTTP}}"
# Distinguish transport failure from a clean GraphQL rejection.
if [[ "${HTTP}" =~ ^(2|3) ]]; then exit 4; else exit 5; fi
