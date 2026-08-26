USERNAME="cy-user01"
PASSWORD="P@ssw0rd"
USERNAME="admin"
PASSWORD="admin"
NUTANIX_HOST="166.6.100.1"
NUTANIX_HOST="rocky96"
NUTANIX_PORT=9442
mkdir /tmp/tmp.y7sq9Y20t8

###── api_version=v4.0 — read-only sweep (auth in force: basic) ──
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/vmm/v4.0/ahv/config/vms; COUNTER=`expr $COUNTER + 1`
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/networking/v4.0/config/subnets; COUNTER=`expr $COUNTER + 1`
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/prism/v4.0/config/tasks; COUNTER=`expr $COUNTER + 1`
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/microseg/v4.0/config/policies; COUNTER=`expr $COUNTER + 1`
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/networking/v4.0/config/vpcs; COUNTER=`expr $COUNTER + 1`
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/networking/v4.0/config/floating-ips; COUNTER=`expr $COUNTER + 1`
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/volumes/v4.0/config/volume-groups; COUNTER=`expr $COUNTER + 1`
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/dataprotection/v4.0/config/recovery-points; COUNTER=`expr $COUNTER + 1`
#
####── api_version=v4.1 — read-only sweep (auth in force: basic) ──
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/vmm/v4.1/ahv/config/vms; COUNTER=`expr $COUNTER + 1`
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/networking/v4.1/config/subnets; COUNTER=`expr $COUNTER + 1`
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/prism/v4.1/config/tasks; COUNTER=`expr $COUNTER + 1`
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/microseg/v4.1/config/policies; COUNTER=`expr $COUNTER + 1`
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/networking/v4.1/config/vpcs; COUNTER=`expr $COUNTER + 1`
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/networking/v4.1/config/floating-ips; COUNTER=`expr $COUNTER + 1`
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/volumes/v4.1/config/volume-groups; COUNTER=`expr $COUNTER + 1`
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/dataprotection/v4.1/config/recovery-points; COUNTER=`expr $COUNTER + 1`

###── api_version=v4.2 — read-only sweep (auth in force: basic) ──
curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER}$ -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER}$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/vmm/v4.2/ahv/config/vms; COUNTER=`expr $COUNTER + 1`
curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER}$ -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER}$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/networking/v4.2/config/subnets; COUNTER=`expr $COUNTER + 1`
curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER}$ -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER}$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/prism/v4.2/config/tasks; COUNTER=`expr $COUNTER + 1`
curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER}$ -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER}$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/microseg/v4.2/config/policies; COUNTER=`expr $COUNTER + 1`
curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER}$ -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER}$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/networking/v4.2/config/vpcs; COUNTER=`expr $COUNTER + 1`
curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER}$ -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER}$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/networking/v4.2/config/floating-ips; COUNTER=`expr $COUNTER + 1`
curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER}$ -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER}$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/volumes/v4.2/config/volume-groups; COUNTER=`expr $COUNTER + 1`
curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER}$ -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER}$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/dataprotection/v4.2/config/recovery-points; COUNTER=`expr $COUNTER + 1`

##── api_version=v4.3 — read-only sweep (auth in force: basic) ──
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/vmm/v4.3/ahv/config/vms; COUNTER=`expr $COUNTER + 1`
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/networking/v4.3/config/subnets; COUNTER=`expr $COUNTER + 1`
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/prism/v4.3/config/tasks; COUNTER=`expr $COUNTER + 1`
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/microseg/v4.3/config/policies; COUNTER=`expr $COUNTER + 1`
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/networking/v4.3/config/vpcs; COUNTER=`expr $COUNTER + 1`
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/networking/v4.3/config/floating-ips; COUNTER=`expr $COUNTER + 1`
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/volumes/v4.3/config/volume-groups; COUNTER=`expr $COUNTER + 1`
#curl -sS -o /tmp/tmp.y7sq9Y20t8/body${COUNTER} -D /tmp/tmp.y7sq9Y20t8/rsphdr${COUNTER} -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/dataprotection/v4.3/config/recovery-points; COUNTER=`expr $COUNTER + 1`
