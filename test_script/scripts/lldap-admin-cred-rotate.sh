#!/usr/bin/env bash
# lldap-admin-cred-rotate.sh
# ==========================
# Rotate the LLDAP admin bind password:
#   1. generate a new strong secret
#   2. update LLDAP (bind as admin with the OLD password, LDAP-modify the
#      admin's own userPassword to the new value — LLDAP hashes it server-side)
#   3. verify connectivity by logging in with the NEW password
#   4. on success, persist the new password to Vault at secret/lldap/admin
#      (KV v2) and (by default) to ../lldap/.env so host-side scripts that
#      source it keep working
#
# Order note: the spec lists "write to Vault, update LLDAP, verify". We update
# LLDAP and verify FIRST, then persist to Vault, so Vault only ever stores a
# verified-good password (avoids a mismatch if the LLDAP update fails).
#
# Refuses to run unless a Vault root token is available (VAULT_ROOT_TOKEN env
# or ../vault/generated/vault.env).
#
# Usage:
#   lldap-admin-cred-rotate.sh [--dry-run] [--no-update-env] [--print-password]
#
# --print-password : print the new password to stdout once (default: do NOT
#                    print; the password lives in Vault + ../lldap/.env only).
# --no-update-env  : do not rewrite ../lldap/.env (Vault is still updated).
#
# Env (via scripts/lldap_common.sh):
#   LLDAP_URL, LLDAP_ADMIN_USER, LLDAP_LDAP_USER_PASS, LLDAP_BASE_DN,
#   LLDAP_LDAP_HOST, LLDAP_LDAP_PORT, LLDAP_AUDIT_LOG, LLDAP_ACTOR
#   VAULT_ADDR, VAULT_ROOT_TOKEN  (../vault/generated/vault.env)
#   LLDAP_ROTATE_UPDATE_ENV=1 (default) — rewrite ../lldap/.env
#   LLDAP_ROTATE_VAULT_PATH=secret/data/lldap/admin (KV v2 data path)
#
# Exit codes:
#   0  rotated + verified + persisted
#   2  preconditions missing (no old password / no vault token)
#   3  old admin login failed (cannot bind to rotate)
#   4  LLDAP password update failed
#   5  verify (new login) failed — LLDAP was updated but persistence skipped
#   6  Vault write failed
#   7  ../lldap/.env rewrite failed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lldap_common.sh
source "${SCRIPT_DIR}/lldap_common.sh"

OPT_DRY_RUN=0; OPT_PRINT=0; OPT_UPDATE_ENV=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)        OPT_DRY_RUN=1; shift ;;
    --print-password) OPT_PRINT=1; shift ;;
    --no-update-env)  OPT_UPDATE_ENV=0; shift ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

old_pw="${LLDAP_ADMIN_PW}"
if [[ -z "${old_pw}" ]]; then
  echo "ERROR: current LLDAP admin password (LLDAP_LDAP_USER_PASS) is empty — run ./setup.sh first" >&2
  exit 2
fi

: "${VAULT_ADDR:=${VAULT_PUBLIC_ADDR:-http://localhost:8200}}"
: "${VAULT_ROOT_TOKEN:=}"
if [[ -z "${VAULT_ROOT_TOKEN}" ]]; then
  echo "ERROR: VAULT_ROOT_TOKEN is empty — source ../vault/generated/vault.env or run ./setup.sh" >&2
  exit 2
fi
vault_path="${LLDAP_ROTATE_VAULT_PATH:-secret/data/lldap/admin}"
update_env="${LLDAP_ROTATE_UPDATE_ENV:-${OPT_UPDATE_ENV}}"

# 1. Generate a new password.
new_pw=$(python3 -c 'import secrets, string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(32)))')
echo "Generated new admin password (${#new_pw} chars)." >&2

if [[ "${OPT_DRY_RUN}" == "1" ]]; then
  echo "DRY-RUN: would update LLDAP admin password, verify, then write to Vault (${vault_path})" >&2
  [[ "${update_env}" == "1" ]] && echo "         and update ../lldap/.env" >&2
  exit 0
fi

# 2. Update LLDAP: bind as admin with the OLD password, replace admin's own
#    userPassword. lldap_set_password.py does bind + ModifyRequest.
admin_dn="uid=${LLDAP_ADMIN_USER},ou=people,${LLDAP_BASE_DN}"
echo "Updating LLDAP admin password via LDAP ModifyRequest ..." >&2
if ! LLDAP_LDAP_HOST="${LLDAP_LDAP_HOST}" LLDAP_LDAP_PORT="${LLDAP_LDAP_PORT}" \
     LLDAP_BIND_DN="${admin_dn}" LLDAP_BIND_PW="${old_pw}" \
     LLDAP_USER_DN="${admin_dn}" LLDAP_NEW_PW="${new_pw}" \
     python3 "${SCRIPT_DIR}/lldap_set_password.py" >/dev/null 2>&1; then
  echo "ERROR: LLDAP admin password update failed (LDAP bind/modify rejected)." >&2
  lldap_audit "{\"ts\":\"$(lldap_now)\",\"event\":\"lldap_admin_cred_rotate\",\"actor\":\"${ACTOR}\",\"result\":\"update_failed\"}"
  exit 4
fi

# 3. Verify by logging in with the NEW password.
verify_body=$(USERNAME="${LLDAP_ADMIN_USER}" PW="${new_pw}" python3 -c '
import json, os
print(json.dumps({"username": os.environ["USERNAME"], "password": os.environ["PW"]}))
')
vresp=$(mktemp)
vcode=$(curl -sS -X POST "${LLDAP_URL}/auth/simple/login" -H "Content-Type: application/json" \
  -d "${verify_body}" -o "${vresp}" -w "%{http_code}") || vcode="000"
vtok=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' < "${vresp}" 2>/dev/null || echo "")
rm -f "${vresp}"
if [[ "${vcode}" != "200" || -z "${vtok}" ]]; then
  echo "ERROR: verify login with the NEW password failed (http=${vcode})." >&2
  echo "       LLDAP admin password WAS updated but is unverified. Persistence skipped." >&2
  lldap_audit "{\"ts\":\"$(lldap_now)\",\"event\":\"lldap_admin_cred_rotate\",\"actor\":\"${ACTOR}\",\"result\":\"verify_failed\",\"http\":${vcode:-0}}"
  exit 5
fi
echo "OK: verified new admin password (login succeeded)." >&2

# 4. Persist to Vault (KV v2): { "data": { "password": ..., "rotated_at": ... } }.
ts="$(lldap_now)"
vault_body=$(PW="${new_pw}" TS="${ts}" USER="${LLDAP_ADMIN_USER}" python3 -c '
import json, os
print(json.dumps({"data": {"password": os.environ["PW"], "rotated_at": os.environ["TS"],
                            "admin_user": os.environ["USER"]}}))
')
vcode=$(curl -sS -X POST "${VAULT_ADDR}/v1/${vault_path}" \
  -H "X-Vault-Token: ${VAULT_ROOT_TOKEN}" -H "Content-Type: application/json" \
  -d "${vault_body}" -o /dev/null -w "%{http_code}") || vcode="000"
if [[ "${vcode}" != "200" && "${vcode}" != "204" ]]; then
  echo "ERROR: Vault write to ${vault_path} failed (http=${vcode})." >&2
  echo "       LLDAP password is rotated and verified but NOT persisted to Vault." >&2
  lldap_audit "{\"ts\":\"${ts}\",\"event\":\"lldap_admin_cred_rotate\",\"actor\":\"${ACTOR}\",\"result\":\"vault_write_failed\",\"http\":${vcode:-0}}"
  exit 6
fi
echo "OK: new admin password written to Vault (${vault_path})." >&2

# 5. Optionally rewrite ../lldap/.env so host-side scripts pick up the new pw.
env_status="skipped"
if [[ "${update_env}" == "1" ]]; then
  env_file="${REPO_ROOT}/lldap/.env"
  if [[ -f "${env_file}" ]]; then
    if PW="${new_pw}" FILE="${env_file}" python3 - <<'PY'
import os, re, sys
path = os.environ["FILE"]
new_pw = os.environ["PW"]
txt = open(path).read()
if re.search(r'^LLDAP_LDAP_USER_PASS=', txt, re.M):
    txt = re.sub(r'^LLDAP_LDAP_USER_PASS=.*$', 'LLDAP_LDAP_USER_PASS=' + new_pw, txt, count=1, flags=re.M)
else:
    txt = txt.rstrip() + f"\nLLDAP_LDAP_USER_PASS={new_pw}\n"
open(path, "w").write(txt)
PY
    then
      env_status="updated"
      echo "OK: ../lldap/.env updated with new LLDAP_LDAP_USER_PASS." >&2
    else
      echo "ERROR: failed to rewrite ../lldap/.env." >&2
      lldap_audit "{\"ts\":\"${ts}\",\"event\":\"lldap_admin_cred_rotate\",\"actor\":\"${ACTOR}\",\"result\":\"env_write_failed\",\"vault\":\"ok\"}"
      exit 7
    fi
  else
    echo "WARN: ../lldap/.env not found; skipping env update (Vault holds the new password)." >&2
    env_status="env_not_found"
  fi
fi

lldap_audit "{\"ts\":\"${ts}\",\"event\":\"lldap_admin_cred_rotate\",\"actor\":\"${ACTOR}\",\"result\":\"success\",\"vault_path\":\"${vault_path}\",\"env\":\"${env_status}\"}"
echo "OK: LLDAP admin credential rotation complete." >&2
[[ "${OPT_PRINT}" == "1" ]] && printf '%s\n' "${new_pw}"
exit 0
