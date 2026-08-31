#!/usr/bin/env bash
# get_admin_vault.sh
# ==================
# Print each tenant's decoded backend cloud credentials from Vault
# (secret/data/libcloud/<tenant>) via jq .data.data.
#
# WARNING: this writes live cloud credentials to stdout in plaintext. Do not run
# it in a shared session, a recorded terminal, or anywhere the scrollback is kept.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=/dev/null
source "${REPO_ROOT}/vault/generated/vault.env"

# One tenant per company: Nutanix + AWS (aws, aws1, aws2).
for tenant in nutanix aws aws1 aws2; do
  echo "== tenant:${tenant} =="
  curl -s -H "X-Vault-Token: $VAULT_ROOT_TOKEN" \
    "$VAULT_ADDR/v1/secret/data/libcloud/${tenant}" | jq .data.data
  echo
done
