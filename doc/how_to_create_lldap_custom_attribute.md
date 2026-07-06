# How to Create / Modify / Delete an LLDAP Custom User Attribute (Schema Field)

This guide covers **custom user attributes** in LLDAP (`../lldap`) — the
schema fields beyond the built-in `uid` / `mail` / `displayName` / `firstName`
/ `lastName`. Today the deployment ships three: `department`, `role`,
`jobtitle`. This is the procedure for adding a fourth (or removing one).

> **Why this is its own guide.** Custom attributes are registered through the
> GraphQL `addUserAttribute` mutation (authenticated with an admin JWT) and
> are recorded in `bootstrap/user-schemas/custom-attributes.json`. They are
> **append-only in practice** — LLDAP does not clean up old custom attributes
> when you remove them from the schema file. Removing one requires an explicit
> `deleteUserAttribute` mutation.

---

## 0. How LLDAP custom attributes work

- Registered via `addUserAttribute(name, attributeType, isList, isVisible,
  isEditable)` — authenticated with an admin JWT.
- Idempotent in practice: a repeat call returns an "already exists" error
  which `setup-schema.sh` treats as success.
- Once registered, the attribute appears in the **web UI** user form and is
  returned by **LDAP searches** by name.
- `attributeType` is one of `STRING`, `INTEGER`, `BOOLEAN`, `DATE`,
  `BYTES`, `JSON` (this deployment uses `STRING`).

---

## 1. Prerequisites

- `../lldap` is up: `docker compose up -d`.
- `LLDAP_LDAP_USER_PASS` is available.
- The `bootstrap` / `lldap-tools` images are built (run with `--build`).

---

## 2. ADD a new custom attribute (e.g. `cost_center`)

### Step 1 — Record it in the schema file

Edit `../lldap/bootstrap/user-schemas/custom-attributes.json` and append:

```json
{
  "name": "cost_center",
  "attributeType": "STRING",
  "isList": false,
  "isVisible": true,
  "isEditable": true
}
```

This file is the **reference/supply** for LLDAP's community bootstrap feature
(`USER_SCHEMAS_DIR=/bootstrap/user-schemas`).

### Step 2 — Add it to the schema-apply loop

Edit `../lldap/scripts/setup-schema.sh` and add the attribute name to the
loop, e.g.:

```bash
for attr in department role jobtitle cost_center; do
  ...
done
```

### Step 3 — Apply the schema (idempotent)

```bash
# One-shot bootstrap profile:
docker compose --profile bootstrap run --rm --build bootstrap

# Or on demand via the tools container:
docker compose run --rm lldap-tools /scripts/setup-schema.sh
```

`setup-schema.sh`:
1. Waits for the web UI at `${LLDAP_URL}/`.
2. `POST /auth/simple/login` as `admin` → admin JWT.
3. For each attribute, calls `addUserAttribute(STRING, isList=false,
   isVisible=true, isEditable=true)`.
4. Queries `schema { userSchema { attributes { ... } } }` and prints the
   resulting schema as JSON.

### Step 4 — Reference it in user creation

Edit `../lldap/scripts/create-user.sh`'s `ATTRS` block to include the new
attribute so it is set when a user is created. (Existing users will have the
attribute empty until you set it via `updateUser` — see
[how_to_create_lldap_user.md](how_to_create_lldap_user.md) §3.2.)

---

## 3. MODIFY a custom attribute

LLDAP custom attributes are **not modifiable** in the sense of changing the
type of an existing attribute. To change the type:

1. Add the new attribute under a new name (§2) and migrate user values via
   GraphQL `updateUser`.
2. Remove the old attribute (§4).

`isVisible` / `isEditable` flags can be re-issued by re-running
`addUserAttribute` with the new flags (LLDAP treats this as already-exists →
no change in most builds; verify with the schema query). Treat the attribute
definition as effectively **append-only**.

---

## 4. DELETE a custom attribute

Removing the attribute from `custom-attributes.json` and re-running
`setup-schema.sh` does **not** remove it from LLDAP — the cleanup does not
happen automatically. To actually remove it:

### Step 1 — Ensure no users carry a value

For every user that has the attribute set, clear it via GraphQL `updateUser`
with `attributes: [{name: "<attr>", value: []}]`.

### Step 2 — Delete the attribute from the schema

```bash
# Obtain an admin JWT (POST /auth/simple/login as admin), then:
curl -sS -X POST http://localhost:17170/api/graphql \
  -H "Authorization: Bearer <admin-jwt>" \
  -H "Content-Type: application/json" \
  -d '{"query":"mutation { deleteUserAttribute(name: \"cost_center\") { ok } }"}'
```

### Step 3 — Remove from the schema file and the loop

Delete the entry from `bootstrap/user-schemas/custom-attributes.json` and
remove it from the `for attr in ...` loop in `scripts/setup-schema.sh`.

---

## 5. VERIFY

```bash
# Print the full user schema (all attributes):
docker compose run --rm lldap-tools /scripts/setup-schema.sh   # ends with schema JSON

# Confirm an attribute appears on a user over LDAP:
docker compose run --rm lldap-tools /scripts/verify-ldap.py   # prints attrs per user
```

---

## 6. Files touched

| File | What changes |
|------|--------------|
| `bootstrap/user-schemas/custom-attributes.json` | new / removed attribute entry |
| `scripts/setup-schema.sh` | attribute name in the `for attr in ...` loop |
| `scripts/create-user.sh` | `ATTRS` block referencing the attribute |
| LLDAP schema (runtime) | attribute registered / deleted via GraphQL |

---

## 7. Quick reference

| Action | Command |
|--------|---------|
| Apply schema (idempotent) | `docker compose --profile bootstrap run --rm --build bootstrap` |
| Apply on demand | `docker compose run --rm lldap-tools /scripts/setup-schema.sh` |
| Delete attribute | GraphQL `deleteUserAttribute(name: "...")` with admin JWT |
| Verify schema | re-run `setup-schema.sh` (prints schema JSON) |
