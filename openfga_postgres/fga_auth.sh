#!/usr/bin/env bash
# fga_auth.sh — extracted authentication + config for the OpenFGA curl scripts.
#
# Sourced (never executed) by list_users.sh. Exports:
#   FGA_API_URL    (env override, else generated/fga.env, else http://localhost:8080)
#   FGA_STORE_ID   (env override, else generated/fga.env)
#   FGA_MODEL_ID   (env override, else generated/fga.env; may be empty)
#   FGA_BEARER     bearer token for the Authorization header
#
# Token resolution mirrors enumerate_openfga.py and
# test_script/scripts/openfga_common.sh:
#   1. $FGA_API_TOKEN        (preshared-key mode / explicit override)
#   2. $SUPERADMIN_JWT       (set by test_script/scripts/superadmin_auth.sh)
#   3. <repo_root>/generated/tokens/superadmin.jwt  (if present and not expired)
# Otherwise: run ./test_script/scripts/superadmin_auth.sh first.
set -euo pipefail

SCRIPT_DIR_FGA="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_FGA="$(cd "${SCRIPT_DIR_FGA}/.." && pwd)"
FGA_ENV_FILE="${SCRIPT_DIR_FGA}/generated/fga.env"
FGA_TOKEN_FILE="${REPO_ROOT_FGA}/generated/tokens/superadmin.jwt"

# ---- config: env vars win over generated/fga.env ----------------------------
_fga_env_val() {  # _fga_env_val <key> : value from fga.env or ""
  [[ -f "${FGA_ENV_FILE}" ]] || { echo ""; return 0; }
  local line
  line=$(grep -E "^$1=" "${FGA_ENV_FILE}" | tail -n1 || true)
  echo "${line#*=}"
}

FGA_API_URL="${FGA_API_URL:-$(_fga_env_val FGA_API_URL)}"
FGA_API_URL="${FGA_API_URL:-http://localhost:8080}"
FGA_STORE_ID="${FGA_STORE_ID:-$(_fga_env_val FGA_STORE_ID)}"
FGA_MODEL_ID="${FGA_MODEL_ID:-$(_fga_env_val FGA_MODEL_ID)}"
export FGA_API_URL FGA_STORE_ID FGA_MODEL_ID

# ---- auth: bearer token ------------------------------------------------------
_fga_jwt_exp() {  # print exp epoch or "" if unparseable
  python3 - "$1" <<'PY' 2>/dev/null
import sys, json, base64
t = sys.argv[1].strip()
try:
    p = t.split('.')[1]; p += '=' * (-len(p) % 4)
    print(int(json.loads(base64.urlsafe_b64decode(p)).get('exp', 0)))
except Exception:
    print("")
PY
}

_fga_resolve_token() {
  if [[ -n "${FGA_API_TOKEN:-}" ]]; then echo "${FGA_API_TOKEN}"; return 0; fi
  if [[ -n "${SUPERADMIN_JWT:-}" ]]; then echo "${SUPERADMIN_JWT}"; return 0; fi
  if [[ -s "${FGA_TOKEN_FILE}" ]]; then
    local tok exp now
    tok=$(cat "${FGA_TOKEN_FILE}")
    exp=$(_fga_jwt_exp "$tok")
    now=$(date +%s)
    if [[ -n "$exp" && "$exp" -gt "$now" ]]; then echo "$tok"; return 0; fi
  fi
  return 1
}

if ! FGA_BEARER=$(_fga_resolve_token); then
  echo "FATAL: no OpenFGA bearer token. Set FGA_API_TOKEN / SUPERADMIN_JWT," >&2
  echo "       ensure ${FGA_TOKEN_FILE} is unexpired, or run" >&2
  echo "       ./test_script/scripts/superadmin_auth.sh first." >&2
  exit 3
fi
export FGA_BEARER
