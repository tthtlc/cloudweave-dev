# Vault AppRole internals — how the secret_id is generated, stored, and used

This document answers, with corrections, the questions originally posed in the
notes, and expands them into a complete picture using the source of record
(`vault_bootstrap.py`, `vault_client.py`, `policy.py`, `credentials.py`,
`vault/ARCHITECTURE.md`, and `SUMMARY.md`).

## 0. The one-paragraph model

There is **one** REST API service (`libcloud-rest-api`), not one API per tenant.
Vault authenticates it with a **per-tenant AppRole** named `libcloud-<tenant>`.
OpenFGA does **not** store the AppRole, the `role_id`, or the `secret_id` — it
only stores the relationship `tenant:<t> parent vault_user:libcloud-<t>` plus
the authorization tuples, and it hands the REST API the *name* of the AppRole to
use. The `secret_id` itself is minted by **Vault** at tenant
creation, returned once in plaintext, stored canonically as an HMAC digest in
the AppRole backend, and also
re-persisted in plaintext into Vault KV so the long-running REST API can re-read
it to perform the AppRole login.

---

## 1. How the secret_id is generated

- The `secret_id` is minted **once, at bootstrap / tenant creation**, by
  **Vault's AppRole backend** — never by OpenFGA and never by the client.
- The bootstrap script (`openfga_postgres/vault_bootstrap.py`) runs with the Vault
  **root token** and calls, per tenant:
  ```
  POST /v1/auth/approle/role/<role>/secret-id     # body = {}
  ```
  (`vault_bootstrap.py:287-296`). The empty body means none of the optional
  limits (`cidr_list`, `num_uses`, `ttl`, `metadata`) are set.
- Vault generates the secret_id **server-side as a cryptographically random
  value**, returns the plaintext **exactly once**, and stores only an
  **HMAC-SHA256 digest** of it (keyed by a per-mount salt).
- The full per-tenant creation sequence is:
  1. Create ACL policy `libcloud-read-<tenant>` (read-only on `secret/data/libcloud/<tenant>`).
  2. Create role `libcloud-<tenant>` (`token_ttl=60m`, `token_max_ttl=120m`).
  3. Read back the `role_id` (`GET /auth/approle/role/<role>/role-id`).
  4. Mint the `secret_id` (`POST .../secret-id`).
  5. Persist `{role_id, secret_id}` into KV at
     `secret/data/libcloud-vault-auth/libcloud-<tenant>`.

---

## 2. Where the secret_id is stored

there are **two physically distinct copies**, both on Vault's file
storage backend:

| Copy | Where | What it holds | Readable back? |
|---|---|---|---|
| **Canonical** | AppRole auth backend (`auth/approle/role/<role>/...`) | only the **HMAC digest** of the secret_id (+ metadata) | No — write-only; verify-at-login only |
| **Deployment plaintext (deviation §8.1)** | KV v2 `secret/data/libcloud-vault-auth/libcloud-<tenant>` | the **plaintext** `{role_id, secret_id}` | Yes — by the orchestrator token only |

- **"file cache" is wrong.** The digest is *not* a cache. It is Vault's
  authoritative internal record, stored in the AppRole auth backend, physically
  on the file storage backend `storage "file" { path = "/vault/file" }` →
  container `/vault/file/` → Docker volume `vault-data` →
  host `/var/lib/docker/volumes/vault-data/_data/`. Everything there is encrypted
  at rest by the barrier (unseal key).

---

## 3. Who reads the HMAC digest, and for what purpose

- The digest is read **only by Vault itself**, at login time, and only by
  **compute-and-compare** — never by retrieval (a digest cannot be reversed).
- At `POST /v1/auth/approle/login {role_id, secret_id}` Vault:
  1. Resolves the role from `role_id`.
  2. Recomputes `HMAC(salt, secret_id)` on the *presented* value.
  3. Looks up that digest among the role's secret-id entries and checks the
     metadata (not expired, `num_uses` not exhausted, `bound_cidr_list` matches).
  4. On success, mints the token (and marks the entry used if `num_uses` is set).
- **Why a digest at all:** it makes the secret_id a *write-only* credential —
  structurally unrecoverable (no read API, not even for root). The HMAC's real
  job is data-model enforcement (the plaintext simply isn't there to read); the
  stronger protection is the barrier encryption above it.

---

## 4. The role of OpenFGA 

- OpenFGA **stores none of** the AppRole, `role_id`, or `secret_id`. It is a pure
  authorization/relationship engine. It has exactly two jobs:
  1. **Authorization** — `can_connect` (API object), `can_use`
     (`provider:<provider>`), `can_read` / `can_provision` (backend object
     `<obj_type>:<tenant>`).
  2. **Name resolution** — `list_objects("vault_user", "parent", "tenant:<binding>")`
     returns `vault_user:libcloud-<tenant>`, i.e. the **name** of the AppRole to use.
- OpenFGA does **not** decide "access to Vault." It decides "may this
  `user:<slug>` act as `tenant:<t>`." Actual Vault access is governed by **Vault's
  own policies**, via the AppRole login and the resulting 60-minute tenant token
  bound to `libcloud-read-<tenant>`.
- The binding string (`aws`, `nutanix`, `aws1`, …) is the single key that ties
  the layers together: `tenant id → OpenFGA tuple → vault_user name → Vault paths`.

---

## 5. How the REST API gets and uses the secret_id

- The REST API (`vault_client.py`) performs a **two-stage** exchange:
  1. **Fetch login material** — `_auth_material()` does
     `GET /v1/secret/data/libcloud-vault-auth/<vault_user>` with the
     **orchestrator token** (`VAULT_TOKEN`), keyed by the **role name**
     (`libcloud-<tenant>`), and receives **both `role_id` and `secret_id`**
     together — not "the secret_id using the role_id."
  2. **AppRole login** — `_approle_token()` does
     `POST /v1/auth/approle/login {role_id, secret_id}` (no token header) and
     receives a 60-minute `client_token` bound to `libcloud-read-<tenant>`.
  3. **Read the secret** — `read_secret()` does
     `GET /v1/secret/data/libcloud/<tenant>` with that tenant token, returning the
     actual cloud credentials (Nutanix user/password or AWS key/secret).
- The secret_id is the **second factor** that lets the REST API *become* the
  tenant inside Vault. The orchestrator token can only hand out the login
  material; it takes the per-AppRole secret_id at `/auth/approle/login` to mint
  the tenant-scoped token.
- Two-layer least privilege:
  1. Orchestrator token → reads only `libcloud-vault-auth/*` (login material),
     never the cloud secrets.
  2. Per-tenant AppRole token → reads only its own `secret/data/libcloud/<tenant>`,
     expires after 60m.
- Caching: login material, tenant token, and secret are cached in-process
  (~30s, token cached to lease minus a 30s refresh margin), never on disk.

---

## 6. Tenants, users, and multiple providers

- **Tenants are one-to-one with a provider.** `tenant:aws` → `provider:aws`,
  `tenant:nutanix` → `provider:nutanix`, `tenant:aws1`/`aws2` → `provider:aws`
  (isolated tenants sharing the AWS provider). No tenant spans two providers.
- It is a **user** — not a tenant — who can access multiple providers, e.g.:
  - `user:int-admin` — owner + admin on **both** `tenant:aws` and `tenant:nutanix`
    (full view/provision/update on both).
  - `user:superadmin` — read-only on both clouds (global_reader), cannot provision.
- each tenant has its own
  `secret/data/libcloud-vault-auth/libcloud-<tenant>` (login material) and its own
  `secret/data/libcloud/<tenant>` (cloud credentials).

---

## 7. "Which REST API is assigned to a tenant"

- There is **no per-tenant API assignment.** There is a **single** shared
  `libcloud-rest-api` service. Per request:
  1. The client selects the tenant via `X-Provider-Connection` /
     `auth_binding` (e.g. `provider=nutanix, auth_binding=nutanix`).
  2. The **JWT provider gate** constrains which providers that principal may use
     (`principal_providers()` → `allowed_providers`).
  3. **OpenFGA** authorizes the user against that tenant's objects and resolves
     the tenant's `vault_user` name.
  4. The REST API then uses **that tenant's** AppRole to fetch the secret.

---

## 8. The full request-time flow (reference)

```
Client ──Dex JWT──▶ REST API ──▶ OpenFGA (authz + name) ──▶ Vault ──▶ Nutanix/AWS

1. AuthN       — Dex OIDC JWT.
2. AuthZ       — scope check → provider allow-list → reject client creds →
                 OpenFGA can_connect/can_use/can_read (or can_provision).
3. Resolve     — vault_user:libcloud-<tenant> from OpenFGA list_objects.
4. Fetch mat.  — GET secret/data/libcloud-vault-auth/<tenant> (orchestrator token)
                 → {role_id, secret_id}.
5. AppRole login — POST /auth/approle/login {role_id, secret_id}
                 → 60m tenant token (policy libcloud-read-<tenant>).
6. Read secret — GET secret/data/libcloud/<tenant> → cloud credentials.
```

---

## 9. Residual risks / deviations worth knowing

- **§8.1 deviation** — the plaintext `secret_id` is re-persisted into KV so the
  orchestrator token can relay it; this forfeits the native write-only property
  and makes the orchestrator token an "impersonate-any-tenant" credential.
- Committed `vault/generated/vault.env` (root token + unseal key) was the
  dominant risk; it has since been rotated and purged (see `SUMMARY.md` §11).
- Threshold-1 unseal, TLS-disabled listener, and no `num_uses`/`bound_cidr_list`/
  response-wrapping on the secret_id are further gaps (see `SUMMARY.md` §10).
