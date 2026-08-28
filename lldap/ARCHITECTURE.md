# LLDAP Architecture — libcloud deployment

This document captures the design, setup, and customization of the LLDAP
instance in this repository: what it provides, how the containers fit
together, how the user schema was extended for the six managed fields, and the
operational flows for creating and verifying users. It is the reference for
*why* the setup looks the way it does; see `README.md` for *how* to use it.

## Goals

- A lightweight LDAP server for creating and managing users in the libcloud
  stack.
- Users are described by exactly six fields:
  `email`, `username`, `name`, `department`, `role`, `job description`.
- Everything runs in Docker — the server **and** all management tooling — so
  the only host dependency is Docker (Compose v2). No host `curl`, `jq`,
  `openssl`, `python`, `ldap-utils`, or `docker exec` is required.

## What LLDAP provides

LLDAP is a single-container lightweight LDAP server with an embedded DB, a web
UI for user/group/credential management, and a scriptable GraphQL API. It
exposes:

- LDAP bind/search on port `3890` (LDAPS `6360` optional, not enabled here).
- A web UI on port `17170`.
- A GraphQL API at `/api/graphql` and an HTTP auth API at `/auth/simple/login`,
  `/auth/refresh`, `/auth/logout`.
- A conventional directory tree rooted at a configurable base DN, with users
  under `ou=people` and groups under `ou=groups`.
- A built-in `admin` user used as the manager DN for apps that search the
  directory.

Out of the box, LLDAP user objects expose: `uid` (login id), `mail`,
`displayName`, `firstName`, `lastName`, `avatar`, plus system attributes
(`uuid`, `creation_date`, `modified_date`, `password_modified_date`). It also
supports **custom user attributes** added through the GraphQL API or the
bootstrap schema files — this is how `department`, `role`, and `jobtitle` are
introduced.

## Field mapping

Three of the six requested fields map onto built-in LLDAP attributes; the
other three are custom attributes created via the GraphQL `addUserAttribute`
mutation. Over LDAP, LLDAP exposes `displayName` as the standard `cn`
attribute.

| Your field   | Web UI / GraphQL attribute | LDAP attribute | Origin             |
|--------------|----------------------------|----------------|--------------------|
| email        | `mail`                     | `mail`         | built-in           |
| username     | `user_id` / `id`           | `uid`          | built-in (login)   |
| name         | `display_name`             | `cn`           | built-in           |
| department   | `department`               | `department`   | custom attribute   |
| role         | `role`                     | `role`         | custom attribute   |
| job desc     | `jobtitle`                 | `jobtitle`     | custom attribute   |

The custom attributes are defined as STRING, editable and visible.
`department` and `jobtitle` are single-valued; `role` is **multi-valued**
(`isList: true` in `scripts/setup-schema.sh`, the authoritative source — the
JSON at `bootstrap/user-schemas/custom-attributes.json` records all three as
`isList: false` but is never applied). Once registered in the schema they
appear in the web UI user form and are returned by LDAP searches.

## Container topology

Three services are defined in `docker-compose.yml`:

```
              +-------------------+       3890  LDAP
   host  ---->|   lldap           |------>------>  ou=people, ou=groups
   :17170---->|   (lldap/lldap)   |       17170 Web UI / GraphQL / auth
              +-------------------+
                       ^  depends_on (service_healthy)
                       |
              +-------------------+
              |  lldap-tools      |  on-demand:  setup-schema / create-user
              |  (built locally)  |  /scripts/*   verify-ldap / set-password
              +-------------------+
                       ^  depends_on (service_healthy)
                       |
              +-------------------+
              |  bootstrap        |  one-shot:    setup-schema.sh
              |  (built locally)  |  profile:bootstrap
              +-------------------+
```

### `lldap` (server)

- Image `lldap/lldap:latest`, `restart: unless-stopped`.
- Host ports `127.0.0.1:${LLDAP_LDAP_PORT}:3890` (LDAP) and
  `127.0.0.1:${LLDAP_HTTP_PORT}:17170` (Web UI), loopback-only, configurable
  via `.env`.
- Persistent data in the named volume `lldap_data` mounted at `/data` (holds
  the embedded DB and generated `lldap_config.toml`).
- Runs rootless as UID/GID 1000.
- Configuration is supplied entirely via environment variables interpolated
  from `.env`:
  - `LLDAP_JWT_SECRET` — session token secret for the web UI/API.
  - `LLDAP_LDAP_USER_PASS` — initial `admin` password (also the LDAP bind
    password and web UI login password).
  - `LLDAP_LDAP_BASE_DN` — directory root (`dc=libcloud,dc=local`). Chosen
    once, up front, to avoid refactoring later.
  - `LLDAP_HTTP_ADDR=0.0.0.0`, `LLDAP_LDAP_HOST=0.0.0.0` — bind on all
    interfaces inside the container.
- The compose file defines its own explicit healthcheck (`curl -fsS
  http://127.0.0.1:17170/`) at `docker-compose.yml` lines 23-28, so
  `depends_on` can use `condition: service_healthy` for the tooling services.

### `lldap-tools` (management tooling)

- Built locally from `Dockerfile` (`python:3.12-slim` + `curl`, `jq`,
  `openssl`, `ca-certificates`, `ldap3`).
- Gated behind the `tools` profile, so `docker compose up` starts only `lldap`;
  the tools container is invoked on demand with
  `docker compose run --rm lldap-tools /scripts/<script>`.
- `depends_on: lldap (service_healthy)` so it never runs before the server is
  ready.
- Connects to the server over the compose network using service-DNS names:
  - `LLDAP_URL=http://lldap:17170` (GraphQL + auth API)
  - `LLDAP_LDAP_URL=ldap://lldap:3890` (LDAP bind/search/password modify)
- `LLDAP_ADMIN_USER=admin` is the HTTP login username; the Python scripts
  derive the LDAP bind DN from it as
  `uid=${LLDAP_ADMIN_USER},ou=people,${LLDAP_BASE_DN}`.
- `ENTRYPOINT []` in the image so scripts execute directly via their shebangs
  (`#!/usr/bin/env bash` / `#!/usr/bin/env python3`).

### `bootstrap` (one-shot schema apply)

- Same image as `lldap-tools`, behind the `bootstrap` profile.
- `entrypoint: ["bash", "/scripts/setup-schema.sh"]`, `restart: "no"`.
- Run with `docker compose -f docker-compose.yml --profile bootstrap up
  bootstrap` to (re)apply the custom attribute schema idempotently after the
  server is up (this is what `setup.sh` invokes).

## Customizing the schema

LLDAP custom attributes are created through the GraphQL
`addUserAttribute(name, attributeType, isList, isVisible, isEditable)` mutation
(authenticated with an admin JWT). The mutation is idempotent in practice: a
repeat call returns an "already exists" error which the script treats as
success.

`scripts/setup-schema.sh` performs, in order:

1. Waits for the web UI to respond at `${LLDAP_URL}/`.
2. Authenticates via `POST /auth/simple/login` with
   `{"username":"admin","password":"<LLDAP_ADMIN_PASS>"}`, extracting the
   `token` (JWT, valid 1 day; refresh token valid 30 days).
3. For each of `department`, `role`, `jobtitle`, calls `addUserAttribute` with
   `attributeType: STRING, isVisible: true, isEditable: true` — `isList: false`
   for `department` and `jobtitle`, but `isList: true` for `role` (see the
   `create_attr` calls at the end of `scripts/setup-schema.sh`).
4. Queries `schema { userSchema { attributes { ... } } }` and prints the
   resulting schema as JSON.

A matching JSON is also recorded in
`bootstrap/user-schemas/custom-attributes.json`, but it is **never mounted or
read**: the `lldap` container mounts only `lldap_data:/data` and sets no
`USER_SCHEMAS_DIR` (see `docker-compose.yml` lines 12-22). That JSON is a stale
reference only — and it disagrees with the script, recording `role` as
`isList: false`. The GraphQL script is what this deployment actually applies,
so it is authoritative.

### Adding a new field later

1. (Optional — the JSON is not read by the deployment) Add an entry to
   `bootstrap/user-schemas/custom-attributes.json` for reference.
2. Add a `create_attr <name> <is_list>` call to `scripts/setup-schema.sh`.
3. Re-run `docker compose -f docker-compose.yml --profile bootstrap up
   bootstrap` (or `docker compose run --rm lldap-tools
   /scripts/setup-schema.sh`).
4. Reference the new attribute in `scripts/create-user.sh`'s `ATTRS` block.

## Creating users

`scripts/create-user.sh` implements user creation with all six fields:

```
create-user.sh <username> <email> <name> <department> <role> <jobtitle> [password]
```

Flow:

1. Logs in via `/auth/simple/login` to obtain an admin JWT.
2. Calls the GraphQL `createUser` mutation with `id`, `email`, `displayName`,
   and an `attributes` array containing `department`, `role`, `jobtitle`
   (each `{name, value:[...]}`; for non-list attributes the value vector must
   contain exactly one element).
3. Sets the user's password by invoking `scripts/set-password.py`, which binds
   as admin over LDAP and uses the **PasswordModify extended operation** to
   reset the user's password.
4. Prints the created user (GraphQL response) and the username/password on
   stderr. If no password is supplied, a random one is generated with
   `openssl rand`.

Using LDAP PasswordModify (rather than the `lldap_set_password` binary shipped
inside the LLDAP container) is the key choice that makes the tooling fully
container-independent: the tools container only needs network reachability to
LLDAP, not `docker exec` access into the server container.

## Verifying the directory

`scripts/verify-ldap.py` binds as admin, searches `ou=people,<base>` for
`(objectClass=person)`, and prints `uid`, `mail`, `cn`, `department`, `role`,
`jobtitle` for each entry. With optional `<uid> [password]` arguments it also
binds as that user to confirm the password works — useful as a smoke test after
creating a user.

## External LDAP client integration

Apps integrating against this directory use generic "OpenLDAP" mode with:

- LDAP URL: `ldap://localhost:3890` (host) or `ldap://lldap:3890` (compose
  network).
- Bind DN: `uid=admin,ou=people,dc=libcloud,dc=local`.
- Bind password: `LLDAP_LDAP_USER_PASS` from `.env`.
- User search base: `ou=people,dc=libcloud,dc=local`.
- Group search base: `ou=groups,dc=libcloud,dc=local`.
- User filter: `(&(uid={0})(objectClass=person))`.
- Mail-based login filter: `(&(mail={0})(objectClass=person))`, or
  `(&(|(uid={0})(mail={0}))(objectClass=person))` to accept both.

Custom attributes are queryable over LDAP by name (`department`, `role`,
`jobtitle`).

## Configuration & secrets

All environment-specific values live in `.env` (generated, not committed):

- `LLDAP_JWT_SECRET` — long random hex (`openssl rand -hex 32`).
- `LLDAP_LDAP_USER_PASS` — admin password.
- `LLDAP_LDAP_BASE_DN` — `dc=libcloud,dc=local`.
- `LLDAP_HTTP_PORT` / `LLDAP_LDAP_PORT` — host port mappings (17170 / 3890).

The base DN should be chosen once and not changed after users exist, because
existing DNs are anchored to it.

## Operational flows

| Action                      | Command                                                                    |
|-----------------------------|----------------------------------------------------------------------------|
| Start server                | `docker compose up -d`                                                     |
| Apply custom schema (once)  | `docker compose --profile bootstrap up bootstrap`                          |
| (Re)apply schema on demand  | `docker compose run --rm lldap-tools /scripts/setup-schema.sh`             |
| Create a user               | `docker compose run --rm lldap-tools /scripts/create-user.sh ...`          |
| List/verify users over LDAP | `docker compose run --rm lldap-tools /scripts/verify-ldap.py`              |
| Stop (keep data)            | `docker compose down`                                                      |
| Stop and wipe all data      | `docker compose down -v`                                                   |

The `Makefile` wraps these as `make bootstrap / schema / create / verify /
up / down / clean` for convenience where `make` is available (it is an
optional layer; the `docker compose` commands are the canonical interface).

## Design notes & constraints learned

- **LLDAP has no GraphQL `login` mutation.** Authentication is a separate REST
  endpoint, `POST /auth/simple/login`, returning `{token, refreshToken}`. The
  token is sent as `Authorization: Bearer <token>` to `/api/graphql`.
- **`Success` type is `{ ok: Boolean }`**, not `{ success }`. Mutations like
  `addUserAttribute` return `.data.<mutation>.ok`.
- **Password cannot be set via GraphQL** at the time of user creation. Options
  are the in-container `lldap_set_password` binary or the LDAP PasswordModify
  extended operation; this deployment uses the latter to avoid `docker exec`.
- **`displayName` is exposed over LDAP as `cn`** (standard `commonName`), not
  as `displayName`. LDAP clients should request `cn` for the user's name.
- **Custom attributes are not removable by simply deleting them from the
  schema file** — LLDAP's cleanup does not remove old custom attributes
  automatically. Treat schema additions as append-only, or remove them
  explicitly via `deleteUserAttribute`.
- **Tooling services must use profiles.** Without a profile, `docker compose
  up` would try to start the one-shot `bootstrap`/`lldap-tools` services on
  every run. Profiles keep `up` limited to the long-running `lldap` service.
- **Healthcheck-driven ordering.** The compose file defines its own explicit
  healthcheck for `lldap`, which lets `depends_on` use `service_healthy` so
  tooling does not race the server on first boot.
