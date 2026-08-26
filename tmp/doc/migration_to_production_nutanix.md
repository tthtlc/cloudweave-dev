# Migration to Production Nutanix Server

## Scope

This document covers the end-to-end steps to switch the libcloud portal from
mock/dev mode to a **real Nutanix Prism Central (or Prism Element)** server for
production use. It also explains the relationship between the mock-data image
name and the real image catalog.

---

## 1. The mock image change is cosmetic only

The mock data in `server/src/services/mockData.js` is **only used when
`REACT_APP_MOCK_MODE=true`** (set in `server/src/config.js` line 18). The
frontend bypasses it entirely when talking to the real backend.

On a real Nutanix server, image names come from whatever ISOs or disk images
the Nutanix admin uploaded to the **Prism Central Image Service**. They
typically look nothing like `"ubuntu-24.04-cloudimg"` — they're whatever the
admin named them at upload time (e.g. `"Ubuntu 24.04 LTS"`,
`"ubuntu-24.04.3-live-server-amd64.iso"`, etc.).

Changing the mock image name from `"ubuntu-22.04-cloudimg"` to
`"ubuntu-24.04-cloudimg"` is a cosmetic refresh of demo data — it has **zero
effect on production** because the real image list comes from the Nutanix API,
not from JavaScript mocks.

---

## 2. Architecture overview

```
┌─────────────────────────────────────────────────────────┐
│  Your host                                               │
│  ┌──────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │ Frontend │  │ Identity Svc │  │ libcloud REST API │  │
│  │ :3000    │  │ :8766        │  │ :8765             │  │
│  └──────────┘  └──────┬───────┘  └────────┬──────────┘  │
│                       │                   │              │
│                       │  internal docker  │              │
│                       │  network          │              │
│                       └───────────────────┘              │
│                                                          │
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │
│                                                          │
│  ┌──────────────────────────────────────────────────┐    │
│  │  Real Nutanix Prism Central / Prism Element      │    │
│  │  https://<nutanix-host>:9440                     │    │
│  │  (or cluster IP / VIP)                           │    │
│  └──────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

The libcloud REST API (`:8765`) is the only component that talks directly to
the Nutanix API. The identity service (`:8766`) proxies provisioning requests
through it. The frontend (`:3000`) talks only to the identity service — it
never contacts Nutanix directly.

---

## 3. Step-by-step migration

### Step 1 — Network & connectivity prerequisites

- **Verify network reachability**: The host running the libcloud REST API must
  be able to reach the Nutanix Prism Central (or Prism Element) at its
  management IP on port **9440**.
- **Verify SSL**: If the Nutanix cluster uses a self-signed certificate
  (default), set `NUTANIX_VERIFY_SSL=false`. For production with a real CA,
  set it to `true`.

```bash
# Quick connectivity test from the REST API host
curl -k https://<nutanix-host>:9440/api/nutanix/v3/clusters/list
```

### Step 2 — Configure environment variables

These settings go into **`libcloud.rest/.env`** (the REST API's own env file):

```bash
# Nutanix connection — REPLACE with your real cluster values
NUTANIX_HOST=<your-prism-central-ip-or-fqdn>   # e.g. 10.20.30.40 or prism-central.example.com
NUTANIX_PORT=9440                               # Prism Central default
NUTANIX_API_VERSION=v4.0                        # v4 API (use v4.0.b1 for some versions)
NUTANIX_VERIFY_SSL=false                        # true if you have a real CA cert

# Per-tenant Nutanix credentials — fallback when Vault is not configured.
# These are the REST API's server-side identity for accessing Nutanix
# (the client NEVER receives these).
LIBCLOUD_NTNX_LAB_USER=admin                   # Prism Central admin user
LIBCLOUD_NTNX_LAB_PASSWORD=<password>
```

And in **`identity_service/.env`**:

```bash
NUTANIX_HOST=<same-ip>      # host.docker.internal if Nutanix is on the same host
NUTANIX_PORT=9440
NUTANIX_API_VERSION=v4.0
NUTANIX_VERIFY_SSL=false
```

### Step 3 — Disable mock mode on the frontend

In the frontend environment (or `server/.env`):

```bash
REACT_APP_MOCK_MODE=false
```

This makes `server/src/services/api.js` use the real HTTP client (`fetch`)
instead of `mockApi.js`.

### Step 4 — Credential setup via Vault (production path)

The libcloud REST API resolves backend credentials from **Vault** (not from
env vars directly). Each tenant's credentials live at:

```
secret/data/libcloud/<binding>
```

To seed the Nutanix tenant credentials:

```bash
# Run this as the ntnx-owner user (or superadmin) — only they have
# OpenFGA can_manage_credentials on nutanix_cluster:nutanix.
TENANT=nutanix \
LIBCLOUD_USER=ntnx-owner \
LIBCLOUD_PASSWORD=$LIBCLOUD_PASSWORD_NTNX_OWNER \
LIBCLOUD_NTNX_USER=admin \
LIBCLOUD_NTNX_PASSWORD=<your-real-nutanix-password> \
python3 scripts/set_tenant_credentials.py
```

The env vars `LIBCLOUD_NTNX_LAB_USER` / `LIBCLOUD_NTNX_LAB_PASSWORD` in
`libcloud.rest/.env` are the **fallback** when Vault is not configured. For
production, Vault is the canonical source — leave the env vars empty and rely
on Vault.

### Step 5 — Verify the connection

```bash
# Set up the environment
source test_script/scripts/common.sh

# Run the Nutanix provisioning script in dry-run mode (no actual VM creation)
LIBCLOUD_USER=ntnx-admin \
CLOUD_PROVIDER=nutanix \
./test_script/scripts/provision_nutanix.sh
```

This hits:
- `GET /v1/compute/images` — Prism Central image catalog
- `GET /v1/compute/locations` — AHV clusters
- `GET /v1/compute/sizes` — available instance sizes
- `GET /v1/compute/storage-containers` — storage containers for VM disks
- `GET /v1/compute/subnets` — network subnets

Check the output to confirm each returns real data from your cluster.

### Step 6 — Ensure required Nutanix resources exist

On the **Nutanix Prism Central** side, an admin must have:

| Resource | Where to check | Required for |
|---|---|---|
| **Images** | Prism Central → Compute & Storage → Images | VM provisioning (must have at least one bootable disk image uploaded, e.g. Ubuntu 24.04 ISO) |
| **Subnet(s)** | Prism Central → Networking → Subnets | VM NIC placement |
| **Cluster(s)** | Prism Central → Hardware → Clusters | VM placement target |
| **Storage container(s)** | Prism Central → Storage → Storage Containers | VM disk placement |

**If no images exist**, upload one:

1. Prism Central → Compute & Storage → Images → **Add Image**
2. Provide a URL, e.g.:
   `https://releases.ubuntu.com/24.04.3/ubuntu-24.04.3-live-server-amd64.iso`
3. Or upload from a local file
4. Image type: **DISK_IMAGE**

The image name on the real Nutanix server is whatever you name it during
upload — the mock data name (`"ubuntu-24.04-cloudimg"`) is irrelevant.

### Step 7 — Run a real provisioning test

```bash
# Actually provision a VM on Nutanix
PROVISION=1 \
LIBCLOUD_USER=ntnx-admin \
VM_NAME=test-nutanix-prod-$(date +%s) \
./test_script/scripts/provision_nutanix.sh
```

The `provision_nutanix.sh` script resolves `IMAGE_ID` by picking the **first
image** from the API response:

```bash
IMAGE_ID="${IMAGE_ID:-$(libcloud_api GET "/v1/compute/images" | python3 -c
    'import json,sys; d=json.load(sys.stdin).get("data",[]); print(d[0]["id"] if d else "")')}"
```

If you need to pick a specific image by name, set it explicitly:

```bash
IMAGE_ID=$(libcloud_api GET "/v1/compute/images" | python3 -c "
import json,sys
data = json.load(sys.stdin).get('data',[])
match = [i for i in data if '24.04' in i.get('name','')]
print(match[0]['id'] if match else '')
")
```

### Step 8 — Verify the portal end-to-end

1. Start the full stack:
   ```bash
   ./setup.sh
   ```
2. Open `http://localhost:3000`
3. Log in as **ntnx-admin** (or ntnx-owner)
4. Click **"View Nutanix Resources"** — should show real cluster, VMs, subnets
   from Prism Central
5. Click **"Provision Nutanix"** — should create a real VM on the cluster
6. Click **"Provision Private VM Machine"** — should create bastion + internal
   VMs (requires the `provision_nutanix_bastion_private.sh` script's
   prerequisites)

---

## 4. Comparison: mock mode vs. real Nutanix

| Aspect | Mock mode | Real Nutanix |
|---|---|---|
| Image list source | `mockData.js` hardcoded | Prism Central `vmm/content/images` API |
| Image names | `"ubuntu-24.04-cloudimg"` | Whatever the Nutanix admin uploaded |
| VM creation | Simulated delay, no real VM | Real AHV VM created via Prism Central |
| Credentials | None needed | Vault `secret/libcloud/nutanix` |
| Networking | Mock data | Real VPCs/subnets from Prism |
| Storage | Mock data | Real storage containers |
| Cluster discovery | Hardcoded `"Dev Cluster"` | Real cluster list from Prism |

---

## 5. Configuration reference

### Environment variables (libcloud.rest/.env)

| Variable | Default | Description |
|---|---|---|
| `NUTANIX_HOST` | `localhost` | Prism Central IP or FQDN |
| `NUTANIX_PORT` | `9440` | Prism Central API port |
| `NUTANIX_API_VERSION` | `v4.0` | API version (v4.0, v4.0.b1) |
| `NUTANIX_VERIFY_SSL` | `false` | Verify SSL certificate |
| `LIBCLOUD_NTNX_LAB_USER` | (empty) | Fallback Nutanix username |
| `LIBCLOUD_NTNX_LAB_PASSWORD` | (empty) | Fallback Nutanix password |

### Vault secrets (per-tenant)

| Path | Keys | Description |
|---|---|---|
| `secret/data/libcloud/nutanix` | `user`, `password` | Nutanix credentials for the default tenant |
| `secret/data/libcloud/<custom>` | `user`, `password` | Credentials for a custom tenant binding |

### OpenFGA objects

| Object | Purpose |
|---|---|
| `tenant:nutanix` | Tenant entity — users belong to this tenant |
| `nutanix_cluster:nutanix` | Backend resource — gated by `can_provision`, `can_view`, `can_manage_credentials` |
| `cluster:nutanix` | Runtime cluster identity |

---

## 6. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `connection test failed` | REST API cannot reach Nutanix | Check `NUTANIX_HOST` and network/firewall; verify with `curl` |
| `SSL certificate verify failed` | Self-signed cert on Nutanix | Set `NUTANIX_VERIFY_SSL=false` |
| `Provider does not support image listing` | API version mismatch | Try `NUTANIX_API_VERSION=v4.0.b1` |
| No images returned | No images uploaded to Prism Central | Upload an ISO/disk image in Prism Central UI |
| No subnets returned | No networks configured | Create a subnet in Prism Central → Networking |
| `could not resolve compatible IMAGE_ID/SIZE_ID` | No images or sizes found | Verify images and sizes exist via the catalog endpoints |
| Portal shows empty dashboard | `REACT_APP_MOCK_MODE` still `true` | Set to `false` and rebuild/redeploy the frontend |
| 401 on provisioning | Vault credentials not seeded | Run `set_tenant_credentials.py` as tenant owner |
