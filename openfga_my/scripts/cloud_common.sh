#!/usr/bin/env bash
# cloud_common.sh — shared helpers for the Group-4 cloud provisioning scripts.
#
# Sourced (never executed) by cloud-node-*.sh / cloud-keypair-manage.sh /
# cloud-image-list.sh / cloud-size-list.sh / cloud-storage-*.sh /
# cloud-volume-list.sh / cloud-network-list.sh / cloud-floatingip-*.sh.
#
# It sources scripts/common.sh (env loading + libcloud_api + the per-provider
# connection builders + json_pretty + curl_http) and adds:
#   * a libcloud REST bearer-token resolution identical to openfga_common.sh
#     (FGA_API_TOKEN > SUPERADMIN_JWT > generated/tokens/superadmin.jwt-if-valid
#     > fresh Dex idp_login), so the scripts work even when the Dex
#     client_secret has drifted (the REST API validates the JWT via JWKS);
#   * cloud_setup         — /v1/auth/me + build the provider connection + test;
#   * cloud_api           — libcloud_api wrapper honouring CLOUD_DRY_RUN;
#   * cloud_audit         — JSONL audit to generated/cloud_audit.log;
#   * cloud_provider / cloud_region selectors.
#
# Provider selection:
#   CLOUD_PROVIDER=aws|nutanix  (default: ${TENANT:-nutanix}; nutanix is mocked
#                                in this dev env via the stoplight emulator on
#                                :9440, so it is safe for read/list tests)
#   AWS_REGION / CLOUD_REGION   region for aws (default ap-southeast-1)
#   CLOUD_DRY_RUN=1             print the REST call instead of executing it
#
# Contract for callers (set -euo pipefail assumed):
#   cloud_setup                 # call once at start
#   cloud_api GET  /v1/compute/nodes
#   cloud_api POST /v1/compute/nodes "$body"
#   cloud_audit '<json-line>'

export LIBCLOUD_USER="${LIBCLOUD_USER:-superadmin}"

SCRIPT_DIR_CC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR_CC}/common.sh" >/dev/null 2>&1 || {
  echo "FATAL: cannot source scripts/common.sh — run ./setup.sh first." >&2
  exit 2
}

: "${LIBCLOUD_REST_URL:?LIBCLOUD_REST_URL not set (run ./setup.sh)}"
: "${CLOUD_AUDIT_LOG:=${ROOT}/generated/cloud_audit.log}"
CLOUD_DRY_RUN="${CLOUD_DRY_RUN:-0}"
CLOUD_PROVIDER="${CLOUD_PROVIDER:-${TENANT:-nutanix}}"
CLOUD_REGION="${CLOUD_REGION:-${AWS_REGION:-ap-southeast-1}}"

# ---- bearer token resolution (mirrors openfga_common.sh) --------------------
_jwt_exp() { python3 - "$1" <<'PY' 2>/dev/null
import sys, json, base64
try:
    p = sys.argv[1].split('.')[1]; p += '=' * (-len(p) % 4)
    print(int(json.loads(base64.urlsafe_b64decode(p)).get("exp", 0)))
except Exception:
    print("")
PY
}

_resolve_rest_token() {
  if [[ -n "${LIBCLOUD_ACCESS_TOKEN:-${FGA_API_TOKEN:-}}" ]]; then
    echo "${LIBCLOUD_ACCESS_TOKEN:-${FGA_API_TOKEN}}"; return 0
  fi
  if [[ -n "${SUPERADMIN_JWT:-}" ]]; then echo "${SUPERADMIN_JWT}"; return 0; fi
  local jp="${ROOT}/generated/tokens/superadmin.jwt"
  if [[ -s "$jp" ]]; then
    local tok exp now
    tok=$(cat "$jp"); exp=$(_jwt_exp "$tok"); now=$(date +%s)
    if [[ -n "$exp" && "$exp" -gt "$now" ]]; then echo "$tok"; return 0; fi
  fi
  if idp_login >/dev/null 2>&1 && [[ -n "${ACCESS_TOKEN:-}" ]]; then
    echo "${ACCESS_TOKEN}"; return 0
  fi
  return 1
}

if [[ -z "${ACCESS_TOKEN:-}" ]]; then
  if ! ACCESS_TOKEN=$(_resolve_rest_token); then
    echo "FATAL: no libcloud REST bearer token. Set LIBCLOUD_ACCESS_TOKEN /" >&2
    echo "       SUPERADMIN_JWT, ensure generated/tokens/superadmin.jwt is valid," >&2
    echo "       or run ./scripts/superadmin_auth.sh." >&2
    exit 3
  fi
  export ACCESS_TOKEN
fi

cloud_provider() { echo "${CLOUD_PROVIDER}"; }
cloud_region()   { echo "${CLOUD_REGION}"; }

# Build the per-provider connection (sets CONNECTION_PARAM). Call after cloud_setup.
build_cloud_connection() {
  case "${CLOUD_PROVIDER}" in
    aws)     build_aws_connection_param "${CLOUD_REGION}" ;;
    nutanix) build_nutanix_connection_param ;;
    *) echo "FATAL: unknown CLOUD_PROVIDER='${CLOUD_PROVIDER}' (use aws|nutanix)" >&2; exit 2 ;;
  esac
}

# One-shot setup: validate token, build connection, test backend connectivity.
cloud_setup() {
  step "auth" "libcloud REST token validation (provider=${CLOUD_PROVIDER})"
  curl_http GET "${LIBCLOUD_REST_URL}/v1/auth/me" "" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Accept: application/json" >/dev/null
  [[ "${CURL_LAST_HTTP_CODE}" == "200" ]] || {
    echo "FATAL: /v1/auth/me returned HTTP ${CURL_LAST_HTTP_CODE}" >&2; exit 3; }
  build_cloud_connection
  step "conn" "backend connection test (${CLOUD_PROVIDER})"
  curl_http POST "${LIBCLOUD_REST_URL}/v1/connections:test" "$(connection_json)" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Accept: application/json" \
    -H "X-Provider-Connection: ${CONNECTION_PARAM}" >/dev/null
  [[ "${CURL_LAST_HTTP_CODE}" == "200" ]] || {
    echo "FATAL: connection test failed (HTTP ${CURL_LAST_HTTP_CODE})" >&2; exit 4; }
}

# cloud_api <method> <path> [body]   — honours CLOUD_DRY_RUN.
cloud_api() {
  local method="$1" path="$2" body="${3:-}"
  if [[ "${CLOUD_DRY_RUN}" == "1" ]]; then
    echo "[dry-run] ${method} ${LIBCLOUD_REST_URL}${path} ${body:+(body ${#body} bytes)}" >&2
    return 0
  fi
  libcloud_api "$method" "$path" "$body"
}

# cloud_api_json <method> <path> [body] — like cloud_api but pretty-prints JSON.
cloud_api_json() {
  if [[ "${CLOUD_DRY_RUN}" == "1" ]]; then cloud_api "$@"; return $?; fi
  cloud_api "$@" | json_pretty
}

# cloud_api_or_die <method> <path> [body] — call cloud_api, validate the body is
# JSON, print it on stdout. Exits 4 with the (truncated) body on non-JSON / HTTP
# errors (e.g. a 500 from a backend that doesn't support the operation). If the
# response is valid JSON carrying a top-level `error` object (e.g. a 501
# "provider_capability_unsupported" or a 502 "provider_operation_failed"), the
# error code/message are printed to stderr and the script exits 4, so list
# scripts do not silently report "no results" when the backend rejected the call.
cloud_api_or_die() {
  local resp rc
  resp=$(cloud_api "$@") || rc=$?
  rc=${rc:-0}
  if [[ "${CLOUD_DRY_RUN}" == "1" ]]; then printf '%s' "${resp}"; return 0; fi
  if ! python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"${resp}" 2>/dev/null; then
    echo "REST ${1} ${2} returned non-JSON / HTTP error: ${resp:0:200}" >&2
    exit 4
  fi
  local err
  err=$(python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
e = d.get("error") if isinstance(d, dict) else None
if isinstance(e, dict):
    print(e.get("code","") + "|" + e.get("message",""))
' <<<"${resp}" 2>/dev/null || echo "")
  if [[ -n "$err" ]]; then
    echo "REST ${1} ${2} error: ${err#*|} (code=${err%%|*})" >&2
    exit 4
  fi
  printf '%s' "${resp}"
}

cloud_now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

cloud_audit() {
  local line="$1"
  echo "${line}" >&2
  mkdir -p "$(dirname "${CLOUD_AUDIT_LOG}")"
  echo "${line}" >> "${CLOUD_AUDIT_LOG}"
}
