# How to Create / Modify / Delete a Vault KV v2 Secret

This guide covers **static KV v2 secrets** in Vault (`../vault`) under the
`secret/libcloud/` prefix — the per-tenant cloud backend credentials and
ad-hoc secrets. It covers the three write paths (root-token ad-hoc,
owner-gated per-tenant, environment-driven), listing, version destroy, and
full delete.

> **What a secret is here.** A KV v2 secret at `secret/data/libcloud/<name>`
> holds an arbitrary `key=value` JSON object. KV v2 is **versioned and
> append-only** — re-writing a key creates a new version; old versions stay
> recoverable until the metadata is deleted. The libcloud REST API reads
> these at request time with a least-privilege read-only token
> (`libcloud-rest-read` policy, scoped to `secret/data/libcloud/*`).

---

## 0. The layout

```
secret/data/libcloud/aws         { key, secret }       tenant:aws      backend creds
secret/data/libcloud/aws-dev     { key, secret }       tenant:aws-dev  (per-tenant)
secret/data/libcloud/nutanix     { key, secret }       tenant:nutanix  backend creds
secret/data/libcloud/<name>      { arbitrary k=v }     any ad-hoc secret
```

Three write entry points, in increasing specificity:

| Path | Tool | Auth | When to use |
|------|------|------|-------------|
| A. Ad-hoc | `vault/add_credential.py` | root token | any non-tenant secret |
| B. Per-tenant backend creds | `openfga_my/scripts/set_tenant_credentials.py` | Dex login + OpenFGA `can_manage_credentials` | cloud credentials (owner-only) |
| C. Cloud secrets engine | `vault-secrets-engine-enable.sh` | root token | dynamic short-lived creds (separate doc) |

---

## 1. Prerequisites

- `../vault` is up and **unsealed** (`vault-bootstrap` has run).
- `generated/vault.env` exists with `VAULT_ADDR`, `VAULT_TOKEN` (read-only),
  `VAULT_ROOT_TOKEN`.
- For path B: the target tenant exists in OpenFGA and you are its owner (or
  `superadmin`).

---

## 2. ADD a secret

### 2a. Ad-hoc via `add_credential.py` (root-token write)

From `../vault`:

```bash
# From key=value pairs:
python3 add_credential.py aws-staging --kv key=AKIA... --kv secret=...

# From environment variables (key = var name lowercased):
python3 add_credential.py aws-staging \
    --from-env LIBCLOUD_AWS_KEY LIBCLOUD_AWS_SECRET

# Interactive prompt (values read silently with getpass):
python3 add_credential.py gcp-prod
```

It reads `VAULT_ADDR` + `VAULT_ROOT_TOKEN` from `generated/vault.env` (or
`--addr` / `--token`), POSTs to `/v1/secret/data/libcloud/<name>` with
`X-Vault-Token`, and prints the resulting path. Re-adding an existing name
creates a **new version** (KV v2 is append-only).

### 2b. Per-tenant backend creds via `set_tenant_credentials.py` (owner-gated)

This is the **authorized** path for cloud credentials — it gates the write
on an OpenFGA `can_manage_credentials` Check (owner-only):

```bash
cd ../openfga_my
TENANT=aws-dev CLOUD=aws \
  LIBCLOUD_USER=aws-dev-owner LIBCLOUD_PASSWORD='<owner-pw>' \
  LIBCLOUD_AWS_KEY=AKIA... LIBCLOUD_AWS_SECRET=... \
  python3 scripts/set_tenant_credentials.py
```

Flow (`set_tenant_credentials.py`):
1. Dex login as `LIBCLOUD_USER` → JWT (proves the caller is a real LLDAP
   user).
2. OpenFGA `Check user:<uid> can_manage_credentials tenant:<tenant>` — only
   the tenant owner (and `superadmin` as break-glass owner on every tenant)
   passes. admins/viewers are denied.
3. `POST /v1/secret/data/libcloud/<tenant>` with `X-Vault-Token: $VAULT_ROOT_TOKEN`.

`CLOUD=aws` selects `LIBCLOUD_AWS_KEY/SECRET`; `CLOUD=nutanix` selects
`LIBCLOUD_NTNX_USER/PASSWORD`. `TENANT` selects both the Vault path and the
OpenFGA object the Check runs against.

Credential values are **never** read from `.env` — the owner supplies them at
runtime.

---

## 3. MODIFY a secret (new version)

KV v2 is append-only — re-run the same write command with the new values. A
new version is created; the previous version remains recoverable.

For per-tenant creds, just re-run `set_tenant_credentials.py` with the new
values (still owner-gated). For rotation with a dedicated tool:

```bash
scripts/vault-static-secret-rotate.sh <name>   # in ../openfga_my/scripts
```

---

## 4. LIST secrets

```bash
# Keys + version/timestamps, no values:
python3 ../vault/list_credentials.py

# Include values (sensitive!):
python3 ../vault/list_credentials.py --show-values
```

Recursively LISTs `secret/metadata/libcloud/` and prints each secret's keys
and metadata. Reads `VAULT_ADDR` + `VAULT_TOKEN` from `generated/vault.env`.

---

## 5. DELETE a secret

`delete_credential.py` — two modes:

```bash
# Permanently remove the secret + all versions + metadata (irreversible):
python3 ../vault/delete_credential.py aws-staging            # prompts to type the name
python3 ../vault/delete_credential.py aws-staging --yes      # skip confirmation

# Destroy only the current version's data; keep metadata (audit trail preserved):
python3 ../vault/delete_credential.py aws-staging --destroy-versions
```

- Full delete → `DELETE /v1/secret/metadata/libcloud/<name>`.
- Version destroy → `DELETE /v1/secret/data/libcloud/<name>`.
- Both require the **root token** (`VAULT_ROOT_TOKEN`).
- The typed-name confirmation guard prevents accidental full deletes.

> For a per-tenant secret, deleting it means the libcloud REST API can no
> longer read backend creds for that tenant → all provisioning for that
> tenant starts failing. Offboard the tenant first (revoke leases, remove
> OpenFGA tuples, offboard users).

---

## 6. VERIFY

```bash
# Vault health:
scripts/vault-health-check.sh

# Read a secret back (root token):
VAULT_TOKEN="$VAULT_ROOT_TOKEN" curl -s \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  http://localhost:8200/v1/secret/data/libcloud/<name> | jq .data.data

# Confirm the libcloud REST API can read it (read-only token):
VAULT_TOKEN="$VAULT_TOKEN" curl -s \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  http://localhost:8200/v1/secret/data/libcloud/<name> | jq .data.data
```

---

## 7. Files touched

| File / store | What changes |
|--------------|--------------|
| Vault KV (`secret/data/libcloud/<name>`) | new version / destroyed version / metadata delete |
| `generated/vault_audit.log` | one JSONL line per write / delete (via `vault_common.sh`) |

The REST API read token (`VAULT_TOKEN`) is **not** re-issued for a new
secret — it already has read on `secret/data/libcloud/*`.

---

## 8. Quick reference

| Action | Command |
|--------|---------|
| Ad-hoc write | `python3 ../vault/add_credential.py <name> --kv k=v ...` |
| Per-tenant write (owner) | `TENANT=<t> CLOUD=<c> LIBCLOUD_USER=<owner> ... python3 scripts/set_tenant_credentials.py` |
| List | `python3 ../vault/list_credentials.py` |
| Rotate static | `scripts/vault-static-secret-rotate.sh <name>` |
| Destroy current version | `python3 ../vault/delete_credential.py <name> --destroy-versions` |
| Full delete | `python3 ../vault/delete_credential.py <name> --yes` |
| Token lookup | `scripts/vault-token-lookup.sh` |
