docker exec libcloud-rest-api env 2>/dev/null | grep VAULT || echo "Container not running or no grep match"
