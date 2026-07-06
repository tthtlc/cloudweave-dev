# How to Create / Modify / Delete a libcloud REST Endpoint (URL + Scope)

This guide is the canonical procedure for adding / changing / removing a
**REST URL** in `../libcloud.rest` and having it authorized by user role
(`superadmin` / `owner` / `admin` / `viewer`). It is the dedicated companion
to the existing `[how_to_add_new_openfga_endpoint.md](how_to_add_new_openfga_endpoint.md)`,
which is the long-form reference with worked examples. This page is the
terse checklist version plus the delete/modify cases the older doc does not
cover.

> **Read the older doc first.** `how_to_add_new_openfga_endpoint.md` §0–§6
> explain the four authorization layers and the decision tables. This guide
> assumes you have read it.

---

## 0. The chain (recap)

```
role (owner/admin/viewer) → JWT scopes (identity.py) → OpenFGA relation (policy.py) → URL (routes.py)
```

When you add a URL you (a) pick or reuse a **scope**, (b) declare it on the
route via `require_scopes(...)` / `require_any_scopes(...)`, (c) make sure
each role that should reach the URL is granted that scope in `identity.py`,
and (d) call `policy_engine.authorize_connection(...)` on provider URLs so
OpenFGA's `can_use` / `can_provision` / `can_read` run.

---

## 1. ADD a URL — checklist

1. **Decide scope** (see `how_to_add_new_openfga_endpoint.md` §1):
   - read → `<resource>:read`; write → `<resource>:manage` / `:create` / `:delete`.
   - Reuse an existing scope if possible → zero role-table edits.

2. **Add the route** in `app/<domain>/routes.py` (compute / network /
   connections / providers / jobs / auth). Two mandatory pieces on a
   provider URL:
   - `Depends(require_scopes("<scope>"))` or `require_any_scopes(...)`
   - `policy_engine.authorize_connection(claims, connection, "<scope>")`

   If the router file is **new**, register it in `app/main.py`:
   `app.include_router(<domain>_router)`.

3. **If you introduced a NEW scope name**, register it:
   - `app/connections/models.py` → `ALL_SCOPES`
   - `app/auth/policy.py` → `WRITE_SCOPES` (for write) **or**
     `READ_SCOPE_ALIASES` (for read)
   - `app/auth/identity.py` → `PROVISIONER_SCOPES` (owner/admin) and/or
     `READER_SCOPES` (viewer)

4. **If the URL acts on a NEW kind of object** (not `aws_region` /
   `nutanix_cluster` / `tenant` / `provider` / `libcloud_api` / `platform`),
   extend the OpenFGA model — see
   [how_to_create_openfga_authorization_model.md](how_to_create_openfga_authorization_model.md).

5. **Validate**:
   ```bash
   python3 -m py_compile ../libcloud.rest/app/<domain>/routes.py
   python3 -c "import app.main"   # from ../libcloud.rest
   docker compose -f ../libcloud.rest/docker-compose.yml up -d --force-recreate libcloud-rest
   ./system_validate.sh
   ```

Full worked examples (a `GET .../audit` read URL and a `POST ...:lock` write
URL) are in `how_to_add_new_openfga_endpoint.md` §9.

---

## 2. MODIFY a URL

| Change | Where |
|--------|-------|
| Change which roles may call it (scope grant) | `app/auth/identity.py` `PROVISIONER_SCOPES` / `READER_SCOPES` |
| Change read↔write classification | move the scope between `WRITE_SCOPES` and `READ_SCOPE_ALIASES` in `app/auth/policy.py`; update the route's `require_scopes(...)` |
| Change the OpenFGA relation a write/read maps to | branch in `policy.py::_enforce_openfga` (only if you introduced a new relation) |
| Change the path / method | the `@router.get/post/...` decorator in `routes.py` |
| Add provider-backend enforcement to a previously non-provider URL | add `authorize_connection(...)` + a `connection` dependency |

Recreate the REST API after editing.

---

## 3. DELETE a URL

1. Remove the route handler from `app/<domain>/routes.py`.
2. If the scope was used **only** by that URL, remove it from
   `ALL_SCOPES`, `WRITE_SCOPES` / `READ_SCOPE_ALIASES`, and
   `PROVISIONER_SCOPES` / `READER_SCOPES` (grep first to confirm it is
   unused).
3. If the router file becomes empty, remove its `include_router` line in
   `app/main.py` (and the file).
4. If the URL was the only consumer of a new OpenFGA object type / relation,
   deprecate that too — see
   [how_to_create_openfga_authorization_model.md](how_to_create_openfga_authorization_model.md) §5.
5. Recreate the REST API and run `./system_validate.sh`.

---

## 4. Files touched (per case)

| Case | `routes.py` | `models.py` (`ALL_SCOPES`) | `policy.py` | `identity.py` | `openfga_bootstrap.py` | `main.py` |
|------|-------------|----------------------------|-------------|---------------|------------------------|-----------|
| Reuse scope + existing object | ✓ | — | — | — | — | (new router only) |
| New scope, existing object | ✓ | ✓ | ✓ | ✓ | — | (new router only) |
| New object / relation | ✓ | ✓ | ✓ (if new relation) | ✓ | ✓ | (new router only) |
| New cloud provider backend object | see [how_to_add_new_tenant.md](how_to_add_new_tenant.md) Case B | | | | | |

---

## 5. Quick reference

| Action | Command |
|--------|---------|
| Syntax check | `python3 -m py_compile ../libcloud.rest/app/<domain>/routes.py` |
| Import check | `python3 -c "import app.main"` (from `../libcloud.rest`) |
| Recreate REST API | `docker compose -f ../libcloud.rest/docker-compose.yml up -d --force-recreate libcloud-rest` |
| Full validation | `./system_validate.sh` |
| Long-form guide | [how_to_add_new_openfga_endpoint.md](how_to_add_new_openfga_endpoint.md) |
