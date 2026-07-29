# P1: Collapse `role_for()` + `cloud_capabilities()` fan-out

**Priority:** P1 (highest — biggest FGA traffic reduction)

**Source:** `libcloud_refactoring2.md` items (B) and (C), confirmed in
`libcloud_refactoring3.md`.

---

## Problem

Two methods in `identity_service/app/fga.py` issued multiple sequential
OpenFGA `/check` calls every time they ran, producing a fan-out of up to
**11 round-trips per session page load** and **5N round-trips per
list-users call**.

| Caller | Method | Checks per call | Trigger |
|---|---|---|---|
| `/api/session` GET | `cloud_capabilities()` | 6 (can_view + can_provision + can_update × 2 clouds) | Every page load |
| `_require_role()` | `role_for()` | up to 5 (platform + 2× owner + 2× admin) | Admin operations |
| `list_all()` | `role_for()` per user | 5N for N users | Admin user list |
| `resolve_on_login()` | `role_for()` | up to 5 | Every login |

Each `/check` is a network round-trip: POST to OpenFGA, wait, parse
response. For N=10 users in `list_all`, the system made **50 HTTP calls**
to OpenFGA.

---

## Root cause

### `role_for()` (was lines 139–152)

```python
def role_for(self, principal: str) -> str:
    if not self.enabled:
        return "viewer"
    if self.check(f"user:{principal}", "can_manage_platform", "platform:main"):  # call 1
        return "superadmin"
    for tenant in ("tenant:aws", "tenant:nutanix"):
        if self.check(f"user:{principal}", "owner", tenant):                      # calls 2, 3
            return "owner"
    for tenant in ("tenant:aws", "tenant:nutanix"):
        if self.check(f"user:{principal}", "admin", tenant):                      # calls 4, 5
            return "admin"
    return "viewer"
```

Five `/check` calls, sequential (each waits for the previous to return
before deciding whether to issue the next).

### `cloud_capabilities()` (was lines 276–288)

```python
def cloud_capabilities(self, principal: str) -> list[dict[str, Any]]:
    return [
        {
            "cloud": cloud,
            "canView": self.can_view(principal, cloud),           # /check × 2
            "canProvision": self.can_provision(principal, cloud), # /check × 2
            "canUpdate": self.can_update(principal, cloud),       # /check × 2
        }
        for cloud in self.SUPPORTED_CLOUDS
    ]
```

Six `/check` calls, each calling `self.check()` → POST to OpenFGA.

### `list_all()` in `users.py` (was lines 216–223)

```python
for u in users:
    uid = ...
    u["role"] = self.fga.role_for(uid) or DEFAULT_ROLE   # 5 /check per user
```

N users → 5N `/check` calls.

---

## Why a `/read` can replace `/check` here

OpenFGA's `/check` API evaluates computed relations (unions,
intersections, `tupleToUserset`). Its `/read` API returns only concrete
tuples — the raw `(user, relation, object)` rows that were written.

The portal's role derivation (`superadmin` / `owner` / `admin` / `viewer`)
and per-cloud capabilities (`canView` / `canProvision` / `canUpdate` at
the portal level) depend **only on concrete tenant-role tuples**:

| Concrete tuple | Portal meaning |
|---|---|
| `user:X superadmin platform:main` | SuperAdmin |
| `user:X owner tenant:aws` | Owner on AWS |
| `user:X admin tenant:aws` | Admin on AWS |
| `user:X viewer tenant:aws` | Viewer on AWS |

The OpenFGA model computes `can_manage_platform` from `superadmin`,
`can_provision` on backends from `owner ∪ admin` on tenants, etc. —
but for the **current bootstrap** (no per-class `resource_class` grants,
no direct `can_use` grants), those computed relations are 1:1 with the
concrete tuples above. A local derivation from the raw tuples is
equivalent.

**Limitation noted:** if per-class grants or direct provider-level grants
are added later, `_derive_from_tuples()` will need a corresponding update.
The `can_view()` / `can_provision()` / `can_update()` methods (still using
`/check`) are kept for the per-route enforcement path, which remains
correct regardless.

---

## Solution

### New method: `_derive_from_tuples()` (static, pure function)

Takes a list of concrete tuples for one user and returns `{role, clouds}`.
No I/O — the caller is responsible for fetching the tuples.

```python
@staticmethod
def _derive_from_tuples(tuples: list[dict[str, str]]) -> dict[str, Any]:
    tenant_roles: dict[str, str] = {}   # tenant_id -> strongest relation
    is_superadmin = False

    for t in tuples:
        rel, obj = t["relation"], t["object"]
        if rel == "superadmin" and obj == "platform:main":
            is_superadmin = True
        elif obj.startswith("tenant:") and rel in ("owner", "admin", "viewer"):
            tenant_id = obj[7:]
            current = tenant_roles.get(tenant_id)
            if current is None or (rel == "owner" or (rel == "admin" and current == "viewer")):
                tenant_roles[tenant_id] = rel

    # Derive role
    if is_superadmin:       role = "superadmin"
    elif "owner" in tenant_roles.values(): role = "owner"
    elif "admin" in tenant_roles.values(): role = "admin"
    else:                   role = "viewer"

    # Derive per-cloud capabilities
    clouds = []
    for cloud, tenant_id in [("aws", "aws"), ("nutanix", "nutanix")]:
        tr = tenant_roles.get(tenant_id)
        priv = tr in ("admin", "owner")
        clouds.append({
            "cloud": cloud,
            "canView": bool(priv or tr == "viewer" or is_superadmin),
            "canProvision": priv,
            "canUpdate": priv,
        })
    return {"role": role, "clouds": clouds}
```

### New method: `_derive_authz(principal)` — single-user wrapper

Fetches the user's tuples via `_read_user_tuples()` (which calls
`list_tuples()` and filters client-side), then delegates to
`_derive_from_tuples()`.

### New method: `batch_derive(principals)` — multi-user, single `/read`

Reads the full tuple store **once** via `list_tuples()`, indexes by user,
then calls `_derive_from_tuples()` for each requested principal. Returns
`{principal: {role, clouds}, ...}`.

### Changed: `role_for()` — now a one-liner

```python
def role_for(self, principal: str) -> str:
    return self._derive_authz(principal)["role"]
```

### Changed: `cloud_capabilities()` — now a one-liner

```python
def cloud_capabilities(self, principal: str) -> list[dict[str, Any]]:
    return self._derive_authz(principal)["clouds"]
```

### Changed: `list_all()` in `users.py` — uses `batch_derive()`

```python
def list_all(self) -> list[dict[str, Any]]:
    users = self.lldap.list_users()
    principals = [
        u["internalUserId"][4:] if u["internalUserId"].startswith("int-")
        else u["internalUserId"]
        for u in users
    ]
    derived = self.fga.batch_derive(principals)
    for u in users:
        uid = u["internalUserId"][4:] if u["internalUserId"].startswith("int-") else u["internalUserId"]
        u["role"] = derived.get(uid, {}).get("role") or DEFAULT_ROLE
    # ... merge pending users ...
```

### Unchanged

`can_view()`, `can_provision()`, `can_update()` still use single `/check`
calls. These are called individually by cloud resource routes (one check
per route), so they are not a fan-out and remain correct for any future
model changes (per-class grants, provider-level grants).

---

## Impact

| Scenario | Before | After |
|---|---|---|
| Session page load (`/api/session`) | 6 `/check` | **1 `/read`** |
| Admin operation (`_require_role`) | 5 `/check` | **1 `/read`** |
| Login (`resolve_on_login`) | 5 `/check` | **1 `/read`** |
| User list (`list_all`, N=10 users) | **50 `/check`** | **1 `/read`** |

### Session page load (worst case, both methods called)

**Before:** `role_for` (5) + `cloud_capabilities` (6) = **11 round-trips**

**After:** `role_for` is not called on the session path (role comes from
the cookie). Only `cloud_capabilities` runs → **1 round-trip**.

### Data transfer trade-off

`/check` is a lightweight call with a specific tuple key; `/read` returns
the full tuple store. For the current store size (~30 tuples), the `/read`
response is still small. The elimination of N sequential round-trips
dominates any increase in per-response payload size.

---

## Files changed

| File | Change |
|---|---|
| `identity_service/app/fga.py` | Added `_derive_from_tuples()`, `_derive_authz()`, `batch_derive()`; simplified `role_for()` and `cloud_capabilities()` |
| `identity_service/app/users.py` | `list_all()` now collects all principals and calls `batch_derive()` instead of N individual `role_for()` calls |

---

## Verification

Manual trace-through of the derivation logic for each principal type:

| Principal | Tuples in store | Derived role | AWS view/provision/update | Nutanix view/provision/update |
|---|---|---|---|---|
| `superadmin` | `superadmin` on `platform:main` | superadmin | true / false / false | true / false / false |
| `aws-owner` | `owner` on `tenant:aws` | owner | true / true / true | false / false / false |
| `aws-admin` | `admin` on `tenant:aws` | admin | true / true / true | false / false / false |
| `aws-viewer` | `viewer` on `tenant:aws` | viewer | true / false / false | false / false / false |
| `ntnx-owner` | `owner` on `tenant:nutanix` | owner | false / false / false | true / true / true |
| (no tuples) | — | viewer | false / false / false | false / false / false |

All match the previous `/check`-based behaviour for the running store.

Resume this session with:
claude --resume dbcc650f-bf04-400f-90fb-d604557eb27d
