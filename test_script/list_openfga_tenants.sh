#!/usr/bin/env bash
# list_openfga_tenants.sh
# =======================
# List every tenant object created in OpenFGA.
#
# A tenant is any object of type `tenant` in the OpenFGA model. This script
# reads every relationship tuple in the store (/read, paginated) and collects
# the unique ids that appear as `tenant:<id>` — either as a tuple object
# (user:<owner> owner tenant:<id>) or as a tuple user
# (tenant:<id> parent <provider|vault_user|libcloud_api>). It is the single
# source of truth for "which tenants exist", unlike the Vault KV list, which
# may also hold legacy/test paths that are not OpenFGA tenants.
#
# Usage:
#   ./test_script/list_openfga_tenants.sh          # one tenant id per line
#   ./test_script/list_openfga_tenants.sh --json   # JSON array
#
# Authn: OpenFGA uses OIDC. A bearer token is resolved from, in order:
#   FGA_API_TOKEN > SUPERADMIN_JWT > a valid generated/tokens/superadmin.jwt
#   > a fresh superadmin Dex login (via scripts/superadmin_auth.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FGA_ENV="${REPO_ROOT}/openfga_postgres/generated/fga.env"

JSON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=1; shift;;
    -h|--help) sed -n '2,21p' "$0"; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

# ---- load FGA env ----------------------------------------------------------
if [[ -f "${FGA_ENV}" ]]; then
  # shellcheck source=/dev/null
  set -a; source "${FGA_ENV}"; set +a
fi
: "${FGA_API_URL:?FGA_API_URL not set — run ./setup.sh first}"
: "${FGA_STORE_ID:?FGA_STORE_ID not set — run ./setup.sh first}"
export FGA_API_URL FGA_STORE_ID

# ---- bearer token ----------------------------------------------------------
_jwt_exp() { python3 - "$1" 2>/dev/null <<'PY'
import sys, json, base64
try:
    p = sys.argv[1].strip().split('.')[1]; p += '=' * (-len(p) % 4)
    print(int(json.loads(base64.urlsafe_b64decode(p)).get('exp', 0)))
except Exception:
    print("")
PY
}

_resolve_fga_token() {
  if [[ -n "${FGA_API_TOKEN:-}" ]]; then echo "${FGA_API_TOKEN}"; return 0; fi
  if [[ -n "${SUPERADMIN_JWT:-}" ]]; then echo "${SUPERADMIN_JWT}"; return 0; fi
  local jp="${REPO_ROOT}/generated/tokens/superadmin.jwt"
  if [[ -s "$jp" ]]; then
    local exp now
    exp=$(_jwt_exp "$(cat "$jp")")
    now=$(date +%s)
    if [[ -n "$exp" && "$exp" -gt "$now" ]]; then cat "$jp"; return 0; fi
  fi
  # Fresh Dex login as superadmin (writes generated/tokens/superadmin.jwt).
  if bash "${REPO_ROOT}/test_script/scripts/superadmin_auth.sh" >/dev/null 2>&1 \
     && [[ -s "$jp" ]]; then
    cat "$jp"; return 0
  fi
  return 1
}

ACCESS_TOKEN="$(_resolve_fga_token)" || {
  echo "FATAL: no OpenFGA bearer token. Set FGA_API_TOKEN / SUPERADMIN_JWT," >&2
  echo "       or run ./test_script/scripts/superadmin_auth.sh." >&2
  exit 3
}
export ACCESS_TOKEN

# ---- read all tuples, extract unique tenant ids ----------------------------
FGA_API_URL="$FGA_API_URL" FGA_STORE_ID="$FGA_STORE_ID" \
ACCESS_TOKEN="$ACCESS_TOKEN" python3 - "$JSON" <<'PY'
import json, os, sys, urllib.request, urllib.error

base = os.environ["FGA_API_URL"].rstrip("/")
store = os.environ["FGA_STORE_ID"]
token = os.environ["ACCESS_TOKEN"]
as_json = sys.argv[1] == "1"

url = f"{base}/stores/{store}/read"
tenants = set()
tok = ""
while True:
    payload = {"page_size": 100}
    if tok:
        payload["continuation_token"] = tok
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(), method="POST",
        headers={"Content-Type": "application/json", "Accept": "application/json",
                 "Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            d = json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        print(f"ERROR: OpenFGA /read failed (HTTP {e.code}): {e.read().decode()[:200]}",
              file=sys.stderr)
        sys.exit(4)
    for t in d.get("tuples", []):
        k = t.get("key", {})
        for field in ("object", "user"):
            val = k.get(field, "")
            if val.startswith("tenant:"):
                tenants.add(val.split(":", 1)[1])
    tok = d.get("continuation_token") or ""
    if not tok:
        break

ids = sorted(tenants)
if as_json:
    print(json.dumps(ids))
else:
    print("\n".join(ids))
PY
