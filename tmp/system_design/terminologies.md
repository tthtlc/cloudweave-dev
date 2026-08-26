# Glossary of Terms

*Sources: `openfga_my/ARCHITECTURE.md`, `openfga_my/IDENTITY.md`, `openfga_my/authorization.md`, `lldap/ARCHITECTURE.md`, `stoplight_mock/ARCHITECTURE.md`, `debugtool/nutanix_libcloud_driver/ARCHITECTURE.md`*

---

## Identity & Authentication

| Term | Definition | Source |
|---|---|---|
| **access_token** | Opaque OIDC token returned by Dex after login; presented to libcloud REST as `Bearer` | IDENTITY, ARCHITECTURE |
| **Active Directory (AD)** | Microsoft directory service; possible Phase 2 upstream IdP for Dex | IDENTITY |
| **admin JWT** | LLDAP session token obtained via `/auth/simple/login` used to call GraphQL mutations | lldap |
| **audience (`aud`)** | JWT claim identifying the intended recipient (`libcloud-rest`) | IDENTITY, ARCHITECTURE |
| **Authentik** | Optional Phase 2 upstream IdP example (Docker profile, port 9000) | ARCHITECTURE |
| **authentication (authn)** | Verifying who the caller is — provided by Dex OIDC | IDENTITY, ARCHITECTURE |
| **bearer token** | JWT sent in `Authorization: Bearer …` header to libcloud REST | ARCHITECTURE |
| **bind DN** | LDAP distinguished name used by apps to bind/search the directory (`uid=admin,ou=people,dc=libcloud,dc=local`) | lldap |
| **bind password** | Password for the LDAP bind DN (admin user) | lldap |
| **by_email** | Principal-map lookup key using email address; survives IdP migrations | IDENTITY |
| **by_sub** | Principal-map lookup key using OIDC `sub` claim | IDENTITY |
| **claim** | A key-value pair in a JWT payload (e.g. `sub`, `email`, `iss`) | IDENTITY |
| **client_id** | OAuth client identifier (`libcloud-rest`); stable across Phase 1→2 | IDENTITY |
| **Dex** | Stable OIDC issuer; Docker container (`ghcr.io/dexidp/dex`, port 5556); LDAP connector → LLDAP | IDENTITY, ARCHITECTURE |
| **dex_bootstrap.py** | Script that renders `dex/config.yaml`, generates client secret, and verifies OIDC discovery | ARCHITECTURE |
| **enablePasswordDB** | Dex config flag (set `false` in Phase 2 when LLDAP is the user directory) | IDENTITY |
| **Entra ID** | Microsoft Entra (formerly Azure AD); Phase 2 upstream connector example | IDENTITY |
| **expiration (`exp`)** | JWT claim for token expiry timestamp | IDENTITY |
| **HTTP Basic Auth** | Authentication method for Nutanix Prism Central (`key` = username, `secret` = password) | nutanix_libcloud_driver |
| **identity provider (IdP)** | External system that authenticates users (LLDAP in Phase 1; Entra/AD/Authentik in Phase 2) | IDENTITY |
| **issuer (`iss`)** | JWT claim identifying the token issuer (`http://localhost:5556/dex/`) | IDENTITY, ARCHITECTURE |
| **JWKS (JSON Web Key Set)** | Public keys at `/dex/keys` used to verify Dex JWT signatures | IDENTITY, ARCHITECTURE |
| **JWT (JSON Web Token)** | Signed token carrying identity claims; issued by Dex, validated by libcloud REST | IDENTITY, ARCHITECTURE |
| **LDAP bind** | Authenticating to LDAP with a DN + password | lldap |
| **LDAP connector** | Dex connector type that authenticates against an LDAP directory (LLDAP) | IDENTITY |
| **LDAP search** | Querying the LDAP directory for user/group entries | lldap |
| **legacy_username_aliases** | Principal-map fallback lookup by `preferred_username` | IDENTITY |
| **LLDAP** | Lightweight LDAP server (Docker, ports 17170/3890); user directory for Dex | IDENTITY, lldap |
| **local auth** | Non-OIDC fallback: `POST /v1/auth/login` with local users in `users.json` | ARCHITECTURE |
| **local JWT mode** | Alternative auth path where scopes are embedded in the JWT at login, not derived from principal | ARCHITECTURE |
| **OAuth** | Authorization framework underlying OIDC | IDENTITY |
| **objectClass** | LDAP schema class (`person`); used in search filters | lldap |
| **OIDC (OpenID Connect)** | Identity layer on OAuth 2.0; Dex is the OIDC issuer | IDENTITY |
| **OIDC discovery** | Well-known endpoint at `/.well-known/openid-configuration` for issuer metadata | ARCHITECTURE |
| **OIDC mode** | Auth mode where Dex issues JWT and libcloud REST derives scopes from principal | ARCHITECTURE |
| **opaque sub** | Encoded/non-human-readable `sub` value (e.g. Dex LDAP, Entra GUID) that must be mapped | IDENTITY |
| **PasswordModify extended operation** | LDAP v3 extended operation used to reset user passwords without `docker exec` into LLDAP | lldap |
| **Phase 1** | Current state: Dex LDAP connector → LLDAP; `sub` = uid | IDENTITY |
| **Phase 2** | Future state: Dex upstream connector → Entra/AD/Authentik; `sub` = opaque GUID; mapped via `principal_map.json` | IDENTITY |
| **preferred_username** | Optional OIDC claim; mapped through `principal_map.json`, not directly to OpenFGA | IDENTITY |
| **principal** | Stable application identity slug (e.g. `cloud-admin`, `aws-owner`) resolved from OIDC token claims | IDENTITY, ARCHITECTURE |
| **principal_map.json** | JSON file mapping `(sub, email)` → principal slug; source of truth for ops | IDENTITY, ARCHITECTURE |
| **principal resolution / resolve_principal** | Function that maps OIDC `(sub, email)` → stable principal slug | IDENTITY |
| **principal slug** | Short stable identifier (`superadmin`, `aws-admin`, `ntnx-viewer`, etc.) used in OpenFGA tuples and JWT `sub` | IDENTITY, authorization |
| **refresh_token** | Long-lived OIDC token for obtaining new access tokens; cached in `generated/tokens/` | ARCHITECTURE |
| **search base** | LDAP subtree root for user/group searches (`ou=people,dc=libcloud,dc=local`) | lldap |
| **stable client boundary** | Dex issuer URL + client_id remain unchanged across IdP migrations | IDENTITY |
| **stable principal** | Principal slug that survives IdP changes because it's mapped, not raw `sub` | IDENTITY |
| **staticPasswords** | Dex config for hardcoded user/password (Phase 1); removed in Phase 2 | IDENTITY |
| **subject (`sub`)** | OIDC claim uniquely identifying the user to the issuer; the primary mapping key | IDENTITY |
| **superadmin** | Bootstrap platform identity (`user:superadmin`); gates Vault, OpenFGA, and LLDAP admin operations | IDENTITY, authorization, ARCHITECTURE |
| **SUPERADMIN_JWT** | JWT obtained after Dex login as `superadmin`; gates bootstrap scripts | authorization, ARCHITECTURE |
| **superadmin_auth.sh** | Script that logs in as superadmin and exports `SUPERADMIN_JWT` | authorization |
| **token cache** | Directory `generated/tokens/` storing OIDC refresh tokens for reuse | ARCHITECTURE |
| **token validation** | Verifying JWT signature via Dex JWKS before trusting claims | IDENTITY |
| **upstream connector** | Dex connector type for external IdPs (Entra, AD); replaces LDAP connector in Phase 2 | IDENTITY |
| **user directory** | LLDAP instance holding all users, groups, and passwords | IDENTITY, lldap |
| **user filter** | LDAP search filter for user lookup: `(&(uid={0})(objectClass=person))` | lldap |

---

## Principal Types (LLDAP `uid` → OpenFGA `user:*`)

| Principal | OpenFGA Subject | Role(s) | Source |
|---|---|---|---|
| **superadmin** | `user:superadmin` | `superadmin` on `platform:main`; `owner` on all tenants (break-glass) | IDENTITY, authorization |
| **cloud-admin** | `user:cloud-admin` | `member` → `role:admin`, `tenant:default` (legacy naming) | IDENTITY |
| **cloud-readonly** | `user:cloud-readonly` | `member` → `role:reader`, `tenant:default` | IDENTITY |
| **cloud-denied** | *(no tuples)* | Authenticated; OpenFGA denies all checks | IDENTITY, authorization |
| **aws-owner** | `user:aws-owner` | `owner` on `tenant:aws` | authorization, ARCHITECTURE |
| **aws-admin** | `user:aws-admin` | `admin` on `tenant:aws` | authorization, ARCHITECTURE |
| **aws-viewer** | `user:aws-viewer` | `viewer` on `tenant:aws` | authorization, ARCHITECTURE |
| **ntnx-owner** | `user:ntnx-owner` | `owner` on `tenant:nutanix` | authorization, ARCHITECTURE |
| **ntnx-admin** | `user:ntnx-admin` | `admin` on `tenant:nutanix` | authorization, ARCHITECTURE |
| **ntnx-viewer** | `user:ntnx-viewer` | `viewer` on `tenant:nutanix` | authorization, ARCHITECTURE |

---

## Authorization — OpenFGA

| Term | Definition | Source |
|---|---|---|
| **allowed** | Direct relation on `provider:*` granting `can_use` to a user | authorization |
| **authorization graph** | Mermaid diagram showing all objects, relations, and how they connect | authorization |
| **authorization model** | OpenFGA type+relation definition; identified by `authorization_model_id` | authorization, ARCHITECTURE |
| **authz separation** | Authentication (Dex) and authorization (OpenFGA) are independent layers | authorization |
| **backend object** | OpenFGA object representing a cloud resource: `aws_region:{id}` or `nutanix_cluster:{id}` | authorization, ARCHITECTURE |
| **bootstrap validation checks** | 25 checks in `openfga_bootstrap.py` verifying the model after seeding | authorization |
| **can_assign_admin** | Computed relation on `tenant:*`: only `owner` can assign admins | authorization |
| **can_assign_owner** | Computed relation on `tenant:*`: only `owner` can assign owners | authorization |
| **can_assign_viewer** | Computed relation on `tenant:*`: `owner` or `admin` can assign viewers | authorization |
| **can_connect** | Computed relation on `libcloud_api:main`: may call the API at all; tenant `member` via `parent` | authorization, ARCHITECTURE |
| **can_manage_credentials** | Computed relation on `tenant:*`: only `owner` may update backend cloud credentials | authorization |
| **can_manage_platform** | Computed relation on `platform:main`: `superadmin` only | authorization |
| **can_provision** | Computed relation on `tenant:*` and backend objects: may create/modify resources | authorization, ARCHITECTURE |
| **can_read** | Computed relation on `tenant:*` and backend objects: read-only access | authorization, ARCHITECTURE |
| **can_use** | Computed relation on `provider:*`: may target that cloud provider | authorization, ARCHITECTURE |
| **check / OpenFGA check** | `POST /stores/{id}/check` — asks OpenFGA whether `(user, relation, object)` is allowed | authorization, ARCHITECTURE |
| **computed relation** | Relation derived at check-time from stored tuples + model rules (not stored directly) | authorization |
| **cross-cloud isolation** | AWS tenant members are not members of `tenant:nutanix` → denied on Nutanix resources | authorization |
| **delegated administration** | Owners assign admins; admins assign viewers; hierarchy enforced by OpenFGA | authorization |
| **direct relation** | Relation stored explicitly as a tuple (e.g. `user:aws-admin` → `admin` → `tenant:aws`) | authorization |
| **effective permissions matrix** | 8×8 table showing which principal can do what (25 validation checks) | authorization |
| **FGA_STORE_ID / FGA_MODEL_ID** | Environment variables pointing to the OpenFGA store and model | ARCHITECTURE |
| **fine-grained authorization** | Per-resource, per-relation policy checks (ReBAC) vs. coarse role checks | ARCHITECTURE |
| **INITIAL_TUPLES** | The 17 seed tuples written by `openfga_bootstrap.py` | authorization |
| **LIBCLOUD_MODEL** | OpenFGA authorization model DSL defined in `openfga_bootstrap.py` | authorization |
| **member** | Computed union on `tenant:*`: `this` or `owner` or `admin` or `viewer` | authorization |
| **object type** | OpenFGA type: `user`, `platform`, `tenant`, `libcloud_api`, `provider`, `aws_region`, `nutanix_cluster` | authorization |
| **openfga_bootstrap.py** | Script that creates store, writes model, seeds tuples, and runs 25 validation checks | authorization, ARCHITECTURE |
| **parent** | Direct relation from `tenant:*` → `libcloud_api:main` or `provider:*`; grants membership propagation | authorization |
| **policy engine** | libcloud REST component (`app/auth/policy.py`) that enforces scopes + OpenFGA checks | ARCHITECTURE |
| **PolicyEngine / _enforce_openfga** | Method that runs the 4-step OpenFGA check sequence for each request | authorization |
| **RBAC (Role-Based Access Control)** | Coarse role assignment via group claims → roles (distinct from ReBAC) | IDENTITY |
| **ReBAC (Relationship-Based Access Control)** | Fine-grained per-relationship authorization (OpenFGA model) | ARCHITECTURE |
| **relation** | Named edge in the authorization graph (stored or computed) | authorization |
| **role propagation** | Tenant roles (`owner`/`admin`/`viewer`) propagate to backend objects via the `tenant` relation | authorization |
| **seeded tuples** | The 17 tuples written at bootstrap into the OpenFGA store | authorization |
| **tenant (OpenFGA object)** | `tenant:aws`, `tenant:nutanix` — carries `owner`/`admin`/`viewer` → user relations | authorization |
| **tuple / tuple store** | A `(user, relation, object)` triple stored in OpenFGA; the tuple store is the database | authorization, ARCHITECTURE |
| **tuple rewrite** | Changing OpenFGA object names when IdP changes — **avoided** by using stable principal slugs | IDENTITY |
| **VALIDATION_CHECKS** | 25 check cases in `openfga_bootstrap.py` covering all principals × relations | authorization |

---

## Authorization — libcloud REST Scopes & API

| Term | Definition | Source |
|---|---|---|
| **allowed_providers** | List of provider names a principal may target (from `identity.py`) | ARCHITECTURE |
| **API gateway** | libcloud REST (FastAPI, port 8765) — unified entry point for AWS + Nutanix | ARCHITECTURE |
| **auth_binding** | Client-supplied selector (`aws`, `nutanix`, `aws-dev`, …) that picks the per-tenant backend object and Vault secret | authorization |
| **build_driver / provider factory** | `app/providers/factory.py` — maps `connection.provider` → Libcloud driver | ARCHITECTURE |
| **coarse authorization** | JWT scope + `allowed_providers` check (before OpenFGA fine-grained check) | ARCHITECTURE |
| **connection object** | JSON body/query-param containing `provider`, `config`, `credentials`; routing key for every compute/network call | ARCHITECTURE |
| **FGA_ENABLED** | Environment flag to toggle OpenFGA enforcement in libcloud REST | ARCHITECTURE |
| **JWT scope** | OAuth-style scope string (`compute:node:create`, `compute:read`, …) carried in JWT | ARCHITECTURE |
| **local JWT mode** | Scopes embedded in JWT at login time (non-OIDC path) | ARCHITECTURE |
| **OIDC mode** | Scopes derived from resolved principal via `PRINCIPAL_SCOPES` | ARCHITECTURE |
| **PRINCIPAL_SCOPES** | Dict in `identity.py` mapping principal slug → scopes + `allowed_providers` | authorization, ARCHITECTURE |
| **provider guard** | 403 if `connection.provider` not in user's `allowed_providers` | ARCHITECTURE |
| **provider-neutral REST facade** | libcloud REST design: same paths for AWS and Nutanix; not a transparent HTTP proxy | ARCHITECTURE |
| **provider routing** | `connection.provider` → `build_driver()` → AWS or Nutanix driver | ARCHITECTURE |
| **route guard** | 403 if required scope missing from JWT | ARCHITECTURE |
| **scope assignment** | `identity.py` assigns scopes based on resolved principal | ARCHITECTURE |
| **scope check** | Verify JWT contains required scope for the endpoint | ARCHITECTURE |
| **scope-gated operations** | Each route requires specific OAuth-like scopes | ARCHITECTURE |
| **standard envelope** | All responses: `{ "data": ..., "meta": { "request_id": ... } }` | ARCHITECTURE |
| **three-tier security model** | Dex (authn) → libcloud REST scopes/provider allowlists (coarse authz) → OpenFGA (fine-grained authz) | ARCHITECTURE |
| **uniform resource model** | Same paths (`/v1/compute/nodes`, `/images`, …) for both AWS and Nutanix | ARCHITECTURE |

---

## Tenants, Multi-Tenancy & Platform

| Term | Definition | Source |
|---|---|---|
| **break-glass** | `superadmin` is `owner` on all tenants for emergency access | authorization |
| **create_tenant.sh** | Superadmin-gated script that mints a new tenant with users, tuples, backend object | authorization |
| **cross-cloud isolation** | Tenant membership on `tenant:aws` does not grant access to `tenant:nutanix` | authorization |
| **per-tenant backend credentials** | Each tenant has its own Vault path + backend object with distinct cloud keys | authorization |
| **per-tenant isolation** | Backend objects, Vault secrets, and OpenFGA tuples are scoped per tenant | authorization |
| **platform** | `platform:main` — the top-level object carrying `superadmin` relation | authorization |
| **set_tenant_credentials.py** | Owner-gated script that writes tenant cloud credentials to Vault | authorization |
| **tenant (platform concept)** | A cloud-account scope (`aws`, `nutanix`, `aws-dev`, …) with own users and credentials | authorization |

---

## Backend, Cloud & Vault

| Term | Definition | Source |
|---|---|---|
| **Apache Libcloud** | Python library providing uniform cloud driver interface (EC2, Nutanix, etc.) | ARCHITECTURE |
| **AWS EC2 Query protocol** | AWS API uses `POST` to a single regional endpoint with `Action=` parameters (not REST paths) | ARCHITECTURE |
| **cloud credential** | `key` + `secret` for AWS or Nutanix; travels in `connection`, stored encrypted in Vault | ARCHITECTURE |
| **EC2NodeDriver** | Libcloud driver for AWS EC2 | ARCHITECTURE |
| **KV v2 secret** | Vault key-value secrets engine v2; path `secret/libcloud/<binding>` | ARCHITECTURE |
| **least-privilege read token** | Vault token issued by `vault_bootstrap.py` with read-only access to libcloud secrets | ARCHITECTURE |
| **libcloud REST** | FastAPI gateway (port 8765) that translates unified REST calls to Libcloud driver methods | ARCHITECTURE |
| **Nutanix Prism Central** | Nutanix management plane; target of `NutanixNodeDriver` on port 9440 | ARCHITECTURE, nutanix_libcloud_driver |
| **Nutanix v4 REST** | Nutanix uses real REST paths (`/api/vmm/v4.0/ahv/config/vms`, …) unlike AWS | ARCHITECTURE |
| **NutanixNodeDriver** | Libcloud driver for Nutanix Prism Central v4 API | ARCHITECTURE, nutanix_libcloud_driver |
| **NutanixPrismConnection** | Custom Libcloud connection class: HTTP Basic Auth, JSON headers, pagination helpers | nutanix_libcloud_driver |
| **NutanixPrismResponse** | Custom Libcloud response class mapping HTTP status → Libcloud exceptions | nutanix_libcloud_driver |
| **provider (connection.provider)** | Client field selecting the cloud: `"aws"` or `"nutanix"` | ARCHITECTURE |
| **provider-native API** | The actual cloud API behind Libcloud (EC2 Query or Nutanix REST) | ARCHITECTURE |
| **stateless gateway** | Cloud credentials travel in each request; not stored server-side | ARCHITECTURE |
| **Vault (HashiCorp Vault)** | Encrypted secret store for cloud credentials; `vault_bootstrap.py` initializes/unseals it | ARCHITECTURE |
| **Vault path** | `secret/data/libcloud/<tenant>` — where per-tenant cloud credentials live | authorization |
| **vault_bootstrap.py** | Script that initializes Vault, enables KV v2, and issues least-privilege token; gated on `SUPERADMIN_JWT` | ARCHITECTURE |

---

## LLDAP User Management

| Term | Definition | Source |
|---|---|---|
| **addUserAttribute** | GraphQL mutation to register a custom user attribute (`department`, `role`, `jobtitle`) | lldap |
| **base DN** | Root of the LDAP directory tree (`dc=libcloud,dc=local`) | lldap |
| **bootstrap (service)** | One-shot Docker Compose service that applies the custom attribute schema | lldap |
| **cn (commonName)** | LDAP attribute; LLDAP maps `displayName` → `cn` | lldap |
| **createUser** | GraphQL mutation to create a user with `id`, `email`, `displayName`, and `attributes` | lldap |
| **custom user attribute** | LLDAP extension fields: `department`, `role`, `jobtitle` — defined via GraphQL, queryable over LDAP | lldap |
| **displayName / display_name** | Built-in LLDAP attribute for the user's full name; exposed as `cn` over LDAP | lldap |
| **GraphQL API** | LLDAP admin API at `/api/graphql` for schema and user management | lldap |
| **jobtitle / job description** | Custom LLDAP attribute; one of the six managed fields | lldap |
| **LLDAP admin user** | Built-in `admin` user; used as manager DN for LDAP searches | lldap |
| **lldap-tools (service)** | Docker Compose service (`python:3.12-slim` + `curl`, `jq`, `ldap3`) for management scripts | lldap |
| **mail** | Built-in LLDAP attribute for email address; used in login filters | lldap |
| **organizational unit (ou)** | LDAP container: `ou=people` (users), `ou=groups` (groups) | lldap |
| **setup-schema.sh** | Script that applies custom attributes via GraphQL after authenticating as admin | lldap |
| **uid (LLDAP)** | Login identifier; the `user_id` field in LLDAP; exposed as LDAP `uid` | lldap, IDENTITY |
| **user schema** | The set of attributes defined on LLDAP user objects (built-in + custom) | lldap |
| **verify-ldap.py** | Script that binds as admin, searches for all users, and prints their attributes | lldap |
| **web UI** | LLDAP's built-in user/group management interface at port 17170 | lldap |

---

## LLDAP GraphQL API

All GraphQL operations available at `/api/graphql` (authenticated via `Authorization: Bearer <token>` from `/auth/simple/login`).

### Queries

**`user`** — lookup by userId

```graphql
query($id: String!) { user(userId: $id) { id } }
```

| | |
|---|---|
| Used in | `scripts/lldap_ensure_user.sh:33` |
| Args | `userId: String!` |
| Returns | `{ id }` — more fields available (`displayName`, `email`, `attributes`, …) |
| Purpose | Existence check before creating a user |

**`schema { userSchema { attributes } }`** — introspect user schema

```graphql
{ schema { userSchema { attributes { name attributeType isList isEditable isHardcoded } } } }
```

| | |
|---|---|
| Used in | `scripts/setup-schema.sh:61` |
| Args | none |
| Returns | Array of `{ name, attributeType, isList, isEditable, isHardcoded }` for every attribute (built-in + custom) |
| Purpose | Verify custom attributes were registered |

### Mutations

**`addUserAttribute`** — register a custom user attribute

```graphql
mutation {
  addUserAttribute(
    name: "department",
    attributeType: STRING,
    isList: false,
    isVisible: true,
    isEditable: true
  ) { ok }
}
```

| | |
|---|---|
| Used in | `scripts/setup-schema.sh:41` (called for `department`, `role`, `jobtitle`) |
| Args | `name: String!`, `attributeType: AttributeType!` (`STRING`), `isList: Boolean!`, `isVisible: Boolean!`, `isEditable: Boolean!` |
| Returns | `{ ok: Boolean }` — note: `ok`, **not** `success` |
| Idempotency | Repeating returns an "already exists" error; the script treats that as success |

**`createUser`** — create a user with all fields

```graphql
mutation CreateUser($user: CreateUserInput!) {
  createUser(user: $user) {
    id
    displayName
    email
    attributes { name value }
  }
}
```

| | |
|---|---|
| Used in | `scripts/create-user.sh:34` |
| Args | `user: CreateUserInput!` with keys: `id` (uid), `email` (mail), `displayName` (name), `attributes: [{name, value: [String]}]` |
| Returns | `{ id, displayName, email, attributes { name value } }` |
| Caveat | Password **cannot** be set here; must use LDAP PasswordModify afterwards (`scripts/set-password.py`) |

**`deleteUserAttribute`** — remove a custom attribute *(documented, not scripted)*

| | |
|---|---|
| Referenced in | `ARCHITECTURE.md:259` |
| Args | `name: String!` (inferred) |
| Returns | Presumed `{ ok: Boolean }` |
| Note | LLDAP does not auto-clean removed attributes; use this explicitly if needed |

### Standard LLDAP Operations NOT Used Here

| Category | Operations (not invoked by any script in this repo) |
|---|---|
| User list | `users(filters: ...)` |
| User mutations | `updateUser`, `deleteUser` |
| Groups | `groups`, `group`, `createGroup`, `updateGroup`, `deleteGroup`, `addUserToGroup`, `removeUserFromGroup` |
| Schema mutations | `updateUserAttribute`, `addGroupAttribute`, `deleteGroupAttribute` |

### Non-GraphQL Auth Endpoints

LLDAP has **no** GraphQL `login` mutation. Authentication goes through REST:

| Endpoint | Method | Purpose |
|---|---|---|
| `/auth/simple/login` | POST | Authenticate, receive `{ token, refreshToken }` |
| `/auth/refresh` | POST | Refresh an expired token |
| `/auth/logout` | POST | Invalidate session |

---

## Nutanix Libcloud Driver

| Term | Definition | Source |
|---|---|---|
| **ACPI shutdown/reboot** | Graceful VM power operations via ACPI (`$actions/shutdown`, `$actions/reboot`) | nutanix_libcloud_driver |
| **AHV** | Nutanix native hypervisor; VMM namespace serves AHV VMs | nutanix_libcloud_driver |
| **api_version** | Configurable Nutanix API version (`v4.0` default) interpolated into endpoint paths | nutanix_libcloud_driver |
| **clustermgmt** | Nutanix namespace for cluster management (`/api/clustermgmt/{ver}/config/clusters`) | nutanix_libcloud_driver |
| **create_node** | Libcloud method → `POST /api/vmm/{ver}/ahv/config/vms`; returns `202` + TaskReference | nutanix_libcloud_driver |
| **ETag / If-Match** | HTTP header required for VM DELETE and PUT; driver fetches VM first to obtain ETag | nutanix_libcloud_driver |
| **ex_get_node** | Libcloud extension to fetch a single VM by extId | nutanix_libcloud_driver |
| **ex_list_clusters** | Libcloud extension: list Nutanix clusters | nutanix_libcloud_driver |
| **ex_list_subnets** | Libcloud extension: list AHV subnets | nutanix_libcloud_driver |
| **ex_list_templates** | Libcloud extension: list VM templates from `content/templates` | nutanix_libcloud_driver |
| **extId** | Nutanix UUID for resources (VMs, images, subnets, etc.) | nutanix_libcloud_driver |
| **guest shutdown/reboot** | Nutanix Guest Tools (NGT) -based power operations | nutanix_libcloud_driver |
| **list_images** | Libcloud method → `GET /api/vmm/{ver}/content/images` | nutanix_libcloud_driver |
| **list_locations** | Libcloud method → `GET /api/clustermgmt/{ver}/config/clusters`; clusters as `NodeLocation` | nutanix_libcloud_driver |
| **list_nodes** | Libcloud method → `GET /api/vmm/{ver}/ahv/config/vms` with OData `$page`/`$limit`/`$filter` | nutanix_libcloud_driver |
| **list_sizes** | Libcloud method → in-code synthetic presets (`small`/`medium`/`large`/`xlarge`) | nutanix_libcloud_driver |
| **networking namespace** | Nutanix REST prefix `/api/networking/{ver}/` — subnets, VPCs, FIPs | nutanix_libcloud_driver |
| **NGT (Nutanix Guest Tools)** | VM agent required for guest-level power operations | nutanix_libcloud_driver |
| **NodeDriver** | Libcloud base class for compute providers | nutanix_libcloud_driver |
| **NodeState** | Libcloud enum: `RUNNING`, `STOPPED`, `PAUSED`, `PENDING`, `UNKNOWN` | nutanix_libcloud_driver |
| **OData** | Query protocol used by Nutanix v4 for pagination (`$page`, `$limit`, `$filter`) | nutanix_libcloud_driver |
| **pagination (Nutanix)** | Loop `$page` (0-based) + `$limit` (max 100) until all records collected | nutanix_libcloud_driver |
| **powerState** | Nutanix VM field (`ON`, `OFF`, `PAUSED`, `SUSPENDED`, `PENDING`) → mapped to `NodeState` | nutanix_libcloud_driver |
| **prism namespace** | Nutanix REST prefix `/api/prism/{ver}/` — task tracking | nutanix_libcloud_driver |
| **Provider.NUTANIX_PRISM** | Libcloud provider enum for the Nutanix driver | nutanix_libcloud_driver |
| **synthetic sizes** | `small`/`medium`/`large`/`xlarge` presets; overridable via `ex_vcpus`/`ex_memory_mib` | nutanix_libcloud_driver |
| **task status** | Nutanix terminal states: `SUCCEEDED`, `FAILED`, `CANCELED`/`CANCELLED`; in-progress: `RUNNING`, `QUEUED`, `PENDING` | nutanix_libcloud_driver |
| **TaskReference** | Nutanix v4 envelope for async operations: `prism.v4.config.TaskReference` with `extId` | nutanix_libcloud_driver |
| **vmm namespace** | Nutanix REST prefix `/api/vmm/{ver}/` — VMs, images, templates, storage containers | nutanix_libcloud_driver |
| **_wait_for_task** | Internal method that polls `prism` namespace until terminal task status | nutanix_libcloud_driver |

---

## Stoplight Mock (Nutanix OpenAPI)

| Term | Definition | Source |
|---|---|---|
| **$fv (fabric version)** | Nutanix envelope discriminator: `"v4.r0"` (AHV/VMM) or `"v4.r2"` (networking) | stoplight_mock |
| **$objectType** | Nutanix v4 envelope field identifying the response schema (e.g. `vmm.v4.ahv.config.VM`) | stoplight_mock |
| **$reserved** | Nutanix v4 envelope wrapper containing `$fv` and `$objectType` | stoplight_mock |
| **AHV / VMM envelope** | Response shape with `vmm.v4.ahv.config.*` discriminators | stoplight_mock |
| **async pattern (Nutanix mock)** | Mutating calls return `202` + `TaskReference`; task transitions `QUEUED → RUNNING → SUCCEEDED` over 200 ms | stoplight_mock |
| **catch-all proxy** | Any route not handled by the shim forwards to Stoplight Prism | stoplight_mock |
| **camelCase / snake_case** | The shim accepts both in requests; always emits `camelCase` responses | stoplight_mock |
| **deepConvert** | Utility that recursively converts object keys between `snake_case` and `camelCase` | stoplight_mock |
| **discriminator** | `$objectType` value used by the Nutanix Go SDK to deserialize polymorphic responses | stoplight_mock |
| **emulator shim** | Node.js Express server (port 9440) that statefully mocks a subset of Nutanix endpoints | stoplight_mock |
| **floating IP (FIP)** | Networking resource mocked by the shim: `POST/GET/DELETE` on `/api/networking/.../floating-ips` | stoplight_mock |
| **health (mock)** | `GET /health` on the emulator returns counts of all in-memory stores | stoplight_mock |
| **in-memory Maps** | JavaScript `Map` objects in the emulator shim; lost on container restart | stoplight_mock |
| **merged spec** | `spec/openapi.json` (12.6 MB, 487 paths, 2206 schemas) produced by `merge-specs.js` from per-namespace YAML | stoplight_mock |
| **Networking envelope** | Response shape with `networking.v4.config.*` discriminators, `$fv = "v4.r2"` | stoplight_mock |
| **NSP (Network Security Policy)** | Mocked networking resource: CRUD on `/api/networking/.../network-security-policies` | stoplight_mock |
| **path variants** | Three API-version paths per resource: `v4.0.a1`, `v4.0`, `v4.0/ahv` | stoplight_mock |
| **Prism (Stoplight)** | Stateless OpenAPI 3 mock server (`stoplight/prism:5`, port 4010); serves schema-valid example responses | stoplight_mock |
| **recovery point** | Mocked dataprotection resource: CRUD on `/api/dataprotection/.../recovery-points` | stoplight_mock |
| **schema-valid response** | Prism returns responses conforming to the OpenAPI schema but with static/example data | stoplight_mock |
| **seed reference data** | 5 bootstrapped resources: cluster, subnet, 2 images, storage container (with hardcoded extIds) | stoplight_mock |
| **stateful emulator** | The Node.js shim maintains in-memory state for CRUD operations + task simulation | stoplight_mock |
| **storage container** | Nutanix vmm resource: `GET /api/vmm/.../storage-containers` | stoplight_mock |
| **TASK_TRANSITION_MS** | 200 ms delay for mock task lifecycle transitions | stoplight_mock |
| **Terraform provider (Nutanix)** | Nutanix Terraform provider v2.2.1 — sensitive to exact `$objectType` discriminators | stoplight_mock |
| **volume group / vDisk** | Nutanix volumes resource: CRUD + VM attach/detach on `/api/volumes/.../volume-groups` | stoplight_mock |
| **VPC** | Mocked networking resource: CRUD on `/api/networking/.../vpcs` | stoplight_mock |

---

## Infrastructure & Operational

| Term | Definition | Source |
|---|---|---|
| **audit logging** | Two layers: Dex JSON logs + libcloud REST `auth_audit.log` (JSON per OIDC decode) | IDENTITY, ARCHITECTURE |
| **auth_audit.log** | libcloud REST file: one JSON line per token decode with `principal`, `subject`, `email`, `issuer` | IDENTITY |
| **depends_on (service_healthy)** | Docker Compose condition ensuring tooling containers wait for server readiness | lldap |
| **Docker Compose profile** | Profiles (`tools`, `bootstrap`) keep one-shot services from starting on `up` | lldap |
| **healthcheck-driven ordering** | Using upstream image healthchecks so tooling doesn't race the server on first boot | lldap |
| **named volume** | `lldap_data` — persistent Docker volume holding LLDAP's embedded DB | lldap |
| **oidc_token_decoded** | Audit log event name when libcloud REST decodes an OIDC token | IDENTITY |
| **one-shot service** | Docker Compose service with `restart: "no"` that runs once and exits (bootstrap) | lldap |
| **per-tenant credentials (owner-only)** | Backend cloud credentials scoped per tenant; only tenant `owner` may write them | authorization, ARCHITECTURE |
| **rootless container** | LLDAP runs as UID/GID 1000 (non-root) | lldap |
| **self-signed TLS cert** | Generated by mock `entrypoint.sh` for HTTPS on the emulator shim | stoplight_mock |
| **superadmin gating** | `vault_bootstrap.py` and `openfga_bootstrap.py` refuse to run without `SUPERADMIN_JWT` | authorization, ARCHITECTURE |
| **Vault read token** | Least-privilege token issued to libcloud REST for reading cloud credentials at runtime | ARCHITECTURE |
