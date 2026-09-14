# Session Logs — Consolidated Summary

A point-form summary of eight exported Claude Code session logs
(`approle_secret.log1`, `vault_approle_login.log2`, `how_secret_id_is_created.log3`,
`onboarding_new_user.log4`, `openfga_gated.log5`, `saved_path.log6`,
`vault_auth_method.log7`, `where_secret_id_stored.log8`). Several of these are
near-duplicates of overlapping conversations, so the material is organized by
theme rather than repeated per file.

## 1. Vault auth model — no multi-user login, per-tenant AppRole

- Vault authenticates callers **three ways only** (token + AppRole; **no**
  userpass/LDAP/OIDC enabled):
  - `VAULT_ROOT_TOKEN` — root token from `vault operator init`; everything (admin only).
  - `VAULT_TOKEN` (orchestrator) — 768h renewable token; read-only on `secret/data/libcloud-vault-auth/*`.
  - AppRole `libcloud-<tenant>` — one per tenant; read-only on `secret/data/libcloud/<tenant>`.
- "Users" in Vault are **tenants, not humans**. Human → tenant mapping lives in OpenFGA.
- The only auth-enable call in the repo is `POST /sys/auth/approle`
  (`vault_bootstrap.py:242`); there is **no** `userpass` enable anywhere.
- Correction made across sessions: "no multi-user login" was imprecise — the
  correct statement is "no *human-account* auth method is enabled; Vault uses
  token + AppRole machine identities."

## 2. Where secrets live (three "password" families)

- **Cloud-backend secrets** → `secret/data/libcloud/<tenant>` (e.g. `aws` =
  `{key, secret}`, `nutanix` = `{user, password}`); KV v2, encrypted at rest;
  written by `set_tenant_credentials.py`, gated on OpenFGA `can_manage_credentials`.
- **Per-tenant AppRole login material** → `secret/data/libcloud-vault-auth/libcloud-<tenant>`
  = `{role_id, secret_id}`; readable only by the orchestrator token.
- **Human login passwords** → in **LLDAP** (verified by Dex at login), **not** in Vault.
- `vault/generated/vault.env` holds only `VAULT_ADDR`, `VAULT_TOKEN`,
  `VAULT_ROOT_TOKEN`, `VAULT_UNSEAL_KEY` — no human/cloud passwords (but was
  committed to git → compromised).

## 3. AppRole internals — role_id / secret_id

- AppRole = a **pair**: `role_id` (stable, non-secret "username", one per role)
  + `secret_id` (secret "password", many per role possible, but each bound to
  exactly **one** role).
- `secret_id` is **not** shared across roles — each `role_id` has its own
  `secret_id(s)`; a secret_id for role A can never log in as role B (HMAC-tied).
- The secret_id is minted server-side as a cryptographically random value; Vault
  returns plaintext **once**, then stores only an **HMAC-SHA256 digest** (keyed
  by a per-mount salt). It cannot be read back — a write-only credential.
- `vault_bootstrap.py` mints per-role secret_id via
  `POST /auth/approle/role/<role>/secret-id` with empty body `{}`.

## 4. Who creates the secret_id — NOT OpenFGA

- **OpenFGA never creates, stores, or sees the secret_id.** It has only two
  jobs: authorization (`can_connect`/`can_use`/`can_read`/`can_provision`) and
  name resolution (`list_objects("vault_user", "parent", "tenant:<binding>")` →
  `vault_user:libcloud-<tenant>`).
- The secret_id is created **once at bootstrap** by `vault_bootstrap.py` (root
  token) in `ensure_tenant_approle()`, sequence:
  1. Create ACL policy `libcloud-read-<tenant>`.
  2. Create role `libcloud-<tenant>` (`token_ttl=60m`, `token_max_ttl=120m`).
  3. Read back role_id (`GET .../role-id`).
  4. Mint secret_id (`POST .../secret-id`).
  5. Persist both into KV `secret/data/libcloud-vault-auth/libcloud-<tenant>`.
- **§8.1 deviation**: this repo re-persists the *plaintext* secret_id back into
  KV (forfeiting the pure write-only property), so the orchestrator token can
  hand it to the REST API later.

## 5. The end-to-end exchange flow (per request)

Client → Dex JWT → **REST API** → OpenFGA (authz + name) → **Vault** → Nutanix/AWS

1. AuthN — Dex OIDC JWT presented.
2. AuthZ — `authorize_connection()` (policy.py): scope check → provider check →
   reject client-supplied creds → OpenFGA checks.
3. Name resolve — `_resolve_vault_user()` → `vault_user:libcloud-<tenant>`.
4. Fetch login material — `_auth_material()` GET
   `secret/data/libcloud-vault-auth/<tenant>` (orchestrator token) → `{role_id, secret_id}`.
5. AppRole login — `_approle_token()` POST `/auth/approle/login`
   `{role_id, secret_id}` → 60-min tenant token (policy `libcloud-read-<tenant>`).
6. Read secret — `read_secret()` GET `secret/data/libcloud/<tenant>` → Nutanix
   user/password or AWS key/secret.
- Client-side code is `libcloud.rest/app/connections/vault_client.py`; actual
  verification happens in HashiCorp's upstream Go (`path_login.go` etc.), not
  vendored in this repo.

## 6. Onboarding a new user (e.g. "aaaaaaaa")

Trust chain: **LLDAP → Dex (JWT) → OpenFGA (`user:<principal>`) → Vault (shared
AppRole) → provider creds**.

- Create **only three things** at the identity/authz layer:
  - LLDAP user `uid=aaaaaaaa`, email `aaaaaaaa@libcloud.local`.
  - LLDAP groups `tenant-aws-admin`, `tenant-nutanix-admin` (must be
    `tenant-<cloud>-<role>` or the reconciler ignores them; a `cloud-admin-aws`
    naming is a known gotcha).
  - OpenFGA tuples `user:aaaaaaaa admin tenant:aws` + `user:aaaaaaaa admin tenant:nutanix`.
- **Vault / provider = no-op** — the user reuses the shared per-tenant AppRole
  and cloud credentials (not per-user).
- **Critical gotcha (JWT scope gate)**: the LLDAP uid, resolved JWT principal,
  and OpenFGA `user:<slug>` must be the **same string**, and it must carry a role
  suffix (or a `principal_map.json` entry) — otherwise `principal_scopes()`
  returns empty → `auth_user_unknown` 403 before OpenFGA is consulted.
- Alternative (own keys): that's **tenant creation**, not user onboarding
  (`create_tenant.sh` + `set_tenant_credentials.py`).
- Outputs produced: `onboard-user-runbook.md` (248 lines) +
  `onboard-user-chain.html` diagram (couldn't publish as Artifact due to
  `ANTHROPIC_AUTH_TOKEN`).

## 7. Tenant isolation & cross-provider/cross-tenant access

- Tenants are **one-to-one with a provider**; `aws`, `aws1`, `aws2`, `nutanix`
  are distinct tenants (aws1/aws2 share the AWS *provider* but are isolated).
  `TENANT_CLOUD = {"aws":"aws","aws1":"aws","aws2":"aws","nutanix":"nutanix"}`.
- **No tenant spans both AWS and Nutanix.** The only cross-provider principal is
  a **user**:
  - `user:superadmin` — read-only on both clouds (global_reader), cannot provision.
  - `user:int-admin` — a **pending/federated** user with **owner + admin on both
    `tenant:aws` and `tenant:nutanix`** (full view/provision/update on both).
- A normal cross-tenant user is possible: give them a `-owner/-admin` suffix
  outside the seeded `PRINCIPAL_PROVIDERS` table (so `principal_providers`
  returns `["*"]`), then write OpenFGA tuples on both tenants; OpenFGA becomes
  the sole boundary. Seeded `aws-*`/`ntnx-*` users are hard-pinned to one
  provider by the JWT gate.
- **`int-admin` bug**: old code stripped `int-` unconditionally (`int-admin` →
  `admin` → `user:admin`, non-existent) → verb routes 403 while `/api/session`
  showed both clouds. Fixed by `UserService._fga_principal()`: pending users keep
  full id (`user:int-admin`), LLDAP users strip `int-` (`int-aws-admin` → `user:aws-admin`).
- "Keyed by the full internal id `user:int-admin`" = OpenFGA matches the tuple's
  subject **string-verbatim**; no stripping.

## 8. Auth-method comparison (userpass vs LDAP vs OIDC vs AppRole)

- **userpass**: passwords inside Vault (bcrypt); N users = N static passwords;
  highest credential-reuse/single-password blast radius; the method that most
  directly embodies "one password → entire DB."
- **LDAP**: password in directory (LLDAP/AD); Vault stores only a bind service
  account; no proliferation; highest reuse risk (one password opens directory + Vault).
- **OIDC**: password at IdP (Dex/Okta); Vault stores only `client_id/client_secret`;
  no proliferation; IdP superuser is single point of trust.
- **AppRole**: secret_id inside Vault (machine secret); cheap disposable
  secret_ids; TTL/num_uses/CIDR bounded; lowest blast radius — chosen because
  Vault is reached by *machines*, humans are federated via LLDAP/Dex.
- **Root-token leak → whole DB**: applies to **all methods equally**; root token
  + unseal key are method-independent backdoors (relevant here because
  `vault/generated/vault.env` was committed).

## 9. `vault/APPROLE_INTERNALS.md` (in-depth article written)

- Nine sections tracing where every secret originates/travels; grounded in
  `vault_bootstrap.py`, `vault_client.py`, `policy.py`, `credentials.py`,
  `vault/ARCHITECTURE.md`.
- Flags §8.1 (secret_id plaintext round-trip) and the committed `vault.env` as
  the dominant risk.

## 10. Ten suggested missing features

1. Rotate committed root token + unseal key out of git (**implemented**).
2. Shamir key shares (5/3) or auto-unseal instead of threshold-1.
3. TLS/mTLS on the Vault listener (`tls_disable=1` today).
4. One-shot secret_id (`secret_id_num_uses=1`) + auto re-mint.
5. `bound_cidr_list` on each AppRole.
6. Response-wrapping instead of the KV round-trip for secret_id.
7. Shorten/scope the orchestrator token.
8. Vault-native audit device + tamper-evident shipping.
9. Dynamic short-lived Nutanix credentials (secrets engine).
10. Secret-broker health + token-TTL monitoring/alerting.

## 11. Task 1 implementation (committed secrets remediation) — full execution

- **Investigation findings**: `vault/generated/vault.env` + `dex/generated/dex.env`
  both git-tracked; `.gitignore` already had `**/generated/` but committed files
  stay tracked; remote `origin → github.com/tthtlc/cloudweave-dev.git`; Vault
  live/unsealed (v1.15.6, Shamir t=1 n=1).
- Created: `vault/rotate_root_and_unseal.sh`, `scripts/git-secrets-check.sh`,
  `scripts/pre-commit`, `.github/workflows/secret-scan.yml`; edited `.gitignore`
  (added `vault/generated/`, `dex/generated/`).
- Encountered a **[Fact-Forcing Gate]** (ECC_GATEGUARD) requiring a "facts
  preamble" before Write/Edit/Bash calls.
- **Executed** (after user authorized all three destructive steps):
  1. **Untrack** — `git rm --cached` both env files (committed `3654d4c`).
  2. **Live rotation** — rekeyed unseal key, rotated root + orchestrator tokens.
     Hit a **self-inflicted bug** (`ttl:"0"` produced an instantly-expired
     "root" token) → recovered via canonical `generate-root` flow (after fixing
     wrong-length OTP: server-generated OTP is 28 chars, not 24). Fixed script
     to use `generate-root`, not `token/create -policy=root`.
  3. **History purge + force-push** — `git-filter-repo` removed both files from
     all 32 commits; force-pushed `e838826…c90b696`; WIP preserved via
     `git stash -u` and restored.
- **Bug/fix cycle during work**: `GET /sys/policies/acl` → `LIST` (405 fix);
  scanner regex false-positives (`s.` collided with Python `s.client_id`) →
  tightened to `VAULT_*TOKEN=` assignment patterns + `hvs./hvr.` prefixes.
- Saved `vault/ROTATION_RUNBOOK.md` (129 lines, committed `479b5f2`, local-only).

## 12. Post-rotation 503 bug (broken resource views)

- Symptom: all Nutanix/AWS resource views (`aws-admin`, `aws1-admin`,
  `aws2-admin`, `ntnx-admin`) returned 503 `server_credentials_unavailable` /
  "Vault request failed / permission denied" on
  `secret/data/libcloud-vault-auth/libcloud-nutanix`.
- Root cause: rotation revoked the old orchestrator token; `libcloud.rest/.env`
  and `vault.env` were updated but the running `libcloud-rest-api` container
  (up 20h) still held the old revoked token.
- Fix: `docker compose -p libcloudrest -f libcloud.rest/docker-compose.yml up -d --force-recreate api`;
  verified orchestrator→auth-material→AppRole-login→secret-read all 200.
- Noted the rotation script doesn't recreate the container (that's `setup.sh`'s job).

## 13. Where the secret_id is physically stored

- **Canonical copy** — HMAC digest only, in the AppRole backend
  (`auth/approle/role/<role>/...`); no read API.
- **Deployment's plaintext copy** — KV v2 at `secret/data/libcloud-vault-auth/libcloud-<tenant>`.
- Physical location: Vault file storage `storage "file" { path = "/vault/file" }`
  → container `/vault/file/` → Docker volume `vault-data` → host
  `/var/lib/docker/volumes/vault-data/_data/`; encrypted at rest by the barrier
  (unseal key).
- Transient copies: REST API in-process cache (30s) + on the wire at login
  (plain HTTP, TLS disabled).

## 14. HMAC digest purpose & orchestrator-token mechanics

- Digest stored (not plaintext) = structural write-only enforcement; HMAC (keyed)
  not bare hash, but the salt is in the same storage, so the real protection is
  barrier encryption. Verification is compute-and-compare, never retrieval.
- The secret_id the orchestrator token reads back comes from the **KV v2
  plaintext copy**, not the digest.
- Orchestrator token policy is exactly two lines: `read` on
  `secret/data/libcloud-vault-auth/*` + `read/list` on
  `secret/metadata/libcloud-vault-auth/*` — so it can read **every tenant's**
  role_id+secret_id (impersonate-any-tenant), but **not** the cloud secrets.
- Orchestrator token stored in three client places: `vault/generated/vault.env`
  (0600, now gitignored), `libcloud.rest/.env` (synced by setup.sh), and the
  `libcloud-rest-api` container env (`env_file: .env`).
- Scalability: reading the file once at startup is fine; the real problem is
  it's a shared long-lived static credential whose blast radius multiplies with
  replicas and whose rotation needs a fleet-wide restart. Fix = per-instance
  AppRole / Vault Agent / K8s auth (short-lived, per-pod credentials).

## 15. Miscellaneous / session metadata

- Sessions ran on Claude Code v2.1.252–2.1.260, model `deepseek-v4-pro`.
- `ANTHROPIC_AUTH_TOKEN` blocked claude.ai Artifact publishing.
- A guard-bypass attempt (`ECC_GATEGUARD=off`) was correctly refused; it's an
  env var set at launch, not a chat command.
- Still-uncommitted/untracked at the end: `vault/APPROLE_INTERNALS.md`,
  presentation files (`click-to-prismv0.html`, `libcloud_nutanix_system_overviewv0.pptx`);
  the local runbook commit (`479b5f2`) was not yet pushed; and the live
  **Dex/LLDAP** superadmin credential in `dex/generated/dex.env` was **not**
  rotated (Dex is a separate system).
