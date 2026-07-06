#!/usr/bin/env bash
# Shared curl helpers for Authentik (IdP) + OpenFGA + libcloud REST provisioning demos.
#
# Security model (rest_api_security.md): the client authenticates to the REST
# API with an OIDC bearer token and never handles backend cloud credentials.
# The REST API reaches the backend using its own identity (IAM role /
# auth_binding). These helpers therefore send only provider + region + an
# `auth_binding` selector via the X-Provider-Connection header.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_load_env_file() {
  local file="$1"
  local force="${2:-0}"
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" != *=* ]] && continue
    local key="${line%%=*}"
    local val="${line#*=}"
    # force=1: generated/*.env always wins (avoids stale parent-shell exports).
    # force=0: only set when unset or empty so blank .env entries do not block generated values.
    if [[ "$force" == "1" ]] || [[ -z "${!key:-}" ]]; then
      export "${key}=${val}"
    fi
  done < "$file"
}

_load_env_file "${ROOT}/.env"
# Dex OIDC env lives in the sibling ../dex project (self-contained compose).
_load_env_file "${ROOT}/../dex/generated/dex.env" 1
_load_env_file "${ROOT}/generated/authentik.env" 1
_load_env_file "${ROOT}/generated/fga.env" 1

DEX_URL="${DEX_URL:-http://localhost:5556}"
IDP_PROVIDER="${IDP_PROVIDER:-dex}"
AUTHENTIK_URL="${AUTHENTIK_URL:-http://localhost:9000}"
AUTHENTIK_OIDC_TOKEN_URL="${AUTHENTIK_OIDC_TOKEN_URL:-${AUTHENTIK_URL}/application/o/token/}"
LIBCLOUD_REST_URL="${LIBCLOUD_REST_URL:-http://localhost:8765}"
LIBCLOUD_OIDC_CLIENT_ID="${LIBCLOUD_OIDC_CLIENT_ID:-libcloud-rest}"
LIBCLOUD_OIDC_CLIENT_SECRET="${LIBCLOUD_OIDC_CLIENT_SECRET:?Set LIBCLOUD_OIDC_CLIENT_SECRET (run setup.sh)}"
FGA_API_URL="${FGA_API_URL:-http://localhost:8080}"
FGA_STORE_ID="${FGA_STORE_ID:?Set FGA_STORE_ID (run setup.sh)}"
FGA_MODEL_ID="${FGA_MODEL_ID:?Set FGA_MODEL_ID (run setup.sh)}"
FGA_API_OBJECT="${FGA_API_OBJECT:-libcloud_api:main}"

# Ensure OpenFGA's cached Dex JWKS is fresh before any Check. Dex rotates its
# OIDC signing keys every 6h (storage: memory); a stale OpenFGA keyset makes
# every Check fail with `invalid_claims`. Throttled + skippable; no-op when
# already refreshed recently (e.g. by a myrun_* script). Set OPENFGA_SKIP_RESTART=1
# to disable.
if [[ "${OPENFGA_SKIP_RESTART:-0}" != "1" ]]; then
  bash "${SCRIPT_DIR}/openfga_ensure_fresh.sh" >/dev/null 2>&1 || true
fi

LIBCLOUD_USER="${LIBCLOUD_USER:-cloud-admin}"

# IdP user password resolution.
#
# Embedded default passwords (e.g. CloudAdmin123!) are gated behind
# ALLOW_DEV_DEFAULTS=1 so they are not silently active in shared/non-dev
# environments. Prefer setting LIBCLOUD_PASSWORD or the per-role
# LIBCLOUD_PASSWORD_* env vars.
if [[ -n "${LIBCLOUD_PASSWORD:-}" ]]; then
  :
else
  case "${LIBCLOUD_USER}" in
    superadmin)
      LIBCLOUD_PASSWORD="${LIBCLOUD_SUPERADMIN_PASSWORD:-${LIBCLOUD_PASSWORD_SUPERADMIN:-}}" ;;
    aws-owner)
      LIBCLOUD_PASSWORD="${LIBCLOUD_PASSWORD_AWS_OWNER:-}" ;;
    aws-admin)
      LIBCLOUD_PASSWORD="${LIBCLOUD_PASSWORD_AWS_ADMIN:-}" ;;
    aws-viewer)
      LIBCLOUD_PASSWORD="${LIBCLOUD_PASSWORD_AWS_VIEWER:-}" ;;
    ntnx-owner)
      LIBCLOUD_PASSWORD="${LIBCLOUD_PASSWORD_NTNX_OWNER:-}" ;;
    ntnx-admin)
      LIBCLOUD_PASSWORD="${LIBCLOUD_PASSWORD_NTNX_ADMIN:-}" ;;
    ntnx-viewer)
      LIBCLOUD_PASSWORD="${LIBCLOUD_PASSWORD_NTNX_VIEWER:-}" ;;
    cloud-denied|outsider)
      LIBCLOUD_PASSWORD="${LIBCLOUD_PASSWORD_CLOUD_DENIED:-}" ;;
    *)
      : "${LIBCLOUD_PASSWORD:?Password required for user ${LIBCLOUD_USER} (set LIBCLOUD_PASSWORD)}" ;;
  esac

  if [[ -z "${LIBCLOUD_PASSWORD}" ]]; then
    if [[ "${ALLOW_DEV_DEFAULTS:-0}" == "1" ]]; then
      case "${LIBCLOUD_USER}" in
        superadmin)   LIBCLOUD_PASSWORD="SuperAdmin123!" ;;
        aws-owner)    LIBCLOUD_PASSWORD="AwsOwner123!" ;;
        aws-admin)    LIBCLOUD_PASSWORD="AwsAdmin123!" ;;
        aws-viewer)   LIBCLOUD_PASSWORD="AwsView123!" ;;
        ntnx-owner)   LIBCLOUD_PASSWORD="NtnxOwner123!" ;;
        ntnx-admin)   LIBCLOUD_PASSWORD="NtnxAdmin123!" ;;
        ntnx-viewer)  LIBCLOUD_PASSWORD="NtnxView123!" ;;
        cloud-denied|outsider) LIBCLOUD_PASSWORD="CloudDenied123!" ;;
      esac
      echo "WARNING: using embedded dev-default password (ALLOW_DEV_DEFAULTS=1)." >&2
    else
      : "${LIBCLOUD_PASSWORD:?Set LIBCLOUD_PASSWORD (or LIBCLOUD_PASSWORD_*) for user ${LIBCLOUD_USER}; set ALLOW_DEV_DEFAULTS=1 only for local dev.}" >&2
    fi
  fi
fi

ACCESS_TOKEN=""
CONNECTION_PARAM=""
VERBOSE="${VERBOSE:-0}"
CURL_LAST_HTTP_CODE=""

for _arg in "$@"; do
  case "${_arg}" in
    -v | --verbose) VERBOSE=1 ;;
  esac
done

verbose_enabled() {
  [[ "${VERBOSE}" == "1" || "${VERBOSE}" == "true" || "${VERBOSE}" == "yes" ]]
}

_redact_secrets() {
  sed -E \
    -e 's/(Authorization: Bearer )[A-Za-z0-9._~+/=-]+/\1***REDACTED***/g' \
    -e 's/(X-Provider-Connection: ).*/\1***REDACTED***/g' \
    -e 's/("secret"[[:space:]]*:[[:space:]]*")[^"]*/\1***REDACTED***/g' \
    -e 's/("access_token"[[:space:]]*:[[:space:]]*")[^"]*/\1***REDACTED***/g' \
    -e 's/("id_token"[[:space:]]*:[[:space:]]*")[^"]*/\1***REDACTED***/g' \
    -e 's/("credentials"[[:space:]]*:[[:space:]]*\{[^}]*\})/"credentials":***REDACTED***/g' \
    -e 's/(client_secret=)[^& ]*/\1***REDACTED***/g'
}

_verbose_log_body() {
  local label="$1"
  local content="$2"
  echo "${label}" >&2
  if [[ -n "${content}" ]]; then
    if echo "${content}" | json_pretty 2>/dev/null | _redact_secrets >&2; then
      :
    else
      echo "${content}" | _redact_secrets >&2
    fi
  else
    echo "(empty)" >&2
  fi
}

# Perform an HTTP request; print the response body to stdout.
# With VERBOSE=1, request/response headers and bodies are logged to stderr.
curl_http() {
  local method="$1" url="$2" body="${3:-}"
  shift 3

  local tmp_body tmp_hdr http_code
  tmp_body=$(mktemp)
  tmp_hdr=$(mktemp)

  local -a curl_args=(-sS -X "${method}" "${url}")
  local -a req_hdr_lines=()

  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-H" && -n "${2:-}" ]]; then
      curl_args+=("-H" "$2")
      req_hdr_lines+=("$2")
      shift 2
      continue
    fi
    curl_args+=("$1")
    shift
  done

  if [[ -n "${body}" ]]; then
    curl_args+=(-H "Content-Type: application/json" -d "${body}")
  fi

  if verbose_enabled; then
    {
      echo ">>> ${method} ${url}"
      echo ">>> Request headers:"
      if ((${#req_hdr_lines[@]})); then
        printf '%s\n' "${req_hdr_lines[@]}"
      fi
      if [[ -n "${body}" ]]; then
        echo "Content-Type: application/json"
      fi
    } | _redact_secrets >&2
    if [[ -n "${body}" ]]; then
      _verbose_log_body ">>> Request body:" "${body}"
    fi
  fi

  http_code=$(curl "${curl_args[@]}" -D "${tmp_hdr}" -o "${tmp_body}" -w "%{http_code}")

  if verbose_enabled; then
    {
      echo "<<< HTTP ${http_code}"
      echo "<<< Response headers:"
      cat "${tmp_hdr}"
    } | _redact_secrets >&2
    _verbose_log_body "<<< Response body:" "$(cat "${tmp_body}")"
    echo >&2
  fi

  cat "${tmp_body}"
  rm -f "${tmp_body}" "${tmp_hdr}"
  CURL_LAST_HTTP_CODE="${http_code}"
}

step() {
  echo
  echo "=== [$1] $2 ==="
}

json_pretty() {
  python3 -m json.tool 2>/dev/null || cat
}

# Step 1: Authenticate to Authentik (IdP) and obtain an OIDC access token.
idp_login() {
  local user="${1:-$LIBCLOUD_USER}"
  local password="${2:-$LIBCLOUD_PASSWORD}"
  : "${password:?Password required for user ${user}}"

  step "1" "Dex IdP login (OIDC authorization code flow) user=${user}"
  export LIBCLOUD_USER="${user}" LIBCLOUD_PASSWORD="${password}"
  if verbose_enabled; then
    export IDP_LOGIN_VERBOSE=1
  fi
  ACCESS_TOKEN=$(python3 "${SCRIPT_DIR}/idp_login.py")
  unset IDP_LOGIN_VERBOSE 2>/dev/null || true
  echo "access_token acquired (${#ACCESS_TOKEN} chars)"
}

# Step 2: OpenFGA authorization checks mirroring libcloud REST policy enforcement.
# OpenFGA runs with OIDC authn: forward the caller's Dex access token as a
# Bearer header (same IdP + audience as the REST API).
fga_check() {
  local user="$1" relation="$2" object="$3"
  local payload
  payload=$(python3 -c "import json; print(json.dumps({'authorization_model_id':'${FGA_MODEL_ID}','tuple_key':{'user':'${user}','relation':'${relation}','object':'${object}'}}))")
  local raw allowed http tmp
  tmp=$(mktemp)
  local -a hdrs=(-H "Content-Type: application/json" -H "Accept: application/json")
  if [[ -n "${ACCESS_TOKEN:-}" ]]; then
    hdrs+=(-H "Authorization: Bearer ${ACCESS_TOKEN}")
  fi
  curl_http POST "${FGA_API_URL}/stores/${FGA_STORE_ID}/check" "${payload}" "${hdrs[@]}" > "${tmp}"
  http="${CURL_LAST_HTTP_CODE}"
  raw=$(cat "${tmp}")
  rm -f "${tmp}"
  allowed=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("allowed", False))' <<<"${raw}")
  echo "Check ${user} ${relation} ${object} -> allowed=${allowed} (HTTP ${http})"
  [[ "$allowed" == "True" || "$allowed" == "true" ]]
}

openfga_authorization_flow() {
  local provider="$1"
  local backend_object="$2"
  local fga_user="user:${LIBCLOUD_USER}"

  step "2" "OpenFGA authorization checks for ${fga_user}"
  fga_check "${fga_user}" "can_connect" "${FGA_API_OBJECT}"
  fga_check "${fga_user}" "can_use" "provider:${provider}"
  case "${LIBCLOUD_USER}" in
    reader|cloud-readonly|*-viewer)
      fga_check "${fga_user}" "can_read" "${backend_object}" ;;
    *)
      fga_check "${fga_user}" "can_provision" "${backend_object}" ;;
  esac
}

# Step 3: Validate token against libcloud REST API.
libcloud_me() {
  step "3" "libcloud REST API token validation (/v1/auth/me)"
  curl_http GET "${LIBCLOUD_REST_URL}/v1/auth/me" "" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Accept: application/json" | json_pretty
}

# Step 4: Test backend connectivity through libcloud REST.
libcloud_connection_test() {
  local connection_json="$1"
  step "4" "libcloud REST connection test (/v1/connections:test)"
  curl_http POST "${LIBCLOUD_REST_URL}/v1/connections:test" "${connection_json}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Accept: application/json" | json_pretty
}

libcloud_api() {
  local method="$1" path="$2" body="${3:-}"
  local -a extra=()
  # Send the provider connection via the X-Provider-Connection header (never via
  # the `?connection=` query parameter, which leaks into logs/proxies/history).
  if [[ -n "${CONNECTION_PARAM}" ]]; then
    extra+=("-H" "X-Provider-Connection: ${CONNECTION_PARAM}")
  fi
  curl_http "${method}" "${LIBCLOUD_REST_URL}${path}" "${body}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Accept: application/json" \
    "${extra[@]}"
}

# Build a connection descriptor that selects a SERVER-SIDE backend identity
# (auth_binding). The client never handles backend cloud credentials; the REST
# API uses its own IAM role / service account. CONNECTION_PARAM is plain JSON
# (sent via the X-Provider-Connection header, not URL-encoded query).
build_aws_connection_param() {
  local region="${1:-${AWS_REGION:-ap-southeast-1}}"
  # auth_binding selects the per-tenant Vault secret at
  # secret/data/libcloud/<binding>. Default "aws" -> tenant:aws credentials,
  # written by the aws-owner via scripts/set_tenant_credentials.py.
  local binding="${LIBCLOUD_AWS_AUTH_BINDING:-aws}"
  CONNECTION_PARAM=$(AWS_REGION_VAL="${region}" AWS_BINDING_VAL="${binding}" python3 -c "
import json, os
print(json.dumps({
    'provider': 'aws',
    'config': {'region': os.environ['AWS_REGION_VAL'], 'secure': True},
    'auth_binding': os.environ['AWS_BINDING_VAL'],
}, separators=(',', ':')))
")
  export CONNECTION_PARAM AWS_REGION="$region"
}

build_nutanix_connection_param() {
  # auth_binding selects the per-tenant Vault secret at
  # secret/data/libcloud/<binding>. Default "nutanix" -> tenant:nutanix
  # credentials, written by the ntnx-owner via set_tenant_credentials.py.
  local binding="${LIBCLOUD_NTNX_AUTH_BINDING:-nutanix}"
  CONNECTION_PARAM=$(NTNX_HOST="${NUTANIX_HOST:-host.docker.internal}" \
    NTNX_PORT="${NUTANIX_PORT:-9440}" \
    NTNX_API_VERSION="${NUTANIX_API_VERSION:-v4.0}" \
    NTNX_VERIFY_SSL="${NUTANIX_VERIFY_SSL:-false}" \
    NTNX_BINDING_VAL="${binding}" python3 -c "
import json, os
print(json.dumps({
    'provider': 'nutanix',
    'config': {
        'host': os.environ['NTNX_HOST'],
        'port': int(os.environ['NTNX_PORT']),
        'secure': True,
        'api_version': os.environ['NTNX_API_VERSION'],
        'verify_ssl_cert': os.environ['NTNX_VERIFY_SSL'].lower() in ('1','true','yes'),
    },
    'auth_binding': os.environ['NTNX_BINDING_VAL'],
}, separators=(',', ':')))
")
  export CONNECTION_PARAM
}

connection_json() {
  CONNECTION_PARAM="${CONNECTION_PARAM}" python3 -c "import json,os; print(json.dumps(json.loads(os.environ['CONNECTION_PARAM']), indent=2))"
}

with_connection() {
  CONNECTION_PARAM="${CONNECTION_PARAM}" python3 -c "
import json, os, sys
conn = json.loads(os.environ['CONNECTION_PARAM'])
body = json.loads(sys.argv[1])
body['connection'] = conn
print(json.dumps(body))
" "$1"
}

# Tear down libcloud demo VMs created during this run.
#
# When TEARDOWN_VMS=1, list /v1/compute/nodes, find the VMs whose name matches
# the libcloud-demo-* / libcloud-ntnx-* prefixes used by the provision scripts,
# and DELETE them. An optional argument narrows the match to a single VM_NAME
# (used by the provision scripts to scope teardown to the VM just created).
teardown_libcloud_vms() {
  local only_name="${1:-}"
  local prefixes=("libcloud-demo-" "libcloud-ntnx-")
  local prefix_args=()
  local p
  for p in "${prefixes[@]}"; do
    prefix_args+=("${p}")
  done

  step "8" "Teardown: listing /v1/compute/nodes and deleting libcloud demo VMs"

  local nodes_resp ids
  nodes_resp=$(libcloud_api GET "/v1/compute/nodes")
  echo "${nodes_resp}" | json_pretty

  ids=$(VM_NAME_FILTER="${only_name}" python3 -c "
import json, os, sys
filter_name = os.environ.get('VM_NAME_FILTER', '')
prefixes = ['libcloud-demo-', 'libcloud-ntnx-']
data = json.load(sys.stdin)
nodes = data.get('data', []) if isinstance(data, dict) else data
out = []
for n in nodes:
    name = n.get('name', '')
    nid = n.get('id', '')
    if not name or not nid:
        continue
    if filter_name and name != filter_name:
        continue
    if not filter_name and not any(name.startswith(pfx) for pfx in prefixes):
        continue
    out.append(nid + '\t' + name)
print('\n'.join(out))
" <<<"${nodes_resp}")

  if [[ -z "${ids}" ]]; then
    echo "No matching libcloud demo VMs found to delete."
    return 0
  fi

  local id name count=0
  while IFS=$'\t' read -r id name; do
    [[ -z "${id}" ]] && continue
    count=$((count + 1))
    echo "Deleting node id=${id} name=${name}"
    libcloud_api DELETE "/v1/compute/nodes/${id}" | json_pretty
  done <<<"${ids}"

  echo "Teardown complete: deleted ${count} libcloud demo VM(s)."
}
