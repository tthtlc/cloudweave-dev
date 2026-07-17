#!/usr/bin/env bash
# cloud-keypair-manage.sh — create / list / delete SSH key pairs via libcloud REST.
#
#   cloud-keypair-manage.sh --action list   [--provider ..] [--region ..]
#   cloud-keypair-manage.sh --action create --name <kp> [--public-key <path>]
#   cloud-keypair-manage.sh --action delete --name <kp> [--confirm]
#
# For create without --public-key, libcloud generates a new key pair and returns
# the private key in the response (save it securely).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cloud_common.sh
source "${SCRIPT_DIR}/cloud_common.sh"

ACTION="" NAME="" PUBKEY_FILE="" CONFIRM=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="$2"; shift 2;;
    --name) NAME="$2"; shift 2;;
    --public-key) PUBKEY_FILE="$2"; shift 2;;
    --confirm) CONFIRM=1; shift;;
    --provider) CLOUD_PROVIDER="$2"; shift 2;;
    --region) CLOUD_REGION="$2"; shift 2;;
    --dry-run) CLOUD_DRY_RUN=1; shift;;
    -h|--help) sed -n '2,8p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ -n "$ACTION" ]] || { echo "--action list|create|delete required" >&2; exit 2; }
case "$ACTION" in list|create|delete) ;; *) echo "bad --action" >&2; exit 2;; esac

cloud_setup >/dev/null 2>&1

case "$ACTION" in
  list)
    RESP=$(cloud_api_or_die GET /v1/compute/key-pairs) || exit $?
    echo "$RESP" | python3 -c '
import json, sys
d = json.load(sys.stdin).get("data", []) or []
if not d: print("(no key pairs)"); sys.exit(0)
print(f"{"name":<28} {"fingerprint":<48}")
for k in d:
    print(f"{k.get("name",""):<28} {k.get("fingerprint","") or "-":<48}")
'
    cloud_audit "{\"ts\":\"$(cloud_now)\",\"actor\":\"${LIBCLOUD_USER}\",\"action\":\"keypair-list\",\"provider\":\"$(cloud_provider)\",\"result\":\"ok\"}"
    ;;
  create)
    [[ -n "$NAME" ]] || { echo "--name required for create" >&2; exit 2; }
    PUBKEY=""
    [[ -n "$PUBKEY_FILE" ]] && PUBKEY=$(cat "$PUBKEY_FILE" 2>/dev/null || { echo "cannot read --public-key" >&2; exit 2; })
    BODY=$(python3 -c '
import json, os
b = {"name": os.environ["N"]}
if os.environ.get("P"): b["public_key"] = os.environ["P"]
print(json.dumps(b))
' N="$NAME" P="$PUBKEY")
    CREATE_BODY=$(with_connection "$BODY")
    RESP=$(cloud_api POST /v1/compute/key-pairs "$CREATE_BODY") || { echo "create failed" >&2; exit 4; }
    cloud_audit "{\"ts\":\"$(cloud_now)\",\"actor\":\"${LIBCLOUD_USER}\",\"action\":\"keypair-create\",\"provider\":\"$(cloud_provider)\",\"name\":\"${NAME}\",\"result\":\"ok\"}"
    echo "$RESP" | json_pretty
    ;;
  delete)
    [[ -n "$NAME" ]] || { echo "--name required for delete" >&2; exit 2; }
    [[ "$CONFIRM" == "1" ]] || { echo "REFUSING delete without --confirm" >&2; exit 3; }
    cloud_api DELETE "/v1/compute/key-pairs/${NAME}" >/dev/null || { echo "delete failed" >&2; exit 4; }
    cloud_audit "{\"ts\":\"$(cloud_now)\",\"actor\":\"${LIBCLOUD_USER}\",\"action\":\"keypair-delete\",\"provider\":\"$(cloud_provider)\",\"name\":\"${NAME}\",\"result\":\"ok\"}"
    echo "deleted key pair: ${NAME}"
    ;;
esac
