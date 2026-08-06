list="libcloud_nutanix/.env \
libcloud_nutanix/dex/config.yaml \
libcloud_nutanix/dex/generated/dex.env \
libcloud_nutanix/generated/tokens/superadmin.json \
libcloud_nutanix/generated/tokens/superadmin.jwt \
libcloud_nutanix/identity_service/.env \
libcloud_nutanix/libcloud.rest/.env \
libcloud_nutanix/openfga_postgres/generated/fga.env \
libcloud_nutanix/openfga_visualized/.env \
libcloud_nutanix/server/.env \
libcloud_nutanix/vault/generated/vault.env"

tar cvfz /tmp/env.tgz $list

