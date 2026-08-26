
> **This document is the single source of truth for RBAC design.** Every
> authorization model (OpenFGA `openfga_postgres/openfga_bootstrap.py`), every
> runtime enforcement point (`libcloud.rest/app/auth/policy.py`), and every
> portal role assignment (`identity_service/app/fga.py`) MUST conform to the
> relations, scopes, and bindings defined here. When the design changes, this
> document is updated first and the code is brought into line — not the other
> way around.

Here’s an RBAC design inspired by DigitalOcean, but generalized for multi-tenant AWS/Nutanix with a minimal role set: **SuperAdmin**, **Owner**, **Admin**, **Viewer**. [docs.digitalocean](https://docs.digitalocean.com/platform/organizations/roles/predefined/index.html.md)

## Design changes (changelog)

The following changes were made to bring the implementation in line with this
document. Each item maps to a concrete relation/tuple change in
`openfga_postgres/openfga_bootstrap.py` (the OpenFGA authorization model) and/or
`identity_service/app/fga.py` (portal role → OpenFGA tuple mapping).

1. **SuperAdmin is no longer a tenant Owner by default.** SuperAdmin is no longer
   seeded as `owner` on `tenant:aws` / `tenant:nutanix`. A new
   `platform.global_reader` relation (computed from `superadmin`) grants
   read-only visibility of every tenant and its resources, but **not**
   `can_provision`. SuperAdmin must be explicitly granted a tenant `owner`/`admin`
   role to provision inside a tenant (break-glass). *(rbac_design.md §SuperAdmin)*
2. **`can_assign_owner` is SuperAdmin-gated.** Moved off `owner` onto
   `tupleToUserset(platform → can_manage_platform)`. A tenant Owner can no longer
   mint co-Owners (closes a privilege-escalation path). *(§Owner, §SuperAdmin)*
3. **`admin` dropped from `can_assign_viewer`.** `can_assign_viewer` is now
   `owner`-only. Admins cannot change tenant membership in any form
   (no assign-owner/admin/viewer). *(§Admin)*
4. **`resource_class` object type added** with per-class `admin`/`viewer` bindings
   feeding backend `can_provision`/`can_read`. An Admin/Viewer can now be narrowed
   to a single resource class (compute/network/data/platform). *(§Resource class)*
5. **Tenant-lifecycle and global-policy relations added under
   `can_manage_platform`:** `can_manage_tenant_lifecycle`,
   `can_manage_global_policy`, `can_manage_iam_mapping` — each computed from
   `superadmin`, giving SuperAdmin's governance job relation-level granularity
   instead of a single `can_manage_platform` blob. *(§SuperAdmin)*
6. **Roles are bound PER-TENANT, never platform-wide.** A portal role maps to a
   single tenant derived from the principal slug (`aws-admin → tenant:aws`,
   `ntnx-admin → tenant:nutanix`), not to both tenants. This fixes the
   over-grant where `aws-admin` held `admin` on `tenant:nutanix` and could
   provision Nutanix. A principal with no resolvable tenant gets **no** tenant
   tuple (least-privilege default). *(§Portal role → OpenFGA tuple)*
7. **Deprovisioning is a first-class Admin/Owner capability.** Delete is part of
   the "full CRUD" granted to Owner/Admin, gated by `can_provision` on the
   backend object. The portal exposes a per-row **Deprovision** action on every
   resource the principal can `can_provision`; the action replays the OpenFGA
   `can_provision` check before `DELETE /v1/compute/nodes/{id}`. *(§Owner, §Admin,
   §Deprovisioning)*
8. **Portal hides the Admin/Owner dashboards from SuperAdmin.** SuperAdmin has
   no resource-management functionality by default (no `can_provision`, no
   per-tenant view of resources — it sees aggregated read-only visibility via
   `global_reader`, not the per-tenant Admin/Owner dashboards). The portal
   therefore no longer surfaces the "Admin" or "Owner" nav tabs to SuperAdmin,
   and the `/admin` / `/owner` routes are blocked for SuperAdmin (they redirect
   to `/unauthorized`). Real `admin`/`owner` users still get their own tab.
   SuperAdmin's landing page is `/superadmin`. *(§SuperAdmin)*
9. **The portal renders only the logged-in user's tenant(s).** The
   Admin/Owner dashboard **and** the Viewer dashboard are driven by per-cloud
   capabilities computed **live from OpenFGA** (`can_read` / `can_provision` on
   `aws_region:aws` and `nutanix_cluster:nutanix`) and returned by
   `/api/session` as `clouds[]`. A `user:aws-admin` therefore sees only the AWS
   Provision/View controls and the AWS resource table — the "Provision Nutanix"
   button and the Nutanix resource table are not rendered at all (not merely
   disabled). Symmetrically, `ntnx-admin` sees only Nutanix. A Viewer
   (`aws-viewer`/`ntnx-viewer`) gets a **read-only** resource view (a "View
   <Cloud> Resources" button + the resource table, with no Provision and no
   Deprovision controls) on their own tenant only. A principal with no tenant
   binding (e.g. a brand-new federated viewer) sees a "no cloud access" notice
   and no controls. This makes the UI always match the user's tenant, on every
   screen, for every role — the frontend never offers a control the backend
   will deny. *(§Portal role → OpenFGA tuple mapping, §Scope & permission
   matrix)*
10. **`can_update` (edit) is a distinct write verb from create/delete.** A new
    `can_update` relation is modeled on `tenant`, `resource_class`, and the
    backends (`aws_region` / `nutanix_cluster`), parallel in structure to
    `can_provision`. At present **Owner and Admin** satisfy `can_update`
    (tenant-wide Owner/Admin, or a per-class Admin via the `resource_class`
    arm); **Viewer** and **SuperAdmin (by default)** do not. The portal's
    Admin/Owner dashboard exposes a per-row **Edit** button (gated by the live
    `canUpdate` flag in `clouds[]`) that opens an inline form for VM parameters
    (name, size, memory, tags); the backend re-runs the OpenFGA `can_update`
    check and then `PATCH /v1/compute/nodes/{id}` on the libcloud REST API. This
    closes the previous "no create/update/delete distinction" gap for the
    update verb (delete remains gated by `can_provision` per §Deprovisioning).
    *(§Deprovisioning, §OpenFGA relation reference, §Scope & permission
    matrix)*
11. **Removed the undocumented OpenFGA surface (`operator`, `allowed`, duplicate
    backend `viewer`).** The model previously carried three out-of-band grant
    paths that bypassed the four-role taxonomy: a direct `operator` relation on
    `aws_region`/`nutanix_cluster` feeding `can_provision`/`can_read`/`can_update`
    (a fifth, undeclared role); a direct `allowed` relation on `provider` feeding
    `can_use` (an undocumented direct-grant hatch); and a direct `viewer`
    relation on the backends that duplicated the tenant-scoped `tenant_viewer`
    path. All three are removed. The only provision/update/read paths on
    backends are now the tenant-wide Owner/Admin (intersected with
    `provider.can_use` for cross-cloud isolation), the per-class
    `resource_class.can_provision`/`can_update`/`can_read`, and
    `platform.global_reader` (read-only). Break-glass elevation now grants a
    documented role (`admin` on the tenant or on a `resource_class`) for the TTL
    window instead of an `operator` tuple. *(§OpenFGA relation reference,
    §Scope & permission matrix)*

## Model overview

- **Tenants**: each tenant is a logical organization (e.g., one AWS account or one Nutanix project) containing cloud resources. [youtube](https://www.youtube.com/watch?v=qS2jIS9JYM4)
- **Scopes**:  
  - Global (cross-tenant): all tenants across AWS and Nutanix.  
  - Tenant: a single AWS account or Nutanix project. [docs.aws.amazon](https://docs.aws.amazon.com/prescriptive-guidance/latest/saas-multitenant-api-access-authorization/avp-mt-abac-examples.html)
  - Resource class: EC2/EBS/RDS/VPC, Prism clusters, AHV VMs, Calm apps, etc. [youtube](https://www.youtube.com/watch?v=qS2jIS9JYM4)
- **Roles**:  
  - SuperAdmin (global).  
  - Owner (per-tenant).  
  - Admin (per-tenant, optional per-resource class).  
  - Viewer (per-tenant, optional per-resource class).  

All permissions are assigned to roles; identities (users, groups, service accounts) just get role bindings at the appropriate scope. [digitalocean](https://www.digitalocean.com/resources/articles/rbac)

## Role semantics

### SuperAdmin (cross-organizational power)

Scope: global control plane (all tenants across AWS and Nutanix).

**SuperAdmin is NOT a tenant Owner/Admin/Viewer by default.** It is the
meta-operator that governs the platform; it does not touch day-to-day resources
inside a tenant unless explicitly granted a tenant role there (break-glass).
[docs.digitalocean](https://docs.digitalocean.com/platform/organizations/roles/predefined/index.html.md)

Capabilities:

- Tenant lifecycle and governance  
  - Create, onboard, and decommission tenants (register AWS accounts, Nutanix projects). [docs.aws.amazon](https://docs.aws.amazon.com/prescriptive-guidance/latest/saas-multitenant-api-access-authorization/avp-mt-abac-examples.html)
  - Assign and revoke tenant Owners (`can_assign_owner` is SuperAdmin-gated; tenant Owners cannot mint co-Owners).  
  - Configure global policies: password/SSO/IdP, logging, global guardrails, default quotas, compliance baselines. [youtube](https://www.youtube.com/watch?v=qS2jIS9JYM4)

- Cross-tenant resource governance  
  - Read-only visibility of all tenants and their aggregated resource inventories and metrics, granted by virtue of the role via `platform.global_reader` (computed from `superadmin`). This feeds `can_connect`, `provider.can_use`, and every `can_read`, but **not** `can_provision`, so SuperAdmin can observe every tenant yet cannot provision inside any of them by default. [docs.aws.amazon](https://docs.aws.amazon.com/prescriptive-guidance/latest/saas-multitenant-api-access-authorization/avp-mt-abac-examples.html)
  - Configure global FinOps policies and cost-visibility (but **not** direct billing changes inside individual tenants unless additionally granted a tenant role).

- IAM and policy management  
  - Define global RBAC templates, default roles, and constraints (e.g., “no public S3 by default”, “no unencrypted EBS”). [osohq](https://www.osohq.com/learn/rbac-examples)
  - Manage mappings between your RBAC engine and underlying AWS IAM/Nutanix Prism roles. [sefcom.asu](https://sefcom.asu.edu/publications/design-implementation-access-science2013.pdf)

OpenFGA relations on `platform:main` (all computed from `superadmin`):
`can_manage_platform`, `can_manage_tenant_lifecycle`, `can_manage_global_policy`,
`can_manage_iam_mapping`, `global_reader`.

Think of SuperAdmin as “meta-operator”: they control the multi-cloud platform, not the day-to-day resources inside each tenant unless explicitly added to those tenants as Owner/Admin/Viewer.

### Owner (tenant-level root)

Scope: one tenant (e.g., one AWS account or one Nutanix project).

Capabilities:

- Tenant configuration and membership  
  - Full access to tenant settings: name, tags, compliance profile, logging destinations, local quotas. [youtube](https://www.youtube.com/watch?v=qS2jIS9JYM4)
  - Manage membership within the tenant: assign/revoke Admin/Viewer roles, bind groups/service accounts. [youtube](https://www.youtube.com/watch?v=qS2jIS9JYM4)
  - Owners **cannot** assign or revoke tenant Owners — that is reserved for SuperAdmin (`can_assign_owner` is SuperAdmin-gated).

- Resource governance within tenant  
  - Full CRUD (create, update, delete) on all resource classes in that tenant, including deprovisioning (deleting) VMs/volumes/etc.:  
    - AWS: EC2, EBS, S3, RDS, EKS, IAM roles specific to the tenant, Lambda, VPC, etc.  
    - Nutanix: Prism clusters, AHV VMs, volumes, Calm blueprints, projects, Kubernetes clusters, etc. [youtube](https://www.youtube.com/watch?v=qS2jIS9JYM4)
  - Can delegate sub-control to Admins per resource class (e.g., “network admin”, “database admin”).

- Tenant-specific billing & cost controls  
  - Full read/write access to tenant billing configuration through your RBAC layer (link cost centers, budgets, internal chargeback tags), while underlying billing changes (credit cards, invoices) may be enforced via external finance process. [docs.aws.amazon](https://docs.aws.amazon.com/prescriptive-guidance/latest/saas-multitenant-api-access-authorization/avp-mt-abac-examples.html)

Owner is effectively the “DigitalOcean team owner” analogue at the AWS/Nutanix tenant scope: full power inside the tenant, plus membership management. [docs.digitalocean](https://docs.digitalocean.com/platform/teams/roles/predefined/)

### Admin (tenant-level operator)

Scope: one tenant, optionally constrained by resource class. An Admin is bound
to exactly one tenant and has **no** authority over any other tenant (e.g.
`aws-admin` cannot provision, read, or deprovision anything in `tenant:nutanix`).

Capabilities:

- Core definition  
  - Full lifecycle management (create, update, delete — including deprovisioning VMs/volumes/etc.) for assigned resource classes, but **no** tenant-wide membership changes and **no** tenant deletion. [docs.digitalocean](https://docs.digitalocean.com/platform/organizations/roles/predefined/index.html.md)
  - Can read all resources in the tenant; can act only within bound resource classes (network, compute, storage, data, k8s, IAM, etc).

Example sub-roles implemented with the same “Admin” concept but different scopes:

- Compute Admin  
  - AWS: EC2, ASG, Launch Templates, Lambda (run/modify), ECS/EKS node groups.  
  - Nutanix: AHV VMs, VM disk configs, snapshots, Calm app deployments. [youtube](https://www.youtube.com/watch?v=qS2jIS9JYM4)

- Network Admin  
  - AWS: VPCs, subnets, routing tables, NACLs, security groups, load balancers, API Gateway.  
  - Nutanix: networks, VLANs, IPAM, load-balancing constructs. [youtube](https://www.youtube.com/watch?v=qS2jIS9JYM4)

- Data Admin  
  - AWS: RDS, DynamoDB, Aurora, S3 bucket lifecycle and configuration.  
  - Nutanix: Volume groups, files, database services if present. [youtube](https://www.youtube.com/watch?v=qS2jIS9JYM4)

- Platform/Kubernetes Admin  
  - AWS: EKS clusters, their node pools, cluster-level IAM and add-ons.  
  - Nutanix: Kubernetes clusters on AHV/Anthos, namespaces and cluster-level operators. [youtube](https://www.youtube.com/watch?v=qS2jIS9JYM4)

Administrative permissions can be codified via your RBAC engine and then translated into AWS IAM policies / Nutanix Prism/Calm roles, similar to using a higher-level RBAC that compiles down to cloud-native policies. [sefcom.asu](https://sefcom.asu.edu/publications/design-implementation-access-science2013.pdf)

Admins cannot:

- Change tenant membership (cannot assign or revoke Owner/Admin/Viewer).  
- Delete the tenant.  
- Change cross-tenant/global policies (SuperAdmin only). [docs.digitalocean](https://docs.digitalocean.com/platform/organizations/roles/predefined/index.html.md)

### Viewer (tenant-level read-only)

Scope: one tenant, optionally constrained by resource class.

Capabilities:

- Read-only access  
  - Can list, describe, and view configuration/metadata for all assigned resources in the tenant. [digitalocean](https://www.digitalocean.com/blog/introducing-new-predefined-roles-for-rbac)
  - No create/update/delete permissions.  
  - Ideal for audit/compliance, observability, or management stakeholders.

Resource-class specific Viewers:

- Infra Viewer: EC2/AHV VMs, networks, storage, clusters.  
- Cost Viewer: cost dashboards, usage metrics (but not billing configuration changes). [digitalocean](https://www.digitalocean.com/blog/introducing-new-predefined-roles-for-rbac)
- Security Viewer: security findings, posture/compliance reports.

This role is your generalized “Resource Viewer” in DigitalOcean, but applied to AWS/Nutanix tenants. [docs.digitalocean](https://docs.digitalocean.com/platform/teams/roles/predefined/)

## Resource class (per-class sub-roles)

A **resource class** is a first-class scope: a `(tenant, class)` pair such as
`resource_class:aws-compute` or `resource_class:nutanix-network`. Each
`resource_class` object carries `admin` and `viewer` relations (bound to users)
plus a `tenant` and `platform` parent. Backends (`aws_region:*`,
`nutanix_cluster:*`) union their `can_provision`/`can_read` with the bound
resource classes' `can_provision`/`can_read`.

This is what lets an Admin/Viewer be narrowed to a single class:

- **Compute Admin** — EC2/ASG/Lambda/ECS-EKS node pools; AHV VMs, Calm apps.
- **Network Admin** — VPCs/subnets/SGs/NACLs/ELBs/API Gateway; Nutanix networks/VLANs/IPAM.
- **Data Admin** — RDS/DynamoDB/Aurora/S3 lifecycle; Nutanix volume groups/files.
- **Platform/Kubernetes Admin** — EKS + node pools; Nutanix K8s on AHV/Anthos.
- **Infra Viewer / Cost Viewer / Security Viewer** — read-only on a single class.

Per-class bindings are tenant-scoped, so a per-class Admin on `tenant:aws` cannot
reach `tenant:nutanix`'s backends (the resource_class is bound to its own
tenant, and the backend is bound to its own resource classes).

## Deprovisioning (delete)

Deprovisioning (deleting a VM/volume/etc.) is a **write** operation and is gated
by `can_provision` on the backend object — the same relation that gates
provisioning. Therefore:

- **Owner** and **Admin** (tenant-wide or per-class) can deprovision resources in
  their bound tenant/class.
- **Viewer** cannot deprovision (`can_provision` excludes viewer).
- **SuperAdmin** cannot deprovision by default (`global_reader` does not feed
  `can_provision`); it must be explicitly granted a tenant `owner`/`admin` role
  for break-glass deprovisioning.

The portal exposes a per-row **Deprovision** action on every resource list the
principal can `can_provision`. The action calls `POST /api/deprovision/aws`,
which re-runs the OpenFGA `can_provision` check and then issues
`DELETE /v1/compute/nodes/{id}` via `test_script/scripts/deprovision_aws.sh` (the
single source of truth for the deprovisioning sequence). An `aws-admin` can
therefore deprovision any VM in `aws_region:aws` but no VM in
`nutanix_cluster:nutanix`.

## Portal role → OpenFGA tuple mapping

The portal exposes a platform-level role per user
(`superadmin`/`owner`/`admin`/`viewer`). Roles are **per-tenant**: the tenant is
derived from the principal slug and the role tuple is written on that one tenant
only — never on both tenants. `identity_service/app/fga.py` `assign_role`
implements this.

| Portal role   | Principal example | OpenFGA tuple(s) written                                       |
|---------------|-------------------|----------------------------------------------------------------|
| superadmin    | superadmin         | `user:superadmin superadmin platform:main` (no tenant owner)  |
| owner         | aws-owner          | `user:aws-owner owner tenant:aws`                              |
| owner         | ntnx-owner         | `user:ntnx-owner owner tenant:nutanix`                         |
| admin         | aws-admin          | `user:aws-admin admin tenant:aws`                              |
| admin         | ntnx-admin         | `user:ntnx-admin admin tenant:nutanix`                         |
| viewer        | aws-viewer         | `user:aws-viewer viewer tenant:aws`                             |
| viewer        | ntnx-viewer        | `user:ntnx-viewer viewer tenant:nutanix`                        |
| (any)         | no tenant prefix   | **no tenant tuple** — denied everywhere until assigned to one |

The previous mapping wrote `owner`/`admin`/`viewer` on **both** tenants for any
portal role, which let `aws-admin` provision Nutanix. That over-grant is
forbidden by this design and is no longer produced by the code.

### Portal per-cloud capability surface

Because roles are per-tenant, the portal must render only the logged-in user's
tenant(s). `/api/session` therefore returns a `clouds[]` array — one entry per
supported cloud (`aws`, `nutanix`) with `canView` and `canProvision` flags —
computed **live from OpenFGA** (`can_read` / `can_provision` on
`aws_region:aws` and `nutanix_cluster:nutanix`) by
`identity_service/app/fga.py` `cloud_capabilities`. The Admin/Owner dashboard
filters to the clouds where the user has either flag and renders only those
controls and resource tables. Concretely:

| Principal   | `clouds[]` result                                                | Portal renders          |
|-------------|------------------------------------------------------------------|-------------------------|
| aws-admin   | `[{aws, view✓, prov✓}, {nutanix, view✗, prov✗}]`                 | AWS only                |
| ntnx-admin  | `[{aws, view✗, prov✗}, {nutanix, view✓, prov✓}]`                 | Nutanix only            |
| aws-viewer  | `[{aws, view✓, prov✗}, {nutanix, view✗, prov✗}]`                 | AWS view-only (View button + read-only table, no Deprovision) |
| ntnx-viewer | `[{aws, view✗, prov✗}, {nutanix, view✓, prov✗}]`                 | Nutanix view-only       |
| (no tenant) | `[{aws, view✗, prov✗}, {nutanix, view✗, prov✗}]`                | "no cloud access" notice |

The frontend never offers a control the backend will deny; a disabled button
is not enough — the control is simply not rendered. Viewers reach this view on
their landing page (`/viewer`); Admin/Owner reach the writable version on
`/admin` and `/owner`.

## OpenFGA relation reference

Object types and the relations this design requires (see
`openfga_postgres/openfga_bootstrap.py`):

- `platform:main` — `superadmin`, `global_reader`, `can_manage_platform`,
  `can_manage_tenant_lifecycle`, `can_manage_global_policy`, `can_manage_iam_mapping`.
- `tenant:<id>` — `owner`, `admin`, `viewer`, `member`, `platform` (→ platform:main),
  `can_assign_owner` (SuperAdmin-gated), `can_assign_admin` (owner),
  `can_assign_viewer` (owner), `can_manage_credentials` (owner),
  `can_provision` (owner∪admin), `can_update` (owner∪admin),
  `can_read` (owner∪admin∪viewer∪global_reader).
- `libcloud_api:main` — `can_connect` (tenant members ∪ global_reader).
- `provider:<cloud>` — `can_use` (tenant members ∪ global_reader).
- `resource_class:<tenant>-<class>` — `admin`, `viewer`, `tenant`, `platform`,
  `can_provision`, `can_update`, `can_read`.
- `aws_region:<binding>` / `nutanix_cluster:<binding>` — `provider`, `tenant`,
  `platform`, `resource_class`, `can_provision`, `can_update`, `can_read`.
  Read/provision/update are satisfied by the tenant-wide Owner/Admin (gated by
  the `provider.can_use` intersection for cross-cloud isolation) or by the
  bound `resource_class`'s per-class Admin/Viewer; SuperAdmin reads via
  `platform.global_reader`. There is **no** out-of-band `operator` relation and
  **no** direct `viewer` grant on backends (the only viewer path is the
  tenant-scoped `tenant_viewer` and the per-class `resource_class.can_read`).

## Scope & permission matrix

At a high level (deprovisioning = delete, gated by `can_provision`):

| Role        | Scope                 | Tenant lifecycle | Tenant membership | Resource mgmt (all classes) | Resource mgmt (subset) | Update (edit) | Deprovision | Read-only visibility |
|-------------|-----------------------|------------------|-------------------|-----------------------------|------------------------|---------------|-------------|----------------------|
| SuperAdmin  | Global (all tenants)  | Full  [youtube](https://www.youtube.com/watch?v=qS2jIS9JYM4)    | Assign Owners  [youtube](https://www.youtube.com/watch?v=qS2jIS9JYM4) | None (by default) | None (by default) | None (by default) | None (by default) | All tenants  [youtube](https://www.youtube.com/watch?v=qS2jIS9JYM4) |
| Owner       | Single tenant         | Configure only   | Full for tenant (Admin/Viewer only; Owner assignment is SuperAdmin-gated) [docs.digitalocean](https://docs.digitalocean.com/platform/organizations/roles/predefined/index.html.md) | Full  [docs.digitalocean](https://docs.digitalocean.com/platform/teams/roles/predefined/)     | Full                 | Full | Full | Full                 |
| Admin       | Single tenant / resource cls | None             | None              | Optional (if broad)        | Full for assigned classes  [digitalocean](https://www.digitalocean.com/resources/articles/rbac) | Full for assigned classes | Full for assigned classes | Full                 |
| Viewer      | Single tenant / resource cls | None             | None              | None                        | None                   | None | None | Full for assigned classes  [docs.digitalocean](https://docs.digitalocean.com/platform/teams/roles/predefined/) |

Note: an Admin/Viewer is bound to **one** tenant. `aws-admin` has no authority
over `tenant:nutanix` (no read, no provision, no update, no deprovision) —
enforced by the OpenFGA `provider.can_use` intersection and the per-tenant
role mapping above.

You can express this in a policy engine (e.g., Cedar/OpenFGA/your own) and compile to AWS IAM roles and Nutanix Prism/Calm projects, as referenced in RBAC-on-AWS multi-tenant designs. [sefcom.asu](https://sefcom.asu.edu/publications/design-implementation-access-science2013.pdf)

## Resource hierarchy examples

Using this model, here’s how AWS and Nutanix resources hang off the tenant:

- AWS tenant (AWS account)  
  - Compute: EC2, ASG, Lambda, ECS/EKS node pools.  
  - Network: VPC, subnets, SGs, NACLs, ELBs, API Gateway.  
  - Storage: EBS volumes, S3 buckets, EFS.  
  - Data: RDS, Aurora, DynamoDB, Redshift.  
  - Platform: EKS, CloudFormation/StackSets, CodePipeline.  
  - IAM: Roles, policies, instance profiles scoped to the account. [docs.aws.amazon](https://docs.aws.amazon.com/prescriptive-guidance/latest/saas-multitenant-api-access-authorization/avp-mt-abac-examples.html)

- Nutanix tenant (project in Prism Central / Calm)  
  - Compute: AHV VMs, VM templates, clones. [youtube](https://www.youtube.com/watch?v=qS2jIS9JYM4)
  - Network: networks, VLANs, IP settings.  
  - Storage: volume groups, files.  
  - Platform: Calm blueprints and apps, Kubernetes clusters on AHV/Anthos. [youtube](https://www.youtube.com/watch?v=qS2jIS9JYM4)
  - Tenant metadata: quotas on vCPU/memory/disk, project tags. [youtube](https://www.youtube.com/watch?v=qS2jIS9JYM4)

Owners can operate across all these; Admins can be narrowed to specific resource classes; Viewers observe. SuperAdmins govern how tenants, roles, and mappings to AWS IAM / Nutanix RBAC are created and enforced. [sefcom.asu](https://sefcom.asu.edu/publications/design-implementation-access-science2013.pdf)
