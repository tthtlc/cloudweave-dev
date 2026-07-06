# Dex — OIDC Gateway for the libcloud security stack

Dex is the **stable OIDC front door** for the libcloud REST API, OpenFGA, and the
host-side provisioning scripts. It does **not** own a user directory of its own;
it federates authentication to **LLDAP** (`../lldap`) over an LDAP connector and
issues the JWTs that **OpenFGA** (`../openfga_my`) validates on every call.

This directory is a **standalone Docker Compose project** that runs the Dex
container named **`dex`** on the shared external `libcloud_net` network.

---

## 1. Role in the stack

```
                 browser / host scripts
                          │  (http://localhost:5556/dex)
                          ▼
                       ┌──────┐
                       │ dex  │  Dex OIDC issuer (this project)
                       └──┬───┘
          LDAP bind        │        OIDC JWKS / discovery
   ldap://lldap:3890       │        http://dex:5556/dex/keys
          ▼                │                ▼
       ┌──────┐            │            ┌─────────┐
       │lldap │            │            │openfga  │  validates `iss`+`aud`+sig
       └──────┘            │            └─────────┘
   user directory          │            authorization
   (uid, mail, cn)         │
                           └──► libcloud REST API (OAuth client `libcloud-rest`)
```

- **Identity provider (upstream):** LLDAP — users, passwords, group membership.
  Reached at `ldap://lldap:3890` over `libcloud_net`.
- **OIDC issuer (this service):** Dex — issues access/ID/refresh tokens, exposes
  discovery + JWKS, registers the OAuth client `libcloud-rest`.
- **Relying parties (downstream):**
  - **libcloud REST API** — performs the authorization-code flow; uses Dex as
    IdP for user login.
  - **OpenFGA** — does **not** do a login flow; it validates the JWT that the
    caller already obtained from Dex, by fetching JWKS from
    `http://dex:5556/dex/keys` and checking `iss=http://dex:5556/dex` and
    `aud=libcloud-rest`.
  - **Host provisioning scripts** — `scripts/idp_login.py`,
    `scripts/superadmin_auth.sh`, `scripts/verify_superadmin_jwt.py` obtain and
    verify tokens via the host-published port `http://localhost:5556`.

The same Dex-issued access token is therefore accepted by both the libcloud REST
API and OpenFGA — one IdP, one audience (`libcloud-rest`), one JWKS endpoint.

---

## 2. Files in this directory

| File | Purpose |
| --- | --- |
| `config.template.yaml` | Template rendered by `../openfga_my/dex_bootstrap.py`. Placeholders: `__DEX_ISSUER__`, `__CLIENT_SECRET__`, `__LLDAP_BIND_DN__`, `__LLDAP_BIND_PW__`, `__LLDAP_BASE_DN__`. |
| `config.yaml` | Rendered, runtime config — mounted read-only into the container at `/etc/dex/config.yaml`. **Do not edit by hand;** re-run `dex_bootstrap.py` instead. |
| `config.phase2.example.yaml` | Optional phase-2 snippet showing Dex federating to an upstream external IdP (Entra ID / Authentik) as an additional OIDC connector. Merge into `config.yaml` on cutover. |
| `docker-compose.yml` | Standalone compose project that runs the `dex` container. |
| `.env.example` | Host port override (`DEX_HTTP_PORT=5556`). |
| `generated/dex.env` | Emitted by `dex_bootstrap.py`; consumed by libcloud REST API, OpenFGA compose (`../openfga_my`), and host scripts. Contains issuer/JWKS/discovery URLs, OAuth client secret, and per-user LLDAP passwords. |

---

## 3. Configuration (`config.yaml`)

Dex is **config-driven** with **in-memory storage** (`storage.type: memory`).
There is no `staticPasswords` block and no `enablePasswordDB`; the user
directory lives entirely in LLDAP. Restarting the container loses ephemeral
OAuth state (in-flight flows, refresh tokens) but **not** user identity, because
users are looked up fresh from LLDAP on every login.

### Issuer and listener

```yaml
issuer: http://dex:5556/dex
web:
  http: 0.0.0.0:5556
```

The **canonical issuer** is the **in-container DNS URL** `http://dex:5556/dex`,
not `http://localhost:5556/dex`. This is deliberate:

- Dex puts `iss: http://dex:5556/dex` into every token it mints.
- In-cluster consumers on `libcloud_net` (OpenFGA, libcloud REST API) validate
  `iss` against this exact string and fetch JWKS from
  `http://dex:5556/dex/keys` — which they can resolve because they share the
  network.
- Host-side scripts cannot resolve the `dex` DNS name, so they use the
  host-published port `http://localhost:5556/dex/...` for discovery, JWKS, the
  token endpoint, and the browser flow. `generated/dex.env` exposes both forms
  (see §5).

### OAuth2

```yaml
oauth2:
  skipApprovalScreen: true
  responseTypes: ["code"]
  grantTypes: ["authorization_code", "refresh_token"]
```

Authorization-code with PKCE-style flow + refresh tokens; the approval screen is
skipped because there is exactly one first-party client.

### Static client

```yaml
staticClients:
  - id: libcloud-rest
    name: libcloud REST API
    secret: <rendered from LIBCLOUD_OIDC_CLIENT_SECRET>
    redirectURIs:
      - http://127.0.0.1:8766/oauth/callback
      - http://localhost:8765/oauth/callback
```

`libcloud-rest` is the **single OAuth client** shared by the libcloud REST API
and (as the token `aud` claim) by OpenFGA. The secret is generated by
`dex_bootstrap.py` (`secrets.token_urlsafe(32)`) unless `LIBCLOUD_OIDC_CLIENT_SECRET`
is provided, then written to `generated/dex.env`.

### LDAP connector → LLDAP

```yaml
connectors:
  - type: ldap
    id: lldap
    name: LLDAP
    config:
      host: lldap:3890
      insecureNoSSL: true
      bindDN: uid=admin,ou=people,dc=libcloud,dc=local
      bindPW: <rendered from LLDAP_BIND_PW>
      userSearch:
        baseDN: ou=people,dc=libcloud,dc=local
        filter: "(objectClass=person)"
        username: uid
        idAttr: uid
        emailAttr: mail
        nameAttr: cn
```

- `host: lldap:3890` — LLDAP is on `libcloud_net`, resolved by container DNS.
- `insecureNoSSL: true` — fine for the single-host dev network. **For
  production**, switch to LDAPS (`startTLS` or `ssl: true`) and a valid CA.
- The service-account bind (`uid=admin,…`) is used **only** for user lookups;
  the user's own password is verified by Dex binding as that user during login.
- Attribute mapping is what keeps principals stable across the stack:

  | LLDAP attr | Dex claim | Used by |
  | --- | --- | --- |
  | `uid` (e.g. `cloud-admin`) | OIDC `sub` | OpenFGA tuples (`user:cloud-admin`), `principal_map` `by_sub` |
  | `mail` (e.g. `cloud-admin@libcloud.local`) | OIDC `email` | libcloud REST API `principal_map` `by_email` |
  | `cn` | OIDC `name` | display only |

  The user types their `uid` (e.g. `cloud-admin`) at the Dex login form.

There is **no group search** configured — group/membership enforcement is done
by OpenFGA tuples, not by Dex claims. See `../openfga_my/authorization.md`.

### Phase-2 federation (optional)

`config.phase2.example.yaml` shows adding a second upstream connector
(`type: oidc`) for Entra ID or Authentik, so Dex stays the stable issuer while
the user directory moves upstream. On cutover: add `by_sub` entries to
`data/principal_map.json` for each upstream object ID, disable any password db,
and leave OpenFGA tuples unchanged (still `user:cloud-admin`, etc.).

---

## 4. Runtime — Docker container `dex`

`docker-compose.yml`:

```yaml
services:
  dex:
    image: ghcr.io/dexidp/dex:v2.41.1
    container_name: dex
    restart: unless-stopped
    networks:
      - libcloud_net
    ports:
      - "${DEX_HTTP_PORT:-5556}:5556"
    volumes:
      - ./config.yaml:/etc/dex/config.yaml:ro
    command: ["dex", "serve", "/etc/dex/config.yaml"]
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "-",
             "http://127.0.0.1:5556/dex/.well-known/openid-configuration"]
      interval: 5s
      timeout: 5s
      retries: 12
      start_period: 5s

networks:
  libcloud_net:
    external: true
```

Key points:

- **Image:** `ghcr.io/dexidp/dex:v2.41.1` (pinned).
- **Container name:** `dex` — this is the DNS name other containers on
  `libcloud_net` use to reach it (`http://dex:5556/dex`), and the name the
  issuer string is built from.
- **Network:** `libcloud_net` (external) — the shared bridge network across all
  sibling compose projects (`../lldap`, `../openfga_my`, `../vault`,
  `../libcloud.rest`). Created by `../openfga_my/setup.sh` before Dex starts.
- **Port:** host `5556` → container `5556`, overridable via `DEX_HTTP_PORT`.
  This is the **host-side** entry point for browsers and provisioning scripts.
- **Config mount:** `./config.yaml` is mounted **read-only** at
  `/etc/dex/config.yaml`. Dex runs `dex serve /etc/dex/config.yaml`.
- **Healthcheck:** probes
  `http://127.0.0.1:5556/dex/.well-known/openid-configuration` (OIDC discovery)
  every 5 s, 12 retries, 5 s start period.

### Lifecycle

Dex is started by `../openfga_my/setup.sh` as part of the joint bootstrap:

1. `setup.sh` sources `../lldap/.env` to obtain `LLDAP_BIND_PW`,
   `LLDAP_BASE_DN`, etc.
2. `dex_bootstrap.py` renders `config.yaml` from `config.template.yaml` and
   writes `generated/dex.env` (first pass, `DEX_WAIT=0`).
3. `setup.sh` creates `libcloud_net` if missing, then
   `docker compose -f ../dex/docker-compose.yml up -d dex`.
4. `dex_bootstrap.py` runs a second time (`DEX_WAIT=1`) to confirm the OIDC
   discovery endpoint is reachable, then `up -d --force-recreate dex` to make
   sure the final config is loaded.
5. `setup.sh` waits for `http://localhost:5556/dex/.well-known/openid-configuration`
   to return 200 before continuing to the superadmin login + OpenFGA bootstrap.

Manual control (from this directory):

```bash
docker compose up -d dex        # start
docker compose restart dex      # reload after editing config.yaml
docker compose logs -f dex      # logs (json format)
docker compose down             # stop (keeps config + generated/)
```

`storage.type: memory` means `docker compose down` (or `up --force-recreate`)
drops in-flight OAuth state and refresh tokens. Users must re-login; this is
intentional for a dev/single-host deployment.

---

## 5. `generated/dex.env` — what consumers read

Emitted by `../openfga_my/dex_bootstrap.py`. Two URL forms are exposed because
in-cluster and host-side callers see different DNS:

| Variable | Value | Used by |
| --- | --- | --- |
| `DEX_URL` | `http://localhost:5556` | host scripts (browser, token endpoint) |
| `DEX_ISSUER_URL` | `http://dex:5556/dex` | canonical issuer (`iss` claim) |
| `DEX_JWKS_URL` | `http://localhost:5556/dex/keys` | host-side JWKS fetch |
| `DEX_OIDC_DISCOVERY` | `http://localhost:5556/dex/.well-known/openid-configuration` | host-side discovery |
| `OIDC_ISSUER_URL` | `http://dex:5556/dex` | OpenFGA (`--authn-oidc-issuer`) |
| `OIDC_JWKS_URL` | `http://dex:5556/dex/keys` | in-cluster JWKS |
| `OIDC_AUDIENCE` | `libcloud-rest` | OpenFGA (`--authn-oidc-audience`) + REST API |
| `LIBCLOUD_OIDC_CLIENT_ID` | `libcloud-rest` | OAuth client id |
| `LIBCLOUD_OIDC_CLIENT_SECRET` | `<random>` | OAuth client secret (also in `config.yaml`) |
| `LIBCLOUD_USER_*` / `LIBCLOUD_PASSWORD_*` | per-user | host scripts (`idp_login.py`, `superadmin_auth.sh`) — these users live in LLDAP; the passwords here are used to log in **through Dex** and to seed LLDAP on first run. |

The split between `DEX_JWKS_URL` (host) and `OIDC_JWKS_URL` (in-cluster) is the
mechanism that lets the same token be validated both by host scripts
(`verify_superadmin_jwt.py`) and by OpenFGA running inside `libcloud_net`.

---

## 6. OpenFGA consumption

`../openfga_my/docker-compose.yml` starts OpenFGA with:

```
--authn-method=oidc
--authn-oidc-issuer=http://dex:5556/dex
--authn-oidc-audience=libcloud-rest
```

So every OpenFGA API call must carry a Dex-issued JWT with
`iss=http://dex:5556/dex` and `aud=libcloud-rest`. OpenFGA fetches signing keys
from `http://dex:5556/dex/keys` (reachable on `libcloud_net`). The caller
obtains that token by logging in to Dex (via `idp_login.py` or
`superadmin_auth.sh`), which authenticates the user against LLDAP through the
LDAP connector. The `sub` claim (the LLDAP `uid`) is the principal OpenFGA
tuples are written against (`user:cloud-admin`, `user:aws-admin`, …).

---

## 7. Security notes

- The rendered `config.yaml` and `generated/dex.env` contain the LLDAP admin
  bind password, the OAuth client secret, and per-user passwords. They are
  git-ignored (see `.gitignore`); never commit them.
- `insecureNoSSL: true` on the LDAP connector is acceptable on the isolated
  single-host `libcloud_net`; for production use LDAPS with a real CA.
- The issuer is plain `http://` — fine on `libcloud_net` and localhost; put a
  TLS-terminating reverse proxy in front for any non-local exposure and change
  `issuer`/redirect URIs accordingly.
- `skipApprovalScreen: true` is safe because the only client is first-party.
- Rotate the OAuth client secret with `scripts/openfga-presharedkey-rotate.sh`
  (re-runs `dex_bootstrap.py` and recreates the `dex` container).
