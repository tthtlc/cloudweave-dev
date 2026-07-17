
  I'll re-run the end-to-end check fresh: build the app and confirm build_driver resolves credentials through a Vault mock and constructs the AWS driver.

  $ cd /home/ubuntu/libcloud_nutanix/libcloud.rest && ([ -d .venv ] && . .venv/bin/activate 2>/dev/null); VAULT_ADDR= VAULT_TOKEN= python3 -c "
    import os, json, threading 4.9s
    … 40 input + 1 output lines hidden · ctrl+o to expand
    driver.key (resolved from Vault): vaultkey
    ASSERT PASS: build_driver resolved credentials through Vault mock

  Confirmed end-to-end:

  • The app builds and imports cleanly.
  • build_driver was called with a credential-free ProviderConnection (provider=aws, region, auth_binding=aws — no credentials field).
  • It resolved the backend credentials from the Vault KV v2 mock and constructed the real EC2NodeDriver.
  • The driver's resolved key (vaultkey) matches the Vault secret, proving the credentials came from Vault, not from env (the env fallback was deliberately
    blanked).

  This validates the full chain: build_driver → effective_credentials → enforce_credential_policy (client creds rejected/absent) → resolve_server_credentials
  → VaultClient.read_secret("aws") → EC2NodeDriver.

                                                                                                                                                                 
  provide instructions on the entire setup: how to build all the docker, startup and run the system. then update the system with new cloud admin users           
  etc.                                                                                                                                                           
                                                                                                                                                                 

  I'll gather the key files so the instructions match the actual code, then write up the full setup + user-management guide.

    Globbed, read 1 glob, 3 files
    Globbed "dex/config*.{yaml,yml,template}" in .
    Read scripts/idp_login.py
    Read dex/config.template.yaml
    Read openfga_bootstrap.py lines 1-60

  Let me look at the seed tuples and principal mapping to document user management accurately.

    Grepped "...ly|cloud-denied|tenant:default|member" in openfga_bootstrap.py
    Found 79 matches  (truncated)

  $ cd /home/ubuntu/libcloud_nutanix/libcloud.rest && ls data/ 2>/dev/null; echo "---principal_map---"; cat data/principal_map.json 2>/dev/null || echo "(no
    principal_map.json)" 3.8s
    … 17 output lines hidden · ctrl+o to expand
      }
    }

    Read openfga_bootstrap.py lines 410-449

  Here's the complete setup and operations guide, based on the actual code in the two compose projects.

  ────────────────────────────────────────

  System layout

  Two Docker Compose projects, side by side:

  ┌────────────────────────────┬────────────────┬─────────────────────────────────────────────────────────────────────────────────────────────┐
  │ Project                    │ Path           │ What it runs                                                                                │
  ├────────────────────────────┼────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Identity + Authz + Secrets │ openfga_my/    │ OpenFGA (sqlite, volume), Dex (OIDC), Vault (encrypted cloud creds), one-shot bootstraps    │
  ├────────────────────────────┼────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────┤
  │ libcloud REST API          │ libcloud.rest/ │ FastAPI libcloud-rest-api (reads OIDC from Dex, authz from OpenFGA, cloud creds from Vault) │
  └────────────────────────────┴────────────────┴─────────────────────────────────────────────────────────────────────────────────────────────┘

  Persistence (survives reboot / docker compose down):
  • openfga-data volume → OpenFGA sqlite (stores/models/tuples)
  • vault-data volume → Vault seal state + encrypted secrets
  • api-data volume → libcloud REST API data/ (users, principal map, audit log)
  • Host bind mounts openfga_my/generated/, openfga_my/dex/ → rendered Dex config + bootstrap env files

  ────────────────────────────────────────

  1. Prerequisites

  • Docker + Docker Compose v2
  • python3 on the host (used by setup.sh and provisioning scripts)
  • Ports free: 5556 (Dex), 8080/8081/2112 (OpenFGA), 8200 (Vault), 8765 (REST API)

  ────────────────────────────────────────

  2. Configure environment files

  openfga_my/.env (created from .env.example on first setup.sh run). Fill in:
  • LIBCLOUD_OIDC_CLIENT_SECRET — leave blank; setup.sh generates it.
  • LIBCLOUD_AWS_PROD_KEY / LIBCLOUD_AWS_PROD_SECRET — seed values for Vault only. These get written to Vault as encrypted KV v2 secrets, then the API reads
    them from Vault (not from env).
  • LIBCLOUD_NTNX_LAB_USER / LIBCLOUD_NTNX_LAB_PASSWORD — same, seeded into Vault.
  • ALLOW_DEV_DEFAULTS=1 — only if you want the embedded Dex bootstrap passwords (CloudAdmin123! etc.) to work without setting LIBCLOUD_PASSWORD_*.

  libcloud.rest/.env — normally maintained by setup.sh, which syncs FGA_STORE_ID, FGA_MODEL_ID, VAULT_ADDR, VAULT_TOKEN from openfga_my/generated/*.env. Leave
  LIBCLOUD_AWS_PROD_* / LIBCLOUD_NTNX_LAB_* blank there (Vault is the source of truth; env is only a dev fallback).

  ────────────────────────────────────────

  3. Build & start everything

  From openfga_my/:

  cd /home/ubuntu/libcloud_nutanix/openfga_my
  ./setup.sh

  setup.sh does, in order:
  1. Copies .env.example → .env if missing.
  2. Renders dex/config.yaml and generates LIBCLOUD_OIDC_CLIENT_SECRET.
  3. docker compose up -d --build openfga dex vault (rebuilds the openfga-local image only when the Dockerfile/binary changed).
  4. Runs openfga-bootstrap (creates/reuses the OpenFGA store + model + seed tuples — idempotent).
  5. Runs vault-bootstrap (init/unseal Vault, enable KV v2, issue a least-privilege read token, seed AWS + Nutanix creds into secret/libcloud/*).
  6. Syncs FGA_STORE_ID/FGA_MODEL_ID/VAULT_ADDR/VAULT_TOKEN into ../libcloud.rest/.env and recreates the API container if it's running.
  7. Reloads Dex with the OAuth client secret.

  Output env files (gitignored): generated/fga.env, generated/dex.env, generated/vault.env.

  Then start the REST API:

  cd /home/ubuntu/libcloud_nutanix/libcloud.rest
  docker compose up -d --build api

  (If setup.sh already recreated it, this is a no-op.)

  ────────────────────────────────────────

  4. Verify it's up

  cd /home/ubuntu/libcloud_nutanix/openfga_my
  docker compose ps                       # openfga, dex, vault healthy
  docker compose -f ../libcloud.rest/docker-compose.yml ps   # libcloud-rest-api healthy
  curl -fsS http://localhost:8080/healthz            # OpenFGA
  curl -fsS http://localhost:5556/dex/.well-known/openid-configuration
  curl -fsS http://localhost:8765/health             # REST API
  docker exec vault vault status -format=json | head # Vault sealed=false

  ────────────────────────────────────────

  5. Run the system (provisioning demo)

  The client scripts log in to Dex (OIDC), run advisory OpenFGA pre-checks, then call the REST API with a bearer token. The API enforces OpenFGA per request
  and uses its own cloud identity from Vault. The client never touches cloud credentials.

  cd /home/ubuntu/libcloud_nutanix/openfga_my
  # Full provisioning path (dry-run unless PROVISION=1)
  LIBCLOUD_USER=cloud-admin    ./scripts/provision_aws.sh
  LIBCLOUD_USER=cloud-readonly ./scripts/provision_aws.sh      # read-only path
  LIBCLOUD_USER=provisioner    PROVISION=1 ./scripts/provision_aws.sh   # actually create EC2
  # Nutanix
  LIBCLOUD_USER=cloud-admin    ./scripts/provision_nutanix.sh
  # Verbose HTTP tracing (secrets redacted)
  VERBOSE=1 LIBCLOUD_USER=cloud-admin ./scripts/provision_aws.sh

  Password resolution: explicit LIBCLOUD_PASSWORD (or LIBCLOUD_PASSWORD_CLOUD_ADMIN etc.) wins; otherwise the generated generated/dex.env passwords; otherwise
  embedded dev defaults only if ALLOW_DEV_DEFAULTS=1.

  ────────────────────────────────────────

  6. Reboot / restart behavior

  • restart: unless-stopped is set on all long-lived services, so they come back after a host reboot.
  • OpenFGA store/model IDs are stable across restarts (sqlite on openfga-data). You do not need to re-run setup.sh after a reboot — docker compose up -d is
    enough.
  • Vault stays initialized/unsealed across restarts (vault-data).
  • To intentionally wipe state: docker compose down -v (deletes openfga-data + vault-data). Re-running setup.sh then re-initializes everything.

  ────────────────────────────────────────

  7. Updating the system — add a new cloud-admin user

  A "cloud-admin" user = can log in to Dex + maps to the cloud-admin principal + has role:admin in OpenFGA (already seeded). The cleanest path is to reuse the
  cloud-admin principal via an email mapping — no code changes, no OpenFGA tuple edits.

  Step 1 — generate a bcrypt hash for the new user's password

  # Using apache2-utils:
  htpasswd -bnBC 10 "" 'NewAdminPass123!' | tr -d ':\n' | sed 's/^\$2y\$/\$2b\$/'
  # → $2b$10$.......

  Step 2 — add the user to Dex

  Edit openfga_my/dex/config.template.yaml, add a staticPasswords entry:

  staticPasswords:
    - email: alice@libcloud.local
      username: alice
      userID: alice
      hash: "$2b$10$.......your-hash......."

  Step 3 — map the new email to the cloud-admin principal

  Edit libcloud.rest/data/principal_map.json:

  "by_email": {
    "cloud-admin@libcloud.local": "cloud-admin",
    "cloud-readonly@libcloud.local": "cloud-readonly",
    "cloud-denied@libcloud.local": "cloud-denied",
    "alice@libcloud.local": "cloud-admin"
  }

  (The cloud-admin principal already has role:admin + tenant membership in OpenFGA, so Alice inherits full admin.)

  Step 4 — (optional) add a script alias so LIBCLOUD_USER=alice resolves the Dex login email

  scripts/idp_login.py already maps any unknown username to <username>@libcloud.local, so LIBCLOUD_USER=alice works automatically. If you want a non-email
  login id, add it to USER_EMAIL in scripts/idp_login.py.

  Step 5 — apply

  cd /home/ubuntu/libcloud_nutanix/openfga_my
  ./setup.sh                                # re-renders dex/config.yaml + reloads Dex
  docker compose restart dex
  # principal_map.json is bind-mounted into the API via api-data? — see note below
  docker compose -f ../libcloud.rest/docker-compose.yml restart api

  │ Note: principal_map.json lives in libcloud.rest/data/, which is the api-data named volume, not a bind mount. To update it inside the running container:
  │ `bash
  │ docker cp libcloud.rest/data/principal_map.json libcloud-rest-api:/app/data/principal_map.json
  │ docker compose -f ../libcloud.rest/docker-compose.yml restart api
  │ `
  │ (The principal map is read fresh per request via _load_map() cache, but restarting clears the cache cleanly.)

  Step 6 — log in as the new user

  LIBCLOUD_USER=alice LIBCLOUD_PASSWORD='NewAdminPass123!' ./scripts/provision_aws.sh

  ────────────────────────────────────────

  7b. Adding a brand-new principal/role (not reusing cloud-admin)

  Only needed if you want a distinct identity with custom scopes. This is a code change:

  1. libcloud.rest/app/auth/identity.py — add the principal to PRINCIPAL_SCOPES (scope list) and PRINCIPAL_PROVIDERS (allowed providers). Optionally add a
     legacy alias in LEGACY_USERNAME_ALIASES.
  2. openfga_my/openfga_bootstrap.py INITIAL_TUPLES — add e.g. {"user":"user:NEW","relation":"member","object":"role:admin"} and
     {"user":"user:NEW","relation":"member","object":"tenant:default"}.
  3. libcloud.rest/data/principal_map.json — map the Dex email → the new principal slug.
  4. Rebuild + re-bootstrap:

     cd libcloud.rest && docker compose up -d --build api
     cd ../openfga_my && docker compose up --no-deps openfga-bootstrap

  ────────────────────────────────────────

  8. Rotate / update cloud backend credentials (in Vault)

  1. Edit openfga_my/.env — update LIBCLOUD_AWS_PROD_KEY / LIBCLOUD_AWS_PROD_SECRET / LIBCLOUD_NTNX_LAB_*.
  2. Re-seed Vault and reload the API:

     cd /home/ubuntu/libcloud_nutanix/openfga_my
     docker compose up --no-deps vault-bootstrap
     docker compose -f ../libcloud.rest/docker-compose.yml up -d --force-recreate api

     (Or just re-run ./setup.sh, which does both plus the sync.)

  The API reads the new values from Vault on the next request (30 s in-process cache). Clients are unaffected — they never see cloud credentials.

  ────────────────────────────────────────

  9. Tear down / clean start

  # Stop everything, keep persistent volumes:
  cd openfga_my && docker compose down
  cd ../libcloud.rest && docker compose down
  # Full wipe (also deletes OpenFGA + Vault state — re-init required):
  cd openfga_my && docker compose down -v
  cd ../libcloud.rest && docker compose down -v
  # Then remove generated env so setup re-creates them:
  rm -rf openfga_my/generated openfga_my/dex/config.yaml

  ────────────────────────────────────────

  Quick reference — what lives where

  ┌────────────────────────────────────────────────┬───────────────────────────────────────────────────────────────────┐
  │ Thing                                          │ Location                                                          │
  ├────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────┤
  │ Dex users (passwords)                          │ openfga_my/dex/config.template.yaml → rendered to dex/config.yaml │
  ├────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────┤
  │ OIDC client secret                             │ openfga_my/generated/dex.env                                      │
  ├────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────┤
  │ OpenFGA store/model IDs                        │ openfga_my/generated/fga.env (synced into libcloud.rest/.env)     │
  ├────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────┤
  │ OpenFGA authz tuples                           │ openfga_my/openfga_bootstrap.py INITIAL_TUPLES                    │
  ├────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────┤
  │ Principal mapping (IdP email → principal slug) │ libcloud.rest/data/principal_map.json                             │
  ├────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────┤
  │ Principal scopes/providers                     │ libcloud.rest/app/auth/identity.py                                │
  ├────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────┤
  │ Cloud creds (encrypted, per-tenant, owner-set) │ Vault KV v2 secret/libcloud/aws, secret/libcloud/nutanix        │
  ├────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────┤
  │ Vault root token + unseal key + API read token │ openfga_my/generated/vault.env (gitignored, chmod 600)            │
  └────────────────────────────────────────────────┴───────────────────────────────────────────────────────────────────┘

  Want me to turn this into a README.md / OPERATIONS.md committed to the repo, or generate a bcrypt hash for a specific new username right now?
