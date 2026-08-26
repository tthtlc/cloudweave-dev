using these script as example:

nutanix_expt/expt_read.sh  nutanix_expt/expt_write.sh scripts/test_read.sh  scripts/test_write.sh

implement a new script for the following URL (read only operation) using the following pattern (NUTANIX_HOST, NUTANIX_PORT, and api_version are specified at the top of the script):

vms="https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/vmm/${api_version}/ahv/config/vms"
subnets="https://166.6.100.1:9440/api/networking/v4.2/config/subnets"
tasks="https://166.6.100.1:9440/api/prism/v4.2/config/tasks"
securitygroups="https://166.6.100.1:9440/api/microseg/v4.2/config/policies"

vpcs="https://166.6.100.1:9440/api/networking/v4.2/config/vpcs"
floatingips="https://166.6.100.1:9440/api/networking/v4.2/config/floating-ips"
volumegroups="https://166.6.100.1:9440/api/volumes/v4.2/config/volume-groups"
recoverypoints="https://166.6.100.1:9440/api/dataprotection/v4.2/config/recovery-points"

run the script in two input mode:   auth=cookie or auth=basic.

when auth=basic, the USERNAME and PASSWORD are used to form the basic auth, which is being sent in ALL URL.   
when auth=cookie, the USERNAME and PASSWORD are used to form the basic auth, and the cookie derived in the first authentication, and then the cookie will be reuse to form the header for all the URL request, and thus ths basic authentication header will not be used anymore.

There should be a verbose or non-verbose mode:   in verbose mode, we should be able to see the detail header and body for the HTTP request and response and non-verbose only the URL and the HTTP response is needed.

for api_version, it should run through from v4.0 to v4.3.

similarly implement another new script for the read/write URL using the same pattern like below:

nutanix_expt/expt_read.sh  nutanix_expt/expt_write.sh scripts/test_read.sh  scripts/test_write.sh
