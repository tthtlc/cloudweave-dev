
what are the consequences of running each of the following secret rotation operation: 

  scripts/chain-presharedkey-rotate.sh                                   
  scripts/lldap-admin-cred-rotate.sh                                                                                                                           
  scripts/openfga-presharedkey-rotate.sh                                                                                                                       
  scripts/vault-root-cred-rotate.sh                                                                                                                            
  scripts/vault-static-secret-rotate.sh                                                                                                                        
                                                                                                                                                               
  Here are the consequences of running each rotation script. All five are idempotent-ish, write to an audit log, and refuse to do destructive work without
  explicit flags.

  scripts/chain-presharedkey-rotate.sh

  This is the orchestrator. It delegates the actual rotation to openfga-presharedkey-rotate.sh and then runs a smoke-test.

  • Without --apply: only stages — writes the new key to Vault and updates env files, prints restart instructions, skips the smoke-test. No service
    disruption.
  • With --apply: rotates the key, then does a rolling restart of the openfga + libcloud-rest-api containers (brief downtime while each restarts), then
    runs openfga-check.sh against a representative tuple (user:superadmin can_connect libcloud_api:main by default) to confirm the REST→OpenFGA authz path
    works with the new key.
  • Failure modes:
    • Exit 3 = the underlying rotate step failed; nothing is activated.
    • Exit 4 = smoke-test failed after rotation — this is the worst case: the key was already rotated and containers restarted, but the authz path is
      broken. The REST API will be failing live calls until you fix it.
  • Side effects: writes generated/chain_audit.log; reloads ../libcloud.rest/.env to pick up the new FGA_API_TOKEN for the smoke-test.

  scripts/openfga-presharedkey-rotate.sh

  Rotates the OpenFGA preshared API key — the credential the libcloud REST uses to call OpenFGA (FGA_API_TOKEN), which is also an accepted
  OPENFGA_AUTHN_PRESHARED_KEYS value alongside the OIDC/Dex JWT path.

  • Generates a new 32-byte hex key, writes it to Vault at secret/data/openfga/apikey, read-back verifies it, then rewrites FGA_API_TOKEN in
    ../libcloud.rest/.env and OPENFGA_AUTHN_PRESHARED_KEYS in ../openfga/.env.
  • Without --apply: stops after Vault + env updates. Prints restart instructions. The new key is stored but not live — old key still works until restart.
  • With --apply: docker restart libcloud-rest-api and docker restart openfga, then probes /v1/auth/me and OpenFGA /healthz. Brief downtime on both
    services.
  • Risk: between restarting the REST container and restarting OpenFGA, or if only one side picks up the new key, OpenFGA will reject the REST API's calls
    (401s) because the two sides must agree. The chain script's smoke-test catches this.
  • --dry-run prints the would-be key and exits without touching Vault.

  scripts/lldap-admin-cred-rotate.sh

  Rotates the LLDAP admin bind password. Notably, it updates LLDAP first and verifies before persisting to Vault, so Vault never holds an unverified
  password.

  • Generates a 32-char alphanumeric password.
  • Binds to LLDAP as admin with the old password and LDAP-modifies the admin's own userPassword (LLDAP hashes server-side).
  • Verifies by logging in to ${LLDAP_URL}/auth/simple/login with the new password.
  • On success: writes secret/data/lldap/admin (KV v2) and rewrites ../lldap/.env's LLDAP_LDAP_USER_PASS (unless --no-update-env).
  • Consequences of partial failure:
    • Exit 5 = the password WAS changed in LLDAP but verify failed and Vault/.env were NOT updated — you now have an admin password nobody can recover
      unless you can still see it in the script's process environment. This is the dangerous middle state.
    • Exit 6 = LLDAP rotated + verified, but Vault write failed — LLDAP is fine, Vault is stale.
    • Exit 7 = Vault updated but .env rewrite failed — host-side scripts that source .env will keep using the old (now-invalid) password and start failing
      bind operations.
  • Requires VAULT_ROOT_TOKEN (env or ../vault/generated/vault.env) and a current LLDAP_LDAP_USER_PASS; refuses otherwise (exit 2).
  • After success, any other client still using the old admin bind password (other than scripts sourcing .env) will break until updated.
  • --print-password echoes the new password to stdout once (otherwise it lives only in Vault + .env).

  scripts/vault-root-cred-rotate.sh

  Rotates the root credential of a cloud secrets engine (e.g. aws, gcp) via POST /<mount>/config/rotate-root. This is the most consequential of the five.

  • One-way operation: after rotation, Vault holds the ONLY copy of the new root credential. The previous root credential you supplied at enable time
    becomes invalid at the cloud provider immediately.
  • Refuses to run without --confirm (or --dry-run). Pre-flight checks the mount exists in /sys/mounts.
  • Recommended cadence per the header: quarterly per provider.
  • Consequences:
    • Anything outside Vault that still uses the old root credential (cloud consoles, other automation, backups) stops working.
    • If Vault is later lost/unsealed-irrecoverable, you lose the root credential entirely with no recovery path unless you saved a copy outside Vault
      (which the script explicitly warns against relying on without).
    • Does not affect any already-issued dynamic leases or static secrets stored in KV — only the engine's root config.
  • --dry-run validates the mount and logs intent without calling rotate-root.

  scripts/vault-static-secret-rotate.sh

  Rotates a static secret in Vault KV v2 (e.g. a SaaS API key, DB password, service-account token with no dynamic engine).

  • Generates --length (default 32) random bytes, URL-safe base64, writes to <path> under field --key (default value), with rotated_at / rotated_by
    metadata.
  • Old value is preserved as the prior KV version — rollback is vault kv undelete / version pinning (out of scope for the script).
  • Optional --hook <script> registers the new value with the upstream provider. Two ordering modes:
    • Default (hook-first): hook runs before Vault is written. If the hook fails (exit 5), Vault is NOT updated — the old value stays live, so no consumer
      is disrupted. Safe.
    • --write-first: Vault is updated first, then the hook runs. If the hook fails (exit 6), Vault has the new value but the upstream provider still has 
      the old one — consumers reading from Vault will start using a value the provider doesn't recognize. This is the inconsistent-state risk; use only
      when the hook is best-effort/idempotent.
  • The hook receives the new value on stdin and any --hook-arg values as argv; non-zero exit aborts.
  • Path normalization accepts secret/foo, secret/data/foo, or foo.
  • This script does not restart any service — consumers that cached the old value won't pick up the new one until they re-read Vault. That's a
    consequence to plan for, not something the script handles.
  • --dry-run logs intent without writing.

  ────────────────────────────────────────

  Cross-cutting notes

  • All five append JSON lines to an audit log (generated/chain_audit.log, lldap's audit log, vault's audit log) with actor/timestamp/result.
  • Two scripts cause live service disruption: openfga-presharedkey-rotate.sh --apply and chain-presharedkey-rotate.sh --apply (both restart containers).
  • Two are one-way / externally-visible: vault-root-cred-rotate.sh (old cloud root dies instantly) and lldap-admin-cred-rotate.sh (old admin password
    dies the moment the LDAP modify succeeds, before Vault persistence).
  • vault-static-secret-rotate.sh is the only one with a built-in rollback path (KV version history), and even that doesn't restart consumers.

                                                                                                                                                               
  what does "Two scripts cause live service disruption" mean? does it mean any of the password are invalidated, or any docker/server need to be                
  restarted? and are they done automatically after rotation? ie, emphasize on the details of what need to be done next if necessary or nothing?                
                                                                                                                                                               

  Good question — let me be precise. "Live service disruption" specifically means containers are restarted as part of running the script, which causes a
  brief window where that service is unavailable. It does not, by itself, mean passwords are invalidated; the restart is the disruption.

  Let me clarify each of the two:

  openfga-presharedkey-rotate.sh (and chain-presharedkey-rotate.sh, which calls it)

  What gets invalidated: the old preshared key stops being accepted by OpenFGA the moment OpenFGA reloads its config. The new key is what the REST API must
  use.

  What gets restarted, and when:
  • Without --apply: the script writes the new key to Vault and edits ../libcloud.rest/.env (FGA_API_TOKEN) and ../openfga/.env
    (OPENFGA_AUTHN_PRESHARED_KEYS), then stops. It prints the restart commands but does not run them. In this state:
    • Nothing is disrupted yet. The old key still works because nothing has reloaded.
    • What you must do next: run the two docker compose ... restart commands it prints (or re-run the script with --apply). Until you do, the rotation is
      staged but inactive. There's no urgency — the old key is still valid.
  • With --apply: the script automatically runs docker restart libcloud-rest-api and docker restart openfga, waits ~5s, and probes /v1/auth/me and OpenFGA
    /healthz. Nothing further is required from you — the rotation is fully activated by the script itself. The chain script additionally runs the
    smoke-test automatically.

  The actual disruption: a few seconds of downtime on each container while it restarts. The real risk isn't the downtime, it's that the two sides must agree
  on the key — if the REST container comes up with the new FGA_API_TOKEN but OpenFGA hasn't reloaded OPENFGA_AUTHN_PRESHARED_KEYS yet (or vice versa),
  OpenFGA returns 401 to the REST API. The chain script's smoke-test exists to catch exactly this.

  If --apply succeeds: nothing more to do.
  If the chain smoke-test fails (exit 4): this is the case where you must intervene — the key is rotated and containers are restarted but the authz path is
  broken. You'd debug why the two sides disagree (env file not picked up, container didn't actually reload config, wrong Vault path, etc.) and re-restart
  the offending side.

  Contrast with the scripts that do NOT auto-restart

  The other three rotate credentials but do not restart anything automatically, and whether you need to do something next depends on the credential:

  • lldap-admin-cred-rotate.sh: the password change in LLDAP is immediate (LDAP modify succeeds → old password is dead right then). The script then
    persists to Vault + .env for you. What's left: any other client that still binds with the old admin password (outside the scripts that source
    ../lldap/.env) will start failing immediately and you must update those manually. The scripts themselves are handled for you.
  • vault-root-cred-rotate.sh: rotation at the cloud provider is immediate and one-way. Vault now holds the only copy. What's left: anything outside Vault
    using the old cloud root credential is now broken and you must re-key it from Vault, or accept Vault as sole custodian. No restart needed.
  • vault-static-secret-rotate.sh: writes the new value to Vault. What's left: consumers that read this secret will only pick up the new value on their
    next Vault read — anything that cached it (long-lived process, app that loads secrets at startup) keeps using the old value and you must
    restart/reload those yourself. The script does not know about them.

  Direct answer to your three sub-questions

  1. "Does it mean any passwords are invalidated?" — Not by the restart itself. In the OpenFGA case, the old preshared key is invalidated, but that
     happens because OpenFGA reloads its config (which the restart triggers), not because of the restart as a general mechanism. The restart is the
     "disruption"; the invalidation is the point of the rotation.

  2. "Does any docker/server need to be restarted?" — Only the two OpenFGA-key scripts restart containers, and only with --apply. The other three never
     restart anything.

  3. "Are they done automatically after rotation?" — Yes, but only for openfga-presharedkey-rotate.sh --apply / chain-presharedkey-rotate.sh --apply:
     those restart both containers and verify health automatically, so nothing further is needed on success. Without --apply, the script does the Vault +
     env edits and leaves the restart to you (it prints the exact commands). For lldap, vault-root, and vault-static-secret, no restart is done or needed
     by the script — but external consumers of those credentials may need manual updates/restarts, as noted above.


