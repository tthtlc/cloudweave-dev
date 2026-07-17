# How to Create / Modify / Delete a Vault Cloud Secrets Engine (+ Roles + Dynamic Creds + Leases)

This guide covers Vault **cloud secrets engines** (`../vault`): the
`aws` / `azure` / `gcp` / `alibaba` engines that mint **dynamic short-lived**
cloud credentials, plus the roles that define what credentials to mint and
the leases that track / renew / revoke them.

> **When to use this instead of a static KV secret.** The per-tenant backend
> credentials in `secret/libcloud/<tenant>` (see
> [how_to_create_vault_secret.md](how_to_create_vault_secret.md)) are
> **static** root creds the libcloud REST API reads at request time. A cloud
> secrets engine is the **dynamic** alternative: Vault holds the cloud root
> creds once (at `<mount>/config/root`), and per-role STS / access-token
> requests return short-lived credentials. Use an engine when you want
> time-boxed, revocable, audit-traced cloud access instead of long-lived
> keys.

> **Policy note.** The `libcloud-rest-read` policy only grants read/list on
> `secret/libcloud/*`. Engine-generated dynamic creds live at their own
> mount paths (`aws/`, `azure/`, …), so the REST API **cannot** reach them
> unless you add a dedicated policy via
> [how_to_create_vault_policy.md](how_to_create_vault_policy.md).

---

## 0. The engine lifecycle

```
vault secrets enable <type> <mount>      # enable engine at mount path
vault write <mount>/config(/root)        # write cloud root creds once
vault write <mount>/roles/<name>         # define a role (what creds to mint)
vault read  <mount>/<role>               # mint dynamic creds → returns lease_id
vault lease renew  <lease_id>            # extend TTL
vault lease revoke  <lease_id>           # revoke early (offboard)
vault secrets disable <mount>            # remove the engine (destructive)
```

---

## 1. Prerequisites

- `../vault` is up and unsealed; `generated/vault.env` has
  `VAULT_ROOT_TOKEN`.
- You have the cloud root credentials in a local file (key=value or a single
  JSON object). The file is read once; values are never echoed.
- You are running as `superadmin` / cloud owner (the enable script uses the
  root token).

---

## 2. ADD an engine (enable + configure root creds)

```bash
cd ../openfga_my
scripts/vault-secrets-engine-enable.sh \
    --provider aws --mount aws --root-creds-file /tmp/aws-root.env --region us-east-1
```

`vault-secrets-engine-enable.sh`:
1. Builds the `/config` body from the creds file (key=value or JSON).
   - aws / alibaba → `access_key`, `secret_key`, `region` → POSTed to
     `<mount>/config/root`.
   - azure → `client_id`, `client_secret`, `subscription_id`, `tenant_id` →
     `<mount>/config`.
   - gcp → raw service-account JSON as `credentials` → `<mount>/config`.
2. `POST /sys/mounts/<mount>` to enable the engine (idempotent — 400 "path
   is already in use" is OK).
3. `POST /<config_path>` to write the root creds (not echoed).
4. Audits to `generated/vault_audit.log`.

`--dry-run` validates and prints what would be done without calling Vault.

---

## 3. ADD a role (what credentials to mint)

Roles are engine-specific. Use `vault-role-create.sh` for the supported
engines:

```bash
scripts/vault-role-create.sh --mount aws --role ec2-readonly \
    --credential-type iam --policy-arns arn:aws:iam::aws:policy/ReadOnly \
    --ttl 30m --max-ttl 2h
```

The script wraps the engine-specific role-write body and audits. For
engines/fields not covered, drop down to the HTTP API directly:

```bash
curl -sS -X POST "$VAULT_ADDR/v1/aws/roles/ec2-readonly" \
  -H "X-Vault-Token: $VAULT_ROOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"credential_type":"iam","policy_arns":[...],"ttl":"30m","max_ttl":"2h"}'
```

---

## 4. MINT dynamic credentials (request a lease)

```bash
scripts/vault-dynamic-cred-request.sh --mount aws --role ec2-readonly
# → prints the dynamic creds + lease_id
```

Or directly:

```bash
curl -sS "$VAULT_ADDR/v1/aws/ec2-readonly" \
  -H "X-Vault-Token: $VAULT_TOKEN" | jq
# → { "data": { "access_key": "...", "secret_key": "...", "security_token": "..." },
#     "lease_id": "aws/ec2-readonly/abc123", "lease_duration": 1800, "renewable": true }
```

Record the `lease_id` — it is how you renew or revoke the credential.

---

## 5. MODIFY

### 5.1 Rotate the engine's root credentials

```bash
scripts/vault-root-cred-rotate.sh --mount aws --root-creds-file /tmp/aws-root.env
```

Re-writes `<mount>/config/root` with new root creds. Existing dynamic leases
are unaffected; new `read` calls mint creds signed by the new root.

### 5.2 Update a role

Re-write the role with `vault-role-create.sh` (idempotent overwrite) or a
direct `POST /<mount>/roles/<name>`. New `read` calls mint creds under the
new role definition.

### 5.3 Renew a lease

```bash
scripts/vault-lease-renew.sh <lease_id>
```

Or `vault lease renew <lease_id>` / `POST /sys/leases/renew`.

---

## 6. DELETE / revoke

### 6.1 Revoke a single lease (offboard one dynamic cred)

```bash
scripts/vault-lease-revoke.sh <lease_id>
```

The dynamic credential is invalidated at the cloud provider immediately.

### 6.2 Revoke all leases under a prefix

```bash
scripts/vault-lease-revoke-prefix.sh aws/
```

Useful when offboarding a whole tenant or rotating a compromised root.

### 6.3 List leases (audit before revoke)

```bash
scripts/vault-lease-list.sh
```

### 6.4 Disable the engine (destructive)

```bash
curl -sS -X DELETE "$VAULT_ADDR/v1/sys/mounts/aws" \
  -H "X-Vault-Token: $VAULT_ROOT_TOKEN"
```

This revokes all leases under the mount and removes the engine. Root creds
and roles are gone.

---

## 7. VERIFY

```bash
# Engine is mounted:
scripts/vault-health-check.sh
curl -sS "$VAULT_ADDR/v1/sys/mounts" -H "X-Vault-Token: $VAULT_ROOT_TOKEN" | jq .[\"aws/\"]

# Role is configured:
curl -sS "$VAULT_ADDR/v1/aws/roles/ec2-readonly" -H "X-Vault-Token: $VAULT_TOKEN" | jq

# Mint + use a dynamic cred (cloud-side smoke test):
scripts/vault-dynamic-cred-request.sh --mount aws --role ec2-readonly
```

---

## 8. Files touched

| File / store | What changes |
|--------------|--------------|
| Vault mount table | engine enabled / disabled at `<mount>/` |
| `<mount>/config(/root)` | root creds (encrypted at rest) |
| `<mount>/roles/<name>` | role definitions |
| Vault lease store | one lease per `read` |
| `generated/vault_audit.log` | one JSONL line per enable / role / mint / renew / revoke |
| `../libcloud.rest` policy | (only if REST API should read dynamic creds) a dedicated ACL policy |

---

## 9. Quick reference

| Action | Command |
|--------|---------|
| Enable + configure | `scripts/vault-secrets-engine-enable.sh --provider <p> --mount <m> --root-creds-file <f>` |
| Create role | `scripts/vault-role-create.sh --mount <m> --role <r> ...` |
| Mint creds | `scripts/vault-dynamic-cred-request.sh --mount <m> --role <r>` |
| List leases | `scripts/vault-lease-list.sh` |
| Renew lease | `scripts/vault-lease-renew.sh <lease_id>` |
| Revoke lease | `scripts/vault-lease-revoke.sh <lease_id>` |
| Revoke prefix | `scripts/vault-lease-revoke-prefix.sh <prefix>` |
| Rotate root | `scripts/vault-root-cred-rotate.sh --mount <m> --root-creds-file <f>` |
| Disable engine | `DELETE /v1/sys/mounts/<mount>` (root token) |
