
  # 1. Check OpenFGA store/model IDs match what identity service uses
  cat openfga_postgres/generated/fga.env | grep -E 'FGA_STORE_ID|FGA_MODEL_ID'

  # 2. Can identity service reach OpenFGA?
  curl -s http://localhost:8080/health

  # 3. Check a tuple directly via OpenFGA API to see if aws-owner's membership exists:
  STORE_ID=$(grep FGA_STORE_ID openfga_postgres/generated/fga.env | cut -d= -f2)
  curl -s -X POST "http://localhost:8080/stores/${STORE_ID}/read" \
    -H 'Content-Type: application/json' \
    -d '{"tuple_key":{"user":"user:aws-owner"}}' | python3 -m json.tool


