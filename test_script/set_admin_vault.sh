#!/usr/bin/env bash
# set_admin_vault.sh
# ==================
# Seed each tenant's backend cloud credentials into Vault by logging in as that
# tenant's OWNER. set_tenant_credentials.py performs its own Dex login and an
# OpenFGA can_manage_credentials check before writing, so the authorization path
# is exercised rather than bypassed.
#
# Companies map to AWS tenants (aws, aws1, aws2, ...) — all under the AWS
# provider — each with its own access key / secret from tenant_vault_secret.env.
# The single Nutanix tenant is seeded separately.
#
# Owner passwords come from the generated dex.env files: aws-owner lives in
# dex/generated/dex.env, while aws1-owner / aws2-owner are appended to
# test_script/generated/dex.env by create_tenant.sh / register_aws_tenants.sh.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=/dev/null
source "${REPO_ROOT}/dex/generated/dex.env"
# shellcheck source=/dev/null
source "${REPO_ROOT}/test_script/generated/dex.env" 2>/dev/null || true
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/tenant_vault_secret.env"

# ---- Nutanix tenant --------------------------------------------------------
LIBCLOUD_OIDC_CLIENT_SECRET=${LIBCLOUD_OIDC_CLIENT_SECRET} TENANT=nutanix LIBCLOUD_USER=ntnx-owner LIBCLOUD_PASSWORD=$LIBCLOUD_PASSWORD_NTNX_OWNER \
    LIBCLOUD_NTNX_USER=${LIBCLOUD_NTNX_USER} LIBCLOUD_NTNX_PASSWORD=${LIBCLOUD_NTNX_PASSWORD} \
    python3 ${REPO_ROOT}/test_script/scripts/set_tenant_credentials.py

# ---- AWS tenants (one per company, all under the AWS provider) -------------
# Table columns: tenant | owner-password-env-var | access-key-env-var | secret-key-env-var
while IFS='|' read -r tenant owner_pw_var access_var secret_var; do
  [[ -z "${tenant}" || "${tenant}" =~ ^[[:space:]]*# ]] && continue
  LIBCLOUD_OIDC_CLIENT_SECRET=${LIBCLOUD_OIDC_CLIENT_SECRET} \
    TENANT="${tenant}" CLOUD=aws \
    LIBCLOUD_USER="${tenant}-owner" LIBCLOUD_PASSWORD="${!owner_pw_var}" \
    LIBCLOUD_AWS_KEY="${!access_var}" LIBCLOUD_AWS_SECRET="${!secret_var}" \
    python3 ${REPO_ROOT}/test_script/scripts/set_tenant_credentials.py
done <<'AWS_TENANTS'
aws|LIBCLOUD_PASSWORD_AWS_OWNER|AWS_ACCESS_KEY|AWS_SECRET_ACCESS_KEY
aws1|LIBCLOUD_PASSWORD_AWS1_OWNER|AWS1_ACCESS_KEY|AWS1_SECRET_KEY
aws2|LIBCLOUD_PASSWORD_AWS2_OWNER|AWS2_ACCESS_KEY|AWS2_SECRET_KEY
AWS_TENANTS
