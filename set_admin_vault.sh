
source dex/generated/dex.env
source tenant_vault_secret.env

#    TENANT=nutanix \
#    LIBCLOUD_USER=ntnx-owner \
#    LIBCLOUD_PASSWORD='SA-Z_E2w5MNW50QferJKy2Okikw' \
#    LIBCLOUD_NTNX_USER='admin' \
#    LIBCLOUD_NTNX_PASSWORD='admin' \
#    python3 test_script/scripts/set_tenant_credentials.py


LIBCLOUD_OIDC_CLIENT_SECRET=${LIBCLOUD_OIDC_CLIENT_SECRET} TENANT=aws LIBCLOUD_USER=aws-owner LIBCLOUD_PASSWORD=$LIBCLOUD_PASSWORD_AWS_OWNER \
    LIBCLOUD_AWS_KEY=${AWS_ACCESS_KEY} LIBCLOUD_AWS_SECRET=${AWS_SECRET_ACCESS_KEY} \
    python3 test_script/scripts/set_tenant_credentials.py

LIBCLOUD_OIDC_CLIENT_SECRET=${LIBCLOUD_OIDC_CLIENT_SECRET} TENANT=nutanix LIBCLOUD_USER=ntnx-owner LIBCLOUD_PASSWORD=$LIBCLOUD_PASSWORD_NTNX_OWNER \
    LIBCLOUD_NTNX_USER=admin LIBCLOUD_NTNX_PASSWORD=admin \
    python3 test_script/scripts/set_tenant_credentials.py
##superadmin (owner on both tenants) can set them too.

##
##echo "Cloud backend credentials are seeded into Vault from the root .env"
##echo "(LIBCLOUD_AWS_KEY/SECRET, LIBCLOUD_NTNX_USER/PASSWORD). If a value is"
##echo "empty, that tenant is skipped — the owner can seed it later manually:"
##echo "  TENANT=aws LIBCLOUD_USER=aws-owner LIBCLOUD_PASSWORD=\$LIBCLOUD_PASSWORD_AWS_OWNER \\"
##echo "    LIBCLOUD_AWS_KEY=AKIA... LIBCLOUD_AWS_SECRET=... \\"
##echo "    python3 ${SCRIPTS_REL}/set_tenant_credentials.py"
##echo "  TENANT=nutanix LIBCLOUD_USER=ntnx-owner LIBCLOUD_PASSWORD=\$LIBCLOUD_PASSWORD_NTNX_OWNER \\"
##echo "    LIBCLOUD_NTNX_USER=admin LIBCLOUD_NTNX_PASSWORD=... \\"
##echo "    python3 ${SCRIPTS_REL}/set_tenant_credentials.py"
##echo "superadmin (owner on both tenants) can set them too."
##
##
##
##    ###NTNX_HOST="${NUTANIX_HOST:-host.docker.internal}" \
