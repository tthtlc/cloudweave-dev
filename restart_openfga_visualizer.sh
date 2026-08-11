 cd /home/ubuntu/libcloud_nutanix/openfga_visualized
  docker compose down
  docker compose build --no-cache
  docker compose up -d
  docker logs openfga-visualizer
