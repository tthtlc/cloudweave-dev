# OpenFGA RBAC Visualizer

Single-file Flask dashboard with **its own authentication screen**. It is a
separate application: it never picks up previously authenticated credentials
(no token files, no shared browser session). Users sign in through the
project's Dex SSO (authorization-code flow); the issued JWT is kept in a
server-side session and used as the bearer token for every OpenFGA call,
so all checks run *as the logged-in user*.

Once authenticated it shows the complete RBAC flow of the live store:

- **Hierarchy** — interactive D3 collapsible tree of the full object
  hierarchy (`platform:main` → tenants → providers / resource classes /
  backends), with user role grants as leaf nodes. Shared objects
  (e.g. `libcloud_api:main`) are marked `⇄ shared`.
- **Permission Matrix** — for any object, a users × relations grid where
  every cell is a live OpenFGA check: `●` direct tuple grant, `○`
  inherited/computed through the model, `·` no access.
- **Check** — ad-hoc *"does user U have relation R on object O?"*, the
  derivation tree (`expand`), and *"everything user X can do"*.
- **Model** — the authorization model with human-readable rewrite rules
  (`direct`, `= alias`, `parent -> relation`, unions) and directly
  assignable types.

## Run

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python app.py          # -> http://${PUBLIC_HOSTNAME:-localhost}:5050
```

Open http://${PUBLIC_HOSTNAME}:5050 (default http://localhost:5050) — you are redirected to the dashboard's own
sign-in page, then to Dex, then back. **Only the LLDAP superadmin account
is allowed in**; every other login (Google, GitHub, or any other LLDAP
user) is denied at the callback — see below.

## Run with Docker

```bash
docker build -t openfga-rbac-visualizer .
docker run --rm --network host \
  -v "$PWD/../dex/config.yaml:/app/dex-config.yaml:ro" \
  -e DEX_CONFIG=/app/dex-config.yaml \
  openfga-rbac-visualizer
```

or simply `docker compose up --build` (the compose file uses host
networking, so OpenFGA at `localhost:8080`, Dex, and the registered
`http://${PUBLIC_HOSTNAME}:5050/callback` redirect URI all behave exactly like the
bare-metal run; a bridge-network variant is commented in
`docker-compose.yml`).

## How authentication works

- OpenFGA pins OIDC audience `libcloud-rest`
  (`OPENFGA_AUTHN_OIDC_AUDIENCE` in `openfga_postgres/.env`), so the
  dashboard signs users in through the existing `libcloud-rest` Dex client.
  Any other client id would produce tokens OpenFGA rejects (`invalid_claims`).
- The dashboard's callback URLs are registered in `dex/config.yaml`
  (staticClients → `libcloud-rest` → `redirectURIs`, port-5050 entries).
  Changing the port or host spelling requires a matching entry there and a
  Dex restart (`docker restart dex`).
- The OAuth client secret is read from `../dex/config.yaml` at request time
  (override with `OIDC_CLIENT_SECRET`). The id token is verified against
  Dex's JWKS (signature, issuer, audience, expiry, nonce).
- Login sessions live in the app's memory (the cookie carries only an
  opaque id) and expire with the token, after 12 h at the latest. Restarting
  the app logs everyone out.

## Access gate: LLDAP superadmin only

Dex deliberately issues the same token shape for every connector
(`lldap`, `google`, `github`) — there is **no connector id and no role/group
claim in the JWT**, so the app cannot ask the token "did you come from
LLDAP?". Instead the callback gate (`is_superadmin` in `app.py`) pins the
identity only the LLDAP superadmin can produce:

- default: the `email` claim must equal `SUPERADMIN_EMAIL`
  (`superadmin@libcloud.local`, the LLDAP `mail` attribute — no Google or
  GitHub account can claim it), and
- strongest: set `SUPERADMIN_SUB` to the superadmin's exact Dex `sub`.
  Dex derives `sub` from user id **+ connector id**, so that value is
  unique to the LLDAP connector. After one sign-in attempt, copy it from
  the `login denied … sub=…` warning in the app log.

Everyone else is redirected back to the login page with
"only the LLDAP superadmin account may sign in" and gets no session.

## Configuration

Defaults match the surrounding libcloud project; override with env vars:

| Variable | Default |
|---|---|
| `OPENFGA_API_URL` | `http://localhost:8080` |
| `OPENFGA_STORE_ID` | `01KXFQ6JWFD2MZKFDFSHYNNNXE` |
| `OPENFGA_MODEL_ID` | `01KXWWZY8424AMK2B443FH7TQ0` |
| `OIDC_ISSUER` | `http://login.quest4science.xyz:5556/dex` |
| `OIDC_CLIENT_ID` | `libcloud-rest` |
| `OIDC_CLIENT_SECRET` | read from `../dex/config.yaml` |
| `OAUTH_REDIRECT_URI` | derived from request host |
| `SUPERADMIN_EMAIL` | `superadmin@libcloud.local` |
| `SUPERADMIN_SUB` | unset (strongest pin when set) |
| `FLASK_SECRET_KEY` | generated into `./.flask_secret` |
| `PORT` | `5050` |

`static/d3.v7.min.js` is vendored so the dashboard works offline; if it is
missing the page falls back to the D3 CDN.
