#!/usr/bin/env bash
# lldap_common.sh — shared helpers for the LLDAP admin scripts (Group 1).
#
# Sourced (never executed) by lldap-user-*.sh / lldap-group-*.sh /
# lldap-audit-*.sh / lldap-admin-cred-rotate.sh. It loads .env, resolves LLDAP
# connection settings, provides admin JWT login + a GraphQL POST helper, a
# structured JSONL audit emitter, and small introspection-derived lookups
# (group-id-by-name, user-exists).
#
# Why this exists instead of scripts/common.sh: common.sh's LIBCLOUD_PASSWORD
# resolver exits when LIBCLOUD_USER has no matching case (the LLDAP `admin`
# user is not a libcloud principal), and these scripts never need a libcloud/
# Dex login — only the LLDAP management credential. Mirrors the approach taken
# by lldap-user-onboard.sh.
#
# Contract for callers (set -euo pipefail is assumed):
#   lldap_login                       # sets LLDAP_JWT; returns 3 on auth failure
#   lldap_graphql <body-json> <out>   # POST /api/graphql; sets LLDAP_HTTP_CODE
#   lldap_audit <json-line>           # stderr + append to LLDAP_AUDIT_LOG
#   lldap_group_id_by_name <name>     # prints group id (int) or empty
#   lldap_user_exists <userId>        # returns 0 if exists, 1 if not
#   lldap_now                         # prints ISO-8601 UTC timestamp

# Resolve SCRIPT_DIR/ROOT for the common case of a direct `source`.
[[ -n "${SCRIPT_DIR:-}" ]] || SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${ROOT:-}" ]] || ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_lldap_load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" != *=* ]] && continue
    local key="${line%%=*}" val="${line#*=}"
    # Full if/then (not `[[ ]] && export`) so a key that is already set does
    # not leave the loop body's last status non-zero under `set -e`.
    if [[ -z "${!key:-}" ]]; then export "${key}=${val}"; fi
  done < "$file"
  return 0
}
_lldap_load_env_file "${ROOT}/.env"
_lldap_load_env_file "${ROOT}/../lldap/.env" 2>/dev/null || true
_lldap_load_env_file "${ROOT}/generated/dex.env" 2>/dev/null || true
_lldap_load_env_file "${ROOT}/../vault/generated/vault.env" 2>/dev/null || true

: "${LLDAP_URL:=http://localhost:${LLDAP_HTTP_PORT:-17170}}"
: "${LLDAP_ADMIN_USER:=admin}"
: "${LLDAP_ADMIN_PW:=${LLDAP_LDAP_USER_PASS:-${LLDAP_ADMIN_PASSWORD:-}}}"
: "${LLDAP_BASE_DN:=${LLDAP_LDAP_BASE_DN:-${LLDAP_BASE_DN:-dc=libcloud,dc=local}}}"
: "${LLDAP_LDAP_HOST:=localhost}"
: "${LLDAP_LDAP_PORT:=3890}"
: "${LLDAP_AUDIT_LOG:=${ROOT}/generated/lldap_audit.log}"
: "${ACTOR:=${LLDAP_ACTOR:-${LLDAP_ADMIN_USER}}}"
LLDAP_BIND_DN="uid=${LLDAP_ADMIN_USER},ou=people,${LLDAP_BASE_DN}"

LLDAP_JWT=""
LLDAP_HTTP_CODE=""

lldap_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Login as the LLDAP admin; export LLDAP_JWT. Returns 0 on success, 3 on
# failure (caller is expected to `lldap_login || exit 3`).
lldap_login() {
  if [[ -z "${LLDAP_ADMIN_PW}" ]]; then
    echo "ERROR: LLDAP_LDAP_USER_PASS is empty — source ../lldap/.env or run ./setup.sh" >&2
    return 3
  fi
  local body resp code
  body=$(USERNAME="${LLDAP_ADMIN_USER}" PW="${LLDAP_ADMIN_PW}" python3 -c '
import json, os
print(json.dumps({"username": os.environ["USERNAME"], "password": os.environ["PW"]}))
')
  resp=$(mktemp)
  code=$(curl -sS -X POST "${LLDAP_URL}/auth/simple/login" \
    -H "Content-Type: application/json" -d "${body}" \
    -o "${resp}" -w "%{http_code}") || code="000"
  if [[ "${code}" != "200" ]]; then
    echo "ERROR: LLDAP admin login failed (HTTP ${code}):" >&2
    cat "${resp}" >&2
    rm -f "${resp}"
    return 3
  fi
  LLDAP_JWT=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' < "${resp}")
  rm -f "${resp}"
  if [[ -z "${LLDAP_JWT}" ]]; then
    echo "ERROR: LLDAP login response had no token" >&2
    return 3
  fi
  return 0
}

# POST a GraphQL request body to /api/graphql using the current LLDAP_JWT.
# $1 = JSON body string, $2 = output file for the response body.
# Sets LLDAP_HTTP_CODE in the current shell (do NOT call via command substitution).
lldap_graphql() {
  local body="$1" out="$2"
  LLDAP_HTTP_CODE=$(curl -sS -X POST "${LLDAP_URL}/api/graphql" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${LLDAP_JWT}" \
    -d "${body}" -o "${out}" -w "%{http_code}") || LLDAP_HTTP_CODE="000"
}

# Emit a structured JSONL audit line to stderr AND append to LLDAP_AUDIT_LOG.
lldap_audit() {
  local line="$1"
  echo "${line}" >&2
  mkdir -p "$(dirname "${LLDAP_AUDIT_LOG}")"
  echo "${line}" >> "${LLDAP_AUDIT_LOG}"
}

# Print the integer id of a group by its displayName, or empty if not found.
lldap_group_id_by_name() {
  local name="$1" out id
  out=$(mktemp)
  lldap_graphql '{"query":"{ groups { id displayName } }"}' "$out"
  id=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
gs = (d.get("data") or {}).get("groups") or []
name = sys.argv[2]
print(next((str(g["id"]) for g in gs if g.get("displayName") == name), ""))
' "$out" "$name" 2>/dev/null || true)
  rm -f "$out"
  echo "${id}"
}

# Return 0 if the LLDAP user exists, 1 if not. Sets LLDAP_HTTP_CODE.
lldap_user_exists() {
  local uid="$1" body out
  body=$(LLDAP_UID="$uid" python3 -c '
import json, os
print(json.dumps({"query": "{ user(userId: \"%s\") { id } }" % os.environ["LLDAP_UID"]}))
')
  out=$(mktemp)
  lldap_graphql "$body" "$out"
  local exists
  exists=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
u = (d.get("data") or {}).get("user")
print("1" if u and u.get("id") else "0")
' "$out" 2>/dev/null || echo 0)
  rm -f "$out"
  [[ "$exists" == "1" ]]
}

# Extract GraphQL errors from a response file as a compact JSON string (or "null").
lldap_graphql_errors() {
  local out="$1"
  python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("errors")))' "$out" 2>/dev/null || echo "null"
}
