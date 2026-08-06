#
#
#● Bash(docker inspect stoplight_mock-emulator-1 --format '{{json .NetworkSettings.Ports}}' 2>/dev/null | python3 -m json.tool)
#  ⎿  {
#         "9440/tcp": [
#             {
#     … +5 lines (ctrl+o to expand)
#  ⎿  Allowed by auto mode classifier
#
#  Thought for 19s, read 1 file (ctrl+o to expand)
#
#● The mock emulator binds to 127.0.0.1:9440 — only localhost connections work. The libcloud REST API container comes through the Docker gateway (not loopback), so the connection is refused.
#     
#  Fix it by binding to all interfaces:
#
#● Update(~/libcloud_nutanix/stoplight_mock/docker-compose.yml)
#  ⎿  Added 1 line, removed 1 line
#      13    emulator:
#      14      build: ./mock
#      15      ports:
#      16 -      - "127.0.0.1:9440:9440"                                                                                                                                                                
#      16 +      - "0.0.0.0:9440:9440"                                                                                                                                                                  
#      17      environment:
#      18        - PRISM_URL=http://prism:4010
#      19      depends_on:
#
#  Thought for 3s (ctrl+o to expand)
#
#● Now restart the mock emulator:
#
cd /home/ubuntu/libcloud_nutanix/stoplight_mock && docker compose up -d --force-recreate emulator
#
#  Then verify the REST API can reach it:
#
docker exec libcloud-rest-api python3 -c "import requests; r = requests.get('https://host.docker.internal:9440/api/vmm/v4.0/ahv/config/vms', verify=False); print(r.status_code)"
#
#  The problem was: 127.0.0.1:9440:9440 only accepted connections from the host's loopback interface. The libcloud REST API container reaches the host via the Docker gateway (not 127.0.0.1), so it was
#  blocked. 0.0.0.0:9440:9440 accepts connections from all interfaces including the Docker gateway.
#
#✻ Baked for 1m 14s
#
