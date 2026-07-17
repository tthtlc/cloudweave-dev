# How to Create / Modify / Delete a Vault ACL Policy (+ LLDAP Group Binding)

This guide covers **Vault ACL policies** (`../vault`) and the **LLDAP group →
policy bindings** that decide which Vault capabilities a human gets when they
log in to Vault through the LDAP auth method.

> **What a policy + binding is here.** A Vault ACL policy is an HCL document
> that grants `read` / `list` / `create` / `update` / `delete` / `sudo`
> capabilities on Vault paths. The `libcloud-rest-read` policy (read/list on
> `secret/data/libcloud/*` and `secret/metadata/libcloud/*`) is created by
> `vault_bootstrap.py` and is the one the libcloud REST API uses. A **group
> binding** is the entry `auth/ldap/groups/<lldap-group>` that maps an LLDAP
> group to one or more policy names, so that members of that LLDAP group get
> those policies on `auth/ldap/login/<uid>`.

---

## 0. The token hierarchy (recap)

| Token | Capabilities | Where it lives | Who gets it |
|-------|--------------|----------------|-------------|
| `VAULT_ROOT_TOKEN` | root | `generated/vault.env` (0600) | host admin scripts only |
| `VAULT_TOKEN` (libcloud REST) | read/list `secret/libcloud/*` | synced into `../libcloud.rest/.env` | libcloud REST API container |
| LDAP-issued tokens | per LLDAP group → bound policy | issued per login, short-lived | humans who `auth/ldap/login` |

Policies are created with the **root token**. The REST API token's policy
(`libcloud-rest-read`) is created during bootstrap; you usually only add
policies for **human** access via LDAP group bindings.

---

## 1. Prerequisites

- `../vault` is up and unsealed; `generated/vault.env` has
  `VAULT_ROOT_TOKEN`.
- The LDAP auth method is configured (`auth/ldap/config` points at
  `ldap://lldap:3890`) — done by `setup.sh` / `vault_bootstrap.py`.
- The LLDAP group you want to bind already exists (see
  [how_to_create_lldap_group.md](how_to_create_lldap_group.md)).

---

## 2. ADD a policy

### Step 1 — Write the HCL

```hcl
# e.g. policy-files/cloud-admin-aws.hcl
path "secret/data/libcloud/aws"          { capabilities = ["read"] }
path "secret/metadata/libcloud/aws"      { capabilities = ["read", "list"] }
path "aws/roles/ec2-readonly"            { capabilities = ["read"] }
path "aws/ec2-readonly"                  { capabilities = ["read"] }   # mint dynamic creds
```

### Step 2 — Apply it

```bash
cd ../openfga_my
scripts/vault-policy-apply.sh cloud-admin-aws policy-files/cloud-admin-aws.hcl
```

`vault-policy-apply.sh`:
1. `PUT /sys/policies/acl/<name>` with `{"policy": "<HCL>"}` (root token).
2. Read-back `GET /sys/policies/acl/<name>` to confirm.
3. Audits to `generated/vault_audit.log`.

Idempotent — re-applying overwrites the policy with the current HCL.

`--dry-run` validates the file and prints the would-be request without
calling Vault.

---

## 3. BIND an LLDAP group to a policy

```bash
scripts/vault-ldap-group-bind.sh cloud-admin-aws cloud-admin-aws
# writes auth/ldap/groups/cloud-admin-aws { policies: "cloud-admin-aws" }
```

The first argument is the LLDAP group `displayName`; the second is the
policy name (comma-separated for multiple). The script:

1. `POST /auth/ldap/groups/<group>` with `{"policies": "<policy>"}` (root
   token).
2. Read-back + audit line to `generated/vault_audit.log`.

Idempotent. After this, a member of the LLDAP group `cloud-admin-aws` who
runs `auth/ldap/login/<uid>` receives a Vault token carrying the
`cloud-admin-aws` policy.

> **How the bind authenticates the user:** Vault binds against LLDAP with
> the user's own password (real-time) and reads their group memberships via
> an LDAP search. The LLDAP service-account bind credential lives in
> `auth/ldap/config` (`binddn` / `bindpass`), written by `setup.sh`. No
> password is stored in Vault beyond that bind credential.

---

## 4. MODIFY

### 4.1 Change a policy's HCL

Edit the file and re-run `vault-policy-apply.sh <name> <file>`. Existing
tokens keep their old capabilities until they expire / are revoked; new
logins get the new policy.

### 4.1 Re-bind a group to different policies

```bash
scripts/vault-ldap-group-bind.sh cloud-admin-aws cloud-admin-aws,cloud-readonly
```

Re-running the bind overwrites the `policies` list for that group.

### 4.3 Rotate the LLDAP admin bind credential

If you rotated the LLDAP `admin` password (see
[how_to_create_lldap_user.md](how_to_create_lldap_user.md) §3.1 and
`scripts/lldap-admin-cred-rotate.sh`), re-write `auth/ldap/config` with the
new `bindpass`:

```bash
vault write auth/ldap/config \
   url="ldap://lldap:3890" \
   userdn="ou=people,dc=libcloud,dc=local" \
   groupdn="ou=groups,dc=libcloud,dc=local" \
   binddn="uid=admin,ou=people,dc=libcloud,dc=local" bindpass="<new>" \
   userattr="uid" insecure_tls=true
```

(`setup.sh` does this on a fresh run; do it manually only after a password
rotation.)

---

## 5. DELETE / unbind

### 5.1 Unbind an LLDAP group from a policy

```bash
curl -sS -X DELETE "$VAULT_ADDR/v1/auth/ldap/groups/<group>" \
  -H "X-Vault-Token: $VAULT_ROOT_TOKEN"
```

Members of that group will no longer receive the policy on their next login
(existing tokens keep their capabilities until expiry).

### 5.2 Delete a policy

```bash
curl -sS -X DELETE "$VAULT_ADDR/v1/sys/policies/acl/<name>" \
  -H "X-Vault-Token: $VAULT_ROOT_TOKEN"
```

Remove all group bindings to that policy first (§5.1), or those groups will
reference a non-existent policy on next login.

> **Never delete `libcloud-rest-read`** while the libcloud REST API is in
> service — its read token is bound to that policy and the API will start
> failing every request.

---

## 6. VERIFY

```bash
# Policy is present and the HCL is what you expect:
curl -sS "$VAULT_ADDR/v1/sys/policies/acl/<name>" -H "X-Vault-Token: $VAULT_ROOT_TOKEN" | jq

# Group binding is present:
curl -sS "$VAULT_ADDR/v1/auth/ldap/groups/<group>" -H "X-Vault-Token: $VAULT_ROOT_TOKEN" | jq

# Audit policies + bindings:
scripts/vault-policy-list-audit.sh

# End-to-end: an LLDAP user in the bound group logs in to Vault:
curl -sS -X POST "$VAULT_ADDR/v1/auth/ldap/login/<uid>" \
  -H "Content-Type: application/json" \
  -d '{"password":"<pw>"}' | jq .auth.policies   # → ["cloud-admin-aws"]

# Inspect a token's capabilities + TTL:
scripts/vault-token-lookup.sh
```

---

## 7. Files touched

| File / store | What changes |
|--------------|--------------|
| Vault ACL policy store | new / updated / deleted `<name>` policy |
| `auth/ldap/groups/<group>` | new / updated / deleted binding |
| `auth/ldap/config` | (only on bind-pass rotation) `bindpass` |
| `generated/vault_audit.log` | one JSONL line per apply / bind |

---

## 8. Quick reference

| Action | Command |
|--------|---------|
| Apply policy | `scripts/vault-policy-apply.sh <name> <file.hcl>` |
| Bind LLDAP group | `scripts/vault-ldap-group-bind.sh <group> <policy[,policy...]>` |
| List / audit policies | `scripts/vault-policy-list-audit.sh` |
| Unbind group | `DELETE /v1/auth/ldap/groups/<group>` (root token) |
| Delete policy | `DELETE /v1/sys/policies/acl/<name>` (root token) |
| Re-write LDAP config | `vault write auth/ldap/config ...` (after `lldap-admin-cred-rotate.sh`) |
| Token lookup | `scripts/vault-token-lookup.sh` |
