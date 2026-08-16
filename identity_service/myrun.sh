

#  cd $REPO_ROOT/identity_service
  # Path 1 (auth hardening) — 13 checks
  ./verify_auth.sh
  # Path 2 (provision replay) — provisions a real VM, then tears it down
  ./verify_provision.sh                       # AWS, provision + teardown
  CLOUD=nutanix ./verify_provision.sh         # Nutanix
  TEARDOWN=0 ./verify_provision.sh             # keep the VM
  BASE_URL=http://\$PUBLIC_HOSTNAME:8766 ./verify_provision.sh




    Verification (live AWS)

  ./verify_provision.sh provisioned a real EC2 instance end-to-end:
  • i-06e87d1677941cf61, t3.micro, Canonical Ubuntu AMI ami-02ccf827dc8b9f27d, ap-southeast-1, private IP 10.99.1.53
  • all 11 replay steps 200 OK, then torn down (200, destroyed:true)

  Path 1 verification re-run: 13/13 pass (no regressions).

  How to test it yourself

  cd $REPO_ROOT/identity_service
  # Path 1 (auth hardening) — 13 checks
  ./verify_auth.sh
  # Path 2 (provision replay) — provisions a real VM, then tears it down
  ./verify_provision.sh                       # AWS, provision + teardown
  CLOUD=nutanix ./verify_provision.sh         # Nutanix
  TEARDOWN=0 ./verify_provision.sh             # keep the VM
  BASE_URL=http://\$PUBLIC_HOSTNAME:8766 ./verify_provision.sh

