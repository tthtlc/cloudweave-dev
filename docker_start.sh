#!/usr/bin/env bash
# ============================================================================
# docker_start.sh — Resume every STOPPED service container on this Docker host.
#                   Nothing is created, recreated, rebuilt or removed.
#
# The non-destructive counterpart to docker_shutdown.sh. docker_shutdown.sh
# stopped the running containers and LEFT THEM IN PLACE (with their volumes,
# networks, images and state intact); this script starts those same containers
# back up in place with `docker start`. No `docker compose up`, no recreate, no
# rebuild — it simply un-pauses the stack, so Vault/Postgres/OpenFGA/LLDAP come
# back with all state intact.
#
#   *** NON-DESTRUCTIVE — NOTHING IS CREATED OR DELETED ***
#
# One-shot containers (openfga-migrate, openfga-bootstrap, vault-bootstrap,
# lldap bootstrap — all declared `restart: "no"`) are deliberately SKIPPED:
# they exist only to be run once by setup.sh with a fresh superadmin JWT, and
# re-running them here would either fail (no JWT) or re-apply migrations.
# For a full re-bootstrap use ./setup.sh instead.
#
# Long-running services (restart: unless-stopped) are started dependency-first
# (Postgres / LLDAP / Vault / Dex before the consumers that talk to them) so
# the stack comes up cleanly rather than crash-looping until peers are ready.
#
# Usage:
#   ./docker_start.sh              # start all stopped service containers
#   ./docker_start.sh --dry-run    # show exactly what WOULD be started
#   ./docker_start.sh --yes        # no prompt (for scripts/CI)
#
# Exit codes: 0 ok, 1 usage/precondition error, 2 one or more starts failed.
# ============================================================================
set -euo pipefail

ASSUME_YES=0
DRY_RUN=0

usage() {
  sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)      ASSUME_YES=1 ;;
    -n|--dry-run)  DRY_RUN=1 ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
  esac
  shift
done

command -v docker >/dev/null 2>&1 || { echo "docker not found in PATH" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "cannot talk to the Docker daemon (is it running? are you in the docker group?)" >&2; exit 1; }

FAILED=0

# ---------------------------------------------------------------------------
# Inventory. Only EXITED containers are candidates: `docker stop` (what
# docker_shutdown.sh ran) leaves a container "exited", whereas "created"
# containers were never started in the first place and are left alone. Within
# the exited set we keep only *service* containers — those with a restart
# policy other than "no" (unless-stopped/always/on-failure). `restart: "no"`
# marks the one-shot bootstrap/migrate containers that setup.sh runs once.
# ---------------------------------------------------------------------------
mapfile -t STOPPED_IDS < <(docker ps -aq --filter status=exited)

is_service()   { local p="$1"; [[ "$p" != "no" && -n "$p" ]]; }   # long-running
is_dependency() { [[ "$1" =~ (postgres|lldap|vault|dex|kafka|redis|mysql|mongo) ]]; }

DEP_IDS=();  DEP_NAMES=()
REST_IDS=(); REST_NAMES=()
SKIP_NAMES=()

for c in "${STOPPED_IDS[@]}"; do
  name=$(docker inspect --format '{{ .Name }}' "$c" 2>/dev/null | sed 's#^/##' || true)
  [[ -n "$name" ]] || continue
  policy=$(docker inspect --format '{{ .HostConfig.RestartPolicy.Name }}' "$c" 2>/dev/null || true)

  if ! is_service "$policy"; then
    SKIP_NAMES+=("$name")            # one-shot (bootstrap/migrate) — skip
  elif is_dependency "$name"; then
    DEP_IDS+=("$c");   DEP_NAMES+=("$name")
  else
    REST_IDS+=("$c");  REST_NAMES+=("$name")
  fi
done

echo "=================================================================="
echo " Docker start — host-wide (resume stopped service containers)"
echo "=================================================================="
echo "  services stopped : $(( ${#DEP_IDS[@]} + ${#REST_IDS[@]} ))"
if ((${#DEP_IDS[@]})); then
  echo "    infrastructure (started first):"
  printf '      %s\n' "${DEP_NAMES[@]}"
fi
if ((${#REST_IDS[@]})); then
  echo "    consumers (started after):"
  printf '      %s\n' "${REST_NAMES[@]}"
fi
if ((${#SKIP_NAMES[@]})); then
  echo "  skipped (one-shot / restart:no):"
  printf '      %s\n' "${SKIP_NAMES[@]}"
fi
echo "  volumes/networks/images : untouched"
echo "=================================================================="

if ((DRY_RUN)); then
  echo "--dry-run: nothing was started."
  exit 0
fi

if ((${#DEP_IDS[@]} + ${#REST_IDS[@]} == 0)); then
  echo "Nothing to do — no stopped service containers."
  exit 0
fi

if ! ((ASSUME_YES)); then
  if [[ ! -t 0 ]]; then
    echo "Refusing to start non-interactively without --yes." >&2
    exit 1
  fi
  echo
  read -r -p "Start the $(( ${#DEP_IDS[@]} + ${#REST_IDS[@]} )) stopped service container(s) listed above? [y/N] " reply
  [[ "$reply" =~ ^[yY]$ ]] || { echo "Aborted."; exit 0; }
fi

# ---------------------------------------------------------------------------
# 1. Dependency-first: bring Postgres/LLDAP/Vault/Dex (and any other obvious
#    stateful backbone) up, then wait for them to actually be running so the
#    consumers in phase 2 don't crash-loop against peers that aren't up yet.
# ---------------------------------------------------------------------------
if ((${#DEP_IDS[@]})); then
  echo
  echo "==> Starting ${#DEP_IDS[@]} infrastructure container(s) ..."
  docker start "${DEP_IDS[@]}" >/dev/null || FAILED=1

  # Wait (up to 60s) until each dependency is running. "running" is the gate:
  # once the process is up, the consumer's `unless-stopped` restart policy
  # covers the remaining warm-up. Extra 3s settle for DB/IdP readiness.
  echo "    waiting for infrastructure to be up ..."
  for i in $(seq 1 60); do
    ready=1
    for c in "${DEP_IDS[@]}"; do
      if ! docker inspect --format '{{ .State.Running }}' "$c" 2>/dev/null | grep -qx true; then
        ready=0; break
      fi
    done
    [[ $ready -eq 1 ]] && break
    [[ "$i" -eq 60 ]] && echo "    !! infrastructure not all running after 60s (continuing)" >&2
    sleep 1
  done
  sleep 3

  # Vault resumes SEALED: the Shamir key lives only in memory, and a
  # `docker stop`/`docker start` re-locks the store. The normal unseal lives in
  # vault-bootstrap (restart: "no"), which this resume path deliberately skips,
  # so unseal here from the same vault/generated/vault.env that setup.sh and
  # rotate_root_and_unseal.sh maintain. Soft-failure: a fresh host (no vault.env)
  # still goes through ./setup.sh, which initializes + unseals.
  if printf '%s\n' "${DEP_NAMES[@]}" | grep -qx vault; then
    VAULT_ENV="${VAULT_ENV:-vault/generated/vault.env}"
    if [[ -f "$VAULT_ENV" ]]; then
      key=$(grep -E '^VAULT_UNSEAL_KEY=' "$VAULT_ENV" | cut -d= -f2-)
      if [[ -n "$key" ]]; then
        sealed=$(curl -sS http://127.0.0.1:8200/v1/sys/seal-status | jq -r '.sealed // "true"')
        if [[ "$sealed" == "true" ]]; then
          if curl -sS -X PUT http://127.0.0.1:8200/v1/sys/unseal -d "{\"key\":\"$key\"}" | jq -e '.sealed == false' >/dev/null 2>&1; then
            echo "    vault unsealed"
          else
            echo "    !! vault unseal failed — check VAULT_UNSEAL_KEY in $VAULT_ENV" >&2
          fi
        else
          echo "    vault already unsealed"
        fi
      else
        echo "    !! $VAULT_ENV has no VAULT_UNSEAL_KEY — run ./setup.sh to (re)initialize Vault" >&2
      fi
    else
      echo "    !! $VAULT_ENV missing — run ./setup.sh to (re)initialize Vault" >&2
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 2. Consumers. Started after the infrastructure above is up.
# ---------------------------------------------------------------------------
if ((${#REST_IDS[@]})); then
  echo
  echo "==> Starting ${#REST_IDS[@]} consumer container(s) ..."
  docker start "${REST_IDS[@]}" >/dev/null || FAILED=1
fi

# ---------------------------------------------------------------------------
# Verify: any service container that is still not running is a failure.
# ---------------------------------------------------------------------------
LEFT=0
for c in "${DEP_IDS[@]}" "${REST_IDS[@]}"; do
  if ! docker inspect --format '{{ .State.Running }}' "$c" 2>/dev/null | grep -qx true; then
    docker inspect --format '    {{ .Name }}  {{ .State.Status }}' "$c" 2>/dev/null | sed 's#/##'
    LEFT=$((LEFT + 1))
  fi
done
if ((LEFT)); then
  echo "!!  ${LEFT} container(s) did not come up" >&2
  FAILED=1
fi

echo
echo "=================================================================="
echo " Running: $(docker ps -q | wc -l) running, $(docker ps -aq | wc -l) total containers"
echo " Volumes, networks and images were not touched."
echo "=================================================================="

if ((FAILED)); then
  echo "Finished WITH ERRORS — see the '!!' lines above." >&2
  exit 2
fi

echo "Start complete. The stack is back up with all state intact."
echo "For a full re-bootstrap (Vault init/unseal, OpenFGA seed, tenant users),"
echo "run ./setup.sh instead."
