#!/usr/bin/env bash
# vault-static-secret-rotate.sh — rotate a static secret stored in Vault KV v2.
#
# Cloud Admin tool. Generates a new secret value, writes it to Vault at
# <path> (KV v2: secret/data/<key>), and optionally calls a hook script to
# register the new value with the upstream provider before deleting the old
# value. The old value is preserved as the prior KV version (Vault keeps
# version history), so rollback is `vault kv undelete` / pinning a prior
# version — out of scope here.
#
# Use cases: a SaaS API key, a database password, a service-account token whose
# provider has no native dynamic-secret engine.
#
# Usage:
#   vault-static-secret-rotate.sh <path> [--key <name>] [--length <n>]
#                                 [--hook <script>] [--hook-arg <s>...]
#                                 [--kv-mount secret] [--dry-run]
#
#   vault-static-secret-rotate.sh secret/data/saas/acme --key api_key
#   vault-static-secret-rotate.sh secret/saas/acme --key api_key \
#       --hook ./register_acme_key.sh --hook-arg acct=123
#
# The hook script receives the new secret value on stdin and any --hook-arg
# values as argv. It must exit 0 on success; non-zero aborts BEFORE the new
# value is written to Vault (so the old value stays live). If --write-first is
# passed instead, Vault is updated first and the hook is run after (the hook
# then receives the new value on stdin and is best-effort).
#
# Options:
#   --key <name>       secret field name to set (default: value)
#   --length <n>       generated secret length in bytes (default 32)
#   --hook <script>    provider registration hook (optional)
#   --hook-arg <s>     extra argv passed to the hook (repeatable)
#   --write-first      update Vault first, run hook after (default: hook first)
#   --kv-mount <m>     KV mount (default secret); path may already include it
#   --vault-token <t>
#   --dry-run
#   -h, --help
#
# Exit codes:
#   0  rotated (+ hook ok)
#   2  usage
#   3  no Vault token / Vault unreachable
#   4  Vault write failed
#   5  hook failed (and Vault was NOT updated — old value still live)
#   6  hook failed after Vault was updated (--write-first)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vault_common.sh
source "${SCRIPT_DIR}/vault_common.sh"

KEY="value"
LENGTH=32
HOOK=""
HOOK_ARGS=()
WRITE_FIRST=0
KV_MOUNT="secret"
DRY_RUN=0
PATH_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)         KEY="$2"; shift 2 ;;
    --length)      LENGTH="$2"; shift 2 ;;
    --hook)        HOOK="$2"; shift 2 ;;
    --hook-arg)    HOOK_ARGS+=("$2"); shift 2 ;;
    --write-first) WRITE_FIRST=1; shift ;;
    --kv-mount)    KV_MOUNT="$2"; shift 2 ;;
    --vault-token) VAULT_TOKEN_ARG="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)           echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$PATH_ARG" ]]; then PATH_ARG="$1"
      else echo "ERROR: unexpected argument: $1" >&2; exit 2; fi
      shift ;;
  esac
done

[[ -n "$PATH_ARG" ]] || { echo "ERROR: secret path is required" >&2; exit 2; }
# Normalize: accept "secret/foo", "secret/data/foo", or "foo" (then prepend mount/data).
if [[ "$PATH_ARG" == "${KV_MOUNT}/data/"* ]]; then
  api_path="$PATH_ARG"
elif [[ "$PATH_ARG" == "${KV_MOUNT}/"* ]]; then
  api_path="${KV_MOUNT}/data/${PATH_ARG#${KV_MOUNT}/}"
else
  api_path="${KV_MOUNT}/data/${PATH_ARG#/}"
fi
if ! [[ "$KEY" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: --key must match [a-zA-Z0-9_-]" >&2; exit 2
fi

# Generate a new secret value (URL-safe base64 of LENGTH random bytes).
new_value=$(LEN="$LENGTH" python3 -c '
import secrets, base64, os
print(base64.urlsafe_b64encode(secrets.token_bytes(int(os.environ["LEN"]))).decode().rstrip("="))
')
ts="$(vault_now)"

write_to_vault() {
  local body tmp
  body=$(V="$new_value" K="$KEY" TS="$ts" A="$ACTOR" python3 -c '
import json, os
print(json.dumps({"data": {os.environ["K"]: os.environ["V"],
                           "rotated_at": os.environ["TS"],
                           "rotated_by": os.environ["A"]}}))
')
  tmp=$(vault_body_file "$body")
  local resp http
  vault_post "$api_path" "$tmp"
  http="$VAULT_HTTP_CODE"
  resp=$(cat "$VAULT_OUT")
  rm -f "$tmp"
  if [[ "$http" != "200" && "$http" != "204" ]]; then
    echo "ERROR: Vault write to ${api_path} failed (http=${http}): ${resp}" >&2
    return 4
  fi
  echo "OK: new ${KEY} written to ${api_path}." >&2
  return 0
}

run_hook() {
  [[ -n "$HOOK" ]] || return 0
  [[ -x "$HOOK" || -f "$HOOK" ]] || { echo "ERROR: hook script not found: $HOOK" >&2; return 5; }
  echo "Running hook: ${HOOK} ${HOOK_ARGS[*]-}" >&2
  if ! printf '%s' "$new_value" | bash -lc "$(read -r _h <<<"$HOOK"; printf '%q ' "$_" "${HOOK_ARGS[@]}")" >/dev/null 2>&1; then
    echo "ERROR: hook '${HOOK}' exited non-zero." >&2
    return 5
  fi
  echo "OK: hook completed." >&2
  return 0
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] would write new ${KEY} (${#new_value} chars) to ${api_path}" >&2
  [[ -n "$HOOK" ]] && echo "[dry-run] would run hook: ${HOOK} ${HOOK_ARGS[*]-}" >&2
  vault_audit "{\"ts\":\"${ts}\",\"actor\":\"${ACTOR}\",\"action\":\"static-secret-rotate\",\"path\":\"${api_path}\",\"key\":\"${KEY}\",\"result\":\"dry-run\"}"
  exit 0
fi

if [[ "$WRITE_FIRST" -eq 1 ]]; then
  if ! write_to_vault; then
    vault_audit "{\"ts\":\"${ts}\",\"actor\":\"${ACTOR}\",\"action\":\"static-secret-rotate\",\"path\":\"${api_path}\",\"key\":\"${KEY}\",\"result\":\"vault-write-error\"}"
    exit 4
  fi
  if ! run_hook; then
    vault_audit "{\"ts\":\"${ts}\",\"actor\":\"${ACTOR}\",\"action\":\"static-secret-rotate\",\"path\":\"${api_path}\",\"key\":\"${KEY}\",\"result\":\"hook-error-after-write\"}"
    exit 6
  fi
else
  if ! run_hook; then
    vault_audit "{\"ts\":\"${ts}\",\"actor\":\"${ACTOR}\",\"action\":\"static-secret-rotate\",\"path\":\"${api_path}\",\"key\":\"${KEY}\",\"result\":\"hook-error\"}"
    exit 5
  fi
  if ! write_to_vault; then
    vault_audit "{\"ts\":\"${ts}\",\"actor\":\"${ACTOR}\",\"action\":\"static-secret-rotate\",\"path\":\"${api_path}\",\"key\":\"${KEY}\",\"result\":\"vault-write-error-after-hook\"}"
    exit 4
  fi
fi

vault_audit "{\"ts\":\"${ts}\",\"actor\":\"${ACTOR}\",\"action\":\"static-secret-rotate\",\"path\":\"${api_path}\",\"key\":\"${KEY}\",\"result\":\"ok\",\"write_first\":${WRITE_FIRST}}"
exit 0
