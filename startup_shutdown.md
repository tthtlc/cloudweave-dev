  How to::::Teardown & migration to a different machine

  The key insight: all durable state lives in Docker named volumes plus the generated/*.env files. Containers, images, and the libcloud_net network are
  recreatable. Migrate the volumes + generated env files, then re-run setup.sh.

  A. Pre-flight (capture state on the old machine)

  1. Take a Postgres backup as belt-and-suspenders (the volume itself will also be moved):

     cd openfga_postgres && ./scripts/pg_dump.sh

  2. Record the current container/volume layout:

     docker ps --format '{{.Names}}\t{{.Image}}' > docker.out.bak
     docker volume ls | rg 'lldap_data|vault-data|openfga-pg-data|openfga-data|api-data'

  B. Stop services cleanly (keep data)

  cd libcloud.rest      && docker compose down
  cd ../openfga_postgres&& docker compose down        # keeps openfga-pg-data
  cd ../dex             && docker compose down
  cd ../vault           && docker compose down        # keeps vault-data
  cd ../lldap           && docker compose down        # keeps lldap_data
  cd ../stoplight_mock  && docker compose down
  docker network rm libcloud_net                       # recreated by setup.sh on the new host

  Do not use down -v anywhere — that wipes the volume you want to migrate.

  C. Export the durable artifacts

  1. Named volumes — back up each volume to a tarball (run on the old host):

     for v in lldap_data vault-data openfga-pg-data api-data; do
       docker run --rm -v ${v}:/src -v "$PWD":/dst alpine \
         tar czf /dst/${v}.tgz -C /src .
     done

     (If you keep the SQLite rollback path, also grab openfga-data.)
  2. Generated env + config files — these are the identity of the deployment and must travel with the volumes (secrets are encrypted at rest only inside
     Vault; these files are the keys to it):
    • openfga_postgres/generated/ (incl. fga.env, postgres.env, tokens/)
    • dex/generated/dex.env and the rendered dex/config.yaml
    • vault/generated/vault.env
    • libcloud.rest/.env
    • lldap/.env
    • the openfga_pg_dump_*.sql from step A.1
  3. Transfer everything (tarballs + the listed files) to the new machine over a secure channel. These contain root tokens, unseal keys, and passwords —
     protect them accordingly.

  HOW TO:::: Restore on the new machine

  1. Install prerequisites: Docker + Compose v2; clone the repo (same path layout so the ../dex, ../vault, etc. references in setup.sh resolve).
  2. Place the generated files at their original paths (dex/generated/dex.env, vault/generated/vault.env, openfga_postgres/generated/*,
     libcloud.rest/.env, lldap/.env).
  3. Restore the named volumes:

     for v in lldap_data vault-data openfga-pg-data api-data; do
       docker volume create ${v}
       docker run --rm -v ${v}:/dst -v "$PWD":/src alpine \
         tar xzf /src/${v}.tgz -C /dst
     done

  4. Build the OpenFGA image once (openfga_postgres/setup.sh builds it
     automatically from ./Dockerfile on first run; to build it manually):

     ( cd openfga_postgres && docker compose build openfga )

  5. Re-run the orchestrator — because the generated/*.env files are present, it reuses the existing Postgres password, OIDC client secret, Vault root
     token/unseal key, and LLDAP bind DN, so the restored volumes remain valid:

     cd openfga_postgres && ./setup.sh

     What happens on restore: libcloud_net is recreated; LLDAP/Postgres/Vault/Dex/OpenFGA come up against the restored volumes; openfga migrate is a no-op
  (schema already present); Vault is unsealed using the restored VAULT_UNSEAL_KEY; the superadmin login re-authenticates against LLDAP; openfga-bootstrap
  clean re-seeds tuples (Postgres already has them, but the seed is idempotent); and the new FGA_STORE_ID/FGA_MODEL_ID + VAULT_TOKEN are synced into
  libcloud.rest/.env.
  6. Verify:

     docker ps                                  # 8 healthy containers as in docker.out
     openfga_postgres/scripts/pg_query.sh -c 'select count(*) from tuple;'   # expect 17
     curl -fsS http://localhost:5556/dex/.well-known/openid-configuration
     curl -fsS http://localhost:8765/health
     LIBCLOUD_USER=aws-admin openfga_postgres/scripts/provision_aws.sh       # end-to-end smoke

  Caveats to handle during migration

  • Dex signing keys live in memory (storage.type: memory), so they are not in any volume — setup.sh re-mints them and restarts OpenFGA to flush its
    cached JWKS (setup.sh:224-231). Already-issued refresh tokens in generated/tokens/*.json will be invalid; users just re-login. The OIDC client secret
    is reused (kept in dex.env), so the client boundary stays stable.
  • iss claim is http://dex:5556/dex (container DNS), independent of host, so no JWT issuer reconfiguration is needed when moving hosts — only
    host-published ports change if you override *_PORT vars.
  • OpenFGA store/model IDs are Postgres-row IDs that travel inside the openfga-pg-data volume, so generated/fga.env and the restored volume must move
    together. If you restore the volume but use a stale fga.env, setup.sh step 8 will re-sync libcloud.rest/.env to the volume's actual IDs.
  • Vault: restoring the vault-data volume + vault.env (root token + unseal key) is sufficient; vault_bootstrap.py detects initialized state and only
    unseals + re-issues/validates the read token. Never restore a vault-data volume without its matching vault.env — the encrypted blob is useless without
    the unseal key.
  • LLDAP base DN (dc=libcloud,dc=local) is anchored to existing DNs; keep lldap/.env's LLDAP_LDAP_BASE_DN identical.
  • The Nutanix mock (stoplight_mock) holds only in-memory state — nothing to migrate; just docker compose up -d on the new host. If you instead target a
    real Prism Central, the mock is not needed at all.

  The one-line summary: move four named volumes (lldap_data, vault-data, openfga-pg-data, api-data) plus the generated/*.env files, then run 
  openfga_postgres/setup.sh — everything else is code and images that the script rebuilds/recreates.


