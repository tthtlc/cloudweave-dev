#!/usr/bin/env bash
# check_stale_fga.sh — Detect and fix stale FGA_STORE_ID / FGA_MODEL_ID.
#
# The OpenFGA bootstrap container writes store + model IDs to
#   openfga_postgres/generated/fga.env
# which the identity-service and libcloud REST API containers read at start time
# via env_file.  If that file reverts (git checkout, stash, manual edit) while
# OpenFGA's Postgres datastore holds a newer store, the mismatch is silent until
# the next container restart — then the services point at a non-existent store.
#
# This script compares three sources:
#   (A) openfga_postgres/generated/fga.env  — the file on disk
#   (B) the identity-service container env   — what the running process sees
#   (C) the live OpenFGA API                 — ground truth (Postgres datastore)
#
# Usage:
#   ./check_stale_fga.sh            # diagnose only, exits non-zero on mismatch
#   ./check_stale_fga.sh --fix      # update fga.env from live OpenFGA API
#   ./check_stale_fga.sh --quiet    # only print mismatches (for scripting)
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
FGA_ENV="${REPO_ROOT}/openfga_postgres/generated/fga.env"
FGA_API="${FGA_API_URL:-http://localhost:8080}"
FGA_STORE_NAME="${FGA_STORE_NAME:-libcloud-rest-store}"
FIX=0
QUIET=0

for arg in "$@"; do
  case "$arg" in
    --fix)   FIX=1 ;;
    --quiet) QUIET=1 ;;
    --help)  echo "Usage: $0 [--fix] [--quiet]"; exit 0 ;;
  esac
done

PASS=0; WARN=0; FAIL=0

ok()   { if [[ "$QUIET" -eq 0 ]]; then echo -e "  ${GREEN}PASS${NC}  $1"; fi; PASS=$((PASS + 1)); }
warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL + 1)); }
info() { if [[ "$QUIET" -eq 0 ]]; then echo -e "  ${BOLD}INFO${NC}  $1"; fi; }

divider() {
  if [[ "$QUIET" -eq 0 ]]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  fi
}

# ---------------------------------------------------------------------------
# 1. Read fga.env (source A: file on disk)
# ---------------------------------------------------------------------------
divider "1. fga.env (file on disk)"

FILE_STORE_ID=""
FILE_MODEL_ID=""

if [[ ! -f "$FGA_ENV" ]]; then
  fail "fga.env missing at $FGA_ENV"
else
  FILE_STORE_ID=$(grep -E '^FGA_STORE_ID=' "$FGA_ENV" 2>/dev/null | head -1 | cut -d= -f2- || true)
  FILE_MODEL_ID=$(grep -E '^FGA_MODEL_ID=' "$FGA_ENV" 2>/dev/null | head -1 | cut -d= -f2- || true)
  FILE_STORE_NAME=$(grep -E '^FGA_STORE_NAME=' "$FGA_ENV" 2>/dev/null | head -1 | cut -d= -f2- || true)

  if [[ -z "$FILE_STORE_ID" ]]; then
    fail "FGA_STORE_ID missing or empty in $FGA_ENV"
  else
    ok "FGA_STORE_ID = ${FILE_STORE_ID}"
  fi
  if [[ -z "$FILE_MODEL_ID" ]]; then
    fail "FGA_MODEL_ID missing or empty in $FGA_ENV"
  else
    ok "FGA_MODEL_ID  = ${FILE_MODEL_ID}"
  fi
  # Use the file's store name if present, otherwise keep the default.
  if [[ -n "${FILE_STORE_NAME:-}" ]]; then
    FGA_STORE_NAME="$FILE_STORE_NAME"
    info "store name    = ${FGA_STORE_NAME}"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Read identity-service container env (source B: running service)
# ---------------------------------------------------------------------------
divider "2. identity-service container environment"

CONTAINER_STORE_ID=""
CONTAINER_MODEL_ID=""

IS_CID=$(docker ps --filter name=^identity-service$ --format '{{.ID}}' 2>/dev/null || true)
if [[ -z "$IS_CID" ]]; then
  warn "identity-service container is not running — skipped"
else
  CONTAINER_STORE_ID=$(docker exec identity-service printenv FGA_STORE_ID 2>/dev/null || true)
  CONTAINER_MODEL_ID=$(docker exec identity-service printenv FGA_MODEL_ID 2>/dev/null || true)
  CONTAINER_API_URL=$(docker exec identity-service printenv FGA_API_URL 2>/dev/null || true)

  if [[ -z "$CONTAINER_STORE_ID" ]]; then
    warn "FGA_STORE_ID empty in container (auto-discovery will be used)"
  else
    ok "FGA_STORE_ID = ${CONTAINER_STORE_ID}"
  fi
  if [[ -z "$CONTAINER_MODEL_ID" ]]; then
    warn "FGA_MODEL_ID empty in container (auto-discovery will be used)"
  else
    ok "FGA_MODEL_ID  = ${CONTAINER_MODEL_ID}"
  fi
  if [[ -n "$CONTAINER_API_URL" ]]; then
    info "FGA_API_URL   = ${CONTAINER_API_URL}"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Resolve bearer token for OpenFGA API authentication.
#    OpenFGA is configured with --authn-method=oidc (issuer=Dex,
#    audience=libcloud-rest), so every API call requires a valid JWT.
#    Resolution order matches openfga_postgres/fga_auth.sh:
#      1. $FGA_API_TOKEN        (preshared-key mode / explicit override)
#      2. $SUPERADMIN_JWT       (set by test_script/scripts/superadmin_auth.sh)
#      3. generated/tokens/superadmin.jwt  (if present and unexpired)
# ---------------------------------------------------------------------------
divider "3. OpenFGA bearer token"

FGA_BEARER=""
FGA_TOKEN_FILE="${REPO_ROOT}/generated/tokens/superadmin.jwt"

_fga_jwt_exp() {  # print exp epoch or "" if unparseable
  python3 - "$1" <<'PY' 2>/dev/null
import sys, json, base64
t = sys.argv[1].strip()
try:
    p = t.split('.')[1]; p += '=' * (-len(p) % 4)
    print(int(json.loads(base64.urlsafe_b64decode(p)).get('exp', 0)))
except Exception:
    print("")
PY
}

_resolve_fga_token() {
  if [[ -n "${FGA_API_TOKEN:-}" ]]; then
    echo "${FGA_API_TOKEN}"
    return 0
  fi
  if [[ -n "${SUPERADMIN_JWT:-}" ]]; then
    echo "${SUPERADMIN_JWT}"
    return 0
  fi
  if [[ -s "${FGA_TOKEN_FILE}" ]]; then
    local tok exp now
    tok=$(cat "${FGA_TOKEN_FILE}")
    exp=$(_fga_jwt_exp "$tok")
    now=$(date +%s)
    if [[ -n "$exp" && "$exp" -gt "$now" ]]; then
      echo "$tok"
      return 0
    fi
  fi
  return 1
}

if FGA_BEARER=$(_resolve_fga_token); then
  ok "Bearer token resolved (length=${#FGA_BEARER})"
  # Check expiry
  exp=$(_fga_jwt_exp "$FGA_BEARER")
  now=$(date +%s)
  if [[ -n "$exp" ]]; then
    remaining=$(( exp - now ))
    if [[ "$remaining" -gt 0 ]]; then
      info "token expires in ~$(( remaining / 60 ))m $(( remaining % 60 ))s"
    else
      warn "token is EXPIRED ($(( -remaining ))s ago)"
      warn "Renew: source test_script/scripts/superadmin_auth.sh"
    fi
  fi
else
  warn "No bearer token available — OpenFGA API calls will fail (OIDC required)"
  warn "Get a token: source test_script/scripts/superadmin_auth.sh"
  warn "Or set:  export FGA_API_TOKEN=<preshared-key>"
fi

# ---------------------------------------------------------------------------
# 4. Query the live OpenFGA API (source C: ground truth in Postgres)
# ---------------------------------------------------------------------------
divider "4. Live OpenFGA API (ground truth)"

LIVE_STORE_ID=""
LIVE_MODEL_ID=""

# Helper: curl with optional bearer auth. When FGA_BEARER is set, include it.
_fga_curl() {
  local method="$1"; shift
  local url="$1"; shift
  if [[ -n "${FGA_BEARER:-}" ]]; then
    curl -sS --max-time 10 -H "Authorization: Bearer ${FGA_BEARER}" \
      -H "Accept: application/json" -X "$method" "$url" "$@" 2>/dev/null || true
  else
    curl -sS --max-time 10 -H "Accept: application/json" -X "$method" "$url" "$@" 2>/dev/null || true
  fi
}

# 4a. Health check (no auth required)
if ! curl -fsS --max-time 5 "${FGA_API}/healthz" > /dev/null 2>&1; then
  fail "OpenFGA API not reachable at ${FGA_API}/healthz"
  LIVE_API_DOWN=1
else
  ok "OpenFGA /healthz reachable"
  LIVE_API_DOWN=0
fi

# 4b. Find store by name
if [[ "${LIVE_API_DOWN:-0}" -eq 0 ]]; then
  STORES_JSON=$(_fga_curl GET "${FGA_API}/stores")
  # Check for auth error (missing/invalid bearer token)
  if echo "$STORES_JSON" | grep -q '"bearer_token_missing"'; then
    fail "OpenFGA requires authentication — no valid bearer token"
    fail "  Get a token: source test_script/scripts/superadmin_auth.sh"
    fail "  Or set:      export FGA_API_TOKEN=<preshared-key>"
    LIVE_API_DOWN=1
  elif [[ -z "$STORES_JSON" ]]; then
    fail "No response from GET /stores"
    LIVE_API_DOWN=1
  else
    # Extract the store id whose name matches
    LIVE_STORE_ID=$(echo "$STORES_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
stores = data.get('stores', [])
for s in stores:
    if s.get('name') == '${FGA_STORE_NAME}':
        print(s['id'])
        break
" 2>/dev/null || true)

    if [[ -z "$LIVE_STORE_ID" ]]; then
      fail "Store '${FGA_STORE_NAME}' not found in OpenFGA (${FGA_API})"
      TOTAL_STORES=$(echo "$STORES_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('stores',[])))" 2>/dev/null || echo "?")
      warn "  ${TOTAL_STORES} store(s) exist in OpenFGA; expected '${FGA_STORE_NAME}'"
      if [[ "$QUIET" -eq 0 ]]; then
        echo "$STORES_JSON" | python3 -m json.tool 2>/dev/null || echo "$STORES_JSON"
      fi
    else
      ok "Store '${FGA_STORE_NAME}' → ${LIVE_STORE_ID}"
    fi
  fi
fi

# 4c. Find latest authorization model for the store
if [[ "${LIVE_API_DOWN:-0}" -eq 0 && -n "$LIVE_STORE_ID" ]]; then
  MODELS_JSON=$(_fga_curl GET \
    "${FGA_API}/stores/${LIVE_STORE_ID}/authorization-models?page_size=1")
  if [[ -z "$MODELS_JSON" ]]; then
    fail "No response from GET /stores/${LIVE_STORE_ID}/authorization-models"
  else
    LIVE_MODEL_ID=$(echo "$MODELS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
models = data.get('authorization_models', [])
if models:
    print(models[0]['id'])
" 2>/dev/null || true)

    if [[ -z "$LIVE_MODEL_ID" ]]; then
      fail "No authorization model found in store ${LIVE_STORE_ID}"
    else
      ok "Latest model → ${LIVE_MODEL_ID}"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 5. Cross-check
# ---------------------------------------------------------------------------
divider "5. Consistency"

MISMATCH=0

# fga.env  vs  live API
if [[ -n "$FILE_STORE_ID" && -n "$LIVE_STORE_ID" ]]; then
  if [[ "$FILE_STORE_ID" == "$LIVE_STORE_ID" ]]; then
    ok "fga.env store_id matches live OpenFGA"
  else
    fail "fga.env store_id (${FILE_STORE_ID}) != live OpenFGA (${LIVE_STORE_ID})"
    MISMATCH=1
  fi
fi

if [[ -n "$FILE_MODEL_ID" && -n "$LIVE_MODEL_ID" ]]; then
  if [[ "$FILE_MODEL_ID" == "$LIVE_MODEL_ID" ]]; then
    ok "fga.env model_id matches live OpenFGA"
  else
    fail "fga.env model_id (${FILE_MODEL_ID}) != live OpenFGA (${LIVE_MODEL_ID})"
    MISMATCH=1
  fi
fi

# container  vs  live API
if [[ -n "$CONTAINER_STORE_ID" && -n "$LIVE_STORE_ID" ]]; then
  if [[ "$CONTAINER_STORE_ID" == "$LIVE_STORE_ID" ]]; then
    ok "container store_id matches live OpenFGA"
  else
    warn "container store_id (${CONTAINER_STORE_ID}) != live OpenFGA (${LIVE_STORE_ID})"
    MISMATCH=1
  fi
fi

if [[ -n "$CONTAINER_MODEL_ID" && -n "$LIVE_MODEL_ID" ]]; then
  if [[ "$CONTAINER_MODEL_ID" == "$LIVE_MODEL_ID" ]]; then
    ok "container model_id matches live OpenFGA"
  else
    warn "container model_id (${CONTAINER_MODEL_ID}) != live OpenFGA (${LIVE_MODEL_ID})"
    MISMATCH=1
  fi
fi

# ---------------------------------------------------------------------------
# 5a. Determine which source is most likely stale
# ---------------------------------------------------------------------------
STALE_SOURCE=""
if [[ "$MISMATCH" -eq 1 ]]; then
  divider "5a. Staleness verdict"

  # Ground truth is the live API.  The stale source is whichever doesn't match.
  FILE_STALE=0
  CONTAINER_STALE=0

  if [[ -n "$FILE_STORE_ID" && -n "$LIVE_STORE_ID" && "$FILE_STORE_ID" != "$LIVE_STORE_ID" ]]; then
    FILE_STALE=1
  fi
  if [[ -n "$FILE_MODEL_ID" && -n "$LIVE_MODEL_ID" && "$FILE_MODEL_ID" != "$LIVE_MODEL_ID" ]]; then
    FILE_STALE=1
  fi

  if [[ -n "$CONTAINER_STORE_ID" && -n "$LIVE_STORE_ID" && "$CONTAINER_STORE_ID" != "$LIVE_STORE_ID" ]]; then
    CONTAINER_STALE=1
  fi
  if [[ -n "$CONTAINER_MODEL_ID" && -n "$LIVE_MODEL_ID" && "$CONTAINER_MODEL_ID" != "$LIVE_MODEL_ID" ]]; then
    CONTAINER_STALE=1
  fi

  if [[ "$FILE_STALE" -eq 1 && "$CONTAINER_STALE" -eq 0 ]]; then
    warn "fga.env is STALE (container is current)."
    warn "Likely cause: fga.env was reverted (git checkout / manual edit)"
    warn "after the last setup.sh re-seed."
  elif [[ "$FILE_STALE" -eq 1 && "$CONTAINER_STALE" -eq 1 ]]; then
    warn "Both fga.env AND container are stale."
    warn "Likely cause: setup.sh re-seeded OpenFGA but services were not restarted."
  elif [[ "$FILE_STALE" -eq 0 && "$CONTAINER_STALE" -eq 1 ]]; then
    warn "Container is STALE (fga.env is current)."
    warn "Likely cause: fga.env was updated but identity-service was not restarted."
    warn "Fix:  docker compose -f identity_service/docker-compose.yml up -d --force-recreate identity-service"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Fix (--fix)
# ---------------------------------------------------------------------------
if [[ "$FIX" -eq 1 ]]; then
  divider "6. Fix"

  if [[ "${LIVE_API_DOWN:-0}" -ne 0 ]]; then
    fail "Cannot fix: OpenFGA API is not reachable"
  elif [[ -z "$LIVE_STORE_ID" || -z "$LIVE_MODEL_ID" ]]; then
    fail "Cannot fix: live store or model ID not available"
  elif [[ "$FILE_STORE_ID" == "$LIVE_STORE_ID" && "$FILE_MODEL_ID" == "$LIVE_MODEL_ID" ]]; then
    ok "No fix needed — fga.env already matches live OpenFGA"
  else
    info "Updating $FGA_ENV ..."
    # Preserve FGA_API_URL and FGA_STORE_NAME lines; replace FGA_STORE_ID / FGA_MODEL_ID.
    TMP_ENV=$(mktemp)
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^FGA_STORE_ID= ]]; then
        echo "FGA_STORE_ID=${LIVE_STORE_ID}"
      elif [[ "$line" =~ ^FGA_MODEL_ID= ]]; then
        echo "FGA_MODEL_ID=${LIVE_MODEL_ID}"
      else
        echo "$line"
      fi
    done < "$FGA_ENV" > "$TMP_ENV"
    mv "$TMP_ENV" "$FGA_ENV"
    ok "fga.env updated:"
    info "  FGA_STORE_ID=${LIVE_STORE_ID}"
    info "  FGA_MODEL_ID=${LIVE_MODEL_ID}"
    echo ""
    warn "If identity-service is running with stale IDs, restart it:"
    warn "  docker compose -f identity_service/docker-compose.yml up -d --force-recreate identity-service"
    warn "  docker compose -f libcloud.rest/docker-compose.yml up -d --force-recreate api"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "══════════════════════════════════════════════════════════════════"
printf "  Total:  ${GREEN}%3d pass${NC}  ${YELLOW}%3d warn${NC}  ${RED}%3d fail${NC}\n" "$PASS" "$WARN" "$FAIL"
echo "══════════════════════════════════════════════════════════════════"

if [[ "$FAIL" -gt 0 || "$WARN" -gt 0 ]]; then
  echo ""
  if [[ "$FIX" -eq 0 ]]; then
    echo "Run with --fix to update fga.env from the live OpenFGA API:"
    echo "  $0 --fix"
  fi
  exit 1
fi

echo ""
echo "fga.env, identity-service container, and live OpenFGA are all consistent."
exit 0
