# Provisioning Command Help

Reference for the environment variables consumed by the three runner scripts
(`myrun_aws_admin.sh`, `myrun_aws_view.sh`, `myrun_nutanix.sh`) and the
underlying commands they invoke: `scripts/set_tenant_credentials.py`,
`scripts/provision_aws.sh`, and `scripts/provision_nutanix.sh`.

## Common runtime / one-time bootstrap env vars

### `AWS_ACCESS_KEY` + `AWS_SECRET_ACCESS_KEY`
- **Where used:** `myrun_aws_admin.sh` (lines 11–12) and `myrun_aws_view.sh`
  (lines 1–2) define them inline, then pass them to `set_tenant_credentials.py`
  as `LIBCLOUD_AWS_KEY` / `LIBCLOUD_AWS_SECRET`.
- **What they are:** The raw AWS IAM key + secret for the **aws** tenant's
  backend identity. These are **not** used by `provision_aws.sh` itself — the
  REST API uses server-side credentials pulled from Vault. They are only
  written into Vault once by the tenant **owner**.
- **How to use:** Replace the hardcoded values with your own AWS IAM
  credentials. They are only consumed at credential-setup time:

  ```
  LIBCLOUD_AWS_KEY=${AWS_ACCESS_KEY} LIBCLOUD_AWS_SECRET=${AWS_SECRET_ACCESS_KEY} \
    python3 scripts/set_tenant_credentials.py
  ```

### `LIBCLOUD_PASSWORD_AWS_OWNER` / `LIBCLOUD_PASSWORD_NTNX_OWNER`
- **Where used:** `myrun_aws_admin.sh:13`, `myrun_aws_view.sh:3`,
  `myrun_nutanix.sh:9`.
- **What it is:** The LLDAP password of the tenant **owner** service account
  (`aws-owner` / `ntnx-owner`). Used to log in to Dex (via `idp_login.py`) so
  the owner can prove identity before writing backend creds to Vault.
- **How to use:** Set to the owner SA password. Only the owner (or superadmin)
  passes `can_manage_credentials` in OpenFGA, so this is the only role that can
  run `set_tenant_credentials.py` successfully.

### `LIBCLOUD_OIDC_CLIENT_SECRET`
- **Where used:** `myrun_aws_admin.sh:15`, `myrun_nutanix.sh:14`.
- **What it is:** The OIDC client secret registered in Dex for the libcloud
  REST client. Required by `idp_login.py` to perform the token exchange
  (Dex client_credentials / password grant).
- **How to use:** Must match the secret configured in Dex's
  `generated/dex.env`. If you `source ../dex/generated/dex.env` it is provided
  for you; otherwise pass it inline as the scripts do.

## Per-call env vars (passed to `set_tenant_credentials.py`)

| Var | Purpose |
|---|---|
| `TENANT` | Tenant id, e.g. `aws`, `aws-dev`, `nutanix`. Selects the Vault path `secret/data/libcloud/<tenant>` and the OpenFGA `tenant:<id>` object. Required. |
| `CLOUD` | `aws` or `nutanix`. For default tenants inferred from `TENANT`; required for custom tenants like `aws-dev`. Decides whether `LIBCLOUD_AWS_*` or `LIBCLOUD_NTNX_*` fields are read. |
| `LIBCLOUD_USER` | LLDAP username of the caller (the owner). Sent to Dex for login and used as the OpenFGA `user:<name>` subject. |
| `LIBCLOUD_PASSWORD` | LLDAP password for `LIBCLOUD_USER`. |
| `LIBCLOUD_AWS_KEY` / `LIBCLOUD_AWS_SECRET` | The actual AWS key/secret to store in Vault for this tenant. |
| `LIBCLOUD_NTNX_USER` / `LIBCLOUD_NTNX_PASSWORD` | The Nutanix Prism admin username/password to store in Vault for this tenant. In `myrun_nutanix.sh:15` these are literally `admin`/`admin` — replace with your Prism creds. |

Optional overrides read by `set_tenant_credentials.py`:
- `FGA_API_URL` (default `http://localhost:8080`), `FGA_STORE_ID`,
  `FGA_MODEL_ID` — normally auto-loaded from `generated/fga.env`.
- `VAULT_ADDR` (default `http://localhost:8200`), `VAULT_ROOT_TOKEN` —
  auto-loaded from `../vault/generated/vault.env`.

## Per-call env vars (passed to `provision_aws.sh` / `provision_nutanix.sh`)

### `LIBCLOUD_USER`
The LLDAP identity running the provisioning flow. The same name is used for
Dex login and as the OpenFGA subject. The scripts special-case `*-viewer` /
`reader` / `cloud-readonly` to skip mutating calls (see
`provision_nutanix.sh:50`). Examples: `aws-admin`, `aws-viewer`,
`ntnx-admin`, `ntnx-viewer`.

**Required.** Must be paired with the matching `LIBCLOUD_PASSWORD` env var
(common.sh reads it) unless you've sourced Dex env that supplies a token.

### `TENANT` + `CLOUD_PROVIDER`
- `TENANT=aws CLOUD_PROVIDER=aws` (admin/viewer script) and
  `TENANT=nutanix CLOUD_PROVIDER=nutanix` (nutanix script).
- Inside `provision_aws.sh` `TENANT` feeds `LIBCLOUD_AWS_AUTH_BINDING`
  (default `aws`), which sets the OpenFGA backend object
  `aws_region:<binding>` and the Vault secret path the REST API reads from.
  Same for Nutanix via `LIBCLOUD_NTNX_AUTH_BINDING` →
  `nutanix_cluster:<binding>`.
- Override `LIBCLOUD_AWS_AUTH_BINDING` / `LIBCLOUD_NTNX_AUTH_BINDING` to
  target a non-default tenant (e.g. `aws-dev`) without changing `TENANT`.

### `PROVISION`
- `0` (default) = dry-run: lists locations/sizes/images/nodes and exits.
- `1` = actually create a VM (POST `/v1/compute/nodes`).

### `TEARDOWN_VMS`
- `1` = after provisioning, delete the VM whose name matches `VM_NAME`. Note
  the caveat in `myrun_aws_admin.sh:71`: only the VM from *this run* is
  deleted (exact `VM_NAME` match), not all `libcloud-demo-*` leftovers.

### `VERBOSE`
- `1` = `common.sh` logs full HTTP request headers/bodies to stderr.
  Equivalent to passing `-v` to the provision scripts.

### Catalog override vars (optional, AWS)
- `AWS_REGION` — default `ap-southeast-1`.
- `AWS_INSTANCE_ARCH` — `x86_64` (default) or `arm64`; used by
  `aws_resolve_catalog.py` to pick a compatible image/size.
- `AWS_DEFAULT_SIZE_ID` — hint size id.
- `AWS_IMAGE_NAME_FILTER` — default `*Ubuntu*`; controls
  `/v1/compute/images?name=...`.
- `IMAGE_ID`, `SIZE_ID`, `SUBNET_ID` — bypass auto-resolution and pin
  specific catalog ids.
- `VM_NAME` — default `libcloud-demo-<epoch>` (AWS) /
  `libcloud-ntnx-<epoch>` (Nutanix).

### Catalog override vars (optional, Nutanix)
- `CLUSTER_ID`, `IMAGE_ID`, `SIZE_ID` (default `small`), `SUBNET_ID` — pin
  specific catalog ids; otherwise auto-picked from the first returned entry.
- `FGA_NUTANIX_CLUSTER` — overrides the cluster name used for the OpenFGA
  backend object (defaults to the auth binding).
- `VM_NAME` — default `libcloud-ntnx-<epoch>`.

## How the three runners fit together

1. `myrun_aws_admin.sh <script>` — refreshes OpenFGA JWKS, registers the AWS
   tenant's backend creds into Vault as `aws-owner`, then runs the given
   script as `aws-admin` with `PROVISION=1` (creates an EC2 VM). Requires
   one arg: the script path, typically `./scripts/provision_aws.sh`.
2. `myrun_aws_view.sh` — registers creds as `aws-owner` (same first step),
   then exercises the **read-only** path as `aws-viewer` against
   `provision_aws.sh` and `deprovision_aws.sh`. Note: it lacks the
   `#!/usr/bin/bash` header and arg guard that the admin script has, so run
   it directly with `bash myrun_aws_view.sh`.
3. `myrun_nutanix.sh <script>` — refreshes JWKS, registers Nutanix creds
   into Vault as `ntnx-owner` (using `LIBCLOUD_NTNX_USER=admin
   LIBCLOUD_NTNX_PASSWORD=admin` — replace these), then runs the given
   script as `ntnx-admin` with `PROVISION=1`. Requires one arg, typically
   `./scripts/provision_nutanix.sh`.

## A couple of things worth flagging

- The AWS key/secret and several SA passwords are committed in plaintext in
  these runner files (e.g. `myrun_aws_admin.sh:11-13`,
  `myrun_nutanix.sh:9,14-15`). They look like real credentials, not
  placeholders. You should rotate them and move them out of the scripts
  (e.g. source from a gitignored env file) before committing.
- `LIBCLOUD_NTNX_USER=admin LIBCLOUD_NTNX_PASSWORD=admin` in
  `myrun_nutanix.sh:15` is a demo default; replace with your real Prism
  admin credentials.
- `myrun_nutanix.sh` and `myrun_aws_view.sh` have no shebang and (for
  nutanix) no arg guard, unlike `myrun_aws_admin.sh`. Invoke them
  explicitly with `bash ...`.
