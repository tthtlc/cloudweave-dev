# How-To Index — Components That Need Add / Modify / Delete Procedures

This index enumerates **every component in the system** whose addition,
modification, or removal requires a documented procedure, and links to the
dedicated `how_to_create_*.md` guide for each.

The stack is the seven projects under `../`:

| Project | Role |
|---------|------|
| `../lldap` | User directory (LDAP) — users, groups, custom attributes |
| `../dex` | Stable OIDC issuer — OAuth clients, connectors, preshared keys |
| `../openfga_my` | Authorization (ReBAC) — store, model, tuples, principal mapping; also the orchestrator that bootstraps Dex, OpenFGA, Vault |
| `../vault` | Encrypted secret store — KV v2 secrets, cloud secrets engines, ACL policies, LDAP bindings |
| `../libcloud.rest` | Unified REST gateway — endpoints/routes, principals/scopes, provider registry, connection/auth_binding |
| `../libcloud` | Apache Libcloud fork — cloud-provider drivers and per-resource methods (compute / network / storage) |
| `../stoplight_mock` | Nutanix v4 mock stack — stateful mock endpoints + merged OpenAPI namespaces |

> Two pre-existing guides already cover two of the most common operations and
> are referenced (not duplicated) below:
> - `how_to_add_new_tenant.md` — new tenant on an existing cloud, **and** a new cloud provider end-to-end.
> - `how_to_add_new_openfga_endpoint.md` — new REST URL authorized by role.

---

## 1. LLDAP (`../lldap`) — identity / user directory

| Component | Add | Modify | Delete / Disable | Guide |
|-----------|-----|--------|-------------------|-------|
| User (uid, mail, name, department, role, jobtitle, password) | ✓ | reset password, change attrs | offboard (groups removed + password scrambled) | [how_to_create_lldap_user.md](how_to_create_lldap_user.md) |
| Group (role) + membership | ✓ | add/remove member | delete group | [how_to_create_lldap_group.md](how_to_create_lldap_group.md) |
| Custom user attribute (schema field) | ✓ | (append-only) | `deleteUserAttribute` (manual) | [how_to_create_lldap_custom_attribute.md](how_to_create_lldap_custom_attribute.md) |

## 2. Dex (`../dex`) — OIDC issuer

| Component | Add | Modify | Delete | Guide |
|-----------|-----|--------|--------|-------|
| Static OAuth2 client (`staticClients`) | ✓ | change redirect URIs / secret | remove entry | [how_to_create_dex_oauth_client.md](how_to_create_dex_oauth_client.md) |
| Connector (LDAP → LLDAP, or upstream OIDC for Phase 2) | ✓ | re-render config | remove connector block | [how_to_create_dex_connector.md](how_to_create_dex_connector.md) |
| OAuth client secret / preshared key (rotation) | — | rotate | — | [how_to_rotate_dex_preshared_key.md](how_to_rotate_dex_preshared_key.md) |

## 3. OpenFGA (`../openfga_my`) — authorization

| Component | Add | Modify | Delete | Guide |
|-----------|-----|--------|--------|-------|
| Relationship tuple (`user relation object`) | ✓ | (immutable; rewrite) | ✓ (with `--confirm` for structural) | [how_to_create_openfga_tuple.md](how_to_create_openfga_tuple.md) |
| Authorization model (type + relations) | ✓ | push new model version | (append-only) | [how_to_create_openfga_authorization_model.md](how_to_create_openfga_authorization_model.md) |
| Store | ✓ | — | delete store | [how_to_create_openfga_store.md](how_to_create_openfga_store.md) |
| Principal mapping (`data/principal_map.json`) | ✓ | edit `by_sub`/`by_email` | remove mapping | [how_to_create_openfga_principal_mapping.md](how_to_create_openfga_principal_mapping.md) |
| Tenant / cloud provider (cross-project) | ✓ | — | — | [how_to_add_new_tenant.md](how_to_add_new_tenant.md) |

## 4. Vault (`../vault`) — secrets

| Component | Add | Modify | Delete | Guide |
|-----------|-----|--------|--------|-------|
| KV v2 static secret (`secret/libcloud/<name>`) | ✓ | new version (append-only) | destroy version / delete all | [how_to_create_vault_secret.md](how_to_create_vault_secret.md) |
| Cloud secrets engine (aws/azure/gcp/alibaba) + roles + dynamic creds + leases | ✓ | rotate root creds, renew/revoke leases | disable mount | [how_to_create_vault_secrets_engine.md](how_to_create_vault_secrets_engine.md) |
| ACL policy + LLDAP→policy group binding | ✓ | overwrite HCL | delete policy / unbind group | [how_to_create_vault_policy.md](how_to_create_vault_policy.md) |

## 5. libcloud REST (`../libcloud.rest`) — gateway

| Component | Add | Modify | Delete | Guide |
|-----------|-----|--------|--------|-------|
| REST endpoint / URL (route + scope) | ✓ | change scope | remove route | [how_to_create_libcloud_rest_endpoint.md](how_to_create_libcloud_rest_endpoint.md) |
| Principal + scopes + `allowed_providers` | ✓ | edit `PRINCIPAL_SCOPES` / role suffix | remove principal | [how_to_create_libcloud_rest_principal.md](how_to_create_libcloud_rest_principal.md) |
| Provider registry entry (`PROVIDER_OBJECT_TYPES`, `PROVIDERS`, factory) | ✓ | edit capabilities | remove provider | [how_to_create_libcloud_rest_provider_registry.md](how_to_create_libcloud_rest_provider_registry.md) |
| Connection object / `auth_binding` / per-tenant Vault binding | ✓ | edit `auth_binding` / Vault path | remove binding | [how_to_create_libcloud_rest_connection.md](how_to_create_libcloud_rest_connection.md) |

## 6. libcloud drivers (`../libcloud`) — Apache Libcloud fork

| Component | Add | Modify | Delete | Guide |
|-----------|-----|--------|--------|-------|
| Cloud-provider driver (new cloud, e.g. GCP) | ✓ | extend methods | deprecate driver | [how_to_create_libcloud_cloud_driver.md](how_to_create_libcloud_cloud_driver.md) |
| Resource method on an existing driver (compute / network / storage / volume / snapshot / SG / LB) | ✓ | change mapping | deprecate method | [how_to_create_libcloud_resource_method.md](how_to_create_libcloud_resource_method.md) |

## 7. stoplight_mock (`../stoplight_mock`) — Nutanix v4 mock

| Component | Add | Modify | Delete | Guide |
|-----------|-----|--------|--------|-------|
| Stateful mock endpoint (CRUD + task lifecycle) + seed data | ✓ | change envelope / transition | remove route | [how_to_create_stoplight_mock_endpoint.md](how_to_create_stoplight_mock_endpoint.md) |
| Mocked Nutanix namespace (OpenAPI merge) | ✓ | re-merge spec | drop namespace | [how_to_create_stoplight_mock_namespace.md](how_to_create_stoplight_mock_namespace.md) |

---

## Cross-cutting rules

- **Superadmin gate.** Anything that changes identity, authorization, or root
  secrets (LLDAP schema, OpenFGA model/tuples, Vault bootstrap/policies, Dex
  client secret) requires a `superadmin` Dex login → `SUPERADMIN_JWT`.
- **Append-only stores.** LLDAP custom attributes, OpenFGA authorization
  models, and Vault KV v2 secrets are append-only / versioned — "modify" means
  "add a new version", "delete" is either explicit or scoped to a version.
- **Audit trail.** Every admin script appends a JSONL line to its
  `generated/*_audit.log`; the audit log is part of the change, not optional.
- **Re-render, don't hand-edit.** Dex `config.yaml`, `generated/dex.env`,
  `generated/fga.env`, `generated/vault.env` are emitted by bootstrap scripts
  — never edit them by hand; re-run the relevant bootstrap.
- **Three credential layers, never conflated:** (1) LLDAP user password
  (login), (2) Dex JWT (identity proof), (3) cloud credentials in Vault
  (backend access). Each how-to states which layer it touches.
