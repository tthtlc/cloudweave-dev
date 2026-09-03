# AppRole Authentication in the libcloud Vault Deployment — Internals and Security Rationale

This article is a deep dive into **why this deployment authenticates to Vault using
AppRole**, how the mechanism works end-to-end, and — most importantly — **where every
secret originates, where it is stored, and where it travels**. The security of the
secrets is the central concern, so the article is organized around tracing them rather
than around describing features.

Sources: the code in this repo (`openfga_postgres/vault_bootstrap.py`,
`libcloud.rest/app/connections/vault_client.py`,
`libcloud.rest/app/auth/policy.py`,
`libcloud.rest/app/connections/credentials.py`, `vault/ARCHITECTURE.md`) and the
upstream HashiCorp Vault AppRole backend (`vault/builtin/credential/approle/*` in
`hashicorp/vault`, matching the pinned `hashicorp/vault:1.15` image).

---

## 1. TL;DR

- Vault has **two enabled auth methods**: the built-in `token` method and **`approle`**.
  There is no `userpass`, no `ldap`, no `oidc`. Human passwords never reach Vault; they
  live in LLDAP and are verified by Dex.
- The "users" of Vault here are **tenants, not humans**. Each tenant gets one AppRole
  (`libcloud-<tenant>`) bound to one read-only policy (`libcloud-read-<tenant>`), plus a
  distinct `role_id` + `secret_id` pair.
- The `secret_id` is **not shared** across roles: it is minted per AppRole and is only
  valid for the role it was minted against.
- AppRole is a **machine identity** mechanism. Its security value over `userpass`/`ldap`/
  `oidc` is that it (a) does not create a second human-password store, and (b) bounds the
  blast radius of a leaked credential to *one tenant's scope for a bounded time*, instead
  of "one reusable password = the whole database."
- The dominant residual risk in this deployment is **not** the auth-method choice — it is
  that `vault/generated/vault.env` (root token + unseal key) is committed to git
  (`vault/ARCHITECTURE.md` §8.5), which makes the auth-method choice moot if leaked.

---

## 2. What AppRole is

AppRole is HashiCorp Vault's **machine-to-machine** auth method. It replaces a
username/password with a pair of values:

| Component | Role | Secret? | Analogy |
| --- | --- | --- | --- |
| `role_id` | Stable, non-secret identifier of a role | No (an identifier) | username |
| `secret_id` | A secret minted against a *specific* role | Yes | password |

At login the caller presents **both**:

```
POST /v1/auth/approle/login
{ "role_id": "<role A's role_id>", "secret_id": "<a secret_id minted FOR role A>" }
```

Vault resolves the role from `role_id`, then validates the `secret_id` against that
role's secret-id store. A `secret_id` minted for role A **cannot** authenticate as role
B: Vault stores each `secret_id` as an HMAC digest keyed by the backend's own secret, so a
foreign `secret_id` simply never matches.

Two properties matter for this article:

1. **One role → one `role_id`, but many `secret_id`s.** A role can have several
   `secret_id`s (each with its own TTL, `num_uses`, CIDR bind, metadata), but every
   `secret_id` belongs to exactly one role.
2. **`secret_id` is "write-only".** When you mint a `secret_id`, Vault returns the
   plaintext exactly once. It stores only an HMAC digest internally, so a raw storage dump
   does not reveal usable `secret_id`s, and there is no API to read one back. (This
   deployment deliberately deviates from this — see §8.1.)

---

## 3. The AppRole model as deployed here

### 3.1 Bootstrap: enabling the method and creating roles

`vault_bootstrap.py` is the only thing in the repo that enables AppRole:

- `enable_approle()` → `POST /v1/sys/auth/approle` (`vault_bootstrap.py:239-247`).
- A repo-wide grep for `userpass` / `auth/userpass` / `vault auth enable` finds **no**
  userpass enable anywhere. The only other auth-enable call in the repo is also AppRole
  (`test_script/scripts/materialize_vault_users.py:92`).

The seeded tenants come from `SEED_TENANTS` (`vault_bootstrap.py:62-64`, default
`aws,nutanix`). For each tenant, `ensure_tenant_approle()` (`vault_bootstrap.py:250-304`)
does four things:

1. Writes the tenant ACL policy `libcloud-read-<tenant>` — read-only on
   `secret/data/libcloud/<tenant>` + its metadata (`_tenant_read_policy`,
   `vault_bootstrap.py:80-89`).
2. Creates the role `libcloud-<tenant>` bound to that policy, with
   `token_ttl=60m`, `token_max_ttl=120m` (`vault_bootstrap.py:265-274`).
3. Reads back the `role_id` (Vault generates it on role creation; it is not returned by
   the create-role call) (`vault_bootstrap.py:277-284`).
4. Mints a `secret_id` for that role via `POST /auth/approle/role/<role>/secret-id`
   (`vault_bootstrap.py:287-296`), then stores **both** values in KV:
   `secret/data/libcloud-vault-auth/libcloud-<tenant>` (`vault_bootstrap.py:298-303`).

The role is created with **no** `bound_cidr_list`, **no** `secret_id_num_uses`, and **no**
`secret_id_ttl` — only `token_ttl`/`token_max_ttl` (see §8.2).

### 3.2 Two secret families in KV v2

The KV v2 `secret/` mount holds two distinct families:

| Path | Contents | Who can read it |
| --- | --- | --- |
| `secret/data/libcloud-vault-auth/libcloud-<tenant>` | `{ role_id, secret_id }` — the AppRole *login material* | **orchestrator token only** (policy `libcloud-vault-auth-read`) |
| `secret/data/libcloud/<tenant>` | `{ key, secret }` — the actual cloud credentials (Nutanix user/password, AWS key/secret) | **that tenant's AppRole token only** (policy `libcloud-read-<tenant>`) |

The distinction is the foundation of the whole design: the login material and the actual
cloud credentials are held in **separate namespaces with separate readers**.

### 3.3 The three-identity hierarchy

| Identity | What it is | Capability | Scope |
| --- | --- | --- | --- |
| `VAULT_ROOT_TOKEN` | root token from `vault operator init` | everything | admin scripts only |
| `VAULT_TOKEN` (orchestrator) | 768h renewable token, policy `libcloud-vault-auth-read` | read only `secret/data/libcloud-vault-auth/*` | libcloud REST API |
| AppRole `libcloud-<tenant>` | per-tenant machine identity | read only `secret/data/libcloud/<tenant>` via a 60m login token | libcloud REST API, resolved per tenant |

The orchestrator policy is a two-line ACL (`vault_bootstrap.py:70-77`):

```hcl
path "secret/data/libcloud-vault-auth/*"      { capabilities = ["read"] }
path "secret/metadata/libcloud-vault-auth/*"  { capabilities = ["read", "list"] }
```

Notice what it *cannot* do: it cannot read `secret/data/libcloud/*` (the cloud secrets),
cannot write, cannot list engines, cannot reach `<mount>/config/root`. Its only job is to
hand out AppRole login material.

---

## 4. The complete exchange flow

This is the path a request takes when a client asks the REST API to reach, e.g., Nutanix.
Trace it left to right:

```
Client ──(Dex JWT)──▶ libcloud.rest ──▶ OpenFGA ──▶ Vault ──▶ Nutanix
```

### Step 1 — Client authenticates to the API (authN)

A caller authenticates with a Dex-issued OIDC JWT and sends a request with
`provider=nutanix`, `auth_binding=nutanix`. The JWT's `sub` is the LLDAP `uid`, and the
audience is the libcloud REST API.

### Step 2 — Authorization gate (OpenFGA)

`PolicyEngine.authorize_connection()` (`policy.py:134-168`) runs, in order:

1. **Scope check** — the JWT must carry the required scope (`policy.py:140-147`).
2. **Provider check** — the JWT must be allowed to use `nutanix` (`policy.py:149-159`).
3. **Defense-in-depth credential rejection** — `enforce_credential_policy()`
   (`credentials.py:30-43`) rejects any client-supplied credentials; the API always uses
   its own backend identity.
4. **OpenFGA checks** (`_enforce_openfga`, `policy.py:73-96`) — asks OpenFGA `check()`
   whether `user:<sub>` holds `can_connect` on the API object, `can_use` on
   `provider:nutanix`, and `can_read` (or `can_provision` for writes) on the backend
   object `nutanix_cluster:nutanix`.

### Step 3 — Resolve the tenant's Vault identity (OpenFGA → Vault name)

`_resolve_vault_user()` (`policy.py:98-115`) asks OpenFGA
`list_objects("vault_user", "parent", "tenant:nutanix")` and normally gets back
`vault_user:libcloud-nutanix`. The name is stashed on the connection as `vault_user`. If
OpenFGA is disabled or returns nothing, it falls back to the deterministic name
`libcloud-<binding>`.

### Step 4 — Fetch credentials (Vault, three-stage auth)

`resolve_server_credentials()` (`credentials.py:82-127`) → `vault.read_secret("nutanix",
vault_user="libcloud-nutanix")`, which in `vault_client.py` does three things:

**Stage A — fetch the login material** (`_auth_material`, `vault_client.py:105-127`).
`GET /v1/secret/data/libcloud-vault-auth/libcloud-nutanix` using the **orchestrator
token** (`VAULT_TOKEN`). This returns `{ role_id, secret_id }`. The orchestrator token is
path-scoped to `libcloud-vault-auth/*`, so it can fetch the login material but **cannot**
read the cloud secret.

**Stage B — AppRole login** (`_approle_token`, `vault_client.py:129-158`).
`POST /v1/auth/approle/login` with `{ role_id, secret_id }` and **no** token header. This
is the step where the `secret_id` authenticates to Vault *itself*: presenting the correct
role_id+secret_id pair proves identity as that tenant's AppRole, and Vault returns a
short-lived (`60m`) `client_token` bound to policy `libcloud-read-nutanix`.

**Stage C — read the secret** (`read_secret`, `vault_client.py:160-191`).
`GET /v1/secret/data/libcloud/nutanix` with that per-tenant token, returning
`{ key, secret }` — the Nutanix username + password.

### Step 5 — Use the credentials

The resolved key/secret become `ConnectionCredentials`, which the Nutanix driver uses for
its Basic-auth login (then reuses a session cookie).

### Caching

`vault_client.py` caches three things in-process, plaintext, for `_CACHE_TTL_SECONDS =
30.0` (the login material and the secret) and for the token's lease minus a 30s refresh
margin (`vault_client.py:38-44`). The cache holds resolved plaintext **only in memory** —
it is never written to disk or env.

---

## 5. Where every secret originates and travels

This is the core of the article. Every secret in the system, traced from origin to
destination.

### 5.1 `VAULT_UNSEAL_KEY` (unseal key)

- **Origin:** `vault operator init` (`vault_bootstrap.py:181-184`, `secret_shares=1`,
  `threshold=1`).
- **Stored:** `vault/generated/vault.env` (written `0600` by `_write_env`,
  `vault_bootstrap.py:148-164`). **Committed to git** — treat as compromised.
- **Travels:** only host-side, to unseal Vault after reboot (`POST /sys/unseal`). Never
  mounted into a long-running container.
- **Risk:** a leaked unseal key + the `vault-data` volume = full plaintext recovery of
  every secret, regardless of auth method.

### 5.2 `VAULT_ROOT_TOKEN`

- **Origin:** `vault operator init`.
- **Stored:** `vault/generated/vault.env` (committed to git — §8.5 of the architecture
  doc flags it).
- **Travels:** only host-side admin scripts (`add_credential.py`, `delete_credential.py`,
  `vault-*.sh`, `set_tenant_credentials.py`). **Not** mounted into any long-running
  container.
- **Risk:** a holder of the root token reads/writes/deletes everything on every path,
  above every auth method. This is the true "one credential = whole database" vector, and
  it is **method-independent** (see §6).

### 5.3 `VAULT_TOKEN` (orchestrator token)

- **Origin:** `ensure_orchestrator_token()` mints it via `POST /auth/token/create` with
  policy `libcloud-vault-auth-read`, `ttl=768h`, `renewable=true`
  (`vault_bootstrap.py:218-236`).
- **Stored:** `vault/generated/vault.env` as `VAULT_TOKEN`, then synced by `setup.sh`
  into `libcloud.rest/.env`.
- **Travels:** to the libcloud REST API container, which uses it **only** to read
  `secret/data/libcloud-vault-auth/*` (the login material).
- **Risk:** deliberately narrow. A leaked orchestrator token can read every tenant's
  `role_id` + `secret_id` (which lets it then *become* any tenant via AppRole login) —
  but it cannot directly read the cloud secrets. That is the point of splitting the
  login material from the secrets.

### 5.4 `role_id`

- **Origin:** generated by Vault on role creation, read back at
  `vault_bootstrap.py:277-284`.
- **Stored:** KV `secret/data/libcloud-vault-auth/libcloud-<tenant>` (readable by
  orchestrator token).
- **Secret?** **No** — it is a non-secret identifier. Knowing a `role_id` alone is
  useless without a matching `secret_id` (because `bind_secret_id` defaults to `true`).
- **Travels:** orchestrator token → REST API process memory → the AppRole login request.

### 5.5 `secret_id` (the credential under discussion)

- **Origin:** minted by Vault via `POST /auth/approle/role/<role>/secret-id`
  (`vault_bootstrap.py:287-296`). Vault returns the plaintext **once**; internally it
  stores only an HMAC digest.
- **Stored in this deployment:** the plaintext is deliberately re-persisted into KV at
  `secret/data/libcloud-vault-auth/libcloud-<tenant>` (`vault_bootstrap.py:298-303`),
  encrypted at rest, readable only by the orchestrator token. (See §8.1 for why this is a
  deviation from the pure model.)
- **Travels:** Vault mint → (root-token write) → KV `libcloud-vault-auth/*` →
  (orchestrator read) → REST API process memory → (AppRole login body) → Vault's login
  handler → (HMAC check against the stored digest) → **a 60m tenant token**.
- **Risk:** a leaked `secret_id` is usable only (a) for its one role, and (b) for as long
  as its TTL / `num_uses` allow. In this deployment the `secret_id` has no explicit
  `secret_id_ttl`/`num_uses`, so its effective lifetime is bounded by the 60m token TTL —
  a leaked `secret_id` yields a token that lives at most 60 minutes.

### 5.6 Cloud credentials (the real secrets) — Nutanix user/password, AWS key/secret

- **Origin:** supplied **by the tenant owner at runtime** (never from `.env`), via
  `set_tenant_credentials.py`.
- **Stored:** KV `secret/data/libcloud/<tenant>` — KV v2, encrypted at rest on the
  `vault-data` volume.
- **Travels:** (owner runtime input) → Dex login → OpenFGA `Check
  can_manage_credentials` → (root-token write) → KV `libcloud/<tenant>` → (per-tenant
  AppRole token) → REST API process memory (30s cache) → the cloud provider (Nutanix
  Basic-auth).
- **Risk:** this is the secret that actually matters. It is protected by **two layers of
  least privilege**: (1) the orchestrator token cannot read it, and (2) only the tenant's
  own 60m AppRole token can. The raw credential never appears in the REST API's env.

### 5.7 Human passwords (LLDAP)

- **Origin:** created in LLDAP.
- **Stored:** LLDAP only. **Not in Vault at all** — Vault has no LDAP auth method, no
  LLDAP bind, no group→policy mapping (`vault/ARCHITECTURE.md` §6.1).
- **Travels:** LLDAP verifies the password at Dex login; Dex issues a JWT; the JWT is
  validated by OpenFGA and the REST API. Vault never sees it.
- **Risk:** none to Vault. Human passwords stay in one directory; they are not duplicated
  into a second store.

### 5.8 Summary table

| Secret | Origin | Stored | Who reads it | TTL / bound |
| --- | --- | --- | --- | --- |
| unseal key | `operator init` | `vault.env` (committed!) | host unseal only | none (until rotation) |
| root token | `operator init` | `vault.env` (committed!) | host admin scripts | none |
| orchestrator token | `token/create` | `vault.env` + REST `.env` | REST API (auth material only) | 768h, renewable |
| `role_id` | role create | KV `libcloud-vault-auth/*` | orchestrator → REST API | non-secret |
| `secret_id` | `role/<r>/secret-id` | KV `libcloud-vault-auth/*` (plaintext) | orchestrator → REST API → login | effective ≤ token TTL |
| cloud creds | tenant owner | KV `libcloud/<tenant>` | tenant AppRole token | 60m token |
| human password | LLDAP | LLDAP | LLDAP at login (via Dex) | LLDAP policy |

---

## 6. Security rationale vs. other auth methods

Why AppRole and not `userpass`/`ldap`/`oidc`? Compare the four methods on the two axes
that matter here: **password proliferation** and **single-secret blast radius**.

| Method | Where the secret lives | Proliferation | Secret type | Revocation / TTL | Credential-reuse risk |
| --- | --- | --- | --- | --- | --- |
| `userpass` | inside Vault (bcrypt-hashed) | **N users = N static passwords** | human password | rewrite; token TTL via policy | high (reuse on other systems) |
| `ldap` | outside Vault, in the directory | none new (reuses directory pw) | human password | directory-side (lockout, expiry) | **highest** (one pw opens dir *and* Vault) |
| `oidc` | outside Vault, at the IdP | none new (reuses IdP pw/MFA) | human password + MFA | IdP-side (session, MFA) | high (IdP account = single point of trust) |
| `approle` | inside Vault — `secret_id` | cheap disposable `secret_id`s | **machine credential** | `token_ttl`, `num_uses` (one-shot), CIDR bind, response-wrap | low (no human reuse, short-lived) |

### 6.1 `userpass` makes Vault a second credential store

`vault write auth/userpass/users/bob password=test policies=user` creates one more
static, reusable, non-expiring password *inside* Vault. Scale to N users and Vault now
holds N more passwords to protect — and a single one bound to a broad policy is the
literal "one password = the whole database" scenario. The password itself has no TTL; it
is only bounded by the token TTL attached to the policy, and the password persists.

### 6.2 `ldap`/`oidc` move the single point of trust, they don't remove it

Both federate: Vault stores no user password, it delegates to a directory/IdP and just
mints a Vault token on success. That avoids proliferation but makes the directory/IdP the
single point of trust — one high-privilege account there (the `bindpass` service account
for LDAP, the IdP superuser for OIDC) is "one credential leaks Vault at that scope."

### 6.3 `approle` bounds the blast radius to one tenant, for a bounded time

A leaked `secret_id`:
- is valid only for **its role** (per-tenant, not global), and
- yields a token that lives **at most 60m** (`token_ttl=60m`), and
- in the full mechanism can additionally be constrained by `num_uses` (one-shot), CIDR
  binding, and response-wrapping (none of which this deployment sets — §8.2).

This is the smallest single-secret blast radius of the four, which is exactly the
property a multi-tenant system needs: a compromise of tenant A's credential must not leak
tenant B's secrets.

### 6.4 The root-token caveat (applies to every method equally)

No auth method protects against a **root token** leak. The root token is minted at
`operator init`, sits *above* all auth methods and policies, and ignores them entirely —
`userpass`/`ldap`/`oidc`/`approle` alike. Likewise the unseal key. So the correct answer
to "which auth method is vulnerable to the root token leaking everything?" is: **none of
them protect you from it — it is the universal backdoor above all four.** In this
deployment that backdoor is currently sitting in a git-committed `vault/generated/vault.env`
(`vault/ARCHITECTURE.md` §8.5), which is the dominant risk regardless of auth-method
choice.

### 6.5 Net

- `userpass` = simplest, but adds a password store and maximizes single-password blast
  radius.
- `ldap`/`oidc` = no Vault-side passwords, single source of truth, but the directory/IdP
  becomes the single point of trust.
- `approle` = machine identities with bounded TTL/use — the smallest single-secret blast
  radius — which is why the repo uses it for per-tenant REST-API access.

This deployment chooses **"one directory (LLDAP), machine identities via AppRole"** to
avoid duplicating human passwords into Vault while still giving each tenant a bounded,
revocable, tenant-scoped credential.

---

## 7. What AppRole specifically buys you

### 7.1 Split of "identifier" from "secret"

`role_id` (non-secret) and `secret_id` (secret) are separate. This means the `role_id` can
be logged, committed, or embedded in config without leaking an authenticating secret, and
rotation is cheap: you revoke/reissue a `secret_id` without touching the `role_id` or the
role's policy.

### 7.2 `secret_id` is stored as an HMAC digest (upstream)

In the Vault AppRole backend, the `secret_id` is HMAC'd before storage using a
per-backend key. Vault can verify a presented `secret_id` but cannot read one back, and a
raw storage dump does not reveal usable `secret_id`s. This is a "write-only credential"
property — the plaintext exists only where the client put it.

### 7.3 Bounded, per-role policies

Each AppRole is bound to a policy that is read-only on a *single tenant's* secret path
(`_tenant_read_policy`). There is no shared or wildcard `secret/libcloud/*` read policy, so
tenant isolation is enforced by Vault's ACL at read time, not just by OpenFGA at request
time.

### 7.4 Short-lived tokens

The role sets `token_ttl=60m`, `token_max_ttl=120m`, so even a successfully obtained
tenant token expires quickly. The client also refreshes with a 30s margin
(`vault_client.py:129-158`), so a stalled cache cannot present a stale token for long.

### 7.5 Two-layer least privilege

The result is a clean separation:

1. **Orchestrator token** → reads only `libcloud-vault-auth/*` (login material), never the
   cloud secrets.
2. **Per-tenant AppRole token** → reads only its own `secret/data/libcloud/<tenant>`, and
   expires after 60m.

A compromise at layer 1 does not directly expose the cloud secrets; a compromise at layer
2 exposes only one tenant, briefly.

---

## 8. Deviations from the ideal and residual risks

The design is sound but not the full-strength AppRole posture. Flagged honestly:

### 8.1 `secret_id` plaintext is re-persisted into KV

The pure AppRole model stores only an HMAC digest of the `secret_id`; the plaintext exists
only on the client. Here, `vault_bootstrap.py:298-303` writes the plaintext `secret_id`
back into `secret/data/libcloud-vault-auth/*` so the orchestrator token can hand it to the
REST API. Consequences:

- The "write-only" property is lost: the plaintext now rests in KV (encrypted at rest),
  readable by the orchestrator token.
- This is acceptable **only because** the read policy on that path is narrowly scoped to
  `libcloud-vault-auth/*` and read-only. It is still a stored plaintext secret, so the
  orchestrator token is effectively a high-value target: whoever holds it can mint a token
  for **any** tenant.
- A stronger alternative (not used here) is response-wrapping or injecting the
  `secret_id` directly into the REST API's env at bootstrap instead of round-tripping it
  through KV.

### 8.2 No `num_uses`, `secret_id_ttl`, or CIDR binding

The role is created with only `token_ttl`/`token_max_ttl`
(`vault_bootstrap.py:265-274`). The `secret_id` mint body is `{}`
(`vault_bootstrap.py:287-292`). Therefore the `secret_id` has no one-shot `num_uses`, no
independent `secret_id_ttl`, and no `bound_cidr_list`. Its practical lifetime is inherited
from the 60m token TTL. For a hardened deployment, set `secret_id_num_uses=1` and
`bound_cidr_list` to the API's subnet.

### 8.3 `vault/generated/vault.env` is committed to git

It contains `VAULT_ROOT_TOKEN` and `VAULT_UNSEAL_KEY`, and is **not** gitignored
(`vault/ARCHITECTURE.md` §8.5). This is the dominant risk and makes the auth-method choice
moot if leaked. Mitigation: rotate the root token and unseal key, `git rm --cached
vault/generated/vault.env`, and purge it from history.

### 8.4 Single unseal key, threshold 1

`secret_shares=1`, `threshold=1` (`vault_bootstrap.py:181-182`). One key unseals the whole
store — convenient for a demo, but a single point of failure/compromise. Production should
use Shamir shares (e.g. 5/3) or auto-unseal via an external KMS.

### 8.5 TLS disabled, loopback-only listener

`tls_disable = 1` in `config.hcl`, and the host port is bound to `127.0.0.1`. Fine for the
isolated `libcloud_net` bridge, but any multi-host exposure must add TLS.

### 8.6 Root token used for writes

Cloud-credential writes go through `set_tenant_credentials.py` using the **root token**
(gated upstream by Dex + OpenFGA `can_manage_credentials`). The write decision is OpenFGA's,
but the write capability is the root token's — a compromise of the root token bypasses the
gate. This is acceptable only because the root token is not in any long-running container.

---

## 9. Conclusion

AppRole is the correct auth method for this deployment because the thing authenticating to
Vault is a **machine** (the libcloud REST API) acting on behalf of a **tenant**, not a
human. It gives the system what it needs:

- **No second human-password store** (LLDAP remains the single source of truth for humans).
- **Per-tenant isolation** enforced at Vault's ACL layer (`libcloud-read-<tenant>`), not
  just at OpenFGA.
- **Bounded blast radius**: a leaked `secret_id` or tenant token exposes one tenant, for at
  most 60 minutes, instead of "one reusable password = the whole database."
- **A two-layer least-privilege path**: the orchestrator token can fetch login material but
  not secrets; the per-tenant token can read its secret but not others'.

The remaining risks are not about the auth-method choice. They are the committed
`vault/generated/vault.env` (root token + unseal key), the re-persisted `secret_id`
plaintext, and the absent `num_uses`/CIDR/response-wrap hardening. Fix those, and the
AppRole design here is a defensible, least-privilege secret-broker architecture.
