#!/usr/bin/env bash
# Convenience wrapper to run psql against the OpenFGA Postgres datastore.
# Usage:
#   scripts/pg_query.sh                          # interactive psql
#   scripts/pg_query.sh -c 'select count(*) from tuple;'
#   scripts/pg_query.sh -c "select store, object_type, object_id, relation, \
#     user_object_type, user_object_id from tuple limit 20;"
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
set -a
source .env 2>/dev/null || true
# Reuse the persisted password if .env left it blank.
if [[ -z "${POSTGRES_PASSWORD:-}" && -f test_script/generated/postgres.env ]]; then
  source test_script/generated/postgres.env
fi
set +a
exec docker exec -it openfga-postgres \
  psql -U "${POSTGRES_USER:-openfga}" -d "${POSTGRES_DB:-openfga}" "$@"
