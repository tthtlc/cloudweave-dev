# Dex — OIDC Gateway for the libcloud security stack

Dex is the **stable OIDC front door** for the libcloud REST API, OpenFGA, and the
host-side provisioning scripts. It does **not** own a user directory of its own;
it federates authentication to **LLDAP** (`../lldap`) over an LDAP connector and
issues the JWTs that **OpenFGA** (`../openfga_postgres`) validates on every call.

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
  discovery + JWKS, registers **two** static OAuth clients: `libcloud-rest`
  (service accounts / CLI scripts / OpenFGA audience) and `libcloud-portal`
  (browser login via the role portal).
- **Relying parties (downstream):**
  - **libcloud REST API** — in `auth_mode=oidc` (the default) it does **not**
    run a login flow; it only **validates** the Dex bearer JWT on each request
    against JWKS / issuer / audience (`libcloud.rest/app/auth/oidc_service.py`).
    The authorization-code flow is run by `test_script/scripts/idp_login.py` and
    `identity_service/app/idp_login.py`.
  - **Role portal** — browser login via identity-service using the
    `libcloud-portal` client; this is the only flow that uses PKCE S256.
  - **OpenFGA** — does **not** do a login flow; it validates the JWT that the
    caller already obtained from Dex, by fetching JWKS from
    `http://dex:5556/dex/keys` and checking `iss=http://dex:5556/dex` and
    `aud=libcloud-rest`.
  - **Host provisioning scripts** — `test_script/scripts/idp_login.py`,
    `test_script/scripts/superadmin_auth.sh`,
    `test_script/scripts/verify_superadmin_jwt.py` obtain and verify tokens via
    the host-published port `http://localhost:5556`. `verify_superadmin_jwt.py`
    is executed **inside** the identity-service container via `docker exec`
    (see `superadmin_auth.sh`).

The same Dex-issued access token is therefore accepted by both the libcloud REST
API and OpenFGA — one IdP, one audience (`libcloud-rest`), one JWKS endpoint.

---

## 2. Files in this directory

| File | Purpose |
| --- | --- |
| `config.template.yaml` | Template rendered by `../openfga_postgres/dex_bootstrap.py`. Placeholders: `__DEX_ISSUER__`, `__CLIENT_SECRET__`, `__LLDAP_BIND_DN__`, `__LLDAP_BIND_PW__`, `__LLDAP_BASE_DN__`. |
| `config.yaml` | Rendered, runtime config — mounted read-only into the container at `/etc/dex/config.yaml`. **Do not edit by hand;** re-run `dex_bootstrap.py` instead. |
| `config.phase2.example.yaml` | Illustrative phase-2 snippet (Entra ID / Authentik). The federation that is **actually implemented** is Google + GitHub, emitted by `dex_bootstrap.py` (`_extra_connectors_block`) when `DEX_GOOGLE_*` / `DEX_GITHUB_*` are set — see §3. |
| `docker-compose.yml` | Standalone compose project that runs the `dex` container. |
| `.env.example` | Host port override (`DEX_HTTP_PORT=5556`). |
| `generated/dex.env` | Emitted by `dex_bootstrap.py`; consumed by libcloud REST API, OpenFGA compose (`../openfga_postgres`), and host scripts. Contains issuer/JWKS/discovery URLs, OAuth client secret, and per-user LLDAP passwords. |

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

Authorization-code flow + refresh tokens; the approval screen is skipped because
all clients are first-party. PKCE S256 is used **only** for the `libcloud-portal`
browser flow (identity-service mints the code verifier/challenge in
`identity_service/app/auth_state.py`); the `libcloud-rest` service-account / CLI
flow authenticates with the client secret and does **not** use PKCE.

### Static clients

```yaml
staticClients:
  - id: libcloud-rest
    name: libcloud REST API
    secret: <rendered from LIBCLOUD_OIDC_CLIENT_SECRET>
    redirectURIs:
      - http://127.0.0.1:8766/oauth/callback    # identity-service /oauth/callback
      - http://localhost:8765/oauth/callback    # libcloud-rest-api (legacy/alternate)
      - http://127.0.0.1:8767/oauth/callback    # host-script callback (idp_login.py)
      - http://localhost:5050/callback          # OpenFGA RBAC visualizer
      - http://127.0.0.1:5050/callback
      - http://rocky96:5050/callback

  - id: libcloud-portal
    name: libcloud Role Portal
    secret: <rendered from DEX_PORTAL_CLIENT_SECRET>
    redirectURIs:
      - http://localhost:3000/auth/callback
      - http://rocky96:3000/auth/callback
```

There are **two** static clients:

- **`libcloud-rest`** — shared by the libcloud REST API, the host provisioning
  scripts, and (as the token `aud` claim) OpenFGA. It authenticates with a
  client secret; no PKCE. Its six redirect URIs cover the identity-service
  callback (`:8766`), the REST API itself (`:8765`), the host-script callback
  (`:8767`, used by `test_script/scripts/idp_login.py` — 8767 was chosen because
  8766 is published by the identity-service container), and the OpenFGA RBAC
  visualizer (`:5050`).
- **`libcloud-portal`** — the role portal (`../server`), whose browser login via
  identity-service uses PKCE S256. Its two redirect URIs cover localhost and the
  public hostname (`:3000/auth/callback`).

The `libcloud-rest` secret is generated by `dex_bootstrap.py`
(`secrets.token_urlsafe(32)`) unless `LIBCLOUD_OIDC_CLIENT_SECRET` is provided,
then written to `generated/dex.env`. The portal client block is rendered by
`dex_bootstrap.py` (`_portal_client_block`) when `DEX_PORTAL_REDIRECT_URI` /
`PUBLIC_HOSTNAME` is set.

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
by OpenFGA tuples, not by Dex claims. See `../openfga_postgres/authorization.md`.

### Federation (optional)

`dex_bootstrap.py` (`_extra_connectors_block`) can append **Google** and
**GitHub** upstream connectors, emitting `type: google` / `type: github` when
`DEX_GOOGLE_CLIENT_ID`+`DEX_GOOGLE_CLIENT_SECRET` and
`DEX_GITHUB_CLIENT_ID`+`DEX_GITHUB_CLIENT_SECRET` are set. The role portal login
screen shows the corresponding buttons (`server/src/pages/LoginPage.js`). The
LDAP connector stays the primary directory for the libcloud REST API + OpenFGA.
For **air-gapped** installs set `DEX_DISABLE_FEDERATION=1`, which forces the
Google/GitHub connectors off regardless of credential values. (The checked-in
`config.phase2.example.yaml` is an unrelated Entra ID / Authentik example, not
the implemented path.)

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
      - "127.0.0.1:${DEX_HTTP_PORT:-5556}:5556"
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
  sibling compose projects (`../lldap`, `../openfga_postgres`, `../vault`,
  `../libcloud.rest`). Created by `../openfga_postgres/setup.sh` before Dex starts.
- **Port:** bound to **loopback only** (`127.0.0.1:5556` → container `5556`),
  overridable via `DEX_HTTP_PORT`. This is the **host-side** entry point for
  provisioning scripts. Browsers never reach port 5556 directly — the role
  portal's nginx proxies `/dex/` to the `dex` container (`server/Dockerfile`).
- **Config mount:** `./config.yaml` is mounted **read-only** at
  `/etc/dex/config.yaml`. Dex runs `dex serve /etc/dex/config.yaml`.
- **Healthcheck:** probes
  `http://127.0.0.1:5556/dex/.well-known/openid-configuration` (OIDC discovery)
  every 5 s, 12 retries, 5 s start period.

### Lifecycle

Dex is started by `../openfga_postgres/setup.sh` as part of the joint bootstrap:

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

Emitted by `../openfga_postgres/dex_bootstrap.py`. Two URL forms are exposed because
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
| `DEX_PORTAL_CLIENT_ID` | `libcloud-portal` | role portal OAuth client id (emitted when `DEX_PORTAL_REDIRECT_URI`/`PUBLIC_HOSTNAME` set) |
| `DEX_PORTAL_CLIENT_SECRET` | `<random>` | role portal OAuth client secret (also in `config.yaml`) |
| `DEX_PORTAL_REDIRECT_URI` | `http://<host>:3000/auth/callback` | role portal callback |
| `DEX_GOOGLE_CLIENT_ID` / `DEX_GOOGLE_CLIENT_SECRET` | optional | Google federation (only when set) |
| `DEX_GITHUB_CLIENT_ID` / `DEX_GITHUB_CLIENT_SECRET` | optional | GitHub federation (only when set) |

The split between `DEX_JWKS_URL` (host) and `OIDC_JWKS_URL` (in-cluster) is the
mechanism that lets the same token be validated both by host scripts
(`verify_superadmin_jwt.py`) and by OpenFGA running inside `libcloud_net`.

---

## 6. OpenFGA consumption

`../openfga_postgres/docker-compose.yml` starts OpenFGA with:

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
- `skipApprovalScreen: true` is safe because all clients are first-party.
- To rotate the OAuth client secret, regenerate it with `dex_bootstrap.py`
  (which re-renders `config.yaml`), then recreate the container:
  `docker compose -f dex/docker-compose.yml up -d --force-recreate dex` (see
  `setup.sh`). Note: `test_script/scripts/openfga-presharedkey-rotate.sh`
  rotates the **OpenFGA** preshared key in Vault and does **not** touch Dex.
