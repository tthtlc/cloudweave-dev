# openfga_postgres — Architecture

This directory is the **authorization backbone** of the system. It owns the
OpenFGA deployment (Postgres-backed), the authorization model, and the tuple
bootstrap, and it also *hosts* two scripts that belong to sibling components:
the Dex config renderer (`dex_bootstrap.py`) and the Vault bootstrap
(`vault_bootstrap.py`). This is a surprising split and is explained in §1.

Everything is driven by the top-level `setup.sh`, which sequences the three
bootstraps in a fixed order (§9). The reader should treat the source files in
this directory as authoritative; several figures in `README.md` are stale and
are flagged inline below.

| File | Role |
| --- | --- |
| `docker-compose.yml` | The OpenFGA + Postgres compose stack (§2) |
| `Dockerfile` | Multi-stage build of `openfga-local:latest` (§3) |
| `.env` | Compose/script defaults (no secrets) |
| `openfga_bootstrap.py` | Store + model + tuples + validation (§5, §6) |
| `dex_bootstrap.py` | Renders `dex/config.yaml` + `dex/generated/dex.env` (§7) |
| `vault_bootstrap.py` | Vault init/unseal/KV/AppRoles/orchestrator-token (§8) |
| `enumerate_openfga.py` | Read-only full-surface enumeration (§9) |
| `list_users.sh`, `fga_auth.sh` | Curl helpers for ListUsers (§9) |
| `scripts/fga-test.sh` | Container + API smoke test (§9) |
| `model/` | Derived DSL model + test fixtures (§5, §9) |
| `generated/` | Runtime outputs: `fga.env`, `postgres.env`, enumeration report |

---

## 1. What this component is, and why it is named `openfga_postgres`

The name is historical-and-accurate. This directory **supersedes a removed
`openfga_my` deployment** that ran OpenFGA on SQLite
(`--datastore-engine=sqlite`, a beta/single-node datastore). The Postgres
version is OpenFGA's recommended production datastore, so the whole OpenFGA
stack was rebuilt around a dedicated `postgres:16` service. The rationale is
consolidated in `README.md` (§"What changed vs the old SQLite deployment") from
the (now-deleted) design docs `redesign_openfga_for_postgresql.md` and
`adding_postgres_openfga.md`.

Only the *datastore* is Postgres. OpenFGA is datastore-agnostic above its
storage layer, so everything else — the model, tuples, bootstrap, the Dex/Vault
renderers, the operator scripts — stayed here. That is why the directory does
**three jobs at once**:

1. **OpenFGA + Postgres deployment** — the compose stack, the image, the
   store/model/tuple bootstrap (§2–§6).
2. **Dex config renderer** — `dex_bootstrap.py` writes `../dex/config.yaml` and
   `../dex/generated/dex.env` (§7). It lives here because it is a *bootstrap
   script*, not a container, and the directory is the home of all bootstrap
   scripts after the `openfga_my` consolidation.
3. **Vault bootstrap** — `vault_bootstrap.py` initialises/unseals Vault, enables
   AppRole auth, and issues per-tenant AppRoles + the orchestrator token (§8).

This is the surprising part worth calling out: **`openfga_postgres` does not
contain a Dex or Vault container.** Dex, Vault, and LLDAP are *sibling*
standalone compose projects (`../dex`, `../vault`, `../lldap`) that join the
shared external `libcloud_net` network. This directory only renders their
config/secrets and drives their bootstrap. `setup.sh` states this explicitly
(`setup.sh:26-30`):

> Dex, Vault, and LLDAP live in sibling standalone compose projects (../dex,
> ../vault, ../lldap); OpenFGA stays in this project. All four (plus
> ../libcloud.rest) share the external `libcloud_net` Docker network.

---

## 2. The compose stack

`docker-compose.yml` defines four services plus one shared image anchor.

### Services

| Service | Image | Purpose | Lifecycle |
| --- | --- | --- | --- |
| `postgres` | `postgres:16` | OpenFGA datastore (`openfga` DB, `openfga` user) | `restart: unless-stopped` |
| `openfga-migrate` | `openfga-local:latest` (anchor) | One-shot `openfga migrate --datastore-engine=postgres` | `restart: "no"` |
| `openfga` | `openfga-local:latest` (anchor) | The OpenFGA server (`run`) | `restart: unless-stopped` |
| `openfga-bootstrap` | `python:3.12-slim` | Runs `openfga_bootstrap.py` | `restart: "no"` |

### The `x-openfga-image` anchor

`docker-compose.yml:34-41` defines a YAML anchor:

```yaml
x-openfga-image: &openfga-image
  image: openfga-local:latest
  build:
    context: .
    dockerfile: Dockerfile
    args:
      OPENFGA_VERSION: ${OPENFGA_VERSION:-v1.16.0}
      OPENFGA_TARBALL_SHA256: ${OPENFGA_TARBALL_SHA256:-...}
```

Both `openfga-migrate` (`:69`) and `openfga` (`:83`) consume it with `<<:
*openfga-image`, so the migration binary and the server binary are always the
**same** image — a hard requirement, because v1.16.0's datastore migrations must
run before the v1.16.0 server starts (§3).

### Dependency ordering

Compose orders startup strictly (all conditions are `service_healthy` /
`service_completed_successfully`, not mere container-start):

- `openfga-migrate` depends on `postgres` **`service_healthy`** (`:73-75`).
- `openfga` depends on `openfga-migrate` **`service_completed_successfully`** and
  on `postgres` **`service_healthy`** (`:88-92`).
- `openfga-bootstrap` depends on `openfga` **`service_healthy`** (`:128-130`).

`postgres` has a `pg_isready` healthcheck (`:61-66`); `openfga` has a
`curl http://127.0.0.1:8080/healthz` healthcheck (`:113-118`).

### Ports (all 127.0.0.1-bound)

| Service | Host | Container | Purpose |
| --- | --- | --- | --- |
| `postgres` | `127.0.0.1:5433` | `5432` | Debug `psql`/`pg_dump` only — "do NOT publish in prod" (`:57-60`) |
| `openfga` | `127.0.0.1:8080` | `8080` | HTTP management API (`:94`) |
| `openfga` | `127.0.0.1:8081` | `8081` | gRPC (`:95`) |
| `openfga` | `127.0.0.1:2112` | `2112` | Prometheus metrics (`:96`) |

The HTTP and gRPC port numbers are `FGA_HTTP_PORT`, `FGA_GRPC_PORT`,
`FGA_METRICS_PORT`, and the Postgres host port is `PG_HOST_PORT`, all overridable
in `.env`.

### Volumes

- `openfga-pg-data` → `/var/lib/postgresql/data` (`:55-56`, declared `:158-159`).
  It survives `docker compose down`; `down -v` is the intentional wipe path.

### Network

The stack joins the **external** network `libcloud_net` (`:151-153`), shared with
Dex, Vault, LLDAP, identity-service and `libcloud.rest`. Containers reach each
other by DNS name (`openfga`, `postgres`, `dex`, `vault`, `lldap`). The bootstrap
container reaches OpenFGA at `http://openfga:8080` (`:132`).

---

## 3. The image: `Dockerfile`

The Dockerfile is **multi-stage** (`download` → `final`) and downloads the
official OpenFGA release rather than vendoring a binary.

- **`downloader` stage** (`Dockerfile:49-70`): on `alpine:3.21`, `curl`s the
  release tarball `openfga_${VER}_${TARGETOS}_${TARGETARCH}.tar.gz` from GitHub
  releases, then verifies it with
  `echo "${OPENFGA_TARBALL_SHA256}  ${TARBALL}" | sha256sum -c -` (`:68`). The
  checksum is **pinned**, not auto-fetched, so a tampered or re-published release
  fails the build fast (`:36-38`).
- **`final` stage** (`Dockerfile:75-92`): a minimal `alpine:3.21` with
  `ca-certificates` + `curl`, copying only the `openfga` binary. Migrations are
  embedded in the binary, so the tarball's `assets/` tree is not needed (`:4-6`).
  `ENTRYPOINT ["/openfga"]` (`:88`).

### Why the version pin matters (v1.16.0)

The pin is operational knowledge worth preserving (`Dockerfile:11-38`):

- OpenFGA's OIDC authenticator enables `RefreshUnknownKID: true` (rate-limited to
  1/min) on its JWKS cache only from **v1.16.0** (PR
  [#3101](https://github.com/openfga/openfga/pull/3101), merged 2026-05-14).
  That means OpenFGA re-fetches Dex's JWKS when a token arrives with a `kid` not
  in cache — i.e. it **adapts to Dex's 6-hour signing-key rotation without a
  container restart**.
- **Do not assume v1.8.x has this.** The previous comment here claiming
  "≥ v1.8.8 sets `RefreshUnknownKID: true`" was wrong. In v1.8.x (including
  v1.8.16), `RefreshUnknownKID` is left unset (default false), so on an unknown
  `kid` keyfunc returns `ErrKIDNotFound` and **every `Check` fails** with
  `{"code":"invalid_claims","message":"invalid claims"}` until the container is
  restarted. That was the recurring 6h `authz_fga_error` (503) observed at
  portal login. v1.8.16 predates the PR by ~11 months and never received a
  backport.

Two consequences follow from the pin:

1. The `openfga-migrate` one-shot **must** run before the new binary, because
   v1.16.0 may carry datastore migrations beyond the 001–005 set from v1.8.x
   (`Dockerfile:30-34`). Compose enforces this via
   `depends_on: service_completed_successfully`.
2. `setup.sh` still explicitly restarts OpenFGA after force-recreating Dex
   (`setup.sh:442-455`), because `--force-recreate dex` mints a fresh signing
   key and the restart clears OpenFGA's cached JWKS set. This is a belt-and-
   braces move on top of the v1.16.0 refresh behaviour.

To upgrade: bump `OPENFGA_VERSION` **and** `OPENFGA_TARBALL_SHA256` together
(`Dockerfile:36-37`, `docker-compose.yml:40-41`), taken from the release's
`checksums.txt`.

---

## 4. Authentication of OpenFGA itself

OpenFGA runs with OIDC authentication enabled, reusing Dex as the IdP
(`docker-compose.yml:100-112`):

```
--playground-enabled=false
--authn-method=oidc
--authn-oidc-issuer=http://dex:5556/dex
--authn-oidc-audience=libcloud-rest
```

- The **issuer** is Dex's *in-container* URL (`http://dex:5556/dex`). That is the
  `iss` claim Dex stamps into tokens **and** the URL OpenFGA fetches JWKS from via
  discovery, both reachable over `libcloud_net` with no public DNS or egress.
- The **audience** (`libcloud-rest`) is the same audience as the libcloud REST
  API client, so a user's access token is accepted by OpenFGA as well.
- The playground is disabled, and the health/readiness endpoints are
  unauthenticated (`scripts/fga-test.sh:24-25`); everything under `/stores/*`
  requires a bearer token.

### The honest caveat: authentication ≠ authorization

OIDC here **only authenticates the caller** — OpenFGA validates the JWT's
`iss`, `aud`, signature and expiry. OpenFGA has **no per-caller authorization on
its own management API**. Any principal that can (a) obtain a
`libcloud-rest`-audience token from Dex and (b) reach `openfga:8080` can **write
tuples, create stores, and rewrite the authorization model** — full management
surface. The `superadmin` gating described in §6 is enforced *by the bootstrap
script refusing to run*, not by OpenFGA itself; once the script has a token, it
is simply a privileged HTTP client.

The **only** real control is network placement: OpenFGA publishes `8080/8081/2112`
on `127.0.0.1` only, so external callers cannot reach the management API. Treat
any process that can talk to `openfga:8080` (any container on `libcloud_net`)
as fully privileged over the authorization data.

---

## 5. The authorization model

The model is schema **1.1**, **9 types**, no conditions, no modules. It exists in
two equivalent forms:

1. **`LIBCLOUD_MODEL`** in `openfga_bootstrap.py:217-852` — the JSON actually
   **POSTed** to `/stores/{id}/authorization-models` by `ensure_model()`
   (`openfga_bootstrap.py:1076-1081`). This is the authoritative live form.
2. **`model/libcloud.fga`** — the equivalent OpenFGA DSL, a *derived* artifact
   produced by transforming the live model with the official CLI
   (`model/README.md:14-32`). It is what `fga model test`, `play.fga.dev`, and
   the VS Code extension consume.

`model/README.md` documents the provenance and the two-way fidelity verification
(structural round-trip + behavioural replay). The DSL is reproduced here so the
semantics are legible without reading the JSON:

```
model
  schema 1.1

type user

type platform
  relations
    define superadmin: [user]
    define global_reader: superadmin
    define can_manage_platform: superadmin
    define can_manage_tenant_lifecycle: superadmin
    define can_manage_global_policy: superadmin
    define can_manage_iam_mapping: superadmin

type tenant
  relations
    define platform: [platform]
    define owner: [user]
    define admin: [user]
    define viewer: [user]
    define member: [user] or owner or admin or viewer
    define can_assign_owner: can_manage_platform from platform
    define can_assign_admin: owner
    define can_assign_viewer: owner
    define can_manage_credentials: owner
    define can_provision: admin or owner
    define can_update: admin or owner
    define can_read: viewer or admin or owner or global_reader from platform

type libcloud_api
  relations
    define parent: [tenant]
    define platform: [platform]
    define can_connect: [user] or member from parent or global_reader from platform

type provider
  relations
    define parent: [tenant]
    define platform: [platform]
    define can_use: [user] or member from parent or global_reader from platform

type resource_class
  relations
    define tenant: [tenant]
    define platform: [platform]
    define admin: [user]
    define viewer: [user]
    define tenant_admin: admin from tenant
    define tenant_owner: owner from tenant
    define tenant_viewer: viewer from tenant
    define can_provision: admin or tenant_admin or tenant_owner
    define can_update: admin or tenant_admin or tenant_owner
    define can_read: viewer or tenant_viewer or admin or tenant_admin or tenant_owner or global_reader from platform

type aws_region
  relations
    define provider: [provider]
    define tenant: [tenant]
    define platform: [platform]
    define resource_class: [resource_class]
    define tenant_admin: admin from tenant
    define tenant_owner: owner from tenant
    define tenant_viewer: viewer from tenant
    define can_provision: ((tenant_admin or tenant_owner) and can_use from provider) or can_provision from resource_class
    define can_update: ((tenant_admin or tenant_owner) and can_use from provider) or can_update from resource_class
    define can_read: tenant_viewer or tenant_admin or tenant_owner or can_use from provider or can_read from resource_class or global_reader from platform

type nutanix_cluster
  relations
    # identical shape to aws_region (see model/libcloud.fga:68-79)

type vault_user
  relations
    define parent: [tenant]
```

(`aws_region` and `nutanix_cluster` are structurally identical — the two backend
object types per cloud.)

### Design semantics

The model is a layered tenant/role hierarchy, described in the comments of
`LIBCLOUD_MODEL` (`openfga_bootstrap.py:189-216`):

- **`platform:main`** is the control plane. `superadmin` is the bootstrap
  identity and the only direct member of `platform:main`. `global_reader` is
  computed from `superadmin` and feeds `can_connect` / `can_use` / `can_read`
  everywhere — **but NOT `can_provision`**. So a superadmin can observe all
  tenants and their resources but cannot provision inside any tenant unless
  explicitly granted a tenant role.
- **`tenant:aws` / `tenant:nutanix`** carry `owner` / `admin` / `viewer`.
  `member` unions all three. `platform:main` parents every object, so
  superadmin-gated relations resolve onto them.
- **`libcloud_api:main`** (`can_connect`) and **`provider:*`** (`can_use`) are
  the gate objects; both inherit `member from parent` (the tenant) plus
  superadmin's `global_reader`.
- **`resource_class:<tenant>-<class>`** is the per-class scope
  (compute/network/data/platform). A direct `admin`/`viewer` grant here, plus the
  tenant-derived `tenant_admin`/`tenant_owner`/`tenant_viewer`, lets an admin be
  narrowed to a single resource class.
- **`aws_region:*` / `nutanix_cluster:*`** are the backend workload objects. The
  write verbs are the key part:

  ```fga
  define can_provision: ((tenant_admin or tenant_owner) and can_use from provider)
                        or can_provision from resource_class
  define can_update:    ((tenant_admin or tenant_owner) and can_use from provider)
                        or can_update from resource_class
  ```

  The **`(...)` intersection** is the intended tenant kill switch: a tenant
  Admin/Owner can provision *only if* they also hold `can_use` on the tenant's
  provider. Because `can_use` is scoped to the tenant's own `provider:*` object,
  a Nutanix admin has no `can_use` on `provider:aws` and therefore cannot reach
  `aws_region:aws` at all — the cross-cloud isolation property that
  `model/isolation.fga.yaml` asserts.

Other key properties enforced by the model:

- **`can_manage_credentials` is owner-only** (`tenant` type). Admins and viewers
  cannot update backend cloud credentials; nor can a superadmin *unless*
  explicitly granted that tenant's `owner` role (break-glass).
- **`can_assign_owner` is superadmin-only**: it resolves through
  `platform.can_manage_platform`, so a tenant Owner **cannot mint co-Owners**
  (closes a privilege-escalation path).
- **`can_assign_admin` / `can_assign_viewer` are owner-only**; an admin cannot
  change tenant membership at all.
- **`can_update` (edit) is a distinct verb** from `can_provision`
  (create/delete), held by Owner+Admin, not by Viewer or a default superadmin.

`model/isolation.fga.yaml` documents *why* it exists: the live-server replay set
only ever re-checks stored tuples, so every recorded check is `true` and nothing
in that dataset proves a boundary *holds*. The isolation fixtures assert the
denials (ntnx-admin reaching aws, viewers provisioning, unassigned principals).

---

## 6. Bootstrap sequence (`openfga_bootstrap.py`)

The bootstrap is idempotent, stdlib-only (`urllib`, no `requests` dependency —
`openfga_bootstrap.py:47-48`), with retry/backoff on 5xx/429 (`FgaClient`
`openfga_bootstrap.py:116-183`). `run()` (`:1235-1242`) executes four steps:

| Step | Method | What it does |
| --- | --- | --- |
| 1 | `ensure_store` (`:1033`) | Finds the store by name, else `POST /stores` |
| 2 | `ensure_model` (`:1062`) | POSTs `LIBCLOUD_MODEL` unless the latest model is structurally identical (normalised comparison strips server-injected default fields, `:1091-1130`) |
| 3 | `ensure_tuples` (`:1133`) | Writes only the seed tuples not already present (batched ≤100/write) |
| 4 | `validate` (`:1189`) | Runs the `Check` matrix with retry/backoff; fails hard on any mismatch |

### Tuple count and split

`INITIAL_TUPLES` (`openfga_bootstrap.py:870-952`) seeds **50 tuples**:

- **41 structural wiring** — `platform:main` parenting every object
  (tenants/api/providers/backends/resource_classes), tenant→provider/api parent
  links, provider/tenant links onto backends, the resource_class↔backend
  bindings, and the per-tenant `vault_user` parent mapping.
- **9 role grants**:

  | Tuple | Meaning |
  | --- | --- |
  | `user:superadmin` → `superadmin` `platform:main` | Bootstrap identity |
  | `user:aws-owner` → `owner` `tenant:aws` | AWS owner |
  | `user:aws-admin` → `admin` `tenant:aws` | AWS admin |
  | `user:aws-viewer` → `viewer` `tenant:aws` | AWS viewer |
  | `user:ntnx-owner` → `owner` `tenant:nutanix` | Nutanix owner |
  | `user:ntnx-admin` → `admin` `tenant:nutanix` | Nutanix admin |
  | `user:ntnx-viewer` → `viewer` `tenant:nutanix` | Nutanix viewer |
  | `user:aws-compute-admin` → `admin` `resource_class:aws-compute` | OpenFGA-only per-class demo |
  | `user:ntnx-compute-viewer` → `viewer` `resource_class:nutanix-compute` | OpenFGA-only per-class demo |

  Note: `README.md` still says "17 tuples" in a few places — that is **stale**;
  the authoritative count is 50 (`INITIAL_TUPLES`). The live store carries more
  (68 at last enumeration) because test runs add extra `int-*` principals.

### Validation

`VALIDATION_CHECKS` (`openfga_bootstrap.py:955-1039`) holds **64**
`(user, relation, object, expected_allowed)` assertions — the README's "28" is
also stale. `validate()` runs them all each attempt (up to 6 attempts with
exponential backoff) and raises `FgaValidationError` if any still mismatches.
The checks cover: superadmin governance + read-only-but-not-provision, owner vs
admin vs viewer capabilities, owner-only credentials, owner-only assign, the
superadmin-only assign-owner gate, cross-cloud isolation, `can_update`, and the
per-class demo principals. The **denials** are as important as the allows — e.g.
`superadmin can_provision aws_region:aws = False` and
`cloud-denied can_connect libcloud_api:main = False`.

### The superadmin gate

`main()` **refuses to run without `SUPERADMIN_JWT`** (`openfga_bootstrap.py:
1253-1264`), returning exit code 3. `setup.sh` obtains this JWT via
`test_script/scripts/superadmin_auth.sh` (§9) and passes it through the compose
environment (`docker-compose.yml:139`). The script then forwards it as the
Bearer token — `FGA_API_TOKEN` wins if set, else `SUPERADMIN_JWT`
(`openfga_bootstrap.py:1269`) — so OpenFGA's OIDC authn accepts it (aud is
`libcloud-rest`).

### Output: `generated/fga.env`

On success the bootstrap writes `generated/fga.env` (`openfga_bootstrap.py:
1288-1297`) with four keys:

| Key | Value |
| --- | --- |
| `FGA_STORE_ID` | Minted store id |
| `FGA_MODEL_ID` | Minted authorization-model id |
| `FGA_API_URL` | `FGA_PUBLIC_API_URL` (default `http://localhost:8080`, host-facing) |
| `FGA_STORE_NAME` | `libcloud-rest-store` |

Note the subtlety: the container *talks* to OpenFGA at `http://openfga:8080`
(its `FGA_API_URL`), but the *written* `FGA_API_URL` records the host-facing
public URL. When `FGA_STORE_ID`/`FGA_MODEL_ID` are unset, runtime clients
(`libcloud.rest`, identity-service, the visualizer) **auto-discover** them by
store name and pick the latest model; `fga.env` remains the authoritative source
for host-side shell scripts (`setup.sh:565-573`).

---

## 7. `dex_bootstrap.py` — the Dex config renderer

`dex_bootstrap.py` renders Dex's config and writes the shared OIDC environment.
It has no Docker container of its own — `setup.sh` runs it directly with
`python3` (three times: §9).

### What it renders

`render_config()` (`dex_bootstrap.py:63-88`) reads `../dex/config.template.yaml`
and string-replaces eight placeholders:

| Placeholder | Replaced by |
| --- | --- |
| `__DEX_ISSUER__` | Canonical issuer (default `http://dex:5556/dex`) |
| `__CLIENT_SECRET__` | `libcloud-rest` OAuth client secret |
| `__LLDAP_BIND_DN__` | LLDAP admin bind DN |
| `__LLDAP_BIND_PW__` | LLDAP admin bind password |
| `__LLDAP_BASE_DN__` | LLDAP base DN (`dc=libcloud,dc=local`) |
| `__PORTAL_CLIENT__` | Optional `libcloud-portal` static client block |
| `__EXTRA_CONNECTORS__` | Optional google/github connector blocks |
| `__VISUALIZER_PUBLIC_CALLBACK__` | Optional visualizer redirect (when `PUBLIC_HOSTNAME` set) |

The template (`dex/config.template.yaml`) hard-codes the `libcloud-rest`
static client (the `__CLIENT_SECRET__` is injected) and the LDAP connector to
LLDAP (`host: lldap:3890`, `insecureNoSSL: true` for the single-host dev
network). There is no `staticPasswords`/`enablePasswordDB` — Dex authenticates
against LLDAP over LDAP.

### The two static clients

- `libcloud-rest` — always emitted, from the template.
- `libcloud-portal` — emitted only when `DEX_PORTAL_REDIRECT_URI` or
  `PUBLIC_HOSTNAME` is set, by `_portal_client_block()` (`dex_bootstrap.py:
  91-120`). It adds `http://localhost:3000/auth/callback` plus the public
  hostname callback.

### The conditional connectors

`_extra_connectors_block()` (`dex_bootstrap.py:123-161`) appends `google` and
`github` connectors only when their client id+secret are both set (and
`DEX_DISABLE_FEDERATION` is not set). The callback URL is forced to
`{issuer}/callback`, because Dex's google/github connectors validate that and
send it to the upstream IdP.

### Secrets are generated on first run

- `libcloud-rest` client secret: `secrets.token_urlsafe(32)` if not provided
  (`dex_bootstrap.py:283`).
- Portal client secret: `secrets.token_urlsafe(32)` if a portal client is
  requested without one (`dex_bootstrap.py:330`).
- Per-user LLDAP passwords: `_gen_password()` = `"SA-" + token_urlsafe(18)`
  (`dex_bootstrap.py:164-166`). Each is taken from the matching
  `LIBCLOUD_PASSWORD_*` env var, else reused from an existing `dex.env`, else
  generated fresh — so re-runs don't drift passwords between `dex.env` and LLDAP
  (`write_env`, `dex_bootstrap.py:208-228`).

### What it writes: `../dex/generated/dex.env`

`write_env()` (`dex_bootstrap.py:169-276`) writes `dex/generated/dex.env` with:
`DEX_URL`, `DEX_ISSUER_URL`, `DEX_JWKS_URL`, `DEX_OIDC_DISCOVERY`,
`LIBCLOUD_OIDC_CLIENT_ID`, `LIBCLOUD_OIDC_CLIENT_SECRET`, `OIDC_ISSUER_URL`,
`OIDC_JWKS_URL`, `OIDC_AUDIENCE`, the eight per-user `LIBCLOUD_USER_*` +
`LIBCLOUD_PASSWORD_*` pairs, and (conditionally) the portal client id/secret/
redirect and the google/github ids/secrets. `setup.sh` sources this file to
create the LLDAP users.

The issuer topology is subtle and worth preserving (`dex_bootstrap.py:185-191`):
`DEX_URL`/`DEX_JWKS_URL` are the **host-reachable** URLs
(`http://localhost:5556`), while `DEX_ISSUER_URL`/`OIDC_ISSUER_URL` is the
**in-container** `iss` string (`http://dex:5556/dex`) that OpenFGA validates and
fetches JWKS from.

---

## 8. `vault_bootstrap.py` — the Vault bootstrap

`vault_bootstrap.py` initialises and configures the sibling `../vault` server.
It is idempotent and **gated on `SUPERADMIN_JWT`** exactly like the OpenFGA
bootstrap (`vault_bootstrap.py:324-333`, return code 3). Sequence in `main()`:

1. `wait_for_vault()` — polls `GET /sys/init` up to 120s (`:123-133`).
2. `initialize_if_needed()` — `POST /sys/init` with **`secret_shares=1`,
   `secret_threshold=1`** (`:181-186`), i.e. a single unseal key is enough.
   Persists the root token + unseal key. On a re-run it reuses the stored values
   (`:167-179`).
3. `unseal_if_needed()` — unseals if sealed (`:189-196`).
4. `enable_kv_v2()` — mounts KV **v2** at `secret/` (`:199-215`), idempotent
   (tolerates an already-mounted path).
5. `enable_approle()` — enables the AppRole auth method at `approle/`
   (`:239-247`).
6. `ensure_orchestrator_token()` — creates the **`libcloud-vault-auth-read`**
   ACL policy (`ORCHESTRATOR_POLICY`, `:70-77`: read on
   `secret/data/libcloud-vault-auth/*`, read+list on its metadata) and issues a
   token with **`ttl=768h`, `renewable=true`** (`:218-236`) → `VAULT_TOKEN`.
   This token reads only the per-tenant AppRole login material, never the cloud
   secrets.
7. `ensure_tenant_approle()` per seeded tenant (`SEED_TENANTS`, default
   `aws,nutanix`) — creates the per-tenant `libcloud-read-<tenant>` ACL policy
   (read `secret/data/libcloud/<tenant>` + metadata), the AppRole
   `libcloud-<tenant>` bound to it (`token_ttl=60m`, `token_max_ttl=120m`), and
   stores its role_id + secret_id at
   `secret/data/libcloud-vault-auth/libcloud-<tenant>` (`:250-304`).
8. `_write_env()` — writes `vault/generated/vault.env` and `chmod 600`s it
   (`:148-164`).

### What is deliberately *not* here

- **No per-tenant backend credentials are seeded here.** Those are written by the
  tenant *owner* via `test_script/scripts/set_tenant_credentials.py`, gated on
  OpenFGA `can_manage_credentials` (owner-only) — not on global env
  (`vault_bootstrap.py:322-324, 350-353`).
- **The tenant → vault-user mapping is not created here** — that is an OpenFGA
  fact (`tenant:<t> parent vault_user:libcloud-<t>`), seeded by
  `openfga_bootstrap.py` / `create_tenant.sh`. `vault_bootstrap.py` only creates
  the Vault side (the AppRole + policy + login material).

### Output: `vault/generated/vault.env`

Four keys (`vault_bootstrap.py:150-158`): `VAULT_ADDR` (host-facing),
`VAULT_TOKEN` (the orchestrator token — reads per-tenant AppRole auth material,
not the cloud secrets), `VAULT_ROOT_TOKEN`, `VAULT_UNSEAL_KEY`.

---

## 9. Operations

### Helper scripts

| Script | Purpose |
| --- | --- |
| `enumerate_openfga.py` | Read-only walk of the whole OpenFGA HTTP surface — health, stores, models, assertions, tuples, `/changes` history, then derived `check`/`batch-check`/`expand`/`list-objects`/`list-users`, plus an AuthZEN probe. Writes `generated/enumeration_report.json`. Mutating APIs are deliberately **not** exercised. |
| `list_users.sh` | Curl `ListUsers` ("which users have relation X with object Y?"). |
| `fga_auth.sh` | Shared auth/config for the curl scripts: resolves `FGA_API_URL`/`FGA_STORE_ID`/`FGA_MODEL_ID` from `generated/fga.env` (env overrides win) and the bearer token from `FGA_API_TOKEN` → `SUPERADMIN_JWT` → `generated/tokens/superadmin.jwt`. |
| `scripts/fga-test.sh` | Container + API smoke test: health/readiness, 401-without-token, store/model queries, tuple read/check, expand/list-objects, metrics on `:2112`. Skips authenticated sections if no token. |

All three token resolvers use the same precedence order (`fga_auth.sh:10-15`,
`enumerate_openfga.py:82-92`, `scripts/fga-test.sh:99-110`).

### `model/` fixtures

`model/store.fga.yaml` and `model/isolation.fga.yaml` are `fga model test`
fixtures: the former replays 112 store decisions (68 checks + 44 list-objects); the latter asserts
cross-tenant isolation denials (derived, not replayed). Regenerate the DSL after
a model change with the CLI (see `model/README.md:59-68`). A failing
`isolation.fga.yaml` means a tenant boundary moved — a security regression.

### Re-seeding

There is no SQLite fallback. To wipe and re-seed the Postgres datastore
(`README.md:149-160`):

```bash
cd openfga_postgres && docker compose down -v   # drop openfga-pg-data
./setup.sh                                      # fresh migrate + bootstrap
```

### How `setup.sh` sequences everything

`setup.sh` drives the whole order (line refs are to `setup.sh`):

1. **Postgres password** — generated into `generated/postgres.env` and reused
   across runs so the data volume stays usable (`:57`).
2. **`dex_bootstrap.py`** run with `DEX_WAIT=0` to render Dex config + `dex.env`
   (`:308`); re-run later with `DEX_WAIT=1` after Dex starts (`:394`). The
   `libcloud-rest` OAuth client secret is reused from an existing `dex.env` on
   re-runs (`:295-305`).
3. **LLDAP** starts, and the `superadmin` user is created via the LLDAP admin
   account (`:347-356`).
4. **Postgres → migrate → OpenFGA** start, then Dex and Vault (`:360-392`).
   `setup.sh` waits on the `openfga-migrate` container exiting 0, then
   force-recreates OpenFGA after the Dex recreate to clear its cached JWKS
   (`:442-455`).
5. **superadmin login** → `SUPERADMIN_JWT` via `test_script/scripts/superadmin_auth.sh`
   (`:461-465`). This is the gate for everything after.
6. **Per-cloud LLDAP users** created (`:472-481`).
7. **`openfga-bootstrap`** runs (`:489-491`) — the superadmin-gated clean re-seed.
8. **`vault-bootstrap`** runs (`:496-497`), then per-tenant cloud credentials are
   seeded via `set_tenant_credentials.py` (`:511-545`).
9. **REST API / visualizer / portal** are force-recreated to pick up fresh
   OpenFGA + Vault state (`:564-640`); store/model IDs are auto-discovered so no
   `.env` sync is needed.

---

## 10. Security notes

These are the honest, specific findings — not aspirational hardening.

### 1. Generated secret files tracked in Git

Verified with `git ls-files` (2026-08-27):

| File | Tracked? | Contents |
| --- | --- | --- |
| `dex/generated/dex.env` | **YES** | OAuth client secret, the portal client secret, and **all eight LLDAP user passwords** (superadmin + owners/admins/viewers/denied) |
| `vault/generated/vault.env` | **YES** | The **Vault root token and unseal key**, plus the orchestrator token |
| `openfga_postgres/generated/fga.env` | **no** | Store/model ids + URL (not secret) |
| `openfga_postgres/generated/postgres.env` | **no** | Postgres credentials (auto-generated) |

`openfga_postgres/.gitignore:8` ignores `generated/`, and the repo-root
`.gitignore` has `**/generated/`, `dex.env`, `postgres.env` — but `dex/generated/
dex.env` and `vault/generated/vault.env` are nonetheless committed (they were
force-added at some point; `git check-ignore` confirms they match ignore rules,
yet `git ls-files` lists them). The `vault_bootstrap.py` output header says
"DO NOT COMMIT (gitignored)" (`vault_bootstrap.py:128`), which is **false** for
this repo: the file is committed. Anyone with repo read access gets the OAuth
client secret, every LLDAP user password, the Vault root token and the unseal
key. Treat these as compromised for anything that matters; rotating them
requires regenerating Dex/Vault and re-running the bootstraps.

### 2. OIDC-authenticates-but-does-not-authorize

See §4. OpenFGA's management API has **no per-caller authorization**. Any
`libcloud-rest`-audience token + reachability of `openfga:8080` = full control
over tuples, stores, and the model. The superadmin "gate" is a property of the
bootstrap script, not of OpenFGA. The only real boundary is `127.0.0.1` port
binding and membership of `libcloud_net`.

### 3. Postgres password auto-generated, `sslmode=disable`

`POSTGRES_PASSWORD` is auto-generated into `generated/postgres.env` and reused
across runs; OpenFGA connects with `?sslmode=disable` (plaintext) — dev-only
(`docker-compose.yml:79,100`, `.env:23`). Production wants `verify-full` + a CA
cert. The `5433` host port is published for debugging only.

### 4. Plaintext HTTP throughout

Every hop is HTTP on the dev network: OpenFGA `:8080`, the OIDC issuer
`http://dex:5556/dex`, Dex `http://localhost:5556`, Vault
`http://localhost:8200`/`http://vault:8200`, LLDAP `ldap://lldap:3890` with
`insecureNoSSL: true`. Tokens and (in the Dex login flow) passwords cross the
wire in cleartext. This is a single-host demo posture; none of it is TLS-
terminated.
