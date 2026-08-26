
right now can the openfga_my directory be removed? any dependencies on this directory?                                                                         
                                                                                                                                                                 

  $ ls -la /home/ubuntu/libcloud_nutanix/openfga_my/ 2>&1 | head -30 1.9s
    … 19 output lines hidden · ctrl+o to expand
    -rwxrwxr-x  1 ubuntu ubuntu 14220 Jul  5 05:47 setup.sh
    -rw-rw-r--  1 ubuntu ubuntu 10534 Jun 30 10:19 vault_bootstrap.py

    Grepped 2 greps
    Grepped "openfga_my" in .
    Grepped "openfga_my" in .

  $ ls -la /home/ubuntu/libcloud_nutanix/openfga_my/scripts/ 2>&1 237ms
    … 5 output lines hidden · ctrl+o to expand
    -rwxrwxr-x  1 ubuntu ubuntu 2784 Jun 30 17:31 superadmin_auth.sh
    -rwxrwxr-x  1 ubuntu ubuntu 4507 Jun 30 17:33 verify_superadmin_jwt.py

  Let me verify the key runtime dependency — whether the Postgres stack builds its own OpenFGA image or relies on the one built in openfga_my.

  $ rg -n "openfga-local|image:|build:" openfga_postgres/docker-compose.yml openfga_my/docker-compose.yml 2>&1 216ms
    … 7 output lines hidden · ctrl+o to expand
    openfga_postgres/docker-compose.yml:63:    image: openfga-local:latest
    openfga_postgres/docker-compose.yml:104:    image: python:3.12-slim

    Read, grepped 1 file, 2 greps
    Read openfga_postgres/setup.sh lines 90-124
    Grepped "openfga_my" in .
    Grepped "...uperadmin_auth|set_tenant_credentials" in .

  $ git -C /home/ubuntu/libcloud_nutanix status --short openfga_my/ | head -20; echo "---"; git -C /home/ubuntu/libcloud_nutanix log --oneline -5 -- openfga_my/
    2>&1 450ms
    … 20 output lines hidden · ctrl+o to expand
    ---
    2e2cb0a     new file:   .gitignore  new file:   dex/.env.example    new file:   dex/ARCHITECTURE.md     new file:   dex/config.phase2.example.yaml  new fil…

  $ git -C /home/ubuntu/libcloud_nutanix status --short -- openfga_my/ 2>&1 | head -20 267ms
    … 18 output lines hidden · ctrl+o to expand
     D openfga_my/execution_path.md
     D openfga_my/finops_dashboard.wtd

  No — openfga_my/ cannot be safely removed right now. It is still a live runtime dependency.

  The git status is misleading: the D entries you see are mostly docs/.wtd scratch files being deleted, but the operational code is still present and tracked
  on disk (setup.sh, shutdown.sh, docker-compose.yml, Dockerfile, dex_bootstrap.py, openfga_bootstrap.py, vault_bootstrap.py, and scripts/).

  Hard runtime dependencies

  1. It is the only place that builds the OpenFGA Docker image.
  openfga_my/docker-compose.yml is the only compose file with a build: section:

   openfga_my/docker-compose.yml lines 27-28

      build: .
      image: openfga-local:latest

  The Postgres stack reuses that image with no build section, and its setup script hard-aborts if the image is missing:

   openfga_postgres/setup.sh lines 98-103

  if ! docker image inspect openfga-local:latest >/dev/null 2>&1; then
    echo "ERROR: openfga-local:latest image not found." >&2
    echo "Build it once from the SQLite project, then re-run this script:" >&2
    echo "  ( cd ../openfga_my && docker compose build openfga )" >&2
    exit 1
  fi

  So openfga_postgres/ cannot even start without openfga_my/.

  2. Its setup.sh is the documented secret-sync source for the REST API.
  The live env files point back to it:

  libcloud.rest/.env:27:  # Vault secret broker (synced by ../openfga_my/setup.sh)
  libcloud.rest/.env:48:  # Dex OIDC + OpenFGA (from ../openfga_my/setup.sh)
  libcloud.rest/docker-compose.yml:23-24:  # ... synced from ../openfga_my/../vault/generated/vault.env
    #   by ../openfga_my/setup.sh ...

  3. Its scripts are still referenced by tooling/test procedures.
  openfga_my/scripts/ still contains idp_login.py, set_tenant_credentials.py, superadmin_auth.sh, verify_superadmin_jwt.py, provision_aws.sh, etc. These are
  referenced from:
  • test_script/shutdown.sh:123 — cd openfga_my && ./setup.sh (restart hint)
  • test_script/doc/startup_procedure.md — provisioning + tenant-credential steps
  • startup_shutdown.md:21,66 — cd ../openfga_my && docker compose down / docker compose build openfga
  • overall_provision_test.sh:82 — SQLite rollback path

  What's safe vs. not

  ┌────────────────────────────────────────────────────────────────────────────────────────────────────┬─────────────────────────────────────────────────────┐
  │ Category                                                                                           │ Status                                              │
  ├────────────────────────────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
  │openfga_my/*.md, *.wtd, log/, scratch scripts (the D entries in git status)                         │ Safe to delete — already being removed              │

  ├────────────────────────────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
  │ openfga_my/setup.sh, shutdown.sh, docker-compose.yml, Dockerfile, *_bootstrap.py                   │ NOT safe — builds the image + bootstraps/syncs      │
  │                                                                                                    │ secrets                                             │
  ├────────────────────────────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
  │ openfga_my/scripts/ (idp_login.py, set_tenant_credentials.py, superadmin_auth.sh, provision_.sh,   │ NOT safe — still referenced by operational          │
  │ _common.sh, etc.)                                                                                  │ docs/test scripts                                   │
  ├────────────────────────────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
  │ openfga_my/generated/ (dex.env, fga.env, vault.env, tokens/)                                       │ NOT safe — secrets the REST API and admin scripts   │
  │                                                                                                    │ consume                                             │
  ├────────────────────────────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
  │ openfga_my/data/principal_map.json                                                                 │ Referenced in docs as identity-resolution source    │
  └────────────────────────────────────────────────────────────────────────────────────────────────────┴─────────────────────────────────────────────────────┘

  To actually remove it, you'd first need to

  1. Move the openfga-local:latest image build (build: . + Dockerfile) into openfga_postgres/ (or a dedicated openfga_build/ dir) and update
     openfga_postgres/setup.sh:98-103.
  2. Re-home setup.sh / shutdown.sh / dex_bootstrap.py / openfga_bootstrap.py / vault_bootstrap.py into openfga_postgres/ (or another canonical location).
  3. Re-home the still-used scripts/ (idp_login.py, set_tenant_credentials.py, superadmin_auth.sh, verify_superadmin_jwt.py, provision_*.sh, *_common.sh)
     and update callers.
  4. Update all references in libcloud.rest/.env, libcloud.rest/docker-compose.yml, test_script/shutdown.sh, startup_shutdown.md, overall_provision_test.sh,
     and test_script/doc/startup_procedure.md.
  5. Decide what to do with generated/ secrets and the openfga_my_openfga-data SQLite volume (the documented rollback path).

  Want me to plan the migration (move build + bootstrap + surviving scripts into openfga_postgres/, then remove openfga_my/)?


  Cursor Agent
  v2026.07.09-a3815c0
  Tip: Use /run-everything to skip all approvals.

                                                                                                                                                               
  right now can the openfga_my directory be removed? any dependencies on this directory?                                                                       
                                                                                                                                                               

  $ ls -la /home/ubuntu/libcloud_nutanix/openfga_my/ 2>&1 | head -30 1.9s
    … 19 output lines hidden · ctrl+o to expand
    -rwxrwxr-x  1 ubuntu ubuntu 14220 Jul  5 05:47 setup.sh
    -rw-rw-r--  1 ubuntu ubuntu 10534 Jun 30 10:19 vault_bootstrap.py

    Grepped 2 greps
    Grepped "openfga_my" in .
    Grepped "openfga_my" in .

  $ ls -la /home/ubuntu/libcloud_nutanix/openfga_my/scripts/ 2>&1 237ms
    … 5 output lines hidden · ctrl+o to expand
    -rwxrwxr-x  1 ubuntu ubuntu 2784 Jun 30 17:31 superadmin_auth.sh
    -rwxrwxr-x  1 ubuntu ubuntu 4507 Jun 30 17:33 verify_superadmin_jwt.py

  Let me verify the key runtime dependency — whether the Postgres stack builds its own OpenFGA image or relies on the one built in openfga_my.

  $ rg -n "openfga-local|image:|build:" openfga_postgres/docker-compose.yml openfga_my/docker-compose.yml 2>&1 216ms
    … 7 output lines hidden · ctrl+o to expand
    openfga_postgres/docker-compose.yml:63:    image: openfga-local:latest
    openfga_postgres/docker-compose.yml:104:    image: python:3.12-slim

    Read, grepped 1 file, 2 greps
    Read openfga_postgres/setup.sh lines 90-124
    Grepped "openfga_my" in .
    Grepped "...uperadmin_auth|set_tenant_credentials" in .

  $ git -C /home/ubuntu/libcloud_nutanix status --short openfga_my/ | head -20; echo "---"; git -C /home/ubuntu/libcloud_nutanix log --oneline -5 --
    openfga_my/ 2>&1 450ms
    … 20 output lines hidden · ctrl+o to expand
    ---
    2e2cb0a     new file:   .gitignore  new file:   dex/.env.example    new file:   dex/ARCHITECTURE.md     new file:   dex/config.phase2.example.yaml  new f…

  $ git -C /home/ubuntu/libcloud_nutanix status --short -- openfga_my/ 2>&1 | head -20 267ms
    … 18 output lines hidden · ctrl+o to expand
     D openfga_my/execution_path.md
     D openfga_my/finops_dashboard.wtd

  No — openfga_my/ cannot be safely removed right now. It is still a live runtime dependency.

  The git status is misleading: the D entries you see are mostly docs/.wtd scratch files being deleted, but the operational code is still present and
  tracked on disk (setup.sh, shutdown.sh, docker-compose.yml, Dockerfile, dex_bootstrap.py, openfga_bootstrap.py, vault_bootstrap.py, and scripts/).

  Hard runtime dependencies

  1. It is the only place that builds the OpenFGA Docker image.
  openfga_my/docker-compose.yml is the only compose file with a build: section:

   openfga_my/docker-compose.yml lines 27-28

      build: .
      image: openfga-local:latest

  The Postgres stack reuses that image with no build section, and its setup script hard-aborts if the image is missing:

   openfga_postgres/setup.sh lines 98-103

  if ! docker image inspect openfga-local:latest >/dev/null 2>&1; then
    echo "ERROR: openfga-local:latest image not found." >&2
    echo "Build it once from the SQLite project, then re-run this script:" >&2
    echo "  ( cd ../openfga_my && docker compose build openfga )" >&2
    exit 1
  fi

  So openfga_postgres/ cannot even start without openfga_my/.

  2. Its setup.sh is the documented secret-sync source for the REST API.
  The live env files point back to it:

  libcloud.rest/.env:27:  # Vault secret broker (synced by ../openfga_my/setup.sh)
  libcloud.rest/.env:48:  # Dex OIDC + OpenFGA (from ../openfga_my/setup.sh)
  libcloud.rest/docker-compose.yml:23-24:  # ... synced from ../openfga_my/../vault/generated/vault.env
    #   by ../openfga_my/setup.sh ...

  3. Its scripts are still referenced by tooling/test procedures.
  openfga_my/scripts/ still contains idp_login.py, set_tenant_credentials.py, superadmin_auth.sh, verify_superadmin_jwt.py, provision_aws.sh, etc. These are
  referenced from:
  • test_script/shutdown.sh:123 — cd openfga_my && ./setup.sh (restart hint)
  • test_script/doc/startup_procedure.md — provisioning + tenant-credential steps
  • startup_shutdown.md:21,66 — cd ../openfga_my && docker compose down / docker compose build openfga
  • overall_provision_test.sh:82 — SQLite rollback path

  What's safe vs. not

  ┌───────────────────────────────────────────────────────────────────────────────────────────────────┬────────────────────────────────────────────────────┐
  │ Category                                                                                          │ Status                                             │
  ├───────────────────────────────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────┤
  │openfga_my/*.md, *.wtd, log/, scratch scripts (the D entries in git status)                        │ Safe to delete — already being removed             │

  ├───────────────────────────────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────┤
  │ openfga_my/setup.sh, shutdown.sh, docker-compose.yml, Dockerfile, *_bootstrap.py                  │ NOT safe — builds the image + bootstraps/syncs     │
  │                                                                                                   │ secrets                                            │
  ├───────────────────────────────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────┤
  │ openfga_my/scripts/ (idp_login.py, set_tenant_credentials.py, superadmin_auth.sh, provision_.sh,  │ NOT safe — still referenced by operational         │
  │ _common.sh, etc.)                                                                                 │ docs/test scripts                                  │
  ├───────────────────────────────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────┤
  │ openfga_my/generated/ (dex.env, fga.env, vault.env, tokens/)                                      │ NOT safe — secrets the REST API and admin scripts  │
  │                                                                                                   │ consume                                            │
  ├───────────────────────────────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────┤
  │ openfga_my/data/principal_map.json                                                                │ Referenced in docs as identity-resolution source   │
  └───────────────────────────────────────────────────────────────────────────────────────────────────┴────────────────────────────────────────────────────┘

  To actually remove it, you'd first need to

  1. Move the openfga-local:latest image build (build: . + Dockerfile) into openfga_postgres/ (or a dedicated openfga_build/ dir) and update
     openfga_postgres/setup.sh:98-103.
  2. Re-home setup.sh / shutdown.sh / dex_bootstrap.py / openfga_bootstrap.py / vault_bootstrap.py into openfga_postgres/ (or another canonical location).
  3. Re-home the still-used scripts/ (idp_login.py, set_tenant_credentials.py, superadmin_auth.sh, verify_superadmin_jwt.py, provision_*.sh, *_common.sh)
     and update callers.
  4. Update all references in libcloud.rest/.env, libcloud.rest/docker-compose.yml, test_script/shutdown.sh, startup_shutdown.md,
     overall_provision_test.sh, and test_script/doc/startup_procedure.md.
  5. Decide what to do with generated/ secrets and the openfga_my_openfga-data SQLite volume (the documented rollback path).

  Want me to plan the migration (move build + bootstrap + surviving scripts into openfga_postgres/, then remove openfga_my/)?

                                                                                                                                                               
  do a close analysis between openfga_my and openfga_postgres and list the different between the two directories, and its files.                               
                                                                                                                                                               

  I'll do a close comparison of both directories.

  $ cd /home/ubuntu/libcloud_nutanix && echo "=== openfga_my tree ===" && find openfga_my -type f -not -path '*/__pycache__/*' -not -path '*/.git/*' | sort &&
    echo "" && echo "=== openfga_postgres tree ===" && find openfga_postgres -type f -not -path '*/__pycache__/*' -not -path '*/.git/*' | sort 1.1s
    … 91 output lines hidden · ctrl+o to expand
    openfga_postgres/setup.sh
    openfga_postgres/vault_bootstrap.py

  Now let me diff the key shared files to see what actually differs.

  $ cd /home/ubuntu/libcloud_nutanix && for f in docker-compose.yml setup.sh .env.example .dockerignore .gitignore dex_bootstrap.py openfga_bootstrap.py
    vault_bootstrap.py data/principal_map.json scripts/idp_login.py scripts/set_tenant_credentials.py scripts/superadmin_auth.sh
    scripts/verify_superadmin_jwt.py; do
      a="openfga_my/$f"; b="openfga_postgres/$f" 320ms
    … 13 input + 11 output lines hidden · ctrl+o to expand
    DIFFERS    : scripts/superadmin_auth.sh  (my=70L  pg=81L)
    IDENTICAL  : scripts/verify_superadmin_jwt.py

  Several files are byte-identical. Let me diff the ones that differ to understand the nature of each change.

  $ cd /home/ubuntu/libcloud_nutanix && echo "########## docker-compose.yml ##########" && diff openfga_my/docker-compose.yml
    openfga_postgres/docker-compose.yml; echo "########## .env.example ##########" && diff openfga_my/.env.example openfga_postgres/.env.example exit 1 • 
    294ms
    … 141 output lines hidden · ctrl+o to expand
    < # by the provision scripts at the end of their provision section (PROVISION=1).
    < TEARDOWN_VMS=0

  $ cd /home/ubuntu/libcloud_nutanix && echo "########## setup.sh ##########" && diff openfga_my/setup.sh openfga_postgres/setup.sh exit 1 • 275ms
    … 172 output lines hidden · ctrl+o to expand
    > echo
    > echo "Rollback to SQLite: see README.md (../openfga_my volume + compose are preserved)."

  $ cd /home/ubuntu/libcloud_nutanix && echo "########## dex_bootstrap.py ##########" && diff openfga_my/dex_bootstrap.py openfga_postgres/dex_bootstrap.py;
    echo "########## scripts/superadmin_auth.sh ##########" && diff openfga_my/scripts/superadmin_auth.sh openfga_postgres/scripts/superadmin_auth.sh exit 1 •
    349ms
    … 50 output lines hidden · ctrl+o to expand
    > _load_env_file "${ROOT}/../dex/generated/dex.env"
    > _load_env_file "${ROOT}/generated/dex.env"

  Let me check the Postgres-only scripts, the README, and the assets/ directory (image-build source).

  $ cd /home/ubuntu/libcloud_nutanix && echo "=== openfga_postgres/README.md (head) ===" && head -40 openfga_postgres/README.md && echo "" && echo "===
    openfga_postgres/scripts/pg_query.sh ===" && cat openfga_postgres/scripts/pg_query.sh && echo "" && echo "=== openfga_postgres/scripts/pg_dump.sh ===" &&
    cat openfga_postgres/scripts/pg_dump.sh 281ms
    … 82 output lines hidden · ctrl+o to expand
      --no-owner --no-privileges > "$out"
    echo "Wrote $out"

  $ cd /home/ubuntu/libcloud_nutanix && echo "=== assets purpose (Dockerfile references?) ===" && grep -n "assets\|migrations" openfga_my/Dockerfile
    openfga_my/docker-compose.yml 2>&1 && echo "" && echo "=== Dockerfile ===" && cat openfga_my/Dockerfile && echo "" && echo "=== openfga_postgres/setup.log
    (head) ===" && head -15 openfga_postgres/setup.log 2>&1 267ms
    … 40 output lines hidden · ctrl+o to expand
    Waiting for LLDAP web UI ...
     Container lldap Running 

  $ cd /home/ubuntu/libcloud_nutanix && echo "=== openfga_my/.gitignore ===" && cat openfga_my/.gitignore && echo "" && echo "=== openfga binary present? ==="
    && ls -la openfga_my/openfga 2>&1 && echo "" && echo "=== openfga_postgres/.gitignore ===" && cat openfga_postgres/.gitignore && echo "" && echo "===
    generated env files (secrets) present? ===" && ls openfga_my/generated/*.env openfga_postgres/generated/*.env 2>&1 && echo "" && echo "=== compare
    provision_aws.sh: exists in openfga_my? ===" && ls openfga_my/scripts/provision_*.sh openfga_my/scripts/deprovision_*.sh openfga_my/scripts/common.sh 2>&1
    exit 2 • 310ms
    … 12 output lines hidden · ctrl+o to expand
    === openfga binary present? ===
    ls: cannot access 'openfga_my/openfga': No such file or directory

  $ cd /home/ubuntu/libcloud_nutanix; echo "=== openfga_postgres/.gitignore ==="; cat openfga_postgres/.gitignore; echo ""; echo "=== generated env files
    ==="; ls openfga_my/generated/*.env openfga_postgres/generated/*.env 2>&1; echo ""; echo "=== provision/deprovision/common in openfga_my/scripts? ==="; ls
    openfga_my/scripts/provision_*.sh openfga_my/scripts/deprovision_*.sh openfga_my/scripts/common.sh 2>&1; echo ""; echo "=== is openfga-local image built?
    ==="; docker image inspect openfga-local:latest --format '{{.Id}} {{.CreatedSince}}' 2>&1 exit 1 • 333ms
    … 25 output lines hidden · ctrl+o to expand
    template parsing error: template: :1:10: executing "" at <.CreatedSince>: map has no entry for key "CreatedSince"

  $ cd /home/ubuntu/libcloud_nutanix; docker images openfga-local 2>&1; echo "---volumes---"; docker volume ls 2>&1 | grep -i openfga 347ms
    … 3 output lines hidden · ctrl+o to expand
    local     openfga_my_openfga-data
    local     openfga_postgres_openfga-pg-data

  I have a complete picture. Here is the close analysis.

  Conceptual relationship

  openfga_postgres/ is the PostgreSQL-backed replacement for openfga_my/ (which uses OpenFGA's "beta / single-node" SQLite datastore). By design, everything
  above the storage layer is reused verbatim from openfga_my/; only the datastore changes. openfga_postgres/README.md documents this explicitly and
  consolidates two root design docs (redesign_openfga_for_postgresql.md, adding_postgres_openfga.md).

  Files that are byte-identical (reused verbatim)

  ┌───────────────────────────────────┬──────────────────────────────────────────────────────────────────────────────────┐
  │ File                              │ Notes                                                                            │
  ├───────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────┤
  │ .dockerignore                     │ identical                                                                        │
  ├───────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────┤
  │ .gitignore                        │ identical (both ignore .env, generated/, certs/, dex/config.yaml, .dockerignore) │
  ├───────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────┤
  │ openfga_bootstrap.py              │ identical — store/model/INITIAL_TUPLES/VALIDATION_CHECKS                         │
  ├───────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────┤
  │ vault_bootstrap.py                │ identical — Vault init/unseal/KV/REST token                                      │
  ├───────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────┤
  │ data/principal_map.json           │ identical — email/sub → principal slug map                                       │
  ├───────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────┤
  │ scripts/idp_login.py              │ identical — Dex OIDC login + token cache                                         │
  ├───────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────┤
  │ scripts/set_tenant_credentials.py │ identical — per-tenant Vault creds                                               │
  ├───────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────┤
  │ scripts/verify_superadmin_jwt.py  │ identical — JWT verifier                                                         │
  └───────────────────────────────────┴──────────────────────────────────────────────────────────────────────────────────┘

  Files that differ

  ┌─────────┬───────────────────────────┬──────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ File    │ openfga_my (SQLite)       │ openfga_postgres                                                                                                 │
  ├─────────┼───────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ docker- │ --datastore-engine=sqlite │ adds postgres:16 service w/ pg_isready healthcheck; --datastore-engine=postgres, URI                             │
  │ compose │ ,                         │ postgres://…@postgres:5432/…?sslmode=…; no build: (reuses prebuilt image); depends_on: postgres                  │
  │ .yml    │ URI /data/openfga.sqlite; │ (service_healthy); volume openfga-pg-data; host port 5433:5432 (debug only)                                      │
  │ (99 vs  │ has build: .; volume      │                                                                                                                  │
  │ 135 L)  │ openfga-data              │                                                                                                                  │
  ├─────────┼───────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ setup.s │ builds                    │ (0a) generates/reuses POSTGRES_PASSWORD → generated/postgres.env; (0b) aborts if openfga-local:latest missing,   │
  │ h       │ openfga-local:latest from │ tells you to cd ../openfga_my && docker compose build openfga; (0c) removes stale                                │
  │ (295 vs │ local Dockerfile +        │ openfga/openfga-migrate/openfga-bootstrap containers owned by the openfga_my project to free names/ports; waits  │
  │ 403 L)  │ vendored binary,          │ for Postgres health + one-shot openfga-migrate exit 0; restarts OpenFGA to flush cached Dex JWKS after fresh Dex │
  │         │ hash-stamps it in         │ keys; "clean re-seed" messaging (new store/model IDs — SQLite IDs don't carry over); prints psql inspect hint +  │
  │         │ .openfga_image_stamp,     │ rollback pointer to README                                                                                       │
  │         │ re-builds on change       │                                                                                                                  │
  ├─────────┼───────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ .env.ex │ DEX_URL=http://localhost: │ adds 27-line POSTGRES_* block (POSTGRES_HOST/DB/USER/PASSWORD/SSLMODE, PG_HOST_PORT=5433); comments out          │
  │ ample   │ 5556;                     │ DEX_PUBLIC_URL; adds DEX_URL vs DEX_INTERNAL_URL clarification; drops TEARDOWN_VMS                               │
  │ (79 vs  │ has TEARDOWN_VMS=0        │                                                                                                                  │
  │ 111 L)  │                           │                                                                                                                  │
  ├─────────┼───────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ dex_boo │ internal_url =            │ reads DEX_INTERNAL_URL instead, with a 7-line comment explaining why: reading DEX_URL here would let a stale     │
  │ tstrap. │ os.environ.get("DEX_URL", │ dex.env (sourced before the 2nd bootstrap call) overwrite the canonical in-container issuer with the host URL →  │
  │ py      │ "http://dex:5556")        │ OpenFGA rejects tokens with invalid_claims                                                                       │
  │ (207 vs │                           │                                                                                                                  │
  │ 214 L)  │                           │                                                                                                                  │
  ├─────────┼───────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ scripts │ sources scripts/common.sh │ self-contained — inlines a _load_env_file helper and loads .env + ../dex/generated/dex.env + generated/dex.env   │
  │ /supera │ (which resolves           │ directly, because common.sh is absent in the pg project and its hard FGA_STORE_ID/FGA_MODEL_ID guards are        │
  │ dmin_au │ LIBCLOUD_PASSWORD from    │ unusable pre-bootstrap                                                                                           │
  │ th.sh   │ LIBCLOUD_USER); sets      │                                                                                                                  │
  │ (70 vs  │ principal before sourcing │                                                                                                                  │
  │ 81 L)   │                           │                                                                                                                  │
  └─────────┴───────────────────────────┴──────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

  Files only in openfga_my/

  • Dockerfile — FROM alpine:3.21, COPY openfga /openfga, default CMD sqlite. This is the only place the openfga-local:latest image is built. Note: the
    vendored openfga binary itself is not currently on disk (not in .gitignore either) — but the image is already built (openfga-local:latest →
    ce5554f202ef, 68.9 MB), which is what openfga_postgres reuses.
  • assets/ — OpenFGA source assets: assets.go, SQL migrations for sqlite/mysql/postgres (001–005), playground/index.html, ABAC/consolidated test YAMLs.
    Image-build input only.
  • generated/ richer contents: dex.env, vault.env, fga.env; audit CSVs (openfga_tuples_*.csv, vault_policy_bindings_*.csv); audit logs (chain_audit,
    cloud_audit, lldap_audit, offboard_audit, openfga_audit, openfga_breakglass, vault_audit); .openfga_image_stamp, .openfga_jwks_refreshed_at; 8 user 
    tokens (aws-admin/owner/viewer, ntnx-admin/owner/viewer, cloud-denied, superadmin + .jwt + .login.err).
  • Per git status, many old scripts were deleted from openfga_my/scripts/ (provision_aws.sh, lldap-, vault-, openfga-, chain-, cloud-*, etc.) — the
    surviving 4 are the identical ones listed above.

  Files only in openfga_postgres/

  • README.md — the consolidation doc with the side-by-side comparison table and rollback procedure.
  • generated/postgres.env — POSTGRES_HOST/DB/USER/PASSWORD/SSLMODE (pg-specific credentials, gitignored).
  • setup.log — a captured setup.sh run.
  • More scripts/: provision_aws.sh, provision_nutanix.sh, deprovision_aws.sh, deprovision_nutanix.sh, common.sh, aws_resolve_catalog.py (the operational
    lifecycle tooling that was deleted from openfga_my/scripts/), plus two new Postgres helpers:
    • scripts/pg_query.sh — docker exec -it openfga-postgres psql …
    • scripts/pg_dump.sh — pg_dump to generated/openfga_pg_dump_<ts>.sql (backup/rollback snapshots)
  • 5 user tokens (aws-admin/owner, ntnx-admin/owner, superadmin + .jwt + .login.err) — fewer than openfga_my's 8 (no *-viewer, no cloud-denied).
  • No Dockerfile, no assets/, no vendored binary — deliberately depends on the prebuilt image.

  Docker state (both stacks' volumes coexist)

  openfga-local:latest   ce5554f202ef   68.9MB   (built once from openfga_my)
  volume: openfga_my_openfga-data          (SQLite — rollback path)
  volume: openfga_postgres_openfga-pg-data (Postgres — current)

  Bottom line

  The two directories are ~90% the same code (the identical-file list above). openfga_postgres is essentially openfga_my with: (1) the datastore swapped
  from SQLite to Postgres, (2) the image-build responsibility left behind in openfga_my, (3) superadmin_auth.sh made self-contained, (4) dex_bootstrap.py
  issuer handling hardened, and (5) the operational provision/deprovision/pg scripts consolidated in scripts/. The only thing keeping openfga_my/ from being
  deletable is item (2) — the Dockerfile + assets/ that build openfga-local:latest, plus it being the documented SQLite rollback path.


