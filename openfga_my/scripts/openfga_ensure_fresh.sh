#!/usr/bin/env bash
# openfga_ensure_fresh.sh — make sure OpenFGA's cached OIDC JWKS matches Dex's
# current signing keys.
#
# Why this exists:
#   Dex is configured with `storage: type: memory` and rotates its OIDC signing
#   keys every 6h. OpenFGA fetches Dex's discovery doc + JWKS once at startup
#   (coreos/go-oidc) and does not reliably refresh on an unknown `kid`. After a
#   Dex key rotation, tokens minted by Dex are signed with a `kid` that OpenFGA's
#   cached keyset does not know, so every `Check` returns
#   `{"code":"invalid_claims","message":"invalid claims"}` (HTTP 401) — which the
#   libcloud REST API surfaces as `authz_fga_error` (HTTP 503). Restarting
#   OpenFGA forces a fresh JWKS fetch and clears the stale cache.
#
# This helper restarts the OpenFGA container (throttled so repeated script
# invocations within a single demo run don't hammer it) and waits for /healthz.
# Safe to source-call repeatedly. Exits 0 on success / skipped.
#
# Env knobs:
#   OPENFGA_SKIP_RESTART=1          skip the restart entirely (use when OpenFGA
#                                   is known-fresh or managed externally).
#   OPENFGA_FORCE_RESTART=1         restart even if within the throttle window.
#   OPENFGA_JWKS_REFRESH_TTL_SEC    throttle window (default 3600).
#   OPENFGA_CONTAINER               container name (default "openfga").
#   FGA_API_URL                     OpenFGA HTTP base (default http://localhost:8080).
set -uo pipefail

SCRIPT_DIR_IEF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_IEF="$(cd "${SCRIPT_DIR_IEF}/.." && pwd)"

OPENFGA_CONTAINER="${OPENFGA_CONTAINER:-openfga}"
FGA_API_URL_IEF="${FGA_API_URL:-http://localhost:8080}"
TTL_SEC="${OPENFGA_JWKS_REFRESH_TTL_SEC:-3600}"
MARKER="${ROOT_IEF}/generated/.openfga_jwks_refreshed_at"

_log() { echo "[openfga_ensure_fresh] $*"; }

if [[ "${OPENFGA_SKIP_RESTART:-0}" == "1" ]]; then
  _log "OPENFGA_SKIP_RESTART=1 — skipping."
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  _log "WARN: docker not found; cannot restart OpenFGA. If you hit 'invalid_claims', restart OpenFGA manually." >&2
  exit 0
fi

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${OPENFGA_CONTAINER}"; then
  _log "WARN: container '${OPENFGA_CONTAINER}' not running — skipping (run ./setup.sh first)." >&2
  exit 0
fi

# Throttle: skip if we refreshed within TTL_SEC, unless forced.
mkdir -p "$(dirname "${MARKER}")"
if [[ "${OPENFGA_FORCE_RESTART:-0}" != "1" && -f "${MARKER}" ]]; then
  now=$(date +%s); mtime=$(stat -c %Y "${MARKER}" 2>/dev/null || stat -f %m "${MARKER}" 2>/dev/null)
  if [[ -n "${mtime:-}" ]] && (( now - mtime < TTL_SEC )); then
    _log "last refresh < ${TTL_SEC}s ago — skipping restart (set OPENFGA_FORCE_RESTART=1 to force)."
    exit 0
  fi
fi

_log "restarting OpenFGA container '${OPENFGA_CONTAINER}' to refresh Dex JWKS cache ..."
if ! docker restart "${OPENFGA_CONTAINER}" >/dev/null 2>&1; then
  _log "ERROR: 'docker restart ${OPENFGA_CONTAINER}' failed." >&2
  exit 0  # do not abort the caller; the run may still succeed if JWKS is fresh.
fi

# Wait for the HTTP API to come back (signature checks go over HTTP/gRPC).
health_url="${FGA_API_URL_IEF}/healthz"
ok=0
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null --max-time 2 "${health_url}" 2>/dev/null; then
    ok=1; break
  fi
  sleep 1
done
if [[ "${ok}" != "1" ]]; then
  _log "WARN: OpenFGA did not return /healthz=200 within 30s; continuing anyway." >&2
  exit 0
fi

date +%s > "${MARKER}"
_log "OpenFGA is healthy and JWKS cache is fresh."
