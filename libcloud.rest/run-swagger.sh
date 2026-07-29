#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run-swagger.sh — Regenerate the OpenAPI spec and serve it via Swagger UI.
#
# Usage:
#   ./run-swagger.sh              # regenerate spec + start Swagger UI
#   ./run-swagger.sh --no-gen     # skip regeneration (use existing spec)
#   ./run-swagger.sh --stop       # stop and remove the Swagger UI container
#   ./run-swagger.sh --port 9090  # listen on a custom port
# -----------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

SWAGGER_PORT="${SWAGGER_PORT:-8080}"
DO_GEN=true
ACTION=up

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-gen) DO_GEN=false; shift ;;
    --stop) ACTION=down; shift ;;
    --port) SWAGGER_PORT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ "$ACTION" == "down" ]]; then
  echo "Stopping Swagger UI ..."
  SWAGGER_PORT="$SWAGGER_PORT" docker compose -f docker-compose.swagger.yml down
  echo "Done."
  exit 0
fi

# --- regenerate openapi spec -------------------------------------------------
if $DO_GEN; then
  echo "Generating OpenAPI spec ..."
  python scripts/generate_openapi.py
  echo ""
fi

SPEC="generated/openapi.json"
if [[ ! -f "$SPEC" ]]; then
  echo "ERROR: $SPEC not found — run 'python scripts/generate_openapi.py' first." >&2
  exit 1
fi

echo "Starting Swagger UI on http://localhost:${SWAGGER_PORT} ..."
SWAGGER_PORT="$SWAGGER_PORT" docker compose -f docker-compose.swagger.yml up -d

echo ""
echo "============================================="
echo "  Swagger UI:  http://localhost:${SWAGGER_PORT}"
echo "  Spec source: ${SPEC}"
echo "============================================="
echo ""
echo "Stop with: ./run-swagger.sh --stop"
