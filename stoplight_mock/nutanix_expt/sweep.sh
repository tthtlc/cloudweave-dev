USERNAME="admin"
PASSWORD="admin"
USERNAME="cy-user01"
PASSWORD="P@ssw0rd"
mkdir /tmp/tmp.y7sq9Y20t8

###── api_version=v4.0 — read-only sweep (auth in force: basic) ──
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/vmm/v4.0/ahv/config/vms
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/networking/v4.0/config/subnets
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/prism/v4.0/config/tasks
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/microseg/v4.0/config/policies
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/networking/v4.0/config/vpcs
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/networking/v4.0/config/floating-ips
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/volumes/v4.0/config/volume-groups
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/dataprotection/v4.0/config/recovery-points

###── api_version=v4.1 — read-only sweep (auth in force: basic) ──
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/vmm/v4.1/ahv/config/vms
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/networking/v4.1/config/subnets
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/prism/v4.1/config/tasks
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/microseg/v4.1/config/policies
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/networking/v4.1/config/vpcs
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/networking/v4.1/config/floating-ips
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/volumes/v4.1/config/volume-groups
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/dataprotection/v4.1/config/recovery-points

###── api_version=v4.2 — read-only sweep (auth in force: basic) ──
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/vmm/v4.2/ahv/config/vms
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/networking/v4.2/config/subnets
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/prism/v4.2/config/tasks
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/microseg/v4.2/config/policies
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/networking/v4.2/config/vpcs
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/networking/v4.2/config/floating-ips
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/volumes/v4.2/config/volume-groups
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/dataprotection/v4.2/config/recovery-points

##── api_version=v4.3 — read-only sweep (auth in force: basic) ──
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/vmm/v4.3/ahv/config/vms
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/networking/v4.3/config/subnets
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/prism/v4.3/config/tasks
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/microseg/v4.3/config/policies
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/networking/v4.3/config/vpcs
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/networking/v4.3/config/floating-ips
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/volumes/v4.3/config/volume-groups
curl -sS -o /tmp/tmp.y7sq9Y20t8/body$$ -D /tmp/tmp.y7sq9Y20t8/rsphdr$$ -w %\{http_code\} -v -X GET -H Accept:\ application/json -k -u ${USERNAME}:${PASSWORD}  https://166.6.100.1:9440/api/dataprotection/v4.3/config/recovery-points
