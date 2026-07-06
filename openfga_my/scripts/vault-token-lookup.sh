#!/usr/bin/env bash
# vault-token-lookup.sh — look up a Vault token's policies, TTL, and accessor.
#
# Cloud Admin tool. Used to verify that a service or user token has the
# expected permissions. Without an argument, looks up the calling token
# (lookup-self). With a token argument, looks up that token (requires the
# calling token to have the `auth/token/lookup` capability — e.g. root or a
# sudo-capable token). With --accessor, treats the argument as an accessor
# and calls /auth/token/lookup-accessor.
#
# Usage:
#   vault-token-lookup.sh                 # lookup-self
#   vault-token-lookup.sh <token>         # lookup a specific token
#   vault-token-lookup.sh <accessor> --accessor
#
# Options:
#   --accessor      treat the argument as a token accessor
#   --vault-token <t>  the token used to make the lookup call
#   --json          print the raw Vault response JSON
#   -h, --help
#
# Exit codes:
#   0  token looked up
#   2  usage
#   3  no Vault token / Vault unreachable
#   4  Vault rejected the lookup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vault_common.sh
source "${SCRIPT_DIR}/vault_common.sh"

ACCESSOR=0
JSON=0
TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --accessor)    ACCESSOR=1; shift ;;
    --json)        JSON=1; shift ;;
    --vault-token) VAULT_TOKEN_ARG="$2"; shift 2 ;;
    -h|--help)     sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)           echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$TARGET" ]]; then TARGET="$1"
      else echo "ERROR: unexpected argument: $1" >&2; exit 2; fi
      shift ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  path="auth/token/lookup-self"
  body_tmp=""
elif [[ "$ACCESSOR" -eq 1 ]]; then
  body=$(A="$TARGET" python3 -c 'import json,os; print(json.dumps({"accessor": os.environ["A"]}))')
  body_tmp=$(vault_body_file "$body")
  path="auth/token/lookup-accessor"
else
  body=$(T="$TARGET" python3 -c 'import json,os; print(json.dumps({"token": os.environ["T"]}))')
  body_tmp=$(vault_body_file "$body")
  path="auth/token/lookup"
fi

vault_post "$path" "${body_tmp:-}"
http="$VAULT_HTTP_CODE"
resp=$(cat "$VAULT_OUT")
[[ -n "${body_tmp:-}" ]] && rm -f "$body_tmp"

if [[ "$http" != "200" ]]; then
  echo "ERROR: Vault rejected token lookup (http=${http}): ${resp}" >&2
  vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"token-lookup\",\"result\":\"error\",\"http\":${http:-0}}"
  exit 4
fi

if [[ "$JSON" -eq 1 ]]; then
  printf '%s\n' "$resp" | vault_json_pretty
else
  d=$(printf '%s' "$resp" | vault_json_field /dev/stdin "data")
  python3 - "$d" <<'PY'
import json, sys
d = json.loads(sys.argv[1]) if sys.argv[1] else {}
pols = d.get("policies") or []
print(f"id           : {d.get('id','?')}")
print(f"accessor     : {d.get('accessor','?')}")
print(f"display_name : {d.get('display_name','-')}")
print(f"policies     : {', '.join(pols)}")
print(f"ttl          : {d.get('ttl','?')}s")
print(f"renewable    : {d.get('renewable')}")
print(f"expire_time  : {d.get('expire_time','-')}")
print(f"creation_ttl : {d.get('creation_ttl','?')}s")
print(f"type         : {d.get('type','-')}")
meta = d.get("meta") or {}
if meta:
    print(f"meta         : {json.dumps(meta)}")
PY
fi

vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"token-lookup\",\"result\":\"ok\",\"http\":${http:-0},\"accessor\":${ACCESSOR}}"
exit 0
