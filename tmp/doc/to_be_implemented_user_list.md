# Listing Users in OpenFGA — Analysis & Implementation Plan

## The problem

OpenFGA has **no user directory**. Users are just strings referenced on the left
side of relationship tuples (`user:aws-admin`, `user:superadmin`, …). There is no
`/users` CRUD endpoint, no user registry, and no direct way to ask "give me all
distinct user subjects in this store."

The portal's user-management screen (`SuperAdminDashboard`) needs to show every
internal user with their derived role and per-cloud capabilities. Today this
works by brute-force reading **every tuple** in the store and filtering
client-side.

---

## Current approach (what the code does today)

### Step 1 — `FgaService.list_tuples()` (`identity_service/app/fga.py:338-353`)

Reads the entire tuple store via `POST /stores/{store_id}/read`, paginating:

```python
def list_tuples(self) -> list[dict[str, str]]:
    out = []
    token = ""
    while True:
        body = self._post("/read", {"page_size": 100, "continuation_token": token})
        for t in body.get("tuples", []):
            k = t.get("key", {})
            out.append({"user": k.get("user", ""), "relation": k.get("relation", ""),
                         "object": k.get("object", "")})
        token = body.get("continuation_token") or ""
        if not token:
            break
    return out
```

This returns **every tuple** — including structural/infrastructure tuples
(`tenant:aws parent libcloud_api:main`, `provider:aws provider aws_region:aws`,
`platform:main platform tenant:aws`, …). For a store with ~50 tuples (the current
seed), this is fine. It does not scale linearly with users; it scales with total
tuples, which includes every resource-class binding and infrastructure edge.

### Step 2 — `FgaService._derive_from_tuples()` (`fga.py:141-216`)

A pure function that walks a list of tuples for **one user** and derives:

- **role** — strongest across all tenants: `superadmin > owner > admin > viewer`
- **clouds** — per-cloud `canView` / `canProvision` / `canUpdate` booleans

### Step 3 — `UserService.list_all()` (`identity_service/app/users.py:222-243`)

1. Calls `lldap.list_users()` to get the real user directory (LLDAP users)
2. Calls `fga.batch_derive(principals)` — reads **all tuples once**, indexes by
   `user:` prefix, derives role+clouds for each principal
3. Merges in `_pending_users` (federated/OAuth users not yet in LLDAP, stored
   **in-memory only** — lost on service restart)

---

## The two sources of user identity

| Source | What it holds | Persistent? |
|---|---|---|
| **LLDAP** (`lldap_data` volume) | Real user accounts: uid, email, password, displayName, custom attrs | Yes |
| **`_pending_users` dict** (`users.py:46`) | Federated (OAuth2) users not yet in LLDAP: internalUserId, email, linkedIdentities | **No** — lost on restart |

OpenFGA tuples only tell you **what roles a user has** — not that the user
exists. A user with zero tuples is invisible to OpenFGA but still exists in
LLDAP (and would be derived as `"viewer"` by the fallback in `_derive_authz`).

---

## OpenFGA's native `list-users` endpoint

### What it is

```
POST /stores/{store_id}/list-users
```

Defined in the [OpenFGA API spec](https://raw.githubusercontent.com/openfga/api/main/docs/openapiv2/apidocs.swagger.json),
operationId `ListUsers`.

### What it does

Returns all users **of a specific type** that have **a given relation to a given
object**. It is a reverse-membership lookup:

```
Request:  { "object": {"type": "tenant", "id": "aws"}, "relation": "admin",
            "user_filters": [{"type": "user"}] }
Response: { "users": [{"object": {"type": "user", "id": "aws-admin"}},
                      {"object": {"type": "user", "id": "superadmin"}}] }
```

### What it CANNOT do

- **Cannot return all distinct users store-wide** — requires `object` + `relation`
- **Cannot return users with no tuples** — only sees users that appear in at
  least one matching relationship
- **Cannot return structural subjects** — `user_filters: [{"type": "user"}]`
  excludes usersets like `tenant:aws`, `provider:nutanix`, `resource_class:*`

### Key parameters

| Parameter | Required | Description |
|---|---|---|
| `authorization_model_id` | No | Defaults to latest model |
| `object` | **Yes** | `{"type": "...", "id": "..."}` — the target object |
| `relation` | **Yes** | The relation to query |
| `user_filters` | **Yes** | At least one type filter, typically `[{"type": "user"}]` |
| `contextual_tuples` | No | Additional tuples for context-aware evaluation |
| `context` | No | Context object for evaluating conditions |

Results are bounded by `OPENFGA_LIST_USERS_DEADLINE` and
`OPENFGA_LIST_USERS_MAX_RESULTS` server-side.

---

## Proposed approach: replace brute-force `/read` with targeted `list-users` calls

### Why

- **Semantically correct** — asks "who has a role on this tenant?" rather than
  "give me everything and I'll filter it myself"
- **Scales with users, not tuples** — each `list-users` call returns only the
  matching user subjects, not every infrastructure edge
- **No client-side filtering** — the server does the work
- **Still requires multiple calls** — one per (object, relation) pair, but the
  number of such pairs is bounded by the model, not by data growth

### The role-bearing relations

The current model has these relations that carry role assignments on
user-bearing objects:

| Object | Relations | Description |
|---|---|---|
| `tenant:aws` | `owner`, `admin`, `viewer` | AWS tenant role members |
| `tenant:nutanix` | `owner`, `admin`, `viewer` | Nutanix tenant role members |
| `platform:main` | `superadmin` | Platform superadmin |
| `resource_class:aws-compute` | `admin`, `viewer` | Per-class admin/viewer (AWS) |
| `resource_class:aws-network` | `admin`, `viewer` | Per-class admin/viewer (AWS) |
| `resource_class:aws-data` | `admin`, `viewer` | Per-class admin/viewer (AWS) |
| `resource_class:aws-platform` | `admin`, `viewer` | Per-class admin/viewer (AWS) |
| `resource_class:nutanix-compute` | `admin`, `viewer` | Per-class admin/viewer (NTNX) |
| `resource_class:nutanix-network` | `admin`, `viewer` | Per-class admin/viewer (NTNX) |
| `resource_class:nutanix-data` | `admin`, `viewer` | Per-class admin/viewer (NTNX) |
| `resource_class:nutanix-platform` | `admin`, `viewer` | Per-class admin/viewer (NTNX) |

That's **21 calls** in the worst case (7 tenant/platform queries + 14
resource_class queries). In practice, queries can be parallelized.

### Implementation sketch

```python
# identity_service/app/fga.py — new method on FgaService

# The (object, relation) pairs that carry user role assignments.
# Keep in sync with openfga_bootstrap.py INITIAL_TUPLES and the model's
# type_definitions.
_ROLE_QUERIES: list[tuple[str, str]] = [
    # Tenant roles
    ("tenant:aws", "owner"),
    ("tenant:aws", "admin"),
    ("tenant:aws", "viewer"),
    ("tenant:nutanix", "owner"),
    ("tenant:nutanix", "admin"),
    ("tenant:nutanix", "viewer"),
    # Platform superadmin
    ("platform:main", "superadmin"),
    # Per-class roles on resource_class objects
    ("resource_class:aws-compute", "admin"),
    ("resource_class:aws-compute", "viewer"),
    ("resource_class:aws-network", "admin"),
    ("resource_class:aws-network", "viewer"),
    ("resource_class:aws-data", "admin"),
    ("resource_class:aws-data", "viewer"),
    ("resource_class:aws-platform", "admin"),
    ("resource_class:aws-platform", "viewer"),
    ("resource_class:nutanix-compute", "admin"),
    ("resource_class:nutanix-compute", "viewer"),
    ("resource_class:nutanix-network", "admin"),
    ("resource_class:nutanix-network", "viewer"),
    ("resource_class:nutanix-data", "admin"),
    ("resource_class:nutanix-data", "viewer"),
    ("resource_class:nutanix-platform", "admin"),
    ("resource_class:nutanix-platform", "viewer"),
]

def list_users(self) -> dict[str, list[dict[str, str]]]:
    """Return every user subject that holds at least one role, keyed by
    ``user:<id>``, with the list of (object, relation) assignments.

    Uses OpenFGA's native ``/list-users`` endpoint — one call per
    (object, relation) pair — instead of brute-force ``/read`` + client-side
    filter.  The number of calls is bounded by the model, not by data growth.
    """
    if not self.enabled:
        return {}

    seen: dict[str, list[dict[str, str]]] = {}
    for obj, rel in _ROLE_QUERIES:
        obj_type, obj_id = obj.split(":", 1)
        body = self._post("/list-users", {
            "authorization_model_id": self.model_id,
            "object": {"type": obj_type, "id": obj_id},
            "relation": rel,
            "user_filters": [{"type": "user"}],
        })
        for entry in body.get("users", []):
            # The response User object wraps the subject inside `object`
            # for concrete users: {"object": {"type": "user", "id": "aws-admin"}}
            uid = (entry.get("object", {}) or {}).get("id", "")
            if not uid:
                continue
            full_user = f"user:{uid}"
            seen.setdefault(full_user, []).append({
                "relation": rel,
                "object": obj,
            })

    return seen
```

### What changes in the callers

`batch_derive()` (`fga.py:218-253`) currently reads all tuples via
`list_tuples()`, indexes by `user:`, and derives.  With `list_users()`, the
input shape is different — each user already has only their role assignments,
not the full tuple set.  `_derive_from_tuples()` can be adapted to accept this
narrower input, or a new derivation path can be written that takes the
`list_users()` output directly (simpler, since the structural tuples are already
filtered out).

### What does NOT change

- **LLDAP remains the user directory** — `UserService.list_all()` still starts
  from `lldap.list_users()` and enriches with derived roles
- **`_pending_users`** still needs a persistence solution (the in-memory dict
  loses federated users on restart)
- **`_disabled_principals`** still needs a persistence solution (disabled users
  would otherwise fall back to `"viewer"` after restart)

---

## Edge cases & limitations

### Users with no role tuples

A user in LLDAP with zero OpenFGA tuples (e.g., `cloud-denied`) has no role.
`list_users()` won't return them.  The caller must still fall back to
`DEFAULT_ROLE` (`"viewer"`) for LLDAP users absent from the result.

### Disabled users

A disabled user has no tuples (they were deleted by `clear_roles()`).
`list_users()` won't return them.  The `_disabled_principals` set in
`users.py:55` preserves the `"disabled"` marker — but it is in-memory.
A persistent disabled-registry (LLDAP custom attribute, or a dedicated table)
is needed.

### Per-class admins with no tenant membership

`aws-compute-admin` has `admin` on `resource_class:aws-compute` but NO role on
`tenant:aws`.  `list_users()` with the queries above WILL find them (the
resource_class queries cover this).  But the current `_derive_from_tuples()`
and `batch_derive()` derive `can_connect` / `can_use` from tenant role tuples —
a per-class admin has neither, so the portal would show them with
`can_connect: false`, which is correct (per-class admins are OpenFGA-only
principals with no LLDAP account and no API access).

---

## Non-goals

- **Replacing LLDAP as the user directory.** LLDAP remains the source of truth
  for user identity (who exists). OpenFGA only answers "what can they do?"
- **Eliminating `/read` entirely.** The raw-tuple screen (`OpenFgaTuplesPage`)
  and `clear_roles()` still need full tuple visibility.  `list_tuples()` stays
  for those paths.
- **Auto-discovering new tenants.** `_ROLE_QUERIES` must be kept in sync with
  `TENANT_BY_SLUG` and the model.  Adding a tenant means adding three queries.

---

## Related files

| File | What it does |
|---|---|
| `identity_service/app/fga.py` | `FgaService` — OpenFGA client; `list_tuples()`, `batch_derive()`, `_derive_from_tuples()` |
| `identity_service/app/users.py` | `UserService` — `list_all()`, `set_role()`, `_pending_users`, `_disabled_principals` |
| `identity_service/app/main.py` | FastAPI routes — `GET /api/users`, `PATCH /api/users/:id/role` |
| `openfga_postgres/openfga_bootstrap.py` | `INITIAL_TUPLES`, `LIBCLOUD_MODEL`, `VALIDATION_CHECKS` — seed data |
| `server/src/pages/SuperAdminDashboard.js` | Frontend — role dropdown, save, disable |
| `server/src/pages/OpenFgaTuplesPage.js` | Frontend — raw tuple CRUD |



Resume this session with:
claude --resume b6658218-920b-4a88-8487-a43267000a63

