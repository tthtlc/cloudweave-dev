
  in the current setup, whenever the Dex OIDC signing key got rotated every 6 hour, is the information also propagated to the openFGA now??                    
                                                                                                                                                               

    Grepped, read 2 greps, 2 files
    Grepped "signing.{0,20}key|jwks|rotate|rotation" in .
    Grepped "dex" in .
    Read system_design/dex_6hour_cycle.md
    Read system_design/openfga_dex_jwt.md

  Let me verify the current state of the actual scripts.

    Read 3 files
    Read test_script/scripts/openfga_ensure_fresh.sh
    Read test_script/scripts/common.sh
    Read openfga_postgres/Dockerfile

  Yes — in the current setup, the Dex signing key rotation (every 6h) is propagated to OpenFGA, and no container restart is needed. The propagation is done
  in-process by OpenFGA itself, not by a script.

  How it works now

  The OpenFGA image is pinned to v1.8.16 (openfga_postgres/Dockerfile:25), which is ≥ v1.8.8. As noted in the Dockerfile comment:

   openfga_postgres/Dockerfile lines 11-15

  # Why >= v1.8.8: OpenFGA's OIDC authenticator sets `RefreshUnknownKID: true`
  # (rate-limited 1/min) on the keyfunc JWKS cache, so it refetches Dex's JWKS
  # on a `kid` not in cache — adapting to Dex's 6h signing-key rotation without
  # a container restart (the suggestion.md "dynamically pull keys" best
  # practice). v1.8.4 lacked this and required openfga_ensure_fresh.sh restarts.

  So when Dex rotates its signing key (every 6h, storage: memory), the next token Dex mints carries a kid that OpenFGA's cached JWKS doesn't know. OpenFGA's
  keyfunc JWKS cache, with RefreshUnknownKID: true, refetches Dex's JWKS itself (rate-limited to 1/min) and picks up the new key — no restart required.

  The restart script is now a fallback, not the primary mechanism

  test_script/scripts/common.sh confirms this. The old behavior (always restart before a Check) is now gated behind an opt-in flag:

   test_script/scripts/common.sh lines 46-63

  # OpenFGA JWKS freshness.
  #
  # As of OpenFGA v1.8.8+ (we pin v1.8.16 — see openfga_postgres/Dockerfile), the
  # OIDC authenticator sets `RefreshUnknownKID: true` (rate-limited to 1/min) on
  # the keyfunc JWKS cache, plus a 48h periodic refresh. So when Dex rotates its
  # signing key (every 6h, storage: memory), the next token Dex mints carries a
  # `kid` OpenFGA's cache doesn't know, and OpenFGA refetches Dex's JWKS itself
  # — no container restart needed. This is the suggestion.md "dynamically pull
  # keys" best practice, done in-process.
  #
  # The restart-based openfga_ensure_fresh.sh workaround below is therefore a
  # FALLBACK, not the primary mechanism. It is opt-in: set OPENFGA_ENSURE_FRESH=1
  # to run it (e.g. on an older OpenFGA image that lacks RefreshUnknownKID, or to
  # force a clean JWKS pull). OPENFGA_SKIP_RESTART=1 is still honored as a hard
  # skip for backward compatibility.
  if [[ "${OPENFGA_SKIP_RESTART:-0}" != "1" && "${OPENFGA_ENSURE_FRESH:-0}" == "1" ]]; then
    ...
  fi

  By default OPENFGA_ENSURE_FRESH is unset, so openfga_ensure_fresh.sh (the container-restart workaround) does not run on every Check anymore. It only runs
  if you explicitly set OPENFGA_ENSURE_FRESH=1 (e.g. for an older image, or to force a clean pull).

  Summary

  • Before (v1.8.4 era): OpenFGA cached Dex's JWKS once at startup and never refreshed on unknown kid → stale cache after every 6h rotation →
    invalid_claims / authz_fga_error 503 until a manual/scripted container restart.
  • Now (v1.8.16): OpenFGA self-refreshes the JWKS on kid-miss (RefreshUnknownKID: true, rate-limited 1/min, plus a 48h periodic refresh). Dex's 6h
    rotation is propagated to OpenFGA automatically, in-process, with no restart. The restart script is preserved only as an opt-in fallback.

  One caveat worth flagging: the kid-miss refetch is rate-limited to 1/min, so the very first request after a rotation may still fail once before the
  refetch kicks in for subsequent requests — but it self-heals within a minute rather than requiring a restart.


