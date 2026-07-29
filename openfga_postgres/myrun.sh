
### rebuild image
docker compose build openfga
docker compose up -d --force-recreate openfga-migrate openfga


