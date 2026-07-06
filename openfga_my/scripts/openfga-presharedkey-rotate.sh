#!/usr/bin/env bash
# openfga-presharedkey-rotate.sh — rotate the OpenFGA preshared API key.
#
# Cloud Owner tool. Generates a new high-entropy preshared key, stores it in
# Vault at secret/openfga/apikey (KV v2), updates the OpenFGA server config and
# the libcloud REST client config to use the new key, and (with --apply) rolls
# the affected containers so the change takes effect, then verifies.
#
# In this deployment OpenFGA runs in OIDC mode (Dex JWTs); the preshared key is
# an additional accepted authn method (OPENFGA_AUTHN_PRESHARED_KEYS) and the
# credential the libcloud REST API uses to call OpenFGA (FGA_API_TOKEN). Rotating
# it therefore requires updating both sides and a rolling restart.
#
# Safety: without --apply the script only updates Vault + the env files and
# prints restart instructions (no disruption). --apply restarts containers.
#
# Usage:
#   openfga-presharedkey-rotate.sh [--apply] [--actor <user>] [--dry-run]
#       [--vault-token <token>] [--vault-path secret/data/openfga/apikey]
#
# Env (loaded from generated/vault.env): VAULT_ADDR, VAULT_ROOT_TOKEN.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=openfga_common.sh
source "${SCRIPT_DIR}/openfga_common.sh"

# Load vault env (VAULT_ROOT_TOKEN) if present.
for f in "${ROOT}/generated/vault.env" "${ROOT}/.env"; do
  [[ -f "$f" ]] || continue
  while IFS='=' read -r k v; do
    case "$k" in ""|\#*) continue;; esac
    [[ -z "${!k:-}" ]] && export "$k=$v" || true
  done < "$f"
done

APPLY=0
DRY_RUN=0
ACTOR="${LIBCLOUD_USER}"
VAULT_PATH="${OPENFGA_VAULT_PATH:-secret/data/openfga/apikey}"
VAULT_TOKEN_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --actor) ACTOR="$2"; shift 2;;
    --vault-token) VAULT_TOKEN_ARG="$2"; shift 2;;
    --vault-path) VAULT_PATH="$2"; shift 2;;
    -h|--help) sed -n '2,20p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
VT="${VAULT_TOKEN_ARG:-${VAULT_ROOT_TOKEN:-${VAULT_TOKEN:-}}}"
[[ -n "$VT" ]] || { echo "FATAL: no Vault token (set VAULT_ROOT_TOKEN or pass --vault-token)." >&2; exit 2; }

NEW_KEY=$(openssl rand -hex 32 2>/dev/null || python3 -c 'import secrets; print(secrets.token_hex(32))')
NOW_ISO=$(fga_now)
OPENFGA_ENV="${ROOT}/../openfga/.env"
LIBCLOUD_REST_ENV="${ROOT}/../libcloud.rest/.env"

rotate_record() {  # <status>
  local status="$1"
  fga_audit "{\"ts\":\"${NOW_ISO}\",\"actor\":\"${ACTOR}\",\"action\":\"presharedkey-rotate\",\"vault_path\":\"${VAULT_PATH}\",\"result\":\"${status}\",\"apply\":${APPLY}}"
}

echo "Rotating OpenFGA preshared key (vault=${VAULT_PATH}, apply=${APPLY})"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] new key (not applied): ${NEW_KEY}" >&2
  echo "[dry-run] would write Vault ${VAULT_PATH}, update ${OPENFGA_ENV} + ${LIBCLOUD_REST_ENV}" >&2
  [[ "$APPLY" -eq 1 ]] && echo "[dry-run] would restart openfga + ${LIBCLOUD_REST_CONTAINER:-libcloud-rest-api}" >&2
  rotate_record "dry-run"
  exit 0
fi

# 1. Store new key in Vault (KV v2).
VAULT_RESP=$(curl -sS -X POST -H "X-Vault-Token: ${VT}" -H "Content-Type: application/json" \
  -d "{\"data\":{\"apikey\":\"${NEW_KEY}\",\"rotated_at\":\"${NOW_ISO}\",\"rotated_by\":\"${ACTOR}\"}}" \
  "${VAULT_ADDR}/v1/${VAULT_PATH}" -w "\n%{http_code}" 2>&1) || VAULT_RESP="$VAULT_RESP"
VAULT_HTTP=$(printf '%s' "$VAULT_RESP" | tail -1)
VAULT_BODY=$(printf '%s' "$VAULT_RESP" | sed '$d')
if [[ "$VAULT_HTTP" != "200" && "$VAULT_HTTP" != "204" ]]; then
  echo "FATAL: Vault write to ${VAULT_PATH} failed (HTTP ${VAULT_HTTP}): ${VAULT_BODY}" >&2
  rotate_record "vault-write-error"
  exit 4
fi
echo "  Vault: wrote new key to ${VAULT_PATH} (HTTP ${VAULT_HTTP})"

# 2. Verify the key round-trips from Vault.
READ_BODY=$(curl -sS -H "X-Vault-Token: ${VT}" "${VAULT_ADDR}/v1/${VAULT_PATH}" 2>/dev/null || echo "")
READ_KEY=$(printf '%s' "$READ_BODY" | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["data"]["data"]["apikey"])
except Exception: print("")' 2>/dev/null || echo "")
if [[ "$READ_KEY" != "$NEW_KEY" ]]; then
  echo "FATAL: Vault read-back mismatch (got len=${#READ_KEY}, expected ${#NEW_KEY})." >&2
  rotate_record "vault-readback-error"
  exit 4
fi
echo "  Vault: read-back verified"

# 3. Update env files (idempotent: replace existing key lines or append).
update_env_file() {
  local file="$1" key="$2" val="$3"
  [[ -f "$file" ]] || touch "$file"
  if grep -qE "^${key}=" "$file"; then
    python3 - "$file" "$key" "$val" <<'PY'
import sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
out = []
for line in open(path):
    if line.startswith(key + "="):
        out.append(f"{key}={val}\n")
    else:
        out.append(line)
open(path, "w").write("".join(out))
PY
  else
    echo "${key}=${val}" >> "$file"
  fi
}
update_env_file "$LIBCLOUD_REST_ENV" "FGA_API_TOKEN" "$NEW_KEY"
update_env_file "$OPENFGA_ENV" "OPENFGA_AUTHN_PRESHARED_KEYS" "$NEW_KEY"
echo "  Updated ${LIBCLOUD_REST_ENV} (FGA_API_TOKEN) and ${OPENFGA_ENV} (OPENFGA_AUTHN_PRESHARED_KEYS)"

rotate_record "ok"

if [[ "$APPLY" -ne 1 ]]; then
  echo
  echo "Vault + env files updated. To activate, restart the affected containers:"
  echo "  docker compose -f ${ROOT}/../libcloud.rest/docker-compose.yml restart ${LIBCLOUD_REST_CONTAINER:-libcloud-rest-api}"
  echo "  (and restart the openfga service to load OPENFGA_AUTHN_PRESHARED_KEYS)"
  echo "Re-run with --apply to do this automatically."
  exit 0
fi

# 4. Rolling restart + verify.
REST_CTR="${LIBCLOUD_REST_CONTAINER:-libcloud-rest-api}"
echo "  Restarting libcloud REST container ${REST_CTR} ..."
docker restart "$REST_CTR" >/dev/null
echo "  Restarting openfga container ..."
docker restart openfga >/dev/null
sleep 5
if curl -sS -o /dev/null -w "%{http_code}" "${LIBCLOUD_REST_URL:-http://localhost:8765}/v1/auth/me" 2>/dev/null | grep -qE '^(200|401)$'; then
  echo "  libcloud REST is back up"
else
  echo "  WARNING: libcloud REST did not return 200/401 on /v1/auth/me after restart" >&2
fi
if curl -sS -o /dev/null -w "%{http_code}" "${FGA_API_URL}/healthz" 2>/dev/null | grep -qE '^2'; then
  echo "  OpenFGA is back up"
else
  echo "  WARNING: OpenFGA /healthz not 2xx after restart" >&2
fi
echo "Preshared key rotation complete (apply)."
