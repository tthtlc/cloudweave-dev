#!/usr/bin/env bash
# register_aws_tenants.sh
# =======================
# Register multiple AWS tenants (aws1, aws2, ...), each bound to its own AWS
# account. For every tenant this script:
#   1. creates the tenant (LLDAP owner/admin/viewer + OpenFGA tuples) via
#      create_tenant.sh, then
#   2. writes the tenant's AWS access key / secret into Vault using the exact
#      same set_tenant_credentials.py invocation used for the default `aws`
#      tenant:
#
#        LIBCLOUD_OIDC_CLIENT_SECRET=... TENANT=aws1 CLOUD=aws \
#          LIBCLOUD_USER=aws1-owner LIBCLOUD_PASSWORD=$LIBCLOUD_PASSWORD_AWS1_OWNER \
#          LIBCLOUD_AWS_KEY=AKIA... LIBCLOUD_AWS_SECRET=... \
#          python3 scripts/set_tenant_credentials.py
#
# So `aws1` and `aws2` resolve to two different AWS accounts (different access
# keys), each addressable as tenant:aws1 / tenant:aws2 with Vault path
# secret/data/libcloud/<tenant>.
#
# Add / edit entries in the AWS_TENANTS table below — one line per tenant:
#   "tenant|access_key|secret_key"
#
# Requirements: ./setup.sh must have run (dex.env / fga.env / vault.env exist)
# and Docker must be up (create_tenant.sh talks to LLDAP + OpenFGA).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/test_script/scripts"
DEX_GENERATED="${REPO_ROOT}/test_script/generated/dex.env"

# ---- AWS tenants to register ----------------------------------------------
# tenant | AWS access key | AWS secret key
AWS_TENANTS=(
  "aws1|AKIAYHGEH2P726TAT2PS|7gBeZLpQreS7571fLGOjAx2iOmpW6vgdnRIPUtnN"
  "aws2|AKIAYHGEH2P7QJKE5UGO|yuOczKQe38Er0jUdeWlGnRJTZrTT87wCzJU4ool2"
)

# shellcheck source=common.sh
source "${SCRIPTS_DIR}/common.sh" >/dev/null 2>&1 || {
  echo "FATAL: cannot source scripts/common.sh — run ./setup.sh first." >&2
  exit 2
}

# Env key create_tenant.sh uses for a tenant's owner password, e.g.
#   aws1 -> LIBCLOUD_PASSWORD_AWS1_OWNER
_pw_key() { echo "LIBCLOUD_PASSWORD_$(echo "$1" | tr '[:lower:]-' '[:upper:]_')_OWNER"; }

for entry in "${AWS_TENANTS[@]}"; do
  IFS='|' read -r tenant access_key secret_key <<< "${entry}"
  [[ -n "${tenant}" && -n "${access_key}" && -n "${secret_key}" ]] || {
    echo "FATAL: malformed AWS_TENANTS entry: '${entry}'" >&2
    exit 2
  }
  pw_key="$(_pw_key "${tenant}")"

  echo "======================================================================"
  echo "tenant:${tenant}  (owner user: ${tenant}-owner)"
  echo "======================================================================"

  # 1. Create the tenant (LLDAP users + OpenFGA tuples). Idempotent: if the
  #    owner password is already recorded, the tenant was created before and
  #    we reuse it so re-runs do not rotate the password.
  if grep -q "^${pw_key}=" "${DEX_GENERATED}" 2>/dev/null; then
    echo "tenant:${tenant} already exists — reusing recorded owner password."
  else
    echo "Creating tenant:${tenant} (CLOUD=aws) ..."
    TENANT="${tenant}" CLOUD=aws "${SCRIPTS_DIR}/create_tenant.sh"
  fi

  # 2. Read the owner password that create_tenant.sh persisted.
  owner_pw="$(grep -E "^${pw_key}=" "${DEX_GENERATED}" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  if [[ -z "${owner_pw}" ]]; then
    echo "FATAL: no owner password found for ${pw_key} — create_tenant.sh may have failed." >&2
    exit 1
  fi

  # 3. Register backend credentials (same command as the default aws tenant).
  LIBCLOUD_OIDC_CLIENT_SECRET="${LIBCLOUD_OIDC_CLIENT_SECRET}" \
    TENANT="${tenant}" CLOUD=aws \
    LIBCLOUD_USER="${tenant}-owner" LIBCLOUD_PASSWORD="${owner_pw}" \
    LIBCLOUD_AWS_KEY="${access_key}" LIBCLOUD_AWS_SECRET="${secret_key}" \
    python3 "${SCRIPTS_DIR}/set_tenant_credentials.py"

  echo "tenant:${tenant} registered (Vault path: secret/data/libcloud/${tenant})."
  echo
done

echo "Done. Registered ${#AWS_TENANTS[@]} AWS tenant(s)."
