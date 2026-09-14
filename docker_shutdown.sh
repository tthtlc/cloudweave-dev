#!/usr/bin/env bash
# ============================================================================
# docker_shutdown.sh — Gracefully STOP every running container on this Docker
#                      host. Nothing is removed.
#
# The non-destructive counterpart to docker_teardown.sh. Containers are stopped
# (so Vault/Postgres/OpenFGA/LLDAP flush and shut down cleanly) but are LEFT IN
# PLACE, along with their volumes, networks, images and build cache. This is the
# "pause the stack" action — ./docker_start.sh / docker compose up brings it
# straight back with all state intact.
#
#   *** NON-DESTRUCTIVE — NOTHING IS DELETED ***
#
# Usage:
#   ./docker_shutdown.sh              # stop all running containers
#   ./docker_shutdown.sh --dry-run    # show exactly what WOULD be stopped
#   ./docker_shutdown.sh --yes        # no prompt (for scripts/CI)
#
# Exit codes: 0 ok, 1 usage/precondition error, 2 one or more stops failed.
# ============================================================================
set -euo pipefail

ASSUME_YES=0
DRY_RUN=0

usage() {
  sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
# Inventory first, so --dry-run and the confirmation prompt show the real list.
# Only RUNNING containers are stopped; anything already exited is left alone.
# ---------------------------------------------------------------------------
mapfile -t RUNNING < <(docker ps -q)

echo "=================================================================="
echo " Docker shutdown — host-wide (stop only, nothing removed)"
echo "=================================================================="
echo "  running    : ${#RUNNING[@]}"
if ((${#RUNNING[@]})); then
  docker ps --format '{{.Names}}  ({{.Image}})' | sed 's/^/    /'
fi
echo "  containers : kept"
echo "  volumes    : kept"
echo "  networks   : kept"
echo "  images     : kept"
echo "=================================================================="

if ((DRY_RUN)); then
  echo "--dry-run: nothing was stopped."
  exit 0
fi

if ((${#RUNNING[@]} == 0)); then
  echo "Nothing to do — no running containers."
  exit 0
fi

if ! ((ASSUME_YES)); then
  if [[ ! -t 0 ]]; then
    echo "Refusing to stop non-interactively without --yes." >&2
    exit 1
  fi
  echo
  read -r -p "Stop the ${#RUNNING[@]} running container(s) listed above? [y/N] " reply
  [[ "$reply" =~ ^[yY]$ ]] || { echo "Aborted."; exit 0; }
fi

# ---------------------------------------------------------------------------
# Stop. `--time 15` lets postgres/vault flush and shut down cleanly rather
# than being SIGKILL'd, which keeps the daemon log free of unclean-shutdown
# noise on the next `up`. Nothing is removed.
# ---------------------------------------------------------------------------
echo
echo "==> Stopping ${#RUNNING[@]} container(s) ..."
docker stop --time 15 "${RUNNING[@]}" >/dev/null || true

mapfile -t LEFT < <(docker ps -q)
if ((${#LEFT[@]})); then
  echo "!!  ${#LEFT[@]} container(s) survived the stop" >&2
  docker ps --format '{{.Names}}  {{.Status}}' | sed 's/^/    /' >&2
  FAILED=1
fi

echo
echo "=================================================================="
echo " Remaining: $(docker ps -q | wc -l) running, $(docker ps -aq | wc -l) total containers"
echo " Volumes, networks and images were not touched."
echo "=================================================================="

if ((FAILED)); then
  echo "Finished WITH ERRORS — see the '!!' lines above." >&2
  exit 2
fi

echo "Shutdown complete. Containers (and all their state) are still in place —"
echo "bring the stack back with ./docker_start.sh or 'docker compose up'."
