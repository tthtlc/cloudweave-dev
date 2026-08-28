# Operator Script Reference

The scripts that bring the stack up, verify it, inspect authorization, move
secrets, and migrate the whole system to an air-gapped host.

Every entry below was read against source. Companion documents:
`ARCHITECTURE.md` (system overview) and the per-subsystem `ARCHITECTURE.md`
files.

**Read §8 before running anything destructive.** Four of these scripts destroy
data or move credentials, and one has a known bug that makes it miss the volume
it claims to wipe.

---

## 1. Bootstrap and lifecycle

### `./setup.sh` — the canonical start path

Brings up the entire stack and bootstraps it. **Deliberately build-free**: it
recreates containers from pre-built images and never runs `docker compose
build`, so it works on an air-gapped host after a restore. It hard-fails if the
`openfga-local:latest` image is absent.

Runs eleven ordered steps. The pivot is **step 4**, a real Dex OIDC login as
`superadmin` producing `SUPERADMIN_JWT`:

| Step | Does |
|---|---|
| 0a | Sync `PUBLIC_HOSTNAME` into sub-project `.env` files; seed `my.env` |
| 0a–0c | Persist the generated Postgres password; verify the vendored libcloud tree and the `openfga-local` image; clear stale containers |
| 1 | Render `dex/config.yaml` + write `dex/generated/dex.env` |
| 2 | Start LLDAP, apply the custom schema, create `superadmin` |
| 3 | Start Postgres → OpenFGA → Dex → Vault |
| **4** | **superadmin Dex login → `SUPERADMIN_JWT` (gates everything below)** |
| 5 | Create the seven per-tenant LLDAP users |
| 6 | OpenFGA bootstrap: store + model + 48 tuples |
| 7 / 7a | Vault init/unseal/KV v2; seed per-tenant cloud credentials |
| 8–10 | Restart REST API + visualizer; recreate the portal; host-side venv |

Steps 5, 6 and 7 refuse to run without step 4's JWT — bootstrap uses the same
identity path a human would, not a backdoor. The JWT is verified by running
`verify_superadmin_jwt.py` *inside* the identity-service container, so the host
needs no Python crypto dependency.

Idempotent: safe to re-run. Generated passwords are reused across runs so data
volumes stay usable.

```bash
./setup.sh
```

### `./rebuild_all.sh` — the online counterpart

Run this on the **internet-connected** machine after editing source. It rebuilds
every compose project declaring a `build:` directive (the `pip install` /
`apt-get` inside those builds need network), then re-runs `setup.sh`.

Deliberately skips: `libcloud.rest/docker-compose.dev.yml` (dev overlay),
`docker-compose.swagger.yml` (image pull), `migrate2internal/tmp/*`, and
`libcloud/contrib/docker/nutanix/*`. Version-pinned base images (dex, vault,
postgres, swagger-ui) are pulled on `up`, not rebuilt.

```bash
./rebuild_all.sh
```

### `./test_script/shutdown.sh` — graceful stop

The mirror of `setup.sh`. Stops containers in **reverse dependency order**
(consumers first, identity and secret stores last) so in-flight requests drain,
and keeps volumes by default.

| Flag | Effect |
|---|---|
| *(none)* | Stop everything, keep volumes and `libcloud_net` |
| `--keep-rest` | Leave `libcloud-rest-api` up; stop only IdP / authz / Vault |
| `--purge-network` | Also remove the `libcloud_net` network |
| `--wipe` | **DESTRUCTIVE** — `docker compose down -v` on every project |

Survives a normal shutdown: `lldap_data`, `vault-data`, `api-data`, and the
OpenFGA store. Lost by design: Dex's in-memory OAuth state and refresh tokens
(users must re-login) and the Nutanix mock's in-memory stores.

> **Known bug.** The header and the `--wipe` warning both name `openfga-data`,
> the volume of the removed SQLite-backed `openfga_my` deployment
> (`shutdown.sh:11,55`). The live tuple store is
> `openfga_postgres_openfga-pg-data`. The docstring is stale, and the warning
> misnames what is actually at risk.

### `./openfga_postgres/myrun.sh` — rebuild OpenFGA only

A six-line convenience wrapper: rebuild the `openfga` image, then force-recreate
`openfga-migrate` and `openfga`. Use after bumping `OPENFGA_VERSION` /
`OPENFGA_TARBALL_SHA256`. Migrations must be allowed to complete — do not skip
`openfga-migrate`.

---

## 2. Verifying the identity service

All four run against a live `identity-service` container. `BASE_URL` defaults to
`http://localhost:8766`. All exit `0` on success, `1` on any failure — safe in CI.

### `identity_service/smoke_test.sh` — is it up and sane?

Fast black-box checks: container state, liveness, Dex wiring, session guards, and
the error contract. The quick triage script; the other three go deeper.

```bash
./smoke_test.sh
CONTAINER_NAME=identity-service BASE_URL=http://host:8766 ./smoke_test.sh
```

### `identity_service/verify_auth.sh` — auth-path hardening

Asserts each hardening guarantee of the state/PKCE and pending-identity work
still holds: server-issued single-use `state`, the PKCE verifier staying
server-side, and `/api/auth/collapse` rejecting anything but a server-issued
pending token. Run after any change to `auth_state.py`, `dex.py`, or `session.py`.

### `identity_service/verify_authz_matrix.sh` — the role matrix

The regression net for a real bug: the portal rendered a Provision button from
`/api/session` capabilities while the verb routes authorized a **different
principal**. It fails if capability flags ever diverge from route gates again.

Two layers:

- **[A]** In-process consistency test via FastAPI `TestClient` inside the
  container. Covers all users including pending federated ones — the bug class —
  with `LibcloudProxy` stubbed, so **no real VMs are touched**.
- **[B]** Live HTTP matrix over every seeded user × cloud × verb. Denied verbs
  must return `403 authz_forbidden`; allowed write verbs are probed with bogus VM
  ids so the gate is exercised without creating anything.

```bash
./verify_authz_matrix.sh                  # gate matrix only, no real VMs
FULL_LIFECYCLE=1 ./verify_authz_matrix.sh # also provisions and destroys a REAL VM
```

> **Note what layer [B] does.** It mints **forged session cookies** using the
> container's own `SESSION_SECRET`. That is a legitimate test technique — and it
> is also a working demonstration of the critical finding that `SESSION_SECRET`
> is never generated by bootstrap and stays at its placeholder value. See
> `ARCHITECTURE.md` §9.

### `identity_service/verify_provision.sh` — real provisioning replay

Exercises the provisioning replay end-to-end against the libcloud REST API.
**By default it creates a real EC2 or Nutanix VM and then tears it down.**

It calls the proxy module inside the container directly, bypassing the cookie
authorization on `/api/provision/*` — it tests replay mechanics, not the session
gate (that is `verify_auth.sh`'s job).

```bash
./verify_provision.sh                # AWS, provision + teardown
CLOUD=nutanix ./verify_provision.sh  # Nutanix
TEARDOWN=0 ./verify_provision.sh     # keep the VM — you will be billed
```

Exits `0` only if the replay reaches `POST /v1/compute/nodes` with 200.

---

## 3. Verifying the REST API and OpenFGA

### `libcloud.rest/scripts/rest-api-test.sh` — the RBAC matrix (1 022 lines)

The most comprehensive test in the repo. Tests **every** user from
`dex/generated/dex.env` against both AWS and Nutanix endpoints, validates
cross-tenant isolation, and can optionally provision real cloud resources.

```bash
./scripts/rest-api-test.sh [base_url] [container_name]
# defaults: http://localhost:8765, libcloud-rest-api
```

| Env var | Effect |
|---|---|
| `SKIP_RBAC=1` | Skip the multi-user matrix (sections 5–8) |
| `SKIP_LOGIN_TEST=1` | Skip the login-attempt test |
| `SKIP_PROVISION=1` | Skip provisioning and Vault checks |
| `PROVISION=1` | **Actually create cloud resources** |
| `TEARDOWN_VMS=1` | Clean up provisioned VMs afterwards |
| `VERBOSE=1` | Full HTTP request/response logging |
| `BEARER_TOKEN` | With `SKIP_RBAC=1`, run the legacy single-token test |

Pair `PROVISION=1` with `TEARDOWN_VMS=1` unless you intend to keep the instances.

### `openfga_postgres/scripts/fga-test.sh` — OpenFGA health and correctness

Verifies the `openfga-postgres` and `openfga` containers are healthy and serving
correctly on `http://localhost:8080`.

```bash
./scripts/fga-test.sh [fga_url] [pg_container] [fga_container]
```

Token resolution (identical to `fga_auth.sh`): `$FGA_API_TOKEN` →
`$SUPERADMIN_JWT` → `generated/tokens/superadmin.jwt` if unexpired. With no
token, authenticated tests are **skipped with a warning** rather than failing —
so read the output; a pass with skips is not a full pass.

`/healthz` and `/readyz` are unauthenticated; tuple read/write and check are not.

---

## 4. Inspecting authorization

### `openfga_postgres/fga_auth.sh` — shared auth helper (sourced, not run)

Exports `FGA_API_URL`, `FGA_STORE_ID`, `FGA_MODEL_ID` (env overrides beat
`generated/fga.env`, which beats the localhost default) and resolves
`FGA_BEARER` by the three-step chain above. Sourced by the curl-based scripts so
token logic lives in one place.

If it cannot find a token, run `test_script/scripts/superadmin_auth.sh` first.

### `openfga_postgres/list_users.sh` — who has relation X on object Y?

A curl wrapper for OpenFGA's ListUsers API (requires the server started with
`--experimentals enable-list-users`).

```bash
./list_users.sh <relation> <type:id> [user_type] [options]
./list_users.sh owner tenant:aws user
```

| Option | Effect |
|---|---|
| `--store-id ID` / `--model-id ID` | Override `generated/fga.env` |
| `--raw` | Print the full raw API response |
| `--table` | One rendered user per line instead of a JSON array |

Output is a JSON array whose entries are an object (`user:alice`), a userset
(`group:eng#member`), or a typed wildcard (`user:*`).

For a visual view of the same data, use the OpenFGA visualizer on port 5050.

---

## 5. Vault credential operations

Both scripts read the **Vault root token** from `vault/generated/vault.env`.
Treat them as privileged.

### `test_script/get_admin_vault.sh` — read tenant credentials

Prints the decoded AWS and Nutanix credentials from
`secret/data/libcloud/{nutanix,aws}` via `jq .data.data`.

**This writes live cloud credentials to your terminal in plaintext.** Do not run
it in a shared session, a recorded terminal, or anywhere the scrollback is kept.

### `test_script/set_admin_vault.sh` — seed tenant credentials

Sources `dex/generated/dex.env` and `tenant_vault_secret.env`, then calls
`set_tenant_credentials.py` once per tenant as that tenant's **owner**. The
Python script performs its own Dex login and an OpenFGA `can_manage_credentials`
check before writing — so the authorization path is exercised, not bypassed.

> `test_script/tenant_vault_secret.env` is **tracked in git** and holds real AWS
> and Nutanix credentials. See §8.

---

## 6. Air-gapped migration

The four scripts that move the whole system to an isolated host. Run in order.

### `migrate2internal/install_docker_in_rocky.sh` — prerequisite (RHEL/Rocky)

Twenty-one lines: `dnf upgrade`, add Docker's official RHEL repo, install
`docker-ce`, CLI, containerd, buildx and the Compose v2 plugin, then
`systemctl enable --now docker`. Needs network and `sudo`; run only on the
destination host if Docker is absent.

### `migrate2internal/backup-system.sh` — on the SOURCE machine

Produces `~/offline/backup/` containing container images, project files, named
volumes, bind mounts, and SSH config. No OS packages are installed, so it works
on any Linux with Docker. A helper `alpine` image reads volumes without needing
root on `/var/lib/docker`.

```bash
PROJECT_ROOT=$HOME/libcloud_nutanix ./backup-system.sh
```

> The backup contains **every secret in the system** — Vault's storage volume,
> `dex/generated/dex.env`, and LLDAP's user database. Treat `~/offline/` as
> equivalent to the root token and move it only over an encrypted channel.

### `migrate2internal/transfer-backup.sh` — ship it

Copies `~/offline/` to the isolated host through the bastion, using an SSH
`ProxyJump` (`source → bastion → internal`) read from `~/.ssh/config`.

```bash
./transfer-backup.sh --dry-run   # show what would transfer
./transfer-backup.sh             # rsync it
./transfer-backup.sh --resume    # resume an interrupted transfer
```

**Environment-specific.** The source, bastion and destination addresses and the
`internal` host alias are hardcoded in the script header and body. Adapt them —
or the matching `~/.ssh/config` stanzas — before use.

### `migrate2internal/restore-system.sh` — on the DESTINATION machine

Loads the images, restores volumes, bind mounts and project files, then starts
the stack. **No builds, no pulls, no apt**: it `docker load`s what the backup
saved and runs `docker compose up --no-build --pull=never`, so the `build:`
directives still in the compose files are inert.

Retargeting is done with plain environment variables:

```bash
DRY_RUN=1 ./restore-system.sh                                  # rehearse
PUBLIC_HOSTNAME=rocky96 NUTANIX_HOST=192.0.2.10 ./restore-system.sh
```

`PUBLIC_HOSTNAME` is the single knob that moves every externally-reachable URL —
Dex issuer, OIDC redirects, portal callback, CORS origins. Always rehearse with
`DRY_RUN=1` first.

---

## 7. Development utilities

### `libcloud.rest/run-swagger.sh` — browse the API

Regenerates the OpenAPI spec and serves it via Swagger UI (default port 8080).

```bash
./run-swagger.sh              # regenerate + start
./run-swagger.sh --no-gen     # use the existing spec
./run-swagger.sh --port 9090
./run-swagger.sh --stop
```

Port 8080 collides with OpenFGA's published HTTP port — use `--port` if OpenFGA
is up.

### `test_script/master_dbg.sh` — all container logs at once

Splits a tmux session into one pane per running container, each tailing
`docker logs -f`. Requires `tmux`. Replaces any existing session of the same
name.

```bash
./master_dbg.sh [session-name]     # detach: Ctrl+b d
tmux kill-session -t master_dbg
```

### `test_script/myrun_nutanix.sh` — personal Nutanix scratch runner

A developer convenience wrapper that seeds Nutanix tenant credentials and then
runs a caller-supplied script as `ntnx-admin` with `PROVISION=1`. Takes the
target script as `$1`; most of the file is commented-out variants.

> **Do not use as a template, and do not copy it.** It contains a **hardcoded
> plaintext LLDAP password and OIDC client secret**, and it is **tracked in
> git**. It is a fifth committed-secrets file beyond the four listed in
> `ARCHITECTURE.md` §9. Rotate those values and move the file to
> `tenant_vault_secret.env` (already gitignored in intent, though also currently
> tracked) or to the environment.

---

## 8. Safety notes

### Scripts that destroy data

| Script | Risk |
|---|---|
| `shutdown.sh --wipe` | `down -v` on every project. Vault unseal key, OpenFGA tuples and LLDAP users are gone permanently. **Also see the stale-volume bug in §1** — it may not remove the volume it names. |
| `docker_teardown.sh` | Host-wide, not repo-scoped. Removes every container, volume and network on the daemon, including unrelated projects. |
| `verify_provision.sh` | Creates a real billable VM by default. `TEARDOWN=0` keeps it. |
| `rest-api-test.sh` with `PROVISION=1` | Creates real cloud resources. Pair with `TEARDOWN_VMS=1`. |

### Scripts that expose credentials

- `get_admin_vault.sh` prints live cloud credentials to stdout.
- `backup-system.sh` packages every secret in the system into `~/offline/`.
- `set_admin_vault.sh` and `myrun_nutanix.sh` read from files holding real
  credentials.

### Secrets committed to git

`git ls-files` confirms **eleven** tracked files contain live secrets:

| File | Contains |
|---|---|
| `vault/generated/vault.env` | Vault root token and unseal key |
| `dex/generated/dex.env` | OAuth client secrets, all eight LLDAP passwords |
| `dex/config.yaml` | OAuth client secrets, LLDAP admin bind password |
| `test_script/tenant_vault_secret.env` | AWS access key/secret, Nutanix credentials |
| `test_script/myrun_nutanix.sh` | LLDAP password, OIDC client secret |
| `test_script/myrun_nutanix_query.sh` | same class |
| `test_script/myrun_aws_admin.sh` | same class |
| `test_script/myrun_aws_query.sh` | same class |
| `test_script/myrun_aws_view.sh` | same class |
| `test_script/doc/provision_aws.md` | Real AWS key/secret, bind password, client secret pasted into a walkthrough |
| `test_script/doc/provision_aws.stderr` | Captured output with the same values |

The whole `myrun_*.sh` family shares this pattern — they are personal scratch
runners with credentials inlined. The last two rows are the ones an audit is
most likely to miss: a Markdown walkthrough and a captured stderr log.

`.gitignore` cannot untrack a file added before the rule existed. Remediation is
`git rm --cached`, **rotate every value**, then purge history — untracking alone
leaves them readable in every clone. See `ARCHITECTURE.md` §9 finding 1.

### Ordering

`setup.sh` must complete before any verification script — they all depend on
`dex/generated/dex.env` and a bootstrapped OpenFGA store. If a script reports a
missing token, run `test_script/scripts/superadmin_auth.sh` first.
