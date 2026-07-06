#!/usr/bin/env bash
# shutdown.sh — gracefully stop the entire libcloud security stack.
#
# The mirror of ./setup.sh. It stops containers in reverse dependency order
# (consumers first, identity/secret stores last) so in-flight requests drain
# cleanly, and leaves all persistent volumes intact by default so the system
# can be restarted in place with ./setup.sh.
#
# Persistent state that survives this script (kept on Docker named volumes):
#   lldap_data       LLDAP users / groups / custom attributes / admin password
#   openfga-data     OpenFGA sqlite store (stores / models / tuples)
#   vault-data       Vault encrypted secrets + seal state (starts sealed next boot)
#   api-data         libcloud REST data/ (auth_audit.log, principal_map.json, users.json)
# Ephemeral state that is LOST on shutdown (by design):
#   dex              in-memory OAuth state + refresh tokens (users must re-login)
#   stoplight_mock   in-memory Nutanix mock stores
#
# Usage:
#   ./shutdown.sh                 stop everything, keep volumes + libcloud_net
#   ./shutdown.sh --keep-rest     leave libcloud-rest-api running (stop only IdP/authz/Vault)
#   ./shutdown.sh --purge-network also remove the libcloud_net network (full teardown)
#   ./shutdown.sh --wipe          DANGER: docker compose down -v on every project
#                                 (destroys all volumes — only for a clean re-bootstrap)
#
# Exit codes: 0 success; 2 bad flag; 5 docker error.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

DEX_DIR="${ROOT}/../dex"
VAULT_DIR="${ROOT}/../vault"
LLDAP_DIR="${ROOT}/../lldap"
REST_DIR="${ROOT}/../libcloud.rest"
STOPLIGHT_DIR="${ROOT}/../stoplight_mock"
SHARED_NET="libcloud_net"

KEEP_REST=0
PURGE_NETWORK=0
WIPE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-rest)     KEEP_REST=1; shift ;;
    --purge-network) PURGE_NETWORK=1; shift ;;
    --wipe)          WIPE=1; shift ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

down_args=()
if [[ "$WIPE" == "1" ]]; then
  down_args=(-v)
  echo "WARNING: --wipe will destroy ALL volumes (lldap_data, openfga-data, vault-data, api-data)." >&2
  echo "         This is irreversible. Ctrl-C now if that is not intended." >&2
  sleep 3
fi

# Helper: down a project only if its compose file exists; tolerate "no containers".
compose_down() {
  local compose_file="$1" project="$2"
  [[ -f "$compose_file" ]] || return 0
  if docker compose -f "$compose_file" ps --status running 2>/dev/null | grep -q . ; then
    echo "Stopping ${project} ..."
    docker compose -f "$compose_file" down "${down_args[@]}" >/dev/null 2>&1 || true
  else
    echo "${project}: not running."
  fi
}

echo "Graceful shutdown of the libcloud security stack (reverse dependency order)."
echo

# 1. libcloud REST API — stop accepting new requests first (it depends on
#    Dex/OpenFGA/Vault). Leave it up if --keep-rest was passed.
if [[ "$KEEP_REST" == "1" ]]; then
  echo "libcloud-rest-api: --keep-rest set, leaving it running."
else
  compose_down "${REST_DIR}/docker-compose.yml" "libcloud-rest-api"
fi
echo

# 2. OpenFGA (server + one-shot bootstrap/migrate containers).
compose_down "${ROOT}/docker-compose.yml" "openfga (openfga, openfga-bootstrap, openfga-migrate)"
echo

# 3. Dex (in-memory — OAuth state + refresh tokens are lost; users re-login on restart).
compose_down "${DEX_DIR}/docker-compose.yml" "dex"
echo

# 4. Vault (starts sealed on next boot; vault_bootstrap.py re-unseals via
#    generated/vault.env's VAULT_UNSEAL_KEY).
compose_down "${VAULT_DIR}/docker-compose.yml" "vault (vault, vault-bootstrap)"
echo

# 5. LLDAP (the identity root — stop last so nothing loses its directory).
compose_down "${LLDAP_DIR}/docker-compose.yml" "lldap (lldap, lldap-tools, bootstrap)"
echo

# 6. stoplight_mock (optional, in-memory only — no persistent state).
compose_down "${STOPLIGHT_DIR}/docker-compose.yml" "stoplight_mock (prism, emulator)"
echo

# 7. Optionally remove the shared network (full teardown).
if [[ "$PURGE_NETWORK" == "1" ]]; then
  if docker network inspect "${SHARED_NET}" >/dev/null 2>&1; then
    echo "Removing shared network ${SHARED_NET} ..."
    docker network rm "${SHARED_NET}" >/dev/null 2>&1 || \
      echo "  WARN: could not remove ${SHARED_NET} (a container may still reference it)." >&2
  else
    echo "${SHARED_NET}: already absent."
  fi
  echo
fi

echo "Shutdown complete."
echo
if [[ "$WIPE" == "1" ]]; then
  echo "  All volumes were destroyed. Next ./setup.sh will perform a FULL re-bootstrap"
  echo "  (new OpenFGA store/model ids, new Vault root token, fresh LLDAP users)."
else
  echo "  Volumes preserved. Restart in place with:  cd openfga_my && ./setup.sh"
  echo "  (Vault will come up sealed and be re-unsealed from generated/vault.env;"
  echo "   OpenFGA reuses the existing sqlite store; Dex re-reads config.yaml.)"
fi
