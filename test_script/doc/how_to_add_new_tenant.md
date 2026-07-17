# How to Add a New Tenant

This guide covers the two distinct "add a tenant" operations in the system and
lists **every file that must change** in each case.

> **Read this distinction first — the two cases are very different.**

| Case | What you are adding | Example | Code changes required? |
|------|---------------------|---------|------------------------|
| **A** | A new **tenant** under an *existing* cloud provider (a new AWS account or a new Nutanix cluster). | `tenant:aws-dev`, `tenant:ntnx-prod` | **No source-code edits.** Fully automated at runtime by `scripts/create_tenant.sh`. |
| **B** | A new **cloud provider** (a whole new cloud). The user's "as good as adding a new tenant" case. | provider `gcp` with default `tenant:gcp` | **Yes — edits in both projects** (`openfga_my` + `../libcloud.rest`). |

The enforcement layer in `../libcloud.rest` was generalized precisely so that
**Case A needs zero code changes** and **Case B needs only registry/data
additions (no per-provider `if/else` branches in the authorization path)**.
The generalizations that make this true:

- `../libcloud.rest/app/connections/models.py` defines `PROVIDER_OBJECT_TYPES`
  (provider id → OpenFGA object type). `policy.py::_backend_object` looks the
  type up from this registry, so no per-provider branch is needed there.
- `ProviderConnection.provider` is validated against `PROVIDER_OBJECT_TYPES`
  (no `Literal` enum to edit).
- `../libcloud.rest/app/auth/identity.py` derives JWT scopes/providers from the
  principal's **role suffix** (`-owner` / `-admin` / `-viewer`), so any new
  tenant's users are recognized without editing `PRINCIPAL_SCOPES`.
- `scripts/create_tenant.sh` mints the LLDAP users, OpenFGA tuples, and Vault
  binding for a new tenant at runtime (superadmin-gated).
- `scripts/set_tenant_credentials.py` accepts any tenant id and selects the
  credential fields from `CLOUD=aws|nutanix`.

---

## Case A — New tenant on an EXISTING cloud (e.g. `aws-dev`)

You already have provider `aws` (with default `tenant:aws`) and you want a
second, isolated AWS account with its own owner/admin/viewer and its own access
key / secret. **No source files change.** Everything is runtime state created
by the superadmin-gated helper scripts.

### Prerequisites

- `./setup.sh` has completed (LLDAP, Dex, OpenFGA, Vault are up and the default
  tenants `aws` / `nutanix` exist).
- You can authenticate as `superadmin` (password in `generated/dex.env` or
  `$LIBCLOUD_SUPERADMIN_PASSWORD`).

### Step 1 — Create the tenant (superadmin-gated)

```bash
TENANT=aws-dev CLOUD=aws ./scripts/create_tenant.sh
```

`create_tenant.sh` performs all of the following atomically:

1. **Verifies the superadmin JWT** (`SUPERADMIN_JWT`, via
   `scripts/verify_superadmin_jwt.py`). Without it, tenant creation is refused.
2. **Creates 3 LLDAP users** via `../lldap/scripts/lldap_ensure_user.sh`:
   - `aws-dev-owner`  (email `aws-dev-owner@libcloud.local`)
   - `aws-dev-admin`
   - `aws-dev-viewer`
   Passwords come from `LIBCLOUD_PASSWORD_AWS_DEV_OWNER/_ADMIN/_VIEWER` if set,
   otherwise are randomly generated.
3. **Appends the new users + passwords** to `generated/dex.env` so host scripts
   can log in as them.
4. **Writes the OpenFGA tuples** for `tenant:aws-dev`:
   - `user:superadmin` `owner` `tenant:aws-dev`  (break-glass)
   - `user:aws-dev-owner` `owner` `tenant:aws-dev`
   - `user:aws-dev-admin` `admin` `tenant:aws-dev`
   - `user:aws-dev-viewer` `viewer` `tenant:aws-dev`
   - `tenant:aws-dev` `parent` `libcloud_api:main`
   - `tenant:aws-dev` `parent` `provider:aws`
   - `provider:aws` `provider` `aws_region:aws-dev`
   - `tenant:aws-dev` `tenant` `aws_region:aws-dev`

   The backend object is `aws_region:aws-dev` — derived from the tenant id.
   Because `tenant:aws-dev` parents `provider:aws`, its members get
   `can_use provider:aws`, and `aws_region:aws-dev`'s `tenant` relation
   propagates owner/admin/viewer → `can_provision` / `can_read`.

The script prints the generated passwords and the exact next commands.

### Step 2 — Owner sets this tenant's backend credentials (in Vault)

Only the tenant **owner** can do this (OpenFGA `can_manage_credentials` =
`owner` only):

```bash
TENANT=aws-dev CLOUD=aws \
  LIBCLOUD_USER=aws-dev-owner LIBCLOUD_PASSWORD='<owner-pw>' \
  LIBCLOUD_AWS_KEY=AKIA... LIBCLOUD_AWS_SECRET=... \
  python3 scripts/set_tenant_credentials.py
```

This writes `secret/data/libcloud/aws-dev` in Vault. `CLOUD=aws` selects the
`LIBCLOUD_AWS_KEY/SECRET` fields; `TENANT=aws-dev` selects the Vault path and
the OpenFGA `can_manage_credentials` check on `tenant:aws-dev`.

For a Nutanix tenant:

```bash
TENANT=ntnx-prod CLOUD=nutanix \
  LIBCLOUD_USER=ntnx-prod-owner LIBCLOUD_PASSWORD='<owner-pw>' \
  LIBCLOUD_NTNX_USER=admin LIBCLOUD_NTNX_PASSWORD=... \
  python3 scripts/set_tenant_credentials.py
```

### Step 3 — Provision / enumerate against the new tenant

Admin provisions, viewer enumerates — just point `auth_binding` at the tenant:

```bash
# AWS admin provisions against tenant:aws-dev
LIBCLOUD_AWS_AUTH_BINDING=aws-dev LIBCLOUD_USER=aws-dev-admin \
  LIBCLOUD_PASSWORD='<admin-pw>' ./scripts/provision_aws.sh

# AWS viewer enumerates only (read-only)
LIBCLOUD_AWS_AUTH_BINDING=aws-dev LIBCLOUD_USER=aws-dev-viewer \
  LIBCLOUD_PASSWORD='<viewer-pw>' ./scripts/provision_aws.sh
```

`provision_aws.sh` builds the backend object `aws_region:aws-dev` from
`LIBCLOUD_AWS_AUTH_BINDING` and sends `auth_binding=aws-dev` in the
`X-Provider-Connection` header. `../libcloud.rest` resolves the backend object
`aws_region:aws-dev` from the same `auth_binding` and reads the Vault secret at
`secret/libcloud/aws-dev` — so the REST API enforces the same per-tenant object
the script checked. End-to-end isolation holds with no code edits.

### Step 4 — Validate

```bash
./system_validate.sh                       # default-tenant regression
PROVISION_VMS=0 LIBCLOUD_AWS_AUTH_BINDING=aws-dev \
  LIBCLOUD_USER=aws-dev-admin LIBCLOUD_PASSWORD='<admin-pw>' \
  ./scripts/provision_aws.sh               # targeted check for the new tenant
```

### Why Case A needs no code edits

| Layer | Why it just works |
|-------|-------------------|
| `../libcloud.rest` policy | `_backend_object` uses `auth_binding` → `aws_region:aws-dev`; object type from `PROVIDER_OBJECT_TYPES`. |
| `../libcloud.rest` identity | `aws-dev-admin` matches the `-admin` role suffix → `PROVISIONER_SCOPES`; `sub=aws-dev-admin` resolves via the known-principal fallback. |
| `../libcloud.rest` credentials | `auth_binding=aws-dev` → Vault `secret/libcloud/aws-dev` (per-tenant). |
| OpenFGA model | `aws_region` type already supports a `tenant` relation; `create_tenant.sh` wires `tenant:aws-dev` → `aws_region:aws-dev`. |
| `openfga_my` scripts | `provision_aws.sh` and `set_tenant_credentials.py` are tenant-aware; `openfga_authorization_flow` treats `*-viewer` as read-only via a glob. |

**Files touched in Case A (runtime state only — no source edits):**

| File / store | What changes |
|--------------|--------------|
| LLDAP directory | 3 new users (`<tenant>-owner/admin/viewer`) |
| OpenFGA store | 9 new tuples (see Step 1) |
| Vault KV (`secret/libcloud/<tenant>`) | 1 new secret (written by the owner in Step 2) |
| `generated/dex.env` | 3 new user + password lines (appended by `create_tenant.sh`) |

---

## Case B — New CLOUD PROVIDER (e.g. `gcp`)

Adding a brand-new cloud is the case that *does* require source edits in both
projects, but the enforcement path is registry-driven so it is mostly
data/table additions. Below is the complete file-by-file list, using `gcp` as
the example. The new provider's default tenant is `tenant:gcp` with backend
object `gcp_region:gcp`.

### B.1 — `openfga_my` project

| File | Change |
|------|--------|
| `openfga_bootstrap.py` → `LIBCLOUD_MODEL` | Add a new type `gcp_region` with the **same relations** as `aws_region` / `nutanix_cluster` (`provider`, `tenant`, `operator`, `viewer`, `tenant_admin`, `tenant_owner`, `tenant_viewer`, `can_read`, `can_provision`). The `provider` and `tenant` types are already generic — no change. |
| `openfga_bootstrap.py` → `INITIAL_TUPLES` | Seed the default tenant: `user:superadmin owner tenant:gcp`; `user:gcp-owner/admin/viewer` on `tenant:gcp`; `tenant:gcp parent libcloud_api:main`; `tenant:gcp parent provider:gcp`; `provider:gcp provider gcp_region:gcp`; `tenant:gcp tenant gcp_region:gcp`. |
| `openfga_bootstrap.py` → `VALIDATION_CHECKS` | Add checks: `gcp-owner`/`gcp-admin` `can_provision gcp_region:gcp` = True; `gcp-viewer` `can_read` True / `can_provision` False; cross-cloud isolation (`gcp-admin` cannot `can_use provider:aws`). |
| `dex_bootstrap.py` | Add `("gcp-owner", "LIBCLOUD_PASSWORD_GCP_OWNER")`, `_ADMIN`, `_VIEWER` to the per-user password list. |
| `setup.sh` | Add `ensure_user gcp-owner …`, `gcp-admin`, `gcp-viewer` (and to the closing summary `echo` block). |
| `.env` and `.env.example` | Add `LIBCLOUD_PASSWORD_GCP_OWNER` / `_ADMIN` / `_VIEWER` placeholders and `LIBCLOUD_GCP_AUTH_BINDING=gcp`. |
| `scripts/common.sh` | Add `gcp-owner/admin/viewer` cases to the password-resolution `case` and the `ALLOW_DEV_DEFAULTS` `case`; add a `build_gcp_connection_param` function mirroring `build_aws_connection_param` (default binding `gcp`). `openfga_authorization_flow` already handles `*-viewer` via a glob — **no change**. |
| `scripts/provision_gcp.sh` (**NEW**) | Copy `provision_aws.sh`; set provider `gcp`, backend object `gcp_region:${LIBCLOUD_GCP_AUTH_BINDING:-gcp}`, and GCP-specific connection fields. |
| `scripts/create_tenant.sh` | Add `gcp) BACKEND_TYPE="gcp_region" ;;` to the `CLOUD` `case`, and a `gcp` branch in the credential-echo `if`. |
| `scripts/set_tenant_credentials.py` | Add `gcp` to `CLOUDS` and a `cloud == "gcp"` branch selecting the GCP credential env fields (e.g. `LIBCLOUD_GCP_SA_KEY` / `_SECRET`). |
| `system_validate.sh` | Add `gcp` LLDAP-user, OIDC, provision, and `tenant-creds` validation sections. |
| `authorization.md`, `ARCHITECTURE.md` | Add `gcp_region` to the object graph, the principals table, and the permissions matrix. |
| `vault_bootstrap.py` | **No change** (Vault no longer seeds global creds; owners set per-tenant creds). |

### B.2 — `../libcloud.rest` project

| File | Change |
|------|--------|
| `app/connections/models.py` | Add `"gcp": "gcp_region"` to `PROVIDER_OBJECT_TYPES`. This single line makes `ProviderConnection(provider="gcp")` valid **and** makes `policy.py::_backend_object` derive `gcp_region:<binding>`. No other change in the auth path. |
| `app/providers/routes.py` | Add a `gcp` entry to `PROVIDERS` with `"fga_object_type": PROVIDER_OBJECT_TYPES["gcp"]` and its `supported_operations`. |
| `app/providers/gcp.py` (**NEW**) | `create_gcp_driver(key, secret, config)` mirroring `app/providers/aws.py`. |
| `app/providers/factory.py` | Add `if connection.provider == "gcp": return create_gcp_driver(...)` to `build_driver`. |
| `app/connections/credentials.py` | Add `"gcp": "gcp"` to `_PROVIDER_TO_DEFAULT_BINDING`; optionally add a `gcp` branch to `_env_credentials` (dev fallback only — Vault is preferred). `default_auth_binding` already falls back to the provider id for any provider not in the settings overrides. |
| `app/auth/identity.py` | **No change required** for `gcp-owner/admin/viewer` — the role-suffix logic (`-owner`/`-admin`/`-viewer`) grants scopes/providers automatically. Add explicit `PRINCIPAL_SCOPES`/`PRINCIPAL_PROVIDERS` entries only if you want non-suffix-based principal names. |
| `data/principal_map.json` | **No change required** (`sub=gcp-admin` resolves via the known-principal fallback). Optionally add `gcp-*@libcloud.local` entries to `by_email`. |
| `app/auth/policy.py` | **No change** — registry-driven. |
| `app/config/settings.py`, `.env`, `.env.example` | Optional: GCP-specific dev fallback settings; not required when Vault is the credential broker. |
| `REST_API_REFERENCE.md` | Add `gcp_region:<auth_binding>` to the backend-objects list and example tuples. |

### B.3 — Step-by-step (new provider `gcp`)

1. **OpenFGA model + default tenant** — edit `openfga_bootstrap.py` (model type
   `gcp_region`, `INITIAL_TUPLES`, `VALIDATION_CHECKS`) and re-run
   `openfga-bootstrap` (superadmin-gated) to push the new model + tuples.
2. **libcloud.rest registry + driver** — add the `PROVIDER_OBJECT_TYPES` entry,
   the `PROVIDERS` entry, `app/providers/gcp.py`, and the `factory.py` branch;
   restart the REST API.
3. **Identity / users** — add `gcp-owner/admin/viewer` to `dex_bootstrap.py`,
   `setup.sh`, `.env` passwords, and `common.sh` password cases; re-run
   `setup.sh` (or just `lldap_ensure_user.sh` for the 3 users).
4. **Default tenant credentials** — the new `gcp-owner` sets them:
   `TENANT=gcp CLOUD=gcp LIBCLOUD_USER=gcp-owner … LIBCLOUD_GCP_SA_KEY=… LIBCLOUD_GCP_SA_SECRET=… python3 scripts/set_tenant_credentials.py`.
5. **Provision** — `LIBCLOUD_GCP_AUTH_BINDING=gcp LIBCLOUD_USER=gcp-admin ./scripts/provision_gcp.sh`.
6. **Add more GCP tenants** — from here on, additional GCP tenants (e.g.
   `gcp-prod`) are **Case A** again: `TENANT=gcp-prod CLOUD=gcp ./scripts/create_tenant.sh`,
   no further code edits.

---

## File-change matrix (quick reference)

### Case A — new tenant on existing cloud
| Project | Source files edited | Runtime state created |
|--------|---------------------|-----------------------|
| `openfga_my` | none | LLDAP users, OpenFGA tuples, `generated/dex.env` lines |
| `../libcloud.rest` | none | (reads the new Vault secret + OpenFGA tuples at request time) |
| Vault | none | `secret/libcloud/<tenant>` (owner-written) |

### Case B — new cloud provider
| Project | Files edited | New files |
|--------|--------------|-----------|
| `openfga_my` | `openfga_bootstrap.py`, `dex_bootstrap.py`, `setup.sh`, `.env`, `.env.example`, `scripts/common.sh`, `scripts/create_tenant.sh`, `scripts/set_tenant_credentials.py`, `system_validate.sh`, `authorization.md`, `ARCHITECTURE.md` | `scripts/provision_gcp.sh` |
| `../libcloud.rest` | `app/connections/models.py`, `app/providers/routes.py`, `app/providers/factory.py`, `app/connections/credentials.py`, `REST_API_REFERENCE.md` | `app/providers/gcp.py` |

---

## Verification checklist

- [ ] `python3 -m py_compile` on every edited `.py`; `bash -n` on every edited `.sh`.
- [ ] `../libcloud.rest`: `python3 -c "import app.main"` succeeds.
- [ ] `PolicyEngine()._backend_object(ProviderConnection(provider="<new>", auth_binding="<tenant>"))` returns `<object_type>:<tenant>`.
- [ ] `principal_scopes("<tenant>-admin")` is non-empty (REST API won't 403 with `auth_user_unknown`).
- [ ] `./system_validate.sh` passes for default tenants.
- [ ] New tenant: owner can `set_tenant_credentials.py`; admin cannot (denied by `can_manage_credentials`).
- [ ] New tenant: admin can provision, viewer can only enumerate, cross-tenant denied.
