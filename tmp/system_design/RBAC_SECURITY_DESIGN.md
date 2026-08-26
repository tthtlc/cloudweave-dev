# RBAC Security Design — libcloud REST + Dex + OpenFGA + Vault

This document is the **final, consolidated RBAC security design** for the
libcloud cloud-management platform. It is written to follow the pedagogical
shape of the
[Kubernetes RBAC Authorization Guide](https://www.plural.sh/blog/kubernetes-rbac-guide/)
(Subjects → Resources → Verbs → Roles/Bindings → Authorization process → Best
practices → Pitfalls → Advanced/troubleshooting), but every concept is
re-expressed in the primitives of **this** stack: **LLDAP** (identity), **Dex**
(OIDC), **OpenFGA** (relationship-based authorization), **libcloud REST**
(policy gateway + scope gate), **Vault** (secrets), and the **AWS / Nutanix**
cloud backends.

It consolidates the current design (`system_design/ARCHITECTURE.md`,
`authorization.md`, `IDENTITY.md`, `privilege.md`, `privilege0.md`,
`rest_api_security.md`, `overall_arch_dev_vs_admin.md`, the per-project
`*/ARCHITECTURE.md`) **and** folds in the proposal in
`adding_postgres_openfga.md` (move OpenFGA from sqlite/in-memory to a
PostgreSQL backend, drive all authorization data through the OpenFGA
transactional API, and use versioned authorization models). Where the proposal
changes the current design, the change is marked **[PROPOSAL]**.

---

## Key Takeaways

- **RBAC secures every cloud action.** No call reaches AWS or Nutanix unless it
  passes three independent gates: a JWT scope gate, a provider allowlist, and an
  OpenFGA relationship check. Least privilege is enforced by *composing* a
  narrow role with a narrow scope with a narrow relationship — never by a single
  broad "admin" flag.
- **Master the four RBAC primitives.** This stack uses the analogues of
  Kubernetes' four objects: **Subjects** (LLDAP users → OpenFGA `user:*`),
  **Resources** (OpenFGA objects: `tenant`, `provider`, `aws_region`,
  `nutanix_cluster`, `libcloud_api`), **Verbs** (OpenFGA computed relations:
  `can_connect`, `can_use`, `can_provision`, `can_read`, `can_manage_*`), and
  **Roles/Bindings** (tenant relations `owner`/`admin`/`viewer` = the Role;
  the tuple `user:X admin tenant:Y` = the Binding). The platform-level
  `superadmin` relation is the analogue of a ClusterRole.
- **The Postgres migration makes RBAC dynamic and transactional
  [PROPOSAL].** Today authorization data lives in a sqlite file under
  `openfga-data`; the proposal moves it to PostgreSQL so that role/permission
  mutations become ACID, API-driven, auditable, multi-instance, and horizontally
  scalable — exactly the properties Kubernetes RBAC gets for free from etcd.
- **Automate and audit at scale.** Like Kubernetes RBAC, this system's RBAC is
  *additive* (a user's effective permission is the union of all tuples that
  resolve to `true`). That makes regular auditing, drift detection, and
  centralized tuple management essential once the tenant count grows.

---

## What is RBAC in this stack?

The platform is a multi-tenant cloud management portal: human operators
provision VMs, networks, volumes, and images on **AWS EC2** and **Nutanix
Prism Central** through one unified REST facade (`libcloud.rest`). RBAC here
governs *who may do what on which cloud tenant/backend*, end to end.

RBAC in this stack is **not** a single component. It is the composition of four
layers, each answering one question:

| Question | Answered by | Mechanism |
|---|---|---|
| **Who is the caller?** | Dex (OIDC) → LLDAP | LDAP bind → signed JWT with `sub` = LLDAP `uid` |
| **May they call this API operation?** | libcloud REST | JWT `scope` set derived from the resolved principal |
| **May they use this provider / backend / tenant?** | OpenFGA | `can_connect` / `can_use` / `can_provision` / `can_read` relationship checks |
| **How do we reach the cloud?** | libcloud REST → Vault → libcloud driver | Server-side least-privilege Vault read token; cloud creds never travel from the client |

This is the direct analogue of Kubernetes' "authenticate the user → check the
RoleBinding's verbs on the resource's API group → admit the request", except
that the resource graph is a **relationship graph** (ReBAC) rather than a flat
`(namespace, resource, verb)` table, and the "service account to cloud" hop is
brokered by Vault instead of an IAM role attached to a pod.

```
┌──────────────────────────────────────────────────────────────┐
│  Client (provision_aws.sh / curl)                            │
└──────────┬───────────────────────────────────┬───────────────┘
           │ OIDC login (password)             │ Bearer JWT + connection
           ▼                                   ▼
   ┌──────────────┐                   ┌────────────────────────────┐
   │ Dex :5556    │                   │ libcloud REST :8765        │
   │ (OIDC issuer)│                   │  1. JWT verify (JWKS)      │
   └──────┬───────┘                   │  2. principal_map → slug   │
          │ LDAP bind                 │  3. scope gate (route)     │
          ▼                           │  4. allowed_providers gate │
   ┌──────────────┐                   │  5. OpenFGA Check          │
   │ LLDAP :3890  │                   │  6. Vault read → driver    │
   │ (user dir)   │                   └──────┬───────────┬────────┘
   └──────────────┘                          │           │
                                  ┌──────────▼───┐  ┌───▼──────────┐
                                  │ OpenFGA :8080│  │ Vault :8200  │
                                  │ (ReBAC)      │  │ (KV v2)      │
                                  └──────┬───────┘  └───┬──────────┘
                                         │ [PROPOSAL]    │
                                         ▼               │
                                  ┌──────────────┐       │
                                  │ PostgreSQL   │       │
                                  │ (tuples+model)│      │
                                  └──────────────┘       │
                                                         ▼
                                                  AWS EC2 / Nutanix PC
```

---

## Understanding the RBAC model

### Core concepts (Subjects, Resources, Verbs)

Just as Kubernetes RBAC is built from Subjects, Resources, and Verbs, this
stack is built from the same three concepts, mapped onto OpenFGA + libcloud
REST primitives.

#### Subjects — the "who"

| K8s subject type | This stack | Where it lives |
|---|---|---|
| **User** | Human operator (`superadmin`, `aws-owner`, `aws-admin`, `aws-viewer`, `ntnx-*`, `cloud-denied`) | LLDAP `ou=people` (`uid`, `mail`, `cn`, custom attrs `department`/`role`/`jobtitle`) |
| **Group** | *(not yet used as an OpenFGA subject — see §"Advanced: group claims" below)* | LLDAP `ou=groups` exists; Dex does not currently emit group claims |
| **ServiceAccount** | The **libcloud REST API server itself** — it authenticates to Vault with a least-privilege read token, and to clouds with the per-tenant creds it reads from Vault | Vault `libcloud-rest-read` policy + per-tenant KV secrets |

The Dex LDAP connector maps `idAttr: uid`, `emailAttr: mail`, `nameAttr: cn`.
Dex puts the LLDAP `uid` into the JWT `sub`; libcloud REST and OpenFGA both
treat `user:<uid>` as the authorization subject. Principals are **stable
application slugs**, never raw Dex/Entra `sub` GUIDs — the `principal_map.json`
indirection (`by_sub` / `by_email` / `legacy_username_aliases`) keeps OpenFGA
tuples invariant across an IdP migration (Phase 1 LLDAP → Phase 2 Entra/AD).

#### Resources — the "what"

OpenFGA object types are the resources. Each is the analogue of a Kubernetes
API resource:

| K8s resource | This stack (OpenFGA object type) | Demo instances |
|---|---|---|
| cluster-scoped (`nodes`, `pv`s) | `platform` | `platform:main` (cluster-wide admin plane) |
| namespace | `tenant` | `tenant:aws`, `tenant:nutanix`, `tenant:aws-dev`, … |
| namespace-scoped workload | `libcloud_api` | `libcloud_api:main` (the REST gateway itself) |
| provider catalog entry | `provider` | `provider:aws`, `provider:nutanix` |
| backend / cloud endpoint | `aws_region`, `nutanix_cluster` | `aws_region:ap-southeast-1`, `nutanix_cluster:lab`, and per-tenant `aws_region:<tenant>` / `nutanix_cluster:<tenant>` |
| *(future [PROPOSAL])* | `vm`, `network`, `logfile`, `cloud_account` | resource-level inheritance per `adding_postgres_openfga.md` §"Authorization Model" |

#### Verbs — the "how"

The verbs are the **computed relations** OpenFGA evaluates at runtime. Each is
named like a Kubernetes verb (`can_*`) and is derived from the role relations
via `union` / `intersection` / `tupleToUserset`:

| K8s verb | This stack (OpenFGA computed relation) | Checked on | Meaning |
|---|---|---|---|
| `get`/`list`/`watch` | `can_read` | `aws_region:*` / `nutanix_cluster:*` | Enumerate cloud resources |
| `create`/`update`/`patch`/`delete` | `can_provision` | same backend objects | Mutate cloud resources |
| — (admit to API) | `can_connect` | `libcloud_api:main` | May call libcloud REST at all |
| — (use a provider) | `can_use` | `provider:aws` / `provider:nutanix` | May target that cloud |
| `impersonate`/`rolebindings:*` | `can_assign_owner` / `can_assign_admin` / `can_assign_viewer` | `tenant:*` | Delegated administration |
| — (secrets write) | `can_manage_credentials` | `tenant:*` | Owner-only Vault credential writes |
| `*` (cluster-admin) | `can_manage_platform` | `platform:main` | `superadmin` only — bootstrap & break-glass |

**Critical difference from Kubernetes:** OpenFGA relations are **not purely
additive**. Where Kubernetes can only *grant* (no deny rule), OpenFGA supports
`intersection` — used today for `can_provision`, which requires **both** a
tenant role (`admin`/`owner` *via* the `tenant` relation) **and** `can_use` on
the linked provider. This is how cross-cloud isolation is enforced: an
`aws-admin` has the tenant-admin half but not the `can_use provider:nutanix`
half, so `can_provision nutanix_cluster:lab` is `false` even though no explicit
"deny" tuple exists.

### The authorization graph

```mermaid
flowchart TB
  SA["user:superadmin"] -->|superadmin| P["platform:main"]
  SA -->|owner| TAWS["tenant:aws"]
  SA -->|owner| TNTX["tenant:nutanix"]

  AWO["user:aws-owner"] -->|owner| TAWS
  AWA["user:aws-admin"] -->|admin| TAWS
  AWV["user:aws-viewer"] -->|viewer| TAWS
  NOW["user:ntnx-owner"] -->|owner| TNTX
  NWA["user:ntnx-admin"] -->|admin| TNTX
  NWV["user:ntnx-viewer"] -->|viewer| TNTX

  TAWS -->|parent| API["libcloud_api:main"]
  TNTX -->|parent| API
  TAWS -->|parent| PA["provider:aws"]
  TNTX -->|parent| PN["provider:nutanix"]

  PA -->|provider| AR["aws_region:ap-southeast-1"]
  TAWS -->|tenant| AR
  PN -->|provider| NC["nutanix_cluster:lab"]
  TNTX -->|tenant| NC

  CD["user:cloud-denied"] -.->|no tuples| X["denied at can_connect"]
```

Source of truth: `LIBCLOUD_MODEL` and `INITIAL_TUPLES` in
`openfga_my/openfga_bootstrap.py` (today, seeded into sqlite; **[PROPOSAL]**
seeded into PostgreSQL via the same bootstrap, then mutated only through the
OpenFGA Write API).

---

## Why this RBAC matters

The same reasons Kubernetes RBAC matters apply here, with cloud-specific
blast-radius:

- **Least privilege limits blast radius.** A compromised `aws-viewer` JWT can
  only enumerate AWS resources; it cannot create, delete, or reach Nutanix at
  all. A compromised `aws-admin` cannot touch Nutanix or write Vault
  credentials (that is owner-only). Only `superadmin` is cross-tenant, and it
  is heavily audited.
- **Multi-tenant isolation is structural, not conventional.** AWS tenant
  members are simply *not members* of `tenant:nutanix`; the `can_use`
  computation therefore fails for the other cloud without any per-route
  deny-list to maintain.
- **Delegated administration scales governance.** Owners assign admins;
  admins assign viewers; nobody can self-elevate. This mirrors Kubernetes'
  `rolebindings` verbs without requiring a central operator for every change.
- **The Postgres migration [PROPOSAL] makes the model production-grade.**
  Today sqlite/in-memory is fine for a single-node demo but is explicitly
  *not production-ready* by OpenFGA's own classification. PostgreSQL brings
  ACID tuple writes, queryable audit history, multi-instance OpenFGA, and
  horizontal scaling — the same properties etcd gives Kubernetes RBAC.

---

## Essential RBAC components

This stack has the direct analogues of Kubernetes' four RBAC objects.

### Roles and "ClusterRoles"

| K8s object | This stack | Scope | Defined in |
|---|---|---|---|
| **Role** (namespace-scoped) | A tenant relation: `owner`, `admin`, `viewer` on `tenant:<id>` | One tenant | `LIBCLOUD_MODEL` → `type tenant` |
| **ClusterRole** (cluster-wide) | The `superadmin` relation on `platform:main` | Whole platform | `LIBCLOUD_MODEL` → `type platform` |

The "Role definition" is the set of computed relations a tenant relation
implies — i.e. the `define can_provision: admin or owner` block in the model.
Changing the model **is** changing the Role definitions; **[PROPOSAL]** this
becomes a versioned, API-pushed migration (see §"Implementing model changes").

### Bindings (RoleBindings / ClusterRoleBindings)

| K8s object | This stack | Example |
|---|---|---|
| **RoleBinding** | A relationship tuple `user:<uid> <role> tenant:<id>` | `user:aws-admin admin tenant:aws` |
| **ClusterRoleBinding** | The tuple `user:superadmin superadmin platform:main` (+ `owner` on every tenant as break-glass) | `user:superadmin superadmin platform:main` |

Bindings are stored as **tuples** in the OpenFGA datastore. Today: 17 seeded
tuples in `INITIAL_TUPLES`. **[PROPOSAL]** they live in PostgreSQL and are
mutated through `POST /stores/{id}/write` (atomic batch, up to 100 tuples per
call, `on_duplicate: ignore` for idempotent imports).

The "hierarchy" tuples — `tenant:<id> parent libcloud_api:main`,
`tenant:<id> parent provider:<cloud>`, `provider:<cloud> provider <backend>`,
`tenant:<id> tenant <backend>` — are the wiring that lets a tenant-level Role
propagate down to a backend Verb (the `tupleToUserset` rewrites in the model).
They are the analogue of Kubernetes' namespace membership + default
RoleBindings, but expressed as relationships.

### The role catalog (concrete)

| Role | Where it lives | OpenFGA relation(s) | JWT scope set | Provider set | Effective reach |
|---|---|---|---|---|---|
| `superadmin` | `platform:main` | `superadmin` on platform; `owner` on every tenant (break-glass) | `PROVISIONER_SCOPES` | `["*"]` | All clouds, all operations; bootstrap & assign owners |
| `<tenant>-owner` | `tenant:<id>` | `owner` | `PROVISIONER_SCOPES` | own cloud only (`can_use`) | Full access to its cloud; assign admins & viewers; set backend creds |
| `<tenant>-admin` | `tenant:<id>` | `admin` | `PROVISIONER_SCOPES` | own cloud only | Provision + read its cloud; assign viewers; **cannot** assign admins or set creds |
| `<tenant>-viewer` | `tenant:<id>` | `viewer` | `READER_SCOPES` | own cloud only | Enumerate (read-only) its cloud; cannot mutate, cannot assign |
| `cloud-denied` | LLDAP only | *(no tuples)* | `READER_SCOPES` | `["aws","nutanix"]` | Authenticated, but every `can_connect`/`can_use` fails → 403 |

Per-cloud principal names follow the **`<tenant>-<role>` suffix convention**
recognized by `_role_suffix()` in `libcloud.rest/app/auth/identity.py`, so a
freshly-created tenant (`aws-dev`) gets the correct scopes *without* editing
`PRINCIPAL_SCOPES`.

---

## The RBAC authorization process

### Request attributes

When a request hits libcloud REST, the authorization decision uses these
attributes (parallel to Kubernetes' request attributes):

| K8s attribute | This stack attribute | Source |
|---|---|---|
| User | `TokenClaims.sub` (principal slug) | `resolve_principal(sub, email)` from `principal_map.json` |
| Groups | *(future)* Dex group claims → OpenFGA `group:*` subjects | LLDAP `ou=groups` (not yet wired) |
| API group / resource | Route's required scope (`compute:node:create`, …) | `require_scopes(...)` on the route |
| Resource name / namespace | OpenFGA backend object (`aws_region:{auth_binding}` / `nutanix_cluster:{auth_binding}`) | `connection.auth_binding` (tenant id) |
| Verb | Scope class → `can_provision` (write scopes) / `can_read` (read scopes) | `WRITE_SCOPES` / `READ_SCOPE_ALIASES` in `policy.py` |

### The authorization process (step by step)

For each provider-backed request (e.g. `POST /v1/compute/nodes`):

1. **RequestIDMiddleware** assigns a request id.
2. **`get_current_claims`** decodes the Bearer JWT via Dex JWKS; `resolve_principal`
   maps `sub`/`email` → principal slug; `TokenClaims` is built (sub, scope,
   `allowed_providers`, tenant_id, jti, session_id, `access_token`).
3. **`require_scopes("compute:node:create")`** — 403 `auth_insufficient_scope`
   if the role's scope set lacks it (e.g. `aws-viewer`).
4. **`policy_engine.authorize_connection`** runs:
   - `_token_has_scope` re-confirms the scope.
   - `claims.allowed_providers` gate — 403 `auth_provider_denied` if the role's
     provider set excludes `connection.provider` (e.g. `ntnx-admin` calling AWS).
   - `enforce_credential_policy` — 400 if the client tried to pass `key`/`secret`
     (defense in depth; cloud creds must come from Vault, not the client).
   - `_enforce_openfga` (fga_client.py, forwarding the Dex JWT as
     `Authorization: Bearer`):
     - `can_connect` on `libcloud_api:main` — 403 for `cloud-denied`.
     - `can_use` on `provider:{aws|nutanix}` — 403 for cross-cloud users.
     - write scope ∈ `WRITE_SCOPES` → `can_provision` on
       `{provider_object}:{auth_binding}` — 403 for `aws-viewer`.
     - read scope → `can_read` on the backend (fallback `can_provision`).
5. **`check_driver_capability`** verifies the driver supports the operation
   (e.g. `create_node`).
6. **`compute_service`** → `build_driver` → `vault_client` reads
   `secret/data/libcloud/<tenant>` → libcloud driver → cloud API.

Every 403 carries a **distinct error code**
(`auth_insufficient_scope`, `auth_provider_denied`, `authz_fga_denied`,
`provider_capability_unsupported`) so the failing layer is identifiable from
the response — the same observability Kubernetes gives with
`kubectl auth can-i --list`.

### Additive vs. intersected permissions

Like Kubernetes, **grant-style** relations are additive: a user's `can_read`
is the union of `viewer`, `operator`, `tenant_viewer`, `tenant_admin`,
`tenant_owner`, and `can_use`-via-provider. Unlike Kubernetes, **`can_provision`
is an `intersection`** — it requires both a tenant-admin/owner/operator relation
*and* `can_use` on the linked provider. This is the mechanism that enforces
cross-cloud isolation without ever writing a "deny" tuple, and it is stricter
than pure-additive Kubernetes RBAC.

### Wildcards and their risks

| K8s wildcard risk | This stack equivalent | Mitigation |
|---|---|---|
| `verbs: ["*"]` | `PROVISIONER_SCOPES` granted to a viewer | `READER_SCOPES` is a separate, narrow set; viewers never receive write scopes |
| `resources: ["*"]` | `allowed_providers: ["*"]` | Reserved for `superadmin` only; tenant roles get a single-cloud list |
| `system:masters` group | The `superadmin` relation on `platform:main` | Kept to a single LLDAP user; every superadmin action is recorded in the Vault **and** OpenFGA audit logs |

The `superadmin` is the deliberate analogue of `system:masters`: it bypasses
tenant boundaries (it is `owner` on every tenant as break-glass). It must stay
tiny, audited, and used only for bootstrap/recovery — never for daily
provisioning.

### Namespace vs. cluster-wide (tenant vs. platform)

This is the tenant-vs-platform split:
- **Tenant-scoped Roles** (`owner`/`admin`/`viewer` on `tenant:<id>`) only
  propagate inside that tenant's subtree (`parent`/`tenant` relations to
  providers and backends). An `aws-owner` has *zero* authority in
  `tenant:nutanix`.
- **Platform-scoped ClusterRole** (`superadmin` on `platform:main`) is the only
  role that crosses tenants, and it exists for bootstrap + break-glass only.

---

## Implementing the RBAC design

This section is the operator/developer "how to" — the equivalent of
`kubectl apply -f role.yaml` for this stack.

### Enabling RBAC (bootstrap)

1. `setup.sh` creates `libcloud_net`.
2. **Superadmin Dex login** (`scripts/superadmin_auth.sh` +
   `verify_superadmin_jwt.py`) → `SUPERADMIN_JWT`. Without it, both
   `vault_bootstrap.py` and `openfga_bootstrap.py` refuse to run.
3. **Dex, LLDAP, Vault** start; `vault_bootstrap.py` initializes/unseals Vault,
   enables KV v2, issues the `libcloud-rest-read` token, and configures the
   LDAP auth method.
4. **OpenFGA bootstrap** (`openfga_bootstrap.py`):
   - creates the store,
   - pushes the authorization model (`LIBCLOUD_MODEL`),
   - writes `INITIAL_TUPLES` (17 tuples),
   - runs 25 `VALIDATION_CHECKS`.
5. `setup.sh` syncs `FGA_STORE_ID`/`FGA_MODEL_ID`/`VAULT_ADDR`/`VAULT_TOKEN`
   into `libcloud.rest/.env` and recreates the API container.

**[PROPOSAL]** Step 4 changes datastore from sqlite to PostgreSQL (see
§"Migration to PostgreSQL" below); the bootstrap logic itself is unchanged
because it already talks to OpenFGA over its HTTP API.

### Creating and managing Roles (the model)

The Role definitions live in `LIBCLOUD_MODEL` (`openfga_bootstrap.py`). To add
or change a role's privileges today, edit the model and re-bootstrap. **[PROPOSAL]**
this becomes a **versioned model push**:

```python
new_model = """
model schema 1.1
type tenant
  relations
    define owner: [user]
    define admin: [user]
    define viewer: [user]
    define operator: [user]              # NEW role
    define can_provision: admin or owner or operator   # now includes operator
"""
await fga_client.write_authorization_model(new_model)
```

Properties of model versioning (per `adding_postgres_openfga.md`):
- The old model stays active until you explicitly switch
  `authorization_model_id`; existing tuples are preserved.
- You can pin `authorization_model_id` per API call for gradual rollout
  (canary a new model on one service while others use the old one).
- The model is validated on creation for well-formedness and evaluation
  efficiency.

### Binding Roles to Subjects (writing tuples)

Bindings are written through the OpenFGA Write API
(`POST /stores/{id}/write`), wrapped by helper scripts:

| To assign this | Write this tuple | Used by |
|---|---|---|
| `superadmin` | `user:superadmin superadmin platform:main` | `openfga_bootstrap.py` |
| break-glass owner on a tenant | `user:superadmin owner tenant:<id>` | `openfga_bootstrap.py` |
| a tenant owner | `user:<id>-owner owner tenant:<id>` | `create_tenant.sh` |
| a tenant admin | `user:<id>-admin admin tenant:<id>` | `create_tenant.sh` |
| a tenant viewer | `user:<id>-viewer viewer tenant:<id>` | `create_tenant.sh` |
| tenant → API gateway | `tenant:<id> parent libcloud_api:main` | `create_tenant.sh` |
| tenant → provider | `tenant:<id> parent provider:<cloud>` | `create_tenant.sh` |
| provider → backend | `provider:<cloud> provider <backend_type>:<id>` | `create_tenant.sh` |
| tenant → backend (role propagation) | `tenant:<id> tenant <backend_type>:<id>` | `create_tenant.sh` |

Atomic batch writes (up to 100 tuples per call, `on_duplicate: ignore`) make
tenant creation an atomic operation — the analogue of
`kubectl auth reconcile` applying a whole Role + RoleBinding YAML at once.

### Verifying grants (the `kubectl auth can-i` equivalent)

`POST /stores/{id}/check` is the decision API. Helpers:
- `openfga_bootstrap.py::validate` — the 25-case post-deploy smoke test.
- `scripts/common.sh::fga_check` — per-step pre-check in provision scripts.
- `libcloud.rest/app/auth/fga_client.py::check` — the **enforcement** call
  (the only one that actually gates a request; the script calls are
  demonstrative).

Example allow:
```json
{"tuple_key": {"user": "user:aws-admin", "relation": "can_provision",
               "object": "aws_region:ap-southeast-1"}}
→ {"allowed": true}
```
Example deny (cross-cloud):
```json
{"tuple_key": {"user": "user:aws-admin", "relation": "can_provision",
               "object": "nutanix_cluster:lab"}}
→ {"allowed": false}
```

### Effective permissions matrix (the 25 validation checks)

| Principal | `can_manage_platform` | `can_connect` | `can_use` AWS/NTNX | `can_provision` AWS | `can_read` AWS | `can_provision` NTNX | `can_read` NTNX |
|---|---|---|---|---|---|---|---|
| `superadmin` | ✓ | ✓ | ✓ / ✓ | ✓ | ✓ | ✓ | ✓ |
| `aws-owner` / `aws-admin` | ✗ | ✓ | ✓ / ✗ | ✓ | ✓ | ✗ | ✗ |
| `aws-viewer` | ✗ | ✓ | ✓ / ✗ | ✗ | ✓ | ✗ | ✗ |
| `ntnx-owner` / `ntnx-admin` | ✗ | ✓ | ✗ / ✓ | ✗ | ✗ | ✓ | ✓ |
| `ntnx-viewer` | ✗ | ✓ | ✗ / ✓ | ✗ | ✗ | ✗ | ✓ |
| `cloud-denied` | ✗ | ✗ | ✗ / ✗ | ✗ | ✗ | ✗ | ✗ |

Delegated-admin checks: `aws-owner`/`superadmin` satisfy `can_assign_admin` on
`tenant:aws`; `aws-admin` does **not**. `aws-admin` satisfies
`can_assign_viewer`; `aws-viewer` does **not**. `can_manage_credentials` is
`owner`-only.

### Routes that intentionally skip OpenFGA

| Route | Why no OpenFGA | File |
|---|---|---|
| `GET /v1/auth/me` | Returns the caller's own claims | `auth/routes.py` |
| `POST /v1/auth/login`/`refresh`/`logout` | Local-auth token mint (disabled under OIDC) | `auth/routes.py` |
| `POST /v1/connections:test` | Probe only; `compute:read` scope gate is enough | `connections/routes.py` |
| `GET /v1/providers` | Static catalog; no backend access | `providers/routes.py` |
| `GET /v1/jobs/{id}` | Owner-scoped inline check (`requested_by == claims.sub`) | `jobs/routes.py` |

---

## RBAC best practices (for this stack)

### Principle of least privilege

- **Viewers get `READER_SCOPES` only**, never `PROVISIONER_SCOPES`. A viewer
  JWT cannot even reach a write route's scope gate, so OpenFGA never has to
  deny it on `can_provision`.
- **Admins cannot set credentials.** `can_manage_credentials` is `owner`-only;
  a compromised `aws-admin` JWT cannot rotate the tenant's AWS keys in Vault.
- **`allowed_providers` is single-cloud** for tenant roles. Cross-cloud calls
  fail at the provider gate (Layer 2) before OpenFGA is even consulted.
- **No client-supplied cloud credentials.** `enforce_credential_policy`
  rejects any `connection.credentials.key`/`secret`; cloud creds come only
  from Vault, read with a path-scoped read-only token.

### Auditing RBAC policies

| What | Where | Cadence |
|---|---|---|
| Tuple inventory | `POST /stores/{id}/read` (or `openfga-tuple-audit.py`) → `generated/audit/openfga_tuples_*.csv` | Per change + periodic |
| Vault policy bindings | `vault-policy-apply.sh` → `generated/audit/vault_policy_bindings_*.csv` | Per change |
| OpenFGA decisions | `generated/openfga_audit.log` (and OpenFGA's own audit device **[PROPOSAL]** when enabled) | Continuous |
| OIDC token decodes | `libcloud.rest/data/auth_audit.log` (one JSON line per decode) | Continuous |
| Vault writes | `generated/vault_audit.log` (JSONL per call) + Vault native audit device | Continuous |
| Offboarding | `generated/offboard_audit.log` | Per event |

**[PROPOSAL]** With PostgreSQL, the tuple store becomes directly queryable, so
audits and drift detection can be SQL-based instead of paginated API reads.

### Tenants for isolation (namespaces for isolation)

Tenants are the namespace analogue. Keep them small and purpose-scoped
(`tenant:aws`, `tenant:aws-dev`, `tenant:nutanix`) rather than one giant
tenant. Prefer **two owners per tenant** for business continuity (never zero),
with `superadmin` as the break-glass recovery authority outside every tenant
(per `privilege0.md`).

### Role aggregation

Today the model defines `can_provision`/`can_read` as `union`s over the role
relations — that *is* role aggregation. **[PROPOSAL]** When resource-level
types (`vm`, `network`, `logfile`) are introduced, prefer inheriting from the
parent (`admin from parent`) over re-stating per-resource roles, so a
tenant-admin automatically gets admin on its tenant's VMs without per-object
tuples — the OpenFGA equivalent of ClusterRole aggregation.

---

## Common RBAC pitfalls to avoid (this stack)

| K8s pitfall | This-stack pitfall | Avoidance |
|---|---|---|
| Overly permissive Roles / wildcards | Giving `allowed_providers: ["*"]` or `PROVISIONER_SCOPES` to a viewer | Keep `READER_SCOPES` separate; reserve `["*"]` for `superadmin` |
| Default Roles / implicit permissions | The legacy Phase-1 `cloud-admin`/`cloud-readonly` users lingering in LLDAP after the per-tenant migration | Delete obsolete LLDAP users + their `dex.env` entries; only per-tenant `*-owner/admin/viewer` should remain |
| `system:masters` group | Using `superadmin` for daily work | `superadmin` is bootstrap/break-glass only; daily provisioning uses tenant roles; all superadmin actions are dual-audited |
| Lingering permissions after user deletion | Deleting an LLDAP user but leaving their OpenFGA tuples | Offboard via a script that deletes the LLDAP user **and** all `user:<uid> * *` tuples **and** revokes Vault leases (`vault-lease-revoke.sh`) |
| Over-privileged ServiceAccounts | The libcloud REST API's Vault token being the **root** token | Replace `VAULT_TOKEN` (root) with the path-scoped `libcloud-rest-read` token (already issued by `vault_bootstrap.py`); blank `LIBCLOUD_AWS_PROD_*`/`LIBCLOUD_NTNX_LAB_*` in `.env` once Vault is the sole cred source |
| `system:unauthenticated` access | OpenFGA published to the host on `:8080` with `OPENFGA_AUTHN_METHOD=none` for debugging | Keep `--authn-method=oidc`; network-isolate `:8080` to `libcloud_net`; enable TLS for non-localhost |
| Stale JWKS after Dex key rotation | OpenFGA caches Dex JWKS at startup; a `kid`-miss after rotation → 503 `authz_fga_error` until restart | Coordinate Dex key rotation with an OpenFGA restart today; **[PROPOSAL]** add kid-miss→refetch with backoff (or upgrade OpenFGA) — see `openfga_dex_jwt.md` |
| Plaintext secrets on the host | `generated/dex.env`, `generated/vault.env` (root token + unseal key) on disk | Move unseal key to offline backup; move user passwords to a password manager; inject per-run via env; `chmod 600` as interim |

---

## Advanced RBAC techniques and troubleshooting

### Using RBAC with "service accounts" (machine identity)

The libcloud REST API is the in-cluster service account analogue. It
authenticates to Vault with a least-privilege read token
(`libcloud-rest-read` policy: `read` on `secret/data/libcloud/*`, `read`/`list`
on `secret/metadata/libcloud/*`) — it cannot write, delete, or reach any path
outside `secret/libcloud/*`. It never receives long-term AWS/Nutanix keys; it
reads the per-tenant KV secret at request time **after** OpenFGA has already
authorized the call. This is the same pattern as an EKS pod using IRSA to
assume an IAM role, mediated by Vault instead of STS.

**[PROPOSAL]** For per-tenant machine isolation, introduce one Vault AppRole
per tenant (RoleID/SecretID, TTL-bound) instead of a single shared
`libcloud-rest-read` token, and gate AppRole issuance on
`can_manage_credentials` (owner-only). This narrows blast radius further if the
REST API container is compromised.

### Integrating RBAC with external authentication (Phase 2)

Dex is the stable OIDC boundary. To migrate from LLDAP to Entra ID / AD /
Authentik:

1. Add an upstream OIDC/AD connector in `dex/config.template.yaml`.
2. Disable `enablePasswordDB`; remove the LDAP connector (or keep both during
   cutover).
3. Populate `principal_map.json` `by_sub` (Entra object GUID) / `by_email` for
   each corporate identity.
4. **Do not** change the OAuth `client_id` (`libcloud-rest`), the issuer URL,
   or any OpenFGA tuple object name — `user:cloud-admin`, `user:aws-admin`,
   etc. stay identical because tuples are written against stable application
   slugs, not raw IdP `sub`s.
5. Re-run `openfga_bootstrap.py` validation against the mapped principals.

Group claims (`groups`) from the upstream IdP should be mapped to OpenFGA
`group:*` subjects and used to assign **roles** (e.g.
`group:devops#member admin tenant:aws`), **not** used as OpenFGA user IDs
directly — group renames otherwise break coupling.

### Resource-level RBAC (future, [PROPOSAL])

`adding_postgres_openfga.md` proposes extending the model to resource types
`vm`, `network`, `logfile`, `cloud_account` with `parent`-based inheritance:

```fga
type vm
  relations
    define parent: [cloud_account]
    define owner: [user, group#member]
    define operator: [user, group#member]
    define viewer: [user, group#member]
    define can_start: owner or operator or admin from parent
    define can_stop:  owner or operator or admin from parent
    define can_delete: owner or admin from parent
```

This adds a fourth resource level (tenant → cloud_account → vm) so that, e.g.,
a VM owner can start/stop but not delete (only the cloud_account admin can
delete). It is the analogue of Kubernetes' namespace → sub-resource RBAC and
is the natural next step once the Postgres backend is in place (per-resource
tuples would dwarf sqlite's comfort zone).

### Troubleshooting checklist

| Symptom | Likely cause | Check |
|---|---|---|
| 403 `auth_insufficient_scope` | Role lacks the route's scope | `identity.py` `PRINCIPAL_SCOPES` / suffix logic vs. route's `require_scopes` |
| 403 `auth_provider_denied` | Cross-cloud call | `allowed_providers` for the principal vs. `connection.provider` |
| 403 `authz_fga_denied` | OpenFGA relation false | `POST /stores/{id}/check` with the exact `user`/`relation`/`object`; inspect tuples with `/read` |
| 503 `authz_fga_error` after Dex key rotation | Stale JWKS cache in OpenFGA | Restart OpenFGA; long-term add kid-miss→refetch |
| 401 `invalid_claims` from OpenFGA | Token `iss`/`aud` mismatch or expired | Confirm `iss=http://dex:5556/dex`, `aud=libcloud-rest`; re-login |
| New per-tenant user gets wrong scopes | Suffix not recognized | Ensure `uid` matches `<tenant>-owner\|-admin\|-viewer`; check `_role_suffix()` |
| Per-tenant isolation leaks in REST API | `policy.py` keys backend object on `region` not `auth_binding` | Derive `aws_region:{auth_binding}` / `nutanix_cluster:{auth_binding}` from `connection.auth_binding` (authorization.md §3 follow-up) |
| `cloud-denied` reaches a route | OpenFGA disabled (`FGA_ENABLED=false`) or `OPENFGA_AUTHN_METHOD=none` | Re-enable OIDC authn; keep `FGA_ENABLED=true` in prod |

### RBAC analysis tools

| Tool | Purpose |
|---|---|
| `openfga_bootstrap.py::validate` | 25-case post-deploy RBAC smoke test |
| `POST /stores/{id}/check` | Single decision query (the `kubectl auth can-i`) |
| `POST /stores/{id}/read` | List tuples (the `kubectl get rolebindings`) |
| `scripts/openfga-tuple-audit.py` | Tuple inventory → CSV |
| `scripts/vault-token-lookup.sh` | Inspect a Vault token's capabilities + TTL |
| `scripts/verify-ldap.py` | LLDAP directory verification (subjects) |
| `verify_superadmin_jwt.py` | Local JWT signature + claim check against Dex JWKS |
| **[PROPOSAL]** SQL queries on the Postgres tuple table | Drift detection, "who can do X on Y?", dormant-user detection |

---

## Migration to PostgreSQL ([PROPOSAL] — from `adding_postgres_openfga.md`)

### Why

OpenFGA classifies its storage engines:

| Engine | Status | Use case |
|---|---|---|
| PostgreSQL | Production ready | **Recommended for production** |
| MySQL | Production ready | Alternative persistent backend |
| SQLite | Beta | Single-node / testing — **current** |
| Memory | Dev only | Local development — **never production** |

The current stack uses sqlite on the `openfga-data` volume. The proposal moves
to PostgreSQL so that:

| Concern | File-Based / SQLite (today) | OpenFGA API + PostgreSQL (proposed) |
|---|---|---|
| Concurrency | File locks; race risk | ACID transactions |
| Consistency | Partial writes possible | Atomic batch writes (all-or-nothing) |
| Audit trail | Filesystem timestamps | Queryable tuple history + OpenFGA audit device |
| Performance | File I/O; no cache | In-memory check cache, fast-path, parallel eval |
| Validation | None on file content | API validates tuples against the model before accepting |
| Scalability | Single node | Multi-instance OpenFGA sharing one DB |
| Access control | Any process with file access | API-level OIDC authn gates all mutations |
| Distributed access | Files must be synced | HTTP/gRPC from any service on `libcloud_net` |

### What changes

1. **Add a `postgres` service** to `openfga_my/docker-compose.yml` (or reuse an
   external Postgres) on `libcloud_net`, with a named volume for durability.
2. **Change OpenFGA startup flags**:
   - `openfga-migrate`: `--datastore-engine=postgres
     --datastore-uri=postgres://openfga:***@postgres:5432/openfga?sslmode=disable`
   - `openfga` `run`: same `--datastore-engine` / `--datastore-uri`.
   - Migrations (`openfga_my/assets/migrations/postgres/001…005`) are applied
     by the one-shot `openfga-migrate` service before `openfga` starts (the
     files already exist in-repo).
3. **Bootstrap unchanged** — `openfga_bootstrap.py` already talks to OpenFGA
   over HTTP, so store/model/tuple creation and the 25 validation checks work
   identically against the Postgres-backed server.
4. **All subsequent mutations go through the API** — no file edits. The
   bootstrap YAML/JSON becomes a *bootstrap-only* seed; `create_tenant.sh`,
   `set_tenant_credentials.py`, and `scripts/common.sh::fga_check` already use
   the Write/Check APIs, so they are unchanged.
5. **Model evolution via versioned pushes** — new roles/relations/permissions
   are pushed with `write_authorization_model`; the old model stays active
   until `authorization_model_id` is switched, enabling canary rollout.
6. **Resource lifecycle sync [PROPOSAL follow-up]** — decide whether cloud
   resource creation events (VM/network provisioning) trigger OpenFGA tuple
   writes inline in the REST handler or via an event/webhook; both are viable
   once the DB backend is in place.

### What does NOT change

- The authorization **model** (`LIBCLOUD_MODEL`), the 17 seed tuples, the 25
  validation checks, the principal slug scheme, the Dex OIDC audience, the
  Vault credential paths, the libcloud REST scope gate, and the per-tenant
  `auth_binding` routing all remain identical. The Postgres migration is a
  *storage* change, not a *policy* change — exactly the property that makes it
  safe to do in isolation.

---

## Implementation plan — all steps, in order

The steps are grouped into phases. Each phase is independently shippable;
later phases depend on earlier ones.

### Phase 0 — Prerequisites & hardening (no policy change)

1. **Network-isolate OpenFGA.** Stop publishing `:8080` to the host in
   `openfga_my/docker-compose.yml`; keep it on `libcloud_net` only. Point host
   scripts at a proxy / `host.docker.internal`.
2. **Enable TLS on OpenFGA** (`--http-tls-enabled`, `--grpc-tls-enabled`) for
   any non-localhost deployment.
3. **Harden Vault.** Replace the root `VAULT_TOKEN` in `libcloud.rest/.env`
   with the path-scoped `libcloud-rest-read` token (already issued); blank the
   `LIBCLOUD_AWS_PROD_*` / `LIBCLOUD_NTNX_LAB_*` lines; bind host port
   `8200` to `127.0.0.1`; move `VAULT_UNSEAL_KEY` to offline backup.
4. **Move plaintext user passwords** out of `generated/dex.env` into an
   encrypted password manager; have scripts inject a single password via env
   at run time. `chmod 600` as interim.
5. **Fix `policy.py` per-tenant routing.** Derive the OpenFGA backend object
   from `connection.auth_binding` (`aws_region:{auth_binding}` /
   `nutanix_cluster:{auth_binding}`) instead of `connection.config.region`, so
   libcloud REST's own enforcement matches the scripts' per-tenant authz.
6. **Add `.gitignore` to `dex/`, `vault/`, `lldap/`** for `generated/` and
   `*.env` if those dirs are ever `git init`'d.
7. **Delete obsolete Phase-1 users** (`cloud-admin`, `cloud-readonly`) from
   LLDAP and their entries from `dex.env`; keep only per-tenant
   `*-owner/admin/viewer` + `superadmin` + `cloud-denied`.

### Phase 1 — PostgreSQL backend for OpenFGA ([PROPOSAL])

8. **Add a `postgres` service** to `openfga_my/docker-compose.yml` (image
   `postgres:16`, named volume `pgdata`, healthcheck, `libcloud_net`).
9. **Add Postgres credentials** to `openfga_my/.env` (gitignored):
   `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`.
10. **Switch `openfga-migrate` and `openfga` commands** to
    `--datastore-engine=postgres --datastore-uri=postgres://...@postgres:5432/openfga?sslmode=disable`.
    The migrations under `assets/migrations/postgres/` are applied by
    `openfga-migrate` automatically.
11. **Re-run `setup.sh`** end to end against the new backend; confirm
    `openfga_bootstrap.py` creates the store, pushes the model, writes the 17
    tuples, and all 25 `VALIDATION_CHECKS` pass.
12. **Verify durability**: `docker compose down` then `up`; confirm tuples,
    model, and store survive (they now live in `pgdata`, not the sqlite file).
13. **Enable OpenFGA's native audit device** and stream it to
    `generated/openfga_audit.log` alongside the existing script-level JSONL.
14. **Add a tuple-audit SQL job** that diffs
    `generated/audit/openfga_tuples_*.csv` snapshots and reports drift
    (dormant users, unexpected new tuples).

### Phase 2 — Dynamic, API-driven RBAC operations

15. **Make `create_tenant.sh` the only path** to mint a tenant: LLDAP users +
    OpenFGA tuples (9 per tenant) + per-tenant backend object, written
    atomically through the OpenFGA Write API. Document an offboarding script
    that deletes the LLDAP user **and** all their tuples **and** revokes Vault
    leases.
16. **Externalize `principal_map.json` management** into a small CRUD surface
    (or a versioned config file in git) so Phase-2 Entra `by_sub` mappings can
    be added without editing a JSON file on the API host.
17. **Add a "who can do X on Y?" query helper** (ListObjects /
    `POST /stores/{id}/list-objects`) for access reviews, backed by Postgres
    for speed.
18. **Add kid-miss→JWKS-refetch with backoff** (or upgrade OpenFGA) so Dex key
    rotation no longer requires an OpenFGA restart (per `openfga_dex_jwt.md`).

### Phase 3 — Resource-level RBAC ([PROPOSAL], optional)

19. **Push a new authorization-model version** adding `cloud_account`, `vm`,
    `network`, `logfile` types with `parent`-based inheritance (per
    `adding_postgres_openfga.md` §"Authorization Model").
20. **Canary the new model** by pinning `authorization_model_id` on one
    service while others use the old model; validate a sample of
    `can_start`/`can_stop`/`can_delete`/`can_view` checks.
21. **Switch the default `authorization_model_id`** once canary is green; keep
    the old model ID recorded for rollback.
22. **Wire resource lifecycle to tuple writes**: when libcloud REST creates a
    VM/network, write the `parent` + role tuples for that resource through the
    OpenFGA API (inline in the handler, or via an event/webhook). Delete the
    tuples on resource destruction.
23. **Extend the validation suite** (`VALIDATION_CHECKS`) to cover
    resource-level inheritance (e.g. a tenant-admin can `can_delete` a VM in
    its tenant's cloud_account; a viewer cannot `can_start`).

### Phase 4 — Phase-2 identity migration (external IdP)

24. **Add an upstream Dex connector** (Entra/AD/OIDC) in
    `dex/config.template.yaml` (sketch in `dex/config.phase2.example.yaml`).
25. **Disable the LDAP connector** (or keep both during cutover); disable
    `enablePasswordDB`.
26. **Populate `principal_map.json`** `by_sub`/`by_email` for each corporate
    identity; leave OpenFGA tuple object names unchanged.
27. **Re-run validation** against the mapped principals; confirm the 25 checks
    still pass with Entra-issued JWTs.
28. **Map group claims** to OpenFGA `group:*` subjects and use them to assign
    tenant roles (e.g. `group:devops#member admin tenant:aws`).

---

## Summary of key changes needed

| # | Change | Phase | Files / Components |
|---|---|---|---|
| 1 | Network-isolate OpenFGA `:8080`; enable TLS | 0 | `openfga_my/docker-compose.yml` |
| 2 | Replace root Vault token with scoped `libcloud-rest-read`; blank plaintext cloud creds in `.env` | 0 | `libcloud.rest/.env`, `vault_bootstrap.py` |
| 3 | Move unseal key offline; move user passwords to a password manager | 0 | `generated/vault.env`, `generated/dex.env` |
| 4 | Fix `policy.py` to derive backend object from `auth_binding` (per-tenant isolation) | 0 | `libcloud.rest/app/auth/policy.py`, `connections/credentials.py` |
| 5 | Delete obsolete Phase-1 LLDAP users (`cloud-admin`, `cloud-readonly`) | 0 | LLDAP, `generated/dex.env` |
| 6 | **Migrate OpenFGA datastore sqlite → PostgreSQL** | 1 | `openfga_my/docker-compose.yml`, `openfga_my/.env` |
| 7 | Enable OpenFGA native audit device + SQL tuple-drift job | 1 | `openfga_my/scripts/`, Postgres |
| 8 | Make `create_tenant.sh` the sole tenant-minting path; add offboarding script (LLDAP + tuples + Vault leases) | 2 | `openfga_my/scripts/` |
| 9 | Externalize `principal_map.json` management | 2 | `libcloud.rest/data/principal_map.json`, CRUD surface |
| 10 | Add "who can do X on Y?" ListObjects helper for access reviews | 2 | `openfga_my/scripts/` |
| 11 | Add kid-miss→JWKS-refetch (or upgrade OpenFGA) for Dex key rotation | 2 | OpenFGA config / upgrade |
| 12 | Push versioned model with resource-level types (`vm`, `network`, `logfile`, `cloud_account`) + `parent` inheritance | 3 | `openfga_bootstrap.py::LIBCLOUD_MODEL` |
| 13 | Wire resource lifecycle (create/destroy) to OpenFGA tuple writes | 3 | `libcloud.rest/app/compute/service.py`, `network/service.py` |
| 14 | Extend `VALIDATION_CHECKS` for resource-level inheritance | 3 | `openfga_bootstrap.py` |
| 15 | Add upstream Dex connector (Entra/AD); populate `principal_map.json by_sub`; map group claims to `group:*` subjects | 4 | `dex/config.template.yaml`, `principal_map.json`, `identity.py` |

### What stays the same (the invariant core)

These are deliberately **not** in the change list — they are the stable spine
that makes every phase safe to do in isolation:

- The **authorization model** shape (platform / tenant / libcloud_api /
  provider / aws_region / nutanix_cluster; owner/admin/viewer; can_connect /
  can_use / can_provision / can_read / can_manage_credentials /
  can_assign_*).
- The **17 seed tuples** and the **25 validation checks**.
- The **principal-slug scheme** (`user:<lldap-uid>`) and the
  `principal_map.json` indirection.
- The **three-layer request gate** (JWT scope → `allowed_providers` → OpenFGA).
- The **Dex OIDC audience** `libcloud-rest` and canonical issuer
  `http://dex:5556/dex`.
- The **Vault KV path convention** `secret/libcloud/<tenant>` and the
  owner-only `can_manage_credentials` gate.
- The **error-code taxonomy**
  (`auth_insufficient_scope` / `auth_provider_denied` / `authz_fga_denied` /
  `provider_capability_unsupported`).

---

## Related documentation

| Document | Focus |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Full system architecture (Dex + OpenFGA + libcloud REST + Vault + LLDAP) |
| [authorization.md](authorization.md) | OpenFGA authorization reference (model, tuples, checks, files) |
| [IDENTITY.md](IDENTITY.md) | Dex OIDC, principal mapping, Phase 2 migration |
| [privilege.md](privilege.md) / [privilege0.md](privilege0.md) | Hierarchical & delegated privilege rationale |
| [rest_api_security.md](rest_api_security.md) | REST API security pattern + secrets model |
| [overall_arch_dev_vs_admin.md](overall_arch_dev_vs_admin.md) | Admin/owner/developer task split |
| [openfga_dex_jwt.md](openfga_dex_jwt.md) | OpenFGA JWKS caching / kid-miss issue |
| `adding_postgres_openfga.md` (repo root) | The Postgres + API-driven OpenFGA proposal |
| `../vault/ARCHITECTURE.md` | Vault as encrypted secret store |
| `../dex/ARCHITECTURE.md` | Dex as OIDC gateway |
| `../lldap/ARCHITECTURE.md` | LLDAP user directory + custom schema |
| `../libcloud.rest/ARCHITECTURE.md` | libcloud REST gateway internals |
| `openfga_bootstrap.py` | Model definition, tuple seeding, 25 validation checks |
