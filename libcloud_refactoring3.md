
                                                                                                                                                              
  what are the outstanding TODOs task in Dex, Identity services, OpenFGA, Vault, and libcloud.rest still exists? And reading libcloud_refactoring.md and       
  libcloud_refactoring2.md what are the duplicated tasks that still have to be address.                                                                        
                                                                                                                                                               

  I'll search for TODOs across the services and read the two refactoring docs in parallel.

    Grepped, read 5 greps, 2 files
    … 4 earlier items hidden
    Grepped "TODO|FIXME|XXX|HACK" in libcloud.rest
    Read libcloud_refactoring.md
    Read libcloud_refactoring2.md

  Let me get more context on the identity_service TODOs and check the README's stubbed list.

    Read 4 files
    Read identity_service/README.md
    Read identity_service/app/main.py lines 180-209
    Read identity_service/app/lldap.py lines 60-79
    Read identity_service/app/users.py lines 60-79

  Here's the consolidated picture.

  Outstanding TODOs by service

  Dex

  • dex/config.yaml:97 — restrict Google connector to org domains via hostedDomains
  • dex/config.yaml:105 — restrict GitHub connector via orgs/teams for group claims
  • Same two TODOs are emitted by the generator at openfga_postgres/dex_bootstrap.py:128,139

  Identity service

  • app/main.py:198 — revoke the Dex refresh token at Dex's revocation endpoint on logout (currently only clears the local session)
  • app/lldap.py:80 — map LLDAP → provider subjects so linkedIdentities survive restarts
  • app/users.py:69 — persist linkedIdentities on the LLDAP user (custom attribute or side table) instead of the in-memory _pending_users registry
  • app/users.py:181 — create the LLDAP user and re-key the OpenFGA tuple onto its uid (the pending int-* → LLDAP uid re-keying step)
  • README.md:82 — session store: move in-memory _refresh_store to Redis for multi-replica
  • (README.md:58 state/PKCE and README.md:75 pending-identity binding are marked done in Path 1)

  OpenFGA

  • No code TODOs in openfga_postgres/ itself. Known operational gap noted in identity_service/README.md:112-118: OpenFGA caches Dex JWKS at startup and
    doesn't refresh on kid rotation, so after a Dex key rotation the REST API's FGA check fails with invalid_claims — workaround is docker restart openfga
    / openfga_ensure_fresh.sh. A real fix (JWKS refresh on unknown kid) is still owed.

  Vault

  • No TODOs found.

  libcloud.rest

  • No code-level TODOs. Only narrative mentions in doc/security_redesign.md (the "update the todos / mark the final todo complete" lines are transcript
    text, not live TODOs).

  Duplicated / outstanding tasks from the two refactoring docs

  From libcloud_refactoring.md (libcloud.rest cleanup + identity refactor)

  • Delete scratch/chat artifacts: doc/tmp.md, doc/conn.md, doc/mylist_ec2.sh, doc/authen/prompt.md, doc/aws_cli_mapping_2_json0.md,
    doc/aws_cli_mapping_2_json2.md, doc/design.md, and repo-root connection.md, error_vs_failure.md
  • Finish the in-progress move of root-level *.dat / *.md.old files into libcloud.rest/doc/ and delete the duplicates (matches the current git status)
  • gitignore build artifacts: .pytest_cache/, __pycache__/, generated/openapi.json, generated/openapi.yaml
  • app/secrets/ is empty placeholder — implement or remove
  • Move doc/nutanix_yaml/*.yaml (~5.5 MB swagger specs) out of repo or into Git LFS
  • Consolidate security docs: ARCHITECTURE.md overlaps with doc/security.md, doc/security_redesign.md, doc/authentication_authorization.md,
    doc/rest_api_summary.md — pick one canonical, archive the rest
  • Add pytest config + CI step so tests/ actually runs on every PR
  • Delete stale openfga_postgres/data/principal_map.json (v1, unused)
  • Move principal→scope/provider tables (PRINCIPAL_SCOPES / PRINCIPAL_PROVIDERS / _role_suffix in app/auth/identity.py) into Dex/LLDAP group claims
  • Delete data/principal_map.json by making Dex's sub (or a custom claim) be the slug, collapsing resolve_principal to a one-liner

  From libcloud_refactoring2.md (cross-component duplication)

  • (B) role_for() fan-out — 5 sequential FGA /check calls per login / list_users; collapse to one /read + local derivation
  • (C) cloud_capabilities() fan-out — 6 FGA /check calls per /api/session GET; same fix
  • (D) Two near-identical OpenFGA HTTP clients — identity_service/app/fga.py and libcloud.rest/app/auth/fga_client.py; extract a shared fga-client
    library
  • (E) Two Dex code-exchange implementations — identity_service/app/dex.py:DexService.exchange_code and app/idp_login.py:ProvisionerAuth._full_login;
    share one Dex token client
  • (F) Provisioner login re-run per cloud — replace human-style LDAP form login with a client-credentials grant or long-lived service token
  • (G) deprovision re-runs the FGA check inside deprovision_<cloud>.sh after identity_service already checked — pick one enforcement point
  • (H) LLDAP on the request-time hot path — identity_service binds LLDAP for collapse/list_users/set_email, breaking the "LLDAP is login-time-only"
    boundary
  • (I) Two sources of truth for user state — in-memory _pending_users vs LLDAP; resolve by finishing the users.py:181 re-keying TODO
  • (J) _shape_resources re-map in libcloud_proxy.py — add a fields= param on the REST side to avoid the portal re-map

  Note on item (A) from refactoring2: the doc itself corrects the original claim — the two OpenFGA checks are not redundant because they evaluate different
  principals (portal user vs. provisioner service account). The real waste is (B), (C), and (G).

  Suggested priority (from the docs' own conclusions)

  1. Collapse (B) + (C) — biggest FGA traffic reduction
  2. Pick one authZ point for (G)
  3. Extract shared fga-client and dex-token-client → kills (D) and (E)
  4. Resolve (I) — finish the LLDAP re-keying TODO (also closes users.py:181)
  5. Reconsider (F) — client-credentials grant for provisioner accounts



                                                                                                                                                               
  → quit                                                                                                                                                       
                                                                                                                                                               

  GLM 5.2 High · 21.5%                                                                                                                          Run Everything
  ~/libcloud_nutanix · main

  To resume this session: agent --resume=67b3a9b1-2785-4f8a-b4c6-a0881dd10a19
