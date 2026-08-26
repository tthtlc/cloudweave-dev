#!/usr/bin/env bash
# =============================================================================
# list_vms_curl.sh - bash+curl port of the C# sample
#   "Nutanix v4 API Demo - List VMs"
#   (code-samples/csharp/v4api_client/list_vms/Nutanix v4 API Demo - List VMs/Program.cs)
#
# Original C# demo:
#   * GET https://<pc>:9440/api/vmm/v4.2/ahv/config/vms
#   * Basic auth (username/password) on that single request
#   * Accept: application/json + X-Correlation-Id headers
#   * prints "Total available results (across pages): <metadata.totalAvailableResults>"
#
# This port differs in ONE respect, as requested:
#   * the session cookie obtained by iam_login() (Basic auth from .env,
#     same credentials as the IAM scripts) is used for access control
#     instead of a Basic Authorization header on the VM request.
#
# Requires Prism Central 7.5+ / AOS 7.5+ (as per the original sample).
#
# Usage:
#   ./list_vms_curl.sh                list VMs, print totalAvailableResults
#   ./list_vms_curl.sh '$page=0' '$limit=10'   paginate via extra query args
#   CURL_DRY_RUN=1 ./list_vms_curl.sh          show the curl command only
# =============================================================================

set -u
set -x
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IAM_BASE_PATH="/iam/v4.2/authn"   # endpoint used by iam_login()
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

# VM list endpoint (v4.2 ahv config vms - same URL as the C# demo)
VM_URL="${API_BASE}/vmm/v4.2/ahv/config/vms"

# C# demo's User-Agent (kept for parity)
USER_AGENT="Nutanix_v4_API_Demo___List_VMs/1.0 (+https://www.nutanix.dev)"

# extra args in "name=value" form become URL query parameters ($page, $limit, ...)
query=""
for pair in "$@"; do
    [[ -z "${pair}" ]] && continue
    query="${query}${query:+&}$(_urlenc "${pair}")"
done
full_url="${VM_URL}${query:+?${query}}"

# --- authenticate once via IAM, then use ONLY the session cookie ------------
iam_login || exit 1

echo "==> GET ${full_url} (auth: session cookie from IAM login)" >&2

if [[ "${CURL_DRY_RUN:-0}" == "1" ]]; then
    printf 'curl '
    printf '%q ' "${CURL_K[@]}" -X GET -b "${COOKIE_JAR}" \
        -H "Accept: application/json" -H "User-Agent: ${USER_AGENT}" -H "X-Correlation-Id: ${CORRELATION_ID}"
    printf '%q\n' "${full_url}"
    exit 0
fi

resp=$(curl "${CURL_K[@]}" -sS \
    -X GET \
    -b "${COOKIE_JAR}" \
    -H "Accept: application/json" \
    -H "User-Agent: ${USER_AGENT}" \
    -H "X-Correlation-Id: ${CORRELATION_ID}" \
    -w $'\n__HTTP_STATUS__:%{http_code}' \
    "${full_url}") || {
    echo "An error occurred while making the request (e.g. network, request properties, authentication)." >&2
    exit 1
}

status="${resp##*$'\n'__HTTP_STATUS__:}"
body="${resp%$'\n'__HTTP_STATUS__:*}"

# verify the request was successful (mirrors the C# IsSuccessStatusCode check)
if [[ "${status}" -ge 400 ]]; then
    echo "Request failed: ${status}" >&2
    printf '%s\n' "${body}" >&2
    exit 1
fi

# print the raw JSON response to stdout (jq-formatted when available)
if [[ "${NTNX_PRETTY:-1}" == "1" ]] && command -v jq >/dev/null 2>&1; then
    printf '%s' "${body}" | jq . 2>/dev/null || printf '%s\n' "${body}"
else
    printf '%s\n' "${body}"
fi

# response metadata: totalAvailableResults (exactly like the C# demo)
total=$(printf '%s' "${body}" | python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
    meta = doc.get("metadata") or {}
    print(meta.get("totalAvailableResults", ""))
except Exception:
    pass
')
if [[ -n "${total}" ]]; then
    echo "Total available results (across pages): ${total}"
fi
