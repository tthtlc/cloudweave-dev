
#provision_nutanix.sh ####— the regular/bastion-side VM (also one VM, libcloud-ntnx-<timestamp>)
#provision_nutanix_private.sh ####— only the "internal server" part, as its header comment states: "Implements the 'internal server' part of nutanix_bastion_internal_server.md"
#provision_nutanix_bastion_private.sh ####— the FULL 2-VM scenario in one run (bastion host on vlan100-external + internal server on vlan200-internal); this is the script behind the portal's "Provision Private VM Machine" button (POST /api/provision-private/nutanix, Nutanix owner/admin only)

##./test_script/scripts/provision_nutanix.sh
##./test_script/scripts/provision_nutanix_private.sh
##./test_script/scripts/provision_nutanix_bastion_private.sh
./test_provision_xxx.sh
./test_provision_xxx_private.sh
