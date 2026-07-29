#!/usr/bin/env bash
# nutanix_lifecycle_benchmark.sh
# =================================
# Provision N Nutanix VMs one at a time, capture per-VM start/end time, then
# deprovision all of them and capture per-VM start/end time. Finally print a
# summary: total + average + min + max for provisioning and deprovisioning.
#
# Catalog discovery (locations/images/sizes/subnets) is done ONCE, then the
# same resolved IDs are reused for every VM, so the timing reflects the actual
# create/delete round trip rather than repeated discovery.
#
# Uses ONLY curl + jq (no python), mirroring deprovision_nutanix.sh. common.sh
# is sourced ONLY to load environment variables (.env / generated env); none of
# its python-based helpers are called.
#
# Authorization: each call carries the provisioner's Dex-issued bearer token
# (audience libcloud-rest), which OpenFGA and the libcloud REST API both
# accept. Run as a tenant owner/admin (e.g. ntnx-owner / ntnx-admin) so the
# OpenFGA can_provision check on nutanix_cluster:<binding> passes.
#
# Usage:
#   N=50 LIBCLOUD_USER=ntnx-admin ./scripts/nutanix_lifecycle_benchmark.sh
#   N=50 LIBCLOUD_USER=ntnx-owner VM_NAME_PREFIX=libcloud-ntnx-bench \
#       ./scripts/nutanix_lifecycle_benchmark.sh
#   N=20 LIBCLOUD_USER=ntnx-admin SKIP_DEPROVISION=1 \
#       ./scripts/nutanix_lifecycle_benchmark.sh   # leave VMs running
#
# Environment:
#   N                   number of VMs to provision (default 50)
#   VM_NAME_PREFIX      VM name prefix (default libcloud-ntnx-bench)
#   LIBCLOUD_USER       LLDAP uid with can_provision on the Nutanix tenant
#                       (default ntnx-admin)
#   LIBCLOUD_NTNX_AUTH_BINDING  tenant / auth_binding (default nutanix)
#   SIZE_ID             size id (default "small"; resolved from catalog if set)
#   IMAGE_ID            image id (resolved from catalog if unset)
#   CLUSTER_ID          cluster id (resolved from catalog if unset)
#   SUBNET_ID           subnet id (resolved from catalog if unset)
#   SKIP_DEPROVISION    if "1", do not deprovision after provisioning
#   CONCURRENCY         reserved for future; currently sequential (1)
#
# Prerequisites:
#   ./setup.sh  and  a token cache for the user at generated/tokens/<user>.json
#   (created by ./scripts/provision_nutanix.sh or scripts/idp_login.py).
set -euo pipefail

N="${N:-50}"
VM_NAME_PREFIX="${VM_NAME_PREFIX:-libcloud-ntnx-bench}"
SKIP_DEPROVISION="${SKIP_DEPROVISION:-0}"

# Default to the Nutanix tenant admin (can_provision). Set BEFORE sourcing
# common.sh so its password/env resolution picks up the right user.
export LIBCLOUD_USER="${LIBCLOUD_USER:-ntnx-admin}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"   # env vars only; we never call its python helpers

LIBCLOUD_NTNX_AUTH_BINDING="${LIBCLOUD_NTNX_AUTH_BINDING:-${TENANT:-nutanix}}"
NUTANIX_BACKEND_OBJECT="nutanix_cluster:${LIBCLOUD_NTNX_AUTH_BINDING}"
DEX_TOKEN_URL="${DEX_TOKEN_URL:-${DEX_URL}/dex/token}"
ACCESS_TOKEN=""
CONNECTION_PARAM=""

# Output files (per-VM CSV + summary). Under generated/ so it is gitignored.
RUN_ID="$(date +%Y%m%dT%H%M%S)"
OUT_DIR="${REPO_ROOT}/generated/benchmark"
mkdir -p "${OUT_DIR}"
PROV_CSV="${OUT_DIR}/nutanix_provision_${RUN_ID}.csv"
DEPROV_CSV="${OUT_DIR}/nutanix_deprovision_${RUN_ID}.csv"
SUMMARY_TXT="${OUT_DIR}/nutanix_summary_${RUN_ID}.txt"

# --------------------------------------------------------------------------- #
# curl + jq helpers (no python)
# --------------------------------------------------------------------------- #

# Acquire an OIDC access token. We reuse common.sh's `idp_login` (which runs
# idp_login.py): it refreshes from a cached refresh_token if present, otherwise
# performs a full Dex password login and caches the result. This handles
# expired access tokens automatically — important because this deployment's
# Dex password grant does NOT issue refresh_tokens, so a stale cache must be
# re-logged, not just read. Requires LIBCLOUD_PASSWORD (resolved by common.sh
# from LIBCLOUD_PASSWORD_NTNX_ADMIN / the dev default when LIBCLOUD_USER is
# ntnx-admin).
#
# PORT COLLISION WORKAROUND (now mostly moot): idp_login.py binds
# 127.0.0.1:<redirect port> to capture the OAuth callback. Its default
# redirect URI is now http://127.0.0.1:8767/oauth/callback (registered on the
# libcloud-rest Dex client), and 8767 is NOT published by any container — so
# idp_login.py no longer collides with the `identity-service` container
# (which publishes :8766 for the RUNTIME portal callback). The stop/start
# logic below is retained as a defensive fallback: if a caller overrides
# LIBCLOUD_OIDC_REDIRECT_URI back to 8766 (or any port held by
# identity-service), we still briefly stop the container for the login. Set
# BENCHMARK_KEEP_IDENTITY_DOWN=1 to leave it stopped.
_IDENTITY_CONTAINER="identity-service"
_identity_was_running=0

_port_in_use() {
  local port="$1"
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"
}

require_token() {
  if ! command -v idp_login >/dev/null 2>&1; then
    echo "FATAL: common.sh idp_login() not available." >&2
    return 1
  fi
  local redir="${LIBCLOUD_OIDC_REDIRECT_URI:-http://127.0.0.1:8767/oauth/callback}"
  local port
  port=$(printf '%s' "${redir}" | sed -E 's#.*://[^/:]*:([0-9]+).*#\1#; t; s#.*://[^/:]*(/|$).*#8767#')
  # If the redirect port is taken AND it's the identity-service container,
  # briefly stop it so idp_login.py can bind the callback socket.
  if _port_in_use "${port}"; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${_IDENTITY_CONTAINER}"; then
      _identity_was_running=1
      echo "[benchmark] port ${port} in use by ${_IDENTITY_CONTAINER}; stopping it for login" >&2
      docker stop "${_IDENTITY_CONTAINER}" >/dev/null
      trap '_restart_identity' EXIT
    else
      echo "FATAL: redirect port ${port} is in use but not by ${_IDENTITY_CONTAINER}." >&2
      echo "       Free it, or set LIBCLOUD_OIDC_REDIRECT_URI to a free, Dex-registered port." >&2
      return 1
    fi
  fi
  idp_login "${LIBCLOUD_USER}" "${LIBCLOUD_PASSWORD}"
}

_restart_identity() {
  if [[ "${_identity_was_running:-0}" == "1" && "${BENCHMARK_KEEP_IDENTITY_DOWN:-0}" != "1" ]]; then
    echo "[benchmark] restarting ${_IDENTITY_CONTAINER}" >&2
    docker start "${_IDENTITY_CONTAINER}" >/dev/null 2>&1 || true
    _identity_was_running=0
  fi
}

# Build the X-Provider-Connection header value (provider + nutanix config +
# auth_binding, NO credentials) with jq. The REST API resolves the backend
# Nutanix credentials server-side from Vault using auth_binding.
connection_param() {
  local host="${NUTANIX_HOST:-host.docker.internal}"
  local port="${NUTANIX_PORT:-9440}"
  local api_version="${NUTANIX_API_VERSION:-v4.0}"
  local verify_ssl="${NUTANIX_VERIFY_SSL:-false}"
  local ssl_bool="false"
  case "${verify_ssl}" in
    1|true|True|TRUE|yes|Yes|YES) ssl_bool="true" ;;
  esac
  jq -nc --arg host "${host}" --argjson port "${port}" --arg api_version "${api_version}" \
       --argjson ssl "${ssl_bool}" --arg binding "${LIBCLOUD_NTNX_AUTH_BINDING}" \
    '{provider:"nutanix",config:{host:$host,port:$port,secure:true,api_version:$api_version,verify_ssl_cert:$ssl},auth_binding:$binding}'
}

# libcloud REST call: curl with Bearer + X-Provider-Connection headers.
# Usage: rest <method> <path> [body]
rest() {
  local method="$1" path="$2" body="${3:-}"
  local -a args=(
    -sS -X "${method}" "${LIBCLOUD_REST_URL}${path}"
    -H "Authorization: Bearer ${ACCESS_TOKEN}"
    -H "Accept: application/json"
    -H "X-Provider-Connection: ${CONNECTION_PARAM}"
  )
  if [[ -n "${body}" ]]; then
    args+=(-H "Content-Type: application/json" -d "${body}")
  fi
  curl "${args[@]}"
}

# Wall-clock milliseconds since the epoch (GNU date).
now_ms() { date +%s%3N; }

# Convert ms to seconds with 3 decimals for human-readable output.
ms_to_s() { awk -v ms="$1" 'BEGIN{printf "%.3f", ms/1000}'; }

# --------------------------------------------------------------------------- #
# OpenFGA check (curl + jq). Returns 0 if allowed, 1 otherwise.
# --------------------------------------------------------------------------- #
fga_check() {
  local u="$1" rel="$2" obj="$3" body http allowed
  body=$(jq -nc --arg m "${FGA_MODEL_ID}" --arg u "${u}" --arg r "${rel}" --arg o "${obj}" \
    '{authorization_model_id:$m,tuple_key:{user:$u,relation:$r,object:$o}}')
  local -a hdrs=(-H "Content-Type: application/json" -H "Accept: application/json")
  if [[ -n "${ACCESS_TOKEN:-}" ]]; then
    hdrs+=(-H "Authorization: Bearer ${ACCESS_TOKEN}")
  fi
  http=$(curl -sS -o /tmp/fga_resp.$$ -w "%{http_code}" -X POST \
    "${FGA_API_URL}/stores/${FGA_STORE_ID}/check" "${hdrs[@]}" -d "${body}")
  if [[ "${http}" != "200" ]]; then
    echo "Check ${u} ${rel} ${obj} -> HTTP ${http}: $(cat /tmp/fga_resp.$$ 2>/dev/null)" >&2
    echo "  (401 invalid_claims usually means the access token is expired or" >&2
    echo "   OpenFGA's JWKS cache is stale — re-login, or restart the openfga container.)" >&2
    rm -f /tmp/fga_resp.$$
    return 1
  fi
  allowed=$(jq -r '.allowed // false' /tmp/fga_resp.$$)
  rm -f /tmp/fga_resp.$$
  echo "Check ${u} ${rel} ${obj} -> allowed=${allowed} (HTTP ${http})" >&2
  [[ "${allowed}" == "true" ]]
}

# --------------------------------------------------------------------------- #
# Catalog discovery (done ONCE). Resolves CLUSTER_ID / IMAGE_ID / SIZE_ID /
# SUBNET_ID from the live catalog, unless the caller preset them.
# --------------------------------------------------------------------------- #
discover_catalog() {
  step "3" "Catalog discovery (locations, sizes, images, subnets)"
  CLUSTER_ID="${CLUSTER_ID:-$(rest GET "/v1/compute/locations" | jq -r '(.data // .) | .[0].id // empty')}"
  IMAGE_ID="${IMAGE_ID:-$(rest GET "/v1/compute/images" | jq -r '(.data // .) | .[0].id // empty')}"
  # SIZE_ID defaults to "small" (matches provision_nutanix.sh); override if the
  # caller did not preset it and the catalog exposes a first size id.
  if [[ -z "${SIZE_ID:-}" ]]; then
    SIZE_ID="$(rest GET "/v1/compute/sizes" | jq -r '(.data // .) | .[0].id // empty')"
    [[ -n "${SIZE_ID}" ]] || SIZE_ID="small"
  fi
  SUBNET_ID="${SUBNET_ID:-$(rest GET "/v1/compute/subnets" | jq -r '(.data // .) | .[0].id // empty')}"

  echo "  CLUSTER_ID=${CLUSTER_ID}"
  echo "  IMAGE_ID=${IMAGE_ID}"
  echo "  SIZE_ID=${SIZE_ID}"
  echo "  SUBNET_ID=${SUBNET_ID:-<none>}"

  if [[ -z "${CLUSTER_ID}" || -z "${IMAGE_ID}" ]]; then
    echo "FATAL: could not resolve CLUSTER_ID/IMAGE_ID from the catalog." >&2
    return 1
  fi
}

# Build the JSON body for creating one Nutanix VM (mirrors provision_nutanix.sh).
create_body() {
  local name="$1"
  jq -nc \
    --arg name "${name}" \
    --arg size_id "${SIZE_ID}" \
    --arg image_id "${IMAGE_ID}" \
    --arg cluster_id "${CLUSTER_ID}" \
    --arg subnet_id "${SUBNET_ID:-}" \
    '{
      name: $name,
      size: {id: $size_id},
      image: {id: $image_id},
      location: {id: $cluster_id},
      provider_options: {}
    } as $b
    | if ($subnet_id | length) > 0
      then $b + {network: {subnet_id: $subnet_id}}
      else $b end'
}

# --------------------------------------------------------------------------- #
# Provision phase: create N VMs, one at a time, recording per-VM timing.
# Emits one CSV row per VM: index,name,vm_id,start_ms,end_ms,duration_ms,status
# --------------------------------------------------------------------------- #
provision_phase() {
  local i name body resp vm_id start end dur status
  echo "index,name,vm_id,start_ms,end_ms,duration_ms,status" > "${PROV_CSV}"
  step "4" "Provisioning ${N} Nutanix VM(s) sequentially"
  for i in $(seq 1 "${N}"); do
    name="${VM_NAME_PREFIX}-${RUN_ID}-$(printf '%03d' "${i}")"
    body="$(create_body "${name}")"
    start="$(now_ms)"
    resp="$(rest POST "/v1/compute/nodes" "${body}" 2>/dev/null || true)"
    end="$(now_ms)"
    dur=$((end - start))
    # Prefer the id from the create response; fall back to a name lookup.
    vm_id="$(printf '%s' "${resp}" | jq -r '.data.id // .id // empty' 2>/dev/null || true)"
    if [[ -z "${vm_id}" ]]; then
      vm_id="$(rest GET "/v1/compute/nodes" 2>/dev/null \
        | jq -r --arg n "${name}" '(.data // .) | .[] | select(.name == $n) | .id' 2>/dev/null || true)"
    fi
    if [[ -n "${vm_id}" ]]; then
      status="ok"
      printf '%s,%s,%s,%s,%s,%s,%s\n' "${i}" "${name}" "${vm_id}" "${start}" "${end}" "${dur}" "${status}" >> "${PROV_CSV}"
      printf '  [%3d/%d] provisioned %s (id=%s) in %s s\n' "${i}" "${N}" "${name}" "${vm_id}" "$(ms_to_s "${dur}")"
    else
      status="failed"
      printf '%s,%s,%s,%s,%s,%s,%s\n' "${i}" "${name}" "" "${start}" "${end}" "${dur}" "${status}" >> "${PROV_CSV}"
      printf '  [%3d/%d] FAILED to provision %s after %s s\n' "${i}" "${N}" "${name}" "$(ms_to_s "${dur}")" >&2
    fi
  done
}

# --------------------------------------------------------------------------- #
# Deprovision phase: delete every VM that was successfully provisioned, by id
# (precise, no list+filter pass). Emits one CSV row per VM.
# --------------------------------------------------------------------------- #
deprovision_phase() {
  local vm_id vm_name start end dur status
  echo "index,name,vm_id,start_ms,end_ms,duration_ms,status" > "${DEPROV_CSV}"
  step "5" "Deprovisioning provisioned Nutanix VM(s) by id"
  # Only deprovision rows that have a vm_id (status=ok).
  local rows
  rows="$(awk -F, '$3 != "" {print}' "${PROV_CSV}")"
  if [[ -z "${rows}" ]]; then
    echo "  No successfully provisioned VMs to deprovision."
    return 0
  fi
  local idx=0
  while IFS=, read -r i name vm_id rest; do
    idx=$((idx + 1))
    start="$(now_ms)"
    rest_resp="$(rest DELETE "/v1/compute/nodes/${vm_id}" 2>/dev/null || true)"
    end="$(now_ms)"
    dur=$((end - start))
    # Treat a 2xx (or empty/JSON success) as ok; rest() returns the body.
    if printf '%s' "${rest_resp}" | jq -e '.destroyed == true or .id != null or (.data.id != null)' >/dev/null 2>&1 \
       || [[ -z "${rest_resp}" ]]; then
      status="ok"
    else
      status="failed"
    fi
    printf '%s,%s,%s,%s,%s,%s,%s\n' "${idx}" "${name}" "${vm_id}" "${start}" "${end}" "${dur}" "${status}" >> "${DEPROV_CSV}"
    printf '  [%3d] deprovisioned %s (id=%s) in %s s [%s]\n' "${idx}" "${name}" "${vm_id}" "$(ms_to_s "${dur}")" "${status}"
  done <<<"${rows}"
}

# --------------------------------------------------------------------------- #
# Summary: total / avg / min / max / count for provisioning and deprovisioning,
# computed from the CSVs with awk. Written to SUMMARY_TXT and printed.
# --------------------------------------------------------------------------- #
summarize_column() {
  # $1 = csv file, $2 = column index (1-based) of duration_ms
  local file="$1" col="$2"
  awk -F, -v c="${col}" '
    NR > 1 && $NF == "ok" {
      n++; sum += $c
      if (min == "" || $c < min) min = $c
      if (max == "" || $c > max) max = $c
    }
    END {
      if (n == 0) { print "0,0,0,0,0"; exit }
      printf "%d,%.3f,%.3f,%.3f,%.3f\n", n, sum/1000, sum/n/1000, min/1000, max/1000
    }
  ' "${file}"
}

summarize() {
  local prov deprov
  prov="$(summarize_column "${PROV_CSV}" 6)"
  deprov="$(summarize_column "${DEPROV_CSV}" 6)"

  local p_n p_total p_avg p_min p_max
  IFS=, read -r p_n p_total p_avg p_min p_max <<<"${prov}"
  local d_n d_total d_avg d_min d_max
  IFS=, read -r d_n d_total d_avg d_min d_max <<<"${deprov}"

  {
    echo "================================================================"
    echo " Nutanix lifecycle benchmark summary"
    echo "   run_id        : ${RUN_ID}"
    echo "   user          : ${LIBCLOUD_USER}"
    echo "   auth_binding  : ${LIBCLOUD_NTNX_AUTH_BINDING}"
    echo "   requested VMs : ${N}"
    echo "   provision CSV : ${PROV_CSV}"
    echo "   deprovision CSV: ${DEPROV_CSV}"
    echo "================================================================"
    echo
    echo " Provisioning"
    printf  "   VMs succeeded : %s\n" "${p_n}"
    printf  "   total time    : %s s\n" "${p_total}"
    printf  "   average / VM  : %s s\n" "${p_avg}"
    printf  "   min / VM      : %s s\n" "${p_min}"
    printf  "   max / VM      : %s s\n" "${p_max}"
    echo
    echo " Deprovisioning"
    printf  "   VMs succeeded : %s\n" "${d_n}"
    printf  "   total time    : %s s\n" "${d_total}"
    printf  "   average / VM  : %s s\n" "${d_avg}"
    printf  "   min / VM      : %s s\n" "${d_min}"
    printf  "   max / VM      : %s s\n" "${d_max}"
    echo
    echo " Grand total (provision + deprovision): $(awk -v a="${p_total}" -v b="${d_total}" 'BEGIN{printf "%.3f", a+b}') s"
    echo "================================================================"
  } | tee "${SUMMARY_TXT}"
  echo
  echo "Summary written to ${SUMMARY_TXT}"
}

# --------------------------------------------------------------------------- #
# Flow
# --------------------------------------------------------------------------- #
step "0" "Nutanix lifecycle benchmark: N=${N} user=${LIBCLOUD_USER} binding=${LIBCLOUD_NTNX_AUTH_BINDING}"
require_token   # idp_login prints its own "access_token acquired (...)" line
CONNECTION_PARAM=$(connection_param)

step "2" "OpenFGA authorization checks (curl)"
fga_check "user:${LIBCLOUD_USER}" "can_connect" "${FGA_API_OBJECT}"
fga_check "user:${LIBCLOUD_USER}" "can_use" "provider:nutanix"
fga_check "user:${LIBCLOUD_USER}" "can_provision" "${NUTANIX_BACKEND_OBJECT}"

discover_catalog

provision_phase

if [[ "${SKIP_DEPROVISION}" == "1" ]]; then
  echo
  echo "SKIP_DEPROVISION=1 -> leaving VMs running. Provision CSV: ${PROV_CSV}"
else
  deprovision_phase
fi

echo
summarize

echo
echo "Nutanix lifecycle benchmark completed (user=${LIBCLOUD_USER}, binding=${LIBCLOUD_NTNX_AUTH_BINDING})."



