#!/usr/bin/env bash
# ============================================================================
# rebuild_all.sh — Rebuild every locally-built Docker image, then run setup.sh
#
# The ONLINE counterpart to setup.sh. setup.sh is deliberately build-free: it
# recreates containers from PRE-BUILT images so it works in the offline /
# air-gapped environment after migrate2internal/backup-system.sh ->
# restore-system.sh has shipped the images. It never runs `docker compose build`
# and hard-fails if the openfga-local:latest image is absent.
#
# This script is what you run on the INTERNET-CONNECTED machine after editing
# source (e.g. libcloud.rest/app/**, identity_service/app/**, libcloud/**,
# server/**, lldap/**, openfga_*/**): it rebuilds every compose project that
# declares a `build:` directive (the pip install / apt-get inside those builds
# need network), then re-runs setup.sh to start everything and verify.
#
# Usage:
#   ./rebuild_all.sh
#
# Skips (not part of the running stack, or pull-only / overlay):
#   - libcloud.rest/docker-compose.dev.yml      (dev overlay: bind-mount + --reload)
#   - libcloud.rest/docker-compose.swagger.yml  (static Swagger UI, image pull)
#   - migrate2internal/tmp/*                    (offline infra, image pull)
#   - libcloud/contrib/docker/nutanix/*         (isolated unit-test harness)
#
# Base images referenced by `image:` only (dex, vault, postgres, swagger-ui)
# are version-pinned in their compose files and are pulled on `up`, so they are
# intentionally NOT rebuilt here.
# ============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

EXCLUDE_SUBSTRINGS=(
  'docker-compose.dev.yml'
  'docker-compose.swagger.yml'
  '/migrate2internal/'
  '/libcloud/contrib/'
)

is_excluded() {
  local file="$1" sub
  for sub in "${EXCLUDE_SUBSTRINGS[@]}"; do
    [[ "$file" == *"$sub"* ]] && return 0
  done
  return 1
}

echo "==> Discovering locally-built compose projects under ${REPO_ROOT}"

BUILT=0
FAILED=0
BUILT_LIST=()
FAILED_LIST=()

while IFS= read -r compose_file; do
  if is_excluded "$compose_file"; then
    echo "    skip  ${compose_file#${REPO_ROOT}/}"
    continue
  fi
  # Only build projects that actually declare a `build:` section; pull-only
  # projects (dex, vault, postgres, swagger) are left to `docker compose up`.
  if ! grep -q '^[[:space:]]*build:' "$compose_file" 2>/dev/null; then
    echo "    pull  ${compose_file#${REPO_ROOT}/} (image only — no build)"
    continue
  fi

  echo
  echo "==> build ${compose_file#${REPO_ROOT}/}"
  if docker compose -f "$compose_file" build; then
    BUILT=$((BUILT + 1))
    BUILT_LIST+=("${compose_file#${REPO_ROOT}/}")
  else
    FAILED=$((FAILED + 1))
    FAILED_LIST+=("${compose_file#${REPO_ROOT}/}")
    echo "!!  FAILED: ${compose_file#${REPO_ROOT}/}" >&2
  fi
done < <(find "$REPO_ROOT" \
  \( -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' \) \
  -type f | sort)

echo
echo "=================================================================="
echo "Build summary: ${BUILT} succeeded, ${FAILED} failed"
if [[ "${#BUILT_LIST[@]}" -gt 0 ]]; then
  printf '  built:  %s\n' "${BUILT_LIST[@]}"
fi
if [[ "${#FAILED_LIST[@]}" -gt 0 ]]; then
  printf '  failed: %s\n' "${FAILED_LIST[@]}" >&2
fi
echo "=================================================================="

if [[ "${FAILED}" -gt 0 ]]; then
  echo "WARNING: ${FAILED} build(s) failed. setup.sh may still error if a"
  echo "required image is missing (notably openfga-local:latest)." >&2
fi

echo
echo "==> Running setup.sh to start the stack and verify ..."
"${REPO_ROOT}/setup.sh"
