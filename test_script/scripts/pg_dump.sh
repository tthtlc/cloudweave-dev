#!/usr/bin/env bash
# Dump the OpenFGA Postgres datastore to a file (plain SQL). For backups /
# rollback snapshots. Usage:
#   scripts/pg_dump.sh [output_file]
# Default: generated/openfga_pg_dump_YYYYmmdd_HHMMSS.sql
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
set -a
source .env 2>/dev/null || true
if [[ -z "${POSTGRES_PASSWORD:-}" && -f test_script/generated/postgres.env ]]; then
  source test_script/generated/postgres.env
fi
set +a
mkdir -p test_script/generated
out="${1:-test_script/generated/openfga_pg_dump_$(date -u +%Y%m%d_%H%M%S).sql}"
docker exec openfga-postgres \
  pg_dump -U "${POSTGRES_USER:-openfga}" -d "${POSTGRES_DB:-openfga}" \
  --no-owner --no-privileges > "$out"
echo "Wrote $out"
