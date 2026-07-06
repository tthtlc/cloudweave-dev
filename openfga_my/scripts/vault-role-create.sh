#!/usr/bin/env bash
# vault-role-create.sh — create a Vault dynamic-secret role for a cloud secrets
# engine.
#
# Cloud Owner tool. The IAM / IAM-equivalent policy document is passed as a file
# argument. The role is created at /<mount>/roles/<role> using the body shape
# appropriate to the engine:
#
#   aws/alibaba: { "credential_type": "assumed_role", "policy_document": "<json>" }
#                (set --credential-type to override; default assumed_role)
#   azure:       { "azure_roles": [<JSON RBAC role assignments>] }
#                (the file is the JSON array, passed verbatim under azure_roles)
#   gcp:         { "secret_type": "access_token", "token_scopes": [...],
#                 "bindings": "...", "project_ids": [...] }
#                (the file is the JSON role body, merged into the request)
#
# Usage:
#   vault-role-create.sh <provider> <role> <policy-file> [--mount <path>]
#                        [--credential-type <t>] [--ttl <d>] [--max-ttl <d>]
#                        [--dry-run] [--vault-token <t>]
#
# Examples:
#   vault-role-create.sh aws ec2-admin policy-files/ec2-admin.json
#   vault-role-create.sh aws ec2-admin '{"Version":"2012-10-17",...}'  # inline
#   vault-role-create.sh gcp gcs-admin policy-files/gcp-admin.json --mount gcp
#
# A policy-file argument that starts with "{" is treated as an inline JSON
# string (read from the argv, not a file).
#
# Exit codes:
#   0  role created (idempotent: overwrites existing role with the same body)
#   2  usage / missing file / unknown provider
#   3  no Vault token / Vault unreachable
#   4  Vault rejected the role write
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vault_common.sh
source "${SCRIPT_DIR}/vault_common.sh"

PROVIDER=""
ROLE=""
POLICY_ARG=""
MOUNT=""
CRED_TYPE="assumed_role"
TTL=""
MAX_TTL=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mount)           MOUNT="$2"; shift 2 ;;
    --credential-type) CRED_TYPE="$2"; shift 2 ;;
    --ttl)             TTL="$2"; shift 2 ;;
    --max-ttl)         MAX_TTL="$2"; shift 2 ;;
    --vault-token)     VAULT_TOKEN_ARG="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)         sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)               echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$PROVIDER" ]]; then PROVIDER="$1"
      elif [[ -z "$ROLE" ]]; then ROLE="$1"
      elif [[ -z "$POLICY_ARG" ]]; then POLICY_ARG="$1"
      else echo "ERROR: unexpected argument: $1" >&2; exit 2; fi
      shift ;;
  esac
done

[[ -n "$PROVIDER" ]] || { echo "ERROR: provider is required" >&2; exit 2; }
[[ -n "$ROLE" ]]     || { echo "ERROR: role name is required" >&2; exit 2; }
[[ -n "$POLICY_ARG" ]] || { echo "ERROR: policy file (or inline JSON) is required" >&2; exit 2; }
case "$PROVIDER" in
  aws|azure|gcp|alibaba) : ;;
  *) echo "ERROR: unsupported provider: $PROVIDER (aws|azure|gcp|alibaba)" >&2; exit 2 ;;
esac
if ! [[ "$ROLE" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "ERROR: role name must match [a-zA-Z0-9._-]" >&2; exit 2
fi
: "${MOUNT:=$PROVIDER}"
MOUNT="${MOUNT%/}"

# Resolve the policy document: inline JSON (starts with '{') or a file path.
if [[ "$POLICY_ARG" == \{* ]]; then
  POLICY_DOC="$POLICY_ARG"
elif [[ -f "$POLICY_ARG" ]]; then
  POLICY_DOC="$(cat "$POLICY_ARG")"
else
  echo "ERROR: policy argument is neither inline JSON nor an existing file: $POLICY_ARG" >&2
  exit 2
fi

# Validate the policy doc parses as JSON.
if ! DOC="$POLICY_DOC" python3 -c 'import json,os; json.loads(os.environ["DOC"])' 2>/dev/null; then
  echo "ERROR: policy document is not valid JSON" >&2; exit 2
fi

# Build the engine-specific role body.
case "$PROVIDER" in
  aws|alibaba)
    body=$(DOC="$POLICY_DOC" CT="$CRED_TYPE" TTL="$TTL" MTTL="$MAX_TTL" python3 - <<'PY'
import json, os
b = {"credential_type": os.environ["CT"], "policy_document": json.loads(os.environ["DOC"])}
if os.environ["TTL"]:  b["ttl"] = os.environ["TTL"]
if os.environ["MTTL"]: b["max_ttl"] = os.environ["MTTL"]
print(json.dumps(b))
PY
)
    ;;
  azure)
    body=$(DOC="$POLICY_DOC" TTL="$TTL" MTTL="$MAX_TTL" python3 - <<'PY'
import json, os
b = {"azure_roles": json.loads(os.environ["DOC"])}
if os.environ["TTL"]:  b["ttl"] = os.environ["TTL"]
if os.environ["MTTL"]: b["max_ttl"] = os.environ["MTTL"]
print(json.dumps(b))
PY
)
    ;;
  gcp)
    body=$(DOC="$POLICY_DOC" TTL="$TTL" MTTL="$MAX_TTL" python3 - <<'PY'
import json, os
# Treat the file as the GCP role body verbatim; merge ttl/max_ttl if given.
b = json.loads(os.environ["DOC"])
if os.environ["TTL"]:  b.setdefault("ttl", os.environ["TTL"])
if os.environ["MTTL"]: b.setdefault("max_ttl", os.environ["MTTL"])
print(json.dumps(b))
PY
)
    ;;
esac

body_tmp=$(vault_body_file "$body")

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] would POST /${MOUNT}/roles/${ROLE} (provider=${PROVIDER})" >&2
  echo "[dry-run] body (policy redacted): $(printf '%s' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); d.pop("policy_document",None); d.pop("azure_roles",None); d.pop("bindings",None); print(json.dumps(d))')" >&2
  vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"role-create\",\"provider\":\"${PROVIDER}\",\"mount\":\"${MOUNT}\",\"role\":\"${ROLE}\",\"result\":\"dry-run\"}"
  rm -f "$body_tmp"; exit 0
fi

echo "Creating Vault role '${ROLE}' at ${MOUNT}/roles/${ROLE} (provider=${PROVIDER}) ..." >&2
vault_post "${MOUNT}/roles/${ROLE}" "$body_tmp"
http="$VAULT_HTTP_CODE"
resp=$(cat "$VAULT_OUT")
rm -f "$body_tmp"
if [[ "$http" != "200" && "$http" != "204" ]]; then
  echo "ERROR: Vault rejected role write (http=${http}): ${resp}" >&2
  vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"role-create\",\"provider\":\"${PROVIDER}\",\"mount\":\"${MOUNT}\",\"role\":\"${ROLE}\",\"result\":\"error\",\"http\":${http:-0}}"
  exit 4
fi

# Read-back: confirm the role exists.
vault_get "${MOUNT}/roles/${ROLE}"
read_body=$(cat "$VAULT_OUT")
read_http="$VAULT_HTTP_CODE"
if [[ "$read_http" == "200" ]]; then
  echo "OK: role '${ROLE}' created and read-back verified." >&2
else
  echo "WARN: role write returned ${http} but read-back returned ${read_http}." >&2
fi
vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"role-create\",\"provider\":\"${PROVIDER}\",\"mount\":\"${MOUNT}\",\"role\":\"${ROLE}\",\"result\":\"ok\",\"http\":${http:-0}}"
exit 0
