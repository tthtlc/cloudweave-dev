
# 50 VMs as the Nutanix tenant admin (default)
  N=50 LIBCLOUD_USER=ntnx-admin
  ./test_script/scripts/nutanix_lifecycle_benchmark.sh
  exit
  # As owner, custom prefix, leave VMs running
  N=50 LIBCLOUD_USER=ntnx-owner VM_NAME_PREFIX=libcloud-ntnx-bench \
      SKIP_DEPROVISION=1
  ./test_script/scripts/nutanix_lifecycle_benchmark.sh

