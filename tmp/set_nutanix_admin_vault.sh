
 # If missing, seed it. First get the ntnx-owner password from dex.env:
  source dex/generated/dex.env
  echo "ntnx-owner password: $LIBCLOUD_PASSWORD_NTNX_OWNER"

  # Then seed (set real values for your Nutanix Prism Central):
  TENANT=nutanix CLOUD=nutanix \
    LIBCLOUD_USER=ntnx-owner \
    LIBCLOUD_PASSWORD="$LIBCLOUD_PASSWORD_NTNX_OWNER" \
    LIBCLOUD_NTNX_USER=admin \
    LIBCLOUD_NTNX_PASSWORD=admin \
    python3 test_script/scripts/set_tenant_credentials.py

    ###NTNX_HOST="${NUTANIX_HOST:-host.docker.internal}" \
