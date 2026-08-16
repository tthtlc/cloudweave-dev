#!/usr/bin/env bash
#
# query_nutanix_v4.sh — talk directly to a Nutanix Prism Central v4 REST API
# (bypassing libcloud/Vault/Dex) to enumerate servers (VMs), networks (VPCs),
# subnets, clusters, images, etc.
#
# It pulls the connection details from the same files the rest of the repo uses:
#   .env                    -> NUTANIX_HOST, NUTANIX_PORT, NUTANIX_API_VERSION,
#                              NUTANIX_VERIFY_SSL
#   tenant_vault_secret.env -> LIBCLOUD_NTNX_USER, LIBCLOUD_NTNX_PASSWORD
#
# Auth is HTTP Basic (same scheme as libcloud/libcloud/common/nutanix.py).
#
# Usage:
#   ./query_nutanix_v4.sh                 # enumerate everything (VMs, clusters,
#                                         #   VPCs, subnets, images)
#   ./query_nutanix_v4.sh vms             # only VMs
#   ./query_nutanix_v4.sh vpcs subnets    # several resources
#   ./query_nutanix_v4.sh list            # show available resource keys
#   ./query_nutanix_v4.sh vms --summary   # name + extId only (compact table)
#
# Env overrides (optional): NUTANIX_HOST, NUTANIX_PORT, NUTANIX_API_VERSION,
#   NUTANIX_VERIFY_SSL, LIBCLOUD_NTNX_USER, LIBCLOUD_NTNX_PASSWORD

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
TENANT_ENV_FILE="${REPO_ROOT}/tenant_vault_secret.env"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# Extract a KEY=VALUE from an env file. Handles optional `export` prefix and
# single/double quotes. Returns nonzero if the key is absent.
get_env() {
    local file="$1" key="$2"
    grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null \
        | head -n1 \
        | sed -E 's/^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=//' \
        | sed -E 's/^["'"'"']//; s/["'"'"'][[:space:]]*$//'
}

# Fetch one page and return the raw JSON body via stdin. `page` is 0-based.
raw_page() {
    local path="$1" limit="$2" page="$3"
    curl -sS --connect-timeout 5 --max-time 30 ${CURL_OPTS[*]:-} \
        -H "Authorization: Basic ${AUTH}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "NTNX-Request-Id: ${REQ_ID}" \
        "${BASE_URL}${path}?\$limit=${limit}&\$page=${page}"
}

# Fetch a list endpoint, follow pagination, print one JSON object per line
# (JSONL) on stdout.
api_list() {
    local path="$1"
    local limit=100 page=0
    local body total

    while :; do
        body="$(raw_page "$path" "$limit" "$page")"
        # A page with no `data` array means we are done (or nothing exists).
        if ! printf '%s' "$body" | jq -e '.data' >/dev/null 2>&1; then
            break
        fi
        total="$(printf '%s' "$body" | jq '.data | length')"
        if [ "$total" -eq 0 ]; then
            break
        fi
        printf '%s' "$body" | jq -c '.data[]'
        if [ "$total" -lt "$limit" ]; then
            break
        fi
        page=$((page + 1))
    done
}

# ---------------------------------------------------------------------------
# resource table: key -> endpoint path (relative to BASE_URL)
# ---------------------------------------------------------------------------

RESOURCES=(
    # key           path
    vms             "/api/vmm/v4.0/ahv/config/vms"
    clusters        "/api/clustermgmt/v4.0/config/clusters"
    vpcs            "/api/networking/v4.0/config/vpcs"
    subnets         "/api/networking/v4.0/config/subnets"
    images          "/api/vmm/v4.0/content/images"
    templates       "/api/vmm/v4.0/content/templates"
    storage         "/api/vmm/v4.0/config/storage-containers"
    security-groups "/api/networking/v4.0/config/network-security-policies"
    floating-ips    "/api/networking/v4.0/config/floating-ips"
)

path_for() {
    local key="$1"
    local i=0
    while [ "$i" -lt "${#RESOURCES[@]}" ]; do
        if [ "${RESOURCES[$i]}" = "$key" ]; then
            echo "${RESOURCES[$((i + 1))]}"
            return 0
        fi
        i=$((i + 2))
    done
    return 1
}

usage() {
    sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# load connection settings
# ---------------------------------------------------------------------------

if [ ! -f "$ENV_FILE" ]; then
    echo "error: $ENV_FILE not found" >&2
    exit 1
fi
if [ ! -f "$TENANT_ENV_FILE" ]; then
    echo "error: $TENANT_ENV_FILE not found" >&2
    exit 1
fi

NUTANIX_HOST="${NUTANIX_HOST:-$(get_env "$ENV_FILE" NUTANIX_HOST)}"
NUTANIX_PORT="${NUTANIX_PORT:-$(get_env "$ENV_FILE" NUTANIX_PORT)}"
NUTANIX_API_VERSION="${NUTANIX_API_VERSION:-$(get_env "$ENV_FILE" NUTANIX_API_VERSION)}"
NUTANIX_VERIFY_SSL="${NUTANIX_VERIFY_SSL:-$(get_env "$ENV_FILE" NUTANIX_VERIFY_SSL)}"

LIBCLOUD_NTNX_USER="${LIBCLOUD_NTNX_USER:-$(get_env "$TENANT_ENV_FILE" LIBCLOUD_NTNX_USER)}"
LIBCLOUD_NTNX_PASSWORD="${LIBCLOUD_NTNX_PASSWORD:-$(get_env "$TENANT_ENV_FILE" LIBCLOUD_NTNX_PASSWORD)}"

# defaults if the env files don't set them
NUTANIX_PORT="${NUTANIX_PORT:-9440}"
NUTANIX_API_VERSION="${NUTANIX_API_VERSION:-v4.0}"
NUTANIX_VERIFY_SSL="${NUTANIX_VERIFY_SSL:-false}"

if [ -z "$NUTANIX_HOST" ] || [ -z "$LIBCLOUD_NTNX_USER" ] || [ -z "$LIBCLOUD_NTNX_PASSWORD" ]; then
    echo "error: missing NUTANIX_HOST / LIBCLOUD_NTNX_USER / LIBCLOUD_NTNX_PASSWORD" >&2
    exit 1
fi

BASE_URL="https://${NUTANIX_HOST}:${NUTANIX_PORT}"
AUTH="$(printf '%s:%s' "$LIBCLOUD_NTNX_USER" "$LIBCLOUD_NTNX_PASSWORD" | base64 | tr -d '\n')"
REQ_ID="$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || cat /proc/sys/kernel/random/uuid)"

CURL_OPTS=(-sS)
if [ "$NUTANIX_VERIFY_SSL" = "false" ] || [ "$NUTANIX_VERIFY_SSL" = "0" ] || [ "$NUTANIX_VERIFY_SSL" = "no" ]; then
    CURL_OPTS+=(-k)
fi

# ---------------------------------------------------------------------------
# parse args
# ---------------------------------------------------------------------------

SUMMARY=false
KEYS=()
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        --summary) SUMMARY=true ;;
        list|--list)
            for ((i = 0; i < ${#RESOURCES[@]}; i += 2)); do
                printf '  %-16s %s\n' "${RESOURCES[$i]}" "${RESOURCES[$((i + 1))]}"
            done
            exit 0
            ;;
        *) KEYS+=("$arg") ;;
    esac
done

# default: everything
if [ ${#KEYS[@]} -eq 0 ]; then
    for ((i = 0; i < ${#RESOURCES[@]}; i += 2)); do
        KEYS+=("${RESOURCES[$i]}")
    done
fi

# ---------------------------------------------------------------------------
# go
# ---------------------------------------------------------------------------

echo "# ${BASE_URL}  (user: ${LIBCLOUD_NTNX_USER}, api: ${NUTANIX_API_VERSION}, ssl verify: ${NUTANIX_VERIFY_SSL})"
echo

for key in "${KEYS[@]}"; do
    path="$(path_for "$key")" || {
        echo "error: unknown resource '$key' (try: $0 list)" >&2
        exit 1
    }

    echo "==== ${key}  ->  ${path} ===="
    if [ "$SUMMARY" = true ]; then
        api_list "$path" \
            | jq -r 'if type=="object" then
                         [(.name // .nameStr // "?"), (.extId // .ext_id // "?")] | @tsv
                     else
                         (.) | @json
                     end' \
            | column -t -s $'\t' 2>/dev/null || true
    else
        api_list "$path" | jq -s '.'
    fi
    echo
done
