OpenFGA fetches Dex's discovery doc + JWKS once at startup
  #   (coreos/go-oidc) and does not reliably refresh on an unknown `kid`. After a
  #   Dex key rotation, tokens minted by Dex are signed with a `kid` that OpenFGA's
  #   cached keyset does not know, so every `Check` returns
  #   `{"code":"invalid_claims","message":"invalid claims"}` (HTTP 401) — which the
  #   libcloud REST API surfaces as `authz_fga_error` (HTTP 503). Restarting
  #   OpenFGA forces a fresh JWKS fetch and clears the stale cache.

<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# elaborate on this:

OpenFGA fetches Dex's discovery doc + JWKS once at startup

# (coreos/go-oidc) and does not reliably refresh on an unknown `kid`. After a

# Dex key rotation, tokens minted by Dex are signed with a `kid` that OpenFGA's

# cached keyset does not know, so every `Check` returns

# `{"code":"invalid_claims","message":"invalid claims"}` (HTTP 401) — which the

# libcloud REST API surfaces as `authz_fga_error` (HTTP 503). Restarting

# OpenFGA forces a fresh JWKS fetch and clears the stale cache.

OpenFGA is caching Dex’s OpenID Connect metadata and JWKS at process start and never doing a “kid‑miss → refetch JWKS” path, so after Dex rotates its signing key, OpenFGA continues to validate tokens against a stale keyset and rejects every request with “invalid_claims” until you restart it and force a fresh JWKS pull.[^1_1][^1_2][^1_3][^1_4]

Below I’ll unpack the moving parts and the failure mode in more detail.

## Actors and moving parts

- Dex is your OpenID Connect provider; it exposes:
    - A discovery document (issuer metadata, endpoints, JWKS URI, etc.).[^1_5][^1_4]
    - A JWKS endpoint with the current public keys used to sign ID/Access tokens (each key has a `kid`).[^1_4]
- OpenFGA is using `coreos/go-oidc` to talk to Dex:
    - It creates an `oidc.Provider` at startup, which internally constructs a `remoteKeySet` bound to the discovery/JWKS endpoints.[^1_2][^1_1]
    - `remoteKeySet` fetches the JWKS document once and caches the keys in memory; verification calls look up keys by `kid` in this cache.[^1_3][^1_2]

So at time $t_0$, OpenFGA starts up, calls Dex’s discovery URL, obtains the JWKS, and freezes that set in its process-local cache.[^1_1][^1_2]

## What happens during Dex key rotation

Dex supports rotation of its signing keys, where it retires the old key and begins signing new tokens with a new key whose `kid` was not previously present.[^1_5][^1_4]

Timeline:

1. Before rotation:
    - Dex’s JWKS contains key $K_1$ with `kid = kid1`.[^1_4]
    - OpenFGA’s cached JWKS contains the same $K_1$; all tokens signed with `kid1` validate correctly.[^1_2][^1_1]
2. Dex rotates keys:
    - Dex starts using a new key $K_2$ with `kid = kid2` to sign fresh tokens; old key $K_1$ may be removed from JWKS or marked inactive.[^1_5][^1_4]
    - The JWKS endpoint now returns $K_2$ (and maybe others), but OpenFGA does not automatically refetch it.[^1_3][^1_2]
3. After rotation:
    - Clients call OpenFGA with bearer tokens minted by Dex; each token’s header has `kid = kid2`.
    - `coreos/go-oidc` / `remoteKeySet` inside OpenFGA looks up `kid2` in its cached keyset, finds nothing, and treats the token as invalid instead of triggering a JWKS refresh.[^1_2][^1_3]

Many JWT libraries implement “on kid miss, refetch JWKS” with some rate limiting.[^1_6][^1_7]
In this OpenFGA + `go-oidc` path, that behavior effectively isn’t happening, so a rotation is indistinguishable from “all tokens are bad” until someone restarts OpenFGA.[^1_3][^1_2]

## Error propagation: invalid_claims → authz_fga_error

At the crypto / OIDC layer:

- Verification fails because no key in the cached JWKS matches the `kid` referenced by the token, or the signature cannot be validated with any cached key.[^1_2]
- `go-oidc` bubbles this up as a validation error, which OpenFGA normalizes to something like `{"code":"invalid_claims","message":"invalid claims"}` and responds with HTTP 401.[^1_1]

At your libcloud REST API layer:

- libcloud is delegating authorization checks to OpenFGA (e.g., “is principal X allowed to perform Y on resource Z?”).
- When OpenFGA returns an authz error due to token validation failure instead of a logical “deny”, the libcloud API surfaces this as `authz_fga_error` and, in your description, maps it to HTTP 503 to signal an upstream authorization service failure.[^1_1]

So from the client’s perspective, nothing changed except Dex rotated its keys; suddenly every authorization check fails with a 503, even though the tokens themselves are valid with respect to Dex’s current JWKS.[^1_4][^1_5]

## Why restart fixes it (but is brittle)

Restarting OpenFGA forces it to:

- Recreate the `oidc.Provider` and `remoteKeySet` with a fresh HTTP call to Dex’s discovery document and JWKS endpoint.[^1_1][^1_2]
- Load the current keyset containing $K_2$ and `kid2`; subsequent tokens verify correctly and `Check` calls succeed again.[^1_4][^1_2]

The core issue is:

- JWKS caching is “static at startup” with no strategy for:
    - Periodic refresh (e.g., TTL-based), and/or
    - Reactive refresh on unknown `kid` with backoff / rate limiting.[^1_7][^1_6]

That makes key rotation an operationally visible event requiring an OpenFGA rollout, which is the opposite of what you want from an IdP rotation story.

## Architectural implications and mitigations

High‑level implications:

- Availability: Dex emergency key rotations (e.g., after a compromise) will break all OpenFGA-based authz until you restart OpenFGA.[^1_6][^1_7]
- Security posture: You’re incentivized *not* to rotate Dex keys frequently because it triggers outages, which is a bad trade-off in a secure environment.[^1_5][^1_4]

Mitigation directions (conceptual, irrespective of OpenFGA’s current implementation):

- Implement “kid‑miss → JWKS refetch” logic with:
    - Circuit breaker / backoff to avoid abuse with random `kid`s.[^1_7][^1_6]
    - A small cache TTL so keys naturally refresh even without rotation.
- Allow operator configuration:
    - Max JWKS age, refresh interval, and unknown‑kid behavior.
- For immediate ops workaround:
    - Monitor Dex key sets and pre‑coordinate rotations with controlled OpenFGA restarts; crude but at least explicit.

If you want, I can walk through a concrete design sketch for a robust JWKS cache (with pseudo‑Go code and backoff behavior) that would handle Dex rotations safely without restarts.
<span style="display:none">[^1_10][^1_8][^1_9]</span>

<div align="center">⁂</div>

[^1_1]: https://github.com/openfga/openfga

[^1_2]: https://chromium.googlesource.com/external/github.com/coreos/go-oidc/+/a93f71fdfe73d2c0f5413c0565eea0af6523a6df/jwks.go

[^1_3]: https://github.com/coreos/go-oidc/issues/339

[^1_4]: https://dexidp.io/docs/configuration/tokens/

[^1_5]: https://github.com/dexidp/dex/blob/master/server/rotation.go

[^1_6]: https://community.auth0.com/t/caching-jwks-signing-key/17654

[^1_7]: https://github.com/istio/istio/issues/49044

[^1_8]: https://www.okta.com/sites/default/files/2022-06/OpenFGA_Docs.pdf

[^1_9]: https://openfga.dev/docs/getting-started/framework

[^1_10]: https://openfga.dev/docs/concepts


---

# what is "kid-miss"?

“kid‑miss” is shorthand for the situation where a JWT’s `kid` header value does not match any key in the verifier’s current JWKS cache, so the verifier can’t find a public key to use for signature verification and the check fails.[^2_1][^2_2][^2_3]

## `kid` in JWTs

- `kid` (key ID) is a header field in a JWT that identifies which signing key was used.[^2_4][^2_2][^2_3][^2_1]
- When an issuer publishes a JSON Web Key Set (JWKS), each key in the set typically has a `kid`; the verifier matches the token’s `kid` to one of these keys to validate the signature.[^2_2][^2_3][^2_1]

Example JWT header:

```json
{
  "alg": "RS256",
  "kid": "key-2026-07"
}
```

Here `"key-2026-07"` tells the verifier which key in the JWKS to use.[^2_3][^2_1]

## What “kid‑miss” means operationally

- A “kid‑miss” occurs when the token carries a `kid` (say `kid = key-2026-07`) that is *not present* in the verifier’s JWKS cache or key store.[^2_1][^2_2]
- Common reasons:
    - The issuer rotated keys and started using a new `kid`, but the verifier hasn’t refreshed its JWKS yet.[^2_2][^2_1]
    - Misconfiguration: token issued by the wrong issuer or pointing to an unexpected key set.[^2_5][^2_1]

In robust implementations, a kid‑miss is usually a trigger to refetch JWKS (with rate limiting) or to fail closed; in your OpenFGA/Dex scenario, it fails closed (invalid claims) without doing the refresh, which is why you see outages after key rotation until you restart OpenFGA.[^2_6][^2_7][^2_1]

Would you like a sketch of how you’d implement safe “kid‑miss → JWKS refresh with backoff” logic in Go for an authz service like OpenFGA?
<span style="display:none">[^2_10][^2_11][^2_12][^2_8][^2_9]</span>

<div align="center">⁂</div>

[^2_1]: https://nhimg.org/glossary/kid/

[^2_2]: https://blog.csdn.net/2401_85480529/article/details/142261283

[^2_3]: https://mojoauth.com/glossary/jwt-key-id

[^2_4]: https://stackoverflow.com/questions/43867440/whats-the-meaning-of-the-kid-claim-in-a-jwt-token

[^2_5]: https://docs.cycubix.com/application-security-series/web-application-security-essentials/solutions/a7-2021-or-identity-and-authentication-failure-or-cycubix-docs/a7-2021-or-jwt-tokens-or-cycubix-docs/a7-2021-or-jwt-tokens-17-or-cycubix-docs

[^2_6]: https://community.auth0.com/t/caching-jwks-signing-key/17654

[^2_7]: https://github.com/istio/istio/issues/49044

[^2_8]: https://dev.to/ssojet/jwt-kid-header-missing-what-it-means-and-how-to-fix-it-fast-3cgl

[^2_9]: https://community.auth0.com/t/what-is-the-origin-of-the-kid-claim-in-the-jwt/8431

[^2_10]: https://learn.microsoft.com/en-my/answers/questions/5497395/validate-a-jwt-without-a-kid-claim-with-the-valida

[^2_11]: https://community.auth0.com/t/idtoken-generated-by-impersonation-does-not-contains-kid-property/21232

[^2_12]: https://github.com/gravitational/teleport/issues/44245


---

# explain issuer?  and how it comes about in the overall flow.

The issuer is the entity (identity provider or auth server) that *creates and signs* the JWT; the `iss` claim in the token identifies that entity, and verifiers use it to decide whether they should trust and attempt to validate the token at all.[^3_1][^3_2][^3_3][^3_4][^3_5]

## What “issuer” means in JWT/OIDC

- In JWT, the `iss` (issuer) claim is a string identifying the party that issued the token (e.g. your Dex server or another IdP).[^3_2][^3_3][^3_6][^3_5][^3_1]
- It’s typically a URL-like identifier (for OIDC, the issuer is the base URL that hosts the discovery document) but can be any unique string your system agrees on.[^3_7][^3_6][^3_8]
- Verifiers should check that `iss` equals one of their configured “trusted issuers”; if it doesn’t match, the token is rejected even before looking at keys.[^3_6][^3_5][^3_1][^3_2]

So in your Dex/OpenFGA setup, Dex is the issuer; its base URL appears as `iss` in tokens, and OpenFGA is configured to only accept that `iss`.[^3_8][^3_5][^3_6]

## How the issuer fits into the overall flow

Consider a typical OIDC/JWT auth flow with Dex and OpenFGA:

1. **Client authenticates with the issuer (Dex)**
    - A user or service calls Dex (e.g. via OIDC authorization code or client credentials).
    - Dex, acting as the issuer, generates a JWT, signs it with its private key, and sets `iss` to its issuer identifier URL.[^3_3][^3_4][^3_9][^3_6]
2. **Client calls your services with the JWT**
    - The client includes the JWT as a bearer token when calling your resource APIs or OpenFGA.[^3_9][^3_10][^3_5]
3. **Verifier identifies the issuer and metadata**
    - Your service (or OpenFGA) decodes the JWT, reads `iss`, and maps it to a configured issuer entry.[^3_5][^3_6][^3_8]
    - For OIDC, this issuer URL determines which discovery document (`/.well-known/openid-configuration`) and JWKS endpoint to use to fetch public keys and other metadata.[^3_4][^3_9][^3_8][^3_5]
4. **Verifier fetches / caches issuer’s keys**
    - Using the issuer’s discovery doc, the verifier finds the JWKS URL and pulls the public keys corresponding to that issuer.[^3_4][^3_9][^3_8][^3_5]
    - It caches these keys and uses the token’s `kid` to pick the right key for signature validation.[^3_10][^3_9][^3_5]
5. **Validation and trust decision**
    - The verifier checks:
        - `iss` matches the expected issuer.[^3_1][^3_2][^3_6][^3_5]
        - Signature verifies with a key belonging to that issuer.[^3_10][^3_5][^3_4]
        - Other claims (audience, expiry, etc.) are valid.[^3_11][^3_12][^3_5]
    - Only then does it accept the token and continue with authorization logic.

In other words:

- `iss` tells *which IdP* this token belongs to.
- `kid` tells *which key* from that issuer’s JWKS to use.
- The issuer string determines which discovery/JWKS endpoints OpenFGA talks to; the kid then drives which entry in that JWKS cache is used.[^3_9][^3_8][^3_5][^3_4]


## Why issuer matters for multi‑tenant / multi‑IdP systems

In more complex setups:

- Different tenants or environments may have different issuers (e.g. multiple Dex instances, external IdPs).[^3_13][^3_6][^3_10]
- Your verifier (OpenFGA, API gateway, etc.) typically keeps a list of trusted issuers and, for each, a mapping to the correct discovery and JWKS endpoints.[^3_6][^3_8][^3_5]
- If a token arrives with an `iss` that is not in that trusted set, it’s rejected early: you don’t even bother doing a JWKS fetch or signature check.[^3_2][^3_5][^3_1][^3_6]

In your Dex/OpenFGA flow, think of “issuer” as the anchor that:

- Selects the right IdP metadata (discovery/JWKS).
- Ensures you only validate tokens from a source you explicitly trust.

Do you have multiple issuers (e.g. several Dex instances or external IdPs) in your environment, or is everything currently coming from a single Dex deployment?
<span style="display:none">[^3_14][^3_15]</span>

<div align="center">⁂</div>

[^3_1]: https://mojoauth.com/glossary/jwt-issuer

[^3_2]: https://stackoverflow.com/questions/68818485/what-is-a-jwt-issuer

[^3_3]: https://mojoauth.com/blog/understanding-jwt-issuer-detailed-guide

[^3_4]: https://datatracker.ietf.org/doc/html/rfc7519

[^3_5]: https://jwt.io/introduction

[^3_6]: https://stackoverflow.com/questions/69229596/differences-between-audience-issuer-and-client-terms-in-jwt-oauth-and-oidc/69231448

[^3_7]: https://www.ibm.com/docs/en/webmethods-integration/webmethods-deployer/12.1.0?topic=values-jwt-issuer

[^3_8]: https://www.cnblogs.com/stulzq/p/10339024.html

[^3_9]: https://trstringer.com/jwt-authz-identity-provider-flow/

[^3_10]: https://www.loginradius.com/blog/engineering/guide-to-jwt

[^3_11]: https://jwtdecode.app/jwt-claims-explained

[^3_12]: https://blog.postman.com/what-is-jwt/

[^3_13]: https://openillumi.com/en/en-jwt-issuer-audience-client-diff/

[^3_14]: https://www.youtube.com/watch?v=RWedxdSRrjk

[^3_15]: https://www.youtube.com/watch?v=AfNN_J1tFxw

right now every time after the Dex has rotated its keys, how is the OpenFGA refresh automatically?                                                           
                                                                                                                                                               
  Short answer: OpenFGA does not refresh automatically. There is no built-in JWKS refresh in OpenFGA in this repo. The "automatic" refresh you see is a
  side-effect of a script-driven container restart.

  What actually happens

  1. The 6h rotation lives in Dex, not OpenFGA. Dex is configured with storage: type: memory, which rotates its OIDC signing keys every 6 hours. OpenFGA is
  just a consumer of Dex's JWKS.

  2. OpenFGA caches JWKS once at startup. It uses coreos/go-oidc, which builds a remoteKeySet from Dex's discovery doc on first use and does not do a
  "kid-miss → refetch JWKS" path. So after Dex rotates, tokens carry a new kid that OpenFGA's in-memory cache doesn't know, and every Check returns
  {"code":"invalid_claims","message":"invalid claims"} (HTTP 401) — surfaced by the libcloud REST API as authz_fga_error (HTTP 503).

  3. The only "refresh" is a container restart. openfga_ensure_fresh.sh restarts the openfga container so it re-fetches Dex's JWKS on startup. It is called
  lazily from scripts/common.sh before any Check:

   openfga_postgres/scripts/common.sh lines 46-53

  # Ensure OpenFGA's cached Dex JWKS is fresh before any Check. Dex rotates its
  # OIDC signing keys every 6h (storage: memory); a stale OpenFGA keyset makes
  # every Check fail with `invalid_claims`. Throttled + skippable; no-op when
  # already refreshed recently (e.g. by a myrun_* script). Set OPENFGA_SKIP_RESTART=1
  # to disable.
  if [[ "${OPENFGA_SKIP_RESTART:-0}" != "1" ]]; then
    bash "${SCRIPT_DIR}/openfga_ensure_fresh.sh" >/dev/null 2>&1 || true
  fi

  The restart is throttled by a marker file generated/.openfga_jwks_refreshed_at with a default TTL of 3600s, so repeated script invocations within an hour
  don't hammer the container.

  Important caveats

  • It is not truly automatic / proactive. There is no cron, timer, or watcher. The refresh only happens when some script that sources common.sh runs. If
    nothing runs after a Dex rotation, OpenFGA stays stale until the next script invocation (or until a Check already fails — note the restart is done
    before the Check, so the first stale request is the trigger, not a victim, in the scripted flow; but any out-of-band caller hitting OpenFGA directly
    would get invalid_claims).
  • Env knobs (in openfga_ensure_fresh.sh):
    • OPENFGA_SKIP_RESTART=1 — disable entirely
    • OPENFGA_FORCE_RESTART=1 — force restart ignoring the throttle
    • OPENFGA_JWKS_REFRESH_TTL_SEC — throttle window (default 3600)
    • OPENFGA_CONTAINER — container name (default openfga)
  • Contrast with the libcloud REST API side, which does handle rotation gracefully. libcloud.rest/app/auth/oidc_service.py uses PyJWT's PyJWKClient,
    whose get_signing_key_from_jwt refetches the JWKS on a kid miss — so the REST API does not need a restart after Dex rotation. Only OpenFGA
    (Go/go-oidc) has the stale-cache problem.

  So: the "automatic refresh" is really a lazy, on-demand restart workaround triggered by the next provisioning script run, not a genuine JWKS refresh
  mechanism. If you want true automatic refresh, the options are (a) a periodic scheduler that calls openfga_ensure_fresh.sh (e.g. a cron/systemd timer at
  <6h cadence), (b) OPENFGA_FORCE_RESTART=1 coordinated with Dex rotations, or (c) moving off in-memory Dex storage so keys persist and rotations are
  graceful. Want me to sketch a small cron/timer that proactively restarts OpenFGA before the 6h window expires?





==============

current problem:


                                                                                                                                                            
  supposed at t=0, the Dex just rotated its key, and generated/.openfga_jwks_refreshed_at indicated that the OpenFGA was refresh at t-10, and with with        
  TTL 3600, OpenFGA will not be restarted again. and so OpenFGA are still using the stale key. what happened after this?                                       
                                                                                                                                                               

  $ ls /home/ubuntu/libcloud_nutanix/generated/ 2>/dev/null; echo "---"; ls /home/ubuntu/libcloud_nutanix/openfga_my/ 2>/dev/null 2.4s
    … 14 output lines hidden · ctrl+o to expand
    setup.sh
    vault_bootstrap.py

    Grepped, read 2 greps, 2 files
    Grepped "openfga_jwks_refreshed_at" in .
    Read system_design/dex_6hour_cycle.md
    Read test_script/scripts/openfga_ensure_fresh.sh
    Grepped "authz_fga_error|invalid_claims" in libcloud.rest

  Here's what happens, traced through the code in this repo.

  The setup at t=0

  • Dex rotates its OIDC signing key at t=0 (its 6h storage: memory rotation). From now on every token Dex mints is signed with a new kid.
  • The marker generated/.openfga_jwks_refreshed_at has mtime t-10, i.e. OpenFGA was last restarted 10s before the rotation. At that restart it fetched
    Dex's JWKS and cached the old kid (the rotation hadn't happened yet).
  • OPENFGA_JWKS_REFRESH_TTL_SEC defaults to 3600.

  Why OpenFGA does NOT get restarted

  openfga_ensure_fresh.sh only decides freshness by the marker's age, not by comparing keys against Dex:

   openfga_my/scripts/openfga_ensure_fresh.sh lines 53-61

  # Throttle: skip if we refreshed within TTL_SEC, unless forced.
  mkdir -p "$(dirname "${MARKER}")"
  if [[ "${OPENFGA_FORCE_RESTART:-0}" != "1" && -f "${MARKER}" ]]; then
    now=$(date +%s); mtime=$(stat -c %Y "${MARKER}" 2>/dev/null || stat -f %m "${MARKER}" 2>/dev/null)
    if [[ -n "${mtime:-}" ]] && (( now - mtime < TTL_SEC )); then
      _log "last refresh < ${TTL_SEC}s ago — skipping restart (set OPENFGA_FORCE_RESTART=1 to force)."
      exit 0
    fi
  fi

  At t=0, now - mtime = 10 < 3600, so the throttle fires and the script exits 0 without restarting. OpenFGA keeps its stale keyset (old kid only). This is
  the core gap: the marker says "fresh" purely by clock time, but the cached JWKS is already stale relative to Dex's just-rotated key.

  What happens on the next request

  common.sh calls openfga_ensure_fresh.sh before any Check, but it no-ops (throttled). The flow then is:

  1. Client authenticates with Dex → gets a JWT signed with the new kid.
  2. libcloud REST forwards that bearer to OpenFGA's /stores/{id}/check (fga_client.py).
  3. OpenFGA (coreos/go-oidc) tries to verify the JWT against its cached keyset. The kid is unknown, and go-oidc does not reliably refresh on unknown kid.
  4. Signature/claims verification fails → OpenFGA returns {"code":"invalid_claims","message":"invalid claims"} (HTTP 401).
  5. fga_client.py catches the HTTPError and raises authz_fga_error (HTTP 503):

   libcloud.rest/app/auth/fga_client.py lines 53-59

              detail = exc.read().decode("utf-8", errors="replace")
              log.error("OpenFGA check failed: %s", detail)
              raise APIError(
                  code="authz_fga_error",
                  message="OpenFGA authorization check failed",
                  status_code=503,
                  details={"relation": relation, "object": obj, "detail": detail},

  So every authorized endpoint starts returning 503 authz_fga_error with invalid_claims in the details — even though the user is legitimately authenticated
  and the tuples are correct. This is a pure key-cache desync, not an authorization denial (that would be authz_fga_denied 403).

  How long it lasts

  The outage persists until the marker becomes older than the TTL. The marker was written at t-10, so the next eligible automatic restart is at:

  (t - 10) + 3600 = t + 3590s   ≈ 59.8 minutes after the rotation

  From t=0 to ~t+3590, every Check fails with authz_fga_error / 503. At t+3590 the next script invocation finally passes the throttle, restarts the
  container, waits on /healthz, rewrites the marker, and OpenFGA re-fetches Dex's JWKS with the new kid — checks then succeed again.

  Ways to recover sooner

  Because the throttle is the only thing holding back the restart, any of these clears it immediately:

  • OPENFGA_FORCE_RESTART=1 — bypasses the marker check (line 55) and forces a restart on the next common.sh invocation.
  • docker restart openfga manually, then date +%s > generated/.openfga_jwks_refreshed_at to update the marker (otherwise the next throttled call may
    restart again needlessly).
  • Lower OPENFGA_JWKS_REFRESH_TTL_SEC so the window is shorter than Dex's 6h rotation cadence (note: 3600s < 6h already, but the alignment matters — see
    below).

  The underlying design flaw this exposes

  The throttle is time-based and keyed to "when did we last restart," not "did Dex's keys actually change." Because the marker was written at t-10 (just
  before a rotation), the 3600s window covers the rotation event entirely, so the cache goes stale with no self-healing until the window expires. A rotation
  that lands just after a refresh creates the longest blind spot (~TTL of failures); a rotation that lands just before a refresh is harmless. The
  mitigation is only robust if the TTL is short relative to the rotation interval and refreshes are staggered away from rotation boundaries — or if the
  freshness check actually compared the cached kid set against Dex's current JWKS rather than trusting a timestamp.


