# OAuth2 Login Flow & SuperAdmin Approval

> **Status:** Implemented 2026-07-22. This document describes the federated
> (Google/GitHub) login flow, the pending-approval gate, and the superadmin
> role+tenant assignment workflow.

## Overview

Federated users (Google OAuth2, GitHub) who log in for the first time are placed
in a **pending** state with no role and no OpenFGA tuples. They cannot access
any cloud resources until a SuperAdmin explicitly assigns them both a **role**
and a **tenant**.

This replaces the previous behavior where new federated users were
auto-assigned the `viewer` role — which was broken because `_tenant_for_principal()`
could not derive a tenant from `int-viewer-<hex>` IDs, so zero OpenFGA tuples
were written. The user appeared to have a role but had no actual capabilities.

## End-to-End Flow

### 1. Federated Login (Google / GitHub)

```
Browser                          identity_service                  Dex
  |                                     |                            |
  | GET /api/auth/begin?provider=google |                            |
  |------------------------------------>|                            |
  |                                     | mint state + PKCE verifier |
  |   {authorizeUrl, state}             |                            |
  |<------------------------------------|                            |
  |                                     |                            |
  | redirect to Dex authorize URL ----->|---------------------------->|
  |                                     |                            |
  |                                     |                   Google OAuth2
  |                                     |                   user authenticates
  |                                     |                            |
  | <-------- Dex callback: ?code=&state=                            |
  |                                     |                            |
  | POST /api/auth/exchange {code,state}|                            |
  |------------------------------------>|                            |
  |                                     | exchange code with Dex     |
  |                                     | verify id_token (JWKS)     |
  |                                     | build external identity    |
  |                                     |                            |
  |                                     | resolve_on_login():        |
  |                                     |  - LLDAP user? → direct    |
  |                                     |  - Known subject? → return |
  |                                     |  - Email match? → collapse |
  |                                     |  - Brand new? → PENDING    |
  |                                     |                            |
  |   {role:"pending", clouds:[], ...}  |                            |
  |<------------------------------------|                            |
  |                                     |                            |
  | navigate to /pending                |                            |
```

### 2. Pending State

After a successful first login, the user:

- Gets an internal ID like `int-pending-a1b2c3d4`
- Has `role: "pending"` in their session cookie
- Has **zero** OpenFGA tuples — no `can_connect`, `can_read`, `can_provision`, `can_update`
- Lands on the **Pending Approval** page (`/pending`)
- Sees their email, internal ID, linked identities, and instructions

The Pending Approval page explains that a SuperAdmin must assign a role and
tenant before they can access anything.

### 3. SuperAdmin Assignment

```
SuperAdmin                        identity_service                 OpenFGA
  |                                     |                            |
  | GET /api/users                      |                            |
  |------------------------------------>|                            |
  |                                     | list_all():                |
  |                                     |  LLDAP users +             |
  |                                     |  _pending_users            |
  |   {users: [...pending...]}          |                            |
  |<------------------------------------|                            |
  |                                     |                            |
  | PATCH /api/users/int-pending-abc/role                            |
  |   {role:"admin", tenant:"aws"}      |                            |
  |------------------------------------>|                            |
  |                                     | set_role():                |
  |                                     |  validate tenant           |
  |                                     |  clear_roles(principal)    |
  |                                     |  assign_role(principal,    |
  |                                     |    "admin", tenant="aws")  |
  |                                     |---------------------------->|
  |                                     |  write tuple:              |
  |                                     |  user:int-pending-abc      |
  |                                     |    admin                   |
  |                                     |    tenant:aws              |
  |                                     |                            |
  |   {role:"admin", tenant:"aws"}      |                            |
  |<------------------------------------|                            |
```

The SuperAdmin:
1. Opens **Superadmin → User Management**
2. Finds the pending user (amber "pending" badge)
3. Selects a **role** (viewer / admin / owner) and a **tenant** (aws / nutanix)
4. Clicks **Save**

The backend:
1. Validates the tenant against `KNOWN_TENANTS`
2. Revokes any existing managed tuples for the principal
3. Writes the new tuple: `user:{principal} {role} tenant:{tenant}`

### 4. Re-Login After Approval

When the user logs out and back in:

1. `resolve_on_login()` finds their existing record in `_pending_users`
2. Their record now has `role: "admin"` and `tenant: "aws"`
3. The session cookie carries the new role
4. `GET /api/session` derives cloud capabilities from OpenFGA
5. `roleHome("admin")` returns `/admin`
6. The user lands on the Admin dashboard with full AWS access

## Key Data Structures

### `_pending_users` (in-memory, `identity_service/app/users.py`)

```python
_pending_users = {
    "int-pending-a1b2c3d4": {
        "internalUserId": "int-pending-a1b2c3d4",
        "email": "user@gmail.com",
        "displayName": "google user",
        "role": "pending",        # or "admin"/"viewer" after superadmin assignment
        "tenant": "aws",          # set after superadmin assigns tenant
        "linkedIdentities": ["google:108214..."],
        "createdAt": "2026-07-22T...",
    }
}
```

### OpenFGA tuples (after superadmin assignment)

```
user:int-pending-a1b2c3d4  admin   tenant:aws
```

The `can_connect` permission flows transitively:
- `user:int-pending-a1b2c3d4` → `admin` → `tenant:aws`
- `tenant:aws` → `member` (union of owner ∪ admin ∪ viewer)
- `tenant:aws` → `parent` → `libcloud_api:main`
- `libcloud_api:main.can_connect` ← `tupleToUserset(parent → member)`

## API Contract Changes

### `PATCH /api/users/{id}/role`

**Before:**
```json
{"role": "admin"}
```

**After:**
```json
{"role": "admin", "tenant": "aws"}
```

`tenant` is optional for LLDAP users (derived from slug), **required** for
pending users. Returns `400` if tenant is missing for a pending user, or if
the tenant is not in `KNOWN_TENANTS`.

### `POST /api/auth/exchange` response

New possible `role` value: `"pending"`. The frontend routes `"pending"` to
`/pending` via `roleHome()`.

## Files Changed

| File | Change |
|---|---|
| `identity_service/app/models.py` | Added `tenant: str \| None` to `RoleUpdateRequest` |
| `identity_service/app/fga.py` | `assign_role()` accepts optional `tenant` param — skips slug derivation when provided |
| `identity_service/app/users.py` | `_provision_viewer()` → `_provision_pending()`; `set_role()` validates and passes tenant for pending users; collapse "keep" path creates pending users |
| `identity_service/app/main.py` | `set_role` route passes `body.tenant` through |
| `server/src/pages/PendingApprovalPage.js` | **New.** "Account Pending Approval" page with user info and instructions |
| `server/src/App.js` | Added `/pending` route (RequireAuth, no role gate) |
| `server/src/services/auth.js` | `roleHome()` maps `"pending"` → `/pending` |
| `server/src/pages/SuperAdminDashboard.js` | Tenant `<select>` for pending users; `drafts` now track `{role, tenant}` |
| `server/src/services/api.js` | `setRole(id, role, tenant)` sends `{role, tenant?}` |
| `server/src/services/mockApi.js` | Mock exchange creates pending users; `setRole` accepts tenant |
| `server/src/styles/app.css` | Added `.role-pill.pending` (amber) style |
| `server/src/pages/IdentityCollapsePage.js` | Label: "new viewer" → "pending approval" |

## Role State Machine

```
                    ┌─────────────┐
     Google OAuth2  │             │
   ───────────────> │   pending   │  (no OpenFGA tuples, no access)
                    │             │
                    └──────┬──────┘
                           │ SuperAdmin assigns role + tenant
                           │ (PATCH /api/users/{id}/role)
                           v
                    ┌─────────────┐
                    │             │
                    │  viewer /   │  (OpenFGA tuples written,
                    │  admin /    │   can_connect + per-tenant
                    │  owner      │   capabilities active)
                    │             │
                    └─────────────┘
```

## Backward Compatibility

- **LLDAP users** (e.g. `aws-admin`, `ntnx-viewer`): Unchanged. `tenant` is
  optional in the API; `assign_role()` derives the tenant from the principal
  slug when no explicit tenant is provided.
- **Existing federated users**: Already in `_pending_users` with their
  assigned role — re-login returns the existing record.
- **Identity collapse flow**: The "keep" path now creates a pending user
  instead of an auto-viewer (which was broken anyway).



Resume this session with:
claude --resume 481d532a-541b-4189-9772-4a1bd13dc27d
CW/home/ubuntu/libcloud_nutanix>

