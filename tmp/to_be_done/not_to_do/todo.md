
this statement below need clarification - does it mean the the OpenFGA cannot have multiple IDP or OIDC component talking to the OpenFGA? (ie, can we        
  setup Dex + Authentik (all in OIDC mode) to talk to OpenFGA?:                                                                                                
    • Dex signing keys live in memory (storage.type: memory), so they are not in any volume — setup.sh re-mints them and restarts OpenFGA to flush its         
      cached JWKS (setup.sh:224-231). Already-issued refresh tokens in generated/tokens/*.json will be invalid; users just re-login. The OIDC client           
      secret                                                                                                                                                   
      is reused (kept in dex.env), so the client boundary stays stable.                                                                                        
                                                                                                                                                               

  Good catch — that caveat and the multi-IdP question are actually two different topics. Let me separate them and verify OpenFGA's multi-issuer capability.

    WebSearch OpenFGA multiple OIDC issuers authn-oidc-issuer flag support
    Found 3 references

    Grepped "...suer|authn-oidc-audience|authn-method" in .
    Found 6 matches 

  Two separate things got tangled together. Let me untangle them.

  That caveat was only about Dex's own key lifecycle

  The bullet you quoted says nothing about how many IdPs OpenFGA can talk to. It only describes what happens to Dex's signing keys because Dex runs with
  storage.type: memory:

  • Dex's signing keys are not on any volume, so on a fresh container they are re-minted.
  • OpenFGA's go-oidc client caches the old JWKS and does not auto-refresh on an unknown kid, so setup.sh:224-231 force-restarts OpenFGA to flush that
    cache.
  • Already-issued refresh tokens become invalid; users re-login. The OAuth client secret is reused (kept in dex.env), so the client boundary is stable.

  That's all about one Dex instance rotating its own keys. It does not address multi-IdP at all.

  Can OpenFGA accept tokens from multiple OIDC issuers (Dex + Authentik)?

  Not as two independent issuers each signing their own tokens. OpenFGA's OIDC authenticator validates every JWT against a single JWKS endpoint — the one
  belonging to the primary issuer (--authn-oidc-issuer). It only ever fetches keys from that one issuer.

  OpenFGA does have a --authn-oidc-issuer-aliases flag (added in v1.5.1, confirmed in cmd/run/run.go), but read the fine print from the upstream PR #1354:

  │ "The aliases are acceptable values for token issuer value (iss claim) check. Note: the token validation still relies on the main issuer JWKS."

  So aliases only solve the case where the same IdP is reachable under multiple URLs (e.g. http://dex:5556/dex inside the cluster vs a public DNS name for
  the same Dex). They do not make OpenFGA fetch Authentik's JWKS. A token signed by Authentik's keys would fail signature verification because OpenFGA never
  downloads Authentik's keys.

  This stack is configured for exactly one issuer:

   openfga_postgres/docker-compose.yml lines 90-92

        - --authn-method=${OPENFGA_AUTHN_METHOD:-oidc}
        - --authn-oidc-issuer=${OPENFGA_AUTHN_OIDC_ISSUER:-http://dex:5556/dex}
        - --authn-oidc-audience=${OPENFGA_AUTHN_OIDC_AUDIENCE:-libcloud-rest}

  And the libcloud REST API has the same single-issuer/single-JWKS constraint (OIDC_ISSUER_URL / OIDC_JWKS_URL in libcloud.rest/.env). Both rely on
  aud=libcloud-rest too. So even if OpenFGA alone could accept a second issuer, the gateway in front of it could not.

  The intended way to add Authentik: federate behind Dex

  This is the design the architecture explicitly calls out — Dex is the "stable OIDC front door" (dex/ARCHITECTURE.md §1, and system_design/ARCHITECTURE.md
  §5.4). The pattern is:

  Authentik / Entra / AD  ──(upstream user directory)──►  Dex  ──(OIDC issuer)──►  OpenFGA + libcloud REST

  • Add Authentik as a second Dex connector (type: oidc) — dex/config.phase2.example.yaml already shows this snippet. Merge it into config.yaml on
    cutover.
  • Dex still mints all the tokens, with its own keys, its own iss=http://dex:5556/dex, its own audience libcloud-rest.
  • OpenFGA and libcloud REST keep seeing one issuer, one JWKS, one audience — nothing on their side changes.
  • The user directory moves upstream (Authentik becomes the source of users/groups); you add by_sub entries to data/principal_map.json mapping
    Authentik's object IDs to the stable principal slugs (aws-admin, etc.) so OpenFGA tuples stay unchanged.

  So the precise answer to your question:

  ┌────────────────────────────────────────────────────────────────────────────────┬───────────────────────────────────────────────────────────────────────┐
  │ Scenario                                                                       │ Possible?                                                             │
  ├────────────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────┤
  │ Two independent OIDC issuers (Dex and Authentik) each signing tokens that      │ No — OpenFGA fetches one JWKS; aliases don't add a second key source. │
  │ OpenFGA validates directly                                                     │                                                                       │
  ├────────────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────┤
  │ One OIDC issuer (Dex) that federates to multiple upstream IdPs (LLDAP and      │ Yes — this is the documented Phase 2 path, and it's the supported way │
  │ Authentik) via Dex connectors                                                  │ to bring Authentik in.                                                │
  └────────────────────────────────────────────────────────────────────────────────┴───────────────────────────────────────────────────────────────────────┘

  In short: multiple upstream user directories → yes, via Dex connectors; multiple token-signing OIDC issuers in front of OpenFGA → no. Dex is deliberately
  the single signing boundary so that OpenFGA and libcloud REST only ever have to trust one JWKS.


