AWS_ACCESS_KEY=AKIAYHGEH2P7SNGEPLZH
AWS_SECRET_ACCESS_KEY=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
LIBCLOUD_PASSWORD_AWS_OWNER="SA-Jv07tZKzzFB85mKAL_rbphi_"  ##    (owner  of tenant:aws)
TENANT=aws LIBCLOUD_USER=aws-owner LIBCLOUD_PASSWORD=$LIBCLOUD_PASSWORD_AWS_OWNER VERBOSE=1 \
	LIBCLOUD_AWS_KEY=${AWS_ACCESS_KEY} LIBCLOUD_AWS_SECRET=${AWS_SECRET_ACCESS_KEY} \
    python3 scripts/set_tenant_credentials.py

  LIBCLOUD_USER=aws-viewer VERBOSE=1 PROVISION=1 ./scripts/provision_aws.sh
  LIBCLOUD_USER=aws-viewer VERBOSE=1 ./scripts/provision_aws.sh
  LIBCLOUD_USER=aws-viewer VERBOSE=1 ./scripts/deprovision_aws.sh


exit

  superadmin   / SA-alAKiKrUf5I1xhO9Ogwljwfk   (bootstrap: Vault/OpenFGA/LLDAP admin)
  aws-owner    / 
  aws-admin    / SA-YxB5zqiYyA8M0mscsjfOkuWd    (admin  of tenant:aws -> provision AWS)
  aws-viewer   / SA-SSxoqVYaKcnOLZX88Kkxe3AA   (viewer of tenant:aws -> enumerate only)
  ntnx-owner   / SA-9HXuDFerBkabyaDw2tG-t7O-   (owner  of tenant:nutanix)
  ntnx-admin   / SA-4ckgB21zNYj4B_cRlh2BFQp-   (admin  of tenant:nutanix -> provision Nutanix)
  ntnx-viewer  / SA-OZlrfS1FP9wP_-Vglx30-n3R  (viewer of tenant:nutanix -> enumerate only)
  cloud-denied / CloudDenied123! (authenticated but denied)

Cloud backend credentials are per-tenant and NOT set by setup.sh.
Each tenant's OWNER writes its credentials to Vault (gated by OpenFGA
can_manage_credentials; admins/viewers cannot):

  TENANT=nutanix LIBCLOUD_USER=ntnx-owner LIBCLOUD_PASSWORD=$LIBCLOUD_PASSWORD_NTNX_OWNER \
    LIBCLOUD_NTNX_USER=admin LIBCLOUD_NTNX_PASSWORD=... \
    python3 scripts/set_tenant_credentials.py
superadmin (owner on both tenants) can set them too.

Then run:
  LIBCLOUD_USER=aws-admin   ./scripts/provision_aws.sh
  LIBCLOUD_USER=aws-viewer  ./scripts/provision_aws.sh
  LIBCLOUD_USER=ntnx-admin  ./scripts/provision_nutanix.sh
  LIBCLOUD_USER=ntnx-viewer ./scripts/provision_nutanix.sh
