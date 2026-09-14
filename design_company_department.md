# Design & Implementation Plan — Company → Department → Cloud

**Status:** Implemented (Phases 0–4 done; Phase 5 deployment/e2e pending). As-built corrections below.
**Source:** `next_target.md`.

---

## As-built corrections (deviations from the draft below)

These override the corresponding draft sections; the draft text was not fully
rewritten, so where they disagree the notes here win.

- **D2 provisioner**: NOT a Dex `client_credentials` machine grant. The spike
  showed Dex v2.41.1 emits `aud = client_id` and an opaque `sub` (base64 client
  identity), so a literal machine grant would have required relaxing downstream
  audience checks and seeding an encoded OpenFGA principal. Instead the existing
  `aws-admin` / `ntnx-admin` LLDAP service accounts are granted the platform
  `provisioner` role (`user:aws-admin`/`user:ntnx-admin provisioner platform:main`).
  No Dex change, no restart, readable principals.
- **`provisioner` is cloud-scoped inside the `can_use` intersection**, not a
  separate OR-arm. `can_provision`/`can_update` on the backend became
  `((tenant_admin or tenant_owner or provisioner from platform) and can_use from provider) or …`
  — so `aws-admin` provisions only AWS backends and `ntnx-admin` only Nutanix
  (the naive OR-arm broke the existing cross-cloud isolation checks, which the
  bootstrap validation caught). `libcloud_api.can_connect` and `provider.can_use`
  gained **no** provisioner arm (the service accounts already pass via their
  tenant membership).
- **No Dex config change** (§4 below is superseded). `libcloud.rest/app/auth/identity.py`
  needs no `libcloud-machine` entry (§8 point 1 is superseded).
- `idp_login.py._provisioner` and `libcloud_proxy.py._script_user` now always
  return the per-cloud service account, independent of the department binding.

---

## 0. Decisions (approved)

| # | Decision | Choice |
|---|---|---|
| D1 | Department credential supply & visibility | **Company admin supplies it; viewable + rotatable** from the UI. (AppRole `role_id`/`secret_id` stay invisible.) |
| D2 | Provisioner identity for the identity-service → libcloud.rest hop | **Existing `aws-admin`/`ntnx-admin` service accounts** granted the platform `provisioner` role (Dex machine grant dropped after the spike). |
| D3 | Existing seeded tenants (`aws`, `nutanix`, `aws1`, `aws2`) | **Grandfather** — no company parent; fully additive. |
| D4 | Department role granularity | **Full `owner` / `admin` / `viewer` triad** per department (mirrors today's tenant). |

---

## 1. Target hierarchy

```
platform:main                              (superadmin)
  └─ company:acme                          admin: user:alice          (company admin)
        └─ tenant:acme-eng  (= "department")  owner: user:user07       (dept administrator)
             │                                  admin: user:user08       (dept admin)
             │                                  viewer: user:user09      (dept viewer)
             ├─ provider:aws                 (shared provider object, one per cloud)
             ├─ aws_region:acme-eng          (per-dept backend object)
             ├─ vault_user:libcloud-acme-eng
             ├─ Vault secret/data/libcloud/acme-eng           {key,secret}   ← credential
             └─ Vault secret/data/libcloud-vault-auth/libcloud-acme-eng  {role_id,secret_id}
```

- **`company`** is a grouping with one `admin`. No cloud/credential of its own.
- **`tenant` (= department)** is the credential/provisioning boundary — the exact
  unit the existing system already models. We reuse it wholesale.
- **Machine identity** (`user:libcloud-machine`, a Dex client_credentials client)
  is a *platform*-level orchestrator identity used by the identity-service to call
  `libcloud.rest` and OpenFGA. It is **not** per-department; department scoping of
  the actual cloud credential is done by `auth_binding` + the per-department
  Vault AppRole (§4).

---

## 2. OpenFGA model changes (`openfga_postgres/model/libcloud.fga`)

Additive; new model version; existing 48 tuples untouched. Full diff:

```text
type platform
  relations
    define superadmin: [user]
    define provisioner: [user]                          # NEW: machine orchestrators
    define global_reader: superadmin
    define can_manage_global_policy: superadmin
    define can_manage_iam_mapping: superadmin
    define can_manage_platform: superadmin
    define can_manage_tenant_lifecycle: superadmin
    define can_manage_company_lifecycle: superadmin     # NEW

type company                                            # NEW
  relations
    define admin: [user]
    define platform: [platform]
    define member: [user] or admin
    define can_manage_company: admin or can_manage_platform from platform
    define can_create_department: admin or can_manage_platform from platform
    define can_assign_department_admin: admin or can_manage_platform from platform
    define can_view: admin or global_reader from platform

type tenant                                             # (department)
  relations
    define owner: [user]
    define admin: [user]
    define viewer: [user]
    define parent: [company]                            # NEW (optional; grandfathers omit it)
    define platform: [platform]
    define member: [user] or owner or admin or viewer
    define can_read: viewer or admin or owner or can_view from parent or global_reader from platform
    define can_provision: admin or owner
    define can_update: admin or owner
    define can_manage_credentials: owner or can_manage_company from parent   # view+rotate (D1)
    define can_assign_admin: owner or can_assign_department_admin from parent
    define can_assign_viewer: owner or can_assign_department_admin from parent
    define can_assign_owner: can_manage_platform from platform

type libcloud_api
  relations
    define can_connect: [user] or member from parent or provisioner from platform or global_reader from platform
    define parent: [tenant]
    define platform: [platform]

type provider
  relations
    define can_use: [user] or member from parent or provisioner from platform or global_reader from platform
    define parent: [tenant]
    define platform: [platform]

type aws_region / nutanix_cluster                       # + provisioner arm
    define can_provision: ((tenant_admin or tenant_owner) and can_use from provider)
                          or can_provision from resource_class
                          or provisioner from platform
    define can_read: tenant_viewer or tenant_admin or tenant_owner or can_use from provider
                     or can_read from resource_class or provisioner from platform or global_reader from platform
    define can_update: ((tenant_admin or tenant_owner) and can_use from provider)
                       or can_update from resource_class or provisioner from platform

# resource_class, vault_user: unchanged
```

### New seed tuples
```text
user:libcloud-machine  provisioner  platform:main        # machine orchestrator
```
Everything else (companies, departments, per-dept wiring) is written at runtime
by the API (§7).

### Why `provisioner` threads through the backend objects
Enforcement point 2 (`libcloud.rest`) evaluates the **token subject** against the
department backend object. A single shared machine identity must therefore pass
`can_connect`/`can_use`/`can_provision`/`can_read` on *any* department's backend.
The `provisioner from platform` arm gives it that, while **per-department
authorization remains at enforcement point 1** (identity-service checks the END
USER's `can_provision` on the specific department) and at the Vault AppRole layer
(per-department credential scope). Documented trade-off: a compromised
identity-service could provision any department — but it already could, as the
orchestrator holding all provisioner credentials.

### Dynamic tenant→cloud derivation (required)
`identity_service/app/fga.py:40-82` hard-codes `TENANT_BY_SLUG`/`KNOWN_TENANTS`/
`TENANT_CLOUD`/`DEFAULT_BINDING`. New departments aren't in those maps. Replace
with derivation from `tenant:<dept> parent provider:<aws|nutanix>`:

- `cloud_for_tenant(tid)` — read the provider object of that tuple.
- `tenant_binding(principal, cloud)` — among the principal's `tenant:*` role
  tuples, pick the one whose parent provider == `cloud`.
- `cloud_capabilities(principal)` — group the principal's tenant tuples by their
  derived cloud (drop the `TENANT_CLOUD` map).

This also removes the `aws1`/`aws2` and `ntnx`↔`nutanix` special-casing at the
authz layer.

---

## 3. Vault changes

1. **New `department-orchestrator` token + policy** held by the identity-service
   (NOT root). It can mint per-department AppRoles and read/write per-department
   credentials, but cannot read any AppRole `secret_id` (keeps "invisible"), and
   cannot touch non-libcloud paths:
   ```hcl
   path "secret/data/libcloud/*"               { capabilities = ["create","update","read"] }
   path "secret/metadata/libcloud/*"           { capabilities = ["list"] }
   path "secret/data/libcloud-vault-auth/*"    { capabilities = ["create","update"] }
   path "sys/policies/acl/libcloud-read-*"     { capabilities = ["create","update"] }
   path "auth/approle/role/libcloud-*"         { capabilities = ["create","update"] }
   path "auth/approle/role/libcloud-*/role-id" { capabilities = ["read"] }
   path "auth/approle/role/libcloud-*/secret-id" { capabilities = ["update"] }
   ```
   `read` on `secret/data/libcloud/*` enables D1 (view credential). The
   identity-service gates that read behind OpenFGA `can_manage_credentials`
   before returning anything.

2. **Department AppRole** — exactly `vault_tenant_role.py`'s output, driven by a
   new `VaultService`: policy `libcloud-read-<dept>`, role `libcloud-<dept>`
   (60m TTL), secret_id minted, auth material at
   `secret/data/libcloud-vault-auth/libcloud-<dept>`.

3. **Credential** — `secret/data/libcloud/<dept>` = `{key,secret}` (AWS key/secret
   or Nutanix user/password).

4. Optional hardening (from `SUMMARY.md §10`) on new AppRoles:
   `secret_id_num_uses`, `bound_cidr_list`, response-wrapping.

---

## 4. ~~Dex changes (machine grant, D2)~~ — SUPERSEDED (see As-built corrections)

1. Add a static client in `dex/config.yaml`:
   ```yaml
   staticClients:
   - id: libcloud-machine
     name: Department provisioning machine identity
     secret: <generated>        # into dex/generated/dex.env (gitignored)
   ```
   Client-credentials grant: `POST /dex/token` with
   `grant_type=client_credentials&client_id=libcloud-machine&client_secret=...&scope=...`.

2. **Audience risk (must spike first)**: `libcloud.rest` and OpenFGA validate
   `aud == libcloud-rest` (`--authn-oidc-audience=libcloud-rest`). Dex's
   client_credentials token `sub`/`aud` default to the client id. **Phase 2 opens
   with a spike** to confirm whether Dex emits `aud=libcloud-rest` for this client
   (e.g. via an `aud`/audience knob) and, if not, we either (a) register the
   client under an audience we control and add `libcloud-machine` to the accepted
   audiences of `libcloud.rest` + OpenFGA, or (b) keep the token's `sub` as the
   machine principal and set `aud` explicitly. **Fallback if the spike fails**: a
   single per-cloud machine client (`libcloud-aws`, `libcloud-nutanix`) so `sub`
   carries the cloud and `aud` can be pinned — still no per-human LDAP logins.

3. `libcloud.rest/app/auth/identity.py`: add
   `libcloud-machine` → `PROVISIONER_SCOPES` + `["*"]` in `PRINCIPAL_SCOPES`/
   `PRINCIPAL_PROVIDERS`.

---

## 5. LLDAP changes

1. **Bulk-create 30 users** — `scripts/create_users.sh` (idempotent loop over
   `lldap_ensure_user.sh`): `user01..user30` (`userNN@libcloud.local`), generated
   passwords persisted to `test_script/generated/users.env` (0600, gitignored).
   No OpenFGA tuples — inert until assigned a company/department role.

2. **`LldapService.create_user()`** — new method (`identity_service/app/lldap.py`)
   for future programmatic user creation (not strictly needed for the 30, but
   required for any hidden account work and for completeness).

3. Optional: LLDAP group per company/department for audit (`lldap-group-create.sh`
   exists).

---

## 6. Identity-service changes

### 6.1 New routes
| Route | Actor | Action |
|---|---|---|
| `GET /api/companies` | superadmin | list companies (+ admins) |
| `POST /api/companies` | superadmin | create `{name, adminUserId}` |
| `GET /api/companies/{id}` | superadmin \| that company's admin | detail + departments |
| `POST /api/companies/{id}/departments` | company admin | create `{name, cloud, ownerUserId, credential}` |
| `GET /api/companies/{id}/departments` | company admin | list departments (no credential/approle) |
| `GET /api/departments/{id}/credential` | company admin \| dept owner | view credential (D1, masked/reveal) |
| `PUT /api/departments/{id}/credential` | company admin \| dept owner | rotate credential |
| `PATCH /api/departments/{id}/members` | dept owner | assign admin/viewer within dept |

All gated on OpenFGA (`can_manage_company_lifecycle`, `can_create_department`,
`can_manage_credentials`, `can_assign_*`).

### 6.2 New `VaultService` (`identity_service/app/vault.py`)
`create_department_identity(dept)`, `write_department_credential(dept, cloud, k, s)`,
`read_department_credential(dept)` — all via the `department-orchestrator` token.

### 6.3 `FgaService` additions
`create_company(name, admin)`, `create_department(...)` (§7 tuple set),
`company_for(principal)`, `departments_for(principal)`, `cloud_for_tenant(tid)`.

### 6.4 Replace provisioner auth with machine grant
- New `MachineAuth` in `idp_login.py`: client_credentials → cached
  `aud=libcloud-rest` token (sub `libcloud-machine`). `ProvisionerAuth` LDAP
  login is retired for the primary path.
- `libcloud_proxy.py` uses `MachineAuth`; `auth_binding` still selects the
  department. The slug-derived `_script_user`/`_provisioner` and env password
  lookup go away.
- **Shelled-out scripts** (`deprovision_*.sh`, `provision_*_private.sh`) still do
  their own LDAP login + FGA check. Migrate them to consume the machine token
  from the existing token-cache file the identity-service already writes
  (`libcloud_proxy.py:_token_cache`), and to pass the dept binding. This is a
  contained follow-up; keep the scripts working on a transition branch if needed.

### 6.5 Session / role model
`role` grows to `company_admin`; department roles stay `owner/admin/viewer`.
Session adds `company`, `departments[]` context so the portal can route.

---

## 7. Department-creation sequence (core operation)

Company admin `POST /api/companies/{id}/departments`:

1. **AuthZ** — OpenFGA `can_create_department` on `company:<id>`.
2. **Validate** — `cloud ∈ {aws,nutanix}`; `ownerUserId` exists in LLDAP; name
   unique within company.
3. **Vault** — (a) `write_department_credential(dept, …)`; (b)
   `create_department_identity(dept)` → AppRole + secret_id + auth material.
   Fire-and-forget; nothing returned.
4. **OpenFGA** — wiring tuples:
   ```
   user:<company-admin>  admin      company:<id>          (at company creation)
   tenant:<dept>         parent     company:<id>
   tenant:<dept>         parent     libcloud_api:main
   tenant:<dept>         parent     provider:<cloud>
   provider:<cloud>      provider   <backend>:<dept>
   tenant:<dept>         tenant     <backend>:<dept>
   tenant:<dept>         parent     vault_user:libcloud-<dept>
   platform:main         platform   <backend>:<dept>      (so provisioner arm resolves)
   user:<ownerUserId>    owner      tenant:<dept>
   ```
5. **Return** — `{id, name, cloud, ownerUserId}` only. No credential value, no
   `role_id`, no `secret_id` (AppRole stays invisible; credential is viewable via
   the dedicated gated endpoint, not in the create response).

**Provisioning** (dept owner/admin) then flows: identity-service
`can_provision(user07, aws)` → `tenant_binding(user07, aws) = acme-eng`
(dynamic) → machine token → `libcloud.rest` with `auth_binding=acme-eng` →
AppRole `libcloud-acme-eng` → credential → backend.

---

## 8. libcloud.rest changes
1. `identity.py`: `libcloud-machine` → scopes/providers (machine grant).
2. Verify `_role_suffix`/`principal_providers` no longer needed for the primary
   path (machine token carries `["*"]`), but keep for backward-compat with the
   seeded `aws-admin`/`ntnx-admin` service accounts used by operator scripts.
3. No change to the `auth_binding → vault_user → AppRole → credential` path —
   already generic (`policy.py:98-115`, `credentials.py:82-127`).

---

## 9. Portal changes (`server/src`)
- **`CompanyAdminDashboard`** (route `/company`) — create department (name, cloud
  select, owner-user select from `GET /api/users`, credential input), department
  list, per-dept credential view/rotate (masked reveal).
- **Superadmin companies section** — create company (name + admin-user select).
- **`AdminDashboard`/`OwnerDashboard`** reused for department admins/owners,
  scoped by new session `departments[]`.
- `App.js` + `RequireRole` extended for `company_admin`.
- `services/api.js` — new client methods for §6.1.

---

## 10. Phased implementation plan

**Phase 0 — model + bootstrap**
1. `openfga_postgres/model/libcloud.fga` — §2 model.
2. `openfga_bootstrap.py` — post v2 model; add `user:libcloud-machine provisioner
   platform:main`; extend `VALIDATION_CHECKS` (machine provisioner + company).
3. `identity_service/app/fga.py` — dynamic `cloud_for_tenant`/`tenant_binding`/
   `cloud_capabilities`; keep slug fallback for grandfathers.

**Phase 1 — 30 users**
4. `scripts/create_users.sh`; `lldap.py:create_user()`.

**Phase 2 — Vault + Dex machine grant (spike first)**
5. **Spike**: Dex client_credentials `aud` behavior (risk §4.2).
6. Dex static client `libcloud-machine` + generated secret.
7. `department-orchestrator` Vault policy + token minting.
8. `identity_service/app/vault.py` → `VaultService`.
9. `MachineAuth` in `idp_login.py`; wire `libcloud_proxy.py`.

**Phase 3 — identity-service API**
10. Routes + `models.py` (§6.1).
11. `fga.py` `create_company`/`create_department`; `users.py` role derivation.

**Phase 4 — portal**
12. Company + department dashboards, routing, api client.

**Phase 5 — verification**
13. `test_script/` e2e: create company → 2 departments (aws + nutanix) → provision
    as dept admin → assert cross-company / cross-department denial + credential
    view/rotate + AppRole invisibility.
14. Update `ARCHITECTURE.md` + subsystem docs; run `system_validate.sh`.

---

## 11. Security notes (carried into implementation)
1. Identity-service now holds a Vault `department-orchestrator` token (read/write
   `secret/data/libcloud/*` + AppRole minting) — never root; document in
   `identity_service/ARCHITECTURE.md`.
2. Credential is **viewable** (D1): the value crosses the browser. Use masked
   fields + explicit reveal + audit log on view.
3. Company-admin isolation — assert a company admin cannot create/read another
   company's departments (OpenFGA check in tests).
4. `_require_role` self-asserted-cookie bug (`main.py:87-97`, `ARCHITECTURE.md`
   finding 3) is especially dangerous for a new `company_admin` role. Recommend
   fixing it (OpenFGA-authoritative role) as part of this work.
5. Machine client secret lives in `dex/generated/dex.env` (gitignored) and is a
   long-lived static credential — rotate with the machine identity.

---

## 12. Confirmations (all resolved)
- 30-user naming `user01..user30` — confirmed.
- Credential view = masked + explicit reveal — confirmed.
- Dept `owner` = "department administrator" assigned at creation — confirmed.
- Acceptance against the existing Nutanix emulator / AWS — confirmed.
