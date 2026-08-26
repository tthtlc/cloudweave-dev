 I now have a complete picture. Here is the explanation.

==================

d4024b2b22f1   libcloud-rest-api:latest     "/entrypoint.sh uvic…"   3 hours ago   Up 3 hours (healthy)   0.0.0.0:8765->8765/tcp, [::]:8765->8765/tcp                                                                    libcloud-rest-api
5f991dec8f4e   openfga-local:latest         "/openfga run --data…"   3 hours ago   Up 3 hours (healthy)   0.0.0.0:2112->2112/tcp, [::]:2112->2112/tcp, 0.0.0.0:8080-8081->8080-8081/tcp, [::]:8080-8081->8080-8081/tcp   openfga
8dae84ba5e3d   ghcr.io/dexidp/dex:v2.41.1   "/usr/local/bin/dock…"   3 hours ago   Up 3 hours (healthy)   0.0.0.0:5556->5556/tcp, [::]:5556->5556/tcp                                                                    dex
f24832ae27cf   postgres:16                  "docker-entrypoint.s…"   3 hours ago   Up 3 hours (healthy)   0.0.0.0:5433->5432/tcp, [::]:5433->5432/tcp                                                                    openfga-postgres
2c680020ec84   lldap/lldap:latest           "tini -- /docker-ent…"   2 weeks ago   Up 13 days (healthy)   0.0.0.0:3890->3890/tcp, [::]:3890->3890/tcp, 0.0.0.0:17170->17170/tcp, [::]:17170->17170/tcp                   lldap
61946a99820c   hashicorp/vault:1.15         "docker-entrypoint.s…"   2 weeks ago   Up 13 days (healthy)   0.0.0.0:8200->8200/tcp, [::]:8200->8200/tcp                                                                    vault
390c2af396c5   stoplight_mock-emulator      "/entrypoint.sh"         2 weeks ago   Up 13 days (healthy)   0.0.0.0:9440->9440/tcp, [::]:9440->9440/tcp                                                                    stoplight_mock-emulator-1
bf8b4249d01f   stoplight/prism:5            "/sbin/tini -- node …"   2 weeks ago   Up 13 days             0.0.0.0:4010->4010/tcp, [::]:4010->4010/tcp                                                                    stoplight_mock-prism-1
==================

  1. The running system

  docker.out is a docker ps snapshot of the live stack. There are 8 containers grouped into four sibling compose projects plus the Nutanix mock. All
  long-running services sit on a shared external Docker bridge network libcloud_net so they reach each other by container-name DNS; host scripts use the
  published ports.

  Identity layer

  lldap — lldap/lldap:latest (lldap/), ports 3890 (LDAP) / 17170 (web UI + GraphQL).
  The sole user directory. Every principal (superadmin, aws-owner/admin/viewer, ntnx-owner/admin/viewer, cloud-denied) lives here as an LLDAP uid with mail,
  cn, and three custom attributes (department, role, jobtitle). State persists on the named volume lldap_data (lldap/ARCHITECTURE.md §Container topology).
  Dex binds to it over LDAP to verify passwords; Vault binds to it in real time for auth/ldap. Human passwords never leave LLDAP.

  dex — ghcr.io/dexidp/dex:v2.41.1 (dex/), port 5556.
  The stable OIDC issuer — the front door every client and every relying party trusts. Dex owns no users of its own (storage.type: memory, no
  staticPasswords); it federates authentication to LLDAP via an LDAP connector (dex/ARCHITECTURE.md §3). It registers a single OAuth client libcloud-rest
  and mints JWTs whose sub is the LLDAP uid and whose iss/aud are http://dex:5556/dex / libcloud-rest. The same token is therefore accepted by both the
  libcloud REST API and OpenFGA. Note: in-memory storage means docker compose down drops OAuth/refresh state (users just re-login); user identity is
  untouched because it lives in LLDAP.

  Authorization layer

  openfga — openfga-local:latest (openfga_postgres/), ports 8080 (HTTP) / 8081 (gRPC) / 2112 (metrics).
  The fine-grained ReBAC policy engine. Started with --authn-method=oidc --authn-oidc-issuer=http://dex:5556/dex --authn-oidc-audience=libcloud-rest, so it
  validates the caller's Dex JWT on every API call and then evaluates relationship tuples (can_connect, can_use, can_provision, can_read,
  can_manage_credentials). OpenFGA is datastore-agnostic above the storage layer; the binary is built once in openfga_my and reused as openfga-local:latest.

  openfga-postgres — postgres:16 (openfga_postgres/), port 5433 (host) → 5432 (container).
  The production datastore for OpenFGA, replacing the beta/single-node SQLite in openfga_my. Holds the store, authorization_model, tuple, and changelog
  tables. State persists on the named volume openfga-pg-data (openfga_postgres/docker-compose.yml:36). Migrations are applied by a one-shot openfga-migrate
  container (openfga migrate --datastore-engine=postgres) before openfga starts (openfga_postgres/docker-compose.yml:48-60). Host port 5433 is for debugging
  only — do not publish in prod.

  Secrets layer

  vault — hashicorp/vault:1.15 (vault/), port 8200.
  The encrypted-at-rest secret store for everything that is not a human password: cloud-provider root credentials (AWS key/secret, Nutanix user/password)
  stored as KV v2 under secret/libcloud/<tenant>, plus Vault's own root token / unseal key / libcloud REST read token (written to generated/vault.env, not
  into KV). File storage on the named volume vault-data (vault/ARCHITECTURE.md §3). Starts sealed on every fresh boot; vault_bootstrap.py unseals it using
  VAULT_UNSEAL_KEY. The libcloud REST API reads tenant creds at request time with a least-privilege read-only token; OpenFGA gates who may write
  (can_manage_credentials, owner-only) — vault/ARCHITECTURE.md §7.

  API gateway layer

  libcloud-rest-api — libcloud-rest-api:latest (libcloud.rest/), port 8765.
  The unified provider-neutral REST facade built on FastAPI + Apache Libcloud. It is not a reverse proxy to AWS/Nutanix URLs; each route validates the
  Bearer JWT against Dex JWKS, resolves the principal via data/principal_map.json, enforces OAuth-style scopes + provider allowlists (app/auth/policy.py),
  calls OpenFGA for backend policy, then translates the call into either an AWS EC2 Query action or a Nutanix v4 REST request via app/providers/factory.py
  (system_design/ARCHITECTURE.md §3-4). Cloud credentials travel in every request via the connection object (or are fetched from Vault per-tenant). Small
  persistent state (data/users.json local-auth fallback, audit log) on the named volume api-data.

  Nutanix mock layer (development only)

  stoplight_mock-emulator-1 (stoplight_mock/mock/), port 9440 (HTTPS, self-signed).
  A stateful Node.js/Express shim that implements real CRUD + async-task lifecycle for the subset of Nutanix v4 endpoints that need behavior (VMs, subnets,
  VPCs, floating IPs, volume groups, tasks, …), holding state in in-memory Maps (stoplight_mock/ARCHITECTURE.md §4). Stand-in for a real Prism Central so
  the stack can be exercised end-to-end without a Nutanix cluster.

  stoplight_mock-prism-1 — stoplight/prism:5 (stoplight_mock/), port 4010.
  A stateless OpenAPI 3 mock server reading spec/openapi.json (487 paths, 2206 schemas). The emulator proxies any path it does not handle itself to Prism,
  which answers with schema-valid example responses (stoplight_mock/ARCHITECTURE.md §4.4). Auth schemes are stripped, so neither tier enforces auth.

  How the request flows (system_design/ARCHITECTURE.md §8)

  provision_*.sh → Dex login (LLDAP verifies pw) → JWT (sub=aws-admin)
    → libcloud REST: verify JWT (Dex JWKS) → resolve principal → scope+provider check
    → OpenFGA Check (can_use / can_provision) → build_driver(connection)
    → AWS EC2 Query API  OR  Nutanix Prism v4 (real, or the stoplight mock on :9440)

  2. Directories & files (see each */ARCHITECTURE.md)

  ┌────────────┬────────────────────────────────────────────────┬──────────────────────────────────────────────────────────────────────────────────────────┐
  │ Directory  │ Role                                           │ Key files                                                                                │
  ├────────────┼────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤
  │ lldap/     │ User directory                                 │ docker-compose.yml, bootstrap/user-schemas/custom-attributes.json,                       │
  │            │                                                │ scripts/{setup-schema,create-user,set-password,verify-ldap}                              │
  ├────────────┼────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤
  │ dex/       │ OIDC issuer                                    │ config.template.yaml → rendered config.yaml (mounted ro), generated/dex.env              │
  ├────────────┼────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤
  │ openfga_po │ Authz engine + Postgres datastore              │ docker-compose.yml, setup.sh, openfga_bootstrap.py, dex_bootstrap.py,                    │
  │ stgres/    │                                                │ vault_bootstrap.py, data/principal_map.json, generated/{fga,postgres}.env                │
  ├────────────┼────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤
  │ openfga_my │ SQLite sibling (rollback path; also the place  │ docker-compose.yml, setup.sh                                                             │
  │ /          │ openfga-local:latest is built)                 │                                                                                          │
  ├────────────┼────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤
  │ vault/     │ Secrets                                        │ config.hcl, docker-compose.yml, {add,delete,list}_credential.py, generated/vault.env     │
  ├────────────┼────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤
  │ libcloud.r │ REST gateway                                   │ app/{auth,compute,network,providers,connections,jobs}/, Dockerfile, .env                 │
  │ est/       │                                                │                                                                                          │
  ├────────────┼────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤
  │ libcloud/  │ Apache Libcloud driver source (Nutanix v4      │ libcloud/compute/drivers/nutanix.py, libcloud/common/nutanix.py                          │
  │            │ driver)                                        │                                                                                          │
  ├────────────┼────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤
  │ stoplight_ │ Nutanix mock                                   │ mock/server.js, spec/openapi.json, scripts/merge-specs.js                                │
  │ mock/      │                                                │                                                                                          │
  ├────────────┼────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤
  │ system_des │ Cross-cutting design docs                      │ ARCHITECTURE.md, IDENTITY.md, authorization.md                                           │
  │ ign/       │                                                │                                                                                          │
  └────────────┴────────────────────────────────────────────────┴──────────────────────────────────────────────────────────────────────────────────────────┘

  Runtime-generated, gitignored, must be carried across a migration: openfga_postgres/generated/{fga,postgres}.env, dex/generated/dex.env,
  vault/generated/vault.env, openfga_postgres/generated/tokens/*.json (cached OIDC refresh tokens), libcloud.rest/.env, lldap/.env.

  3. Role of openfga_postgres/setup.sh

  It is the single end-to-end bootstrap orchestrator for the Postgres-backed stack. It is the Postgres equivalent of ../openfga_my/setup.sh; everything
  above the storage layer is identical. Reading openfga_postgres/setup.sh:30-404, the steps are:

  1. (0a) Generate/reuse POSTGRES_PASSWORD into generated/postgres.env (reused across re-runs so the openfga-pg-data volume stays usable) —
     setup.sh:69-92.
  2. (0b) Verify the prebuilt openfga-local:latest image exists (built once in openfga_my) — setup.sh:98-103.
  3. (0c) Create libcloud_net if missing; remove any stale openfga/openfga-migrate/openfga-bootstrap containers owned by a different compose project so
     the names/ports are free (the SQLite stack must be torn down first) — setup.sh:106-128.
  4. Reuse/generate the LIBCLOUD_OIDC_CLIENT_SECRET so the Dex issuer boundary and existing refresh tokens stay stable across re-runs/migration —
     setup.sh:134-144.
  5. (1) Render dex/config.yaml + write dex/generated/dex.env (LDAP connector + per-user passwords) via dex_bootstrap.py — setup.sh:149-157.
  6. (2) Start LLDAP, apply the custom-attribute schema, and create the superadmin break-glass user via the LLDAP admin account — setup.sh:163-179.
  7. (3) Start Postgres, wait for healthcheck, run openfga-migrate (--datastore-engine=postgres), start openfga, then Dex and Vault. Restart OpenFGA after
     Dex key rotation to flush its cached JWKS — setup.sh:186-236.
  8. (4) Perform the superadmin Dex login → SUPERADMIN_JWT. This is the gate for everything below (setup.sh:243-247).
  9. (5) Create the per-cloud tenant users in LLDAP (owner/admin/viewer for aws + nutanix, plus cloud-denied), gated by the superadmin JWT —
     setup.sh:254-261.
  10. (6) Run openfga-bootstrap — clean re-seed of store + authorization model + INITIAL_TUPLES (17 tuples) against Postgres, then VALIDATION_CHECKS
      (superadmin-gated) — setup.sh:270-271.
  11. (7) Run vault-bootstrap — init/unseal/enable KV v2/issue the read token; seed backend cloud credentials from the operator's environment
      (superadmin-gated) — setup.sh:278-279.
  12. (8) Sync the new FGA_STORE_ID/FGA_MODEL_ID (Postgres mints fresh IDs; the SQLite store id does not carry over) and VAULT_ADDR/VAULT_TOKEN into
      libcloud.rest/.env, and recreate the REST API container so it points at the Postgres-backed store and Vault — setup.sh:288-363.

  In short, setup.sh is what turns eight empty containers into a coherent, mutually-trusting, superadmin-gated system. It is idempotent and migration-safe:
  it reuses existing passwords/IDs/secrets when generated/*.env are present, and only mints new ones on first boot.


