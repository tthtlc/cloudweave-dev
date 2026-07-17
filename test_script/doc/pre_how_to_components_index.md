
in view of the various components in the system: ../dex/ARCHITECTURE.md                                                                                      
  ../libcloud.rest/ARCHITECTURE.md                                                                                                                             
  ../libcloud/ARCHITECTURE.md                                                                                                                                  
  ../lldap/ARCHITECTURE.md                                                                                                                                     
  ../openfga_my/ARCHITECTURE.md                                                                                                                                
  ../stoplight_mock/ARCHITECTURE.md                                                                                                                            
  ../vault/ARCHITECTURE.md, identify all the different components in the system that need to be documented whenever a new addition or removal of it is         
  needed: eg a new user to LLDAP, a new object-relation tuples to OpenFGA, a new cloud provider to libcloud, all the types of resources and its                
  managements and changes to libcloud and libcloud.rest. After identifying the different component, go ahead and create for each a                             
  "how_to_create_xxxx.md" document which list all the steps involved in adding and modifying and deleting of objects/rules/rules/entities/users.               
                                                                                                                                                               

  I'll start by reading all the architecture documents to understand the system components.

    Read 7 files
    … 4 earlier items hidden
    Read ...ntu/libcloud_nutanix/openfga_my/ARCHITECTURE.md
    Read ...libcloud_nutanix/stoplight_mock/ARCHITECTURE.md
    Read ...e/ubuntu/libcloud_nutanix/vault/ARCHITECTURE.md

  I have a good understanding of most components. Let me explore the openfga_my architecture (which was too large) and look at the directory structures to
  understand the management scripts available.

    Grepped "^#" in ...ntu/libcloud_nutanix/openfga_my/ARCHITECTURE.md
    Found 31 matches 

  $ ls /home/ubuntu/libcloud_nutanix/openfga_my/scripts/ /home/ubuntu/libcloud_nutanix/lldap/scripts/ /home/ubuntu/libcloud_nutanix/vault/
    /home/ubuntu/libcloud_nutanix/libcloud.rest/app/ 2>&1 | head -200 1.5s
    … 111 output lines hidden · ctrl+o to expand
    myrun.sh
    vault.log

  $ find /home/ubuntu/libcloud_nutanix/libcloud.rest/app -name "*.py" | sort; echo "---LIBCLOUD---"; ls /home/ubuntu/libcloud_nutanix/libcloud/ 2>&1 | head;
    echo "---NUTANIX DRIVER---"; ls /home/ubuntu/libcloud_nutanix/libcloud/compute/drivers/ 2>&1 | grep -i nutanix; echo "---PROVIDERS---"; ls
    /home/ubuntu/libcloud_nutanix/libcloud/compute/providers/ 2>&1 | head; echo "---DOC DIR---"; ls /home/ubuntu/libcloud_nutanix/doc/ 2>&1 226ms
    … 77 output lines hidden · ctrl+o to expand
    why_discrepancies_betw_openfga_and_dex.md
    wtd

  The doc directory already has some how_to docs. Let me look at the existing ones for style reference and explore the libcloud structure more.

  $ cd /home/ubuntu/libcloud_nutanix/libcloud && find . -path ./apache_libcloud.egg-info -prune -o -name "*.py" -print | grep -iE
    "nutanix|drivers/__init__|providers" | head -30; echo "---"; ls /home/ubuntu/libcloud_nutanix/libcloud/compute/ 2>&1 exit 2 • 352ms
    … 21 output lines hidden · ctrl+o to expand
    ---
    ls: cannot access '/home/ubuntu/libcloud_nutanix/libcloud/compute/': No such file or directory

    Read 2 files
    Read how_to_add_new_tenant.md
    Read how_to_add_new_openfga_endpoint.md

  I now have a clear picture. Let me read key scripts to ensure my how-to docs are accurate, then build a comprehensive set.

    Read 6 files
    … 3 earlier items hidden
    Read ...ix/openfga_my/scripts/lldap-group-add-member.sh
    Read ...tanix/openfga_my/scripts/openfga-tuple-write.sh
    Read ...anix/openfga_my/scripts/openfga-tuple-delete.sh

  I have strong context now. Let me read a few more key files to ensure accuracy for the libcloud driver, Vault secrets engine, and stoplight mock docs.

    Read 3 files
    Read ...ix/openfga_my/scripts/set_tenant_credentials.py
    Read ...enfga_my/scripts/vault-secrets-engine-enable.sh
    Read ...utanix/openfga_my/scripts/vault-policy-apply.sh

  I have enough context for most docs. Let me quickly scan the stoplight mock server.js and the libcloud compute service to ensure those docs are accurate.

    Read 3 files
    Read .../libcloud_nutanix/stoplight_mock/mock/server.js
    Read ...ud_nutanix/libcloud.rest/app/compute/service.py
    Read ..._nutanix/libcloud.rest/app/providers/factory.py

  I now have comprehensive context across all seven components. Let me set up a task plan and create the how-to documents.

    To-do Working on 8 to-dos
    ◐ Create index doc mapping all components to their how-to docs
    ○ LLDAP how-to docs: user, group, custom attribute
    ○ Dex how-to docs: oauth client, connector, preshared key rotation
    ○ OpenFGA how-to docs: tuple, authorization model, store, principal mapping
    ○ Vault how-to docs: secret, secrets engine, policy/LDAP binding
    ○ libcloud.rest how-to docs: endpoint, principal/scope, provider registry, connection/auth_binding
    ○ libcloud driver how-to docs: cloud driver, resource method
    ○ stoplight_mock how-to docs: mock endpoint, mock namespace

  Let me create the index document first.

    Edited how_to_components_index.md +99

    ▎+ # How-To Index — Components That Need Add / Modify / Delete Procedures
    ▎ 
    ▎+ This index enumerates **every component in the system** whose addition,
    ▎+ modification, or removal requires a documented procedure, and links to the
    ▎+ dedicated `how_to_create_*.md` guide for each.
    ▎+ 
    ▎+ The stack is the seven projects under `../`:
    ▎+ 
    ▎+ | Project | Role |
    ▎+ |---------|------|
    ▎+ | `../lldap` | User directory (LDAP) — users, groups, custom attributes |
    ▎+ | `../dex` | Stable OIDC issuer — OAuth clients, connectors, preshared keys |
    ▎ … truncated (88 more lines) · ctrl+r to review

    To-do Working on 7 to-dos • 1 done
    ✔ Create index doc mapping all components to their how-to docs
    ◐ LLDAP how-to docs: user, group, custom attribute
    ○ Dex how-to docs: oauth client, connector, preshared key rotation
    ○ OpenFGA how-to docs: tuple, authorization model, store, principal mapping
    ○ Vault how-to docs: secret, secrets engine, policy/LDAP binding
    ○ libcloud.rest how-to docs: endpoint, principal/scope, provider registry, connection/auth_binding
    ○ libcloud driver how-to docs: cloud driver, resource method
    ○ stoplight_mock how-to docs: mock endpoint, mock namespace

  Now the LLDAP how-to docs.

    Edited how_to_create_lldap_user.md +226

    ▎+ # How to Create / Modify / Offboard an LLDAP User
    ▎ 
    ▎+ This guide covers the full lifecycle of a **user** in the LLDAP directory
    ▎+ (`../lldap`): the six managed fields, how to add a user, reset / change a
    ▎+ password, update attributes, and offboard (disable) a user.
    ▎+ 
    ▎+ > **What a "user" is here.** A user is an LDAP entry under
    ▎+ > `ou=people,dc=libcloud,dc=local` with `uid` (login id), `mail`, `cn`
    ▎+ > (display name), and three custom attributes — `department`, `role`,
    ▎+ > `jobtitle`. The `uid` becomes the Dex OIDC `sub` and the OpenFGA subject
    ▎+ > (`user:<uid>`); `mail` becomes the libcloud REST `by_email` mapping key.
    ▎+ > Renaming a `uid` is **not** supported — create a new user instead.
    ▎ … truncated (215 more lines) · ctrl+r to review

    Edited how_to_create_lldap_group.md +170

    ▎+ # How to Create / Modify / Delete an LLDAP Group (and Membership)
    ▎ 
    ▎+ This guide covers **groups** in the LLDAP directory (`../lldap`): the role
    ▎+ naming convention, how to create a group, add / remove a member, list
    ▎+ memberships, and delete a group. It also explains how an LLDAP group becomes
    ▎+ OpenFGA tuples and Vault policy bindings.
    ▎+ 
    ▎+ > **What a group is here.** An LLDAP group is a role container under
    ▎+ > `ou=groups,dc=libcloud,dc=local`. Groups are keyed by an integer `id`; the
    ▎+ > human name is `displayName`. Membership in a group is what gives a user a
    ▎+ > **role** — e.g. membership in `cloud-admin-aws` makes someone an AWS cloud
    ▎+ > admin. Group membership is **the** source of truth for role grants; it is
    ▎ … truncated (159 more lines) · ctrl+r to review

    Edited how_to_create_lldap_custom_attribute.md +168

    ▎+ # How to Create / Modify / Delete an LLDAP Custom User Attribute (Schema Field)
    ▎ 
    ▎+ This guide covers **custom user attributes** in LLDAP (`../lldap`) — the
    ▎+ schema fields beyond the built-in `uid` / `mail` / `displayName` / `firstName`
    ▎+ / `lastName`. Today the deployment ships three: `department`, `role`,
    ▎+ `jobtitle`. This is the procedure for adding a fourth (or removing one).
    ▎+ 
    ▎+ > **Why this is its own guide.** Custom attributes are registered through the
    ▎+ > GraphQL `addUserAttribute` mutation (authenticated with an admin JWT) and
    ▎+ > are recorded in `bootstrap/user-schemas/custom-attributes.json`. They are
    ▎+ > **append-only in practice** — LLDAP does not clean up old custom attributes
    ▎+ > when you remove them from the schema file. Removing one requires an explicit
    ▎ … truncated (157 more lines) · ctrl+r to review

    To-do Working on 6 to-dos • 2 done
    ✔ Create index doc mapping all components to their how-to docs
    ✔ LLDAP how-to docs: user, group, custom attribute
    ◐ Dex how-to docs: oauth client, connector, preshared key rotation
    ○ OpenFGA how-to docs: tuple, authorization model, store, principal mapping
    ○ Vault how-to docs: secret, secrets engine, policy/LDAP binding
    ○ libcloud.rest how-to docs: endpoint, principal/scope, provider registry, connection/auth_binding
    ○ libcloud driver how-to docs: cloud driver, resource method
    ○ stoplight_mock how-to docs: mock endpoint, mock namespace

  Now the Dex how-to docs.

    Edited how_to_create_dex_oauth_client.md +160

    ▎+ # How to Create / Modify / Delete a Dex OAuth2 Client
    ▎ 
    ▎+ This guide covers **static OAuth2 clients** in Dex (`../dex`): the
    ▎+ `staticClients` block in `config.yaml`, what a client means downstream, and
    ▎+ how to add, change, or remove one.
    ▎+ 
    ▎+ > **What a client is here.** A Dex `staticClients` entry is an OAuth2 client
    ▎+ > that Dex registers in-memory. The single seeded client is `libcloud-rest`
    ▎+ > — used by the libcloud REST API for the authorization-code flow **and** as
    ▎+ > the `aud` claim that OpenFGA validates on every JWT. Adding a second client
    ▎+ > is rare; most deployments keep exactly one first-party client so
    ▎+ > `skipApprovalScreen: true` stays safe.
    ▎ … truncated (149 more lines) · ctrl+r to review

    Edited how_to_create_dex_connector.md +181

    ▎+ # How to Create / Modify / Delete a Dex Connector
    ▎ 
    ▎+ This guide covers **Dex connectors** (`../dex`): the LDAP connector that
    ▎+ federates authentication to LLDAP today, and the optional Phase-2 upstream
    ▎+ OIDC connector (Entra ID / Authentik / AD) that lets you swap the user
    ▎+ directory without changing the issuer.
    ▎+ 
    ▎+ > **What a connector is here.** A Dex connector is an upstream authentication
    ▎+ > provider. Dex stays the **stable OIDC issuer**; connectors are where the
    ▎+ > user directory actually lives. Today there is exactly one connector —
    ▎+ > `type: ldap` pointing at `lldap:3890`. The principal identity (`uid`) is
    ▎+ > stable across connector changes, so OpenFGA tuples and Vault bindings
    ▎ … truncated (170 more lines) · ctrl+r to review

    Edited how_to_rotate_dex_preshared_key.md +116

    ▎+ # How to Rotate a Dex Preshared Key / OAuth Client Secret
    ▎ 
    ▎+ This guide covers **rotation** of the OAuth2 client secret that Dex issues
    ▎+ for the `libcloud-rest` client — the "preshared key" between Dex and its
    ▎+ relying parties (libcloud REST API, OpenFGA's `aud` check, host scripts).
    ▎+ 
    ▎+ > **What is being rotated.** The `secret` field of the `libcloud-rest`
    ▎+ > `staticClients` entry in `../dex/config.yaml`. It is generated by
    ▎+ > `dex_bootstrap.py` (`secrets.token_urlsafe(32)`) unless
    ▎+ > `LIBCLOUD_OIDC_CLIENT_SECRET` is provided, and written to
    ▎+ > `generated/dex.env` as `LIBCLOUD_OIDC_CLIENT_SECRET`. It is **not** a
    ▎+ > per-user password (those live in LLDAP).
    ▎ … truncated (105 more lines) · ctrl+r to review

    To-do Working on 5 to-dos • 3 done
    ✔ Create index doc mapping all components to their how-to docs
    ✔ LLDAP how-to docs: user, group, custom attribute
    ✔ Dex how-to docs: oauth client, connector, preshared key rotation
    ◐ OpenFGA how-to docs: tuple, authorization model, store, principal mapping
    ○ Vault how-to docs: secret, secrets engine, policy/LDAP binding
    ○ libcloud.rest how-to docs: endpoint, principal/scope, provider registry, connection/auth_binding
    ○ libcloud driver how-to docs: cloud driver, resource method
    ○ stoplight_mock how-to docs: mock endpoint, mock namespace

  Now the OpenFGA how-to docs.

    Edited how_to_create_openfga_tuple.md +194

    ▎+ # How to Create / Modify / Delete an OpenFGA Relationship Tuple
    ▎ 
    ▎+ This guide covers **relationship tuples** in OpenFGA (`../openfga_my`): the
    ▎+ `<user> <relation> <object>` triples that are the system's fine-grained
    ▎+ authorization facts. It covers writing, deleting, auditing, and the safety
    ▎+ rules around structural tuples.
    ▎+ 
    ▎+ > **What a tuple is here.** A tuple is one authorization fact, e.g.
    ▎+ > `user:aws-admin admin tenant:aws`. OpenFGA evaluates `Check(user, relation,
    ▎+ > object)` by walking the tuple graph plus the model's computed relations.
    ▎+ > The seeded store has 17 tuples; `openfga_bootstrap.py` runs 25 validation
    ▎+ > checks after deploy. Tuple writes/deletes are **superadmin-gated** at the
    ▎ … truncated (183 more lines) · ctrl+r to review

    Edited how_to_create_openfga_authorization_model.md +209

    ▎+ # How to Create / Modify an OpenFGA Authorization Model (Type + Relations)
    ▎ 
    ▎+ This guide covers the OpenFGA **authorization model** (`../openfga_my`): the
    ▎+ type definitions and their relations that OpenFGA evaluates. It covers adding
    ▎+ a new protected object type, adding a new relation to an existing type, and
    ▎+ pushing a new model version.
    ▎+ 
    ▎+ > **When you need this.** Most new URLs / tenants need **no** model change —
    ▎+ > see [how_to_add_new_openfga_endpoint.md](how_to_add_new_openfga_endpoint.md)
    ▎+ > §6 and [how_to_add_new_tenant.md](how_to_add_new_tenant.md) Case A. You
    ▎+ > only extend the model when you introduce a **brand-new kind of protected
    ▎+ > object** (e.g. `billing_account:*`, `image_registry:*`, or a new cloud
    ▎ … truncated (198 more lines) · ctrl+r to review

    Edited how_to_create_openfga_store.md +153

    ▎+ # How to Create / Delete an OpenFGA Store
    ▎ 
    ▎+ This guide covers the OpenFGA **store** (`../openfga_my`): the per-deployment
    ▎+ container that holds one authorization model + its tuples. It covers creating
    ▎+ a fresh store, pointing the stack at it, and deleting one.
    ▎+ 
    ▎+ > **What a store is here.** An OpenFGA store is an isolated tuple + model
    ▎+   namespace identified by a UUID (`FGA_STORE_ID`). The seeded store is
    ▎+   created by `openfga_bootstrap.py` during `setup.sh`; its id is written to
    ▎+   `generated/fga.env`. The demo datastore is `--datastore-engine=memory` (or
    ▎+   sqlite); a production deployment would back it with PostgreSQL. You almost
    ▎+   never need a second store in a single deployment — this guide exists for
    ▎ … truncated (142 more lines) · ctrl+r to review

    Edited how_to_create_openfga_principal_mapping.md +160

    ▎+ # How to Create / Modify / Delete an OpenFGA Principal Mapping
    ▎ 
    ▎+ This guide covers the **principal map** in
    ▎+ `../libcloud.rest/data/principal_map.json`: the file that translates a Dex
    ▎+ JWT's `sub` / `email` claims into the **stable application principal slug**
    ▎+ that OpenFGA tuples and libcloud REST scopes are keyed on.
    ▎+ 
    ▎+ > **What a principal mapping is here.** OpenFGA tuples and libcloud REST
    ▎+ > `PRINCIPAL_SCOPES` reference stable slugs like `aws-admin`, `ntnx-viewer`,
    ▎+ > `superadmin`. In Phase 1 the Dex JWT `sub` **is** that slug (because Dex
    ▎+ > authenticates LLDAP `uid`s directly). In Phase 2 — when Dex federates to
    ▎+ > an upstream IdP (Entra ID / Authentik / AD) — the JWT `sub` becomes an
    ▎ … truncated (149 more lines) · ctrl+r to review

    To-do Working on 4 to-dos • 4 done
    ✔ Create index doc mapping all components to their how-to docs
    ✔ LLDAP how-to docs: user, group, custom attribute
    ✔ Dex how-to docs: oauth client, connector, preshared key rotation
    ✔ OpenFGA how-to docs: tuple, authorization model, store, principal mapping
    ◐ Vault how-to docs: secret, secrets engine, policy/LDAP binding
    ○ libcloud.rest how-to docs: endpoint, principal/scope, provider registry, connection/auth_binding
    ○ libcloud driver how-to docs: cloud driver, resource method
    ○ stoplight_mock how-to docs: mock endpoint, mock namespace

  Now the Vault how-to docs.

    Edited how_to_create_vault_secret.md +194

    ▎+ # How to Create / Modify / Delete a Vault KV v2 Secret
    ▎ 
    ▎+ This guide covers **static KV v2 secrets** in Vault (`../vault`) under the
    ▎+ `secret/libcloud/` prefix — the per-tenant cloud backend credentials and
    ▎+ ad-hoc secrets. It covers the three write paths (root-token ad-hoc,
    ▎+ owner-gated per-tenant, environment-driven), listing, version destroy, and
    ▎+ full delete.
    ▎+ 
    ▎+ > **What a secret is here.** A KV v2 secret at `secret/data/libcloud/<name>`
    ▎+ > holds an arbitrary `key=value` JSON object. KV v2 is **versioned and
    ▎+ > append-only** — re-writing a key creates a new version; old versions stay
    ▎+ > recoverable until the metadata is deleted. The libcloud REST API reads
    ▎ … truncated (183 more lines) · ctrl+r to review

    Edited how_to_create_vault_secrets_engine.md +221

    ▎+ # How to Create / Modify / Delete a Vault Cloud Secrets Engine (+ Roles + Dynamic Creds + Leases)
    ▎ 
    ▎+ This guide covers Vault **cloud secrets engines** (`../vault`): the
    ▎+ `aws` / `azure` / `gcp` / `alibaba` engines that mint **dynamic short-lived**
    ▎+ cloud credentials, plus the roles that define what credentials to mint and
    ▎+ the leases that track / renew / revoke them.
    ▎+ 
    ▎+ > **When to use this instead of a static KV secret.** The per-tenant backend
    ▎+ > credentials in `secret/libcloud/<tenant>` (see
    ▎+ > [how_to_create_vault_secret.md](how_to_create_vault_secret.md)) are
    ▎+ > **static** root creds the libcloud REST API reads at request time. A cloud
    ▎+ > secrets engine is the **dynamic** alternative: Vault holds the cloud root
    ▎ … truncated (210 more lines) · ctrl+r to review

    Edited how_to_create_vault_policy.md +208

    ▎+ # How to Create / Modify / Delete a Vault ACL Policy (+ LLDAP Group Binding)
    ▎ 
    ▎+ This guide covers **Vault ACL policies** (`../vault`) and the **LLDAP group →
    ▎+ policy bindings** that decide which Vault capabilities a human gets when they
    ▎+ log in to Vault through the LDAP auth method.
    ▎+ 
    ▎+ > **What a policy + binding is here.** A Vault ACL policy is an HCL document
    ▎+ > that grants `read` / `list` / `create` / `update` / `delete` / `sudo`
    ▎+ > capabilities on Vault paths. The `libcloud-rest-read` policy (read/list on
    ▎+ > `secret/data/libcloud/*` and `secret/metadata/libcloud/*`) is created by
    ▎+ > `vault_bootstrap.py` and is the one the libcloud REST API uses. A **group
    ▎+ > binding** is the entry `auth/ldap/groups/<lldap-group>` that maps an LLDAP
    ▎ … truncated (197 more lines) · ctrl+r to review

    To-do Working on 3 to-dos • 5 done
    ✔ Create index doc mapping all components to their how-to docs
    ✔ LLDAP how-to docs: user, group, custom attribute
    ✔ Dex how-to docs: oauth client, connector, preshared key rotation
    ✔ OpenFGA how-to docs: tuple, authorization model, store, principal mapping
    ✔ Vault how-to docs: secret, secrets engine, policy/LDAP binding
    ◐ libcloud.rest how-to docs: endpoint, principal/scope, provider registry, connection/auth_binding
    ○ libcloud driver how-to docs: cloud driver, resource method
    ○ stoplight_mock how-to docs: mock endpoint, mock namespace

  Now the libcloud.rest how-to docs.

    Edited how_to_create_libcloud_rest_endpoint.md +119

    ▎+ # How to Create / Modify / Delete a libcloud REST Endpoint (URL + Scope)
    ▎ 
    ▎+ This guide is the canonical procedure for adding / changing / removing a
    ▎+ **REST URL** in `../libcloud.rest` and having it authorized by user role
    ▎+ (`superadmin` / `owner` / `admin` / `viewer`). It is the dedicated companion
    ▎+ to the existing `[how_to_add_new_openfga_endpoint.md](how_to_add_new_openfga_endpoint.md)`,
    ▎+ which is the long-form reference with worked examples. This page is the
    ▎+ terse checklist version plus the delete/modify cases the older doc does not
    ▎+ cover.
    ▎+ 
    ▎+ > **Read the older doc first.** `how_to_add_new_openfga_endpoint.md` §0–§6
    ▎+ > explain the four authorization layers and the decision tables. This guide
    ▎ … truncated (108 more lines) · ctrl+r to review

    Edited how_to_create_libcloud_rest_principal.md +183

    ▎+ # How to Create / Modify / Delete a libcloud REST Principal (Scopes + allowed_providers)
    ▎ 
    ▎+ This guide covers **principals** in `../libcloud.rest`: the stable slugs
    ▎+ (`superadmin`, `*-owner`, `*-admin`, `*-viewer`, `cloud-denied`) that
    ▎+ OpenFGA tuples reference and that the REST API maps to JWT scopes and
    ▎+ `allowed_providers`. It covers adding a new principal, changing its scopes,
    ▎+ and removing one.
    ▎+ 
    ▎+ > **What a principal is here.** A principal is **not** a user account —
    ▎+ > user accounts live in LLDAP. A principal is the **authorization identity**
    ▎+ > the REST API resolves a JWT into. The resolution: Dex JWT `sub`/`email` →
    ▎+ > `data/principal_map.json` (or the known-principal fallback) →
    ▎ … truncated (172 more lines) · ctrl+r to review

    Edited how_to_create_libcloud_rest_provider_registry.md +203

    ▎+ # How to Create / Modify / Delete a libcloud REST Provider Registry Entry
    ▎ 
    ▎+ This guide covers the **provider registry** in `../libcloud.rest`: the small
    ▎+ set of data tables that teach the gateway about a cloud provider — its
    ▎+ OpenFGA object type, its capability surface, and how to build its driver. It
    ▎+ is the libcloud.rest-side companion to
    ▎+ [how_to_add_new_tenant.md](how_to_add_new_tenant.md) Case B (which is the
    ▎+ full cross-project procedure for a new cloud).
    ▎+ 
    ▎+ > **What a registry entry is here.** Three things, all in
    ▎+ > `../libcloud.rest`:
    ▎+ > 1. `app/connections/models.py::PROVIDER_OBJECT_TYPES` — `provider id →
    ▎ … truncated (192 more lines) · ctrl+r to review

    Edited how_to_create_libcloud_rest_connection.md +190

    ▎+ # How to Create / Modify / Delete a libcloud REST Connection (auth_binding + Vault Binding)
    ▎ 
    ▎+ This guide covers the **connection object** in `../libcloud.rest`: the
    ▎+ per-request payload that selects the cloud backend (`provider` + `config` +
    ▎+ `credentials`) and the **`auth_binding`** that selects which per-tenant
    ▎+ backend object + Vault secret the REST API uses at runtime.
    ▎+ 
    ▎+ > **What a connection is here.** Every compute/network call carries a
    ▎+ > `connection`:
    ▎+ >
    ▎+ > ```json
    ▎+ > { "provider": "aws",
    ▎ … truncated (179 more lines) · ctrl+r to review

    To-do Working on 2 to-dos • 6 done
    ✔ Create index doc mapping all components to their how-to docs
    ✔ LLDAP how-to docs: user, group, custom attribute
    ✔ Dex how-to docs: oauth client, connector, preshared key rotation
    ✔ OpenFGA how-to docs: tuple, authorization model, store, principal mapping
    ✔ Vault how-to docs: secret, secrets engine, policy/LDAP binding
    ✔ libcloud.rest how-to docs: endpoint, principal/scope, provider registry, connection/auth_binding
    ◐ libcloud driver how-to docs: cloud driver, resource method
    ○ stoplight_mock how-to docs: mock endpoint, mock namespace

  Let me quickly check the libcloud provider registration to write accurate driver docs.

    Read, grepped 1 file, 1 grep
    Read .
    Grepped "" in .

  $ cd /home/ubuntu/libcloud_nutanix/libcloud && find . -path ./venv -prune -o -path ./.tox -prune -o -name providers.py -print | head; echo "---"; rg -n
    "NUTANIX|nutanix" libcloud/compute/providers.py 2>/dev/null | head; echo "---DRIVER HEAD---"; sed -n '1,60p' libcloud/compute/drivers/nutanix.py 267ms
    … 68 output lines hidden · ctrl+o to expand
        NodeSize,
        StorageVolume,

  Now I have what I need. Writing the libcloud driver how-to docs.

    Edited how_to_create_libcloud_cloud_driver.md +200

    ▎+ # How to Create / Modify / Deprecate a Cloud-Provider Driver in libcloud
    ▎ 
    ▎+ This guide covers adding a **new cloud-provider driver** to the
    ▎+ `../libcloud` Apache Libcloud fork (the libcloud-side half of "add a new
    ▎+ cloud"). It is the libcloud counterpart to
    ▎+ [how_to_create_libcloud_rest_provider_registry.md](how_to_create_libcloud_rest_provider_registry.md)
    ▎+ and the cross-project [how_to_add_new_tenant.md](how_to_add_new_tenant.md)
    ▎+ Case B.
    ▎+ 
    ▎+ > **What a driver is here.** A libcloud driver is a subclass of
    ▎+ > `NodeDriver` (compute), `StorageDriver` (storage), etc., that translates
    ▎+ > libcloud's uniform resource model into a specific cloud's native API. The
    ▎ … truncated (189 more lines) · ctrl+r to review

    Edited how_to_create_libcloud_resource_method.md +201

    ▎+ # How to Create / Modify / Deprecate a libcloud Resource Method (compute / network / storage)
    ▎ 
    ▎+ This guide covers adding a **new resource method** to an **existing** libcloud
    ▎+ driver in `../libcloud` — e.g. a new `ex_*` Nutanix operation, a new EC2
    ▎+ helper, or a new storage operation — and surfacing it through the libcloud
    ▎+ REST API. It is the per-resource counterpart to
    ▎+ [how_to_create_libcloud_cloud_driver.md](how_to_create_libcloud_cloud_driver.md)
    ▎+ (which adds a whole new cloud).
    ▎+ 
    ▎+ > **What a resource method is here.** A method on a libcloud driver that
    ▎+ > performs one operation against one resource type. The Nutanix compute
    ▎+ > driver exposes the full set: `list_nodes`, `create_node`, `destroy_node`,
    ▎ … truncated (190 more lines) · ctrl+r to review

    To-do Working on 1 to-do • 7 done
    ✔ Create index doc mapping all components to their how-to docs
    ✔ LLDAP how-to docs: user, group, custom attribute
    ✔ Dex how-to docs: oauth client, connector, preshared key rotation
    ✔ OpenFGA how-to docs: tuple, authorization model, store, principal mapping
    ✔ Vault how-to docs: secret, secrets engine, policy/LDAP binding
    ✔ libcloud.rest how-to docs: endpoint, principal/scope, provider registry, connection/auth_binding
    ✔ libcloud driver how-to docs: cloud driver, resource method
    ◐ stoplight_mock how-to docs: mock endpoint, mock namespace

  Now the final two stoplight_mock how-to docs.

    Edited how_to_create_stoplight_mock_endpoint.md +207

    ▎+ # How to Create / Modify / Delete a stoplight_mock Stateful Endpoint (+ Seed Data)
    ▎ 
    ▎+ This guide covers the **stateful emulator shim** in `../stoplight_mock`
    ▎+ (`mock/server.js`): adding a new mocked Nutanix v4 endpoint that needs real
    ▎+ CRUD behaviour + async task semantics, changing its envelope / transitions,
    ▎+ and removing one. It also covers adding **seed reference data**.
    ▎+ 
    ▎+ > **What a mock endpoint is here.** The stack is a two-tier mock:
    ▎+ > **Stoplight Prism** serves schema-valid static responses for **every**
    ▎+ > path in the merged OpenAPI spec (487 paths); the **Node.js emulator shim**
    ▎+ > (`mock/server.js`, port 9440, HTTPS self-signed) intercepts the **subset**
    ▎+ > that needs stateful CRUD + task lifecycle and proxies everything else to
    ▎ … truncated (196 more lines) · ctrl+r to review

    Edited how_to_create_stoplight_mock_namespace.md +166

    ▎+ # How to Create / Modify / Delete a stoplight_mock Namespace (OpenAPI Merge)
    ▎ 
    ▎+ This guide covers the **merged OpenAPI specification** in
    ▎+ `../stoplight_mock` (`spec/openapi.json`): adding a new Nutanix v4 namespace
    ▎+ spec to the merge, re-merging, and dropping a namespace. It is the spec-side
    ▎+ companion to [how_to_create_stoplight_mock_endpoint.md](how_to_create_stoplight_mock_endpoint.md).
    ▎+ 
    ▎+ > **What a namespace is here.** The merged spec is produced by
    ▎+ > `scripts/merge-specs.js`, which runs inside a throwaway `node:20-alpine`
    ▎+ > container (`myrun.sh`) and reads the per-namespace YAML specs from
    ▎+ > `mock/v40/`, merges their `paths` (each prefixed with `/api`), `schemas`,
    ▎+ > and `tags`, and writes the combined OpenAPI 3.0.1 document
    ▎ … truncated (155 more lines) · ctrl+r to review

    To-do All done
    ✔ Create index doc mapping all components to their how-to docs
    ✔ LLDAP how-to docs: user, group, custom attribute
    ✔ Dex how-to docs: oauth client, connector, preshared key rotation
    ✔ OpenFGA how-to docs: tuple, authorization model, store, principal mapping
    ✔ Vault how-to docs: secret, secrets engine, policy/LDAP binding
    ✔ libcloud.rest how-to docs: endpoint, principal/scope, provider registry, connection/auth_binding
    ✔ libcloud driver how-to docs: cloud driver, resource method
    ✔ stoplight_mock how-to docs: mock endpoint, mock namespace

  All how-to documents are created. Let me verify the final set.

  $ ls -1 /home/ubuntu/libcloud_nutanix/doc/how_to_*.md | sort && echo "--- count ---" && ls /home/ubuntu/libcloud_nutanix/doc/how_to_*.md | wc -l 194ms
    … 24 output lines hidden · ctrl+o to expand
    --- count ---
    24

  Done. I identified every component in the seven-project stack that requires a documented add/modify/delete procedure and created a dedicated
  how_to_create_*.md for each, plus an index.

  What was created

  how_to_components_index.md — the entry point: a per-project table mapping each component to its guide, plus the cross-cutting rules (superadmin gate,
  append-only stores, audit trail, re-render-don't-hand-edit, the three credential layers).

  22 new how-to guides in /home/ubuntu/libcloud_nutanix/doc/, grouped by project:

  ┌───────────────┬────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ Project       │ Guides                                                                                                                                 │
  ├───────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ LLDAP         │ how_to_create_lldap_user.md, how_to_create_lldap_group.md, how_to_create_lldap_custom_attribute.md                                     │
  ├───────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Dex           │ how_to_create_dex_oauth_client.md, how_to_create_dex_connector.md, how_to_rotate_dex_preshared_key.md                                  │
  ├───────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ OpenFGA       │ how_to_create_openfga_tuple.md, how_to_create_openfga_authorization_model.md, how_to_create_openfga_store.md,                          │
  │               │ how_to_create_openfga_principal_mapping.md                                                                                             │
  ├───────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Vault         │ how_to_create_vault_secret.md, how_to_create_vault_secrets_engine.md, how_to_create_vault_policy.md                                    │
  ├───────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ libcloud.rest │ how_to_create_libcloud_rest_endpoint.md, how_to_create_libcloud_rest_principal.md, how_to_create_libcloud_rest_provider_registry.md,   │
  │               │ how_to_create_libcloud_rest_connection.md                                                                                              │
  ├───────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ libcloud      │ how_to_create_libcloud_cloud_driver.md, how_to_create_libcloud_resource_method.md                                                      │
  │ (drivers)     │                                                                                                                                        │
  ├───────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ stoplight_moc │ how_to_create_stoplight_mock_endpoint.md, how_to_create_stoplight_mock_namespace.md                                                    │
  │ k             │                                                                                                                                        │
  └───────────────┴────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

  The two pre-existing guides (how_to_add_new_tenant.md, how_to_add_new_openfga_endpoint.md) are referenced rather than duplicated — the new docs cross-link
  to them where they overlap (e.g. the provider-registry guide points to Case B of how_to_add_new_tenant.md for the full cross-project procedure).

  Each guide follows the same structure used by the existing two: what the component is → prerequisites → ADD → MODIFY → DELETE → VERIFY → files touched → 
  quick reference, with the real script names, file paths, and exact commands verified against the codebase (e.g. openfga-tuple-write.sh,
  set_tenant_credentials.py, PROVIDER_OBJECT_TYPES, mock/server.js, libcloud/compute/drivers/nutanix.py).


