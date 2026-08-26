  who are all the users of Vault for storage in the current system                                                                                             
    Grepped, read 1 grep, 2 files
    Grepped "[Vv]ault" in .
    Read vault/ARCHITECTURE.md
    Read libcloud.rest/app/connections/vault_client.py

  The Vault architecture doc is comprehensive. Let me also check the concrete tenants/users defined in the system to give a precise answer.

    Read, grepped 1 file, 1 grep
    Read openfga_my/terminologies.md
    Grepped "tenant:|owner|can_manage_credentials" in openfga_my

  Based on vault/ARCHITECTURE.md, openfga_my/terminologies.md, and libcloud.rest/app/connections/vault_client.py, here is the complete picture of who uses
  Vault for storage in this system.

  What Vault stores

  Vault is the encrypted at-rest secret store for everything in the stack that is not a human login password (those live in LLDAP). Specifically
  (vault/ARCHITECTURE.md lines 1-17):

  • Cloud-provider root credentials (AWS key/secret, Nutanix user/password, Azure/GCP/Alibaba service principals) as KV v2 secrets under
    secret/libcloud/<tenant>
  • Per-tenant backend credentials
  • Cloud-secrets-engine root creds at <mount>/config/root (e.g. aws/, azure/, gcp/, alic/)
  • The LLDAP service-account bind DN + password, stored inside Vault's auth/ldap/config (§6.2)
  • Vault-internal material (root token, unseal key, REST read token) — written to generated/vault.env, not inside Vault's KV

  The "users" of Vault — three categories

  1. Human identities (authenticate via LDAP → LLDAP)

  These LLDAP users log in to Vault through auth/ldap/login/<uid>, get short-lived tokens scoped to their group's policy (terminologies.md lines 72-85):

  ┌─────────────────────────────────────────────┬───────────────────────────────────┐
  │ Principal                                   │ Tenant role                       │
  ├─────────────────────────────────────────────┼───────────────────────────────────┤
  │ superadmin                                  │ break-glass owner on every tenant │
  ├─────────────────────────────────────────────┼───────────────────────────────────┤
  │ aws-owner                                   │ owner on tenant:aws               │
  ├─────────────────────────────────────────────┼───────────────────────────────────┤
  │ aws-admin                                   │ admin on tenant:aws               │
  ├─────────────────────────────────────────────┼───────────────────────────────────┤
  │ aws-viewer                                  │ viewer on tenant:aws              │
  ├─────────────────────────────────────────────┼───────────────────────────────────┤
  │ ntnx-owner                                  │ owner on tenant:nutanix           │
  ├─────────────────────────────────────────────┼───────────────────────────────────┤
  │ ntnx-admin                                  │ admin on tenant:nutanix           │
  ├─────────────────────────────────────────────┼───────────────────────────────────┤
  │ ntnx-viewer                                 │ viewer on tenant:nutanix          │
  ├─────────────────────────────────────────────┼───────────────────────────────────┤
  │ cloud-admin / cloud-readonly / cloud-denied │ legacy/default tenant principals  │
  └─────────────────────────────────────────────┴───────────────────────────────────┘

  Only the tenant owner (and superadmin) can write credentials — gated by OpenFGA's can_manage_credentials relation (terminologies.md line 103).
  admins/viewers can read per their bound Vault policy but are denied writes.

  2. Service / machine tokens (the token hierarchy)

  From vault/ARCHITECTURE.md lines 498-510:

  ┌───────────────────────┬─────────────────────────────────────┬──────────────────────────────────────────────────────────────────────────────────────────┐
  │ Token                 │ Capabilities                        │ Who uses it                                                                              │
  ├───────────────────────┼─────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤
  │ VAULT_ROOT_TOKEN      │ root                                │ host admin scripts (openfga_my/scripts/vault-*.sh, set_tenant_credentials.py,            │
  │                       │                                     │ vault_bootstrap.py) — read from generated/vault.env at invocation time only              │
  ├───────────────────────┼─────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤
  │ VAULT_TOKEN (libcloud │ read/list on secret/data/libcloud/  │ the libcloud REST API container — the runtime reader (vault_client.py lines 45-105)      │
  │ REST read token)      │ + secret/metadata/libcloud/         │                                                                                          │
  ├───────────────────────┼─────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤
  │ LDAP-issued tokens    │ per LLDAP group → bound policy      │ humans who auth/ldap/login                                                               │
  └───────────────────────┴─────────────────────────────────────┴──────────────────────────────────────────────────────────────────────────────────────────┘

  3. Tenants whose data is stored (the storage "accounts")

  Per-tenant backend credentials live at secret/data/libcloud/<tenant> (terminologies.md line 199, vault/ARCHITECTURE.md lines 217-222):

  • tenant:aws → secret/data/libcloud/aws
  • tenant:nutanix → secret/data/libcloud/nutanix
  • ad-hoc / extra tenants such as aws-dev → secret/data/libcloud/aws-dev
  • any tenant created later via create_tenant.sh

  Who does NOT use Vault

  Worth noting for completeness (§7.1): the OpenFGA server container itself has no Vault client — it never reads or writes Vault. OpenFGA's relationship to
  Vault is logical (it authorizes writes via can_manage_credentials checks), not network-level. LLDAP also does not store anything in Vault except the one
  service-account bind credential written into auth/ldap/config by setup.sh.

  So the direct users of Vault for storage are: the 8 LLDAP principals above (via LDAP auth), two machine tokens (root + REST read), and per-tenant 
  credential stores for aws, nutanix, and any additional tenants.

                                                                                                                                                               
  i cannot locate the path "secret/data/libcloud/<tenant>" or "auth/ldap/config" please indicate the all the path mentioned above in full.                     
                                                                                                                                                               

  Those are not filesystem paths — they are paths inside Vault's HTTP API / KV v2 mount, accessed over the network at http://vault:8200. They don't exist as
  files on disk. Let me show you exactly where each one lives and where it is referenced in the codebase.

    Grepped "...nfig|auth/ldap/login|auth/ldap/groups" in .
    Found 147 matches  (truncated)

  Let me also find the exact filesystem files that construct these Vault API paths in code.

    Grepped 3 greps
    Grepped "...ata/libcloud|auth/ldap|kv_prefix|/v1/" in openfga_my/vault_bootstrap.py
    Grepped "secret|/v1/|libcloud" in vault/add_credential.py
    Grepped "vault" in libcloud.rest/app/config/settings.py

  Those strings are Vault-internal paths (key-value routes inside the Vault server's HTTP API), not directories on disk. They only exist as data inside the 
  running Vault container's encrypted file storage at /vault/file on the vault-data Docker volume. You "locate" them by calling Vault's HTTP API, not by
  ls-ing the filesystem.

  Here is each path, in full, with what it is and where it is constructed in code.

  1. KV v2 secrets — secret/data/libcloud/<tenant>

  This is a Vault KV v2 mount named secret, prefix libcloud/, with <tenant> as the secret name. The on-the-wire URL is:

  http://vault:8200/v1/secret/data/libcloud/<tenant>

  Examples for the tenants in this system:

  http://vault:8200/v1/secret/data/libcloud/aws
  http://vault:8200/v1/secret/data/libcloud/aws-dev
  http://vault:8200/v1/secret/data/libcloud/nutanix

  It is built in three places in code:

  • libcloud.rest/app/connections/vault_client.py lines 41-43 — f"/v1/{settings.vault_mount}/data/{settings.vault_kv_prefix}/{binding}"
  • vault/add_credential.py line 47 — f"{addr}/v1/{KV_MOUNT}/data/{KV_PREFIX}/{name}"
  • openfga_my/vault_bootstrap.py line 221 — f"/v1/{KV_MOUNT}/data/{KV_PREFIX}/{name}"

  The mount and prefix come from env vars (defaults secret / libcloud):

  • vault/add_credential.py lines 29-30 — KV_MOUNT=secret, KV_PREFIX=libcloud
  • libcloud.rest/app/config/settings.py lines 78-84 — vault_mount, vault_kv_prefix

  The corresponding metadata path (for LIST / delete) is:

  http://vault:8200/v1/secret/metadata/libcloud/<tenant>

  The actual encrypted bytes backing these live inside the Vault container at:

  /vault/file          (filesystem path inside the `vault` container)

  mounted from the Docker named volume vault-data (see vault/docker-compose.yml). There is no readable secret/data/libcloud/... directory there — it is
  Vault's encrypted storage blob.

  2. LDAP auth method config — auth/ldap/config

  This is a Vault sys/auth route, not a KV path. Full URL:

  http://vault:8200/v1/auth/ldap/config

  It is written by setup.sh via the CLI (vault/ARCHITECTURE.md lines 354-359):

  vault write auth/ldap/config \
     url="ldap://lldap:3890" \
     userdn="ou=people,dc=libcloud,dc=local" \
     groupdn="ou=groups,dc=libcloud,dc=local" \
     binddn="$LLDAP_BIND_DN" bindpass="$LLDAP_BIND_PW" \
     userattr="uid" insecure_tls=true

  This data is stored encrypted-at-rest inside Vault (in the same /vault/file blob). It is documented in doc/how_to_create_vault_policy.md lines 124-130 and
  vault/ARCHITECTURE.md §6.2.

  3. Related Vault-internal paths (for completeness)

  http://vault:8200/v1/auth/ldap/login/<uid>          # human login (returns scoped token)
  http://vault:8200/v1/auth/ldap/groups/<lldap-group>  # group→policy binding
  http://vault:8200/v1/sys/init                         # init status
  http://vault:8200/v1/sys/unseal                       # unseal
  http://vault:8200/v1/sys/mounts/secret                # KV v2 mount enable
  http://vault:8200/v1/sys/policies/acl/libcloud-rest-read  # REST read policy

  Where to actually see them on disk

  If you want to inspect the values, use the CLI/HTTP API, not the filesystem:

  # From the host (needs generated/vault.env sourced):
  source vault/generated/vault.env
  curl -sS -H "X-Vault-Token: $VAULT_ROOT_TOKEN" \
       "$VAULT_ADDR/v1/secret/data/libcloud/aws" | jq
  curl -sS -H "X-Vault-Token: $VAULT_ROOT_TOKEN" \
       "$VAULT_ADDR/v1/auth/ldap/config" | jq

  Or via the helper scripts in the repo:

  • vault/list_credentials.py — lists every secret/libcloud/* secret
  • vault/add_credential.py / vault/delete_credential.py — CRUD on a secret
  • openfga_my/scripts/vault_common.sh — vault_get / vault_put / vault_post / vault_delete / vault_list wrappers (attach X-Vault-Token)

  Summary

  ┌───────────────────────────────────┬────────────────────────────┬────────────────────────────────────────────────────────┐
  │ Path string                       │ Kind                       │ Full URL                                               │
  ├───────────────────────────────────┼────────────────────────────┼────────────────────────────────────────────────────────┤
  │ secret/data/libcloud/<tenant>     │ Vault KV v2 data route     │ http://vault:8200/v1/secret/data/libcloud/<tenant>     │
  ├───────────────────────────────────┼────────────────────────────┼────────────────────────────────────────────────────────┤
  │ secret/metadata/libcloud/<tenant> │ Vault KV v2 metadata route │ http://vault:8200/v1/secret/metadata/libcloud/<tenant> │
  ├───────────────────────────────────┼────────────────────────────┼────────────────────────────────────────────────────────┤
  │ auth/ldap/config                  │ Vault auth method config   │ http://vault:8200/v1/auth/ldap/config                  │
  ├───────────────────────────────────┼────────────────────────────┼────────────────────────────────────────────────────────┤
  │ auth/ldap/login/<uid>             │ Vault LDAP login endpoint  │ http://vault:8200/v1/auth/ldap/login/<uid>             │
  ├───────────────────────────────────┼────────────────────────────┼────────────────────────────────────────────────────────┤
  │ auth/ldap/groups/<group>          │ Vault group→policy binding │ http://vault:8200/v1/auth/ldap/groups/<group>          │
  └───────────────────────────────────┴────────────────────────────┴────────────────────────────────────────────────────────┘

  None of these are filesystem directories — they are routes inside the Vault HTTP API, backed by the encrypted blob at /vault/file (Docker volume
  vault-data) inside the vault container.


