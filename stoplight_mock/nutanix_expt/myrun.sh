USER="cy-user01"
PASSWORD="P@ssw0rd"
USER="admin"
PASSWORD="admin"
NUTANIX_HOST="rocky96"

./sweep_read.sh auth=basic --username admin --password secret --username $USER --password $PASSWORD --dry-run 
exit
#./sweep_read.sh auth=cookie
#./sweep_read.sh auth=basic verbose=1

./sweep_read.sh auth=basic api_version=v4.2 --ip $NUTANIX_HOST --port 9442  --username $USER --password ${PASSWORD} --verbose
exit
./sweep_read.sh auth=cookie api_version=v4.1 --ip $NUTANIX_HOST --port 9441 --username $USER --password ${PASSWORD} --verbose
./sweep_read.sh auth=cookie api_version=v4.2 --ip $NUTANIX_HOST --port 9442 --username $USER --password ${PASSWORD} --verbose
./sweep_read.sh auth=cookie api_version=v4.3 --ip $NUTANIX_HOST --port 9443 --username $USER --password ${PASSWORD} --verbose

exit
./sweep_read.sh auth=cookie api_version=v4.2 --ip 166.6.100.1 --port 9440




./expt_read.sh --ip rocky96 --port 9440 --api-version v4.0 --username admin --password admin --insecure --verbose
./expt_read.sh --ip rocky96 --port 9440 --api-version v4.1 --username admin --password admin --insecure --verbose
./expt_read.sh --ip rocky96 --port 9440 --api-version v4.2 --username admin --password admin --insecure --verbose
./expt_read.sh --ip rocky96 --port 9440 --api-version v4.3 --username admin --password admin --insecure --verbose

exit

./expt_read.sh --ip rocky96 --username admin --password admin --insecure --verbose
exit
#./iam_v4.0_curl.sh                      # list all endpoints
./iam_v4.1_curl.sh
exit

./iam_v4.0_curl.sh listUsers '$page=0' '$filter=userType eq "LOCAL"'
exit
#./iam_v4.0_curl.sh all-readonly         # run every GET
./list_vms_curl.sh                      # lists VMs via cookie auth
CURL_DRY_RUN=1 ./iam_v4.0_curl.sh listUsers   # show the exact curl command





  490  bash expt_read.sh --ip rocky96 --username admin --password admin --insecure --verbose
  491  bash expt_read.sh --ip rocky96 --username admin --password admin --insecure --verbose > /tmp/abc
  492  bash expt_read.sh --ip rocky96 --username admin --password admin --insecure --verbose > /tmp/abc2
  493  bash expt_read.sh --ip rocky96 --username admin --password admin --insecure --verbose 2> /tmp/abc2
  494  bash expt_read.sh --ip rocky96 --username admin --password admin --insecure --verbose 1>&2 2> /tmp/abc2 
  495  bash expt_read.sh --ip rocky96 --username admin --password admin --insecure --verbose  2> /tmp/abc2 1>&2
  496  vi /tmp/abc2 



