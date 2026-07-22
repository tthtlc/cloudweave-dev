#!/usr/bin/env bash
# openfga_common.sh — shared helpers for the OpenFGA admin scripts (Group 2).
#
# Sourced (never executed) by openfga-tuple-*.sh / openfga-check.sh /
# openfga-list-*.sh / openfga-breakglass-grant.sh. It sources scripts/common.sh
# (which loads .env + generated/dex.env + generated/fga.env, resolves the
# caller's LLDAP password, and exposes idp_login + curl_http), performs the
# Dex OIDC login, and adds OpenFGA REST helpers + a JSONL audit emitter.
#
# OpenFGA runs with OIDC authn (Dex, aud=libcloud-rest): the caller's Dex
# access token is forwarded as a Bearer header on every FGA call. Tuple writes
# are therefore gated on a successful LLDAP/Dex login as an authorised admin
# principal. Default principal: superadmin (the OpenFGA bootstrap identity);
# override with LIBCLOUD_USER + the usual LIBCLOUD_PASSWORD* env.
#
# Contract for callers (set -euo pipefail assumed):
#   fga_write  <user> <relation> <object> [more triples...]   # idempotent write
#   fga_delete <user> <relation> <object> [more triples...]   # idempotent delete
#   fga_check  <user> <relation> <object>   # prints allowed=true|false, returns 0 if allowed
#   fga_read_all_tuples    # prints JSON array of {user,relation,object}
#   fga_list_objects <user> <relation> <type>   # prints JSON array of object ids
#   fga_list_users   <relation> <object> <user_type>  # prints JSON array of users
#   fga_audit <json-line>
#   FGA_AUDIT_LOG (default generated/openfga_audit.log)

# Default principal = superadmin (OpenFGA bootstrap identity). Set BEFORE
# sourcing common.sh so its password resolver picks the superadmin branch.
export LIBCLOUD_USER="${LIBCLOUD_USER:-superadmin}"

SCRIPT_DIR_OG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR_OG}/common.sh" >/dev/null 2>&1 || {
  echo "FATAL: cannot source scripts/common.sh — run ./setup.sh first." >&2
  exit 2
}

: "${FGA_API_URL:?FGA_API_URL not set (run ./setup.sh)}"
: "${FGA_STORE_ID:?FGA_STORE_ID not set (run ./setup.sh)}"
: "${FGA_MODEL_ID:?FGA_MODEL_ID not set (run ./setup.sh)}"
: "${FGA_AUDIT_LOG:=${REPO_ROOT}/generated/openfga_audit.log}"

# common.sh loads the real superadmin bind password from ../dex/generated/dex.env
# into LIBCLOUD_SUPERADMIN_PASSWORD. Its case-based resolver can still fall
# through to the embedded dev default under ALLOW_DEV_DEFAULTS=1, which Dex
# rejects (401). Resolve the password explicitly (mirrors superadmin_auth.sh)
# so idp_login uses the real LLDAP credential.
if [[ "${LIBCLOUD_USER}" == "superadmin" && -z "${LIBCLOUD_PASSWORD:-}" ]]; then
  : "${LIBCLOUD_PASSWORD:=${LIBCLOUD_SUPERADMIN_PASSWORD:-${LIBCLOUD_PASSWORD_SUPERADMIN:-}}}"
  export LIBCLOUD_PASSWORD
fi

# Resolve an OpenFGA bearer token. Preference order:
#   1. FGA_API_TOKEN        (preshared-key mode / explicit override)
#   2. SUPERADMIN_JWT env   (set by scripts/superadmin_auth.sh)
#   3. generated/tokens/superadmin.jwt  (if present and not expired)
#   4. fresh Dex idp_login  (fallback; needs a matching Dex client_secret)
# OpenFGA validates the JWT via JWKS (iss + aud + signature), not the Dex
# client_secret, so a previously-minted JWT stays valid even when the secret
# has since drifted (common in dev after a Dex restart).
_superadmin_jwt_path() { echo "${REPO_ROOT}/generated/tokens/superadmin.jwt"; }

_jwt_exp() {  # print exp epoch or "" if unparseable
  python3 - "$1" <<'PY' 2>/dev/null
import sys, json, base64, time
t = sys.argv[1].strip()
try:
    p = t.split('.')[1]; p += '=' * (-len(p) % 4)
    print(int(json.loads(base64.urlsafe_b64decode(p)).get('exp', 0)))
except Exception:
    print("")
PY
}

_resolve_fga_token() {
  if [[ -n "${FGA_API_TOKEN:-}" ]]; then echo "${FGA_API_TOKEN}"; return 0; fi
  if [[ -n "${SUPERADMIN_JWT:-}" ]]; then echo "${SUPERADMIN_JWT}"; return 0; fi
  local jp; jp=$(_superadmin_jwt_path)
  if [[ -s "$jp" ]]; then
    local tok exp now
    tok=$(cat "$jp")
    exp=$(_jwt_exp "$tok")
    now=$(date +%s)
    if [[ -n "$exp" && "$exp" -gt "$now" ]]; then echo "$tok"; return 0; fi
  fi
  # Fallback: fresh Dex login (requires a matching client_secret + valid pw).
  if idp_login >/dev/null 2>&1 && [[ -n "${ACCESS_TOKEN:-}" ]]; then
    echo "${ACCESS_TOKEN}"; return 0
  fi
  return 1
}

if [[ -z "${ACCESS_TOKEN:-}" ]]; then
  if ! ACCESS_TOKEN=$(_resolve_fga_token); then
    echo "FATAL: no OpenFGA bearer token. Set FGA_API_TOKEN / SUPERADMIN_JWT," >&2
    echo "       ensure generated/tokens/superadmin.jwt is valid, or run" >&2
    echo "       ./scripts/superadmin_auth.sh (requires a matching Dex client_secret)." >&2
    exit 3
  fi
  export ACCESS_TOKEN
fi

# ---- low-level FGA POST ------------------------------------------------------
# fga_post <path> <json-body-file> : POST body to FGA, print response to stdout,
# set FGA_HTTP_CODE in the current shell.
fga_post() {
  local path="$1" body="$2"
  FGA_HTTP_CODE=$(curl -sS -X POST "${FGA_API_URL}${path}" \
    -H "Content-Type: application/json" -H "Accept: application/json" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    --data-binary "@${body}" -o /dev/null -w "%{http_code}") || FGA_HTTP_CODE="000"
}

# fga_post_capture <path> <json-body-file> <out-file> : same but saves body.
fga_post_capture() {
  local path="$1" body="$2" out="$3"
  FGA_HTTP_CODE=$(curl -sS -X POST "${FGA_API_URL}${path}" \
    -H "Content-Type: application/json" -H "Accept: application/json" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    --data-binary "@${body}" -o "${out}" -w "%{http_code}") || FGA_HTTP_CODE="000"
}

_fga_triples_json() {
  # read remaining args as (user,relation,object) triples -> JSON array on stdout
  python3 - "$@" <<'PY'
import json, sys
out = []
args = sys.argv[1:]
for i in range(0, len(args), 3):
    if i + 2 < len(args):
        out.append({"user": args[i], "relation": args[i+1], "object": args[i+2]})
    elif i + 1 < len(args):
        out.append({"user": args[i], "relation": args[i+1], "object": ""})
    else:
        out.append({"user": args[i], "relation": "", "object": ""})
print(json.dumps(out))
PY
}

# Idempotent tuple write (batched, 100/req). Returns non-zero on hard failure.
fga_write() {
  [[ $# -ge 3 ]] || { echo "fga_write: needs at least one triple" >&2; return 2; }
  local triples; triples=$(_fga_triples_json "$@")
  local body; body=$(M="${FGA_MODEL_ID}" T="${triples}" python3 -c '
import json, os
print(json.dumps({"authorization_model_id": os.environ["M"],
                  "writes": {"tuple_keys": json.loads(os.environ["T"])}}))
')
  local tmp; tmp=$(mktemp); printf '%s' "$body" > "$tmp"
  fga_post "/stores/${FGA_STORE_ID}/write" "$tmp"; local http="${FGA_HTTP_CODE}"; rm -f "$tmp"
  if [[ "$http" == "200" || "$http" == "204" ]]; then return 0; fi
  # 400 "already exists" is idempotent success.
  if [[ "$http" == "400" ]]; then
    echo "fga_write: HTTP 400 (possibly already-exists); treating as idempotent ok" >&2; return 0
  fi
  echo "fga_write: HTTP $http" >&2; return 4
}

# Idempotent tuple delete (batched). Returns non-zero on hard failure.
fga_delete() {
  [[ $# -ge 3 ]] || { echo "fga_delete: needs at least one triple" >&2; return 2; }
  local triples; triples=$(_fga_triples_json "$@")
  local body; body=$(M="${FGA_MODEL_ID}" T="${triples}" python3 -c '
import json, os
print(json.dumps({"authorization_model_id": os.environ["M"],
                  "deletes": {"tuple_keys": json.loads(os.environ["T"])}}))
')
  local tmp; tmp=$(mktemp); printf '%s' "$body" > "$tmp"
  fga_post "/stores/${FGA_STORE_ID}/write" "$tmp"; local http="${FGA_HTTP_CODE}"; rm -f "$tmp"
  if [[ "$http" == "200" || "$http" == "204" || "$http" == "400" ]]; then return 0; fi
  echo "fga_delete: HTTP $http" >&2; return 4
}

# fga_check <user> <relation> <object> : print allowed=true|false; return 0 if allowed.
fga_check() {
  local user="$1" rel="$2" obj="$3"
  local body; body=$(M="${FGA_MODEL_ID}" U="$user" R="$rel" O="$obj" python3 -c '
import json, os
print(json.dumps({"authorization_model_id": os.environ["M"],
                  "tuple_key": {"user": os.environ["U"], "relation": os.environ["R"], "object": os.environ["O"]}}))
')
  local tmp out; tmp=$(mktemp); out=$(mktemp); printf '%s' "$body" > "$tmp"
  fga_post_capture "/stores/${FGA_STORE_ID}/check" "$tmp" "$out"; local http="${FGA_HTTP_CODE}"; rm -f "$tmp"
  if [[ "$http" != "200" ]]; then echo "fga_check: HTTP $http" >&2; rm -f "$out"; return 4; fi
  local allowed; allowed=$(python3 -c 'import json,sys; print("true" if json.load(sys.stdin).get("allowed") else "false")' < "$out")
  rm -f "$out"
  echo "allowed=${allowed}"
  [[ "$allowed" == "true" ]]
}

# Print JSON array of all tuples as {user,relation,object} (paginated).
fga_read_all_tuples() {
  python3 - <<'PY'
import json, os, urllib.request
url = os.environ["FGA_API_URL"].rstrip("/") + f"/stores/{os.environ['FGA_STORE_ID']}/read"
token = os.environ["ACCESS_TOKEN"]
out = []
tok = ""
while True:
    payload = {"page_size": 100}
    if tok: payload["continuation_token"] = tok
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), method="POST",
                                 headers={"Content-Type":"application/json","Accept":"application/json",
                                          "Authorization": f"Bearer {token}"})
    import urllib.error
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            d = json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        print(json.dumps([])); raise SystemExit(4)
    for t in d.get("tuples", []):
        k = t.get("key", {})
        out.append({"user": k.get("user"), "relation": k.get("relation"), "object": k.get("object")})
    tok = d.get("continuation_token") or ""
    if not tok: break
print(json.dumps(out))
PY
}

# fga_list_objects <user> <relation> <type> : print JSON array of object ids.
fga_list_objects() {
  local user="$1" rel="$2" typ="$3"
  local body; body=$(M="${FGA_MODEL_ID}" U="$user" R="$rel" T="$typ" python3 -c '
import json, os
print(json.dumps({"authorization_model_id": os.environ["M"],
                  "user": os.environ["U"], "relation": os.environ["R"], "type": os.environ["T"]}))
')
  local tmp out; tmp=$(mktemp); out=$(mktemp); printf '%s' "$body" > "$tmp"
  fga_post_capture "/stores/${FGA_STORE_ID}/list-objects" "$tmp" "$out"; local http="${FGA_HTTP_CODE}"; rm -f "$tmp"
  if [[ "$http" != "200" ]]; then echo "fga_list_objects: HTTP $http" >&2; cat "$out" >&2; rm -f "$out"; return 4; fi
  python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("objects", [])))' < "$out"
  rm -f "$out"
}

# fga_list_users <relation> <object> <user_type> : print JSON array of users.
fga_list_users() {
  local rel="$1" obj="$2" utype="$3"
  local body; body=$(M="${FGA_MODEL_ID}" R="$rel" O="$obj" U="$utype" python3 -c '
import json, os
o = os.environ["O"]
otype, _, oid = o.partition(":")
print(json.dumps({"authorization_model_id": os.environ["M"],
                  "object": {"type": otype, "id": oid},
                  "relation": os.environ["R"],
                  "user_filters": [{"type": os.environ["U"]}]}))
')
  local tmp out; tmp=$(mktemp); out=$(mktemp); printf '%s' "$body" > "$tmp"
  fga_post_capture "/stores/${FGA_STORE_ID}/list-users" "$tmp" "$out"; local http="${FGA_HTTP_CODE}"; rm -f "$tmp"
  if [[ "$http" != "200" ]]; then echo "fga_list_users: HTTP $http" >&2; cat "$out" >&2; rm -f "$out"; return 4; fi
  python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("users", [])))' < "$out"
  rm -f "$out"
}

fga_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

fga_audit() {
  local line="$1"
  echo "${line}" >&2
  mkdir -p "$(dirname "${FGA_AUDIT_LOG}")"
  echo "${line}" >> "${FGA_AUDIT_LOG}"
}
