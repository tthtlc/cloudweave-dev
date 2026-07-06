# How to Create / Modify / Delete an LLDAP Group (and Membership)

This guide covers **groups** in the LLDAP directory (`../lldap`): the role
naming convention, how to create a group, add / remove a member, list
memberships, and delete a group. It also explains how an LLDAP group becomes
OpenFGA tuples and Vault policy bindings.

> **What a group is here.** An LLDAP group is a role container under
> `ou=groups,dc=libcloud,dc=local`. Groups are keyed by an integer `id`; the
> human name is `displayName`. Membership in a group is what gives a user a
> **role** — e.g. membership in `cloud-admin-aws` makes someone an AWS cloud
> admin. Group membership is **the** source of truth for role grants; it is
> mirrored into OpenFGA tuples by the reconciler and into Vault policy
> bindings by `vault-ldap-group-bind.sh`.

---

## 0. Naming convention

Groups follow `<scope>-<role>-<provider-or-suffix>`, e.g.

- `cloud-admin-aws`
- `cloud-ro-gcp`
- `cloud-owner-nutanix`

`lldap-group-create.sh` enforces at least one dash unless `--force` is passed.
Charset: lowercase `[a-z0-9][a-z0-9._-]{0,62}`.

---

## 1. Prerequisites

- `../lldap` is up and the schema is applied.
- `LLDAP_LDAP_USER_PASS` is available (from `../lldap/.env` or
  `generated/dex.env`).
- For the downstream effects (OpenFGA tuples, Vault bindings) those sibling
  services are up.

---

## 2. ADD a group

```bash
scripts/lldap-group-create.sh --name cloud-admin-aws [--force] [--dry-run]
```

The script:
1. Logs in as `admin` → admin JWT.
2. Checks idempotency — if a group with that `displayName` already exists, it
   exits 0 (no-op).
3. Calls GraphQL `createGroup(name: "...")` → returns the integer group `id`.
4. Audits to `generated/lldap_audit.log`.

`--force` overrides the naming-convention check. `--dry-run` validates without
calling LLDAP.

---

## 3. ADD / REMOVE a member (grant / revoke a role)

### 3.1 Add a member

```bash
scripts/lldap-group-add-member.sh --user <uid> --group <group-name> [--dry-run]
```

The script:
1. Verifies the user and the group exist in LLDAP.
2. Calls GraphQL `addUserToGroup(userId, groupId)`. Re-adding an existing
   member is a no-op (LLDAP returns "already a member" → treated as success).
3. Audits the add.
4. **Triggers the OpenFGA tuple reconciler**
   (`LLDAP_RECONCILE_CMD`, default
   `python3 scripts/openfga-tuple-reconcile.py`) so the new membership is
   mirrored as relationship tuples. Set `LLDAP_RECONCILE_CMD=` (empty) to
   skip.

### 3.2 Remove a member

```bash
scripts/lldap-group-remove-member.sh --user <uid> --group <group-name>
```

Calls GraphQL `removeUserFromGroup(userId, groupId)` and audits. The OpenFGA
reconciler (next scheduled run, or re-triggered) removes the corresponding
tuple.

> For **bulk** membership audit across all groups, use
> `scripts/lldap-audit-all-memberships.sh`.

---

## 4. MODIFY a group

LLDAP groups have only a `displayName` (rename via GraphQL `updateGroup` —
rare; the integer `id` stays). Membership changes (§3) are the common
"modify". There is no per-group attribute set.

---

## 5. DELETE a group

```bash
scripts/lldap-group-delete.sh --name <group-name> [--yes]
```

The script removes the group entry. **Before** deleting a group:

1. Remove all members (`lldap-group-remove-member.sh` for each, or use the
   bulk audit to enumerate them).
2. Remove the corresponding OpenFGA tuples (`openfga-tuple-delete.sh`).
3. Remove the Vault LDAP-group binding
   (`auth/ldap/groups/<group-name>`) — see
   [how_to_create_vault_policy.md](how_to_create_vault_policy.md) §unbinding.

Failing to do step 2/3 leaves dangling tuples / bindings that reference a
group that no longer exists.

---

## 6. Downstream effects — what a group grant does

| Downstream | How it gets there | Effect |
|------------|-------------------|--------|
| OpenFGA tuples | `openfga-tuple-reconcile.py` reads LLDAP memberships | `user:<uid>` gains the relation(s) the group implies (e.g. `admin tenant:aws`) |
| Vault ACL policy | `scripts/vault-ldap-group-bind.sh <group> <policy>` | members get `<policy>` on `auth/ldap/login/<uid>` |
| Dex | (none — Dex does no group search) | group membership is **not** a Dex claim |

---

## 7. VERIFY

```bash
# List members of a group:
scripts/lldap-group-list-members.sh --group <group-name>

# List groups a user is in:
scripts/lldap-user-list-groups.sh --user <uid>

# Audit all memberships:
scripts/lldap-audit-all-memberships.sh

# Over LDAP directly:
docker compose run --rm lldap-tools /scripts/verify-ldap.py
```

---

## 8. Files touched

| File / store | What changes |
|--------------|--------------|
| LLDAP directory (`ou=groups,…`) | group entry + membership rows |
| `generated/lldap_audit.log` | one JSONL line per create / add / remove / delete |
| OpenFGA tuple store | (via reconciler) `user:<uid>` relation tuples added/removed |
| Vault `auth/ldap/groups/<name>` | (only if you bind it) policy mapping |

---

## 9. Quick reference

| Action | Command |
|--------|---------|
| Create group | `scripts/lldap-group-create.sh --name <name>` |
| Add member | `scripts/lldap-group-add-member.sh --user <u> --group <g>` |
| Remove member | `scripts/lldap-group-remove-member.sh --user <u> --group <g>` |
| List members | `scripts/lldap-group-list-members.sh --group <g>` |
| List a user's groups | `scripts/lldap-user-list-groups.sh --user <u>` |
| Audit all | `scripts/lldap-audit-all-memberships.sh` |
| Delete group | `scripts/lldap-group-delete.sh --name <name>` |
| Bind to Vault policy | `scripts/vault-ldap-group-bind.sh <group> <policy>` |
