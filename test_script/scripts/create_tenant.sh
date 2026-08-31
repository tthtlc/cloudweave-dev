#!/usr/bin/env bash
# create_tenant.sh
# =================
# Create a new per-cloud tenant with its own owner/admin/viewer, its own
# OpenFGA backend object, and its own Vault credential binding. This is how
# you give different AWS (or Nutanix) tenants different access keys / secrets.
#
# Gated on a successful superadmin Dex login (SUPERADMIN_JWT). Without it,
# tenant creation is refused — only superadmin can mint new tenants.
#
# Usage:
#   TENANT=aws-dev CLOUD=aws ./scripts/create_tenant.sh
#   TENANT=ntnx-prod CLOUD=nutanix ./scripts/create_tenant.sh
#
# Optional env (random-generated + appended to generated/dex.env if blank):
#   LIBCLOUD_PASSWORD_AWS_DEV_OWNER / _ADMIN / _VIEWER   (for TENANT=aws-dev)
#   LIBCLOUD_PASSWORD_NTNX_PROD_OWNER / _ADMIN / _VIEWER (for TENANT=ntnx-prod)
#
# After creation, the tenant OWNER sets its credentials:
#   TENANT=aws-dev LIBCLOUD_USER=aws-dev-owner LIBCLOUD_PASSWORD=... \
#     LIBCLOUD_AWS_KEY=... LIBCLOUD_AWS_SECRET=... \
#     python3 scripts/set_tenant_credentials.py
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LLDAP_DIR="${REPO_ROOT}/lldap"
cd "$REPO_ROOT"

TENANT="${TENANT:-}"
CLOUD="${CLOUD:-}"

if [[ -z "${TENANT}" || -z "${CLOUD}" ]]; then
  echo "Usage: TENANT=<id> CLOUD=aws|nutanix ./scripts/create_tenant.sh" >&2
  exit 2
fi
case "${CLOUD}" in
  aws)     BACKEND_TYPE="aws_region" ;;
  nutanix) BACKEND_TYPE="nutanix_cluster" ;;
  *) echo "CLOUD must be aws or nutanix (got ${CLOUD})" >&2; exit 2 ;;
esac

# ---- 1. superadmin gate ---------------------------------------------------
if [[ -z "${SUPERADMIN_JWT:-}" ]]; then
  echo "SUPERADMIN_JWT not set — logging in as superadmin ..." >&2
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/superadmin_auth.sh"
fi
export SUPERADMIN_JWT
echo "${SUPERADMIN_JWT}" | docker exec -i \
    -e SUPERADMIN_JWT="${SUPERADMIN_JWT}" \
    identity-service \
    python3 /opt/libcloud-scripts/scripts/verify_superadmin_jwt.py >/dev/null \
  || { echo "FATAL: superadmin JWT verification failed — tenant creation denied." >&2; exit 3; }

# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh" >/dev/null 2>&1 || {
  echo "FATAL: cannot source scripts/common.sh — run ./setup.sh first." >&2; exit 2
}

# ---- 2. passwords (env or generated) --------------------------------------
_pw_env_key() { echo "LIBCLOUD_PASSWORD_$(echo "$1" | tr '[:lower:]-' '[:upper:]_')_$2"; }
gen_pw() { python3 -c "import secrets; print('PW-'+secrets.token_urlsafe(18))"; }

owner_key=$(  _pw_env_key "${TENANT}" OWNER  )
admin_key=$(  _pw_env_key "${TENANT}" ADMIN  )
viewer_key=$( _pw_env_key "${TENANT}" VIEWER )
OWNER_PW="${!owner_key:-$(gen_pw)}";   export "${owner_key}=${OWNER_PW}"
ADMIN_PW="${!admin_key:-$(gen_pw)}";   export "${admin_key}=${ADMIN_PW}"
VIEWER_PW="${!viewer_key:-$(gen_pw)}"; export "${viewer_key}=${VIEWER_PW}"

# ---- 3. LLDAP users -------------------------------------------------------
LLDAP_UID_OWNER="${TENANT}-owner"
LLDAP_UID_ADMIN="${TENANT}-admin"
LLDAP_UID_VIEWER="${TENANT}-viewer"
EMAIL_DOMAIN="libcloud.local"

ensure_user() {
  docker compose -f "${LLDAP_DIR}/docker-compose.yml" run --rm lldap-tools \
    /scripts/lldap_ensure_user.sh "$@"
}

echo "Creating LLDAP users for tenant:${TENANT} ..." >&2
CLOUD_TITLE="$(echo "${CLOUD}" | sed 's/^./\U&/')"
ensure_user "${LLDAP_UID_OWNER}"  "${LLDAP_UID_OWNER}@${EMAIL_DOMAIN}"  "${TENANT} owner"  "${TENANT}" owner  "${TENANT} owner"  "${OWNER_PW}"  >/dev/null
ensure_user "${LLDAP_UID_ADMIN}"  "${LLDAP_UID_ADMIN}@${EMAIL_DOMAIN}"  "${TENANT} admin"  "${TENANT}" admin  "${TENANT} admin"  "${ADMIN_PW}"  >/dev/null
ensure_user "${LLDAP_UID_VIEWER}" "${LLDAP_UID_VIEWER}@${EMAIL_DOMAIN}" "${TENANT} viewer" "${TENANT}" viewer "${TENANT} viewer" "${VIEWER_PW}" >/dev/null

# Persist passwords into generated/dex.env so host scripts can log in.
DEX_ENV="${REPO_ROOT}/test_script/generated/dex.env"
{
  echo ""
  echo "# Added by create_tenant.sh for tenant:${TENANT}"
  echo "LIBCLOUD_USER_${TENANT//-/_}_OWNER=${LLDAP_UID_OWNER}"
  echo "$(  _pw_env_key "${TENANT}" OWNER  )=${OWNER_PW}"
  echo "LIBCLOUD_USER_${TENANT//-/_}_ADMIN=${LLDAP_UID_ADMIN}"
  echo "$(  _pw_env_key "${TENANT}" ADMIN  )=${ADMIN_PW}"
  echo "LIBCLOUD_USER_${TENANT//-/_}_VIEWER=${LLDAP_UID_VIEWER}"
  echo "$( _pw_env_key "${TENANT}" VIEWER )=${VIEWER_PW}"
} >> "${DEX_ENV}"

# ---- 4. OpenFGA tuples ----------------------------------------------------
BACKEND_OBJECT="${BACKEND_TYPE}:${TENANT}"
PROVIDER_OBJECT="provider:${CLOUD}"

write_tuple() {
  local user="$1" rel="$2" obj="$3"
  local -a hdrs=(-H "Content-Type: application/json")
  if [[ -n "${SUPERADMIN_JWT:-}" ]]; then
    hdrs+=(-H "Authorization: Bearer ${SUPERADMIN_JWT}")
  fi
  curl -fsS -X POST "${FGA_API_URL}/stores/${FGA_STORE_ID}/write" \
    "${hdrs[@]}" \
    -d "$(python3 -c "
import json, os
print(json.dumps({
  'authorization_model_id': os.environ['FGA_MODEL_ID'],
  'writes': {'tuple_keys': [{'user':'${user}','relation':'${rel}','object':'${obj}'}]},
}))
")" >/dev/null
}

echo "Writing OpenFGA tuples for tenant:${TENANT} ..." >&2
write_tuple "user:superadmin"        owner   "tenant:${TENANT}"
write_tuple "user:${LLDAP_UID_OWNER}" owner   "tenant:${TENANT}"
write_tuple "user:${LLDAP_UID_ADMIN}" admin   "tenant:${TENANT}"
write_tuple "user:${LLDAP_UID_VIEWER}" viewer "tenant:${TENANT}"
write_tuple "tenant:${TENANT}"        parent  "libcloud_api:main"
write_tuple "tenant:${TENANT}"        parent  "${PROVIDER_OBJECT}"
write_tuple "${PROVIDER_OBJECT}"      provider "${BACKEND_OBJECT}"
write_tuple "tenant:${TENANT}"        tenant   "${BACKEND_OBJECT}"
# Per-tenant Vault identity mapping (tenant -> vault_user). The matching
# AppRole role/policy/secret_id is created by vault_tenant_role.py below.
write_tuple "tenant:${TENANT}"        parent  "vault_user:libcloud-${TENANT}"

# ---- 5. Vault AppRole identity (the tenant's per-tenant "vault user") ------
# Non-fatal: a failure here leaves LLDAP + OpenFGA intact; retry manually.
echo "Creating Vault AppRole identity for tenant:${TENANT} ..." >&2
if TENANT="${TENANT}" python3 "${SCRIPT_DIR}/vault_tenant_role.py"; then
  echo "Vault AppRole identity created for tenant:${TENANT}."
else
  echo "WARNING: Vault AppRole creation failed for tenant:${TENANT}." >&2
  echo "  Retry manually:" >&2
  echo "    TENANT=${TENANT} python3 test_script/scripts/vault_tenant_role.py" >&2
fi

echo
echo "Tenant created: tenant:${TENANT} (cloud=${CLOUD}, binding=${TENANT})"
echo "  backend object : ${BACKEND_OBJECT}"
echo "  Vault path     : secret/libcloud/${TENANT}"
echo "  owner          : ${LLDAP_UID_OWNER}  / ${OWNER_PW}"
echo "  admin          : ${LLDAP_UID_ADMIN}  / ${ADMIN_PW}"
echo "  viewer         : ${LLDAP_UID_VIEWER} / ${VIEWER_PW}"
echo
echo "Set this tenant's backend credentials (owner only):"
echo "  TENANT=${TENANT} CLOUD=${CLOUD} LIBCLOUD_USER=${LLDAP_UID_OWNER} LIBCLOUD_PASSWORD='${OWNER_PW}' \\"
if [[ "${CLOUD}" == "aws" ]]; then
  echo "    LIBCLOUD_AWS_KEY=AKIA... LIBCLOUD_AWS_SECRET=... \\"
else
  echo "    LIBCLOUD_NTNX_USER=... LIBCLOUD_NTNX_PASSWORD=... \\"
fi
echo "    python3 scripts/set_tenant_credentials.py"
echo
echo "Provision against this tenant:"
if [[ "${CLOUD}" == "aws" ]]; then
  echo "  LIBCLOUD_AWS_AUTH_BINDING=${TENANT} LIBCLOUD_USER=${LLDAP_UID_ADMIN} ./scripts/provision_aws.sh"
else
  echo "  LIBCLOUD_NTNX_AUTH_BINDING=${TENANT} LIBCLOUD_USER=${LLDAP_UID_ADMIN} ./scripts/provision_nutanix.sh"
fi
