#!/usr/bin/env bash
# =============================================================================
# common.sh - shared helpers for the Nutanix Prism Central v4 curl scripts.
#
# Loads Prism Central credentials from .env (same directory as the scripts):
#     PC_URL        full Prism Central URL, e.g. https://10.0.0.1:9440
#     PC_USERNAME   login name
#     PC_PASSWORD   password
#     PC_INSECURE   "true" (default) -> curl -k, skip TLS verification
#
# Authentication model (as used by the Prism Central web UI):
#   iam_login()  ->  authenticates ONCE with HTTP Basic auth (from .env)
#                    against an IAM endpoint and stores the NTNX_IGW_SESSION
#                    session cookie in a cookie jar.
#   every other  ->  sends ONLY the cookie (no Authorization header).
#                    This is the "cookie derived from IAM authentication"
#                    access-control model.
#
# Environment knobs:
#   AUTH_MODE=cookie|basic   default cookie (basic = -u on every request)
#   ETAG=<value>             If-Match value for DELETE/PUT (default 0 = no check)
#   PAYLOAD='{...}'          override the default JSON body of a request function
#   CURL_DRY_RUN=1           print the curl command instead of executing it
#   NTNX_PRETTY=0            disable jq pretty-printing (auto if jq installed)
# =============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

# ---------------------------------------------------------------------------
# load .env
# ---------------------------------------------------------------------------
if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
else
    echo "ERROR: ${ENV_FILE} not found." >&2
    echo "Create it from the template in the repo (PC_URL, PC_USERNAME, PC_PASSWORD)." >&2
    exit 1
fi

: "${PC_URL:?PC_URL is required in .env}"
: "${PC_USERNAME:?PC_USERNAME is required in .env}"
: "${PC_PASSWORD:?PC_PASSWORD is required in .env}"

if [[ "${PC_USERNAME}" == "admin" && "${PC_PASSWORD}" == "changeme" ]]; then
    echo "WARNING: .env still contains the placeholder credentials (admin/changeme)." >&2
fi

PC_INSECURE="${PC_INSECURE:-true}"
API_BASE="${PC_URL%/}/api"                       # strip trailing slash
AUTH_MODE="${AUTH_MODE:-cookie}"
COOKIE_JAR="${COOKIE_JAR:-${TMPDIR:-/tmp}/ntnx_cookie_${PPID:-$$}.txt}"
CORRELATION_ID="${CORRELATION_ID:-$(uuidgen 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')}"

CURL_K=()
[[ "${PC_INSECURE}" == "true" ]] && CURL_K+=(-k)

# ---------------------------------------------------------------------------
# IAM login: authenticate once with Basic auth, store the session cookie.
# The script sets IAM_BASE_PATH before sourcing this file, e.g.
#     IAM_BASE_PATH="/iam/v4.0/authn"   (or /iam/v4.1.b3/authn)
# ---------------------------------------------------------------------------
iam_login() {
    local probe="${API_BASE}${IAM_BASE_PATH:-/iam/v4.0/authn}/users?\$limit=1"
    local code

    echo "==> IAM login: ${PC_USERNAME} @ ${PC_URL} (capturing session cookie)" >&2

    # 1) trigger session creation with Basic auth and capture the cookie
    code=$(curl "${CURL_K[@]}" -sS -o /dev/null -w "%{http_code}" \
        -u "${PC_USERNAME}:${PC_PASSWORD}" \
        -c "${COOKIE_JAR}" \
        -H "Accept: application/json" \
        -H "X-Correlation-Id: ${CORRELATION_ID}" \
        "${probe}")

    if [[ "${code}" != "200" ]]; then
        # 2) fallback: legacy PrismGateway session endpoint (some PC builds)
        echo "    IAM probe returned ${code}; trying PrismGateway session endpoint..." >&2
        code=$(curl "${CURL_K[@]}" -sS -o /dev/null -w "%{http_code}" \
            -u "${PC_USERNAME}:${PC_PASSWORD}" \
            -c "${COOKIE_JAR}" \
            -H "Content-Type: application/json" \
            -d '{}' \
            "${PC_URL%/}/PrismGateway/services/rest/v1/session")
    fi

    if [[ "${code}" != "200" ]]; then
        echo "ERROR: authentication failed (HTTP ${code}). Check PC_URL/PC_USERNAME/PC_PASSWORD in .env" >&2
        return 1
    fi

    # 3) verify the COOKIE ALONE (no Authorization header) is accepted
    code=$(curl "${CURL_K[@]}" -sS -o /dev/null -w "%{http_code}" \
        -b "${COOKIE_JAR}" \
        -H "Accept: application/json" \
        -H "X-Correlation-Id: ${CORRELATION_ID}" \
        "${probe}")

    if [[ "${code}" != "200" ]]; then
        echo "WARNING: cookie-only request returned ${code}; falling back to AUTH_MODE=basic" >&2
        AUTH_MODE="basic"
    else
        echo "    OK - session cookie accepted (cookie jar: ${COOKIE_JAR})" >&2
        [[ "${AUTH_MODE}" != "basic" ]] && AUTH_MODE="cookie"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# _urlenc <name=value>  ->  name=<url-encoded value>
# ---------------------------------------------------------------------------
_urlenc() {
    python3 -c 'import sys,urllib.parse; s=sys.argv[1]; k,_,v=s.partition("="); print(k+"="+urllib.parse.quote(v))' "$1"
}

# ---------------------------------------------------------------------------
# _req METHOD URL [BODY] [ARG ...]
#   BODY  - JSON payload for POST/PUT/PATCH (empty string = no body)
#   ARG   - "name=value"      appended as a URL query parameter
#           "@Header: value"  appended as an HTTP header
# ---------------------------------------------------------------------------
_req() {
    local method="$1" url="$2" body="${3:-}" pair query="" full h
    shift 3 2>/dev/null || shift 2

    for pair in "$@"; do
        [[ -z "${pair}" ]] && continue
        case "${pair}" in
            @*:*) h="${pair#@}" ;;
            *)    query="${query}${query:+&}$(_urlenc "${pair}")" ;;
        esac
    done
    full="${API_BASE}${url}${query:+?${query}}"

    local args=( "${CURL_K[@]}" -sS -X "${method}" \
        -H "Accept: application/json" \
        -H "X-Correlation-Id: ${CORRELATION_ID}" )
    if [[ "${AUTH_MODE}" == "basic" ]]; then
        args+=( -u "${PC_USERNAME}:${PC_PASSWORD}" )
    else
        [[ -s "${COOKIE_JAR}" ]] || iam_login
        args+=( -b "${COOKIE_JAR}" )
    fi
    [[ -n "${h:-}" ]] && args+=( -H "${h}" )
    [[ -n "${body}" ]] && args+=( -H "Content-Type: application/json" --data-raw "${body}" )

    if [[ "${CURL_DRY_RUN:-0}" == "1" ]]; then
        printf 'curl '
        printf '%q ' "${args[@]}"
        printf '%q\n' "${full}"
        return 0
    fi

    local resp status body_resp
    resp=$(curl "${args[@]}" -w $'\n__HTTP_STATUS__:%{http_code}' "${full}") || {
        echo "ERROR: curl failed" >&2
        return 1
    }
    status="${resp##*$'\n'__HTTP_STATUS__:}"
    body_resp="${resp%$'\n'__HTTP_STATUS__:*}"

    echo "HTTP_STATUS: ${status}"
    if [[ "${NTNX_PRETTY:-1}" == "1" ]] && command -v jq >/dev/null 2>&1; then
        printf '%s' "${body_resp}" | jq . 2>/dev/null || printf '%s\n' "${body_resp}"
    else
        printf '%s\n' "${body_resp}"
    fi

    if [[ "${status}" -ge 400 ]]; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# _req_multipart METHOD URL [FIELD=value ...]   (value "@file" uploads a file)
# ---------------------------------------------------------------------------
_req_multipart() {
    local method="$1" url="$2" field
    shift 2

    local args=( "${CURL_K[@]}" -sS -X "${method}" \
        -H "Accept: application/json" \
        -H "X-Correlation-Id: ${CORRELATION_ID}" )
    if [[ "${AUTH_MODE}" == "basic" ]]; then
        args+=( -u "${PC_USERNAME}:${PC_PASSWORD}" )
    else
        [[ -s "${COOKIE_JAR}" ]] || iam_login
        args+=( -b "${COOKIE_JAR}" )
    fi
    for field in "$@"; do
        [[ -z "${field}" ]] && continue
        case "${field}" in
            @*:*) args+=( -H "${field#@}" ) ;;
            *)    args+=( -F "${field}" ) ;;
        esac
    done

    if [[ "${CURL_DRY_RUN:-0}" == "1" ]]; then
        printf 'curl '
        printf '%q ' "${args[@]}"
        printf '%q\n' "${API_BASE}${url}"
        return 0
    fi

    local resp status body_resp
    resp=$(curl "${args[@]}" -w $'\n__HTTP_STATUS__:%{http_code}' "${API_BASE}${url}") || {
        echo "ERROR: curl failed" >&2
        return 1
    }
    status="${resp##*$'\n'__HTTP_STATUS__:}"
    body_resp="${resp%$'\n'__HTTP_STATUS__:*}"

    echo "HTTP_STATUS: ${status}"
    if [[ "${NTNX_PRETTY:-1}" == "1" ]] && command -v jq >/dev/null 2>&1; then
        printf '%s' "${body_resp}" | jq . 2>/dev/null || printf '%s\n' "${body_resp}"
    else
        printf '%s\n' "${body_resp}"
    fi
    return 0
}
