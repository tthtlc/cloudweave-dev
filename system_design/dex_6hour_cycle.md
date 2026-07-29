
> **RESOLVED (2026-07) — historical note.** This file describes the pre-v1.16.0 era.
> OpenFGA v1.16.0 (pinned in `openfga_postgres/Dockerfile`; PR #3101) enables
> `RefreshUnknownKID` in its OIDC authenticator, so on an unknown `kid` after a
> Dex rotation it refetches Dex's JWKS in-process — no container restart needed.
> The restart-based `openfga_ensure_fresh.sh` workaround, its env knobs
> (`OPENFGA_SKIP_RESTART`, `OPENFGA_FORCE_RESTART`, `OPENFGA_JWKS_REFRESH_TTL_SEC`)
> and the marker file `generated/.openfga_jwks_refreshed_at` have all been removed.
> Kept for historical context only.

---

OpenFGA fetches Dex's discovery doc + JWKS once at startup
  #   (coreos/go-oidc) and does not reliably refresh on an unknown `kid`. After a
  #   Dex key rotation, tokens minted by Dex are signed with a `kid` that OpenFGA's
  #   cached keyset does not know, so every `Check` returns
  #   `{"code":"invalid_claims","message":"invalid claims"}` (HTTP 401) — which the
  #   libcloud REST API surfaces as `authz_fga_error` (HTTP 503). Restarting
  #   OpenFGA forces a fresh JWKS fetch and clears the stale cache.

 The 6-hourly renewal isn't actually inside OpenFGA — it's a Dex behavior that OpenFGA reacts to. Here's the relevant note from the codebase:

  scripts/openfga_ensure_fresh.sh:

   openfga_my/scripts/openfga_ensure_fresh.sh lines 1-13

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

  The summary:

  • Where the 6h cycle lives: Dex (the IdP), not OpenFGA. Dex with storage: type: memory rotates its OIDC signing keys every 6h.
  • OpenFGA's behavior: it fetches Dex's discovery doc + JWKS once at startup (via coreos/go-oidc) and does not reliably refresh on an unknown kid. So
    after each 6h Dex rotation, OpenFGA's cached keyset goes stale and every Check fails with invalid_claims (surfaced as authz_fga_error / HTTP 503).
  • Where the renewal/refresh is handled: openfga_my/scripts/openfga_ensure_fresh.sh, which restarts the OpenFGA container (throttled, default 3600s, via
    OPENFGA_JWKS_REFRESH_TTL_SEC) so it re-fetches Dex's JWKS. It's invoked from scripts/common.sh before any Check:

   openfga_my/scripts/common.sh lines 50-57

  # Ensure OpenFGA's cached Dex JWKS is fresh before any Check. Dex rotates its
  # OIDC signing keys every 6h (storage: memory); a stale OpenFGA keyset makes
  # every Check fail with `invalid_claims`. Throttled + skippable; no-op when
  # already refreshed recently (e.g. by a myrun_* script). Set OPENFGA_SKIP_RESTART=1
  # to disable.
  if [[ "${OPENFGA_SKIP_RESTART:-0}" != "1" ]]; then
    bash "${SCRIPT_DIR}/openfga_ensure_fresh.sh" >/dev/null 2>&1 || true
  fi

  Env knobs controlling it (in openfga_ensure_fresh.sh):
  • OPENFGA_SKIP_RESTART=1 — disable entirely
  • OPENFGA_FORCE_RESTART=1 — force restart ignoring the throttle window
  • OPENFGA_JWKS_REFRESH_TTL_SEC — throttle window (default 3600)
  • OPENFGA_CONTAINER — container name (default openfga)
  • Marker file: generated/.openfga_jwks_refreshed_at

  So to be precise: there is no 6h renewal logic in OpenFGA itself in this repo — the 6h cadence originates in Dex, and scripts/openfga_ensure_fresh.sh is
  the local workaround that renews OpenFGA's cached JWKS by restarting the container.

