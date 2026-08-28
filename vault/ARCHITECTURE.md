# Vault — Encrypted Secret Store for the libcloud security stack

Vault is the **encrypted at-rest secret store** for everything in the stack that
is **not** a user password living in LLDAP. Concretely:

- Cloud-provider root credentials (AWS access key / secret, Nutanix user /
  password, Azure / GCP / Alibaba service principals) — stored as KV v2 secrets
  under `secret/libcloud/<tenant>`, or registered with a cloud secrets engine.
- Per-tenant backend credentials, written by the tenant **owner** only.
- Vault-internal material: root token, unseal key, the libcloud REST API
  read-only token (these are *outputs* of bootstrap, written to
  `generated/vault.env`, not stored *inside* Vault's KV).

What Vault does **not** store: human login passwords. Those live in LLDAP
(`../lldap`) and are verified by LLDAP/Dex at login time. Vault has **no LDAP
auth method** — callers authenticate to Vault by token only (see §6), so it
never imports or replicates LLDAP passwords.

This directory is a **standalone Docker Compose project** running the Vault
container named **`vault`** on the shared external `libcloud_net` network.

---

## 1. Role in the stack

```
            ┌────────────────────────── libcloud_net ──────────────────────────────┐
            │                                                                      │
            │   ┌─────────┐   read-only token    ┌─────────┐                       │
            │   │libcloud │ ───────────────────► │ vault   │  (this project)       │
            │   │ REST API│   GET /v1/secret/... │ :8200   │  KV v2 (token auth)   │
            │   └────┬────┘                      └─────────┘                       │
            │        │ JWT (Dex-issued)                                            │
            │        ▼                                                             │
            │   ┌─────────┐   Check           ┌─────────┐                          │
            │   │openfga  │ ◄── can_manage_ ──│ lldap   │  user directory          │
            │   │ :8080   │     credentials   │ :3890   │  (uid, mail, cn, groups) │
            │   └─────────┘                   └─────────┘                          │
            └─────────────────────────────────▲────────────────────────────────────┘
                                              │  HTTP API (X-Vault-Token)
                              host admin scripts (../test_script/scripts/vault-*.sh,
                                  set_tenant_credentials.py) + ../openfga_postgres/vault_bootstrap.py
```

- **Secrets store (this service):** Vault holds cloud-provider credentials as
  KV v2 secrets and (optionally) registers cloud secrets engines for dynamic
  short-lived credentials.
- **Identity / authentication (upstream):** LLDAP holds users + groups and is
  verified by Dex at login time. Vault itself has **no LDAP auth method** —
  callers reach Vault by token only (root token for admin scripts, read-only
  token for the libcloud REST API). LLDAP is not mapped to Vault ACL policies.
- **Authorization gate (sibling):** OpenFGA gates **writes** to Vault: a
  tenant's backend credentials can only be written by a caller who (a) logs in
  to Dex (i.e. is a real LLDAP user) and (b) holds the OpenFGA
  `can_manage_credentials` relation on that tenant (owner-only). The OpenFGA
  server itself does **not** talk to Vault at runtime (see §7).
- **Runtime consumer:** the libcloud REST API reads credentials from Vault at
  request time using a least-privilege read-only token issued during bootstrap.

---

## 2. Files in this directory

| File | Purpose |
| --- | --- |
| `config.hcl` | Vault server config — file storage, TCP listener (TLS disabled), UI, mlock. Mounted read-only at `/vault/config/config.hcl`. |
| `docker-compose.yml` | Standalone compose project: the `vault` service + a one-shot `vault-bootstrap` service. |
| `.env.example` | Host port override (`VAULT_PORT=8200`) and optional seed-credential env vars for direct `docker compose up vault-bootstrap` runs. |
| `add_credential.py` | Insert / overwrite a KV v2 secret at `secret/libcloud/<name>` (root-token write). |
| `delete_credential.py` | Delete a KV v2 secret (metadata + all versions, or destroy current version only). |
| `list_credentials.py` | Enumerate every secret under `secret/libcloud/` (keys + metadata, optionally values). |
| `generated/vault.env` | Emitted by `vault_bootstrap.py` (chmod `0600`). Contains `VAULT_ADDR`, `VAULT_TOKEN` (libcloud REST read token), `VAULT_ROOT_TOKEN`, `VAULT_UNSEAL_KEY`. **Committed to git — treat values as compromised; see §8.5.** |
| `vault.log` | Captured server log from a manual run (not used by the container; the compose project logs to Docker). |
| `myrun.sh` | Developer convenience wrapper for a manual local run. |

The bootstrap logic itself lives in the OpenFGA orchestrator project at
`../openfga_postgres/vault_bootstrap.py` and is mounted read-only into the
`vault-bootstrap` container (see `docker-compose.yml`).

---

## 3. Server configuration (`config.hcl`)

```hcl
storage "file" {
  path = "/vault/file"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

ui            = true
api_addr      = "http://0.0.0.0:8200"
disable_mlock = true
```

- **File storage** at `/vault/file` — secrets + seal state are persisted on the
  `vault-data` Docker volume, so they survive reboot / restart /
  `docker compose down`. `/vault/file` is used (not a custom path) because the
  `hashicorp/vault` image's `docker-entrypoint.sh` automatically chowns that
  path to the vault user (uid 100) when run as root; a custom path would not be
  chowned and `vault operator init` would fail with permission denied.
- **TCP listener on `0.0.0.0:8200`** with **TLS disabled**. This is a
  single-host dev configuration — traffic stays on the isolated `libcloud_net`
  bridge network or on `localhost`. **For production**, enable TLS on the
  listener and use Raft storage + an external KMS for auto-unseal.
- **`disable_mlock = true`** — disables memory locking in dev mode (the
  container still requests `IPC_LOCK` capability for parity with the upstream
  image; see §4).
- **`ui = true`** — Vault web UI is enabled (reachable on the same port).

There is **no** `api_addr` pointing at a public hostname: in-cluster callers
reach `http://vault:8200` by container DNS; host-side scripts reach
`http://localhost:8200` via the published port. `generated/vault.env` records
the host-reachable `VAULT_ADDR=http://localhost:8200` for the host scripts.

---

## 4. Runtime — Docker container `vault`

`docker-compose.yml`:

```yaml
services:
  vault:
    image: hashicorp/vault:1.15
    container_name: vault
    restart: unless-stopped
    networks:
      - libcloud_net
    ports:
      - "127.0.0.1:${VAULT_PORT:-8200}:8200"
    cap_add:
      - IPC_LOCK
    volumes:
      - ./config.hcl:/vault/config/config.hcl:ro
      - vault-data:/vault/file
    command: ["vault", "server", "-config=/vault/config/config.hcl"]
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8200/v1/sys/seal-status"]
      interval: 10s
      timeout: 5s
      retries: 6
      start_period: 5s
```

Key points:

- **Image:** `hashicorp/vault:1.15` (pinned).
- **Container name:** `vault` — the DNS name other containers on `libcloud_net`
  use (`http://vault:8200`), used by the libcloud REST API at runtime and by
  `vault-bootstrap` for init/unseal.
- **Network:** `libcloud_net` (external) — shared bridge across all sibling
  compose projects (`../lldap`, `../dex`, `../openfga_postgres`, `../libcloud.rest`).
  Created by the repo-root `../setup.sh` before Vault starts.
- **Port:** host `127.0.0.1:8200` → container `8200`, overridable via
  `VAULT_PORT` (loopback-only — not reachable from other hosts). This is the
  **host-side** entry point for the admin scripts and the web UI.
- **`cap_add: IPC_LOCK`** — required by Vault's `mlock` syscall; harmless when
  `disable_mlock = true` (kept for forward-compat if mlock is re-enabled).
- **Volumes:** `config.hcl` is mounted **read-only**; the `vault-data` named
  volume holds `/vault/file` (encrypted secrets + seal state). `docker compose
  down -v` is the only way to wipe state — never do this in production.
- **Healthcheck:** probes `/v1/sys/seal-status`, which returns HTTP 200 in
  every state (uninit / sealed / unsealed), so it reliably reports "listener up
  + core responsive". `vault status` is avoided because the CLI defaults to
  HTTPS against this TLS-disabled listener.

### Bootstrap container (`vault-bootstrap`)

A one-shot `python:3.12-slim` container runs `../openfga_postgres/vault_bootstrap.py`
to initialize, unseal, configure, and issue the libcloud REST API read token.
It runs as the host UID/GID so `generated/vault.env` (chmod `0600`) is owned by
the host user and readable by `setup.sh`. It is started by
`../setup.sh`; compose `depends_on` waits only for `condition: service_started`
(not `service_healthy`), and the script itself polls `/sys/init` until Vault
responds.

### Lifecycle (driven by `../setup.sh`)

1. `setup.sh` creates `libcloud_net` if missing.
2. `setup.sh` performs a **superadmin Dex login** (`test_script/scripts/superadmin_auth.sh`)
   to obtain `SUPERADMIN_JWT`. Without it, `vault_bootstrap.py` refuses to run
   (§6).
3. `docker compose -f ../vault/docker-compose.yml up -d vault` starts the
   server (sealed/uninitialized on first boot).
4. `docker compose ... up vault-bootstrap` runs `vault_bootstrap.py`, which:
   - waits for the Vault API to be reachable,
   - initializes (1 key, threshold 1) if not yet initialized,
   - unseals,
   - enables KV v2 at `secret/`,
   - creates the `libcloud-rest-read` ACL policy (read/list on
     `secret/data/libcloud/*` and `secret/metadata/libcloud/*`),
   - issues a 768 h renewable token bound to that policy → written to
     `generated/vault.env` as `VAULT_TOKEN`.
5. `setup.sh` syncs `VAULT_ADDR=http://vault:8200` + `VAULT_TOKEN` into
   `../libcloud.rest/.env` and recreates the libcloud REST API container so it
   picks them up.

Manual control (from this directory):

```bash
docker compose up -d vault            # start (sealed on first boot)
docker compose up   vault-bootstrap   # init + unseal + issue read token
docker compose logs -f vault          # server log
docker compose restart vault          # restart (seal state survives on the volume)
docker compose down                   # stop (keeps vault-data volume)
```

After a host reboot, `vault` comes up **sealed**; re-running `vault-bootstrap`
(or `setup.sh`) unseals it using `VAULT_UNSEAL_KEY` from `generated/vault.env`.

---

## 5. KV v2 layout and CRUD

All libcloud secrets live under the KV v2 mount `secret/`, prefix `libcloud/`:

```
secret/data/libcloud/aws         { key, secret }       tenant:aws      backend creds
secret/data/libcloud/aws-dev     { key, secret }       tenant:aws-dev  (per-tenant)
secret/data/libcloud/nutanix     { key, secret }       tenant:nutanix  backend creds
secret/data/libcloud/<name>      { arbitrary k=v }     any ad-hoc secret
```

KV v2 is **versioned + append-only**: re-writing a key creates a new version
(safe update), and old versions remain recoverable until metadata is deleted.

### Inserting / updating a secret

Three entry points, in increasing specificity:

**A. Ad-hoc secret via `add_credential.py`** (root-token write):

```bash
# From key=value pairs:
python3 add_credential.py aws-staging --kv key=AKIA... --kv secret=...

# From environment variables (key = var name lowercased):
python3 add_credential.py aws-staging \
    --from-env LIBCLOUD_AWS_KEY LIBCLOUD_AWS_SECRET

# Interactive prompt (values read silently with getpass):
python3 add_credential.py gcp-prod
```

It reads `VAULT_ADDR` + `VAULT_ROOT_TOKEN` from `generated/vault.env` (or env
/ `--addr` / `--token`), POSTs to
`/v1/secret/data/libcloud/<name>` with `X-Vault-Token`, and prints the
resulting path. Re-adding an existing name creates a new version (KV v2 is
append-only).

**B. Per-tenant backend creds via `set_tenant_credentials.py`** (owner-gated;
the normal path for cloud credentials):

```bash
TENANT=aws \
  LIBCLOUD_USER=aws-owner LIBCLOUD_PASSWORD="$LIBCLOUD_PASSWORD_AWS_OWNER" \
  LIBCLOUD_AWS_KEY=AKIA... LIBCLOUD_AWS_SECRET=... \
  python3 ../test_script/scripts/set_tenant_credentials.py
```

This is the **authorized** path: it (1) logs the caller in to Dex as the LLDAP
user, (2) asks OpenFGA `Check user:<uid> can_manage_credentials tenant:<t>`,
and (3) only then writes `secret/data/libcloud/<tenant>` to Vault using the
root token. admins/viewers are denied by OpenFGA; only the tenant owner (and
superadmin, who is owner on every tenant) can write. The credential values
are **never** read from `.env` — the owner supplies them at runtime.

**C. Cloud secrets engine via `vault-secrets-engine-enable.sh`** (for dynamic
short-lived credentials):

```bash
../test_script/scripts/vault-secrets-engine-enable.sh \
    --provider aws --mount aws --root-creds-file /tmp/aws-root.env --region us-east-1
```

Enables the `aws`/`azure`/`gcp`/`alibaba` engine at a mount path and writes the
provider root creds to `<mount>/config/root` (or `/config`). Root creds are
read once from the supplied file (key=value or JSON) and never echoed.

### Listing secrets

```bash
python3 list_credentials.py                 # keys + version/timestamps, no values
python3 list_credentials.py --show-values   # includes values (sensitive!)
```

Recursively LISTs `secret/metadata/libcloud/` and prints each secret's keys
and metadata. Reads `VAULT_ADDR` + `VAULT_TOKEN` from `generated/vault.env`.

### Deleting secrets

`delete_credential.py` — two modes:

```bash
# Permanently remove the secret + all versions + metadata (irreversible):
python3 delete_credential.py aws-staging            # prompts to type the name
python3 delete_credential.py aws-staging --yes      # skip confirmation

# Destroy only the current version's data; keep metadata (audit trail preserved):
python3 delete_credential.py aws-staging --destroy-versions
```

The full delete calls `DELETE /v1/secret/metadata/libcloud/<name>`; the
version-destroy calls `DELETE /v1/secret/data/libcloud/<name>`. Both require
the root token (resolved from `VAULT_ROOT_TOKEN` in `generated/vault.env`).
A typed-name confirmation guard prevents accidental full deletes.

### KV paths outside `libcloud/`

Cloud secrets engines (§C above) live at their own mount paths (`aws/`,
`azure/`, `gcp/`, `alic/`), not under `secret/libcloud/`. The
`libcloud-rest-read` policy only grants read/list on `secret/libcloud/*`, so
the libcloud REST API cannot reach engine-generated dynamic creds unless a
dedicated policy is added (via `vault-policy-apply.sh`).

---

## 6. How Vault is authenticated (token-only; no LDAP)

Vault is reached **exclusively by Vault token** over the HTTP API
(`X-Vault-Token`). There is **no LDAP auth method** in this deployment:
`vault_bootstrap.py` never writes `auth/ldap/config`, never issues
LDAP-issued tokens, and never maps LLDAP groups to Vault policies.

The only two tokens Vault uses are:

- **`VAULT_ROOT_TOKEN`** — the root token from `vault operator init`, used by
  host admin scripts (`add_credential.py`, `delete_credential.py`, the
  `vault-*.sh` operators) for writes, policy/engine management, and
  credential seeding.
- **`VAULT_TOKEN`** — the least-privilege read token (ttl 768h, renewable),
  bound to the `libcloud-rest-read` policy, used by the libcloud REST API to
  read `secret/libcloud/*` at request time.

Both are written to `generated/vault.env` by `vault_bootstrap.py` (§4).

### 6.1 LLDAP credentials do not reach Vault

LLDAP holds the user directory and is the password authority, but it is
**upstream of Dex, not Vault**. The `LLDAP_BIND_DN` / `LLDAP_BIND_PW` exports
in `setup.sh` are consumed by `openfga_postgres/dex_bootstrap.py` to render
**Dex's** LDAP connector. When a human (or a host script) logs in to Dex, the
result is a Dex-issued JWT; that JWT is validated by OpenFGA and the libcloud
REST API — **not** by Vault. Vault performs no LLDAP bind, no group search,
and no group→policy mapping.

### 6.2 Bootstrap gate — superadmin JWT

`vault_bootstrap.py` **refuses to initialize or configure Vault** unless
`SUPERADMIN_JWT` is set and valid. That JWT is obtained by
`test_script/scripts/superadmin_auth.sh` after a successful Dex login as the
LLDAP `superadmin` user. This enforces: *the initial root token, the KV mount,
and the read policy can only be created by superadmin.* Without that gate, any
host user with `generated/vault.env` could re-bootstrap Vault and re-issue the
root token.

---

## 7. How OpenFGA accesses Vault at runtime

There are two senses of "OpenFGA accesses Vault," and they must be kept
distinct:

### 7.1 The OpenFGA **server** (`openfga` container) — does not talk to Vault

The OpenFGA server itself has **no** Vault client. It is started
(see `../openfga_postgres/docker-compose.yml`) with OIDC authn pointed at Dex
and a PostgreSQL datastore (`postgres:16`, volume `openfga-pg-data`); it
validates caller JWTs against Dex's JWKS and evaluates tuples. It neither reads
from nor writes to Vault. Authorization decisions are made purely from the
OIDC `sub` + the tuple store.

### 7.2 The **`test_script/scripts` admin tooling** — does talk to Vault

The operator-script directory (`../test_script/scripts/`) contains the Vault
admin scripts. They reach Vault over the HTTP API using
`../test_script/scripts/vault_common.sh`, which:

- loads `../vault/generated/vault.env` (and the repo-root `.env`) to resolve
  `VAULT_ADDR` and `VAULT_ROOT_TOKEN` (preferring the root token for admin
  operations, falling back to `VAULT_TOKEN` for read-only ones),
- exposes `vault_get` / `vault_put` / `vault_post` / `vault_delete` /
  `vault_list` wrappers that attach `X-Vault-Token` via curl,
- emits a structured JSONL audit line per call to
  `generated/vault_audit.log`.

These scripts cover: policy apply/list/audit, secrets-engine enable, role
create, dynamic-cred request, static-secret rotate, lease list/renew/revoke,
root-cred rotate, LDAP group bind, health check, and audit-log query.

### 7.3 The OpenFGA **authorization gate on Vault writes**

The most important connection between OpenFGA and Vault is **logical, not
network**: OpenFGA decides who may write to Vault. The flow
(`set_tenant_credentials.py`, §5B) is:

```
caller (LLDAP user)
  │  1. test_script/scripts/idp_login.py → Dex login (LLDAP password verified by LLDAP)
  │      └─ returns a Dex-issued JWT (sub = LLDAP uid, aud = libcloud-rest)
  │
  │  2. OpenFGA Check: user:<uid>  can_manage_credentials  tenant:<t>
  │      └─ OpenFGA validates the JWT (iss+aud+sig via Dex JWKS), then
  │         evaluates the tuple. allowed=true only for the tenant owner
  │         (and superadmin as break-glass owner on every tenant).
  │
  │  3. Vault POST /v1/secret/data/libcloud/<tenant>
  │      └─ X-Vault-Token: VAULT_ROOT_TOKEN (from generated/vault.env)
  │         writes the encrypted credential. KV v2 → new version.
  ▼
secret/data/libcloud/<tenant> updated, attributed to the owner identity.
```

So OpenFGA is the **authorization layer in front of Vault writes**, while
Vault remains the **encrypted storage layer**. The two are decoupled at the
network level (no OpenFGA→Vault calls) but coupled at the policy level
(no write happens without an OpenFGA `Check` allowing it).

### 7.4 The libcloud REST API — the runtime reader

At request time, the libcloud REST API reads the cloud credentials it needs
from Vault using the **least-privilege read-only token** issued during
bootstrap (`VAULT_TOKEN` in `generated/vault.env`, synced into
`../libcloud.rest/.env` as `VAULT_ADDR=http://vault:8200` + `VAULT_TOKEN`).
That token is bound to the `libcloud-rest-read` policy:

```hcl
path "secret/data/libcloud/*"     { capabilities = ["read"] }
path "secret/metadata/libcloud/*" { capabilities = ["read", "list"] }
```

It cannot write, delete, or reach any path outside `secret/libcloud/*`. The
REST API first authorizes the caller via OpenFGA (`can_provision`, etc.), then
fetches the tenant's backend creds from Vault and uses them to talk to AWS /
Nutanix. The raw cloud credentials are never present in the REST API's env
beyond the read token.

---

## 8. Security — preventing illegitimate access

The threat model is: an attacker (or a misconfigured/compromised container or
host user) tries to read, modify, or destroy secrets in Vault. The defenses,
layered:

### 8.1 Seal state + init gate

- Vault starts **sealed** on every fresh boot. The unseal key is in
  `generated/vault.env` (chmod `0600`, host-side only — but committed to git;
  see §8.5). Without it, the encrypted blob on the `vault-data` volume is
  opaque even if the volume is exfiltrated.
- `vault_bootstrap.py` refuses to initialize or re-issue the root token unless
  `SUPERADMIN_JWT` is present and valid (a real Dex login as the LLDAP
  `superadmin` user). So merely having host access is not enough to (re)create
  the root token — you must also be `superadmin` in LLDAP.

### 8.2 Token hierarchy + scoped policies

| Token | Capabilities | Where it lives | Who gets it |
| --- | --- | --- | --- |
| `VAULT_ROOT_TOKEN` | root | `generated/vault.env` (0600) | host admin scripts only |
| `VAULT_TOKEN` (libcloud REST) | read/list `secret/libcloud/*` | synced into `../libcloud.rest/.env` | libcloud REST API container |

- The root token is **not** mounted into any long-running container; it is read
  from `generated/vault.env` only by host-side scripts at invocation time.
- The REST API token is path-scoped to `secret/libcloud/*` and read-only — it
  cannot enumerate engines, write, delete, or reach `<mount>/config/root`.
- `vault_require_root_token()` in `test_script/scripts/vault_common.sh` refuses to run
  policy/engine/lease-revoke-prefix scripts if only the read-only token is
  available, so a mis-set `VAULT_TOKEN` cannot accidentally perform root ops.

### 8.3 Authorization gate on writes

- **Every** credential write goes through `set_tenant_credentials.py`, which
  requires (a) a valid Dex login as an LLDAP user and (b) an OpenFGA `Check`
  allowing `can_manage_credentials` on the target tenant. admins/viewers are
  denied; only the tenant owner (and `superadmin`) can write.
- The write itself uses the root token, but the *decision* to allow the write
  is OpenFGA's, evaluated from the caller's JWT (`sub` = LLDAP `uid`). A
  stolen root token alone is not enough to pass the gate *legitimately* — the
  audit trail (`generated/vault_audit.log`) records the actor, and the
  OpenFGA tuple audit (`test_script/scripts/openfga-tuple-audit.py`) records who has the
  owner relation.

### 8.4 Network isolation

- Vault is on `libcloud_net` (a dedicated Docker bridge), reachable by
  container DNS only from other containers on that network. It is **not**
  exposed on a public interface; the host port `8200` is bound to `127.0.0.1`
  (loopback) by default (the `ports:` map can be removed for headless
  deployments).
- In-cluster traffic to Vault is plain HTTP (TLS disabled, §3). This is
  acceptable **only** because `libcloud_net` is an isolated single-host bridge.
  For any multi-host or external exposure, enable TLS on the listener and put
  Vault behind a TLS-terminating reverse proxy; set `api_addr` accordingly.

### 8.5 Secret material handling

- **`generated/vault.env` is committed to git** — it is **not** gitignored
  (`git ls-files` lists `vault/generated/vault.env`), and it contains the Vault
  root token and unseal key. Treat those values as **compromised**: rotate
  them, run `git rm --cached vault/generated/vault.env`, and purge the file
  from git history (and from any clone of the repo). The same applies to
  `dex/generated/dex.env`. The file is `chmod 0600`, owned by the host user,
  and read by the admin scripts, but that does not protect it once it is in
  the repository; it is also never baked into an image or mounted into
  long-running containers.
- Cloud root credentials supplied to `vault-secrets-engine-enable.sh` are read
  once from a caller-supplied file (never hardcoded, never logged), mapped to
  the engine-specific `/config` body, and not echoed. The temp files holding
  the JSON body are unlinked after the call.
- `add_credential.py` interactive mode uses `getpass` so values are not echoed
  to the terminal or shell history. `list_credentials.py` redacts values by
  default and requires an explicit `--show-values` to print them.

### 8.6 Audit + rotation

- Every admin script emits a JSONL audit line to `generated/vault_audit.log`
  (timestamp, actor, action, target, result, HTTP code). Vault's own audit
  devices can be enabled in addition (`vault audit enable file ...`).
- Rotation scripts:
  - `test_script/scripts/vault-root-cred-rotate.sh` — rotates a cloud secrets
    engine's root credentials.
  - `test_script/scripts/vault-static-secret-rotate.sh` — rotates a static KV
    secret.
  - `test_script/scripts/vault-lease-revoke.sh` /
    `vault-lease-revoke-prefix.sh` — revoke dynamic-cred leases on offboard.
  - `test_script/scripts/vault-token-lookup.sh` — inspect a token's
    capabilities + TTL.
- `test_script/scripts/lldap-admin-cred-rotate.sh` rotates the LLDAP admin
  password and persists the new value to Vault (`secret/lldap/admin`) and
  `../lldap/.env` — there is no Vault `auth/ldap/config` to update, since
  Vault has no LDAP auth method.

### 8.7 Break-glass

`superadmin` is the break-glass identity: it is `owner` on every tenant in
OpenFGA, so it can write any tenant's credentials and rotate any secret. Its
Dex password is in `generated/dex.env` (committed to git — treat as
compromised; see §8.5). Use it only for recovery;
its actions are recorded in both the Vault and OpenFGA audit logs.

### 8.8 Hardening checklist for production

1. Enable TLS on the Vault listener (`tls_disable = 0`, real cert + CA).
2. Use `ldaps://` on Dex's LLDAP connector (Vault itself performs no LLDAP
   bind).
3. Switch storage to Raft and use an external KMS for auto-unseal (remove the
   `VAULT_UNSEAL_KEY` from disk).
4. Replace the single root token with short-lived, renewable Vault tokens
   (token auth is the only auth method in this deployment).
5. Re-enable `mlock` (remove `disable_mlock = true`) and keep `cap_add:
   IPC_LOCK`.
6. Bind the host port to `127.0.0.1` only (or remove it and use a sidecar /
   SSH tunnel for admin access).
7. Enable Vault's native audit device (`vault audit enable file file=/vault/file/audit.log`)
   in addition to the script-level JSONL audit.
