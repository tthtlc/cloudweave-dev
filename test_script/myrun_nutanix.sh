SCRIPT_FILE=$1

#  ntnx-owner   / SA-9HXuDFerBkabyaDw2tG-t7O-   (owner  of tenant:nutanix)
LIBCLOUD_PASSWORD_NTNX_OWNER="SA-9HXuDFerBkabyaDw2tG-t7O-"
#  ntnx-admin   / SA-4ckgB21zNYj4B_cRlh2BFQp-   (admin  of tenant:nutanix -> provision Nutanix)
#  ntnx-viewer  / SA-OZlrfS1FP9wP_-Vglx30-n3R  (viewer of tenant:nutanix -> enumerate only)
##LIBCLOUD_OIDC_CLIENT_SECRET="AUS9xB87FmlkqmvtMhrT2Cyp9CRgMXBhfIICDU8jtwc" TENANT=nutanix LIBCLOUD_USER=ntnx-owner LIBCLOUD_PASSWORD=$LIBCLOUD_PASSWORD_NTNX_OWNER

LIBCLOUD_OIDC_CLIENT_SECRET="HbpzexeVfU0STxDY9f14Td3-T2OfmhTsJIFwXxQrFVs" VERBOSE=1 TENANT=nutanix LIBCLOUD_USER=ntnx-owner LIBCLOUD_PASSWORD=$LIBCLOUD_PASSWORD_NTNX_OWNER \
    LIBCLOUD_NTNX_USER=admin LIBCLOUD_NTNX_PASSWORD=admin \
    python3 scripts/set_tenant_credentials.py

###superadmin (owner on both tenants) can set them too.

  TENANT=nutanix CLOUD_PROVIDER=nutanix LIBCLOUD_USER=ntnx-admin  PROVISION=1 VERBOSE=1 "${SCRIPT_FILE}"
  #TENANT=nutanix CLOUD_PROVIDER=nutanix LIBCLOUD_USER=ntnx-viewer VERBOSE=1 "${SCRIPT_FILE}"
  #TENANT=nutanix CLOUD_PROVIDER=nutanix LIBCLOUD_USER=ntnx-admin  PROVISION=1 VERBOSE=1 ./scripts/deprovision_nutanix.sh
  #LIBCLOUD_NTNX_AUTH_BINDING=nutanix-dev LIBCLOUD_USER=ntnx-dev-admin ./scripts/deprovision_nutanix.sh
  #VM_NAME=libcloud-ntnx-1234567890 LIBCLOUD_USER=ntnx-admin ./scripts/deprovision_nutanix.sh

exit


