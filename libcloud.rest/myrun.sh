#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example — add provider secrets before use."
fi

cd /home/ubuntu/libcloud_nutanix/libcloud.rest && docker compose build api && docker compose up -d api && sleep 5 && curl -s http://localhost:8765/health

docker compose build api && docker compose up -d api
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d api

docker compose up --build -d --wait
echo "API listening on http://localhost:${API_PORT:-8765}"
echo "Docs: http://localhost:${API_PORT:-8765}/docs"
