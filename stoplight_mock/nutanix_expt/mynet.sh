vms="https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/vmm/${api_version}/ahv/config/vms"




##subnets="https://166.6.100.1:9440/api/networking/v4.2/config/subnets"
##vpcs="https://166.6.100.1:9440/api/networking/v4.2/config/vpcs"
##floatingips="https://166.6.100.1:9440/api/networking/v4.2/config/floating-ips"
securitygroups="https://166.6.100.1:9440/api/microseg/v4.2/config/policies"
volumegroups="https://166.6.100.1:9440/api/volumes/v4.2/config/volume-groups"
recoverypoints="https://166.6.100.1:9440/api/dataprotection/v4.2/config/recovery-points"
tasks="https://166.6.100.1:9440/api/prism/v4.2/config/tasks"


             "message": "Failed to list subnets as the access is denied - Application error kAccessDeniedError raised: User denied access to get resource",
    body: {"data":{"error":[{"$reserved":{"$fv":"v4.r3"},"$objectType":"networking.v4.error.AppMessage","message":"Failed to list subnets as the access is denied - Application error kAccessDeniedError raised: User denied access to get resource","severity":"ERROR","code":"NETWORKING-10071","locale":"en_US"}],"
              "message": "Failed to list VPCs as the access is denied - Application error kAccessDeniedError raised: User denied access to get resource",
    body: {"data":{"error":[{"$reserved":{"$fv":"v4.r3"},"$objectType":"networking.v4.error.AppMessage","message":"Failed to list VPCs as the access is denied - Application error kAccessDeniedError raised: User denied access to get resource","severity":"ERROR","code":"NETWORKING-10071","locale":"en_US"}],"$re
              "message": "Failed to list floating IPs as the access is denied - Application error kAccessDeniedError raised: User denied access to get resource",
    body: {"data":{"error":[{"$reserved":{"$fv":"v4.r3"},"$objectType":"networking.v4.error.AppMessage","message":"Failed to list floating IPs as the access is denied - Application error kAccessDeniedError raised: User denied access to get resource","severity":"ERROR","code":"NETWORKING-10071","locale":"en_US
              "message": "Failed to authorize the request due to Access Denied because no or incorrect permissions were set in the request http://166.6.100.4/api/clustermgmt/v4.0/config/storage-containers",
    body: {"data":{"error":[{"message":"Failed to authorize the request due to Access Denied because no or incorrect permissions were set in the request http://166.6.100.4/api/clustermgmt/v4.0/config/storage-containers","code":"PLAT-10007","locale":"en_US","errorGroup":"RBAC_AUTHORIZATION_ERROR","severity":"E
            "accessibleClients": [
            "accessibleClients

#real-host mode is read-only (166.6.100.1:9440) — skipping the mutating write suite.

##curl --url 'https://166.6.100.1:9440/api/networking/v4.1/config/subnets' \
#curl --url 'https://166.6.100.1:9440/api/networking/v4.0/config/subnets' \


myfun(){

curl --url "$1" \
  -H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7' \
  -H 'accept-language: en-US,en;q=0.9' \
  -H 'cache-control: no-cache' \
  -b 'NTNX_SESSION_META=invalid; X-Nutanix-Client-Type=ui; iam-sessionid=ceee3d49-d9e1-54a2-8e82-22645fd1814d; NTNX_MERCURY_IAM_REFRESH_TOKEN="Chl4Yzd5eXk2dDQzcHh6cGl1a2JsNWJka3ByEhlpNnBqZW43YXIzczczNGp3Z2J1ZHlzNnY0"; NTNX_IAM_SESSION=ChFjeS11c2VyMDFAdGNjLmNvbRDMp6DUBhoHTWVyY3VyeSAAKigwOTg4ZGY3ZGFhODJlZDYzZDNlNGI4MGI1YjVmYmY0NDBkYWQ0ZTYx|JJhiXG2Deo8Vy1udtFwKgZBs+GyFxtpvf/3+tj2EA7A=; NTNX_MERCURY_IAM_SESSION=ChFjeS11c2VyMDFAdGNjLmNvbRDMp6DUBhoHTWVyY3VyeSAAKigwOTg4ZGY3ZGFhODJlZDYzZDNlNGI4MGI1YjVmYmY0NDBkYWQ0ZTYx|JJhiXG2Deo8Vy1udtFwKgZBs+GyFxtpvf/3+tj2EA7A=' \
  -H 'pragma: no-cache' \
  -H 'priority: u=0, i' \
  -H 'sec-ch-ua: "Not=A?Brand";v="99", "Microsoft Edge";v="151", "Chromium";v="151"' \
  -H 'sec-ch-ua-mobile: ?0' \
  -H 'sec-ch-ua-platform: "Windows"' \
  -H 'sec-fetch-dest: document' \
  -H 'sec-fetch-mode: navigate' \
  -H 'sec-fetch-site: none' \
  -H 'sec-fetch-user: ?1' \
  -H 'upgrade-insecure-requests: 1' \
  -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0' \
  --insecure

}

myfun $vms > vms.outout
myfun $subnets > subnets.outout
myfun $vpcs > vpcs.outout
myfun $floatingips > floatingips.outout
myfun $securitygroups > securitygroups.outout
myfun $volumegroups > volumegroups.outout
myfun $recoverypoints > recoverypoints.outout
myfun $tasks > tasks.outout
