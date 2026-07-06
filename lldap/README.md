# LLDAP — User Directory for libcloud (fully containerized)

Everything runs in Docker — LLDAP **and** the management tooling. The only host
dependency is Docker (Compose v2). No `curl`, `jq`, `openssl`, `python` or
`ldap-utils` required on the host.

Users are managed with six fields:

| Your field   | UI / GraphQL attribute | LDAP attribute | Type             |
|--------------|------------------------|----------------|------------------|
| email        | `mail`                 | `mail`         | built-in         |
| username     | `user_id` / `id`       | `uid`          | built-in (login) |
| name         | `display_name`         | `cn`           | built-in         |
| department   | `department`           | `department`   | custom attribute |
| role         | `role`                 | `role`         | custom attribute |
| job desc     | `jobtitle`             | `jobtitle`     | custom attribute |

## Layout

```
lldap/
  docker-compose.yml   # lldap + lldap-tools + bootstrap services
  Dockerfile           # image for the management tooling (curl/jq/openssl/ldap3)
  .env                 # secrets, base DN, ports (do not commit)
  Makefile             # convenience targets
  scripts/
    setup-schema.sh    # create the custom attributes (idempotent)
    create-user.sh     # create a user with all six fields + set password
    set-password.py    # reset a user password over LDAP (PasswordModify)
    verify-ldap.py     # list users / verify a bind over LDAP
```

## Quick start

```bash
make bootstrap   # builds tools, starts LLDAP (detached), applies custom attributes
```

Then either open the Web UI or keep using `make`:

```bash
make verify                                          # list users over LDAP
make create U=jdoe E=john.doe@libcloud.local N="John Doe" \
     D=Engineering R="Software Engineer,On-Call" J="Senior Backend Engineer"
# `R` is a comma-separated list -> role: ["Software Engineer","On-Call"]
# password auto-generated and printed; or pass P=...
```

## What runs where

- `lldap` — the LLDAP server (image `lldap/lldap`), ports `3890` (LDAP) and
  `17170` (Web UI), data in the `lldap_data` volume.
- `lldap-tools` — built from `Dockerfile` (`python:3.12-slim` + `curl`, `jq`,
  `openssl`, `ldap3`). Runs on demand via `docker compose run --rm`, gated
  behind the `tools` profile so plain `docker compose up` won't start it.
- `bootstrap` — same image, runs `setup-schema.sh` once via the `bootstrap`
  profile.

The tools container talks to LLDAP over the compose network
(`LLDAP_URL=http://lldap:17170`, `LLDAP_LDAP_URL=ldap://lldap:3890`). Passwords
are set over LDAP using the PasswordModify extended operation — no
`docker exec` into the LLDAP container is needed.

## Access

- **Web UI:** http://localhost:17170 — log in as `admin` (password in `.env`).
- **LDAP:** `ldap://localhost:3890`
  - Bind DN: `uid=admin,ou=people,dc=libcloud,dc=local`
  - User base: `ou=people,dc=libcloud,dc=local`
  - Group base: `ou=groups,dc=libcloud,dc=local`
  - User filter: `(&(uid={0})(objectClass=person))`
  - Mail filter: `(&(mail={0})(objectClass=person))`

## Common commands

```bash
make up          # start LLDAP only
make down        # stop (keeps data)
make schema      # (re)apply custom attributes
make verify      # list users + attributes over LDAP
make create U=.. E=.. N=.. D=.. R=.. J=.. [P=..]
make clean       # stop and wipe ALL data
```

Equivalents without `make`:

```bash
docker compose up -d
docker compose --profile bootstrap up --build
docker compose run --rm lldap-tools /scripts/setup-schema.sh
docker compose run --rm lldap-tools /scripts/create-user.sh jdoe \
    john.doe@libcloud.local "John Doe" Engineering "Software Engineer" "Senior Backend Engineer"
docker compose run --rm lldap-tools /scripts/verify-ldap.py
```

## Verifying over LDAP from the host

If you happen to have `ldap-utils` installed you can query directly:

```bash
ldapsearch -x -H ldap://localhost:3890 \
  -D "uid=admin,ou=people,dc=libcloud,dc=local" -W \
  -b "ou=people,dc=libcloud,dc=local" "(uid=jdoe)" \
  uid mail cn department role jobtitle
```

But the containerized equivalent (`make verify`) needs no host tooling.
