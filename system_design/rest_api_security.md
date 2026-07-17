
For **client compromise and REST API compromise**, the easiest strong pattern is: **OIDC/OAuth2 for the client to authenticate to your API, and IAM roles for the API to access AWS**. Do not mint `GetSessionToken` per client request. That adds credential-vending risk without solving either compromise scenario well. [docs.aws.amazon](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/security-iam-roles.html)

## Recommended pattern

Use this split: [docs.aws.amazon](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-integrate-with-cognito.html)

- Client authenticates with **OIDC/OAuth2** and gets a short-lived JWT access token.
- Client sends `Authorization: Bearer <JWT>` to the REST API.
- REST API validates the token, then uses its **own AWS identity** through an IAM role attached to the compute platform, such as ECS task role, EKS IRSA, or EC2 instance profile. AWS rotates these credentials automatically. [docs.aws.amazon](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- REST API never receives long-term AWS keys from the client, and the client never receives AWS credentials. [docs.aws.amazon](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/security-iam-roles.html)

This is easier to implement because each side has one job: user/session auth at the app layer, AWS auth at the infrastructure layer. OIDC is also a better fit than SAML for application protocols because it uses HTTP/JSON flows. [aws.amazon](https://aws.amazon.com/blogs/security/approaches-for-authenticating-external-applications-in-a-machine-to-machine-scenario/)

## Why this is better

For **client compromise**, a stolen app token can be limited with short TTL, scopes, audience checks, revocation strategy, and API-side rate limits. A stolen AWS credential set is usually worse because it directly authorizes backend cloud actions. [docs.aws.amazon](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-integrate-with-cognito.html)

For **REST API compromise**, the blast radius is controlled by the IAM role attached to that service. ECS task roles and EKS IRSA issue temporary credentials automatically and rotate them, so you avoid storing root or IAM user access keys in an “authenticator” service.  With `GetSessionToken`, the temp credentials inherit the caller’s permissions, which often makes accidental over-privilege more likely than a tightly scoped role-based design. [docs.aws.amazon](https://docs.aws.amazon.com/STS/latest/APIReference/API_GetSessionToken.html)

## Practical standards

### Client to API

Use one of these, ordered by ease:

| Option | What it does | Fit |
|---|---|---|
| **Cognito User Pool + API Gateway authorizer** | Managed login and JWT validation at the API edge.  [docs.aws.amazon](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-integrate-with-cognito.html) | Easiest if you are already on AWS. |
| Any OIDC provider + JWT validation in app | Your API verifies issuer, audience, expiry, and signature via JWKS.  [aws.amazon](https://aws.amazon.com/blogs/security/approaches-for-authenticating-external-applications-in-a-machine-to-machine-scenario/) | Good when you already use Auth0, Okta, Entra ID, Keycloak. |
| OAuth2 client credentials | For machine-to-machine clients, not end users.  [aws.amazon](https://aws.amazon.com/blogs/security/approaches-for-authenticating-external-applications-in-a-machine-to-machine-scenario/) | Good for service callers. |

If your “client” is a browser or mobile app, Cognito User Pools or another OIDC IdP is usually the cleanest path. API Gateway can enforce Cognito user-pool tokens before traffic even reaches your backend. [docs.aws.amazon](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-integrate-with-cognito.html)

### API to AWS

Use compute-native AWS identity:

- **ECS task role** for containers on ECS; credentials are temporary and automatically rotated, and exposed to the SDK through the container credential endpoint. [docs.aws.amazon](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/security-iam-roles.html)
- **EKS IRSA** for Kubernetes; the pod uses a service-account token and STS `AssumeRoleWithWebIdentity` to get temporary credentials for the bound IAM role. [docs.aws.amazon](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- **EC2 instance profile** if the API runs on EC2. This follows the same role-based pattern. [docs.aws.amazon](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/security-iam-roles.html)

This is the AWS standard alternative to passing AWS credentials around between services. [docs.aws.amazon](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)

## Simple protocol flow

A minimal secure flow looks like this: [docs.aws.amazon](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-integrate-with-cognito.html)

1. User signs in to OIDC provider and receives JWT access token.
2. Client calls REST API with bearer token.
3. API validates JWT claims: signature, issuer, audience, expiry, scopes.
4. API performs business authorization in app logic.
5. API calls AWS using its local role-backed SDK credentials.
6. AWS authorizes only what that service role allows.

That gives you **separation of concerns**: user identity is not mixed with cloud credentials. [aws.amazon](https://aws.amazon.com/blogs/security/approaches-for-authenticating-external-applications-in-a-machine-to-machine-scenario/)

## Easy implementation choices

If you want the least engineering effort on AWS:

- **Frontend/mobile app:** Cognito User Pool.
- **API entry:** API Gateway with Cognito authorizer. [docs.aws.amazon](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-integrate-with-cognito.html)
- **Backend compute:** Lambda, ECS, or EKS with attached IAM role. [docs.aws.amazon](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- **AWS SDK:** use default credential chain; no explicit access key handling in code. [docs.aws.amazon](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/security-iam-roles.html)

If you are not using API Gateway, validating JWTs in a Node, Go, or Python REST API is still straightforward because OIDC exposes standard JWKS-based signature verification. OIDC is specifically positioned as application-friendly compared with SAML. [aws.amazon](https://aws.amazon.com/blogs/security/approaches-for-authenticating-external-applications-in-a-machine-to-machine-scenario/)

## Threat-model notes

This design does **not** eliminate damage from a compromised REST API server; nothing can, if the server is the actor calling AWS. It does, however, constrain damage to the service role’s permissions and avoids turning your auth service into a credential mint for attackers. [docs.aws.amazon](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)

For compromised clients, use:

- Short JWT TTLs.
- Refresh token rotation if applicable.
- Scope-based access tokens.
- Device/session revocation.
- Rate limiting and anomaly detection at the API. [aws.amazon](https://aws.amazon.com/blogs/security/approaches-for-authenticating-external-applications-in-a-machine-to-machine-scenario/)

If your client is not a human user but another service outside AWS, the nearest “easy standard” is **OAuth2 client credentials** for client-to-API auth, while the API still uses an IAM role to reach AWS. [aws.amazon](https://aws.amazon.com/blogs/security/approaches-for-authenticating-external-applications-in-a-machine-to-machine-scenario/)

---

## Security model of the helper scripts (this stack)

The generic pattern above is implemented in this stack by the helper scripts in
`openfga_my/scripts/`. They are **clients** of the platform, not part of the
enforcement path. The canonical, detailed version lives in
[authorization.md §14](authorization.md#14-security-model-of-the-helper-scripts-openfga_myscripts);
this section is the concrete summary.

- **No production passwords are hardcoded.** The only embedded passwords are
  dev defaults in `scripts/common.sh:84-92` (`SuperAdmin123!`, `AwsOwner123!`,
  …), gated behind `ALLOW_DEV_DEFAULTS=1` and used only when no
  `LIBCLOUD_PASSWORD*` env var is set (`common.sh:82-94`); otherwise the script
  hard-fails (`common.sh:96`).
- **Passwords are always passed in before execution**, resolved in order:
  `LIBCLOUD_PASSWORD` env → `LIBCLOUD_PASSWORD_<ROLE>` env → dev default (only
  with `ALLOW_DEV_DEFAULTS=1`) → fail. `create_tenant.sh` generates random
  passwords for new tenants; `set_tenant_credentials.py` requires the cloud
  credential env at runtime with no fallback.
- **Password verification is done by the called API (Dex → LLDAP), not by the
  scripts.** `idp_login.py:219` POSTs the password to Dex's
  `/dex/auth/<id>/login` form; Dex performs the LDAP bind to LLDAP and returns
  a JWT only on success. The scripts never compare passwords themselves. The
  one local crypto check, `verify_superadmin_jwt.py:90-97`, verifies the
  **JWT signature** (RS256 against Dex JWKS), not the password.
- **API servers called by the scripts** (all `localhost` defaults):

  | Service | Default URL | Endpoints used |
  |---|---|---|
  | Dex (OIDC IdP) | `http://localhost:5556` | `/dex/auth`, `/dex/auth/<id>/login`, `/dex/token`, `/dex/keys` |
  | LLDAP (LDAP directory) | `localhost:3890` | LDAP bind + user CRUD via `docker compose run lldap-tools` |
  | OpenFGA | `http://localhost:8080` | `POST /stores/{id}/check`, `/write`, `/read` |
  | Vault | `http://localhost:8200` | `POST/GET /v1/secret/data/libcloud/{tenant}` |
  | libcloud REST API | `http://localhost:8765` | `/v1/auth/me`, `/v1/connections:test`, `/v1/compute/*`, `/v1/jobs/*` |

- **Each server enforces its own auth/authz:**

  | Server | Authn | Authz |
  |---|---|---|
  | Dex | password → LLDAP LDAP bind | issues signed RS256 JWT (`iss`/`aud`/`exp`) |
  | LLDAP | admin-DN LDAP bind for writes | only directory admin can CRUD users |
  | OpenFGA | **OIDC via Dex** — validates caller's Dex JWT (`iss=http://dex:5556/dex`, `aud=libcloud-rest`) against JWKS; unauthenticated → 401 | the model relations (`can_connect`/`can_use`/`can_provision`/`can_read`/`can_manage_credentials`) queried via `/check` |
  | Vault | `X-Vault-Token` on every call | KV policy on the token |
  | libcloud REST API | Bearer JWT decode | JWT scope gate → `allowed_providers` → OpenFGA `can_connect`→`can_use`→`can_provision`/`can_read` per request |

- **OpenFGA now has OIDC authn** (reusing Dex): `--authn-method=oidc
  --authn-oidc-issuer=http://dex:5556/dex --authn-oidc-audience=libcloud-rest`
  in `openfga_my/docker-compose.yml`. Every OpenFGA call carries the caller's
  Dex JWT as `Authorization: Bearer`. The issuer is Dex's canonical in-container
  URL (so OpenFGA can fetch JWKS over `libcloud_net` and the token `iss`
  matches); host-side JWKS uses the published `localhost:5556` port. See
  [authorization.md §15.3](authorization.md#153-openfga-authentication--oidc-via-dex-implemented).
  Remaining hardening: network-isolate `:8080` and enable TLS.
- **The libcloud REST API is the only server that re-runs the full OpenFGA
  authorization on every request.** The scripts' `fga_check` calls
  (`common.sh:229-258`) are a demonstrative pre-check, not the enforcement
  boundary.

---

## Secrets handling (this stack)

User passwords live in **LLDAP** (as hashes); authentication is always
**Dex → LLDAP**. The running servers do not read the plaintext user passwords
from `generated/dex.env` — that file is consumed by the host helper scripts
only, to submit passwords to Dex's login form. Canonical version:
[authorization.md §15](authorization.md#15-secrets-handling).

### What to do with each secret-bearing file

| Action | Files | Why |
|---|---|---|
| **Delete now (and repeatedly)** | `generated/tokens/*` (`.jwt`, `.json`, `.login.err`) | Bearer tokens = full identity; short-lived. Never back up. Scripts re-login on next run. |
| **Move to offline backup, then delete from host** | `vault/generated/vault.env`, `openfga_my/generated/vault.env` (esp. `VAULT_UNSEAL_KEY`) | Unseal key only needed to restart/restore Vault. Root token → replace with a scoped KV token. Keeping them next to Vault defeats its purpose. |
| **Move to encrypted password manager / offline; stop keeping plaintext on host** | `../dex/generated/dex.env`, `openfga_my/generated/dex.env` (user passwords) | Servers don't read these; only the scripts do. If scripts must run, inject a single password via env at runtime. Interim: `chmod 600`, keep gitignored. |
| **Keep on host, but harden** | `libcloud.rest/.env` (`chmod 600`; blank `LIBCLOUD_AWS_PROD_*`/`LIBCLOUD_NTNX_LAB_*` once Vault is used; scope the Vault token); `openfga_my/.env` (leave password blanks so `setup.sh` generates them) | Read by the running API container; cannot delete. |
| **Keep as-is** | `generated/fga.env`, `generated/.openfga_image_stamp`, `libcloud.rest/data/principal_map.json` | Non-secret config. |
| **Harden OpenFGA further** | Network-isolate OpenFGA (`:8080` not published); enable TLS. OIDC authn is now enforced via Dex — `FGA_STORE_ID` is config, not a secret | OpenFGA has no native auth. |
| **Verify gitignore** | `openfga_my/generated/` ✓, `*/.env` ✓ in `openfga_my` & `libcloud.rest`. **`dex/`, `vault/`, `lldap/` have no `.gitignore`** — add `generated/` + `*.env` if those dirs are ever `git init`'d | Prevent accidental commits of secrets. |

### Can `generated/dex.env` be deleted at runtime?

- **For the servers**: yes — they don't read it.
- **For the scripts**: not without a replacement (env vars / password manager),
  because the scripts must submit the password to Dex to obtain a JWT. Deleting
  it breaks `provision_aws.sh`, `set_tenant_credentials.py`,
  `create_tenant.sh`, `superadmin_auth.sh`.
- **Best practice**: don't keep plaintext passwords on the host at all. Move
  them to an encrypted offline store; have operators inject the one password
  they need via an env var at run time. LLDAP remains the single source of
  truth for authentication.

