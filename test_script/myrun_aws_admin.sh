#!/usr/bin/bash
#
[ $# -ne 1 ]  && { echo "$0 <script_file>"; exit 0; }

SCRIPT_FILE=$1
AWS_ACCESS_KEY=AKIAYHGEH2P7SNGEPLZH
AWS_SECRET_ACCESS_KEY=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
LIBCLOUD_PASSWORD_AWS_OWNER="SA-Jv07tZKzzFB85mKAL_rbphi_"  ##    (owner  of tenant:aws)

LIBCLOUD_OIDC_CLIENT_SECRET="HbpzexeVfU0STxDY9f14Td3-T2OfmhTsJIFwXxQrFVs" \
TENANT=aws LIBCLOUD_USER=aws-owner LIBCLOUD_PASSWORD=$LIBCLOUD_PASSWORD_AWS_OWNER VERBOSE=1 \
	LIBCLOUD_AWS_KEY=${AWS_ACCESS_KEY} LIBCLOUD_AWS_SECRET=${AWS_SECRET_ACCESS_KEY} \
python3 scripts/set_tenant_credentials.py

TENANT=aws CLOUD_PROVIDER=aws LIBCLOUD_USER=aws-admin VERBOSE=1 PROVISION=1 ${SCRIPT_FILE}

#LIBCLOUD_USER=aws-admin VERBOSE=1 PROVISION=1 ${SCRIPT_FILE}
sleep 10
#LIBCLOUD_USER=aws-admin VERBOSE=1 ./scripts/deprovision_aws.sh


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



  set -a; source ../dex/generated/dex.env; set +a
  TENANT=aws CLOUD=aws \
    LIBCLOUD_USER=aws-owner LIBCLOUD_PASSWORD="${LIBCLOUD_PASSWORD_AWS_OWNER}" \
    LIBCLOUD_AWS_KEY="${AWS_ACCESS_KEY}" LIBCLOUD_AWS_SECRET="${AWS_SECRET_ACCESS_KEY}" \
    python3 scripts/set_tenant_credentials.py

  #TENANT=aws LIBCLOUD_USER=aws-owner \
  #  LIBCLOUD_AWS_KEY=$AWS_ACCESS_KEY LIBCLOUD_AWS_SECRET=$AWS_SECRET_ACCESS_KEY \
  #  python3 scripts/set_tenant_credentials.py

  LIBCLOUD_USER=aws-admin \
  PROVISION=1 TEARDOWN_VMS=1 \
  ./scripts/provision_aws.sh


  exit

  One caveat I flagged earlier still stands: with the current wiring, TEARDOWN_VMS=1 deletes only the VM created during this run (matched by exact VM_NAME). If you want it to delete all libcloud-demo-* VMs for the tenant (cleanup of prior runs), say so and I'll add a TEARDOWN_SCOPE=all option.




##LIBCLOUD_USER=aws-admin   ./scripts/provision_aws.sh

LIBCLOUD_USER=aws-admin \
  PROVISION=0 TEARDOWN_VMS=1 \
  ./scripts/provision_aws.sh


exit
LIBCLOUD_USER=aws-admin \
  LIBCLOUD_PASSWORD_AWS_ADMIN='AwsAdmin123!' \
  ALLOW_DEV_DEFAULTS=1 \
  PROVISION=1 \
  TEARDOWN_VMS=1 \
  ./scripts/provision_aws.sh


exit

  #./system_validate.sh                 # full suite (exit 0 = all pass)
  #ONLY=lldap ./system_validate.sh      # single section: infra|lldap|dex|oidc|provision
  VERBOSE=1 PROVISION_VMS=1 ./system_validate.sh   # surface HTTP bodies
  ##VERBOSE=1 ONLY=provision ./system_validate.sh
  exit
  VERBOSE=1 ONLY=oidc ./system_validate.sh
  VERBOSE=1 ONLY=dex ./system_validate.sh
  VERBOSE=1 ONLY=lldap ./system_validate.sh
  VERBOSE=1 ONLY=infra ./system_validate.sh
  #ONLY=lldap ./system_validate.sh      # single section: infra|lldap|dex|oidc|provision
  #ONLY=lldap ./system_validate.sh      # single section: infra|lldap|dex|oidc|provision #VERBOSE=1 ./system_validate.sh       # show captured command output on failures

  # Dry-run (default, no VMs created):
  ./system_validate.sh
  # Actually provision VMs in AWS + Nutanix:
  PROVISION_VMS=1 ./system_validate.sh
  VERBOSE=1 PROVISION_VMS=1 ./system_validate.sh   # surface HTTP bodies
  ONLY=provision PROVISION_VMS=1 ./system_validate.sh

  You can still override individual catalog choices with the same env vars the scripts already accept, e.g. AWS_REGION=..., AWS_INSTANCE_ARCH=arm64,
  IMAGE_ID=..., SIZE_ID=..., SUBNET_ID=..., CLUSTER_ID=..., VM_NAME=....


  exit
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

export FGA_API_URL="${FGA_API_URL:-http://localhost:8080}"
export FGA_STORE_NAME="${FGA_STORE_NAME:-libcloud-rest-store}"
export FGA_LOG_LEVEL="${FGA_LOG_LEVEL:-DEBUG}"

python3 openfga_bootstrap.py
