# User Management

This document describes the user directory and the role/authorization model for
the libcloud platform: **where users live** (LLDAP) and **what roles they hold**
(OpenFGA), plus the scripts used to add / delete / modify / list each.

## 1. Users — LLDAP directory (`../lldap`)

All end-user identities are stored in **LLDAP**, deployed in the sibling compose
project at `../lldap`. Dex authenticates against LLDAP over LDAP and issues JWTs
that libcloud REST + OpenFGA accept. The OpenFGA project itself holds *no* user
records — it only stores relationship tuples that reference `user:<uid>`
subjects, where `<uid>` is the LLDAP uid.

Users are created by `setup.sh` (this project) via the `lldap-tools` container:
`docker compose -f ../lldap/docker-compose.yml run --rm lldap-tools
/scripts/lldap_ensure_user.sh <uid> <email> <name> <dept> <role> <jobtitle>
<password>`. The LLDAP directory `admin` user is the LLDAP built-in
administrator (created by LLDAP itself at first boot) and is **not** a libcloud
principal — it is only used to bootstrap `superadmin`.

| uid            | displayName    | mail                          | Origin                                           |
|----------------|----------------|-------------------------------|--------------------------------------------------|
| admin          | Administrator  | —                             | LLDAP directory admin (not a libcloud principal) |
| superadmin     | Super Admin    | superadmin@libcloud.local     | setup.sh — platform bootstrap                    |
| aws-owner      | AWS Owner      | aws-owner@libcloud.local      | setup.sh — tenant:aws                            |
| aws-admin      | AWS Admin      | aws-admin@libcloud.local      | setup.sh — tenant:aws                            |
| aws-viewer     | AWS Viewer     | aws-viewer@libcloud.local     | setup.sh — tenant:aws                            |
| ntnx-owner     | Nutanix Owner  | ntnx-owner@libcloud.local     | setup.sh — tenant:nutanix                        |
| ntnx-admin     | Nutanix Admin  | ntnx-admin@libcloud.local     | setup.sh — tenant:nutanix                        |
| ntnx-viewer    | Nutanix Viewer | ntnx-viewer@libcloud.local    | setup.sh — tenant:nutanix                        |
| cloud-denied   | Cloud Denied   | cloud-denied@libcloud.local   | setup.sh — denial demo                           |

### LLDAP management scripts (add / delete / modify / list)

All scripts live in `../lldap/scripts/` and are run through the `lldap-tools`
container (or directly via the scripts in `scripts/` of this project that wrap
them). They require `LLDAP_ADMIN_PASS` (the LLDAP directory admin password) and
are gated by the superadmin JWT obtained from `scripts/superadmin_auth.sh`.

| Operation | Script                                        | Notes                                                        |
|-----------|-----------------------------------------------|--------------------------------------------------------------|
| add       | `scripts/lldap-user-onboard.sh`               | Creates a user + assigns group(s); wraps `lldap_ensure_user.sh` |
| delete    | `scripts/lldap-user-offboard.sh`              | Removes the user and revokes group membership                |
| modify    | `scripts/lldap-user-password-reset.sh`        | Resets a user's password                                     |
| modify    | `scripts/lldap-admin-cred-rotate.sh`          | Rotates the LLDAP directory admin credential                 |
| list      | `scripts/lldap-user-list-groups.sh`           | Lists groups a user belongs to                               |
| list      | `scripts/lldap-audit-all-memberships.sh`      | Dumps every user→group membership for audit                  |
| group add | `scripts/lldap-group-add-member.sh`           | Adds a user to an LLDAP group                                |
| group del | `scripts/lldap-group-remove-member.sh`        | Removes a user from an LLDAP group                           |
| group list| `scripts/lldap-group-list-members.sh`         | Lists members of a group                                     |
| group CRUD| `scripts/lldap-group-create.sh` / `...-delete.sh` | Create / delete LLDAP groups                             |

Password sets for new users can also be done via `../lldap/scripts/set-password.py`.

## 2. OpenFGA — roles & object types (this project, `openfga_my`)

The authorization model is defined in `openfga_bootstrap.py::LIBCLOUD_MODEL`
and the seeded tuples in `openfga_bootstrap.py::INITIAL_TUPLES`. The live store
name is `libcloud-rest-store`; the store id and model id are written to
`generated/fga.env` after bootstrap. The model is schema 1.1.

Object types and their relations (only these exist in the active model — there
are **no** `role`, `api_scope`, or legacy object types):

| Object type     | Relations                                                                                                                            |
|-----------------|--------------------------------------------------------------------------------------------------------------------------------------|
| user            | (none — terminal subject type)                                                                                                      |
| platform        | superadmin, can_manage_platform                                                                                                      |
| tenant          | owner, admin, viewer, member, can_assign_owner, can_assign_admin, can_assign_viewer, can_manage_credentials, can_provision, can_read |
| libcloud_api    | parent, can_connect                                                                                                                  |
| provider        | parent, allowed, can_use                                                                                                             |
| aws_region      | provider, tenant, operator, viewer, tenant_owner, tenant_admin, tenant_viewer, can_provision, can_read                               |
| nutanix_cluster | same as aws_region                                                                                                                   |

**Role-bearing relations** (the "roles" the system creates) are exactly:

- `superadmin` on `platform:main`
- `owner` / `admin` / `viewer` on `tenant:aws` and `tenant:nutanix`

All other relations (`member`, `can_connect`, `can_use`, `can_provision`,
`can_read`, `can_assign_*`, `can_manage_credentials`,
`tenant_owner`/`tenant_admin`/`tenant_viewer`, etc.) are **derived** by the
model from those role-bearing tuples — they are not assigned directly to users.

The live store holds exactly the **17 tuples** seeded by
`openfga_bootstrap.py::INITIAL_TUPLES` (no legacy / orphan tuples).

### OpenFGA management scripts (add / delete / modify / list)

All scripts live in `scripts/` of this project and reuse
`scripts/openfga_common.sh` / `scripts/openfga_pylib.py`. They require a valid
superadmin JWT (`SUPERADMIN_JWT`) obtained from `scripts/superadmin_auth.sh`.

| Operation      | Script                                  | Notes                                                              |
|----------------|-----------------------------------------|--------------------------------------------------------------------|
| add tuple      | `scripts/openfga-tuple-write.sh`        | Write a `(user, relation, object)` tuple (grants a role)           |
| delete tuple   | `scripts/openfga-tuple-delete.sh`       | Delete a tuple (revokes a role)                                    |
| modify         | `scripts/openfga-breakglass-grant.sh`   | Grant/revoke superadmin break-glass owner on a tenant              |
| modify         | `scripts/openfga-presharedkey-rotate.sh`| Rotate the OpenFGA API preshared key                               |
| list / check   | `scripts/openfga-check.sh`              | Run a Check() for `(user, relation, object)`                       |
| list           | `scripts/openfga-list-objects.sh`       | List objects of a type a user can access for a relation            |
| list           | `scripts/openfga-list-users.sh`         | List users that have a relation on an object                       |
| audit          | `scripts/openfga-tuple-audit.py`        | Dump all tuples + which model relation they match                  |
| reconcile      | `scripts/openfga-tuple-reconcile.py`    | Reconcile live store against `INITIAL_TUPLES`                      |
| audit          | `scripts/openfga-denial-log-query.sh`   | Query OpenFGA denial logs                                          |

## 3. User → role table (effective, current model)

This is the complete, exact mapping defined by `INITIAL_TUPLES` (9 per-tenant
tuples + superadmin's 3 platform/tenant tuples = 17 total).

| LLDAP uid    | OpenFGA subject   | Relation   | Object              | Effective role                          |
|--------------|-------------------|------------|---------------------|-----------------------------------------|
| superadmin   | user:superadmin   | superadmin | platform:main       | Platform superadmin (bootstrap)         |
| superadmin   | user:superadmin   | owner      | tenant:aws          | Break-glass owner of tenant:aws         |
| superadmin   | user:superadmin   | owner      | tenant:nutanix      | Break-glass owner of tenant:nutanix     |
| aws-owner    | user:aws-owner    | owner      | tenant:aws          | Owner of tenant:aws                     |
| aws-admin    | user:aws-admin    | admin      | tenant:aws          | Admin of tenant:aws                     |
| aws-viewer   | user:aws-viewer   | viewer     | tenant:aws          | Viewer of tenant:aws                    |
| ntnx-owner   | user:ntnx-owner   | owner      | tenant:nutanix      | Owner of tenant:nutanix                 |
| ntnx-admin   | user:ntnx-admin   | admin      | tenant:nutanix      | Admin of tenant:nutanix                 |
| ntnx-viewer  | user:ntnx-viewer  | viewer     | tenant:nutanix      | Viewer of tenant:nutanix                |
| cloud-denied | (none)            | —          | —                   | Authenticated in Dex, denied at can_connect (intended) |
| admin        | (none)            | —          | —                   | LLDAP directory admin, not a libcloud principal        |

## 4. Non-user (structural) tuples in the store

These are the structural grants that wire tenants to the API gateway, providers,
and backends. They are written by `INITIAL_TUPLES` and are not user roles.

| Subject          | Relation | Object                  | Purpose                                     |
|------------------|----------|-------------------------|---------------------------------------------|
| tenant:aws       | parent   | libcloud_api:main       | AWS members can connect to the API          |
| tenant:nutanix   | parent   | libcloud_api:main       | Nutanix members can connect to the API      |
| tenant:aws       | parent   | provider:aws            | AWS members can can_use provider:aws        |
| tenant:nutanix   | parent   | provider:nutanix        | Nutanix members can can_use provider:nutanix|
| provider:aws     | provider | aws_region:aws          | Backend link                                |
| tenant:aws       | tenant   | aws_region:aws          | Role propagation to AWS backend             |
| provider:nutanix | provider | nutanix_cluster:nutanix | Backend link                                |
| tenant:nutanix   | tenant   | nutanix_cluster:nutanix | Role propagation to Nutanix backend         |

## 5. Privilege summary

- **superadmin** (on `platform:main`): bootstrap identity. Gates Vault seeding
  of backend cloud credentials, OpenFGA policy / tuple changes, and LLDAP user
  CRUD. Also owner on both tenants as break-glass.
- **owner** (on a `tenant`): can assign owner/admin/viewer, can manage backend
  cloud credentials (`can_manage_credentials`), can provision, can read.
- **admin** (on a `tenant`): can assign viewer, can provision, can read. Cannot
  assign admin/owner, cannot manage credentials.
- **viewer** (on a `tenant`): can read / enumerate only. Cannot provision,
  cannot assign, cannot manage credentials.
- **cloud-denied**: authenticated via Dex but has no OpenFGA tuples, so fails
  `can_connect` on `libcloud_api:main` — the intended denial-demo behavior.

Tenant roles propagate to backends (`aws_region:*` / `nutanix_cluster:*`) via
the `tenant` relation on each backend object (`tenant_owner`, `tenant_admin`,
`tenant_viewer` computed usersets), and to providers via `parent` → `member` →
`can_use`. Cross-cloud isolation is enforced: an AWS tenant user has no
relation on `provider:nutanix` / `nutanix_cluster:*` and vice versa.
