# How to Create / Delete an OpenFGA Store

This guide covers the OpenFGA **store** (`../openfga_my`): the per-deployment
container that holds one authorization model + its tuples. It covers creating
a fresh store, pointing the stack at it, and deleting one.

> **What a store is here.** An OpenFGA store is an isolated tuple + model
  namespace identified by a UUID (`FGA_STORE_ID`). The seeded store is
  created by `openfga_bootstrap.py` during `setup.sh`; its id is written to
  `generated/fga.env`. The demo datastore is `--datastore-engine=memory` (or
  sqlite); a production deployment would back it with PostgreSQL. You almost
  never need a second store in a single deployment — this guide exists for
  green-field re-bootstrap and for test isolation.

---

## 0. Where the store id lives

| File | Field | Used by |
|------|-------|---------|
| `generated/fga.env` | `FGA_STORE_ID` | every `openfga_*.sh` script (via `openfga_common.sh`) |
| `generated/fga.env` | `FGA_MODEL_ID` | every tuple write/delete (must match the store's current model) |
| `../libcloud.rest` | reads `FGA_STORE_ID` from env / `.env` | the `fga_client.py` runtime checker |
| `set_tenant_credentials.py` | reads `FGA_STORE_ID` | the `can_manage_credentials` Check |

So "creating a store" means: create it in OpenFGA, write its id + a model id
into `generated/fga.env`, then restart consumers.

---

## 1. Prerequisites

- `../openfga_my` is up (`docker compose up -d openfga`).
- You can authenticate as `superadmin` (bootstrap is superadmin-gated).
- You accept that **a new store starts empty** — the seeded tuples must be
  re-written by `openfga_bootstrap.py`.

---

## 2. ADD (create) a fresh store

### Option A — full re-bootstrap (preferred)

This is what `setup.sh` runs. It creates the store (if missing), writes the
model, seeds `INITIAL_TUPLES`, and runs `VALIDATION_CHECKS`:

```bash
cd ../openfga_my
SUPERADMIN_JWT=<...> python3 openfga_bootstrap.py
```

`openfga_bootstrap.py`:
1. Creates a store if `FGA_STORE_ID` is absent in `generated/fga.env`
   (`POST /stores`), else reuses it.
2. Writes `LIBCLOUD_MODEL` → receives a new `authorization_model_id`.
3. Writes `INITIAL_TUPLES` against that model id.
4. Runs `VALIDATION_CHECKS` (25 checks).
5. Updates `generated/fga.env` with `FGA_STORE_ID` and `FGA_MODEL_ID`.

### Option B — isolated test store

To create a throwaway store without touching the deployment's
`generated/fga.env`:

```bash
curl -sS -X POST http://localhost:8080/stores \
  -H "Authorization: Bearer <superadmin-jwt>" \
  -H "Content-Type: application/json" \
  -d '{"name":"libcloud-test"}' | jq
# → { "id": "<uuid>", ... }
```

Then point a test script at it with `FGA_STORE_ID=<uuid>` and push a model
into it.

### After creating — sync consumers

```bash
# Re-sync into libcloud.rest and recreate it so the new store id is picked up:
grep -E '^(FGA_STORE_ID|FGA_MODEL_ID)=' generated/fga.env
# (setup.sh does this; manually, copy them into ../libcloud.rest/.env)
docker compose -f ../libcloud.rest/docker-compose.yml up -d --force-recreate libcloud-rest
```

---

## 3. MODIFY a store

There is no "rename" / "resize" operation that matters operationally. The
only meaningful change is **pushing a new model version** into the same
store — see
[how_to_create_openfga_authorization_model.md](how_to_create_openfga_authorization_model.md).
The store id stays the same; only `FGA_MODEL_ID` advances.

---

## 4. DELETE a store

> **Destructive.** Deleting a store removes its model **and** all tuples.
> Every `Check` will then fail open or closed (OpenFGA returns an error) and
> libcloud REST will 403 every call until a new store is set up.

```bash
# Drain the tuples first if you want an audit trail (recommended):
python3 scripts/openfga-tuple-audit.py > generated/openfga_tuples_<ts>.json

# Delete the store:
curl -sS -X DELETE http://localhost:8080/stores/${FGA_STORE_ID} \
  -H "Authorization: Bearer <superadmin-jwt>"

# Remove the stale ids from generated/fga.env (or re-run setup.sh to remint):
# delete FGA_STORE_ID and FGA_MODEL_ID lines, then:
SUPERADMIN_JWT=<...> python3 openfga_bootstrap.py
```

For a memory/sqlite datastore, restarting the `openfga` container has the
same effect as deleting the store (state is lost).

---

## 5. VERIFY

```bash
# Store is reachable and the model is loaded:
curl -sS http://localhost:8080/stores/${FGA_STORE_ID} \
  -H "Authorization: Bearer <jwt>" | jq
scripts/openfga-check.sh user:superadmin can_connect libcloud_api:main   # True

# Validation suite:
SUPERADMIN_JWT=<...> python3 openfga_bootstrap.py   # re-runs 25 checks
```

---

## 6. Files touched

| File | What changes |
|------|--------------|
| OpenFGA datastore | new / deleted store + model + tuples |
| `generated/fga.env` | `FGA_STORE_ID`, `FGA_MODEL_ID` |
| `../libcloud.rest/.env` | `FGA_STORE_ID`, `FGA_MODEL_ID` (synced) |
| `generated/openfga_audit.log` | audit lines from any tuple writes |

---

## 7. Quick reference

| Action | Command |
|--------|---------|
| Create / re-bootstrap | `SUPERADMIN_JWT=… python3 openfga_bootstrap.py` |
| Create throwaway | `POST /stores` with superadmin JWT |
| Push new model into store | see [how_to_create_openfga_authorization_model.md](how_to_create_openfga_authorization_model.md) |
| Delete store | `DELETE /stores/${FGA_STORE_ID}` with superadmin JWT |
| Recreate REST API | `docker compose -f ../libcloud.rest/docker-compose.yml up -d --force-recreate libcloud-rest` |
