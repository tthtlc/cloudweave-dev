### check nutanix credentials in vault

  # First, check what's in Vault:
  docker exec vault vault kv get secret/libcloud/nutanix 2>&1 || echo "No nutanix secret found"

  exit

  # If missing, seed it. First get the ntnx-owner password from dex.env:
  source dex/generated/dex.env
  echo "ntnx-owner password: $LIBCLOUD_PASSWORD_NTNX_OWNER"

  # Then seed (set real values for your Nutanix Prism Central):
  TENANT=nutanix CLOUD=nutanix \
    LIBCLOUD_USER=ntnx-owner \
    LIBCLOUD_PASSWORD="$LIBCLOUD_PASSWORD_NTNX_OWNER" \
    LIBCLOUD_NTNX_USER=admin \
    LIBCLOUD_NTNX_PASSWORD='<your-prism-password>' \
    python3 test_script/scripts/set_tenant_credentials.py



