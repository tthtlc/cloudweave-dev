#!/usr/bin/env bash
#
# rotate_root_and_unseal.sh
#
# Rotates the three long-lived Vault credentials that were committed to git in
# vault/generated/vault.env and are therefore treated as compromised
# (vault/ARCHITECTURE.md §8.5):
#
#   1. VAULT_UNSEAL_KEY  — rekey the seal key (POST /v1/sys/rekey/...)
#   2. VAULT_ROOT_TOKEN  — generate a fresh root token (generate-root), revoke old
#   3. VAULT_TOKEN       — mint a fresh orchestrator token, revoke old
#
# The root token is produced with the canonical "generate-root" rescue flow
# (which needs only the unseal key), NOT by `vault token create -policy=root`:
# a token created that way has a finite TTL and is not the true root token.
#
# On success the leaked values in the committed file are useless (rekey
# invalidates the old unseal key; revocation invalidates the old tokens) and
# vault/generated/vault.env is rewritten with fresh values (0600, with a
# timestamped backup).
#
# SAFETY: dry-run by default — pass --yes to actually mutate Vault. The script
# refuses to run unless Vault is reachable and UNSEALED, and unless the current
# credentials in vault.env still authenticate. It persists the new unseal key
# BEFORE any revocation, so a mid-run failure cannot strand a sealed Vault.
#
# REQUIREMENTS: curl, jq, docker (the `vault` container running), and an
#               unsealed Vault at $VAULT_ADDR (default http://127.0.0.1:8200).
#
# USAGE:
#   ./rotate_root_and_unseal.sh            # dry-run: show what will change
#   ./rotate_root_and_unseal.sh --yes      # rotate for real
#   VAULT_ADDR=http://vault:8200 ./rotate_root_and_unseal.sh --yes
set -euo pipefail

ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/generated/vault.env"
ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
ADDR="${ADDR%/}"
CONTAINER="${VAULT_CONTAINER:-vault}"
CONTAINER_ADDR="http://127.0.0.1:8200"   # vault's own listener, as seen inside the container

YES=0
DO_ORCH=1
for a in "$@"; do
  case "$a" in
    --yes) YES=1 ;;
    --no-orch) DO_ORCH=0 ;;
    -h|--help) sed -n '2,48p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

log() { echo "[rotate] $*" >&2; }
die() { echo "[rotate] ERROR: $*" >&2; exit 1; }

# curl against $ADDR/v1$path. TOKEN (optional) sets X-Vault-Token. Echoes the
# raw JSON body; fails the script on transport error or HTTP >= 400.
req() {
  local method="$1" path="$2" body="${3:-}" token="${4:-}"
  local args=(-sS -f -X "$method")
  [[ -n "$token" ]] && args+=(-H "X-Vault-Token: $token")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" -d "$body")
  curl "${args[@]}" "$ADDR/v1$path" || die "$method $path failed (HTTP/transport error)"
}

# Like req, but RETURNS non-zero on failure instead of exiting (best-effort ops).
req_opt() {
  local method="$1" path="$2" body="${3:-}" token="${4:-}"
  local args=(-sS -f -X "$method")
  [[ -n "$token" ]] && args+=(-H "X-Vault-Token: $token")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" -d "$body")
  curl "${args[@]}" "$ADDR/v1$path" 2>/dev/null
}

# Extract a field from JSON with jq, failing loudly if absent/null.
jqr() {
  local expr="$1" json="$2" what="${3:-$1}" v
  v="$(jq -r "$expr" <<<"$json")" || die "jq failed parsing $what"
  [[ -n "$v" && "$v" != "null" ]] || die "missing $what in response: $json"
  printf '%s' "$v"
}

# Read a single KEY=value from the env file (no eval, no field splitting).
get_env() { sed -nE "s/^$1=//p" "$ENV_FILE" | head -1; }

# gen_root <unseal_key> — produce a fresh root token via the generate-root
# rescue flow (server-generated OTP), printing only the token value.
gen_root() {
  local unseal="$1" init nonce otp upd enc dec tok
  docker exec -e VAULT_ADDR="$CONTAINER_ADDR" "$CONTAINER" vault operator generate-root -cancel >/dev/null 2>&1 || true
  init="$(docker exec -e VAULT_ADDR="$CONTAINER_ADDR" "$CONTAINER" vault operator generate-root -init -format=json)" \
    || die "generate-root -init failed"
  nonce="$(jq -r .nonce <<<"$init")"
  otp="$(jq -r .otp <<<"$init")"
  upd="$(docker exec -e VAULT_ADDR="$CONTAINER_ADDR" "$CONTAINER" vault operator generate-root -format=json -nonce="$nonce" "$unseal")" \
    || die "generate-root update failed"
  enc="$(jq -r '.encoded_root_token // .encoded_token' <<<"$upd")"
  dec="$(docker exec -e VAULT_ADDR="$CONTAINER_ADDR" "$CONTAINER" vault operator generate-root -format=json -decode="$enc" -otp="$otp")" \
    || die "generate-root decode failed"
  tok="$(jq -r 'if type=="object" then (.token // .root_token // empty) else . end' <<<"$dec")"
  [[ -n "$tok" && "$tok" != "null" ]] || die "generate-root returned no token"
  printf '%s' "$tok"
}

# --- load current state ------------------------------------------------------

[[ -f "$ENV_FILE" ]] || die "env file not found: $ENV_FILE (run vault_bootstrap.py first)"

VAULT_ADDR="$(get_env VAULT_ADDR)"
VAULT_TOKEN="$(get_env VAULT_TOKEN)"
VAULT_ROOT_TOKEN="$(get_env VAULT_ROOT_TOKEN)"
VAULT_UNSEAL_KEY="$(get_env VAULT_UNSEAL_KEY)"

[[ -n "${VAULT_UNSEAL_KEY:-}" ]] || die "VAULT_UNSEAL_KEY missing from $ENV_FILE"
[[ -n "${VAULT_ROOT_TOKEN:-}" ]] || die "VAULT_ROOT_TOKEN missing from $ENV_FILE"
[[ -n "${VAULT_TOKEN:-}" ]]       || die "VAULT_TOKEN missing from $ENV_FILE"

# Keep the old values so we can revoke them at the end.
OLD_ROOT_TOKEN="$VAULT_ROOT_TOKEN"
OLD_ORCH_TOKEN="$VAULT_TOKEN"

status_json="$(req GET /sys/seal-status)"
[[ "$(jq -r .sealed <<<"$status_json")" == "false" ]] || die "Vault is sealed — unseal it first"
req LIST /sys/policies/acl "" "$VAULT_ROOT_TOKEN" >/dev/null \
  || die "current VAULT_ROOT_TOKEN no longer authenticates — aborting"
log "Vault reachable and unsealed; current credentials authenticate."

if (( ! YES )); then
  log "DRY RUN — would perform:"
  log "  1. rekey the unseal key (new 1-of-1 Shamir key)"
  log "  2. generate a new root token (generate-root), then revoke the old root"
  if (( DO_ORCH )); then
    log "  3. mint a new orchestrator token (policy=libcloud-vault-auth-read), revoke old"
  fi
  log "  4. rewrite $ENV_FILE (0600, timestamped backup kept)"
  log "Re-run with --yes to apply."
  exit 0
fi

# --- apply (--yes) -----------------------------------------------------------

backup="$ENV_FILE.bak.$(date +%s)"
cp -a "$ENV_FILE" "$backup"
log "backed up $ENV_FILE -> $backup"

write_env() {
  umask 077
  {
    echo "# Generated by rotate_root_and_unseal.sh — DO NOT COMMIT (gitignored)."
    echo "VAULT_ADDR=${VAULT_ADDR}"
    echo "VAULT_TOKEN=${VAULT_TOKEN}"
    echo "VAULT_ROOT_TOKEN=${VAULT_ROOT_TOKEN}"
    echo "VAULT_UNSEAL_KEY=${VAULT_UNSEAL_KEY}"
  } > "$ENV_FILE.new"
  chmod 600 "$ENV_FILE.new"
  mv "$ENV_FILE.new" "$ENV_FILE"
  log "wrote $ENV_FILE"
}

# 1. rekey — rotate the unseal key. Persist the new key IMMEDIATELY.
rekey_init_json="$(req PUT /sys/rekey/init '{"secret_shares":1,"secret_threshold":1}' "$VAULT_ROOT_TOKEN")"
REKEY_NONCE="$(jqr .nonce "$rekey_init_json" "rekey nonce")"
log "rekey initialized (nonce=${REKEY_NONCE:0:8}…)"

rekey_update_json="$(req PUT /sys/rekey/update \
  "$(jq -cn --arg k "$VAULT_UNSEAL_KEY" --arg n "$REKEY_NONCE" '{key:$k,nonce:$n}')")"
[[ "$(jq -r .complete <<<"$rekey_update_json")" == "true" ]] \
  || die "rekey did not complete: $rekey_update_json"
VAULT_UNSEAL_KEY="$(jqr '.keys[0]' "$rekey_update_json" "new unseal key")"
write_env   # new unseal key + still-old tokens (all valid right now)

# 2. generate a fresh root token (true root token, no TTL) using the NEW key.
NEW_ROOT_TOKEN="$(gen_root "$VAULT_UNSEAL_KEY")"
req LIST /sys/policies/acl "" "$NEW_ROOT_TOKEN" >/dev/null \
  || die "new root token failed sanity check"
log "new root token generated (generate-root)"

# 3. rotate orchestrator token — using the NEW root token.
if (( DO_ORCH )); then
  new_orch_json="$(req POST /auth/token/create \
    '{"policies":["libcloud-vault-auth-read"],"ttl":"768h","renewable":true}' "$NEW_ROOT_TOKEN")"
  VAULT_TOKEN="$(jqr '.auth.client_token' "$new_orch_json" "new orchestrator token")"
  log "new orchestrator token minted (policy=libcloud-vault-auth-read, ttl=768h)"
fi

VAULT_ROOT_TOKEN="$NEW_ROOT_TOKEN"
write_env   # final: new root + new orchestrator + new unseal key

# 4. revoke the OLD credentials (non-fatal). Revoking the old root token also
#    cascades to the old orchestrator token (its child), so the second revoke
#    is expected to be a no-op/warning.
req_opt POST /auth/token/revoke \
  "$(jq -cn --arg t "$OLD_ROOT_TOKEN" '{token:$t}')" "$NEW_ROOT_TOKEN" >/dev/null \
  && log "old root token revoked" \
  || log "WARN: could not revoke old root token (already gone?)"
if (( DO_ORCH )) && [[ "$OLD_ORCH_TOKEN" != "$VAULT_TOKEN" ]]; then
  req_opt POST /auth/token/revoke \
    "$(jq -cn --arg t "$OLD_ORCH_TOKEN" '{token:$t}')" "$NEW_ROOT_TOKEN" >/dev/null \
    && log "old orchestrator token revoked" \
    || log "WARN: old orchestrator token already gone (revoked via cascade)"
fi

log "DONE. Vault rekeyed and tokens rotated."
log "IMPORTANT: re-sync VAULT_TOKEN into libcloud.rest/.env (re-run setup.sh) so"
log "          the REST API uses the new orchestrator token."
log "          Remove the backup file once verified: rm -f '$backup'"
