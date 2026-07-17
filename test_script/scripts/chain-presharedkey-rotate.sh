#!/usr/bin/env bash
# chain-presharedkey-rotate.sh — rotate the OpenFGA preshared key end-to-end.
#
# Cloud Owner tool. Orchestrates the full rotation chain (delegating the heavy
# lifting to openfga-presharedkey-rotate.sh) and then smoke-tests an
# authorization check through the libcloud REST → OpenFGA path to confirm the
# new key is live:
#   1. openfga-presharedkey-rotate.sh --apply
#        - writes the new key to Vault at secret/data/openfga/apikey
#        - updates the OpenFGA server config (OPENFGA_AUTHN_PRESHARED_KEYS)
#        - updates the libcloud REST env (FGA_API_TOKEN)
#        - performs a rolling restart of the openfga + libcloud REST containers
#        - verifies both come back up
#   2. smoke-test: run openfga-check.sh against a representative tuple to
#      confirm the libcloud REST can still reach OpenFGA with the new key
#      (uses FGA_API_TOKEN, which the rotate step just updated).
#
# Without --apply the script only updates Vault + the env files and prints
# restart instructions (no disruption); the smoke-test is then skipped.
#
# Usage:
#   chain-presharedkey-rotate.sh [--apply] [--actor <u>] [--dry-run]
#       [--smoke-user <u>] [--smoke-relation <r>] [--smoke-object <o>]
#       [--vault-token <t>] [--vault-path secret/data/openfga/apikey]
#
# Options:
#   --apply               actually rotate + restart (else: stage only)
#   --actor <u>           audit actor
#   --dry-run             plan only
#   --smoke-user <u>      smoke-test user tuple (default: user:superadmin)
#   --smoke-relation <r>  smoke-test relation (default: can_connect)
#   --smoke-object <o>    smoke-test object (default: libcloud_api:main)
#   --vault-token <t>     forwarded to openfga-presharedkey-rotate.sh
#   --vault-path <p>      forwarded to openfga-presharedkey-rotate.sh
#   --skip-smoke          skip the smoke-test (rotation only)
#   -h, --help
#
# Exit codes:
#   0  rotation + smoke-test ok (or staged without --apply)
#   2  usage
#   3  rotation step failed
#   4  smoke-test failed (key may be rotated but the authz path is broken)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AUDIT_LOG="${REPO_ROOT}/generated/chain_audit.log"
mkdir -p "$(dirname "$AUDIT_LOG")"

APPLY=0
DRY_RUN=0
ACTOR="${USER:-cloud-owner}"
SMOKE_USER="user:superadmin"
SMOKE_REL="can_connect"
SMOKE_OBJ="libcloud_api:main"
SKIP_SMOKE=0
ROTATE_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)           APPLY=1; shift ;;
    --dry-run)         DRY_RUN=1; ROTATE_ARGS+=("$1"); shift ;;
    --actor)           ACTOR="$2"; shift 2 ;;
    --smoke-user)      SMOKE_USER="$2"; shift 2 ;;
    --smoke-relation)  SMOKE_REL="$2"; shift 2 ;;
    --smoke-object)    SMOKE_OBJ="$2"; shift 2 ;;
    --vault-token)     ROTATE_ARGS+=("$1" "$2"); shift 2 ;;
    --vault-path)      ROTATE_ARGS+=("$1" "$2"); shift 2 ;;
    --skip-smoke)      SKIP_SMOKE=1; shift ;;
    -h|--help)         sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

chain_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
chain_audit() { local line="$1"; echo "$line" >&2; echo "$line" >> "$AUDIT_LOG"; }

echo "=== chain-presharedkey-rotate (apply=${APPLY}) ===" >&2

# Step 1: rotate (delegate).
echo "[1/2] openfga-presharedkey-rotate.sh" >&2
rotate_cmd=(bash "${SCRIPT_DIR}/openfga-presharedkey-rotate.sh")
[[ "$APPLY" -eq 1 ]] && rotate_cmd+=(--apply)
rotate_cmd+=("--actor" "$ACTOR" "${ROTATE_ARGS[@]}")
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  [dry-run] would run: ${rotate_cmd[*]}" >&2
  chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-presharedkey-rotate\",\"step\":1,\"result\":\"dry-run\"}"
else
  if "${rotate_cmd[@]}" >/tmp/chain_psk1.log 2>&1; then
    echo "  ok" >&2
    chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-presharedkey-rotate\",\"step\":1,\"result\":\"ok\"}"
  else
    rc=$?
    echo "  FAILED (rc=$rc):" >&2; tail -n 30 /tmp/chain_psk1.log >&2
    chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-presharedkey-rotate\",\"step\":1,\"result\":\"error\",\"rc\":$rc}"
    exit 3
  fi
fi

# Step 2: smoke-test an authorization check.
echo "[2/2] smoke-test openfga-check ${SMOKE_USER} ${SMOKE_REL} ${SMOKE_OBJ}" >&2
if [[ "$SKIP_SMOKE" -eq 1 ]]; then
  echo "  skipped (--skip-smoke)" >&2
  chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-presharedkey-rotate\",\"step\":2,\"result\":\"skipped\"}"
  exit 0
fi
if [[ "$APPLY" -ne 1 || "$DRY_RUN" -eq 1 ]]; then
  echo "  skipped (no --apply / dry-run; key not yet live)" >&2
  chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-presharedkey-rotate\",\"step\":2,\"result\":\"skipped\"}"
  exit 0
fi
# Reload the new FGA_API_TOKEN from the libcloud REST env (written by step 1).
  libcloud_env="${REPO_ROOT}/libcloud.rest/.env"
if [[ -f "$libcloud_env" ]]; then
  # shellcheck disable=SC1090
  set -a; . "$libcloud_env"; set +a
fi
if check_out=$(bash "${SCRIPT_DIR}/openfga-check.sh" "$SMOKE_USER" "$SMOKE_REL" "$SMOKE_OBJ" 2>/tmp/chain_psk2.log); then
  echo "  ${check_out}" >&2
  chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-presharedkey-rotate\",\"step\":2,\"result\":\"ok\",\"check\":\"allowed\"}"
  echo "=== chain-presharedkey-rotate complete; new key is live ===" >&2
  exit 0
else
  rc=$?
  echo "  ${check_out}" >&2
  echo "  smoke-test FAILED (rc=$rc):" >&2; tail -n 20 /tmp/chain_psk2.log >&2
  chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-presharedkey-rotate\",\"step\":2,\"result\":\"smoke-failed\",\"rc\":$rc}"
  echo "=== chain-presharedkey-rotate FAILED smoke-test: the key was rotated but the authz path returned an error ===" >&2
  exit 4
fi
