# How to Create / Modify an OpenFGA Authorization Model (Type + Relations)

This guide covers the OpenFGA **authorization model** (`../openfga_my`): the
type definitions and their relations that OpenFGA evaluates. It covers adding
a new protected object type, adding a new relation to an existing type, and
pushing a new model version.

> **When you need this.** Most new URLs / tenants need **no** model change —
> see [how_to_add_new_openfga_endpoint.md](how_to_add_new_openfga_endpoint.md)
> §6 and [how_to_add_new_tenant.md](how_to_add_new_tenant.md) Case A. You
> only extend the model when you introduce a **brand-new kind of protected
> object** (e.g. `billing_account:*`, `image_registry:*`, or a new cloud
> backend type `gcp_region:*`). Models are **append-only** — you push a new
> model version; you do not edit the live one in place.

---

## 0. The current model

Defined in `../openfga_my/openfga_bootstrap.py` constant `LIBCLOUD_MODEL`. The
types in use:

| Type | Purpose | Key relations |
|------|---------|---------------|
| `user` | identity (referenced, not defined as a type with relations) | — |
| `platform` | top-level platform object (`platform:main`) | `superadmin` |
| `libcloud_api` | the REST API gateway (`libcloud_api:main`) | `can_connect` (computed) |
| `tenant` | a cloud tenant (`tenant:aws`, `tenant:aws-dev`) | `owner`, `admin`, `viewer`, `parent`, `tenant`, `tenant_owner/admin/viewer`, `can_manage_credentials` |
| `provider` | a cloud provider (`provider:aws`) | `parent`, `provider`, `can_use` (computed) |
| `aws_region` | AWS backend object (`aws_region:ap-southeast-1`) | `provider`, `tenant`, `operator`, `viewer`, `tenant_admin/owner/viewer`, `can_read`, `can_provision` |
| `nutanix_cluster` | Nutanix backend object (`nutanix_cluster:lab`) | same as `aws_region` |

Computed relations are how the graph propagates: e.g.
`can_provision` on `aws_region:X` is satisfied by `tenant_admin`/`tenant_owner`
on that backend, which is satisfied by `tenant:X`'s `admin`/`owner` members.

---

## 1. Prerequisites

- `../openfga_my` is up; `generated/fga.env` has the store id.
- You can authenticate as `superadmin` — model pushes are superadmin-gated.
- You understand which existing type's relations to mirror (almost always
  `aws_region` / `nutanix_cluster`).

---

## 2. ADD a new object type (e.g. `gcp_region`)

This is the cloud-provider-backend case; it accompanies
[how_to_add_new_tenant.md](how_to_add_new_tenant.md) Case B.

### Step 1 — Extend `LIBCLOUD_MODEL` in `openfga_bootstrap.py`

Add a new type with the **same relations** as `aws_region` / `nutanix_cluster`:

```python
LIBCLOUD_MODEL = {
  ...
  "types": [
    ...
    {
      "type": "gcp_region",
      "relations": {
        "provider":      {"this": {}},
        "tenant":        {"this": {}},
        "operator":      {"this": {}},
        "viewer":        {"this": {}},
        "tenant_admin":  {"computedUsers": {"user": {"..." }}},  # mirror aws_region
        "tenant_owner":  {...},
        "tenant_viewer": {...},
        "can_read":      {"union": {"child": [...]}},   # mirror aws_region
        "can_provision": {"union": {"child": [...]}},
      },
      "metadata": {"relations": {...}},
    },
  ],
}
```

Copy the relation definitions from the existing `aws_region` entry verbatim
— the computed-relation structure is what makes owner/admin/viewer propagate
to `can_provision` / `can_read`.

### Step 2 — Seed the default tenant tuples in `INITIAL_TUPLES`

```python
INITIAL_TUPLES = [
  ...
  ("user:superadmin", "owner", "tenant:gcp"),
  ("user:gcp-owner",  "owner", "tenant:gcp"),
  ("user:gcp-admin",  "admin", "tenant:gcp"),
  ("user:gcp-viewer", "viewer","tenant:gcp"),
  ("tenant:gcp",      "parent","libcloud_api:main"),
  ("tenant:gcp",      "parent","provider:gcp"),
  ("provider:gcp",    "provider","gcp_region:gcp"),
  ("tenant:gcp",      "tenant","gcp_region:gcp"),
]
```

### Step 3 — Add validation checks in `VALIDATION_CHECKS`

```python
("gcp-owner can_provision gcp_region:gcp", True),
("gcp-admin can_provision gcp_region:gcp", True),
("gcp-viewer can_read     gcp_region:gcp", True),
("gcp-viewer can_provision gcp_region:gcp", False),
("gcp-admin can_use provider:aws", False),   # cross-cloud isolation
```

### Step 4 — Push the new model (superadmin-gated)

```bash
cd ../openfga_my
SUPERADMIN_JWT=<...> python3 openfga_bootstrap.py
```

`openfga_bootstrap.py` writes the new model (a new `authorization_model_id`
is minted), writes the seed tuples, runs `VALIDATION_CHECKS`, and updates
`generated/fga.env` with the new `FGA_MODEL_ID`.

### Step 5 — Update the libcloud.rest registry

Add `"gcp": "gcp_region"` to `PROVIDER_OBJECT_TYPES` in
`../libcloud.rest/app/connections/models.py` so `policy.py::_backend_object`
can derive `gcp_region:<binding>`. See
[how_to_create_libcloud_rest_provider_registry.md](how_to_create_libcloud_rest_provider_registry.md).

---

## 3. ADD a new relation to an existing type

Example: a `can_audit` relation on `aws_region` / `nutanix_cluster` for a new
audit-only role.

1. Add the relation definition to the type in `LIBCLOUD_MODEL` (decide whether
   it is `this`, `computedUsers`, or a `union` over existing relations).
2. Add seed tuples if needed (e.g. a new `auditor` membership on `tenant:aws`
   that propagates to `can_audit` on `aws_region:*`).
3. Add `VALIDATION_CHECKS` for allow/deny per role.
4. Branch on the new relation in `../libcloud.rest/app/auth/policy.py::_enforce_openfga`
   if a URL will gate on it (call `fga.require(user, "can_audit", backend)`).
5. Re-push the model and recreate the libcloud REST API.

---

## 4. MODIFY the model

OpenFGA models are **versioned and immutable** — "modify" means push a new
model version with the changed type definitions. `openfga_bootstrap.py` does
this on each run and records the new `FGA_MODEL_ID` in `generated/fga.env`.
Existing tuples are evaluated against the **latest** model id; you do not
need to rewrite tuples when you push a new model.

> Do not remove a type or relation that tuples still reference — OpenFGA will
> start rejecting `Check` calls for those tuples. Deprecate by removing the
> tuples first, then pushing a model without the type.

---

## 5. DELETE / deprecate

1. Remove all tuples referencing the type/relation
   (`openfga-tuple-delete.sh --confirm` for structural ones).
2. Remove the type/relation from `LIBCLOUD_MODEL` and push a new model
   version.
3. Remove the `PROVIDER_OBJECT_TYPES` entry / `PROVIDERS` entry in
   libcloud.rest if it was a backend object.
4. Update `authorization.md` and `ARCHITECTURE.md`.

---

## 6. VERIFY

```bash
# The bootstrap's own validation (25 checks) runs at the end:
SUPERADMIN_JWT=<...> python3 openfga_bootstrap.py

# Spot-check a decision against the new type:
scripts/openfga-check.sh user:gcp-admin can_provision gcp_region:gcp
scripts/openfga-check.sh user:gcp-viewer can_provision gcp_region:gcp   # False

# Tuple audit:
python3 scripts/openfga-tuple-audit.py
```

---

## 7. Files touched

| File | What changes |
|------|--------------|
| `../openfga_my/openfga_bootstrap.py` (`LIBCLOUD_MODEL`) | new type / relation |
| `../openfga_my/openfga_bootstrap.py` (`INITIAL_TUPLES`) | seed tuples for new default tenant |
| `../openfga_my/openfga_bootstrap.py` (`VALIDATION_CHECKS`) | allow/deny checks |
| `generated/fga.env` | new `FGA_MODEL_ID` after push |
| `../libcloud.rest/app/connections/models.py` | `PROVIDER_OBJECT_TYPES` entry (backend object only) |
| `../libcloud.rest/app/auth/policy.py` | branch on new relation (if a URL gates on it) |
| `authorization.md`, `ARCHITECTURE.md` | object graph + permissions matrix |

---

## 8. Quick reference

| Action | Command |
|--------|---------|
| Push new model | `SUPERADMIN_JWT=… python3 openfga_bootstrap.py` |
| Check a decision | `scripts/openfga-check.sh <u> <r> <o>` |
| Audit tuples | `python3 scripts/openfga-tuple-audit.py` |
| Related guide | [how_to_add_new_tenant.md](how_to_add_new_tenant.md) Case B |
