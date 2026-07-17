#!/usr/bin/env bash
# vault-root-cred-rotate.sh — rotate the root credentials of a cloud secrets
# engine.
#
# Cloud Owner tool. Calls `POST /<mount>/config/rotate-root`. Should be run
# quarterly per provider. After rotation Vault holds the ONLY copy of the new
# root credential — the previous root credential (whatever you supplied when
# you ran vault-secrets-engine-enable.sh) becomes invalid at the cloud provider.
#
# **WARNING**: this is a one-way operation. Ensure you have a safe copy of the
# new root credential OUTSIDE Vault before relying on it, or accept that Vault
# is now the sole custodian. The script refuses to run without an explicit
# --confirm flag.
#
# Usage:
#   vault-root-cred-rotate.sh <mount> --confirm
#   vault-root-cred-rotate.sh aws --confirm
#   vault-root-cred-rotate.sh gcp --confirm --dry-run
#
# Options:
#   --confirm          REQUIRED — guard against accidental rotation
#   --vault-token <t>  use this Vault token
#   --dry-run          validate mount exists; do not call rotate-root
#   -h, --help
#
# Exit codes:
#   0  root credential rotated
#   2  usage / missing --confirm / unknown mount
#   3  no Vault token / Vault unreachable
#   4  Vault rejected rotate-root
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vault_common.sh
source "${SCRIPT_DIR}/vault_common.sh"

CONFIRM=0
DRY_RUN=0
MOUNT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm)     CONFIRM=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --vault-token) VAULT_TOKEN_ARG="$2"; shift 2 ;;
    -h|--help)     sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)           echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$MOUNT" ]]; then MOUNT="$1"
      else echo "ERROR: unexpected argument: $1" >&2; exit 2; fi
      shift ;;
  esac
done

[[ -n "$MOUNT" ]] || { echo "ERROR: mount is required" >&2; exit 2; }
MOUNT="${MOUNT%/}"
if ! [[ "$MOUNT" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
  echo "ERROR: mount must match [a-zA-Z0-9._/-]" >&2; exit 2
fi
if [[ "$CONFIRM" -ne 1 && "$DRY_RUN" -ne 1 ]]; then
  echo "ERROR: --confirm is required to rotate root credentials (this is a one-way operation)." >&2
  echo "       Re-run with --confirm once you accept that Vault will hold the only copy." >&2
  exit 2
fi

# Pre-flight: confirm the mount exists.
vault_get "sys/mounts"
mount_http="$VAULT_HTTP_CODE"
mounts_body=$(cat "$VAULT_OUT")
if [[ "$mount_http" != "200" ]]; then
  echo "ERROR: cannot read /sys/mounts (http=${mount_http})" >&2; exit 3
fi
mount_key="${MOUNT}/"
exists=$(KEY="$mount_key" BODY="$mounts_body" python3 -c '
import json, os
try:
    d = json.loads(os.environ["BODY"])
    print("1" if os.environ["KEY"] in d else "0")
except Exception:
    print("0")
')
if [[ "$exists" != "1" ]]; then
  echo "ERROR: mount '${MOUNT}/' is not enabled in Vault" >&2; exit 2
fi
echo "Pre-flight: mount ${MOUNT}/ is enabled." >&2

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] would POST /${MOUNT}/config/rotate-root (one-way; Vault becomes sole custodian)." >&2
  vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"root-cred-rotate\",\"mount\":\"${MOUNT}\",\"result\":\"dry-run\"}"
  exit 0
fi

echo "WARNING: rotating root credentials for ${MOUNT}/. Vault will hold the only copy." >&2
resp=$(vault_post "${MOUNT}/config/rotate-root")
http="$VAULT_HTTP_CODE"
if [[ "$http" != "200" && "$http" != "204" ]]; then
  echo "ERROR: Vault rejected rotate-root (http=${http}): ${resp}" >&2
  vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"root-cred-rotate\",\"mount\":\"${MOUNT}\",\"result\":\"error\",\"http\":${http:-0}}"
  exit 4
fi

echo "OK: root credentials rotated for ${MOUNT}/. Update any external records to reflect that Vault now holds the new root." >&2
vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"root-cred-rotate\",\"mount\":\"${MOUNT}\",\"result\":\"ok\",\"http\":${http:-0}}"
exit 0
