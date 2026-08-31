#!/usr/bin/env bash
# pg_dump.sh — download (dump) the entire OpenFGA PostgreSQL datastore and
# print every physical file relevant to that database.
#
# Reads the Postgres credentials from generated/postgres.env and the active
# store/model IDs from generated/fga.env, then:
#   1. pg_dump's the whole `openfga` database out of the running
#      `openfga-postgres` container into generated/ (git-ignored).
#   2. Prints the store + authorization_model rows so the IDs in fga.env map
#      to the rows actually persisted in Postgres.
#   3. Prints every physical file that backs or describes the datastore:
#      the env/config files, the FGA model sources, the generated runtime
#      state, and the on-disk Postgres data directory inside the Docker named
#      volume (the real physical storage).
#
# Usage:
#   scripts/pg_dump.sh               # plain-SQL dump + physical-file report
#   scripts/pg_dump.sh --custom      # pg_dump -Fc archive (pg_restore-able)
#   scripts/pg_dump.sh --out DIR     # write the dump to DIR instead of generated/
#
# Optional env overrides: PG_CONTAINER (default openfga-postgres), OUT_DIR.
#
# Note: the dump is produced by pg_dump *inside* the container (no host psql
# client is required) and written to the host via stdout redirection.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"        # openfga_postgres/
REPO_ROOT="$(cd "${PG_DIR}/.." && pwd)"

PG_ENV_FILE="${PG_DIR}/generated/postgres.env"
FGA_ENV_FILE="${PG_DIR}/generated/fga.env"

PG_CONTAINER="${PG_CONTAINER:-openfga-postgres}"

# ---- arg parsing -------------------------------------------------------------
FORMAT=plain
OUT_DIR="${OUT_DIR:-${PG_DIR}/generated}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --custom)   FORMAT=custom; shift;;
    --out)      OUT_DIR="$2"; shift 2;;
    -h|--help)  sed -n '2,26p' "$0"; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

# ---- env helpers -------------------------------------------------------------
# env_val <file> <key>  -> value ("" if the file or key is missing). Never
# sources the file, so it cannot execute arbitrary shell in an env file.
env_val() {
  [[ -f "$1" ]] || { echo ""; return 0; }
  grep -E "^[[:space:]]*$2=" "$1" 2>/dev/null | tail -n1 \
    | sed -E 's/^[[:space:]]*[^=]*=[[:space:]]*//; s/[[:space:]]*$//'
}

PG_HOST="$(env_val "$PG_ENV_FILE" POSTGRES_HOST)"
PG_DB="$(env_val "$PG_ENV_FILE" POSTGRES_DB)"
PG_USER="$(env_val "$PG_ENV_FILE" POSTGRES_USER)"
PG_PASS="$(env_val "$PG_ENV_FILE" POSTGRES_PASSWORD)"
PG_SSLMODE="$(env_val "$PG_ENV_FILE" POSTGRES_SSLMODE)"
FGA_STORE_ID="$(env_val "$FGA_ENV_FILE" FGA_STORE_ID)"
FGA_MODEL_ID="$(env_val "$FGA_ENV_FILE" FGA_MODEL_ID)"

PG_DB="${PG_DB:-openfga}"
PG_USER="${PG_USER:-openfga}"

# ---- sanity checks -----------------------------------------------------------
if [[ ! -f "$PG_ENV_FILE" ]]; then
  echo "FATAL: missing ${PG_ENV_FILE}" >&2; exit 3
fi
if [[ -z "$PG_PASS" ]]; then
  echo "FATAL: POSTGRES_PASSWORD is empty in ${PG_ENV_FILE}" >&2; exit 3
fi
if ! docker inspect -f '{{.State.Running}}' "$PG_CONTAINER" 2>/dev/null | grep -qx true; then
  echo "FATAL: postgres container '${PG_CONTAINER}' is not running." >&2
  echo "       start it with: (cd ${PG_DIR} && docker compose up -d postgres)" >&2
  exit 3
fi

# psql/pg_dump run *inside* the container; connect over TCP so the
# credentials from postgres.env are actually exercised (local unix-socket
# connections would be `trust`).
psql_cmd() {
  docker exec -e PGPASSWORD="$PG_PASS" "$PG_CONTAINER" \
    psql -h 127.0.0.1 -U "$PG_USER" -d "$PG_DB" -X -P pager=off "$@"
}

# ---- 1. dump the whole database ---------------------------------------------
mkdir -p "$OUT_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
if [[ "$FORMAT" == "custom" ]]; then
  DUMP_FILE="${OUT_DIR}/openfga-pg-${FGA_STORE_ID:-nostore}-${TS}.dump"
  DOCKER_ARGS=(pg_dump -h 127.0.0.1 -U "$PG_USER" -d "$PG_DB" -Fc --no-owner --no-privileges)
else
  DUMP_FILE="${OUT_DIR}/openfga-pg-${FGA_STORE_ID:-nostore}-${TS}.sql"
  DOCKER_ARGS=(pg_dump -h 127.0.0.1 -U "$PG_USER" -d "$PG_DB" --no-owner --no-privileges)
fi

echo "== Dumping PostgreSQL database ============================================"
echo "  container : ${PG_CONTAINER}"
echo "  database  : ${PG_DB} (user=${PG_USER}, sslmode=${PG_SSLMODE:-<unset>})"
echo "  store     : ${FGA_STORE_ID:-<unset>}   model: ${FGA_MODEL_ID:-<unset>}"
echo "  format    : ${FORMAT}"
echo "  -> ${DUMP_FILE}"
docker exec -e PGPASSWORD="$PG_PASS" "$PG_CONTAINER" "${DOCKER_ARGS[@]}" > "$DUMP_FILE"
echo "  dumped $(du -h "$DUMP_FILE" | cut -f1) ($(wc -l < "$DUMP_FILE" 2>/dev/null || echo 0) lines / bytes: $(stat -c%s "$DUMP_FILE"))"
echo

# ---- 2. map store/model IDs to DB rows --------------------------------------
echo "== store rows =============================================================="
psql_cmd -c "SELECT id, name, created_at FROM store ORDER BY created_at;"
echo
echo "== authorization_model rows ================================================"
psql_cmd -c "SELECT store, authorization_model_id, schema_version FROM authorization_model ORDER BY store, authorization_model_id;"
echo

# ---- 3. physical files relevant to the Postgres datastore -------------------
# The Docker named volume is the actual on-disk storage. The host path is
# root-owned, so enumerate the files via the container instead.
VOL_MOUNT="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}|{{.Source}}{{end}}{{end}}' "$PG_CONTAINER")"
VOL_NAME="${VOL_MOUNT%%|*}"
VOL_HOST_PATH="${VOL_MOUNT#*|}"

section() { printf '== %s %s\n' "$1" "$(printf '=%.0s' {1..64})" | cut -c1-76; echo; }

section "Configuration & credentials"
for f in \
  "${PG_ENV_FILE}" \
  "${FGA_ENV_FILE}" \
  "${PG_DIR}/.env" \
  "${PG_DIR}/docker-compose.yml" \
  "${PG_DIR}/Dockerfile" \
  "${PG_DIR}/.dockerignore"; do
  [[ -f "$f" ]] && printf '  %-10s %s\n' "$(du -h "$f" 2>/dev/null | cut -f1)" "${f#${REPO_ROOT}/}"
done
echo

section "Authorization model sources (stored in the DB as authorization_model)"
for f in "${PG_DIR}"/model/*; do
  [[ -f "$f" ]] && printf '  %-10s %s\n' "$(du -h "$f" 2>/dev/null | cut -f1)" "${f#${REPO_ROOT}/}"
done
[[ -f "${PG_DIR}/data/principal_map.json" ]] && \
  printf '  %-10s %s\n' "$(du -h "${PG_DIR}/data/principal_map.json" | cut -f1)" "openfga_postgres/data/principal_map.json"
echo

section "Generated runtime state (git-ignored)"
for f in "${PG_DIR}"/generated/* "${PG_DIR}"/generated/tokens/*; do
  [[ -f "$f" ]] && printf '  %-10s %s\n' "$(du -h "$f" 2>/dev/null | cut -f1)" "${f#${REPO_ROOT}/}"
done
echo

section "Docker named volume (physical Postgres data dir)"
echo "  volume     : ${VOL_NAME:-<unknown>}"
echo "  host path  : ${VOL_HOST_PATH:-<unknown>} (root-owned; listed via container)"
echo "  container  : /var/lib/postgresql/data"
echo "  files:"
docker exec "$PG_CONTAINER" sh -lc 'ls -la /var/lib/postgresql/data' 2>/dev/null \
  | sed 's/^/    /'
echo
echo "  base/<db oid> — the per-database subdirectories (tables + indexes):"
docker exec "$PG_CONTAINER" sh -lc 'ls -la /var/lib/postgresql/data/base' 2>/dev/null \
  | sed 's/^/    /'
echo

section "Other postgres/FGA files anywhere under the repo"
find "$REPO_ROOT" -type f \( -path '*/.git/*' -o -path '*/node_modules/*' \
  -o -path '*/.venv/*' -o -path '*/venv/*' -o -path '*/site-packages/*' \) -prune -o \
  -type f \( -iname '*postgres*' -o -iname 'fga.env' -o -iname '*.fga' -o -iname '*.fga.yaml' -o -iname '*pg_dump*' \) -print 2>/dev/null \
  | while IFS= read -r f; do printf '  %s\n' "${f#${REPO_ROOT}/}"; done
echo

echo "Done. Full dump: ${DUMP_FILE}"
if [[ "$FORMAT" == "custom" ]]; then
  echo "Restore with: pg_restore -h 127.0.0.1 -U ${PG_USER} -d ${PG_DB} \"${DUMP_FILE}\""
fi
exit 0
