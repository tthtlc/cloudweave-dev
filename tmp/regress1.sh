set -x
  # 1. Check what the identity service actually sees
  docker exec identity-service env | grep -E 'FGA_STORE_ID|FGA_MODEL_ID|FGA_API_URL'

  # 2. Check if fga.env exists and has content
  cat openfga_postgres/generated/fga.env

  # 3. Check the bootstrap container logs
  docker logs openfga-bootstrap 2>&1 | tail -30

  # 4. Check identity-service logs for FGA discovery failures
  docker logs identity-service 2>&1 | grep -iE 'fga|discover|store.*not found'


  check_stale_fga.sh ### check

  docker compose -f identity_service/docker-compose.yml up -d --force-recreate identity-service

  get_admin_vault.sh
  set_admin_vault.sh

  recover_vault.sh


  ###restart stopmachine yourself
