# How to Create / Modify / Delete an OpenFGA Relationship Tuple

This guide covers **relationship tuples** in OpenFGA (`../openfga_my`): the
`<user> <relation> <object>` triples that are the system's fine-grained
authorization facts. It covers writing, deleting, auditing, and the safety
rules around structural tuples.

> **What a tuple is here.** A tuple is one authorization fact, e.g.
> `user:aws-admin admin tenant:aws`. OpenFGA evaluates `Check(user, relation,
> object)` by walking the tuple graph plus the model's computed relations.
> The seeded store has 17 tuples; `openfga_bootstrap.py` runs 25 validation
> checks after deploy. Tuple writes/deletes are **superadmin-gated** at the
> OpenFGA API (OIDC `aud=libcloud-rest`, `iss=http://dex:5556/dex`).

---

## 0. Tuple shape and the seeded graph

A triple is `user relation object`:

- `user` — `user:<uid>` (e.g. `user:aws-admin`) or another object
  (`tenant:aws`, `provider:aws`).
- `relation` — `owner`, `admin`, `viewer`, `parent`, `provider`, `tenant`,
  `superadmin`, or a computed relation (`can_connect`, `can_use`,
  `can_provision`, `can_read`, `can_manage_credentials`).
- `object` — `tenant:<id>`, `provider:<cloud>`, `aws_region:<id>`,
  `nutanix_cluster:<id>`, `libcloud_api:main`, `platform:main`.

Simplified seeded graph (full version in `../openfga_my/ARCHITECTURE.md` §6):

```
user:superadmin --owner-->  tenant:aws, tenant:nutanix
user:aws-owner   --owner-->  tenant:aws
user:aws-admin   --admin -->  tenant:aws
user:aws-viewer  --viewer--> tenant:aws
tenant:aws       --parent--> libcloud_api:main, provider:aws
provider:aws     --provider--> aws_region:ap-southeast-1
tenant:aws       --tenant -->  aws_region:ap-southeast-1
```

The runtime-checked computed relations are:

| Relation | Object | Meaning |
|----------|--------|---------|
| `can_connect` | `libcloud_api:main` | may use libcloud REST at all |
| `can_use` | `provider:aws` / `provider:nutanix` | may target that provider |
| `can_provision` | `aws_region:…` / `nutanix_cluster:…` | may create/modify resources |
| `can_read` | same backend objects | read-only access |
| `can_manage_credentials` | `tenant:<id>` | owner-only; gates Vault writes |

---

## 1. Prerequisites

- `../openfga_my` is up; `generated/fga.env` has `FGA_STORE_ID` and
  `FGA_MODEL_ID`.
- You have a Dex-issued JWT (`LIBCLOUD_USER` / `LIBCLOUD_PASSWORD`) for a
  principal permitted to write tuples (typically `superadmin`). The scripts
  source `openfga_common.sh`, which loads `generated/fga.env`.

---

## 2. ADD tuples (write)

```bash
# One or more triples (each triple is 3 args):
scripts/openfga-tuple-write.sh \
  user:alice admin tenant:aws \
  user:bob viewer tenant:nutanix

# Dry-run (validate + print payload, no FGA call):
scripts/openfga-tuple-write.sh --dry-run user:alice admin tenant:aws

# Override the audit actor:
scripts/openfga-tuple-write.sh --actor superadmin user:alice admin tenant:aws
```

`openfga-tuple-write.sh`:
1. Validates each triple's syntax (`user:type`, relation `[a-z_]+`, `object:type`).
2. POSTs `{"authorization_model_id": $FGA_MODEL_ID, "writes": {"tuple_keys": [...]}}`
   to `/stores/${FGA_STORE_ID}/write`.
3. Idempotent — re-writing an existing tuple is a no-op (HTTP 200/204 or a
   400 "already exists" treated as success).
4. Emits one JSONL audit line per triple to `generated/openfga_audit.log`.

### 2a. The preferred path for tenant membership

For tenant owner/admin/viewer triples, prefer `lldap-group-add-member.sh`
(see [how_to_create_lldap_group.md](how_to_create_lldap_group.md)) — it
writes the LLDAP membership and triggers `openfga-tuple-reconcile.py`, which
is the source-of-truth mirror. Direct `openfga-tuple-write.sh` is for
break-glass or non-membership tuples.

### 2b. Bulk reconcile

```bash
python3 scripts/openfga-tuple-reconcile.py
```

Reads current LLDAP memberships and rewrites the OpenFGA tuple set to match
(idempotent). Run after any group change if you did not use
`lldap-group-add-member.sh`.

---

## 3. DELETE tuples

```bash
scripts/openfga-tuple-delete.sh user:alice admin tenant:aws

# Structural / infra tuples require --confirm:
scripts/openfga-tuple-delete.sh --confirm tenant:aws parent provider:aws
```

`openfga-tuple-delete.sh`:
1. Validates syntax.
2. **Refuses** to delete **protected** tuples without `--confirm`:
   - relations `parent`, `provider`, `tenant` (the structural graph);
   - any tuple on `platform:*` (e.g. `user:superadmin superadmin platform:main`).
   These break `can_connect` / `can_use` / `can_provision` propagation if
   removed.
3. POSTs `{"deletes": {"tuple_keys": [...]}}` to `/stores/${id}/write`.
4. Idempotent — deleting a non-existent tuple is success (200/204; 400 also
   accepted).
5. Audits each triple.

> Direct `user→role` tuples on `tenant:` / `platform:` are always allowed
> (they are the membership-derived set). Use the offboard chain
> (`scripts/chain-offboard-user.sh`) to remove all of a user's tuples in one
> shot.

---

## 4. MODIFY a tuple

Tuples are **immutable** — "modify" means delete the old triple and write the
new one. Example: change `alice` from `admin` to `viewer` on `tenant:aws`:

```bash
scripts/openfga-tuple-delete.sh user:alice admin tenant:aws
scripts/openfga-tuple-write.sh  user:alice viewer tenant:aws
```

If the change originates from an LLDAP group move, just use
`lldap-group-remove-member.sh` + `lldap-group-add-member.sh` and let the
reconciler sync the tuples.

---

## 5. Audit / inspect

```bash
# Who has a relation on an object (expand):
scripts/openfga-list-users.sh --object tenant:aws --relation admin

# What objects a user can access:
scripts/openfga-list-objects.sh --user user:alice --relation can_provision

# Check a single decision:
scripts/openfga-check.sh user:aws-admin can_provision aws_region:ap-southeast-1

# Structured tuple audit:
python3 scripts/openfga-tuple-audit.py

# Query denial log (OpenFGA 403s observed by libcloud REST):
scripts/openfga-denial-log-query.sh
```

---

## 6. Files touched

| File / store | What changes |
|--------------|--------------|
| OpenFGA tuple store | new / removed triples |
| `generated/openfga_audit.log` | one JSONL line per write/delete |
| `generated/openfga_denial.log` | (written by libcloud REST, not the tuple scripts) |

Tuple writes do **not** edit `openfga_bootstrap.py`'s `INITIAL_TUPLES` —
that constant only seeds a fresh store. Runtime additions live in the store.

---

## 7. Quick reference

| Action | Command |
|--------|---------|
| Write tuple(s) | `scripts/openfga-tuple-write.sh <u> <r> <o> [...]` |
| Delete tuple(s) | `scripts/openfga-tuple-delete.sh <u> <r> <o> [...]` |
| Delete structural | `scripts/openfga-tuple-delete.sh --confirm <u> <r> <o>` |
| Dry-run | append `--dry-run` |
| Reconcile from LLDAP | `python3 scripts/openfga-tuple-reconcile.py` |
| Check | `scripts/openfga-check.sh <u> <r> <o>` |
| Audit | `python3 scripts/openfga-tuple-audit.py` |
| Offboard a user's tuples | `scripts/chain-offboard-user.sh --username <uid>` |
