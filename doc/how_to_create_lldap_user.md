# How to Create / Modify / Offboard an LLDAP User

This guide covers the full lifecycle of a **user** in the LLDAP directory
(`../lldap`): the six managed fields, how to add a user, reset / change a
password, update attributes, and offboard (disable) a user.

> **What a "user" is here.** A user is an LDAP entry under
> `ou=people,dc=libcloud,dc=local` with `uid` (login id), `mail`, `cn`
> (display name), and three custom attributes — `department`, `role`,
> `jobtitle`. The `uid` becomes the Dex OIDC `sub` and the OpenFGA subject
> (`user:<uid>`); `mail` becomes the libcloud REST `by_email` mapping key.
> Renaming a `uid` is **not** supported — create a new user instead.

---

## 0. The six managed fields

| Your field | LLDAP / GraphQL attribute | LDAP attribute | Origin |
|------------|----------------------------|----------------|--------|
| email      | `mail`                     | `mail`         | built-in |
| username   | `user_id` / `id`           | `uid`          | built-in (login) |
| name       | `display_name`             | `cn`           | built-in |
| department | `department`               | `department`   | custom attribute |
| role       | `role`                     | `role`         | custom attribute |
| job desc   | `jobtitle`                 | `jobtitle`     | custom attribute |

Custom attributes must be registered first (see
[how_to_create_lldap_custom_attribute.md](how_to_create_lldap_custom_attribute.md))
or `create-user.sh` cannot set them.

---

## 1. Prerequisites

- `../lldap` is up: `docker compose up -d` (from `../lldap`).
- The custom-attribute schema has been applied at least once:
  `docker compose --profile bootstrap run --rm --build bootstrap`.
- `LLDAP_LDAP_USER_PASS` (the `admin` password) is available — sourced from
  `../lldap/.env` or `generated/dex.env`.
- LLDAP uid rules: lowercase `[a-z0-9][a-z0-9._-]{0,62}`, password ≥ 8 chars,
  email valid.

You can run either the **canonical containerized scripts** (no host deps) or
the **orchestrator scripts** in `../openfga_my/scripts/` (which add OpenFGA
tuple reconciliation). Both are listed below.

---

## 2. ADD a user

### 2a. Canonical LLDAP tooling (six fields, no OpenFGA)

From `../lldap`:

```bash
docker compose run --rm lldap-tools /scripts/create-user.sh \
  <username> <email> <name> <department> <role> <jobtitle> [password]
```

If no password is supplied, a random one is generated (`openssl rand`).

`create-user.sh` flow:
1. `POST /auth/simple/login` as `admin` → admin JWT.
2. GraphQL `createUser` with `id`, `email`, `displayName`, and an `attributes`
   array containing `department`, `role`, `jobtitle` (each
   `{name, value:[<one value>]}`).
3. `scripts/set-password.py` binds as admin over LDAP and uses the
   **PasswordModify extended operation** to set the user's password.

### 2b. Orchestrator tooling (account only — group/role grant is separate)

From `../openfga_my`:

```bash
scripts/lldap-user-onboard.sh \
  --username aws-admin --display-name "AWS Admin" \
  --email aws-admin@libcloud.local --password '<pw>' \
  [--first-name ... --last-name ...]
# or from a parameter file:
scripts/lldap-user-onboard.sh --file user-aws-admin.json
```

`lldap-user-onboard.sh` deliberately **only** creates the account + initial
password — it does **not** assign groups, so account creation and role grant
are audited separately. Use `lldap-user-add-member.sh` (next) to grant roles.

### 2c. Tenant-shaped users (owner / admin / viewer)

For the standard `<tenant>-owner` / `<tenant>-admin` / `<tenant>-viewer`
triples, prefer the tenant helpers, which create all three users, append their
passwords to `generated/dex.env`, and write the OpenFGA tuples in one shot:

```bash
TENANT=aws-dev CLOUD=aws ./scripts/create_tenant.sh
```

See [how_to_add_new_tenant.md](how_to_add_new_tenant.md) Case A.

---

## 3. MODIFY a user

### 3.1 Reset / change the password

```bash
# Orchestrator (audited; optionally reconciles OpenFGA):
scripts/lldap-user-password-reset.sh --username <uid> [--password <pw>]

# Canonical (LDAP PasswordModify):
docker compose run --rm lldap-tools /scripts/set-password.py   # reads env
```

If `--password` is omitted, a random password is generated. After a reset, any
cached Dex refresh tokens for that user (`generated/tokens/*.json`) should be
removed so the user must re-login.

### 3.2 Update custom attributes (department / role / jobtitle)

There is no first-class script — use the GraphQL `updateUser` mutation with an
admin JWT (obtained the same way as `create-user.sh`):

```graphql
mutation {
  updateUser(user: {
    id: "<uid>"
    email: "<new-email>"        # optional
    displayName: "<new-name>"   # optional → cn
    attributes: [
      { name: "department", value: ["<new dept>"] }
      { name: "role",       value: ["<new role>"] }
      { name: "jobtitle",   value: ["<new title>"] }
    ]
  }) { ok }
}
```

POST to `http://localhost:17170/api/graphql` with
`Authorization: Bearer <admin-jwt>`. Each non-list attribute's `value` vector
must contain exactly one element.

> **Cross-component effect:** changing `uid` is not supported. Changing `mail`
> requires updating `data/principal_map.json` `by_email` (see
> [how_to_create_openfga_principal_mapping.md](how_to_create_openfga_principal_mapping.md)).
> Changing which group/role a user belongs to is a group-membership change,
> not a user attribute change — see
> [how_to_create_lldap_group.md](how_to_create_lldap_group.md).

---

## 4. DELETE / disable a user (offboard)

LLDAP has no native "disabled" flag in this version, and the canonical path
**does not delete** the account (the `uid` and audit trail are retained).
Offboarding is:

1. **Remove the user from every group** (revokes role-derived access).
2. **Scramble the password** to a random unknown value (locks login).

```bash
scripts/lldap-user-offboard.sh --username <uid> [--keep-password] [--dry-run]
```

`--keep-password` only removes group memberships (use when the caller will
reset the password themselves). The LLDAP directory admin cannot be offboarded
(the script refuses).

### 4.1 Full offboarding chain (LLDAP + OpenFGA + Vault)

Offboarding a user who held a tenant role must also clean up OpenFGA tuples
and Vault leases. Use the chain:

```bash
scripts/chain-offboard-user.sh --username <uid>
```

which runs, in order: `lldap-user-offboard.sh` → OpenFGA tuple deletion for
`user:<uid>` → Vault lease revocation for that caller. Each step audits to its
own `generated/*_audit.log`.

### 4.2 Truly deleting an account

If you must permanently remove the DN (rare — breaks audit references), use a
GraphQL `deleteUser` mutation with an admin JWT. The OpenFGA tuples and any
Vault LDAP-group bindings referencing that `uid` must be removed first, or
they become dangling.

---

## 5. VERIFY

```bash
# List + verify all users over LDAP (prints uid, mail, cn, department, role, jobtitle):
docker compose run --rm lldap-tools /scripts/verify-ldap.py

# Bind as a specific user to confirm the password works:
docker compose run --rm lldap-tools /scripts/verify-ldap.py <uid> [password]

# Orchestrator: list a user's groups (shows current roles):
scripts/lldap-user-list-groups.sh --user <uid>
```

---

## 6. Files touched

| File / store | What changes |
|--------------|--------------|
| LLDAP directory (`ou=people,…`) | new / updated / offboarded user entry |
| `generated/dex.env` | new user+password lines (only via `create_tenant.sh` / `dex_bootstrap.py`) |
| `generated/lldap_audit.log` | one JSONL line per onboard / reset / offboard |
| OpenFGA tuple store | (only via the chain) `user:<uid>` tuples removed on offboard |
| `data/principal_map.json` | only if `mail` changes (Phase 2 `by_email`/`by_sub`) |

---

## 7. Quick reference

| Action | Command |
|--------|---------|
| Create (canonical, 6 fields) | `docker compose run --rm lldap-tools /scripts/create-user.sh <u> <e> <n> <dept> <role> <title> [pw]` |
| Create (orchestrator) | `scripts/lldap-user-onboard.sh --username <u> --display-name <n> --email <e> --password <p>` |
| Create tenant-shaped triple | `TENANT=<t> CLOUD=<c> ./scripts/create_tenant.sh` |
| Reset password | `scripts/lldap-user-password-reset.sh --username <u>` |
| Update attributes | GraphQL `updateUser` with admin JWT |
| Offboard (disable) | `scripts/lldap-user-offboard.sh --username <u>` |
| Full offboard chain | `scripts/chain-offboard-user.sh --username <u>` |
| Verify | `docker compose run --rm lldap-tools /scripts/verify-ldap.py` |
