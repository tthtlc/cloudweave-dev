cd server/
docker compose down
cd ..
cd openfga_visualized/
docker compose down
cd ..
cd stoplight_mock/
docker compose down
cd ..
cd libcloud.rest/
docker compose -f ./docker-compose.swagger.yml down
cd ..
docker ps
