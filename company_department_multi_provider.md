# Company / Department management — editable lists + multi-provider departments

Implements `modification.md`:

1. **Superadmin** — the company list is now editable (rename + change admin) and
   deletable (cascade: company + its departments + members).
2. **Company admin** — department users are editable (role + move department) and
   deletable; the create-department screen uses a **provider checkbox list** so a
   department can be assigned **multiple providers** (AWS and/or Nutanix).
3. **Department user** — a user whose department is bound to several providers
   sees (and can provision on) every provider they are authorized for.

## Data model change: a department may bind to multiple providers

Previously a department (== `tenant`) was bound to exactly one cloud via a single
`tenant:<dept> parent provider:<cloud>` tuple. Now `create_department` writes one
such tuple **per provider**, plus the per-provider backend-object wiring
(`aws_region:<dept>` / `nutanix_cluster:<dept>`). The OpenFGA model already
supported this — `tenant` can parent multiple `provider:*` objects and the
backend objects intersect `(tenant admin/owner) and can_use from provider` — so no
model change was needed.

`fga._cloud_map_from` now returns `{tenant_id: [cloud, ...]}` (a list), and
`_derive_from_tuples` / `tenant_binding` / `clouds_for_tenant` / `list_companies`
were updated accordingly. A user's per-cloud capabilities aggregate their role
across **all** of a tenant's providers, so an admin on a department bound to both
AWS and Nutanix derives `canProvision` on both — which is what the portal's
`CloudDashboard` already renders from `session.clouds`.

## New / changed endpoints (identity-service)

| Method | Path | Role | Purpose |
|---|---|---|---|
| POST | `/api/companies/{id}/departments` | company_admin | now accepts `clouds: []` + `credentials: {aws, nutanix}` (multi-provider) |
| PUT | `/api/companies/{id}` | superadmin | rename company and/or change admin |
| DELETE | `/api/companies/{id}` | superadmin | delete company (cascade) |
| PUT | `/api/departments/{dept}` | company_admin | change owner and/or provider set |
| DELETE | `/api/departments/{dept}` | company_admin | delete department |
| GET | `/api/companies/{id}/members` | company_admin | list department users (user, dept, role, providers) |
| PUT | `/api/departments/{dept}/users/{uid}` | company_admin | set role / move to another department |
| DELETE | `/api/departments/{dept}/users/{uid}` | company_admin | remove the user's role from the department |

Authorization stays OpenFGA-computed: company create/update/delete are
superadmin-gated; department + member edits check `can_manage_credentials` /
`can_assign_admin` on the tenant (the company admin passes via
`can_manage_company` / `can_assign_department_admin from parent`).

## Credentials — known limitation

Each provider's backend credential is stored per-provider at
`secret/data/libcloud/<dept>-<cloud>`, and the **first** provider's credential is
also written to `secret/data/libcloud/<dept>` (the path the provisioning flow
reads, where `auth_binding == <dept>`). The company-admin credential view/rotate
still operates on the single primary secret.

**Limitation:** end-to-end *provisioning* for a multi-provider department reads
the single primary credential for every provider — per-provider credential
resolution at provision time would require re-plumbing `libcloud.rest`'s
`auth_binding` → Vault AppRole resolution (per-provider AppRoles / broader policy)
and is intentionally out of scope here. In the emulator this is moot (auth is a
no-op); for a real deployment it is the next follow-up.

## Frontend

- `services/api.js` — new `updateCompany`, `deleteCompany`, `updateDepartment`,
  `deleteDepartment`, `listMembers`, `updateDepartmentUser`, `deleteDepartmentUser`.
- `pages/SuperAdminDashboard.js` — company rows gained inline Edit (name + admin)
  and Delete.
- `pages/CompanyAdminDashboard.js` — rewritten: provider checkbox list +
  per-provider credential blocks on create; department rows editable/deletable;
  a new **Department users** table with add / edit (role + move) / remove.
- `services/mockData.js` / `services/mockApi.js` — mock company/department/member
  data + the matching CRUD methods, so the SPA is fully demonstrable in mock mode
  (a seeded `company_admin` user `int-company-admin-0007` reaches `/company`).

## Design

UI changes follow the incumbent portal system (light surface, `--accent` blue,
cards + tables) per the impeccable Operate-mode floor: added form/checkbox/credential
block styling, keyboard focus rings, themed text selection + caret, and tabular
numerals for data tables.
