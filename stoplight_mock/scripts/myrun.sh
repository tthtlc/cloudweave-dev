
#NUTANIX_HOST=rocky96 NUTANIX_PORT=9441 ./test_read.sh --version v4.1
NUTANIX_HOST=rocky96 NUTANIX_PORT=9440 ./test_read.sh --version v4.0 ##--verbose
NUTANIX_HOST=rocky96 NUTANIX_PORT=9441 ./test_read.sh --version v4.1 ##--verbose
NUTANIX_HOST=rocky96 NUTANIX_PORT=9442 ./test_read.sh --version v4.2 ##--verbose
NUTANIX_HOST=rocky96 NUTANIX_PORT=9443 ./test_read.sh --version v4.3 ##--verbose
exit
#
#
curl --url 'https://rocky96:9440/api/networking/v4.0/config/floating-ips' \
  -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7' \
  -H 'Accept-Language: en-US,en;q=0.9,ko;q=0.8,zh-CN;q=0.7,zh;q=0.6' \
  -H 'Cache-Control: max-age=0' \
  -H 'Connection: keep-alive' \
  -H 'Sec-Fetch-Dest: document' \
  -H 'Sec-Fetch-Mode: navigate' \
  -H 'Sec-Fetch-Site: none' \
  -H 'Sec-Fetch-User: ?1' \
  -H 'Upgrade-Insecure-Requests: 1' \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36' \
  -H 'sec-ch-ua: "Not=A?Brand";v="99", "Google Chrome";v="151", "Chromium";v="151"' \
  -H 'sec-ch-ua-mobile: ?0' \
  -H 'sec-ch-ua-platform: "Linux"' \
  --insecure
