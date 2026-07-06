
reading ../doc/startup_procedure.md, and looking into all the ../*/ARCHITECTURE.md file, now rewrite the procedure to shutdown entire system                 
  gracefully, copy to another new machine, then startup entire system: which docker to startup in sequence, and how ./openfga_my/setup.sh is executed to       
  startup entire system. update any of the shell script if necessary, update ../doc/startup_procedure.md on the startup/shutdown/migrate procedure             
  (including describing in all the different components and its starting procedures).                                                                          
                                                                                                                                                               

  Let me read the existing startup procedure and the master setup.sh to understand the current flow.

    Read 2 files
    Read startup_procedure.md
    Read /home/ubuntu/libcloud_nutanix/openfga_my/setup.sh

  Let me check the OpenFGA and libcloud.rest compose files to confirm datastores and volumes, which determines what survives a migration.

    Read 3 files
    Read .../libcloud_nutanix/openfga_my/docker-compose.yml
    Read ...bcloud_nutanix/libcloud.rest/docker-compose.yml
    Read ...buntu/libcloud_nutanix/lldap/docker-compose.yml

  I have the full picture: 4 persistent volumes (lldap_data, openfga-data sqlite, vault-data, api-data), Dex is in-memory, stoplight_mock is in-memory. The
  existing startup_procedure.md is just a paste of setup.sh output, and there's no shutdown script. Let me make the changes.

  First, an idempotency fix to setup.sh so re-runs (and migration) reuse the existing OIDC client secret instead of regenerating it:

    Edited setup.sh +10

    ▎    docker network create "${SHARED_NET}"
    ▎  fi
    ▎ 
    ▎+ # Reuse the existing OIDC client secret on re-runs / migration so the
    ▎+ # Dex issuer boundary stays stable and previously issued refresh tokens
    ▎+ # (generated/tokens/*.json) keep working. Only generate a new secret if
    ▎+ # neither .env nor an existing generated/dex.env provides one (first boot).
    ▎+ if [[ -z "${LIBCLOUD_OIDC_CLIENT_SECRET:-}" && -f "${DEX_ENV}" ]]; then
    ▎+   LIBCLOUD_OIDC_CLIENT_SECRET=$(grep -E '^LIBCLOUD_OIDC_CLIENT_SECRET=' "${DEX_ENV}" 2>/dev/null | cut -d= -f2- ||  ...
    ▎+   if [[ -n "${LIBCLOUD_OIDC_CLIENT_SECRET}" ]]; then
    ▎+     echo "Reusing existing LIBCLOUD_OIDC_CLIENT_SECRET from ${DEX_ENV}."
    ▎+   fi
    ▎ … truncated (4 more lines) · ctrl+r to review

  Now let me create the graceful shutdown script.

    Edited shutdown.sh +125

    ▎+ #!/usr/bin/env bash
    ▎+ # shutdown.sh — gracefully stop the entire libcloud security stack.
    ▎+ #
    ▎+ # The mirror of ./setup.sh. It stops containers in reverse dependency order
    ▎+ # (consumers first, identity/secret stores last) so in-flight requests drain
    ▎+ # cleanly, and leaves all persistent volumes intact by default so the system
    ▎+ # can be restarted in place with ./setup.sh.
    ▎+ #
    ▎+ # Persistent state that survives this script (kept on Docker named volumes):
    ▎+ #   lldap_data       LLDAP users / groups / custom attributes / admin password
    ▎+ #   openfga-data     OpenFGA sqlite store (stores / models / tuples)
    ▎+ #   vault-data       Vault encrypted secrets + seal state (starts sealed next boot)
    ▎ … truncated (114 more lines) · ctrl+r to review

  $ chmod +x /home/ubuntu/libcloud_nutanix/openfga_my/shutdown.sh && bash -n /home/ubuntu/libcloud_nutanix/openfga_my/shutdown.sh && bash -n
    /home/ubuntu/libcloud_nutanix/openfga_my/setup.sh && echo "syntax OK" 232ms
    syntax OK

  Now let me rewrite the startup procedure document with the full shutdown/migrate/startup procedure.

    Edited startup_procedure.md +349 -316

    ▎+ # Startup / Shutdown / Migrate Procedure
    ▎ 
    ▎- cd openfga_my and
    ▎- run setup.sh (will setup vault and dex)
    ▎+ This document is the operational runbook for the libcloud security stack: how
    ▎+ to **start** the whole system, **shut it down** gracefully, **migrate** it to
    ▎+ a new machine, and what each component does during startup. It replaces the
    ▎+ earlier raw `setup.sh` output paste.
    ▎ 
    ▎- Generated ephemeral LIBCLOUD_OIDC_CLIENT_SECRET (also written to /home/ubuntu/libcloud_nutanix/openfga_my/../dex/ge ...
    ▎- Rendering Dex config (LDAP connector → LLDAP) ...
    ▎- 04:00:11  INFO     Wrote /home/ubuntu/libcloud_nutanix/openfga_my/../dex/config.yaml
    ▎ … truncated (661 more lines) · ctrl+r to review

  Both files are in place. Here's a summary of what I changed.

  Changes

  1. openfga_my/setup.sh — idempotency fix for re-runs and migration

  Before generating a new OIDC client secret, it now first tries to reuse the one already written to generated/dex.env. This means a reboot re-run or a
  migration no longer mints a new LIBCLOUD_OIDC_CLIENT_SECRET (which would force-recreate Dex and invalidate every cached refresh token). Only a true first
  boot generates a fresh secret.

  2. openfga_my/shutdown.sh — new graceful-shutdown orchestrator (mirror of setup.sh)

  Stops containers in reverse dependency order — libcloud-rest-api → openfga → dex → vault → lldap (+ optional stoplight_mock) — so in-flight requests drain
  cleanly. Flags:
  • default: stop everything, keep all volumes + libcloud_net
  • --keep-rest: leave the REST API up, stop only IdP/authz/Vault
  • --purge-network: also remove libcloud_net
  • --wipe: down -v on every project (destroys lldap_data, openfga-data, vault-data, api-data) with a 3 s warning — only for a clean re-bootstrap

  3. doc/startup_procedure.md — full rewrite

  Replaced the raw setup.sh output paste with a real runbook covering:
  • Dependency graph + start/stop order (lldap → dex → openfga → vault → libcloud-rest-api, reverse for shutdown)
  • Startup — the 9-step table of what setup.sh does, the exact by-hand Docker sequence, and per-component startup notes (LLDAP healthcheck-gated
    one-shots, Dex in-memory loses refresh tokens, OpenFGA sqlite reuse + openfga-migrate gating, Vault starts sealed and is re-unsealed from
    generated/vault.env, REST API rebuild)
  • Shutdown — shutdown.sh usage and per-project preserve/loss table
  • Migrate — old-machine shutdown → tar the tree (with the critical-paths table, especially generated/vault.env's VAULT_UNSEAL_KEY) + 4 named-volume
    tarballs → restore on new host → setup.sh (which is migration-aware thanks to the fix above), plus port-change guidance and post-migration
    verification commands
  • Quick-reference command table and the file-dependency table

  The key migration invariant is called out explicitly: the in-container issuer string http://dex:5556/dex is preserved automatically because container
  names on libcloud_net are unchanged, so JWT iss validation keeps working without re-issuing anything.


  To resume this session: agent --resume=e2a098f8-5d45-4fe4-a65c-4470ec9f7682
CW/home/ubuntu/libcloud_nutanix/doc>

