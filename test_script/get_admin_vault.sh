#!/usr/bin/env bash
# get_admin_vault.sh
# ==================
# Print each tenant's decoded backend cloud credentials from Vault
# (secret/data/libcloud/<tenant>) via jq .data.data.
#
# The tenant list is discovered from OpenFGA (via list_openfga_tenants.sh)
# rather than hardcoded — OpenFGA is the source of truth for which tenants
# exist, so company/department tenants created after this script was written
# are not silently missed.
#
# WARNING: this writes live cloud credentials to stdout in plaintext. Do not run
# it in a shared session, a recorded terminal, or anywhere the scrollback is kept.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=/dev/null
source "${REPO_ROOT}/vault/generated/vault.env"

# Discover tenants from OpenFGA (single source of truth).
tenants="$( "${REPO_ROOT}/test_script/list_openfga_tenants.sh" )" || {
  echo "FATAL: could not list tenants from OpenFGA." >&2
  exit 1
}

for tenant in ${tenants}; do
  echo "== tenant:${tenant} =="
  curl -s -H "X-Vault-Token: $VAULT_ROOT_TOKEN" \
    "$VAULT_ADDR/v1/secret/data/libcloud/${tenant}" | jq '.data.data'
  echo
done
