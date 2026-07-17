# Startup / Shutdown / Migrate Procedure

This document is the operational runbook for the libcloud security stack: how
to **start** the whole system, **shut it down** gracefully, **migrate** it to
a new machine, and what each component does during startup. It replaces the
earlier raw `setup.sh` output paste.

The stack is seven sibling projects under `libcloud_nutanix/`:

| Project | Container(s) | Port(s) | Persistent storage | Role |
|----------|--------------|---------|--------------------|------|
| `lldap/` | `lldap` (+ on-demand `lldap-tools`, one-shot `bootstrap`) | 17170, 3890 | `lldap_data` volume | User directory (LDAP) |
| `dex/` | `dex` | 5556 | **in-memory** (no volume) | Stable OIDC issuer |
| `openfga_my/` | `openfga` (+ one-shot `openfga-migrate`, `openfga-bootstrap`) | 8080, 8081, 2112 | `openfga-data` volume (sqlite) | Authorization (ReBAC) |
| `vault/` | `vault` (+ one-shot `vault-bootstrap`) | 8200 | `vault-data` volume (encrypted) | Secret store |
| `libcloud.rest/` | `libcloud-rest-api` | 8765 | `api-data` volume (`data/`) | Unified REST gateway |
| `stoplight_mock/` | `prism`, `emulator` | 4010, 9440 | **in-memory** (no volume) | Nutanix v4 mock (optional) |
| `openfga_my/` (orchestrator) | — | — | `generated/` files | Bootstrap scripts + admin tooling |

All long-running services share the external Docker network `libcloud_net`
(created by `setup.sh`) so they reach each other by container name
(`ldap://lldap:3890`, `http://dex:5556/dex`, `http://openfga:8080`,
`http://vault:8200`).

---

## 1. Dependency graph (what must be up before what)

```
                 lldap  (identity root — no deps)
                   │
                   ▼
                 dex    (LDAP connector → lldap; in-memory storage)
                   │
            ┌──────┴──────┐
            ▼             ▼
        openfga       libcloud-rest-api  ──► vault  (reads backend creds at request time)
        (OIDC JWKS    (JWT via Dex JWKS,
         via dex)     Check via openfga,
                      creds via vault)
```

Startup order (bottom-up): **lldap → dex → openfga → vault → libcloud-rest-api**.
Shutdown order is the exact reverse: **libcloud-rest-api → openfga → dex → vault → lldap**.

`stoplight_mock` is independent (no `libcloud_net` dependency, in-memory) and
optional — start/stop it any time.

---

## 2. STARTUP — `./openfga_my/setup.sh` (the single entry point)

`setup.sh` is **idempotent** and is the only thing you run to start the whole
system, whether it is a first boot, a reboot, or a re-run after a config
change. It performs the entire startup sequence below in order.

### 2.1 Prerequisites

- Docker + Docker Compose v2 on the host; the host user can run `docker`.
- The repository tree is present at `$LIBCLOUD_NUTANIX_ROOT` (default
  `~/libcloud_nutanix`).
- `openfga_my/.env`, `lldap/.env`, and (for the REST API)
  `libcloud.rest/.env` exist. On first boot `setup.sh` copies
  `openfga_my/.env.example` → `.env`; you must edit the superadmin + user
  passwords before running it. `lldap/.env` must be created by hand from the
  `lldap` README (it holds `LLDAP_JWT_SECRET`, `LLDAP_LDAP_USER_PASS`,
  `LLDAP_LDAP_BASE_DN`, ports).
- For a **migration** (not first boot): the generated envs and the Docker
  volumes must already be present (see §4).

### 2.2 What `setup.sh` does, step by step

| # | Step | What runs | Result |
|---|------|-----------|--------|
| 0 | Prep | `mkdir -p generated …`; `docker network create libcloud_net` if missing | shared network ready |
| 0b | Reuse / generate OIDC client secret | read `LIBCLOUD_OIDC_CLIENT_SECRET` from `.env` or existing `generated/dex.env`; else `secrets.token_urlsafe(32)` | stable Dex client secret across re-runs |
| 1 | Render Dex config | `DEX_WAIT=0 python3 dex_bootstrap.py` | writes `dex/config.yaml` + `generated/dex.env` (URLs, client id/secret, per-user passwords) |
| 2 | Start LLDAP | `docker compose -f lldap/docker-compose.yml up -d lldap`; wait for `http://localhost:17170/` | `lldap` healthy |
| 2b | Apply custom-attribute schema | `docker compose --profile bootstrap up bootstrap` (runs `setup-schema.sh`) | `department`/`role`/`jobtitle` registered (idempotent) |
| 2c | Create / sync `superadmin` in LLDAP | `lldap-tools run lldap_ensure_user.sh superadmin …` | break-glass user ready |
| 3 | Start OpenFGA + Dex + Vault | `docker compose up -d --build openfga` (only if image missing or Dockerfile changed, else `up -d`); `up -d dex`; `up -d vault` | three containers up |
| 3b | Re-render Dex config + reload | `DEX_WAIT=1 dex_bootstrap.py` (verifies OIDC discovery); `up -d --force-recreate dex` | Dex serving the final config |
| 4 | Superadmin login (the gate) | `source scripts/superadmin_auth.sh` → logs in to Dex as `superadmin`, verifies the JWT | `SUPERADMIN_JWT` exported; everything below is gated on it |
| 5 | Create / sync per-cloud users | `lldap_ensure_user.sh` for `aws-owner/admin/viewer`, `ntnx-owner/admin/viewer`, `cloud-denied` | 8 LLDAP users ready |
| 6 | OpenFGA bootstrap | `docker compose up openfga-bootstrap` → `openfga_bootstrap.py` (superadmin-gated) | creates/reuses store, writes/verifies model, seeds 17 tuples, runs 33 validation checks; writes `generated/fga.env` |
| 7 | Vault bootstrap | `docker compose -f vault/docker-compose.yml up vault-bootstrap` → `vault_bootstrap.py` (superadmin-gated) | init (if needed) + **unseal** (using `generated/vault.env`'s `VAULT_UNSEAL_KEY`) + ensure KV v2 + issue REST read token; writes `generated/vault.env` |
| 8 | Sync into libcloud REST | `sync_libcloud_rest_fga` + `sync_libcloud_rest_vault` rewrite `libcloud.rest/.env` (`FGA_STORE_ID`, `FGA_MODEL_ID`, `VAULT_ADDR`, `VAULT_TOKEN`) | REST API env current |
| 8b | (Re)build + recreate REST API | `docker compose -f libcloud.rest/docker-compose.yml up -d --build --force-recreate api` | `libcloud-rest-api` up on `:8765` |

After it prints `Setup complete.` the system is fully operational.

### 2.3 The exact Docker start sequence (if you ever do it by hand)

`setup.sh` already does this; the sequence is documented here for debugging.

```bash
docker network create libcloud_net 2>/dev/null || true

# 1. Identity root
docker compose -f lldap/docker-compose.yml up -d lldap
docker compose -f lldap/docker-compose.yml --profile bootstrap up bootstrap

# 2. OIDC issuer (depends on lldap over LDAP)
docker compose -f dex/docker-compose.yml up -d dex

# 3. Authorization (depends on dex for OIDC JWKS) + secret store (no deps)
docker compose -f openfga_my/docker-compose.yml up -d openfga   # runs openfga-migrate first
docker compose -f vault/docker-compose.yml up -d vault

# 4. Unified REST gateway (depends on dex + openfga + vault)
docker compose -f libcloud.rest/docker-compose.yml up -d --build api

# 5. Optional Nutanix mock (independent)
docker compose -f stoplight_mock/docker-compose.yml up -d
```

> One-shot containers (`openfga-migrate`, `openfga-bootstrap`,
> `vault-bootstrap`, lldap `bootstrap`) exit after doing their work; they are
> not long-running. `setup.sh` runs `openfga-bootstrap` and `vault-bootstrap`
> explicitly (steps 6–7) because they need `SUPERADMIN_JWT`.

### 2.4 Per-component startup notes

- **LLDAP** — comes up healthy within ~10 s; its healthcheck gates the
  `lldap-tools`/`bootstrap` one-shots via `depends_on: service_healthy`.
  Custom attributes are applied by the one-shot `bootstrap` service running
  `setup-schema.sh`. The `lldap_data` volume means existing users/groups
  survive restarts unchanged.
- **Dex** — `storage.type: memory`, so every (re)start loses in-flight OAuth
  flows and refresh tokens; users must re-login. User identity is **not**
  lost because Dex looks users up fresh from LLDAP on every login. `config.yaml`
  is re-rendered by `dex_bootstrap.py` before Dex starts.
- **OpenFGA** — the one-shot `openfga-migrate` runs `migrate
  --datastore-engine=sqlite --datastore-uri=/data/openfga.sqlite` and must
  complete successfully before `openfga` starts (`depends_on:
  service_completed_successfully`). The `openfga-data` volume means the
  store/model/tuples survive restarts; `openfga_bootstrap.py` reuses them
  (logs "Reusing existing store … Latest authorization model already matches
  … All 17 seed tuples already present").
- **Vault** — starts **sealed** after every fresh boot. `vault_bootstrap.py`
  unseals it using `VAULT_UNSEAL_KEY` from `generated/vault.env` and re-issues
  the REST read token. The `vault-data` volume holds encrypted secrets + seal
  state; without `generated/vault.env` the volume is opaque (that file is the
  one thing you must never lose on migrate).
- **libcloud REST API** — built from `libcloud.rest/Dockerfile` (copies the
  `libcloud` fork in as a pip-installable). It reads Dex JWKS, calls OpenFGA
  `Check`, and reads Vault creds at request time. Recreated by `setup.sh`
  whenever `FGA_STORE_ID`/`FGA_MODEL_ID`/`VAULT_TOKEN` change.
- **stoplight_mock** — not started by `setup.sh`; start it separately when
  developing against the Nutanix mock.

---

## 3. SHUTDOWN — `./openfga_my/shutdown.sh`

`shutdown.sh` is the mirror of `setup.sh`. It stops containers in **reverse
dependency order** (consumers first, identity root last) so in-flight requests
drain, and **leaves all volumes intact** by default.

```bash
cd openfga_my
./shutdown.sh                  # stop everything, keep volumes + libcloud_net
./shutdown.sh --keep-rest      # leave libcloud-rest-api running (stop IdP/authz/Vault only)
./shutdown.sh --purge-network  # also remove the libcloud_net network (full teardown)
./shutdown.sh --wipe           # DANGER: down -v on every project — destroys all volumes
```

Shutdown order:

| # | Project stopped | What is preserved / lost |
|---|------------------|--------------------------|
| 1 | `libcloud-rest-api` | `api-data` volume kept (`data/auth_audit.log`, `principal_map.json`) |
| 2 | `openfga` (+ `openfga-bootstrap`, `openfga-migrate`) | `openfga-data` sqlite kept (store/model/tuples) |
| 3 | `dex` | **in-memory lost** — OAuth state + refresh tokens gone (users re-login on restart) |
| 4 | `vault` (+ `vault-bootstrap`) | `vault-data` kept; **starts sealed next boot** (re-unsealed by `vault_bootstrap.py`) |
| 5 | `lldap` (+ `lldap-tools`, `bootstrap`) | `lldap_data` kept (users/groups/custom attrs) |
| 6 | `stoplight_mock` (if running) | in-memory only — nothing to preserve |

After `./shutdown.sh`, restart in place with `./setup.sh` (Vault is re-unsealed
from `generated/vault.env`; OpenFGA reuses its sqlite store; Dex re-reads
`config.yaml`).

> Never run `docker compose down -v` on any project unless you intend a full
  re-bootstrap — `down -v` destroys the named volumes. `shutdown.sh --wipe`
  is the only sanctioned way to do that, and it confirms first.

---

## 4. MIGRATE — copy the system to a new machine

The system is fully migratable because all persistent state lives either on
Docker named volumes or in the `generated/` + `.env` files. The one invariant
that must be preserved: **the in-container DNS issuer string
`http://dex:5556/dex`** — it is baked into every JWT's `iss` claim and OpenFGA
validates against it. Because Docker container names on `libcloud_net` are
preserved on the new machine, the issuer stays valid automatically.

### 4.1 On the OLD machine — shut down gracefully

```bash
cd openfga_my
./shutdown.sh                 # stop everything, keep volumes
```

Do **not** use `--wipe` or `--purge-network` — you need the volumes and the
network definition is recreated by `setup.sh` on the new machine anyway.

### 4.2 Copy the state to the new machine

You must copy **both** the file tree **and** the Docker volumes.

**A. The file tree** — tar the whole repository (it includes the generated
envs, `.env` files, `data/`, and the rendered `dex/config.yaml`):

```bash
cd ~
tar --exclude='libcloud_nutanix/libcloud/.tox' \
    --exclude='libcloud_nutanix/libcloud/venv' \
    --exclude='libcloud_nutanix/libcloud.rest/.venv' \
    --exclude='libcloud_nutanix/openfga_my/log' \
    -czf libcloud_nutanix.tgz libcloud_nutanix/
scp libcloud_nutanix.tgz newuser@newhost:~/
```

What this carries (the parts that matter):

| Path | Why it must come along |
|------|------------------------|
| `openfga_my/generated/vault.env` | `VAULT_ROOT_TOKEN` + `VAULT_UNSEAL_KEY` — **without these the vault-data volume is unrecoverable** |
| `openfga_my/generated/dex.env` | OAuth client secret + per-user passwords |
| `openfga_my/generated/fga.env` | `FGA_STORE_ID` + `FGA_MODEL_ID` (so the REST API targets the migrated store) |
| `openfga_my/generated/tokens/` | cached OIDC refresh tokens per user (optional; can be dropped to force re-login) |
| `openfga_my/generated/*_audit.log`, `generated/audit/` | audit history |
| `openfga_my/.env`, `lldap/.env`, `libcloud.rest/.env` | secrets + config (gitignored — `tar` includes them) |
| `dex/config.yaml` | rendered Dex config (re-rendered by `setup.sh` anyway, but keep it) |
| `libcloud.rest/data/principal_map.json` | sub/email → principal slug map |

**B. The Docker volumes** (4 named volumes) — pick one method:

```bash
# Option 1: per-volume tar (cleanest). Run on the OLD machine for each volume:
for v in lldap_data openfga-data vault-data api-data; do
  docker run --rm -v "${v}:/src" -v "$(pwd)":/backup alpine \
    tar -czf "/backup/${v}.tgz" -C /src .
done
scp lldap_data.tgz openfga-data.tgz vault-data.tgz api-data.tgz newuser@newhost:~/
```

```bash
# Option 2: if both machines share storage / a snapshot of the Docker root
# (/var/lib/docker/volumes), snapshot that instead.
```

> `vault-data` is encrypted at rest; transporting it without the
> `VAULT_UNSEAL_KEY` (in `generated/vault.env`) is safe but useless. Keep the
> volume tarball and `generated/vault.env` together, ideally on the same
> encrypted transfer.

### 4.3 On the NEW machine — restore volumes, then run `setup.sh`

```bash
# 0. Install Docker + Compose v2; unpack the tree.
tar -xzf libcloud_nutanix.tgz -C ~/

# 1. Recreate the 4 named volumes and restore them.
for v in lldap_data openfga-data vault-data api-data; do
  docker volume create "${v}"
  docker run --rm -v "${v}:/dst" -v "$(pwd)":/backup alpine \
    tar -xzf "/backup/${v}.tgz" -C /dst
done

# 2. Start the whole system. setup.sh is idempotent and migration-aware:
#    - it reuses LIBCLOUD_OIDC_CLIENT_SECRET from the copied generated/dex.env
#      (so the Dex issuer boundary and refresh tokens stay valid);
#    - openfga_bootstrap.py reuses the migrated sqlite store (same store/model ids);
#    - vault_bootstrap.py unseals the migrated vault-data with the copied
#      VAULT_UNSEAL_KEY (same root token, same encrypted secrets);
#    - lldap reuses the migrated lldap_data (same users/groups/custom attrs).
cd ~/libcloud_nutanix/openfga_my
./setup.sh
```

If the new machine uses **different host ports** (e.g. 5556/8200/8080/8765 are
taken), edit `lldap/.env` (`LLDAP_HTTP_PORT`/`LLDAP_LDAP_PORT`),
`dex/.env.example`→`.env` (`DEX_HTTP_PORT`), `openfga_my/.env`
(`FGA_HTTP_PORT` etc.), `vault/.env.example`→`.env` (`VAULT_PORT`), and
`libcloud.rest/.env` (`API_PORT`) **before** running `setup.sh`. The
in-container URLs (`http://dex:5556/dex`, `http://vault:8200`,
`http://openfga:8080`) do **not** change — only the host-published ports do,
so JWT `iss` validation is unaffected.

### 4.4 Post-migration verification

```bash
# 1. Dex is serving the (unchanged) issuer:
curl -s http://localhost:5556/dex/.well-known/openid-configuration | jq .issuer
#   → "http://dex:5556/dex/"   (must match the OLD machine — it does, container names preserved)

# 2. OpenFGA reused the migrated store (ids match the copied generated/fga.env):
cat openfga_my/generated/fga.env            # FGA_STORE_ID / FGA_MODEL_ID unchanged
curl -s http://localhost:8080/stores -H "Authorization: Bearer <superadmin-jwt>" | jq

# 3. Vault unsealed and the migrated secrets are present:
VAULT_TOKEN="$(grep ^VAULT_ROOT_TOKEN= openfga_my/generated/vault.env | cut -d= -f2)" \
  curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
  http://localhost:8200/v1/sys/seal-status | jq .sealed   # → false
python3 vault/list_credentials.py                          # → lists secret/libcloud/*

# 4. LLDAP users migrated:
docker compose -f lldap/docker-compose.yml run --rm lldap-tools /scripts/verify-ldap.py

# 5. End-to-end:
LIBCLOUD_USER=aws-admin LIBCLOUD_PASSWORD='<pw>' ./openfga_my/scripts/provision_aws.sh
```

### 4.5 What does NOT survive migration (by design)

- **Dex in-memory state** — all refresh tokens are gone; users re-login once.
  `generated/tokens/*.json` caches become stale and are overwritten by
  `idp_login.py` on the next login (you can delete them before migrate to
  force a clean re-login).
- **stoplight_mock in-memory state** — the Nutanix mock stores reset to seed
  data on restart; this is expected.
- **The `libcloud_net` Docker network** — it is an external network recreated
  by `setup.sh` on the new machine; you do not need to migrate it.

---

## 5. Quick reference

| Goal | Command |
|------|---------|
| Start the whole system | `cd openfga_my && ./setup.sh` |
| Restart in place after a reboot | `cd openfga_my && ./setup.sh` (Vault re-unsealed, OpenFGA reuses store) |
| Stop gracefully (keep state) | `cd openfga_my && ./shutdown.sh` |
| Stop but keep REST API up | `cd openfga_my && ./shutdown.sh --keep-rest` |
| Full teardown (keep volumes, remove net) | `cd openfga_my && ./shutdown.sh --purge-network` |
| Wipe everything (fresh re-bootstrap) | `cd openfga_my && ./shutdown.sh --wipe` then `./setup.sh` |
| Migrate to a new machine | `./shutdown.sh` → tar tree + 4 volumes → restore on new host → `./setup.sh` |
| Start only the Nutanix mock | `docker compose -f stoplight_mock/docker-compose.yml up -d` |
| Set per-tenant cloud creds (post-startup) | `TENANT=aws LIBCLOUD_USER=aws-owner … python3 openfga_my/scripts/set_tenant_credentials.py` |
| Provision as a tenant user | `LIBCLOUD_USER=aws-admin ./openfga_my/scripts/provision_aws.sh` |

## 6. Files this procedure depends on

| File | Role |
|------|------|
| `openfga_my/setup.sh` | Master startup orchestrator (idempotent, migration-aware) |
| `openfga_my/shutdown.sh` | Master graceful-shutdown orchestrator (reverse order, keeps volumes) |
| `openfga_my/dex_bootstrap.py` | Renders `dex/config.yaml` + `generated/dex.env`; verifies OIDC discovery |
| `openfga_my/openfga_bootstrap.py` | OpenFGA store/model/tuples + validation → `generated/fga.env` (superadmin-gated) |
| `openfga_my/vault_bootstrap.py` | Vault init + unseal + KV v2 + REST read token → `generated/vault.env` (superadmin-gated) |
| `openfga_my/scripts/superadmin_auth.sh` | Dex login as `superadmin` → `SUPERADMIN_JWT` (the gate) |
| `lldap/scripts/setup-schema.sh` | Applies the 3 custom user attributes (one-shot `bootstrap` service) |
| `lldap/scripts/lldap_ensure_user.sh` | Creates / syncs each LLDAP user (called by `setup.sh`) |
| `openfga_my/generated/{dex,fga,vault}.env` | The generated envs that make re-runs/migrate stable |
| `*/docker-compose.yml` | Per-project compose files (all join `libcloud_net`) |
