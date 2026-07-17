# OpenFGA — PostgreSQL-backed deployment

This directory is the project's **OpenFGA deployment**, backed by PostgreSQL
(OpenFGA's recommended production datastore). It supersedes the old
SQLite-backed `openfga_my` directory, which has been removed — OpenFGA's
SQLite datastore is flagged "beta / single-node". The design is consolidated
from two docs in the repo root:

- `../redesign_openfga_for_postgresql.md` — inspection of the live SQLite
  deployment, counts, growth model, pros/cons, and the 17-point requirements
  list for relocating to Postgres.
- `../adding_postgres_openfga.md` — OpenFGA architecture, the database-backed
  tuple/model storage model, and why the API + DB design replaces file-based
  updates.

Everything above OpenFGA's storage layer is datastore-agnostic, so the
bootstrap script, `scripts/`, `data/principal_map.json`, Dex/Vault/LLDAP
integration, and the OIDC authn flags all live in this directory. Only the
datastore is Postgres: a `postgres:16` container on `libcloud_net`. The
`openfga-local:latest` image is built here from `./Dockerfile` (multi-stage:
it downloads the official OpenFGA release tarball from GitHub and verifies
its checksum — no `openfga` binary is vendored).

## What changed vs the old SQLite deployment

| Aspect | old `openfga_my` (SQLite) | `openfga_postgres` (this dir) |
| --- | --- | --- |
| Datastore engine | `--datastore-engine=sqlite` | `--datastore-engine=postgres` |
| Datastore URI | `/data/openfga.sqlite` (file on `openfga-data` volume) | `postgres://openfga:***@postgres:5432/openfga?sslmode=disable` |
| Migration | `openfga migrate` (sqlite) on the same volume | `openfga migrate` (postgres) against the `postgres` service |
| Data volume | `openfga-data` (SQLite file) | `openfga-pg-data` (`/var/lib/postgresql/data`) |
| New service | — | `postgres` (image `postgres:16`, `pg_isready` healthcheck) |
| OpenFGA image | built locally from a vendored `openfga` binary (`COPY openfga /openfga`) | built from `./Dockerfile` (multi-stage: downloads official release, verifies checksum — no vendored binary) |
| Credentials | none (file DB) | `POSTGRES_USER` / `POSTGRES_PASSWORD` in `generated/postgres.env` |
| Host DB port | none | `5433` (debug only; do not publish in prod) |
| Bootstrap data | idempotent re-seed against SQLite | **clean re-seed** from `openfga_bootstrap.py` `INITIAL_TUPLES` (per design §7.9) |

OIDC authn (`OPENFGA_AUTHN_*`), the superadmin JWT gate, Dex, Vault, LLDAP,
the libcloud REST API ID sync, and the 28 `VALIDATION_CHECKS` in
`openfga_bootstrap.py` are all unchanged.

## Files

```
openfga_postgres/
├── docker-compose.yml      # postgres + openfga-migrate + openfga + openfga-bootstrap
├── Dockerfile              # multi-stage: downloads official openfga release, verifies checksum
├── .env.example            # Postgres creds + openfga version + OIDC + tenant user vars
├── setup.sh                # full bootstrap (build image + Postgres + Dex + Vault + LLDAP + OpenFGA)
├── openfga_bootstrap.py    # store/model/tuple seed + VALIDATION_CHECKS (unchanged)
├── dex_bootstrap.py        # Dex config render (unchanged)
├── vault_bootstrap.py      # Vault credential seed (unchanged)
├── data/principal_map.json # IdP-alias map (unchanged)
├── scripts/
│   ├── superadmin_auth.sh        # superadmin Dex login -> JWT (unchanged)
│   ├── verify_superadmin_jwt.py  # JWT verification (unchanged)
│   ├── idp_login.py              # user OIDC login (unchanged)
│   ├── set_tenant_credentials.py # tenant owner -> Vault (unchanged)
│   ├── pg_query.sh               # psql wrapper against the datastore
│   └── pg_dump.sh                # pg_dump backup snapshot
└── generated/              # created at runtime (gitignored): fga.env, postgres.env, audit logs
```

## Quick start

This stack owns the `openfga` container name and host ports `8080/8081/2112`.
`setup.sh` removes any stale containers holding those names (e.g. leftovers
from the removed `openfga_my` project) before bringing the stack up.

```bash
cd openfga_postgres
./setup.sh
```

`setup.sh` will:

0. Generate / reuse `POSTGRES_PASSWORD` into `generated/postgres.env`.
0. Build `openfga-local:latest` from `./Dockerfile` (downloads the official
   openfga `${OPENFGA_VERSION}` release and verifies its checksum; rebuilt only
   when the Dockerfile or pinned version/checksum changes).
0. Remove any stale containers holding the `openfga*` names / `8080/8081/2112`.
1. Render Dex config + user passwords.
2. Start LLDAP + create `superadmin`.
3. Start `postgres`, run `openfga migrate --datastore-engine=postgres`, start
   `openfga`, then Dex + Vault.
4. Obtain the superadmin JWT (gate for everything below).
5. Create the per-cloud tenant users in LLDAP.
6. Run `openfga-bootstrap` — clean re-seed of the store, authorization model,
   and `INITIAL_TUPLES` against Postgres, then `VALIDATION_CHECKS`.
7. Seed Vault with backend cloud credentials.
8. Sync the **new** `FGA_STORE_ID` / `FGA_MODEL_ID` (Postgres mints fresh IDs;
   the old SQLite store id `01KW9EZ0Q706Y580FGQ2488THC` does **not** carry over)
   into `../libcloud.rest/.env` and restart the REST API.

## Upgrading OpenFGA

Bump `OPENFGA_VERSION` and `OPENFGA_TARBALL_SHA256` together in `.env` (the
checksum is for `openfga_<version-no-v>_linux_amd64.tar.gz`, taken from the
release's `checksums.txt` at
<https://github.com/openfga/openfga/releases>). Re-run `./setup.sh` — it
detects the change, rebuilds `openfga-local:latest`, and re-runs `openfga
migrate` against the datastore. Pin both values to fail the build on a
tampered/republished release.

## Inspecting the datastore

```bash
# Count tuples (expect 17 after a clean re-seed of INITIAL_TUPLES)
./scripts/pg_query.sh -c 'select count(*) from tuple;'

# List the relationship tuples
./scripts/pg_query.sh -c \
  "select store, object_type, object_id, relation, user_object_type, user_object_id from tuple;"

# Tables OpenFGA creates (same shape as the SQLite schema):
# store, authorization_model, tuple, changelog, assertion, schema_migrations, ...
./scripts/pg_query.sh -c '\dt'

# Backup snapshot
./scripts/pg_dump.sh
```

## Design rationale (consolidated)

**Why Postgres** (from `redesign_openfga_for_postgresql.md` §6 and
`adding_postgres_openfga.md`): PostgreSQL is OpenFGA's recommended production
datastore; SQLite is documented as beta / single-node. Postgres unlocks
horizontal scaling of OpenFGA (multiple replicas sharing one DB), real
concurrent writes via MVCC, ACID + crash safety with WAL/PITR, streaming
replication + managed-Postgres options, queryable audit via SQL, network
accessibility for migrations/analytics, and larger datasets. The trade-offs
are a new moving part / SPOF (unless you also stand up Postgres HA), extra
operational overhead, per-check network latency (mitigated by OpenFGA's
in-memory cache), and DB credential management.

**Why clean re-seed** (per design §7.9): the prior live SQLite DB had drifted
from `INITIAL_TUPLES` — it carried legacy `role:*` / `api_scope:*` /
`tenant:default` tuples from the Jun 29 bootstrap plus the current model's
tuples from the Jul 2 bootstrap, across 2 model versions. Re-running the
idempotent bootstrap against Postgres reproduces only the current model's
`INITIAL_TUPLES` (17 tuples), giving a clean, validated baseline. (An
export/import path was deliberately not taken.)

**Growth model** (design §4): with role indirection, tuples scale near-linearly
in users — `T(N) ≈ 37 + 1.4 × N_users` (50 today, ~1 437 at 1 000 users,
~14 037 at 10 000). Postgres indexes + connection pooling matter at the
higher end; at the current ~17-tuple re-seed the workload is trivial.

## Resetting the datastore

There is no SQLite fallback (that deployment has been removed). To wipe and
re-seed the Postgres datastore:

```bash
# Stop the stack and delete the Postgres data volume
cd openfga_postgres && docker compose down -v

# Re-run setup.sh — fresh `openfga migrate` + bootstrap re-seeds the datastore
./setup.sh
```

## Production hardening checklist (design §7)

These are **not** done by `setup.sh` (local-dev defaults) — address before
production:

- [ ] `POSTGRES_SSLMODE=verify-full` + mount a CA cert into the `openfga`
      container; terminate TLS at Postgres or use a managed Postgres.
- [ ] Strong `POSTGRES_PASSWORD` (not the auto-generated dev value); store it
      in Vault, not `generated/postgres.env`.
- [ ] Do **not** publish `5432` to the host (unset `PG_HOST_PORT`) in prod.
- [ ] Restricted DB role (not superuser); dedicated `openfga` user with only
      the privileges OpenFGA needs.
- [ ] Pin the Postgres major version (`postgres:16`) and the OpenFGA image;
      re-run `openfga migrate` on every OpenFGA upgrade.
- [ ] Backups: schedule `pg_dump` (or WAL archiving + base backups for PITR);
      define retention + a tested restore drill. `scripts/pg_dump.sh` is a
      starting point.
- [ ] HA: Postgres primary + replica, ≥2 OpenFGA replicas behind a load
      balancer (only possible now that SQLite is gone).
- [ ] Observability: Postgres Prometheus exporter; keep OpenFGA `:2112`
      metrics; ship OpenFGA + Postgres logs to the same destination as
      `generated/openfga_audit.log`.
- [ ] Changelog retention/prune policy (the `changelog` table grows
      monotonically with writes).
- [ ] Validation gate: re-run `openfga_bootstrap.py`'s `VALIDATION_CHECKS`
      (all green) + replay representative `Check` calls from
      `../libcloud.rest/app/auth/policy.py` before cutting traffic.
