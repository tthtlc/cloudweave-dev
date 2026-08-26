#!/usr/bin/env bash
# ============================================================================
# docker_teardown.sh — Stop & remove EVERY container, volume and network on
#                      this Docker host.
#
# This is the blunt-instrument counterpart to setup.sh / rebuild_all.sh. It is
# host-wide, NOT repo-scoped: it does not read any docker-compose.yml and does
# not care which project a resource belongs to. Anything else you happen to be
# running on this daemon dies with it.
#
#   *** DESTRUCTIVE — VOLUME REMOVAL IS PERMANENT DATA LOSS ***
#
# The named volumes in this repo carry real state, and there is no undo:
#   vault_vault-data                -> Vault storage. Unseal keys + root token
#                                      are gone; Vault comes back UNINITIALIZED.
#   openfga_postgres_openfga-pg-data-> OpenFGA store/model IDs + all tuples.
#   openfga_my_openfga-data         -> OpenFGA local state.
#   lldap_lldap_data                -> LLDAP users/groups.
#   libcloudrest_api-data           -> libcloud.rest API state.
# Anonymous volumes (the bare 64-hex names) go too.
#
# Images and build cache are deliberately LEFT ALONE, so the offline/air-gapped
# path still works: after this you can re-run ./setup.sh without a rebuild and
# without network. Re-bootstrapping (Vault init/unseal, OpenFGA store, LLDAP
# seed) will happen from scratch.
#
# Usage:
#   ./docker_teardown.sh              # prompt for confirmation, then wipe
#   ./docker_teardown.sh --dry-run    # show exactly what WOULD be removed
#   ./docker_teardown.sh --yes        # no prompt (for scripts/CI)
#
# Exit codes: 0 ok, 1 usage/precondition error, 2 one or more removals failed.
# ============================================================================
set -euo pipefail

ASSUME_YES=0
DRY_RUN=0

usage() {
  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
# `mapfile -t < <(...)` keeps empty output as an empty array (a plain
# `$(...)` split would leave a single empty element and we'd try to rm "").
# Predefined networks bridge/host/none cannot be removed, so filter them out
# up front rather than eating an error per run.
# ---------------------------------------------------------------------------
mapfile -t CONTAINERS < <(docker ps -aq)
mapfile -t VOLUMES    < <(docker volume ls -q)
mapfile -t NETWORKS   < <(docker network ls --filter type=custom --format '{{.Name}}')

echo "=================================================================="
echo " Docker teardown — host-wide"
echo "=================================================================="
echo "  containers : ${#CONTAINERS[@]}"
if ((${#CONTAINERS[@]})); then
  # docker strips leading whitespace from --format, so indent with sed.
  docker ps -a --format '{{.Names}}  ({{.Image}}, {{.State}})' | sed 's/^/    /'
fi
echo "  volumes    : ${#VOLUMES[@]}   ** DATA LOSS **"
((${#VOLUMES[@]})) && printf '    %s\n' "${VOLUMES[@]}"
echo "  networks   : ${#NETWORKS[@]}   (bridge/host/none are predefined and kept)"
((${#NETWORKS[@]})) && printf '    %s\n' "${NETWORKS[@]}"
echo "  images     : kept"
echo "=================================================================="

if ((DRY_RUN)); then
  echo "--dry-run: nothing was removed."
  exit 0
fi

if ((${#CONTAINERS[@]} + ${#VOLUMES[@]} + ${#NETWORKS[@]} == 0)); then
  echo "Nothing to do."
  exit 0
fi

if ! ((ASSUME_YES)); then
  if [[ ! -t 0 ]]; then
    echo "Refusing to wipe non-interactively without --yes." >&2
    exit 1
  fi
  echo
  echo "This PERMANENTLY deletes the volumes listed above (Vault unseal keys,"
  echo "OpenFGA tuples, LLDAP users). There is no undo."
  read -r -p "Type 'yes' to proceed: " reply
  [[ "$reply" == "yes" ]] || { echo "Aborted."; exit 0; }
fi

# ---------------------------------------------------------------------------
# 1. Containers. Stop then force-remove. `rm -f` alone would do it, but the
#    graceful stop first lets postgres/vault flush and shut down cleanly, which
#    keeps the daemon log free of unclean-shutdown noise on the next `up`.
#    Removing containers is also what frees the volumes and networks below.
# ---------------------------------------------------------------------------
if ((${#CONTAINERS[@]})); then
  echo
  echo "==> Stopping ${#CONTAINERS[@]} container(s) ..."
  docker stop --time 15 "${CONTAINERS[@]}" >/dev/null || true

  echo "==> Removing containers ..."
  # -v drops each container's anonymous volumes along with it.
  docker rm -f -v "${CONTAINERS[@]}" >/dev/null || true

  mapfile -t LEFT < <(docker ps -aq)
  if ((${#LEFT[@]})); then
    echo "!!  ${#LEFT[@]} container(s) survived removal" >&2
    docker ps -a --format '{{.Names}}  {{.Status}}' | sed 's/^/    /' >&2
    FAILED=1
  fi
fi

# ---------------------------------------------------------------------------
# 2. Volumes. Enumerate + `volume rm` rather than `volume prune`: prune's
#    semantics differ across Docker versions (older ones skip named volumes
#    without -a) and it silently no-ops on anything it considers in use.
#    Re-list here — the container pass above already took anonymous ones.
# ---------------------------------------------------------------------------
mapfile -t VOLUMES < <(docker volume ls -q)
if ((${#VOLUMES[@]})); then
  echo
  echo "==> Removing ${#VOLUMES[@]} volume(s) ..."
  for v in "${VOLUMES[@]}"; do
    if docker volume rm -f "$v" >/dev/null 2>&1; then
      echo "    removed  $v"
    else
      echo "!!  in use or undeletable: $v" >&2
      FAILED=1
    fi
  done
fi

# ---------------------------------------------------------------------------
# 3. Networks. Same re-list rationale.
# ---------------------------------------------------------------------------
mapfile -t NETWORKS < <(docker network ls --filter type=custom --format '{{.Name}}')
if ((${#NETWORKS[@]})); then
  echo
  echo "==> Removing ${#NETWORKS[@]} network(s) ..."
  for n in "${NETWORKS[@]}"; do
    if docker network rm "$n" >/dev/null 2>&1; then
      echo "    removed  $n"
    else
      echo "!!  in use or undeletable: $n" >&2
      FAILED=1
    fi
  done
fi

echo
echo "=================================================================="
echo " Remaining: $(docker ps -aq | wc -l) containers, $(docker volume ls -q | wc -l) volumes, $(docker network ls --filter type=custom -q | wc -l) custom networks"
echo " Images were not touched:  $(docker images -q | wc -l) image(s) still present"
echo "=================================================================="

if ((FAILED)); then
  echo "Finished WITH ERRORS — see the '!!' lines above." >&2
  exit 2
fi

echo "Teardown complete. Re-run ./setup.sh to rebuild the stack from images."
