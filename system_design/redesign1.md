  does OpenFGA (../openfga_my) at the present moment uses any of files to store the authorization relationship? how many users are there? how many             
  subjects and objects and resources and relationship are there? provide an estimate of the number or growth of relationship as the number of users            
  grow. list all the relationships for AWS admin and viewer, Nutanix admin and viewer, and superadmin. if all these relationship were to be relocated to       
  a PostgreSQL database, what are the pros and cons. list all the requirements for setting this up.                                                            
                                                                                                                                                               

  $ ls -la /home/ubuntu/openfga_my 2>/dev/null || ls -la /home/ubuntu/ | head -50 2.5s
    … 26 output lines hidden · ctrl+o to expand
    drwxrwxr-x  2 ubuntu ubuntu    4096 Jun 30 17:42 glm52
    drwxrwxr-x 16 ubuntu ubuntu    4096 Jul 11 07:22 libcloud_nutanix

  $ find /home/ubuntu -maxdepth 3 -iname "*openfga*" -not -path "*/node_modules/*" 2>/dev/null | head -50 181ms
    … 10 output lines hidden · ctrl+o to expand
    /home/ubuntu/libcloud_nutanix/adding_postgres_openfga.md
    /home/ubuntu/libcloud_nutanix/test_script/check_dex_vs_openfga.sh

  $ ls -la /home/ubuntu/libcloud_nutanix/openfga_my/ 226ms
    … 19 output lines hidden · ctrl+o to expand
    -rwxrwxr-x  1 ubuntu ubuntu 14220 Jul  5 05:47 setup.sh
    -rw-rw-r--  1 ubuntu ubuntu 10534 Jun 30 10:19 vault_bootstrap.py

  $ ls -la /home/ubuntu/libcloud_nutanix/openfga_my/data/ /home/ubuntu/libcloud_nutanix/openfga_my/scripts/
    /home/ubuntu/libcloud_nutanix/openfga_my/generated/ 2>/dev/null 183ms
    … 32 output lines hidden · ctrl+o to expand
    -rwxrwxr-x  1 ubuntu ubuntu 2784 Jun 30 17:31 superadmin_auth.sh
    -rwxrwxr-x  1 ubuntu ubuntu 4507 Jun 30 17:33 verify_superadmin_jwt.py

    Read 5 files
    … 2 earlier items hidden
    Read openfga_my/openfga_bootstrap.py
    Read openfga_my/data/principal_map.json
    Read adding_postgres_openfga.md

  $ docker volume inspect openfga_my_openfga-data 2>/dev/null; echo "---"; docker ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null | rg -i fga; echo
    "---volume mountpoint---"; sudo ls -la /var/lib/docker/volumes/openfga_my_openfga-data/_data/ 2>/dev/null 7.1s
    … 25 output lines hidden · ctrl+o to expand
    -rw-r--r-- 1 root root 32768 Jul  8 05:27 openfga.sqlite-shm
    -rw-r--r-- 1 root root     0 Jul  8 05:27 openfga.sqlite-wal

  $ sudo cp /var/lib/docker/volumes/openfga_my_openfga-data/_data/openfga.sqlite /tmp/openfga_copy.sqlite 2>&1; sudo chmod a+r /tmp/openfga_copy.sqlite; ls
    -la /tmp/openfga_copy.sqlite; echo "---tables---"; sqlite3 /tmp/openfga_copy.sqlite ".tables" 2>&1 exit 127 • 14s
    … 2 output lines hidden · ctrl+o to expand
    Command 'sqlite3' not found, but can be installed with:
    sudo apt install sqlite3

  $ python3 -c "
    import sqlite3 263ms
    … 13 input + 7 output lines hidden · ctrl+o to expand
    store: 1 rows
    tuple: 50 rows

  $ python3 -c "
    import sqlite3, json exit 1 • 455ms
    … 15 input + 9 output lines hidden · ctrl+o to expand
    {'store': '01KW9EZ0Q706Y580FGQ2488THC', 'object_type': 'tenant', 'object_id': 'default', 'relation': 'member_role', 'user_object_type': 'role', 'user_obj…

  $ python3 -c "
    import sqlite3 325ms
    … 14 input + 50 output lines hidden · ctrl+o to expand
      user:superadmin                      owner               tenant:nutanix
      user:ntnx-viewer                     viewer              tenant:nutanix

  $ python3 -c "
    import sqlite3 353ms
    … 46 input + 87 output lines hidden · ctrl+o to expand
       admin 2
       superadmin 1

  $ python3 -c "
    import sqlite3 317ms
    … 14 input + 26 output lines hidden · ctrl+o to expand
    {"ts":"2026-07-04T09:41:12Z","actor":"superadmin","action":"check","tuple":{"use​r":"user:alice","relation":"can_provision","object":"provider:aws"},"re…
    {"ts":"2026-07-08T05:28:04Z","actor":"aws-admin","action":"presharedkey-rotate",​"vault_path":"secret/data/openfga/apikey","result":"vault-write-error",…

  $ python3 -c "
    import sqlite3 373ms
    … 13 input + 59 output lines hidden · ctrl+o to expand
      WRITE  user:sweepuser                      viewer         tenant:nutanix
      DELETE user:sweepuser                      viewer         tenant:nutanix

  $ python3 -c "
    import sqlite3 591ms
    … 15 input + 3 output lines hidden · ctrl+o to expand
    cols: ['store', 'authorization_model_id', 'schema_version', 'serialized_protobuf']

  $ python3 -c "
    import sqlite3 406ms
    … 9 input + 2 output lines hidden · ctrl+o to expand
    {'id': '01KW9EZ0Q706Y580FGQ2488THC', 'name': 'libcloud-rest-store', 'created_at': '2026-06-29 10:31:54.344', 'updated_at': '2026-06-29 10:31:54.344', 'de…

  I inspected the live OpenFGA deployment (docker-compose.yml, the SQLite datastore on the openfga-data volume, the bootstrap model, and the audit log).
  Here is the full picture.

  1. Does OpenFGA currently use any files to store authorization relationships?

  Yes — a single SQLite database file. OpenFGA does not store relationships in JSON/YAML; it stores them in its datastore, which in this deployment is
  SQLite.

  • docker-compose.yml lines 8–11, 20–21, 42–43 configure it:

   /home/ubuntu/libcloud_nutanix/openfga_my/docker-compose.yml lines 8-14

  # Persistent sqlite datastore on the `openfga-data` volume so
  # stores/models/tuples survive reboot/restart. The sqlite driver wants a bare
  # file path (NOT "sqlite://..."); migrations are applied by the one-shot
  # `openfga-migrate` service before `openfga` starts.
  ...
        - --datastore-engine=sqlite
        - --datastore-uri=/data/openfga.sqlite

  The actual file on disk is the Docker volume:

  /var/lib/docker/volumes/openfga_my_openfga-data/_data/openfga.sqlite   (86 KB)

  Tables in that SQLite file: store, authorization_model, tuple, changelog, assertion, goose_db_version, sqlite_sequence.

  There is also data/principal_map.json, but that is not authorization data — it is a host-side IdP-alias map (email/legacy-username → OpenFGA principal
  slug). The relationships themselves live only in SQLite.

  2. How many users?

  9 users are referenced as subjects (user:*) in stored tuples:

  ┌─────────────────────┬────────────────────────────────────────────────────┐
  │ user                │ role(s)                                            │
  ├─────────────────────┼────────────────────────────────────────────────────┤
  │ user:superadmin     │ platform superadmin + owner on both tenants        │
  ├─────────────────────┼────────────────────────────────────────────────────┤
  │ user:aws-owner      │ owner tenant:aws                                   │
  ├─────────────────────┼────────────────────────────────────────────────────┤
  │ user:aws-admin      │ admin tenant:aws                                   │
  ├─────────────────────┼────────────────────────────────────────────────────┤
  │ user:aws-viewer     │ viewer tenant:aws                                  │
  ├─────────────────────┼────────────────────────────────────────────────────┤
  │ user:ntnx-owner     │ owner tenant:nutanix                               │
  ├─────────────────────┼────────────────────────────────────────────────────┤
  │ user:ntnx-admin     │ admin tenant:nutanix                               │
  ├─────────────────────┼────────────────────────────────────────────────────┤
  │ user:ntnx-viewer    │ viewer tenant:nutanix                              │
  ├─────────────────────┼────────────────────────────────────────────────────┤
  │ user:cloud-admin    │ member role:admin, member tenant:default (legacy)  │
  ├─────────────────────┼────────────────────────────────────────────────────┤
  │ user:cloud-readonly │ member role:reader, member tenant:default (legacy) │
  └─────────────────────┴────────────────────────────────────────────────────┘

  user:cloud-denied exists in principal_map.json but has zero tuples (authenticated-but-unauthorized).

  3. Counts of subjects, objects, resources, and relationships

  Measured directly from the tuple table (50 active tuples):

  ┌─────────────────────────────────────────────────────────────────────────────────┬────────────────────────────┐
  │ Metric                                                                          │ Count                      │
  ├─────────────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
  │ Active relationship tuples                                                      │ 50                         │
  ├─────────────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
  │ Distinct subjects (left-hand side, incl. role:admin#member, tenant:*, provider:*) │ 20                         │
  ├─────────────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
  │ Distinct users (user:* subjects)                                                │ 9                          │
  ├─────────────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
  │ Distinct objects / resources (right-hand side)                                  │ 17                         │
  ├─────────────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
  │ Distinct relations                                                              │ 12                         │
  ├─────────────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
  │ Authorization models (versions)                                                 │ 2 (schema 1.1)             │
  ├─────────────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
  │ Stores                                                                          │ 1 (libcloud-rest-store)    │
  ├─────────────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
  │ Changelog entries (history)                                                     │ 58 (54 writes + 4 deletes) │
  └─────────────────────────────────────────────────────────────────────────────────┴────────────────────────────┘

  The 12 relations in use: admin, allowed, granted, member, member_role, operator, owner, parent, provider, superadmin, tenant, viewer.

  Tuples grouped by object type:

  tenant           13
  provider         10
  api_scope         9
  nutanix_cluster   6
  aws_region        6
  libcloud_api      3
  role              2
  platform          1

  The 17 distinct objects/resources: platform:main, libcloud_api:main, tenant:aws, tenant:nutanix, tenant:default (legacy), provider:aws, provider:nutanix,
  aws_region:aws, aws_region:ap-southeast-1 (legacy), nutanix_cluster:nutanix, nutanix_cluster:lab (legacy), role:admin, role:reader,
  api_scope:compute_read, api_scope:compute_node_create, api_scope:compute_node_delete, api_scope:compute_network_manage.

  │ Note: the DB still contains tuples written against an older model (role:*, api_scope:*, tenant:default) from the Jun 29 bootstrap, plus the current 
    model's tuples (tenant:aws/nutanix, aws_region:aws, nutanix_cluster:nutanix) from the Jul 2 bootstrap. That is why you see both tenant:default/role:* 
    and tenant:aws/nutanix coexisting. The latest model id is 01KWCSRHRR4ADZPJYGSQ52GENX.

  4. Estimate of relationship growth as users grow

  Decompose the 50 tuples:

  • Infrastructure / scaffolding tuples (≈37) — independent of user count: parent (tenant→libcloud_api, tenant→provider), provider (provider→backend),
    tenant (tenant→backend), allowed/granted/operator/viewer from role:*#member to providers/backends/api_scopes, member_role for the legacy tenant.
  • Per-user tuples (≈13) — the 9 users above. Average ≈ 1.4 tuples/user (superadmin carries 3, cloud-admin/cloud-readonly carry 2 each via legacy
    role+tenant membership, the 6 per-cloud users carry 1 each).

  Because the model uses role indirection (user:X → member → role:Y, then role:Y#member → operator/viewer/granted/allowed on resources), adding a new user
  to an existing role costs ~1 tuple, not one tuple per resource.

  Growth model (holding tenants/backends/roles fixed):

  T(N_users) ≈ 37 + 1.4 × N_users

  ┌───────────┬──────────────────┐
  │ Users     │ Estimated tuples │
  ├───────────┼──────────────────┤
  │ 9 (today) │ ~50 (actual)     │
  ├───────────┼──────────────────┤
  │ 50        │ ~107             │
  ├───────────┼──────────────────┤
  │ 100       │ ~177             │
  ├───────────┼──────────────────┤
  │ 1 000     │ ~1 437           │
  ├───────────┼──────────────────┤
  │ 10 000    │ ~14 037          │
  └───────────┴──────────────────┘

  If you also scale tenants/backends, add roughly:

  • Per new tenant: ~6–10 scaffolding tuples (parent libcloud_api + parent provider + provider→backend + tenant→backend + per-role
    allowed/operator/viewer/granted).
  • Per new backend object (new aws_region:* / nutanix_cluster:*): ~2 scaffolding + (roles × {operator, viewer}) tuples.
  • Per new role: ~1 member_role + (api_scopes + providers + backends) granted/allowed/operator/viewer tuples.

  Without role indirection (direct user → relation → object on every resource), growth would be O(users × resources) — for 1 000 users across 4 backends and
  12 relations that would already be tens of thousands of tuples; the current role-based design keeps it near-linear in users.

  5. All relationships for AWS admin, AWS viewer, Nutanix admin, Nutanix viewer, superadmin

  I list both directly stored tuples and the effective (computed) permissions that the model derives from them (see VALIDATION_CHECKS in
  openfga_bootstrap.py).

  AWS admin — user:aws-admin

  Stored:
  • user:aws-admin  admin  tenant:aws

  Effective (computed via the model):
  • can_connect  libcloud_api:main = true (admin ⊆ member of tenant:aws → parent libcloud_api)
  • can_use  provider:aws = true
  • can_provision  aws_region:aws = true (admin ⊆ tenant_admin → can_provision ∩ provider can_use)
  • can_read  aws_region:aws = true
  • can_assign_viewer  tenant:aws = true
  • can_assign_admin  tenant:aws = false (owner-only)
  • can_assign_owner  tenant:aws = false
  • can_manage_credentials  tenant:aws = false (owner-only)
  • can_use  provider:nutanix / can_provision  nutanix_cluster:nutanix = false (cross-tenant isolation)

  AWS viewer — user:aws-viewer

  Stored:
  • user:aws-viewer  viewer  tenant:aws

  Effective:
  • can_connect  libcloud_api:main = true
  • can_use  provider:aws = true (viewer ⊆ member)
  • can_read  aws_region:aws = true
  • can_provision  aws_region:aws = false
  • can_assign_viewer  tenant:aws = false
  • can_assign_admin / can_assign_owner / can_manage_credentials  tenant:aws = false
  • Cross-tenant (Nutanix) = false

  Nutanix admin — user:ntnx-admin

  Stored:
  • user:ntnx-admin  admin  tenant:nutanix

  Effective:
  • can_connect  libcloud_api:main = true
  • can_use  provider:nutanix = true
  • can_provision  nutanix_cluster:nutanix = true
  • can_read  nutanix_cluster:nutanix = true
  • can_assign_viewer  tenant:nutanix = true
  • can_assign_admin / can_assign_owner  tenant:nutanix = false
  • can_manage_credentials  tenant:nutanix = false (owner-only)
  • can_use  provider:aws / can_provision  aws_region:aws = false

  Nutanix viewer — user:ntnx-viewer

  Stored:
  • user:ntnx-viewer  viewer  tenant:nutanix

  Effective:
  • can_connect  libcloud_api:main = true
  • can_use  provider:nutanix = true
  • can_read  nutanix_cluster:nutanix = true
  • can_provision  nutanix_cluster:nutanix = false
  • can_assign_* / can_manage_credentials  tenant:nutanix = false
  • Cross-tenant (AWS) = false

  Superadmin — user:superadmin

  Stored:
  • user:superadmin  superadmin  platform:main
  • user:superadmin  owner  tenant:aws
  • user:superadmin  owner  tenant:nutanix

  Effective:
  • can_manage_platform  platform:main = true
  • can_connect  libcloud_api:main = true
  • can_use  provider:aws = true, can_use  provider:nutanix = true
  • can_provision  aws_region:aws = true, can_provision  nutanix_cluster:nutanix = true
  • can_read  aws_region:aws / nutanix_cluster:nutanix = true
  • can_assign_owner / can_assign_admin / can_assign_viewer  tenant:aws and tenant:nutanix = true
  • can_manage_credentials  tenant:aws = true, tenant:nutanix = true (break-glass owner on both)

  (Also user:cloud-admin / user:cloud-readonly still carry legacy member role:admin/member role:reader + member tenant:default tuples from the older model —
  listed in §3 but not requested above.)

  6. Relocating all these relationships to PostgreSQL — pros and cons

  The repo already discusses this in adding_postgres_openfga.md; OpenFGA officially supports PostgreSQL as a production backend (SQLite is flagged
  "beta/single-node").

  Pros

  • Production-supported backend. PostgreSQL is the recommended production datastore for OpenFGA; SQLite is documented as beta / single-node.
  • Horizontal scaling of OpenFGA. Multiple openfga replicas can share one Postgres DB (the current SQLite-on-a-volume design pins you to one container —
    you cannot run >1 OpenFGA instance).
  • Real concurrent writes. Postgres handles high write concurrency with MVCC; SQLite uses coarse file-level locking and serializes writers (problematic
    as tuple writes from the REST API / portal grow).
  • ACID + crash safety across hosts. Postgres gives WAL + PITR; SQLite WAL on a Docker volume is fine for dev but fragile for prod backups and multi-host
    access.
  • HA / replication / backups. Streaming replication, pg_dump/PITR, managed-Postgres options (RDS, CloudSQL), point-in-time recovery — none of which
    SQLite-on-a-volume gives you.
  • Operational tooling. Queryable audit via SQL, indexing, partitions on tuple/changelog, mature monitoring (Prometheus exporter, pg_stat_statements).
  • Network accessibility. Other services can run migrations / analytics against the DB; SQLite requires the file to be local to the OpenFGA container.
  • Larger datasets. At ~50 tuples SQLite is trivially fine, but per the growth model §4, once you reach thousands of users + many tenants/backends,
    Postgres indexes and connection pooling matter.
  • Consistent with the rest of the stack. Vault/Dex/libcloud already run as separate services; introducing Postgres fits the deployment style and lets
    you centralize secrets/TLS.

  Cons

  • New moving part / SPOF. Unless you also stand up Postgres HA, the DB becomes a single point of failure for all authz checks. SQLite-on-volume
    currently "just works" with no extra service.
  • Operational overhead. Another container/process to run, patch, back up, monitor, size; more CPU/RAM than an 86 KB SQLite file.
  • Network dependency & latency. Every Check/Write now goes over TCP to Postgres (mitigated by OpenFGA's in-memory cache, but cold checks add latency vs.
    local file).
  • Migration work. The current SQLite DB has drifted from INITIAL_TUPLES (legacy role:*, api_scope:*, tenant:default tuples + 2 model versions).
    Re-running the idempotent bootstrap against Postgres will not reproduce the legacy tuples — you must export the 50 tuples and re-import them, or
    accept a clean re-seed.
  • Secret management. DB credentials must be stored securely (Vault) rather than the current no-creds SQLite file.
  • More complex local dev. Contributors no longer get a zero-config file DB; they need a Postgres container or docker compose profile.
  • Risk of schema/lock surprises. OpenFGA's Postgres migration must match the OpenFGA image version; running migrate with a mismatched image can require
    manual cleanup.
  • Backup/restore procedure change. Replace volume snapshot with pg_dump + WAL archiving; need a tested restore drill.

  7. Requirements for setting up PostgreSQL as the OpenFGA datastore

  1. PostgreSQL server. A Postgres instance reachable from the OpenFGA container — either a new service in docker-compose.yml (image postgres:16, its own
     volume, healthcheck, restart: unless-stopped, on libcloud_net) or an external managed Postgres. OpenFGA currently requires PostgreSQL ≥ 12 (verify
     against the exact openfga-local:latest image version you run).
  2. Database + credentials. A dedicated database (e.g. openfga) and a dedicated role/user with privileges to create the schema on first migration and
     then SELECT/INSERT/UPDATE/DELETE on OpenFGA's tables. Do not reuse a shared app user.
  3. Connection string (DSN). Form postgres://USER:PASS@HOST:5432/DB?sslmode=verify-full. Store USER/PASS in Vault (or generated/), not in .env.
  4. Network connectivity. Postgres must be on libcloud_net (or reachable from it) and only exposed internally; do not publish 5432 to the host in prod.
  5. TLS. sslmode=verify-full with a CA cert the OpenFGA container trusts (mount the CA into the container). For dev, sslmode=disable is acceptable.
  6. Run the OpenFGA migration before starting the server, replacing the current SQLite migrate command:

     openfga migrate \
       --datastore-engine=postgres \
       --datastore-uri='postgres://openfga:***@postgres:5432/openfga?sslmode=verify-full'

  7. Update docker-compose.yml:
    • openfga-migrate: change --datastore-engine to postgres and --datastore-uri to the DSN; remove the openfga-data volume mount (or keep it only for
      non-DB artifacts).
    • openfga: same --datastore-engine/--datastore-uri change; keep OIDC auth flags unchanged.
    • Add a postgres service with a named volume for /var/lib/postgresql/data, POSTGRES_DB/USER/PASSWORD env, and a pg_isready healthcheck; make
      openfga-migrate depends_on it being healthy.
  8. Environment variables. Introduce OPENFGA_DATASTORE_ENGINE, OPENFGA_DATASTORE_URI, POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB, and source them in
     compose. Keep OIDC settings (OPENFGA_AUTHN_METHOD, OPENFGA_AUTHN_OIDC_ISSUER, OPENFGA_AUTHN_OIDC_AUDIENCE) as-is.
  9. Data migration from existing SQLite. Export the 50 live tuples and 2 authorization models from openfga.sqlite (or via OpenFGA read API against the
     current container) and re-write them against the Postgres-backed OpenFGA. Decide explicitly whether to keep the legacy role:* / api_scope:* /
     tenant:default tuples or re-seed cleanly from openfga_bootstrap.py's INITIAL_TUPLES. Either way, run validate() afterward.
  10. Backups. Schedule pg_dump (or WAL archiving + base backups for PITR) of the openfga DB; define retention and a tested restore procedure. Keep a
      one-time copy of the old openfga.sqlite for rollback.
  11. Capacity planning. Using §4's growth model, size Postgres for tuple + changelog rows (changelog grows monotonically with writes — add a
      retention/prune policy if you don't keep it forever).
  12. HA (optional but recommended for prod). Postgres primary + replica, and ≥2 OpenFGA replicas behind a load balancer; only possible once SQLite is
      gone.
  13. Observability. Enable the Postgres exporter for Prometheus; keep OpenFGA's :2112 metrics port; ship OpenFGA + Postgres logs to the same destination
      as today's generated/openfga_audit.log.
  14. Security. Restricted DB user, sslmode=verify-full, no published DB port, network policies, DB creds in Vault, and periodic credential rotation.
      Tuple mutations remain gated by the superadmin Dex JWT (unchanged).
  15. Rollback plan. Document how to fall back to SQLite (keep the volume, keep the old compose file in git, keep the tuple export). Test a forward +
      backward migration in a staging environment before touching prod.
  16. Version pinning. Pin the Postgres major version and the OpenFGA image; re-run openfga migrate whenever you upgrade OpenFGA (migrations are
      forward-only across major versions in some releases).
  17. Validation gate. Re-run openfga_bootstrap.py's 28 VALIDATION_CHECKS against the Postgres-backed server and require all green before cutting traffic;
      also replay a few representative Check calls from the libcloud REST API (../libcloud.rest/app/auth/policy.py) to confirm end-to-end behavior.

