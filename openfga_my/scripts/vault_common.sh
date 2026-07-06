#!/usr/bin/env bash
# vault_common.sh — shared helpers for the Vault admin scripts (Group 3).
#
# Sourced (never executed) by vault-policy-*.sh / vault-ldap-group-bind.sh /
# vault-secrets-engine-enable.sh / vault-role-create.sh / vault-root-cred-rotate.sh
# / vault-lease-*.sh / vault-dynamic-cred-request.sh / vault-static-secret-rotate.sh
# / vault-health-check.sh / vault-audit-log-query.sh / vault-token-lookup.sh.
#
# Vault has no CLI in this deployment, so every operation goes through the HTTP
# API (https://developer.hashicorp.com/vault/api-docs) via curl. Root privileges
# use the root token stored in ../vault/generated/vault.env (written by
# vault_bootstrap.py). Per-call token override: set VAULT_TOKEN or pass
# --vault-token (each script exports VAULT_TOKEN_ARG).
#
# Contract for callers (set -euo pipefail assumed):
#   vault_resolve_token          # prints the token to use; honours VAULT_TOKEN_ARG
#   vault_http <method> <path> [body-file]   # sets VAULT_HTTP_CODE, prints body
#   vault_get  <path>            vault_put  <path> [body-file]
#   vault_post <path> [body-file]            vault_delete <path>
#   vault_list <path>            # LIST (curl -X LIST); prints JSON keys
#   vault_json_field <file> <jq-ish path>    # extracts nested field via python
#   vault_now                    # ISO-8601 UTC
#   vault_audit <json-line>      # stderr + append to VAULT_AUDIT_LOG
#
# Env (loaded from .env / ../vault/generated/vault.env):
#   VAULT_ADDR                  default http://localhost:8200
#   VAULT_ROOT_TOKEN            root token (required unless VAULT_TOKEN/--vault-token)
#   VAULT_AUDIT_LOG             default generated/vault_audit.log
#   ACTOR                       default $USER / cloud-admin

# Resolve SCRIPT_DIR/ROOT for the common case of a direct `source`.
[[ -n "${SCRIPT_DIR:-}" ]] || SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${ROOT:-}" ]] || ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_vault_load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" != *=* ]] && continue
    local key="${line%%=*}" val="${line#*=}"
    if [[ -z "${!key:-}" ]]; then export "${key}=${val}"; fi
  done < "$file"
  return 0
}
_vault_load_env_file "${ROOT}/.env"
_vault_load_env_file "${ROOT}/../vault/generated/vault.env" 2>/dev/null || true
_vault_load_env_file "${ROOT}/generated/vault.env" 2>/dev/null || true

: "${VAULT_ADDR:=http://localhost:8200}"
VAULT_ADDR="${VAULT_ADDR%/}"
export VAULT_ADDR
: "${VAULT_AUDIT_LOG:=${ROOT}/generated/vault_audit.log}"
: "${ACTOR:=${VAULT_ACTOR:-${USER:-cloud-admin}}}"

VAULT_HTTP_CODE=""
VAULT_OUT="$(mktemp -t vault_body.XXXXXX)"
VAULT_TOKEN_ARG="${VAULT_TOKEN_ARG:-}"
export VAULT_OUT

vault_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Print the token to use for this invocation. Priority:
#   1. --vault-token (caller exports VAULT_TOKEN_ARG)
#   2. VAULT_ROOT_TOKEN (root, from ../vault/generated/vault.env) — preferred
#      for admin operations so policy/engine/lease-revoke-prefix scripts work
#   3. VAULT_TOKEN env (libcloud REST read token — limited capabilities; only
#      used as a last-resort fallback)
vault_resolve_token() {
  if [[ -n "${VAULT_TOKEN_ARG}" ]]; then echo "${VAULT_TOKEN_ARG}"; return 0; fi
  if [[ -n "${VAULT_ROOT_TOKEN:-}" ]]; then echo "${VAULT_ROOT_TOKEN}"; return 0; fi
  if [[ -n "${VAULT_TOKEN:-}" ]]; then echo "${VAULT_TOKEN}"; return 0; fi
  echo "FATAL: no Vault token. Set VAULT_ROOT_TOKEN (../vault/generated/vault.env) or pass --vault-token." >&2
  return 3
}

# Require a root-capable token (used by policy / engine / lease-revoke-prefix
# scripts that need root). Exits non-zero if only a non-root token is available.
vault_require_root_token() {
  local tok
  tok=$(vault_resolve_token) || return $?
  # A best-effort guard: if the explicit arg is the read-only libcloud token,
  # refuse. The caller is expected to provide the root token via env or --vault-token.
  if [[ -z "${VAULT_ROOT_TOKEN:-}" && -z "${VAULT_TOKEN_ARG:-}" ]]; then
    echo "FATAL: this operation requires a root token. Set VAULT_ROOT_TOKEN (../vault/generated/vault.env)." >&2
    return 3
  fi
  echo "${tok}"
}

# Normalize a Vault API path so callers can pass either "sys/health" or
# "/v1/sys/health". Returns the full URL on stdout.
_vault_url() {
  local path="$1"
  if [[ "$path" != /v1/* && "$path" != v1/* ]]; then
    path="/v1/${path#/}"
  fi
  printf '%s%s\n' "${VAULT_ADDR}" "${path}"
}

# vault_http <method> <path> [body-file-or-string] [out-file]
#
# Performs the request with the resolved token as X-Vault-Token. Writes the
# response body to <out-file> if given, else to the global $VAULT_OUT. Sets
# VAULT_HTTP_CODE in the CURRENT shell. Prints the body path on stdout so a
# caller can do:  out=$(vault_http GET "$p"); body=$(cat "$out"); code=$VAULT_HTTP_CODE
#
# IMPORTANT: do NOT call via command substitution if you need VAULT_HTTP_CODE
# in the caller — `out=$(vault_http ...)` is fine (the code is set before the
# inner cat), but `body=$(vault_http ...)` would capture the body path, not the
# body. The wrappers below (vault_get/put/post/delete/list) and the
# vault_capture helper follow the correct pattern.
vault_http() {
  local method="$1" path="$2" body="${3:-}" out="${4:-}"
  local tok url tmp
  tok=$(vault_resolve_token) || return $?
  url=$(_vault_url "$path")
  [[ -n "$out" ]] || out="$VAULT_OUT"
  local -a args=(-sS -X "$method" "$url" -H "X-Vault-Token: ${tok}" -o "$out" -w "%{http_code}")
  if [[ -n "$body" && -f "$body" ]]; then
    args+=(-H "Content-Type: application/json" --data-binary "@${body}")
  elif [[ -n "$body" ]]; then
    args+=(-H "Content-Type: application/json" -d "$body")
  fi
  VAULT_HTTP_CODE=$(curl "${args[@]}" 2>/dev/null) || VAULT_HTTP_CODE="000"
  printf '%s\n' "$out"
}

# vault_capture <method> <path> [body] <out-file>
#   Convenience: writes body to <out-file>, sets VAULT_HTTP_CODE. The out-file
#   is the LAST argument. Use this when you want the body in a specific file.
vault_capture() {
  local method="$1" path="$2"
  shift 2
  local out body=""
  # The last argument is the out-file; anything between is the body.
  if [[ $# -ge 2 ]]; then body="$1"; out="$2"; elif [[ $# -eq 1 ]]; then out="$1"; fi
  vault_http "$method" "$path" "$body" "$out" >/dev/null
}

vault_get()    { vault_http GET    "$1" "" "${2:-}" >/dev/null; }
vault_put()    { vault_http PUT    "$1" "${2:-}" "${3:-}" >/dev/null; }
vault_post()   { vault_http POST   "$1" "${2:-}" "${3:-}" >/dev/null; }
vault_delete() { vault_http DELETE "$1" "" "${2:-}" >/dev/null; }

# Vault LIST uses the LIST verb; curl supports arbitrary methods. Some proxies
# downgrade LIST to GET, so fall back to GET with ?list=true on a 405/404.
# Writes body to $VAULT_OUT (or <out-file> if given); sets VAULT_HTTP_CODE.
vault_list() {
  local path="$1" out="${2:-}"
  vault_http LIST "$path" "" "$out" >/dev/null
  if [[ "$VAULT_HTTP_CODE" == "000" || "$VAULT_HTTP_CODE" == "405" || "$VAULT_HTTP_CODE" == "404" ]]; then
    local sep="?"
    [[ "$path" == *\?* ]] && sep="&"
    vault_http GET "${path}${sep}list=true" "" "$out" >/dev/null
  fi
}

# Extract a nested field from a JSON file using a dotted path.
#   vault_json_field <file> "data.data.password"
# Implemented with `python3 -c` (not a heredoc) so that callers may pipe JSON
# through stdin and pass `/dev/stdin` as the file argument — a heredoc would
# claim stdin and break that usage.
vault_json_field() {
  local file="$1" path="$2"
  FILE_E="$file" PATH_E="$path" python3 -c '
import json, os, sys
f, path = os.environ["FILE_E"], os.environ["PATH_E"]
try:
    d = json.load(open(f))
except Exception:
    print(""); sys.exit(0)
for p in path.split("."):
    if d is None: break
    if isinstance(d, list):
        try: d = d[int(p)]
        except Exception: d = None; break
    else:
        d = d.get(p) if isinstance(d, dict) else None
print("" if d is None else (d if isinstance(d, str) else json.dumps(d)))
' 2>/dev/null || true
}

# Write a JSON body to a temp file and print its path (for --data-binary @file).
vault_body_file() {
  local tmp; tmp=$(mktemp)
  printf '%s' "$1" > "$tmp"
  echo "$tmp"
}

vault_audit() {
  local line="$1"
  echo "$line" >&2
  mkdir -p "$(dirname "$VAULT_AUDIT_LOG")"
  echo "$line" >> "$VAULT_AUDIT_LOG"
}

# Pretty-print JSON on stdin if python is available, else passthrough.
vault_json_pretty() { python3 -m json.tool 2>/dev/null || cat; }
