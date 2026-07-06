# `./scripts/` — Complete File Documentation

> Generated from `admin_scripts.wtd` task inventory cross-reference.
> Each script is documented with: filename, functionality, required role/credentials/env vars, and mapping to the WTD task matrix.

---

## Architecture: Library Dependency Chain

```
common.sh  ←──  cloud_common.sh  ←──  cloud-*.sh (16 scripts)
    ↑              ↑
    ├── openfga_common.sh  ←──  openfga-*.sh (10 scripts)
    ├── openfga_pylib.py   ←──  openfga-tuple-*.py (2 scripts)
    ├── idp_login.py  ←──  superadmin_auth.sh, set_tenant_credentials.py, etc.
    ├── superadmin_auth.sh  ←──  create_tenant.sh
    └── verify_superadmin_jwt.py

lldap_common.sh  ←──  lldap-*.sh (11 scripts)
lldap_set_password.py  ←──  lldap-user-*.sh (4 scripts)
```

---

## Layer 1: Shared Libraries (5 files)

These are **sourced, not executed directly**. They provide the foundational functions, env loading, and API helpers that all operational scripts depend on.

---

### `common.sh`

- **Purpose:** Foundational bash library for all non-LLDAP scripting. Loads env files (`.env`, `dex.env`, `fga.env`, `authentik.env`), resolves the libcloud user password, and provides HTTP, JSON, IdP auth, OpenFGA check, and libcloud REST API helpers.
- **Key functions:** `curl_http()`, `idp_login()`, `fga_check()`, `openfga_authorization_flow()`, `libcloud_me()`, `libcloud_api()`, `build_aws_connection_param()`, `build_nutanix_connection_param()`, `teardown_libcloud_vms()`
- **Env vars loaded:** `.env`, `../dex/generated/dex.env`, `generated/authentik.env`, `generated/fga.env`
- **Requires:** `curl`, `python3`, `LIBCLOUD_OIDC_CLIENT_SECRET`, `FGA_STORE_ID`, `FGA_MODEL_ID`, Dex/Authentik URL, `LIBCLOUD_PASSWORD` (or per-role variant)
- **Used by:** All non-LLDAP scripts
- **Role:** N/A (library)

---

### `cloud_common.sh`

- **Purpose:** Shared library for the 16 cloud provisioning scripts. Sources `common.sh`, adds multi-layered bearer token resolution, provider-agnostic setup (`cloud_setup()`), API wrappers with dry-run support (`cloud_api()`, `cloud_api_or_die()`), and JSONL audit logging.
- **Key functions:** `cloud_setup()`, `cloud_api()`, `cloud_api_or_die()`, `cloud_audit()`, `cloud_provider()`, `cloud_region()`
- **Token resolution chain:** `LIBCLOUD_ACCESS_TOKEN` / `FGA_API_TOKEN` > `SUPERADMIN_JWT` > `generated/tokens/superadmin.jwt` (if not expired) > fresh Dex `idp_login`
- **Requires:** `common.sh`, `LIBCLOUD_REST_URL`, `CLOUD_PROVIDER`/`TENANT`, `CLOUD_REGION`/`AWS_REGION`
- **Used by:** All `cloud-*.sh` scripts
- **Role:** N/A (library)

---

### `lldap_common.sh`

- **Purpose:** Shared library for the 11 LLDAP admin scripts. **Independent of `common.sh`** — loads its own env files and provides LLDAP admin JWT auth, GraphQL query helpers, group/user lookups, and JSONL audit logging.
- **Key functions:** `lldap_login()`, `lldap_graphql()`, `lldap_group_id_by_name()`, `lldap_user_exists()`, `lldap_audit()`
- **Env vars loaded:** `.env`, `../lldap/.env`, `generated/dex.env`, `../vault/generated/vault.env`
- **Requires:** `curl`, `python3`, `LLDAP_URL`, `LLDAP_ADMIN_USER`, `LLDAP_LDAP_USER_PASS`
- **Used by:** All `lldap-*.sh` scripts
- **Role:** N/A (library)

---

### `openfga_common.sh`

- **Purpose:** Shared library for the 10 OpenFGA admin scripts. Sources `common.sh`, resolves an OpenFGA bearer token, and provides tuple CRUD (batched, idempotent), check, list-objects, list-users, and JSONL audit helpers.
- **Key functions:** `fga_write()`, `fga_delete()`, `fga_check()`, `fga_read_all_tuples()`, `fga_list_objects()`, `fga_list_users()`, `fga_audit()`
- **Token resolution:** `FGA_API_TOKEN` > `SUPERADMIN_JWT` > `generated/tokens/superadmin.jwt` > fresh Dex `idp_login`
- **Requires:** `common.sh`, `FGA_API_URL`, `FGA_STORE_ID`, `FGA_MODEL_ID`
- **Used by:** All `openfga-*.sh` scripts
- **Role:** N/A (library)

---

### `openfga_pylib.py`

- **Purpose:** Pure-Python (stdlib only) shared library for the OpenFGA Python tools. Provides `FgaClient` (read/write/delete/check via `urllib`), `LldapClient` (GraphQL group/user listing), the LLDAP-group-to-OpenFGA-tuple naming convention mapper, and managed-tuple predicates.
- **Key classes:** `FgaClient`, `LldapClient`, `FgaHttpError`
- **Key functions:** `bootstrap_env()`, `resolve_fga_token()`, `group_to_tuple()`, `is_managed_tuple()`, `load_map_file()`, `audit()`
- **Requires:** Python 3 stdlib, `FGA_API_URL`, `FGA_STORE_ID`, `FGA_MODEL_ID`, `LLDAP_URL`, `LLDAP_ADMIN_USER`, `LLDAP_LDAP_USER_PASS`
- **Used by:** `openfga-tuple-reconcile.py`, `openfga-tuple-audit.py`
- **Role:** N/A (library)

---

## Layer 2: Authentication & Tenant Management (5 files)

These scripts handle OIDC authentication, superadmin bootstrap, and tenant lifecycle.

---

### `idp_login.py`

- **Purpose:** Obtain an OIDC access token from Dex or Authentik via the authorization code flow. This is the **token-acquisition primitive** used by all other scripts.
- **WTD mapping:** Cross-cutting — all authenticated operations depend on it.
- **How it works:**
  1. Reads `IDP_PROVIDER` (default `dex`) to choose the login path.
  2. For Dex: builds authorize URL, starts local HTTP server on `127.0.0.1:8766`, POSTs credentials to Dex login form, captures authorization code, exchanges for tokens at `/dex/token`.
  3. For Authentik: walks Authentik flow executor API stages (identification → password → redirect), captures code, exchanges for token.
  4. Token caching: checks `generated/tokens/{user}.json` for refresh token; attempts silent refresh before full re-login.
  5. Prints `access_token` to stdout on success.
- **Env vars:** `IDP_PROVIDER` (dex|authentik), `DEX_URL`, `AUTHENTIK_URL`, `LIBCLOUD_OIDC_CLIENT_ID`, `LIBCLOUD_OIDC_CLIENT_SECRET` (**required** — exits if blank), `LIBCLOUD_OIDC_REDIRECT_URI`, `LIBCLOUD_USER`, `LIBCLOUD_PASSWORD` (**required**), `IDP_TOKEN_CACHE_DIR`, `IDP_LOGIN_VERBOSE`/`VERBOSE`
- **Binaries:** Python 3 stdlib (`urllib`, `json`, `http.server`, `threading`, `re`)
- **Role:** Cloud Owner / Cloud Admin

---

### `superadmin_auth.sh`

- **Purpose:** Login as the LLDAP `superadmin` user and export a verified `SUPERADMIN_JWT` — the bootstrap credential for Vault seeding, OpenFGA policy changes, and tenant creation.
- **WTD mapping:** Part 1.2 — OpenFGA model governance bootstrap; Part 1.3 — Vault root configuration bootstrap.
- **How it works:**
  1. Sets `LIBCLOUD_USER=superadmin`, sources `common.sh`.
  2. Resolves superadmin password from `LIBCLOUD_SUPERADMIN_PASSWORD` (from `generated/dex.env`).
  3. Invokes `idp_login.py` as superadmin, caches JWT to `generated/tokens/superadmin.jwt`.
  4. Reads JWT into `SUPERADMIN_JWT` env var and exports it.
  5. Cryptographically verifies JWT via `verify_superadmin_jwt.py`.
  6. If sourced (`source superadmin_auth.sh`), `SUPERADMIN_JWT` is exported to caller's shell.
- **Env vars:** `LIBCLOUD_SUPERADMIN_PASSWORD` (**required**, from `generated/dex.env`), `SUPERADMIN_JWT` (output)
- **Binaries:** `python3`, `grep`, `cut`, `cat`; `idp_login.py`, `verify_superadmin_jwt.py`
- **Role:** Cloud Owner only

---

### `verify_superadmin_jwt.py`

- **Purpose:** Cryptographically validate that a Dex-issued JWT belongs to the `superadmin` identity. Gates all bootstrap and tenant-creation operations.
- **WTD mapping:** Part 1.1 — identity governance guardrail.
- **How it works:**
  1. Reads `SUPERADMIN_JWT` env var.
  2. Decodes JWT header, checks `alg` is `RS256`.
  3. Fetches Dex JWKS from `{DEX_ISSUER_URL}/keys`.
  4. Verifies RS256 signature using `cryptography` library against JWKS public key.
  5. Validates claims: `iss` (issuer), `aud` (audience must contain `libcloud-rest`), `exp` (not expired), `sub`/`email` (must be `superadmin` or `superadmin@libcloud.local`).
  6. Exits 0 if valid, 1 otherwise.
- **Env vars:** `SUPERADMIN_JWT` (**required**), `DEX_URL`, `DEX_ISSUER_URL`, `DEX_JWKS_URL`, `LIBCLOUD_OIDC_CLIENT_ID`
- **Binaries:** Python 3, `cryptography` package (required for RS256 verification)
- **Role:** Called by other scripts; enforces superadmin-only access

---

### `create_tenant.sh`

- **Purpose:** Create a new per-cloud tenant with three LLDAP users (owner/admin/viewer), OpenFGA relationship tuples, and Vault credential binding.
- **WTD mapping:** Part 1.1 — LLDAP group/user creation; Part 1.2 — OpenFGA tuple writes; Part 1.3 — Vault credential path setup.
- **How it works:**
  1. Validates `TENANT` and `CLOUD` (aws|nutanix) env vars.
  2. If `SUPERADMIN_JWT` not set, sources `superadmin_auth.sh`; verifies JWT.
  3. Generates passwords for owner/admin/viewer (or uses `LIBCLOUD_PASSWORD_{TENANT}_{ROLE}` env vars).
  4. Creates 3 LLDAP users via `docker compose exec lldap-tools`.
  5. Persists usernames + passwords to `generated/dex.env`.
  6. Writes 8 OpenFGA tuples: `user:superadmin → owner → tenant:{TENANT}`, `user:{owner} → owner → tenant:{TENANT}`, `user:{admin} → admin → tenant:{TENANT}`, `user:{viewer} → viewer → tenant:{TENANT}`, `tenant:{TENANT} → parent → libcloud_api:main`, `tenant:{TENANT} → parent → provider:{CLOUD}`, `provider:{CLOUD} → provider → {BACKEND_TYPE}:{TENANT}`, `tenant:{TENANT} → tenant → {BACKEND_TYPE}:{TENANT}`
  7. Prints summary with all usernames, passwords, and Vault path.
- **Env vars:** `TENANT` (**required**), `CLOUD` (**required**, aws|nutanix), `SUPERADMIN_JWT` (auto-acquired if missing), `FGA_API_URL`, `FGA_STORE_ID`, `FGA_MODEL_ID`, Docker
- **Binaries:** `python3`, `curl`, `sed`, `grep`, `cut`, `tr`, `docker compose`
- **Role:** Cloud Owner only (gated by superadmin JWT verification)

---

### `set_tenant_credentials.py`

- **Purpose:** Write a tenant's cloud credentials (AWS key/secret or Nutanix user/password) into Vault KV v2 at `secret/data/libcloud/{TENANT}`, **gated by an OpenFGA `can_manage_credentials` check**.
- **WTD mapping:** Part 1.3 — Vault credential binding; Part 2.4 — Vault credential operations.
- **How it works:**
  1. Reads `TENANT`, `CLOUD`, `LIBCLOUD_USER`, `LIBCLOUD_PASSWORD` from env.
  2. Collects cloud credentials: `LIBCLOUD_AWS_KEY`/`LIBCLOUD_AWS_SECRET` for AWS; `LIBCLOUD_NTNX_USER`/`LIBCLOUD_NTNX_PASSWORD` for Nutanix. Credentials never read from `.env` files.
  3. Authenticates via `idp_login.py` subprocess to prove caller identity.
  4. OpenFGA Check: `user:{LIBCLOUD_USER}`, relation `can_manage_credentials`, object `tenant:{TENANT}`. If `allowed=false`, exits 3.
  5. Writes credentials to Vault: `POST {VAULT_ADDR}/v1/secret/data/libcloud/{TENANT}` with root token.
- **Env vars:** `TENANT` (**required**), `CLOUD` (**required**), `LIBCLOUD_USER` (**required**), `LIBCLOUD_PASSWORD` (**required**), `LIBCLOUD_AWS_KEY`/`LIBCLOUD_AWS_SECRET` (for AWS) or `LIBCLOUD_NTNX_USER`/`LIBCLOUD_NTNX_PASSWORD` (for Nutanix), `VAULT_ROOT_TOKEN`, `FGA_API_URL`/`FGA_STORE_ID`/`FGA_MODEL_ID`
- **Binaries:** Python 3 stdlib
- **Role:** Tenant Owner (or superadmin via break-glass)

---

## Layer 3: LLDAP Identity Scripts (12 files)

All source `lldap_common.sh` (except `lldap_set_password.py`). All require `curl`, `python3`, and the LLDAP admin password.

---

### `lldap_set_password.py`

- **Purpose:** Set a user's `userPassword` in LLDAP via raw LDAP ModifyRequest (BER/ASN.1 encoding over TCP). **Foundational primitive** — no external LDAP tools needed.
- **WTD mapping:** Part 2.1 — password reset.
- **How it works:**
  1. Opens TCP socket to LLDAP's LDAP port (default `localhost:3890`).
  2. Binds as admin DN (simple auth).
  3. Sends ModifyRequest (APPLICATION 6) replacing `userPassword` with plaintext (LLDAP hashes server-side).
  4. Reads ModifyResponse, checks result code (0 = success).
  5. Sends UnbindRequest, closes connection.
- **Env vars:** `LLDAP_LDAP_HOST`, `LLDAP_LDAP_PORT`, `LLDAP_BIND_DN` (**required**), `LLDAP_BIND_PW` (**required**), `LLDAP_USER_DN` (**required**), `LLDAP_NEW_PW` (**required**)
- **Binaries:** Python 3 stdlib only (`os`, `socket`, `sys`)
- **Role:** Lower-level helper; invoked by shell scripts, not directly by humans

---

### `lldap-user-onboard.sh`

- **Purpose:** Create a new LLDAP user account and set initial password. Idempotent (`--skip-if-exists`).
- **WTD mapping:** Part 2.1 — "Add a new user to LLDAP (create account, set password)."
- **How it works:**
  1. Parses `--username`, `--display-name`, `--email`, `--password`, `--first-name`, `--last-name` (or `--file PATH`).
  2. Authenticates to LLDAP via `POST /auth/simple/login`.
  3. Sends `createUser` GraphQL mutation.
  4. On success, calls `lldap_set_password.py` to set initial password via LDAP ModifyRequest.
  5. Emits audit entry. Does NOT assign groups (left to `lldap-group-add-member.sh`).
- **Env vars:** `LLDAP_URL`, `LLDAP_ADMIN_USER`, `LLDAP_LDAP_USER_PASS` (**required**), `LLDAP_LDAP_BASE_DN`, `LLDAP_LDAP_HOST`, `LLDAP_LDAP_PORT`, `LLDAP_AUDIT_LOG`, `LLDAP_ONBOARD_ACTOR`
- **Binaries:** `curl`, `python3`
- **Role:** Cloud Admin

---

### `lldap-user-offboard.sh`

- **Purpose:** Remove user from all groups + scramble password. Step 1 of the offboarding chain (OpenFGA tuple cleanup and Vault revocation happen in later steps).
- **WTD mapping:** Part 2.1 — "Remove user from groups / disable account."
- **How it works:**
  1. Validates `--username`; refuses to offboard the LLDAP admin.
  2. Authenticates, confirms user exists, fetches group memberships via GraphQL.
  3. Iterates over each group, calls `removeUserFromGroup` mutation.
  4. Unless `--keep-password`, generates random 32-char password and scrambles via `lldap_set_password.py`.
  5. Emits audit entries.
- **Exit codes:** 0 (success), 2 (validation), 3 (auth), 4 (GraphQL), 5 (network), 6 (groups removed but password scramble failed)
- **Env vars:** (via `lldap_common.sh`) `LLDAP_URL`, `LLDAP_ADMIN_USER`, `LLDAP_LDAP_USER_PASS`, `LLDAP_BASE_DN`, `LLDAP_LDAP_HOST`, `LLDAP_LDAP_PORT`, `LLDAP_AUDIT_LOG`, `ACTOR`
- **Binaries:** `curl`, `python3`, `mktemp`
- **Role:** Cloud Admin

---

### `lldap-user-password-reset.sh`

- **Purpose:** Reset an LLDAP user's password to a generated (or supplied) value. Password printed exactly once for secure hand-off; never written to audit log.
- **WTD mapping:** Part 2.1 — "Reset a user's LLDAP password."
- **How it works:**
  1. Accepts `--username` and optional `--password` (generates 32 random chars if not supplied).
  2. Authenticates, verifies user exists.
  3. Calls `lldap_set_password.py` to set the new password via LDAP.
  4. Prints new password to stdout once; emits audit entry (without password).
- **Exit codes:** 0 (success), 2 (validation/unknown user), 3 (auth), 4 (LDAP modify), 5 (network)
- **Env vars:** (via `lldap_common.sh`) Same as offboard
- **Binaries:** `curl`, `python3`
- **Role:** Cloud Admin

---

### `lldap-user-list-groups.sh`

- **Purpose:** List all LLDAP groups a user belongs to. Used for access reviews.
- **WTD mapping:** Part 2.1 — access review.
- **How it works:**
  1. Accepts `--username`, `--format json|table`.
  2. Authenticates, verifies user exists.
  3. GraphQL query: `{ user(userId: "...") { id email displayName groups { id displayName } } }`.
  4. Formats output as JSON or table.
- **Env vars:** (via `lldap_common.sh`) `LLDAP_URL`, `LLDAP_ADMIN_USER`, `LLDAP_LDAP_USER_PASS`
- **Binaries:** `curl`, `python3`, `mktemp`
- **Role:** Cloud Admin or Cloud Owner (read-only)

---

### `lldap-group-create.sh`

- **Purpose:** Create a new LLDAP group. Idempotent. Enforces naming convention (lowercase alphanumeric + dash/underscore; must contain at least one dash unless `--force`).
- **WTD mapping:** Part 2.1 — group creation.
- **How it works:**
  1. Accepts `--name`, `--force`, `--dry-run`.
  2. Authenticates, checks idempotency via `lldap_group_id_by_name`.
  3. Sends `createGroup(name: "...")` GraphQL mutation.
  4. Emits audit entry.
- **Exit codes:** 0 (created or already existed), 2 (validation), 3 (auth), 4 (GraphQL), 5 (network)
- **Env vars:** (via `lldap_common.sh`) `LLDAP_URL`, `LLDAP_ADMIN_USER`, `LLDAP_LDAP_USER_PASS`, `LLDAP_AUDIT_LOG`, `ACTOR`
- **Binaries:** `curl`, `python3`, `mktemp`, `awk`
- **Role:** Cloud Admin

---

### `lldap-group-delete.sh`

- **Purpose:** Delete an LLDAP group. Refuses if group has members (unless `--force` with interactive confirmation). Protects built-in management groups (`lldap_admin`, `lldap_password_manager`, `lldap_strict_readonly`).
- **WTD mapping:** Part 2.1 — group lifecycle.
- **How it works:**
  1. Accepts `--name`, `--force`, `--dry-run`.
  2. Validates group name; refuses built-in groups.
  3. Authenticates, resolves group to ID. If not found, exits 0 (idempotent).
  4. Queries member count; if > 0 and no `--force`, refuses.
  5. Sends `deleteGroup(groupId: ...)` mutation.
  6. Emits audit entry.
- **Exit codes:** 0 (deleted/not found), 2 (validation/populated/protected), 3 (auth), 4 (GraphQL), 5 (network)
- **Env vars:** (via `lldap_common.sh`) Same as group-create
- **Binaries:** `curl`, `python3`, `mktemp`
- **Role:** Cloud Admin

---

### `lldap-group-add-member.sh`

- **Purpose:** Add user to LLDAP group, then **trigger OpenFGA reconciler** to sync the membership into tuples.
- **WTD mapping:** Part 2.1 — "Assign user to role-groups"; Part 2.2 — tuple write (via reconciler trigger).
- **How it works:**
  1. Accepts `--user`, `--group`, `--dry-run`.
  2. Authenticates, verifies user and group exist.
  3. Sends `addUserToGroup(userId: "...", groupId: ...)` mutation.
  4. "Already member" treated as non-error (idempotent).
  5. Emits audit entry.
  6. If `LLDAP_RECONCILE_CMD` is set (default: `python3 scripts/openfga-tuple-reconcile.py`), triggers it.
- **Env vars:** (via `lldap_common.sh`) Same as above + `LLDAP_RECONCILE_CMD`
- **Binaries:** `curl`, `python3`, `mktemp`
- **Role:** Cloud Admin

---

### `lldap-group-remove-member.sh`

- **Purpose:** Remove user from LLDAP group, then **trigger OpenFGA reconciler** to delete stale tuples. Idempotent.
- **WTD mapping:** Part 2.1 — role removal; Part 2.2 — tuple delete (via reconciler).
- **How it works:**
  1. Accepts `--user`, `--group`, `--dry-run`.
  2. Authenticates, verifies user and group exist.
  3. Checks current membership; if not a member, exits 0 (idempotent).
  4. Sends `removeUserFromGroup` mutation.
  5. Emits audit entry.
  6. Triggers OpenFGA reconciler (same mechanism as add-member).
- **Env vars:** (via `lldap_common.sh`) Same as add-member
- **Binaries:** `curl`, `python3`, `mktemp`
- **Role:** Cloud Admin

---

### `lldap-group-list-members.sh`

- **Purpose:** List all members of a given LLDAP group. Used for access reviews.
- **WTD mapping:** Part 2.1 — "List users in a group (access review)."
- **How it works:**
  1. Accepts `--group`, `--format json|table`.
  2. Authenticates, resolves group name to ID.
  3. GraphQL query: `{ group(groupId: ...) { id displayName users { id email displayName } } }`.
  4. Formats output as JSON or table.
- **Env vars:** (via `lldap_common.sh`) `LLDAP_URL`, `LLDAP_ADMIN_USER`, `LLDAP_LDAP_USER_PASS`
- **Binaries:** `curl`, `python3`, `mktemp`
- **Role:** Cloud Admin or Cloud Owner (read-only)

---

### `lldap-audit-all-memberships.sh`

- **Purpose:** Dump full LLDAP group-to-member matrix to a dated CSV. Monthly access-review artifact.
- **WTD mapping:** Part 1.1 — "Audit group memberships (monthly)."
- **How it works:**
  1. Accepts `--out PATH` (default `generated/audit/lldap_memberships_<date>.csv`), `--stdout`.
  2. Authenticates, fetches all groups with members via GraphQL.
  3. Python generates CSV: columns `generated_at, group_id, group_name, user_id, user_email, user_displayname, membership`.
  4. Empty groups emit `EMPTY_GROUP` row; populated groups emit `MEMBER` row per member.
- **Env vars:** (via `lldap_common.sh`) `LLDAP_URL`, `LLDAP_ADMIN_USER`, `LLDAP_LDAP_USER_PASS`, `LLDAP_AUDIT_LOG`, `ACTOR`
- **Binaries:** `curl`, `python3`, `mktemp`
- **Role:** Cloud Admin or Cloud Owner (read-only audit)

---

### `lldap-admin-cred-rotate.sh`

- **Purpose:** Rotate the LLDAP admin bind password: generate new → update LLDAP via LDAP → verify → persist to Vault KV v2 → optionally rewrite `../lldap/.env`.
- **WTD mapping:** Part 1.1 — "Rotate LLDAP admin credentials (quarterly)."
- **How it works:**
  1. Generates new 32-char random password.
  2. Calls `lldap_set_password.py` with old bind password to replace admin's own `userPassword`.
  3. Verifies by logging into LLDAP with new password.
  4. Writes to Vault at `secret/data/lldap/admin` (configurable).
  5. Optionally rewrites `../lldap/.env` replacing `LLDAP_LDAP_USER_PASS` line.
  6. New password never printed unless `--print-password`.
- **Exit codes:** 0 (rotated/verified/persisted), 2 (precondition), 3 (old bind fail), 4 (LDAP update fail), 5 (verify fail), 6 (Vault write fail), 7 (`.env` rewrite fail)
- **Env vars:** `LLDAP_URL`, `LLDAP_ADMIN_USER`, `LLDAP_LDAP_USER_PASS`, `LLDAP_BASE_DN`, `LLDAP_LDAP_HOST`, `LLDAP_LDAP_PORT`, `VAULT_ADDR`, `VAULT_ROOT_TOKEN` (**required**), `LLDAP_ROTATE_VAULT_PATH`, `LLDAP_ROTATE_UPDATE_ENV`
- **Binaries:** `curl`, `python3`, `mktemp`
- **Role:** Cloud Admin (holder of both LLDAP admin credential and Vault root token)

---

## Layer 4: OpenFGA Authorization Scripts (11 files)

All bash scripts source `openfga_common.sh` → `common.sh`. All Python scripts import `openfga_pylib`. All require `FGA_API_URL`, `FGA_STORE_ID`, `FGA_MODEL_ID`.

---

### `openfga-check.sh`

- **Purpose:** Single OpenFGA `Check()` call. Tests whether a user has a specific relation on an object.
- **WTD mapping:** Part 2.2 — "Verify access before a provisioning action (dry-run check)."
- **How it works:**
  1. Parses `<user> <relation> <object>`.
  2. Calls `fga_check()` (POST to `/stores/{id}/check`).
  3. On success, prints `allowed=true|false`; exits 0 if allowed, 1 if denied.
  4. Emits JSONL audit record regardless of outcome.
- **Options:** `--json` (raw response), `--actor`
- **Role:** Cloud Admin (read-only)

---

### `openfga-list-objects.sh`

- **Purpose:** List all objects of a given type that a user has a relation to.
- **WTD mapping:** Part 2.2 — "List all objects a user has access to."
- **How it works:**
  1. Parses `<user> <relation> <type>`.
  2. Calls `fga_list_objects()` (POST to `/stores/{id}/list-objects`).
  3. Outputs JSON array; `--table` for newline-separated IDs.
  4. Emits audit record with count.
- **Options:** `--table`, `--actor`
- **Role:** Cloud Admin (read-only)

---

### `openfga-list-users.sh`

- **Purpose:** List all users who have a relation on an object (reverse of ListObjects).
- **WTD mapping:** Part 2.2 — "List all users who have access to a specific resource."
- **How it works:**
  1. Parses `<relation> <object> [user_type]` (user_type defaults to `"user"`).
  2. Calls `fga_list_users()` (POST to `/stores/{id}/list-users`).
  3. Outputs JSON array; `--table` for `type:id` per line.
  4. Emits audit record with count.
- **Options:** `--table`, `--actor`
- **Role:** Cloud Admin (read-only)

---

### `openfga-tuple-write.sh`

- **Purpose:** Write one or more OpenFGA relationship tuples. Batched, idempotent. Primary tool for granting authorizations.
- **WTD mapping:** Part 2.2 — "Write access tuple when user joins a role."
- **How it works:**
  1. Accepts triples: `<user> <relation> <object> [more...]` (must be multiple of 3).
  2. Validates each triple (user/object: `type:id`, relation: `^[a-z_]+$`).
  3. Builds batched write payload with `FGA_MODEL_ID`.
  4. Calls `fga_write()` (POST to `/stores/{id}/write` with `writes` block).
  5. Emits audit record per triple.
- **Options:** `--dry-run`, `--actor`
- **Role:** Cloud Admin (mutates authorization state)

---

### `openfga-tuple-delete.sh`

- **Purpose:** Delete relationship tuples. Batched, idempotent. **Safety guard:** structural/infra tuples (`parent`, `provider`, `tenant` relations or `platform:*` objects) require `--confirm`.
- **WTD mapping:** Part 2.2 — "Delete access tuple when user leaves a role."
- **How it works:**
  1. Accepts triples as positional args.
  2. Validates each triple.
  3. `is_protected()` check: if relation is `parent`/`provider`/`tenant` or object starts with `platform:`, and no `--confirm`, refuses with exit 3.
  4. Builds batched delete payload (same `/stores/{id}/write` endpoint with `deletes` block).
  5. Emits audit record per triple.
- **Options:** `--dry-run`, `--confirm`, `--actor`
- **Role:** Cloud Admin (mutates authorization state; guardrails protect structural tuples)

---

### `openfga-tuple-audit.py`

- **Purpose:** Dump all OpenFGA tuples → CSV, cross-reference against LLDAP group memberships. Classifies each tuple as `infra`, `managed-ok`, `orphan`, `unknown`, or `missing`.
- **WTD mapping:** Part 1.2 — "Audit relationship tuples in the FGA store (monthly/post-incident)."
- **How it works:**
  1. Loads env via `openfga_pylib.bootstrap_env()`.
  2. Reads all OpenFGA tuples via `FgaClient.read_all_tuples()` (paginated).
  3. Reads all LLDAP groups with members via `LldapClient` (GraphQL).
  4. Maps LLDAP groups to expected tuples using naming convention or `--map-file`.
  5. Classifies each tuple; reports missing (LLDAP memberships with no OpenFGA tuple).
  6. Writes CSV to `generated/audit/openfga_tuples_<date>.csv`.
  7. Prints JSON summary to stderr; emits audit record.
- **Options:** `--out PATH`, `--stdout`, `--map-file PATH`, `--actor`
- **Requires also:** `openfga_pylib.py`, `LLDAP_URL`, `LLDAP_ADMIN_USER`, `LLDAP_LDAP_USER_PASS`
- **Binaries:** `python3`
- **Role:** Cloud Admin (read-only audit)

---

### `openfga-tuple-reconcile.py`

- **Purpose:** Synchronize LLDAP group memberships into OpenFGA tuples. `--additive` writes missing; `--full` also deletes stale managed tuples. **Never touches structural/infra tuples.**
- **WTD mapping:** Part 4 — "LLDAP → OpenFGA reconciler (scheduled cron, every 5 min + on group-change event)."
- **How it works:**
  1. Loads env, connects to LLDAP and OpenFGA.
  2. Maps LLDAP groups to expected tuples via naming convention.
  3. Reads all current OpenFGA managed tuples.
  4. Computes diff: `missing = expected - current_managed`, `stale = current_managed - expected`.
  5. `--additive` mode: writes missing tuples only.
  6. `--full` mode: writes missing + deletes stale (requires `--yes`).
  7. `--dry-run`: prints plan without mutation.
  8. Emits audit records for each write/delete + summary record.
- **Options:** `--additive` (default), `--full`, `--dry-run`, `--yes`, `--map-file PATH`, `--actor`
- **Requires also:** `openfga_pylib.py`, `LLDAP_URL`, `LLDAP_ADMIN_USER`, `LLDAP_LDAP_USER_PASS`
- **Binaries:** `python3`
- **Role:** Cloud Admin (mutates tuples; `--full --yes` is destructive)

---

### `openfga-breakglass-grant.sh`

- **Purpose:** Grant time-bounded elevated access (1–480 min TTL). Writes tuple, logs grant, spawns background process that auto-deletes after TTL. Mandatory `--reason` for audit trail.
- **WTD mapping:** Part 2.2 — "Grant temporary elevated access (break-glass) for a specific resource."
- **How it works:**
  1. Requires `--user`, `--relation`, `--object`, `--ttl MINUTES` (1–480), `--reason`.
  2. Generates unique `GRANT_ID`.
  3. Writes break-glass tuple via `fga_write()`.
  4. Records grant to `generated/openfga_breakglass.log` + standard FGA audit log.
  5. Forks `nohup` background process: sleep TTL minutes → call `openfga-tuple-delete.sh` → log auto-deletion → clean up pidfile.
  6. Stores PID in `generated/breakglass/<GRANT_ID>.pid`.
- **Options:** `--dry-run`, `--actor`
- **Safety features:** TTL capped at 480 min (8h), mandatory reason, auto-revocation, dual audit trails
- **Role:** Cloud Admin (privileged emergency operation)

---

### `openfga-denial-log-query.sh`

- **Purpose:** Aggregate authorization denial events from 3 sources over the last N hours: (1) libcloud REST auth audit log, (2) REST HTTP access log (403s), (3) OpenFGA audit log (check + result=false).
- **WTD mapping:** Part 2.5 — "Review OpenFGA authorization denial logs for unexpected blocks."
- **How it works:**
  1. Parses `--hours N` (default 1), `--json`.
  2. Source 1: `docker exec` into REST container, reads `/app/data/auth_audit.log`, filters denial-ish JSONL lines.
  3. Source 2: `docker logs --since Nh` on REST container, greps for ` 403 ` patterns.
  4. Source 3: reads `generated/openfga_audit.log`, filters `action=check` + `result=false`.
  5. Python merges, deduplicates, sorts by timestamp.
  6. Outputs table or JSON; emits own audit record.
- **Options:** `--hours N`, `--json`, `--actor`
- **Requires also:** `docker exec`/`docker logs` access to `$LIBCLOUD_REST_CONTAINER`
- **Role:** Cloud Admin (troubleshooting and incident investigation)

---

### `openfga-presharedkey-rotate.sh`

- **Purpose:** Rotate the OpenFGA preshared API key. Generate new 256-bit key → store in Vault → update OpenFGA `.env` + libcloud REST `.env` → optionally `--apply` (restart containers + health check).
- **WTD mapping:** Part 1.2 — "Rotate OpenFGA preshared keys (quarterly)."
- **How it works:**
  1. Generates 64-hex-char key via `openssl rand -hex 32` (fallback: Python `secrets.token_hex(32)`).
  2. Writes to Vault KV v2 at `secret/data/openfga/apikey`.
  3. Verifies round-trip read-back from Vault.
  4. Updates `../openfga/.env` (`OPENFGA_AUTHN_PRESHARED_KEYS`) and `../libcloud.rest/.env` (`FGA_API_TOKEN`).
  5. Without `--apply`: prints docker restart instructions; no disruption.
  6. With `--apply`: `docker restart` both containers, sleep 5s, health-check both endpoints.
- **Options:** `--apply`, `--dry-run`, `--vault-token TOKEN`, `--vault-path PATH`, `--actor`
- **Requires also:** `VAULT_ROOT_TOKEN`, `openssl`, `docker`, write access to `../openfga/.env` and `../libcloud.rest/.env`
- **Role:** Cloud Owner only (highest privilege — rotates shared secrets + restarts production containers)

---

### `openfga_ensure_fresh.sh`

- **Purpose:** Restart OpenFGA container to force fresh OIDC JWKS fetch after Dex signing-key rotation. Auto-sourced by `common.sh`; throttled to once per hour.
- **WTD mapping:** Part 2.5 — operational health (prevents `invalid_claims` failures).
- **How it works:**
  1. Checks `OPENFGA_SKIP_RESTART=1` — skips if set.
  2. Throttle: reads marker file `generated/.openfga_jwks_refreshed_at`; skips if within `OPENFGA_JWKS_REFRESH_TTL_SEC` (default 3600s) unless `OPENFGA_FORCE_RESTART=1`.
  3. `docker restart <container>` (default name `openfga`).
  4. Polls `FGA_API_URL/healthz` up to 30 times (1s intervals).
  5. On success, writes epoch to marker file.
  6. Always exits 0 (warnings only, never aborts caller).
- **Env vars:** `OPENFGA_SKIP_RESTART`, `OPENFGA_FORCE_RESTART`, `OPENFGA_JWKS_REFRESH_TTL_SEC`, `OPENFGA_CONTAINER`, `FGA_API_URL`
- **Binaries:** `docker`, `curl`, `date`, `stat`
- **Role:** Auto-executed; can be run standalone by Cloud Admin

---

## Layer 5: Cloud Provisioning Scripts (22 files)

### Generic Cloud Scripts (16 files)

All source `cloud_common.sh` → `common.sh`. All require `LIBCLOUD_REST_URL`, `CLOUD_PROVIDER`/`TENANT`, `CLOUD_REGION`, `ACCESS_TOKEN` (resolved by `cloud_common.sh`), `python3`, `curl`.

---

### `cloud-node-list.sh`

- **Purpose:** List compute nodes (VMs/instances) for a provider/region.
- **WTD mapping:** Part 2.3 — "List all running nodes and their state."
- **How it works:** `cloud_setup()` → `GET /v1/compute/nodes` → Python filters by `--filter NAME` and formats as JSON or table (id, name, state, size, public_ip, private_ip).
- **Options:** `--provider`, `--region`, `--filter NAME`, `--format json|table`
- **Role:** Read-only — any authenticated user with `can_read`

---

### `cloud-node-provision.sh`

- **Purpose:** Provision a new compute instance. Idempotent by name (`--force` overrides).
- **WTD mapping:** Part 2.3 — "Provision a new VM / compute instance."
- **How it works:** Idempotency check → builds body from `--param-file` or flags (`--name`, `--image`, `--size`, `--subnet`, `--location`, `--no-public-ip`) → injects connection → `POST /v1/compute/nodes` → audits.
- **Options:** `--name`, `--image`, `--size`, `--subnet`, `--location`, `--no-public-ip`, `--param-file`, `--provider`, `--region`, `--force`, `--dry-run`
- **Role:** Mutating — requires `can_provision`. Cloud Admin.

---

### `cloud-node-action.sh`

- **Purpose:** Perform lifecycle actions: start, stop, reboot, or destroy a node.
- **WTD mapping:** Part 2.3 — "Start / stop / reboot / destroy an existing node."
- **How it works:** Resolves node ID (name→ID lookup) → maps action to REST endpoint (`:start`, `:stop`, `:reboot` via POST; `destroy` via DELETE, requires `--confirm`) → audits.
- **Options:** `--node ID|NAME`, `--action start|stop|reboot|destroy`, `--confirm` (required for destroy), `--provider`, `--region`, `--dry-run`
- **Role:** Mutating — requires `can_provision`. Cloud Admin.

---

### `cloud-image-list.sh`

- **Purpose:** List available OS images, filterable by family, architecture, and name glob.
- **WTD mapping:** Part 2.3 — "List available images for a provider."
- **How it works:** `GET /v1/compute/images` (with `?name=` for AWS) → Python filters by `--family`, `--arch`, `--name-filter` → table (id, name, os, arch, size_gb) or JSON.
- **Options:** `--family`, `--arch x86_64|arm64`, `--name-filter`, `--provider`, `--region`, `--format`
- **Role:** Read-only — any authenticated user

---

### `cloud-size-list.sh`

- **Purpose:** List available instance sizes/flavors.
- **WTD mapping:** Part 2.3 — "List available instance sizes for a provider."
- **How it works:** `GET /v1/compute/sizes` → Python formats as table (id, name, cpu, ram_mib, disk_gb, price) or JSON.
- **Options:** `--format json|table`, `--provider`, `--region`
- **Role:** Read-only

---

### `cloud-network-list.sh`

- **Purpose:** List networks and subnets.
- **WTD mapping:** Part 2.3 — "List available VPCs, subnets, and zones."
- **How it works:** `GET /v1/compute/networks` + `GET /v1/compute/subnets` → Python merges and formats both tables (id, name, cidr, vpc, target) or combined JSON.
- **Options:** `--format`, `--provider`, `--region`
- **Role:** Read-only

---

### `cloud-keypair-manage.sh`

- **Purpose:** List, create, or delete SSH key pairs.
- **WTD mapping:** Part 2.3 — "Manage SSH key pairs (upload, list, delete)."
- **How it works:**
  - `list`: `GET /v1/compute/key-pairs` → name + fingerprint table.
  - `create`: `POST /v1/compute/key-pairs` with optional `--public-key` file.
  - `delete`: `DELETE /v1/compute/key-pairs/{name}` (requires `--confirm`).
- **Options:** `--action list|create|delete`, `--name`, `--public-key PATH`, `--confirm`, `--dry-run`
- **Role:** List = read-only; Create/Delete = `can_provision` required. Cloud Admin.

---

### `cloud-storage-bucket-create.sh`

- **Purpose:** Create an object-storage bucket. Idempotent.
- **WTD mapping:** Part 2.3 — "Create object storage buckets."
- **How it works:** Builds body from `--name`, `--location`, `--tag k=v` → injects connection → `POST /v1/storage/buckets` → audits.
- **Options:** `--name`, `--location`, `--tag k=v`, `--dry-run`
- **Role:** Mutating — `can_provision` required. Cloud Admin.

---

### `cloud-storage-bucket-delete.sh`

- **Purpose:** Delete a storage bucket. `--force` empties bucket first (lists and deletes all objects).
- **WTD mapping:** Part 2.3 — "Delete object storage buckets."
- **How it works:** Requires `--confirm` → with `--force`, lists objects and deletes each → `DELETE /v1/storage/buckets/{name}` → handles `bucket_not_empty` gracefully.
- **Options:** `--name`, `--force`, `--confirm`, `--dry-run`
- **Role:** Mutating (destroy) — `can_provision`. Cloud Admin.

---

### `cloud-storage-bucket-list.sh`

- **Purpose:** List all object-storage buckets.
- **WTD mapping:** Part 2.3 — "List buckets and their metadata."
- **How it works:** `GET /v1/storage/buckets` → Python table (name, provider, target, created) or JSON.
- **Options:** `--format`, `--provider`, `--region`
- **Role:** Read-only

---

### `cloud-storage-object-upload.sh`

- **Purpose:** Upload an object (file) to a bucket. File is base64-encoded in JSON body.
- **WTD mapping:** Part 2.3 — "Upload objects."
- **How it works:** Reads `--file`, base64-encodes → builds body with `--bucket`, `--key`, `--content-type`, `--meta k=v` → injects connection → `POST /v1/storage/buckets/{bucket}/objects` → audits.
- **Options:** `--bucket`, `--key`, `--file`, `--content-type`, `--meta k=v`, `--param-file`, `--dry-run`
- **Role:** Mutating — `can_provision`. Cloud Admin.
- **Requires also:** `base64` CLI

---

### `cloud-storage-object-download.sh`

- **Purpose:** Download an object from a bucket. Base64-decodes response.
- **WTD mapping:** Part 2.3 — "Download objects."
- **How it works:** `POST /v1/storage/buckets/{bucket}/objects/{key}:download` → extracts `data_b64`, decodes, writes to `--out` path.
- **Options:** `--bucket`, `--key`, `--out PATH`, `--dry-run`
- **Role:** Read scope. Any authenticated user.

---

### `cloud-volume-list.sh`

- **Purpose:** List block-storage volumes.
- **WTD mapping:** Part 2.3 — storage volumes.
- **How it works:** `GET /v1/compute/volumes` → Python table (id, name, state, size_gb, target) or JSON.
- **Options:** `--format`, `--provider`, `--region`
- **Role:** Read-only

---

### `cloud-floatingip-allocate.sh`

- **Purpose:** Allocate a floating (elastic) IP address.
- **WTD mapping:** Part 2.3 — "Allocate floating IPs."
- **How it works:** Builds body with `--domain vpc|standard` → injects connection → `POST /v1/compute/floating-ips` → logs allocated address.
- **Options:** `--domain vpc|standard`, `--dry-run`
- **Role:** Mutating — `can_provision`. Cloud Admin.

---

### `cloud-floatingip-list.sh`

- **Purpose:** List floating IPs, optionally filtered by address.
- **WTD mapping:** Part 2.3 — networking.
- **How it works:** `GET /v1/compute/floating-ips` (with `?address=`) → Python table (address, domain, associated, instance_id, target) or JSON.
- **Options:** `--address IP`, `--format`
- **Role:** Read-only

---

### `cloud-floatingip-release.sh`

- **Purpose:** Release (deallocate) a floating IP address.
- **WTD mapping:** Part 2.3 — "Release floating IPs."
- **How it works:** Requires `--confirm` → `DELETE /v1/compute/floating-ips/{address}` (with `?domain=`).
- **Options:** `--address`, `--domain`, `--confirm`, `--dry-run`
- **Role:** Mutating (destroy) — `can_provision`. Cloud Admin.

---

### Provider-Specific Scripts (6 files)

---

### `provision_aws.sh`

- **Purpose:** End-to-end AWS provisioning demo. Catalog discovery → node listing → optional VM provision → optional teardown.
- **WTD mapping:** Part 2.3 — compute provisioning (full workflow demo).
- **How it works:**
  1. Sources `common.sh` directly.
  2. `idp_login()` → build AWS connection → `libcloud_me()` + connection test.
  3. Discovers catalog: locations, sizes, images (with name filter).
  4. Lists existing nodes.
  5. If `PROVISION=1`: resolves compatible AMI + instance type via `aws_resolve_catalog.py`, picks subnet, `POST /v1/compute/nodes`.
  6. If `TEARDOWN_VMS=1`: calls `teardown_libcloud_vms()`.
- **Key env vars:** `LIBCLOUD_USER`, `LIBCLOUD_PASSWORD`, `AWS_REGION`, `PROVISION` (0/1), `TEARDOWN_VMS` (0/1), `VM_NAME`, `AWS_INSTANCE_ARCH`, `LIBCLOUD_AWS_AUTH_BINDING`, `IMAGE_ID`/`SIZE_ID`/`SUBNET_ID` (overrides)
- **Role:** Any user (read); `can_provision` required for `PROVISION=1`. Cloud Admin.

---

### `provision_nutanix.sh`

- **Purpose:** End-to-end Nutanix provisioning demo. Mirror of `provision_aws.sh`. Self-limits: viewer/reader roles exit before mutating calls.
- **WTD mapping:** Part 2.3 — compute provisioning (Nutanix).
- **How it works:**
  1. Sources `common.sh`.
  2. `idp_login()` → build Nutanix connection (`NUTANIX_HOST`, `PORT`, `API_VERSION`, `VERIFY_SSL`) → token validation + connection test.
  3. Discovers catalog: clusters, sizes, images, storage containers.
  4. Lists existing VMs.
  5. If user is `reader`/`cloud-readonly`/`*-viewer`: exits (read-only mode).
  6. If `PROVISION=1`: picks first cluster/image/subnet, `POST /v1/compute/nodes`.
  7. If `TEARDOWN_VMS=1`: deletes VM.
- **Key env vars:** `LIBCLOUD_USER`, `LIBCLOUD_PASSWORD`, `PROVISION`, `TEARDOWN_VMS`, `VM_NAME`, `NUTANIX_HOST`, `NUTANIX_PORT`, `NUTANIX_API_VERSION`, `NUTANIX_VERIFY_SSL`, `LIBCLOUD_NTNX_AUTH_BINDING`
- **Role:** Any user (read); `can_provision` for write. Cloud Admin.

---

### `deprovision_aws.sh`

- **Purpose:** Delete AWS demo VMs. Uses **only `curl` + `jq`** (no Python). Deletes VMs matching `libcloud-demo-*` name prefix.
- **WTD mapping:** Part 2.3 — node deprovisioning.
- **How it works:**
  1. Sources `common.sh` for env vars only.
  2. `require_token()`: reads OIDC token cache from `generated/tokens/{user}.json`, refreshes via curl POST to Dex, persists with `jq`.
  3. Builds connection param with `jq`.
  4. Three OpenFGA checks via curl + jq: `can_connect`, `can_use` on `provider:aws`, `can_provision` on `aws_region:{binding}`.
  5. Lists nodes via `curl GET /v1/compute/nodes`, filters by `libcloud-demo-*` prefix (or `$VM_NAME`).
  6. Deletes each via `curl DELETE /v1/compute/nodes/{id}`.
- **Key env vars:** `LIBCLOUD_USER` (default `aws-admin`), `LIBCLOUD_AWS_AUTH_BINDING`, `AWS_REGION`, `VM_NAME`
- **Requires:** `curl`, `jq`, `generated/tokens/{user}.json`
- **Role:** Cloud Admin (`can_provision` required)

---

### `deprovision_nutanix.sh`

- **Purpose:** Delete Nutanix demo VMs. Mirror of `deprovision_aws.sh`. Uses **only `curl` + `jq`** (no Python). Deletes VMs matching `libcloud-ntnx-*` name prefix.
- **WTD mapping:** Part 2.3 — node deprovisioning (Nutanix).
- **How it works:**
  1. Sources `common.sh` for env vars only. Defaults `LIBCLOUD_USER` to `ntnx-admin`.
  2. Same `require_token()` pattern as deprovision_aws.sh.
  3. Builds Nutanix connection param with `jq` (host, port, api_version, verify_ssl).
  4. Three OpenFGA checks: `can_connect`, `can_use` on `provider:nutanix`, `can_provision` on `nutanix_cluster:{binding}`.
  5. Lists nodes, filters by `libcloud-ntnx-*` prefix, deletes each.
- **Key env vars:** `LIBCLOUD_USER` (default `ntnx-admin`), `LIBCLOUD_NTNX_AUTH_BINDING`, `NUTANIX_HOST`, `NUTANIX_PORT`, `NUTANIX_API_VERSION`, `NUTANIX_VERIFY_SSL`
- **Requires:** `curl`, `jq`, `generated/tokens/{user}.json`
- **Role:** Cloud Admin (`can_provision` required)

---

### `aws_vm_lifecycle.sh`

- **Purpose:** Orchestrate full AWS VM lifecycle in one script: preflight check (Vault credentials exist) → provision → list → deprovision → list again.
- **WTD mapping:** Part 2.3 — full compute lifecycle demonstration.
- **How it works:**
  1. Preflight: reads Vault root token from `../vault/generated/vault.env`, checks `secret/data/libcloud/{binding}` has AWS credentials. If missing, prints exact `set_tenant_credentials.py` command.
  2. Step 1/4: calls `provision_aws.sh` with `PROVISION=1`.
  3. Step 2/4: acquires cached token, lists VMs via curl GET.
  4. Step 3/4: calls `deprovision_aws.sh`.
  5. Step 4/4: re-acquires token, lists VMs again to confirm teardown.
- **Key env vars:** `LIBCLOUD_USER` (default `aws-admin`), `LIBCLOUD_AWS_AUTH_BINDING`, `AWS_REGION`, `VM_NAME`
- **Requires:** `curl`, `jq`, calls `provision_aws.sh` and `deprovision_aws.sh`
- **Role:** Cloud Admin

---

### `aws_resolve_catalog.py`

- **Purpose:** Select a compatible AWS AMI + instance type from catalog JSON files. Scoring heuristic prefers Canonical Ubuntu LTS HVM-SSD images; filters blocked terms (SQL, GPU, Elasticsearch, WordPress, etc.).
- **WTD mapping:** Internal helper for `provision_aws.sh`.
- **How it works:**
  1. Takes two JSON file arguments: images and sizes (from libcloud REST API).
  2. `pick_image()`: scores images by owner (Canonical +200), Ubuntu version (Noble 24.04 +150, Jammy 22.04 +140), virtualization (HVM +50), root type (EBS SSD +30). Filters by architecture; skips blocked names.
  3. `pick_size()`: prefers `AWS_DEFAULT_SIZE_ID` if arch-compatible; else first matching-arch size. Checks Graviton detection and ARM family set.
  4. Prints `IMAGE_ID=...`, `SIZE_ID=...`, `AWS_INSTANCE_ARCH=...` to stdout (eval'd by calling bash script).
- **Env vars:** `AWS_INSTANCE_ARCH` (default x86_64), `AWS_DEFAULT_SIZE_ID` (optional)
- **Binaries:** `python3`
- **Role:** Not invoked directly; called by `provision_aws.sh`

---

## Cross-Reference: WTD Task → Script(s)

| WTD Task | Script(s) |
|----------|-----------|
| **User onboarding** | `lldap-user-onboard.sh`, `lldap-group-add-member.sh` → triggers `openfga-tuple-reconcile.py` |
| **User offboarding** | `lldap-user-offboard.sh` + `openfga-tuple-delete.sh` |
| **Password reset** | `lldap-user-password-reset.sh` (calls `lldap_set_password.py`) |
| **Group management** | `lldap-group-create.sh`, `lldap-group-delete.sh` |
| **Membership audit** | `lldap-audit-all-memberships.sh`, `lldap-group-list-members.sh`, `lldap-user-list-groups.sh` |
| **LLDAP cred rotation** | `lldap-admin-cred-rotate.sh` |
| **Tenant creation** | `create_tenant.sh` |
| **Tenant credential write** | `set_tenant_credentials.py` |
| **OpenFGA check** | `openfga-check.sh` |
| **OpenFGA tuple write/delete** | `openfga-tuple-write.sh`, `openfga-tuple-delete.sh` |
| **OpenFGA list-objects/users** | `openfga-list-objects.sh`, `openfga-list-users.sh` |
| **OpenFGA tuple audit** | `openfga-tuple-audit.py` |
| **LLDAP→FGA reconciliation** | `openfga-tuple-reconcile.py` |
| **Break-glass grant** | `openfga-breakglass-grant.sh` |
| **Denial log review** | `openfga-denial-log-query.sh` |
| **FGA key rotation** | `openfga-presharedkey-rotate.sh` |
| **FGA JWKS freshness** | `openfga_ensure_fresh.sh` |
| **Compute node list** | `cloud-node-list.sh` |
| **Compute node provision** | `cloud-node-provision.sh`, `provision_aws.sh`, `provision_nutanix.sh` |
| **Compute node lifecycle** | `cloud-node-action.sh` |
| **Compute node deprovision** | `deprovision_aws.sh`, `deprovision_nutanix.sh` |
| **Full VM lifecycle demo** | `aws_vm_lifecycle.sh` |
| **Image/size discovery** | `cloud-image-list.sh`, `cloud-size-list.sh`, `aws_resolve_catalog.py` |
| **Keypair management** | `cloud-keypair-manage.sh` |
| **Network listing** | `cloud-network-list.sh` |
| **Storage bucket CRUD** | `cloud-storage-bucket-create.sh`, `cloud-storage-bucket-list.sh`, `cloud-storage-bucket-delete.sh` |
| **Object upload/download** | `cloud-storage-object-upload.sh`, `cloud-storage-object-download.sh` |
| **Volume listing** | `cloud-volume-list.sh` |
| **Floating IP management** | `cloud-floatingip-allocate.sh`, `cloud-floatingip-list.sh`, `cloud-floatingip-release.sh` |
| **IdP authentication** | `idp_login.py`, `superadmin_auth.sh`, `verify_superadmin_jwt.py` |

---

## Role-Responsibility Summary

| Role | Scripts They Execute |
|------|---------------------|
| **Cloud Owner only** | `superadmin_auth.sh`, `verify_superadmin_jwt.py`, `create_tenant.sh`, `openfga-presharedkey-rotate.sh` |
| **Cloud Admin** | All LLDAP scripts (12), all OpenFGA scripts (10, except key rotation), all cloud provisioning scripts (22), `idp_login.py`, `set_tenant_credentials.py` |
| **Tenant Owner** | `set_tenant_credentials.py` |
| **Any authenticated user** | Read-only cloud scripts (`cloud-*-list.sh`, `cloud-image-list.sh`, `cloud-size-list.sh`, etc.), `openfga-check.sh`, `openfga-list-objects.sh`, `openfga-list-users.sh` |

---

## Common Environment Variable Dependency Chain

All scripts ultimately depend on these env vars (loaded from `.env` files created by `setup.sh`):

| Env Var | Source File | Used By |
|---------|-------------|---------|
| `FGA_API_URL` | `generated/fga.env` | All non-LLDAP scripts |
| `FGA_STORE_ID` | `generated/fga.env` | All non-LLDAP scripts |
| `FGA_MODEL_ID` | `generated/fga.env` | All non-LLDAP scripts |
| `LIBCLOUD_REST_URL` | `.env` | All cloud/provisioning scripts |
| `LIBCLOUD_OIDC_CLIENT_SECRET` | `../dex/generated/dex.env` | All scripts that call `idp_login()` |
| `DEX_URL` | `../dex/generated/dex.env` | All scripts that call `idp_login()` |
| `LLDAP_URL` | `.env` / `../lldap/.env` | All LLDAP scripts |
| `LLDAP_ADMIN_USER` | `../lldap/.env` | All LLDAP scripts |
| `LLDAP_LDAP_USER_PASS` | `../lldap/.env` | All LLDAP scripts |
| `VAULT_ADDR` | `../vault/generated/vault.env` | Credential rotation + tenant scripts |
| `VAULT_ROOT_TOKEN` | `../vault/generated/vault.env` | Credential rotation + tenant scripts |
| `LIBCLOUD_USER` | env / script default | All scripts (audit actor + auth identity) |
| `LIBCLOUD_PASSWORD` | env / `common.sh` resolver | All scripts that call `idp_login()` |
