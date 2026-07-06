#!/usr/bin/env bash
# vault-secrets-engine-enable.sh — enable + configure a cloud provider secrets
# engine at a given mount path.
#
# Cloud Owner tool. One-off per provider. Supports the engines Vault ships for
# the major clouds:
#   aws     -> vault secrets enable aws-path aws;     vault write aws-path/config/root
#   azure   -> vault secrets enable azure-path azure; vault write azure-path/config
#   gcp     -> vault secrets enable gcp-path gcp;     vault write gcp-path/config
#   alibaba -> vault secrets enable alic-path alibaba;vault write alic-path/config
#
# Root credentials are read from a local env file (key=value or a single JSON
# object) whose path is passed on the CLI — never hardcoded, never logged. The
# file is read once, mapped to the engine-specific /config body, and the values
# are not echoed.
#
# Usage:
#   vault-secrets-engine-enable.sh --provider <aws|azure|gcp|alibaba> \
#       --mount <path> --root-creds-file <file> [--region <r>] [--dry-run]
#
# Options:
#   --provider          aws | azure | gcp | alibaba  (required)
#   --mount             mount path without trailing slash (e.g. aws, azure-prod)
#   --root-creds-file   file with root credentials (key=value or JSON object)
#   --region            default region (aws / alibaba)
#   --vault-token <t>   use this Vault token
#   --dry-run           show what would be done; do not call Vault
#   -h, --help
#
# Root creds file keys (per provider):
#   aws     : access_key, secret_key, region  (region optional if --region given)
#   alibaba : access_key, secret_key, region
#   azure   : client_id, client_secret, subscription_id, tenant_id
#   gcp     : credentials  (raw JSON service-account key, multi-line OK)
#
# Exit codes:
#   0  engine enabled + configured
#   2  usage / missing or unreadable creds file / unknown provider
#   3  no Vault token / Vault unreachable
#   4  Vault rejected enable or config write
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vault_common.sh
source "${SCRIPT_DIR}/vault_common.sh"

PROVIDER=""
MOUNT=""
CREDS_FILE=""
REGION=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)        PROVIDER="$2"; shift 2 ;;
    --mount)           MOUNT="$2"; shift 2 ;;
    --root-creds-file) CREDS_FILE="$2"; shift 2 ;;
    --region)          REGION="$2"; shift 2 ;;
    --vault-token)     VAULT_TOKEN_ARG="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)         sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$PROVIDER" ]] || { echo "ERROR: --provider is required" >&2; exit 2; }
[[ -n "$MOUNT" ]]    || { echo "ERROR: --mount is required" >&2; exit 2; }
[[ -n "$CREDS_FILE" ]] || { echo "ERROR: --root-creds-file is required" >&2; exit 2; }
[[ -f "$CREDS_FILE" ]] || { echo "ERROR: creds file not found: $CREDS_FILE" >&2; exit 2; }
if ! [[ "$MOUNT" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
  echo "ERROR: mount must match [a-zA-Z0-9._/-]" >&2; exit 2
fi
MOUNT="${MOUNT%/}"
case "$PROVIDER" in
  aws|azure|gcp|alibaba) : ;;
  *) echo "ERROR: unsupported provider: $PROVIDER (aws|azure|gcp|alibaba)" >&2; exit 2 ;;
esac

# Build the /config body from the creds file. The file may be either a flat
# key=value env file or a single JSON object. Convert to a JSON object first.
creds_json=$(FILE="$CREDS_FILE" python3 - <<'PY'
import json, os, sys
path = os.environ["FILE"]
raw = open(path).read().strip()
if raw.startswith("{"):
    obj = json.loads(raw)
else:
    obj = {}
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line: continue
        k, v = line.split("=", 1)
        obj[k.strip()] = v.strip()
print(json.dumps(obj))
PY
)

case "$PROVIDER" in
  aws|alibaba)
    cfg_body=$(C="$creds_json" R="$REGION" P="$PROVIDER" python3 - <<'PY'
import json, os
c = json.loads(os.environ["C"])
r = os.environ["R"]
if r: c.setdefault("region", r)
# aws engine needs both access_key + secret_key at /config/root (root creds).
body = {
    "access_key": c.get("access_key", ""),
    "secret_key": c.get("secret_key", ""),
}
if c.get("region"): body["region"] = c["region"]
print(json.dumps(body))
PY
)
    config_path="${MOUNT}/config/root"
    ;;
  azure)
    cfg_body=$(C="$creds_json" python3 - <<'PY'
import json, os
c = json.loads(os.environ["C"])
body = {
    "client_id":       c.get("client_id", ""),
    "client_secret":   c.get("client_secret", ""),
    "subscription_id": c.get("subscription_id", ""),
    "tenant_id":       c.get("tenant_id", ""),
}
print(json.dumps(body))
PY
)
    config_path="${MOUNT}/config"
    ;;
  gcp)
    cfg_body=$(C="$creds_json" python3 - <<'PY'
import json, os
c = json.loads(os.environ["C"])
# Vault GCP config accepts the raw service-account JSON as `credentials`.
body = {"credentials": c.get("credentials", c.get("service_account_json", ""))}
print(json.dumps(body))
PY
)
    config_path="${MOUNT}/config"
    ;;
esac

enable_body=$(P="$PROVIDER" python3 -c '
import json, os
print(json.dumps({"type": os.environ["P"], "description": os.environ["P"] + " cloud secrets engine", "config": {}}))
')
enable_tmp=$(vault_body_file "$enable_body")
cfg_tmp=$(vault_body_file "$cfg_body")

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] would: POST /sys/mounts/${MOUNT} type=${PROVIDER}" >&2
  echo "[dry-run] would: POST /${config_path} (root creds redacted)" >&2
  vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"secrets-engine-enable\",\"provider\":\"${PROVIDER}\",\"mount\":\"${MOUNT}\",\"result\":\"dry-run\"}"
  rm -f "$enable_tmp" "$cfg_tmp"
  exit 0
fi

# 1. Enable the engine (idempotent: 400 "path is already in use" is OK).
echo "Enabling ${PROVIDER} secrets engine at ${MOUNT}/ ..." >&2
vault_post "sys/mounts/${MOUNT}" "$enable_tmp"
enable_http="$VAULT_HTTP_CODE"
enable_resp=$(cat "$VAULT_OUT")
if [[ "$enable_http" != "200" && "$enable_http" != "204" && "$enable_http" != "400" ]]; then
  echo "ERROR: Vault rejected secrets-enable (http=${enable_http}): ${enable_resp}" >&2
  vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"secrets-engine-enable\",\"provider\":\"${PROVIDER}\",\"mount\":\"${MOUNT}\",\"result\":\"enable-error\",\"http\":${enable_http:-0}}"
  rm -f "$enable_tmp" "$cfg_tmp"; exit 4
fi
if [[ "$enable_http" == "400" ]]; then
  # Inspect the message: "path is already in use" => idempotent ok.
  if echo "$enable_resp" | grep -qi "already in use\|path is already in use"; then
    echo "  engine already enabled at ${MOUNT}/ (idempotent)" >&2
  else
    echo "ERROR: secrets-enable returned 400: ${enable_resp}" >&2
    vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"secrets-engine-enable\",\"provider\":\"${PROVIDER}\",\"mount\":\"${MOUNT}\",\"result\":\"enable-error\",\"http\":400}"
    rm -f "$enable_tmp" "$cfg_tmp"; exit 4
  fi
fi
rm -f "$enable_tmp"

# 2. Configure root credentials.
echo "Writing root credentials to /${config_path} ..." >&2
vault_post "$config_path" "$cfg_tmp"
cfg_http="$VAULT_HTTP_CODE"
cfg_resp=$(cat "$VAULT_OUT")
rm -f "$cfg_tmp"
if [[ "$cfg_http" != "200" && "$cfg_http" != "204" ]]; then
  echo "ERROR: Vault rejected config write (http=${cfg_http}): ${cfg_resp}" >&2
  vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"secrets-engine-enable\",\"provider\":\"${PROVIDER}\",\"mount\":\"${MOUNT}\",\"result\":\"config-error\",\"http\":${cfg_http:-0}}"
  exit 4
fi

echo "OK: ${PROVIDER} secrets engine enabled at ${MOUNT}/ and configured." >&2
vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"secrets-engine-enable\",\"provider\":\"${PROVIDER}\",\"mount\":\"${MOUNT}\",\"result\":\"ok\"}"
exit 0
