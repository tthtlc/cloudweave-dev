# libcloud Portal Identity Service

Backend for `../server` (the role portal). Implements the `/api/*` contract
documented in `../server/README.md` by orchestrating the already-running stack:

```
Dex          -> token exchange + ID-token verification   (DEX_PORTAL_CLIENT_SECRET)
LLDAP        -> internal user directory                   (uid, mail, cn)
OpenFGA      -> authorization (roles + per-cloud can_use/can_provision)
libcloud-rest -> cloud resources + provisioning          (:8765, Vault-backed creds)
```

The portal is a browser-side SPA; this service is the **integration tier** that
turns a Dex authorization code into a server-side session, maps external
identities (google/github) to stable internal users (with the identity-collapse
flow), enforces roles via OpenFGA, and proxies cloud calls to the libcloud REST
API — which holds the backend cloud identity in Vault. The browser never sees
provider tokens or cloud credentials.

## Endpoints

| Method | Path | AuthZ | Purpose |
|--------|------|-------|---------|
| GET    | `/health` | none | liveness |
| GET    | `/api/session` | cookie | restore session on page load |
| POST   | `/api/auth/exchange` | code | Dex code -> session; resolve internal user; collapse or provision |
| POST   | `/api/auth/collapse` | pending | link/keep a new external identity |
| POST   | `/api/logout` | cookie | revoke session + Dex refresh token |
| GET    | `/api/users` | superadmin | list internal users |
| PATCH  | `/api/users/:id/role` | superadmin | change a user's role (OpenFGA re-keyed) |
| GET    | `/api/resources/aws` | viewer+ (can_use) | list AWS compute nodes + categorized inventory (VPCs, subnets, SGs, ENIs, route tables, IGWs, EIPs, AMIs, volumes, snapshots, buckets, key pairs; via libcloud-rest) |
| GET    | `/api/resources/nutanix` | viewer+ (can_use) | list Nutanix compute nodes + categorized inventory (clusters, VPCs, subnets, Flow SGs, load balancers, images, volumes, storage containers, buckets, key pairs; via libcloud-rest) |
| POST   | `/api/provision/aws` | admin+ (can_provision) | queue AWS provisioning job |
| POST   | `/api/provision/nutanix` | admin+ (can_provision) | queue Nutanix provisioning job |

## Run

```bash
# from the identity_service/ directory
export SESSION_SECRET="$(python3 -c 'import secrets;print(secrets.token_urlsafe(48))')"
docker compose up -d --build
curl -fsS http://localhost:8766/health   # -> {"status":"ok"}
```

`docker-compose.yml` mounts `dex/generated/dex.env`, `openfga_postgres/generated/fga.env`,
and `lldap/.env` via `env_file` (so `DEX_PORTAL_CLIENT_SECRET`, `FGA_STORE_ID`,
`FGA_MODEL_ID`, `LLDAP_LDAP_USER_PASS` are available) and overrides the host-side
URLs in those files with in-container forms (`http://dex:5556/dex`,
`http://openfga:8080`, `lldap`, `http://libcloud-rest-api:8765`) via `environment:`,
which takes precedence over `env_file`.

## How login flows through this service

1. Browser -> Dex authorize (Google/GitHub) -> Dex redirects to
   `http://login.quest4science.xyz:3000/auth/callback?code=...&state=...`
2. Portal's `/auth/callback` calls `POST /api/auth/exchange` with the code.
3. This service:
   - validates `state` (TODO: server-issued nonce + PKCE),
   - exchanges the code at `http://dex:5556/dex/token` using `DEX_PORTAL_CLIENT_SECRET`,
   - verifies the returned ID token (JWKS, iss/aud/exp),
   - builds the external identity `<provider>:<sub>`,
   - resolves an internal user (existing / collapse-required / brand-new viewer),
   - mints an **httpOnly** session cookie (signed JWT) carrying `internalUserId`,
     `role`, `email`, `linkedIdentities`; the Dex refresh token is kept
     **server-side only**, keyed by session id.
4. If `needsIdentityCollapse`, the portal routes to `/identity/collapse` and calls
   `POST /api/auth/collapse` with the user's link/keep decision. Backend policy
   may override `keep` -> `link`.
5. Subsequent calls authenticate via the cookie; authorization is re-checked
   against OpenFGA on every request (frontend role checks are UX-only).

## What is stubbed (TODOs in code)

- **`state`/PKCE validation**: verify a server-issued nonce. *(done in Path 1)*
- **Pending-identity binding** in `collapse`: bind the pending identity to a
  server-side pending token issued at exchange time so collapse can't be called
  out of band. *(done in Path 1)*
- **Refresh-token revocation** in `logout`: call Dex's revocation endpoint.
- **LLDAP `linkedIdentities`**: map provider subjects onto LLDAP users (custom
  attribute or side table) so subject linking survives restarts; today the
  in-memory `_pending_users` registry tracks new logins.
- **Session store**: in-memory `_refresh_store`; move to Redis for multi-replica.

## Provisioning replay (Path 2 — implemented)

`libcloud_proxy.provision()` replays the exact orchestration order from
`test_script/scripts/provision_{aws,nutanix}.sh` against the libcloud REST API
(`:8765`):

1. `idp_login` — the identity service logs into Dex as a per-cloud provisioner
   LLDAP user (`aws-admin` / `ntnx-admin`) via the LDAP connector, obtaining a
   `libcloud-rest`-audience OIDC token. This is the same flow
   `test_script/scripts/idp_login.py` uses, but WITHOUT an ephemeral callback
   server: the login form is POSTed with redirects disabled and the auth code
   is read from the 302 `Location` header (reusing the already-registered
   `http://127.0.0.1:8766/oauth/callback` redirect URI). Tokens are cached with
   refresh.
2. `build_{aws,nutanix}_connection_param` — the `X-Provider-Connection` header
   (provider + region/host + `auth_binding`, **no credentials in client**).
3. `GET /v1/auth/me` (token validation) → `POST /v1/connections:test`.
4. catalog discovery (`locations`, `sizes`, `images`, `storage-containers` for Nutanix).
5. `GET /v1/compute/nodes` + `GET /v1/compute/subnets`.
6. resolve image/size/subnet (and cluster for Nutanix). AWS uses a port of
   `aws_resolve_catalog.py` to pick an architecture-compatible (x86_64) AMI +
   instance type pair so AWS doesn't reject the create.
7. `POST /v1/compute/nodes`.

Portal-user authorization is enforced by the identity service via OpenFGA
(`can_provision` on the cloud's backend object) BEFORE the replay runs; the
REST API then does its own OpenFGA check against the provisioner token subject.

**Note on OpenFGA JWKS:** Dex rotates its signing keys every 6h (in-memory
storage). OpenFGA v1.16.0+ (pinned in `openfga_postgres/Dockerfile`) enables
`RefreshUnknownKID` in its OIDC authenticator, so an unknown `kid` after a Dex
rotation makes OpenFGA refetch Dex's JWKS in-process — no restart and no helper
script needed. (Older OpenFGA images cached the JWKS at startup and needed a
container restart after each rotation; the `openfga_ensure_fresh.sh` workaround
for that era has been removed.) If checks fail with `invalid_claims` now, the
cause is token validation (iss/aud/exp), not a stale JWKS cache.

## Files

```
identity_service/
├── app/
│   ├── main.py            # FastAPI app + 10 routes + CORS + session/role deps
│   ├── config.py          # settings (Dex/OIDC/FGA/LLDAP/libcloud-rest URLs)
│   ├── models.py          # pydantic request/response models
│   ├── dex.py             # token exchange + ID-token verification (JWKS)
│   ├── session.py         # httpOnly signed-cookie session; server-side refresh store
│   ├── users.py           # external->internal resolution + collapse + role set
│   ├── lldap.py           # LLDAP user directory (ldap3)
│   ├── fga.py             # OpenFGA check + write; role<->relation mapping
│   ├── libcloud_proxy.py  # real provision_*.sh replay against libcloud-rest :8765
│   ├── idp_login.py       # provisioner Dex LDAP login (libcloud-rest token), no ephemeral server
│   ├── aws_resolve.py     # arch-compatible AMI + instance-type picker (port of aws_resolve_catalog.py)
│   └── errors.py          # APIError + handler
├── Dockerfile
├── docker-compose.yml
├── requirements.txt
└── .env.example
```
