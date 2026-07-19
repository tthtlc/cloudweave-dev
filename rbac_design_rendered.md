
  Here's a summary of every relationship in rbac_design.md, in the DigitalOcean table style (roles × capability categories, color‑coded) plus ASCII line
  drawings of the OpenFGA object graph.

  Legend — 🟢 Full access · 🟡 Partial / Read‑only / Conditional · 🔴 No access (by default)

  1. Role × Capability matrix (DO‑style)

  ┌───────┬──────────────────────────┬────────────────────────────────────┬─────────────────┬─────────────────┬─────────────────┬──────────────────────────┐
  │ Role  │ Tenant lifecycle         │ Tenant membership                  │ Global policy & │ Provision       │ Deprovision     │ Read resources           │
  │       │                          │                                    │ IAM mapping     │ (create/update) │ (delete)        │                          │
  ├───────┼──────────────────────────┼────────────────────────────────────┼─────────────────┼─────────────────┼─────────────────┼──────────────────────────┤
  │ Super │ 🟢 Full — create /       │ 🟡 Assign Owners only              │ 🟢 Full         │ 🔴 None (by     │ 🔴 None (by     │ 🟡 All tenants —         │
  │ Admin │ onboard / decommission   │ (SuperAdmin‑gated)                 │                 │ default)        │ default)        │ read‑only                │
  │       │                          │                                    │                 │                 │                 │ (global_reader)          │
  ├───────┼──────────────────────────┼────────────────────────────────────┼─────────────────┼─────────────────┼─────────────────┼──────────────────────────┤
  │ Owner │ 🟡 Configure only — no   │ 🟡 Admin/Viewer only (Owner        │ 🔴 None         │ 🟢 Full — all   │ 🟢 Full         │ 🟢 Full                  │
  │       │ create/delete            │ assignment = SuperAdmin)           │                 │ classes         │                 │                          │
  ├───────┼──────────────────────────┼────────────────────────────────────┼─────────────────┼─────────────────┼─────────────────┼──────────────────────────┤
  │ Admin │ 🔴 None                  │ 🔴 None                            │ 🔴 None         │ 🟢 Full —       │ 🟢 Full —       │ 🟢 Full (own tenant)     │
  │       │                          │                                    │                 │ assigned        │ assigned        │                          │
  │       │                          │                                    │                 │ classes         │ classes         │                          │
  ├───────┼──────────────────────────┼────────────────────────────────────┼─────────────────┼─────────────────┼─────────────────┼──────────────────────────┤
  │ Viewe │ 🔴 None                  │ 🔴 None                            │ 🔴 None         │ 🔴 None         │ 🔴 None         │ 🟡 Read‑only — assigned  │
  │ r     │                          │                                    │                 │                 │                 │ classes                  │
  └───────┴──────────────────────────┴────────────────────────────────────┴─────────────────┴─────────────────┴─────────────────┴──────────────────────────┘

  │ Per‑tenant binding: Owner / Admin / Viewer are bound to one tenant (derived from the principal slug). SuperAdmin is global. Break‑glass: SuperAdmin 
    explicitly granted a tenant owner/admin role gains provision + deprovision there.

  2. Per‑tenant scoping (who can touch which tenant)

  ┌───────────────────────────────────────┬──────────────────────────────────┬──────────────────────────────────┐
  │ Principal                             │ tenant:aws                       │ tenant:nutanix                   │
  ├───────────────────────────────────────┼──────────────────────────────────┼──────────────────────────────────┤
  │ superadmin                            │ 🟡 read‑only, no provision       │ 🟡 read‑only, no provision       │
  ├───────────────────────────────────────┼──────────────────────────────────┼──────────────────────────────────┤
  │ aws-owner / aws-admin / aws-viewer    │ 🟢 Full / 🟢 Full / 🟡 Read‑only │ 🔴 None                          │
  ├───────────────────────────────────────┼──────────────────────────────────┼──────────────────────────────────┤
  │ ntnx-owner / ntnx-admin / ntnx-viewer │ 🔴 None                          │ 🟢 Full / 🟢 Full / 🟡 Read‑only │
  ├───────────────────────────────────────┼──────────────────────────────────┼──────────────────────────────────┤
  │ (no tenant prefix)                    │ 🔴 None — denied everywhere      │ 🔴 None                          │
  └───────────────────────────────────────┴──────────────────────────────────┴──────────────────────────────────┘

  3. Portal role → OpenFGA tuple mapping

  ┌─────────────┬──────────────────────────┬────────────────────────────────────────────────────────────┐
  │ Portal role │ Principal example        │ Tuple(s) written                                           │
  ├─────────────┼──────────────────────────┼────────────────────────────────────────────────────────────┤
  │ superadmin  │ superadmin               │ user:superadmin superadmin platform:main (no tenant owner) │
  ├─────────────┼──────────────────────────┼────────────────────────────────────────────────────────────┤
  │ owner       │ aws-owner / ntnx-owner   │ user:<p> owner tenant:<aws|nutanix>                        │
  ├─────────────┼──────────────────────────┼────────────────────────────────────────────────────────────┤
  │ admin       │ aws-admin / ntnx-admin   │ user:<p> admin tenant:<...>                                │
  ├─────────────┼──────────────────────────┼────────────────────────────────────────────────────────────┤
  │ viewer      │ aws-viewer / ntnx-viewer │ user:<p> viewer tenant:<...>                               │
  ├─────────────┼──────────────────────────┼────────────────────────────────────────────────────────────┤
  │ (any)       │ no tenant prefix         │ no tenant tuple — denied until assigned                    │
  └─────────────┴──────────────────────────┴────────────────────────────────────────────────────────────┘

  4. OpenFGA object relation reference

  ┌─────────────────┬──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ Object type     │ Relations (and who feeds them)                                                                                                       │
  ├─────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ platform:main   │ superadmin (user) → computes global_reader, can_manage_platform, can_manage_tenant_lifecycle, can_manage_global_policy,              │
  │                 │ can_manage_iam_mapping                                                                                                               │
  ├─────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ tenant:<id>     │ owner, admin, viewer, member, platform(→platform:main); can_assign_owner(→platform.can_manage_platform = SuperAdmin);                │
  │                 │ can_assign_admin(owner); can_assign_viewer(owner); can_manage_credentials(owner); can_provision(owner∪admin);                        │
  │                 │ can_read(owner∪admin∪viewer∪global_reader)                                                                                           │
  ├─────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ libcloud_api:ma │ can_connect (tenant members ∪ global_reader)                                                                                         │
  │ in              │                                                                                                                                      │
  ├─────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ provider:<cloud │ can_use (tenant members ∪ allowed ∪ global_reader)                                                                                   │
  │ >               │                                                                                                                                      │
  ├─────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ resource_class: │ admin, viewer, tenant, platform; can_provision(admin∪tenant_admin∪tenant_owner);                                                     │
  │ <tenant>-<class │ can_read(viewer∪tenant_viewer∪admin∪tenant_admin∪tenant_owner∪global_reader)                                                         │
  │ >               │                                                                                                                                      │
  ├─────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ aws_region: /   │ provider, tenant, platform, resource_class, operator, viewer; can_provision = operator ∪ tenant.can_provision ∪                      │
  │ nutanix_cluster │ resource_class.can_provision; can_read = viewer ∪ tenant.can_read ∪ resource_class.can_read ∪ platform.global_reader                 │
  │ :               │                                                                                                                                      │
  └─────────────────┴──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

  5. Line drawings

  5a. SuperAdmin → global read‑only (no provision)

                        platform:main
                              │  superadmin  ◄── user:superadmin
                              │
     ┌────────────────────────┼─────────────────────────────────┐
     ▼                        ▼                                 ▼
   can_manage_platform    global_reader              can_manage_tenant_lifecycle
   can_manage_global_policy   │                     can_manage_iam_mapping
                              │
            ┌─────────────────┼──────────────────────┐
            ▼                 ▼                      ▼
     libcloud_api         provider:<cloud>      aws_region / nutanix_cluster
     .can_connect         .can_use             .can_read   ◄── read-only
                                                  ✗ can_provision  (NOT granted)

  5b. Tenant tree (per‑tenant role binding)

                           platform:main
                                │ platform (parent)
              ┌─────────────────┴──────────────────┐
              ▼                                    ▼
         tenant:aws                            tenant:nutanix
         ├── owner   ◄ user:aws-owner            ├── owner   ◄ user:ntnx-owner
         ├── admin   ◄ user:aws-admin            ├── admin   ◄ user:ntnx-admin
         ├── viewer  ◄ user:aws-viewer           ├── viewer  ◄ user:ntnx-viewer
         ├── can_assign_admin  (owner)            ├── can_assign_admin  (owner)
         ├── can_assign_viewer (owner)            ├── can_assign_viewer (owner)
         ├── can_assign_owner  ──► platform.can_manage_platform  (SuperAdmin only)
         ├── can_provision    = owner ∪ admin
         └── can_read          = owner ∪ admin ∪ viewer ∪ ◄─ platform.global_reader
              │ tenant
              ▼
         aws_region:aws                       nutanix_cluster:nutanix

  5c. Resource‑class narrowing (Admin/Viewer scoped to one class)

     resource_class:aws-compute
     ├── admin   ◄ user (per-class admin)
     ├── viewer  ◄ user (per-class viewer)
     ├── tenant  ──► tenant:### 5c. Resource‑class narrowing (Admin/Viewer scoped to one class)

     resource_class:aws-compute
     ├── admin   ◄ user (per-class admin)
     ├── viewer  ◄ user (per-class viewer)
     ├── tenant  ──► tenant:aws
     └── platform ─► platform:main
          │ resource_class
          ▼
     aws_region:aws
          can_provision = operator ∪ tenant.can_provision ∪ resource_class.can_provision
          can_read       = viewer ∪ tenant.can_read ∪ resource_class.can_read
                           ∪ ◄─ platform.global_reader

  A per‑class admin on `tenant:aws` **cannot** reach `tenant:nutanix`'s backends — the `resource_class` is bound to its own tenant, and the backend to its
  own resource classes.
  ### 5d. Portal session → per‑cloud capability surface

     login (Dex OIDC) ──► /api/session
                              │
                              ▼
          clouds[] = fga.cloud_capabilities(principal)   ← live OpenFGA checks
                              │
          ┌───────────────────┴─────────────────────┐
          ▼                                           ▼
     canView  (can_read)                       canProvision (can_provision)
          │                                           │
          ▼                                           ▼
     "View <Cloud> Resources"                 "Provision <Cloud>" + "Deprovision"
     (owner / admin / viewer)                  (owner / admin only)
          │                                           │
          └──────── AWS only (aws-*) ─────────────────┘
                       Nutanix only (ntnx-*)
                       no controls (no tenant)  →  "no cloud access" notice

  The frontend never offers a control the backend will deny — a non‑matching cloud is **not rendered** (not merely disabled).
  ## 6. Deprovisioning rule (one‑liner)
  `delete` is gated by the **same** relation as `create` — `can_provision` on the backend object:

     Owner  ─┐
     Admin  ─┼── can_provision ──► Deprovision ✓  (own tenant / assigned class)
     Viewer ─┤── ✗ can_provision ─► Deprovision ✗
     SuperAdmin ─┤── ✗ by default (global_reader ≠ can_provision)
                   └── break-glass: grant tenant owner/admin ──► ✓

  That covers all relationships in `rbac_design.md`: the four roles, their per‑tenant scoping, the SuperAdmin global‑read‑only model, resource‑class
  narrowing, deprovisioning parity with provisioning, the portal tuple mapping, and the live `clouds[]` capability surface.
