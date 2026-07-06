# Nutanix on Apache Libcloud — Conceptual Guide

This guide explains how **Apache Libcloud** models cloud infrastructure, how the **Nutanix Prism Central v4** REST API maps onto that model, and what design choices the Nutanix driver makes.

---

## 1. What is Apache Libcloud?

Apache Libcloud is a Python library that exposes a **vendor-neutral API** for common cloud operations. Instead of learning each provider’s SDK separately, you write code against shared abstractions:

| Libcloud domain | Nutanix coverage in this driver |
|-----------------|--------------------------------|
| **Compute** (`NodeDriver`) | ✅ Implemented (VMs, images, volumes, snapshots) |
| Storage (object) | ❌ Not implemented |
| DNS | ❌ Not implemented |
| Load balancer | ❌ Not implemented |

The Nutanix integration is a **compute driver** targeting **Prism Central** with **AHV** workloads via Nutanix **v4.0** REST namespaces.

---

## 2. Core Libcloud concepts

### 2.1 Provider and driver

A **provider** is a constant (`Provider.NUTANIX`) registered in `libcloud.compute.providers`. You obtain a driver class with `get_driver()` and instantiate it with credentials and endpoint details.

```python
from libcloud.compute.providers import get_driver
from libcloud.compute.types import Provider

cls = get_driver(Provider.NUTANIX)
driver = cls(key="admin", secret="password", host="pc.example.com", port=9440)
```

The driver instance is your single entry point for all operations.

### 2.2 Standard vs extension methods

Libcloud distinguishes:

- **Standard methods** — part of the portable `NodeDriver` API (e.g. `list_nodes`, `create_volume`). Portable across providers where implemented.
- **Extension methods** — prefixed with `ex_` (e.g. `ex_get_node`, `ex_list_subnets`). Nutanix-specific or not part of the base portable contract.

### 2.3 Resource objects

Libcloud returns typed objects instead of raw JSON:

| Object | Represents on Nutanix |
|--------|------------------------|
| `Node` | AHV VM (`extId`, power state, NICs, …) |
| `NodeImage` | Disk/ISO image in image service |
| `NodeLocation` | Cluster (used as “location”) |
| `NodeSize` | **Synthetic** CPU/RAM/disk preset (not a Nutanix catalog) |
| `StorageVolume` | Volume group (block storage) |
| `VolumeSnapshot` | Recovery point (dataprotection) |

Each object has:

- **`id`** — primary external identifier (`extId` on Nutanix)
- **`name`** — human-readable name where applicable
- **`driver`** — back-reference to the driver
- **`extra`** — provider-specific dict (cluster IDs, task IDs, disk metadata, …)

### 2.4 States

Libcloud normalizes provider states into enums:

- **`NodeState`** — `RUNNING`, `STOPPED`, `PENDING`, … mapped from Nutanix `powerState`
- **`StorageVolumeState`** — `AVAILABLE`, `INUSE`, … inferred from VM attachments
- **`VolumeSnapshotState`** — `AVAILABLE` when Nutanix recovery point status is `COMPLETE`

---

## 3. Nutanix v4 API architecture

Nutanix v4 is **multi-namespace**. The driver does not use a single `/api/nutanix/v3` base; each capability lives under its own path prefix:

| Namespace | Libcloud usage | Example path |
|-----------|----------------|--------------|
| **vmm** | VMs, images | `/api/vmm/v4.0/ahv/config/vms` |
| **clustermgmt** | Clusters, storage containers | `/api/clustermgmt/v4.0/config/clusters` |
| **networking** | Subnets (read-only in driver) | `/api/networking/v4.0/config/subnets` |
| **volumes** | Volume groups, attach/detach | `/api/volumes/v4.0/config/volume-groups` |
| **dataprotection** | Recovery points (snapshots) | `/api/dataprotection/v4.0/config/recovery-points` |
| **prism** | Async task polling | `/api/prism/v4.0/config/tasks/{extId}` |

Default API version: **`v4.0`** (`DEFAULT_API_VERSION` in `libcloud.common.nutanix`).

### 3.1 Authentication

- **HTTP Basic auth** — Libcloud `key` = username, `secret` = password.
- Every mutating request includes **`NTNX-Request-Id`** (UUID) for idempotency/tracing.

### 3.2 Response envelope

v4 list/get responses typically look like:

```json
{
  "data": [ ... ] or { ... },
  "metadata": { "totalAvailableResults": N, ... }
}
```

The connection layer parses JSON via `NutanixResponse` and maps HTTP errors to `LibcloudError` / `InvalidCredsError`.

### 3.3 Pagination (OData)

List operations support query parameters:

- `$page`, `$limit` (max 100 per request)
- `$filter`, `$select`, `$orderby`

The driver exposes these via kwargs: `ex_page`, `ex_page_size`, `ex_filter`, `ex_select`, `ex_orderby`.

### 3.4 Async operations and tasks

Many mutations return **HTTP 202** with a **`TaskReference`** (`data.extId`). The driver:

1. Extracts `task_ext_id` from the response
2. Polls `GET /api/prism/v4.0/config/tasks/{extId}` until `SUCCEEDED` or failure
3. Reads **`entitiesAffected`** or **`completionDetails`** for created entity IDs

Common completion detail keys:

| Operation | Detail key |
|-----------|------------|
| Create recovery point (snapshot) | `recoveryPointExtId` |
| Create image | `imageExtId` |

### 3.5 Conditional updates (ETag)

DELETE and some POST actions require **`If-Match`** with the ETag from a prior GET. The driver fetches the resource, extracts `ETag` from response headers, and sends it on mutation.

Resources using ETag in this driver:

- VM power actions and destroy
- Volume group destroy
- Recovery point destroy
- Image destroy

---

## 4. Mapping Nutanix resources to Libcloud

### 4.1 Compute (Phase 1)

| Libcloud method | Nutanix concept | Notes |
|-----------------|-----------------|-------|
| `list_nodes` | AHV VMs | Paginated list |
| `create_node` | VM create | Requires cluster + image; optional subnet, storage container, cloud-init SSH key |
| `destroy_node` | VM delete | Async + ETag |
| `start_node` / `stop_node` / `reboot_node` | Power `$actions` | `power-on`, `shutdown`, `reboot` |
| `list_images` | Content images | |
| `list_sizes` | **Synthetic presets** | `small`/`medium`/`large`/`xlarge` — not from Nutanix API |
| `list_locations` | Clusters | Wraps `ex_list_clusters` |

**Not implemented:** key pairs, `deploy_node`, DNS, object storage.

### 4.2 Block storage (Phase 2)

Nutanix **volume groups** map to Libcloud **`StorageVolume`**.

| Libcloud method | Nutanix API |
|-----------------|-------------|
| `list_volumes` | `GET .../volume-groups` |
| `create_volume` | `POST .../volume-groups` (disk size in **GB**) |
| `destroy_volume` | `DELETE .../volume-groups/{id}` |
| `attach_volume` | `POST .../$actions/attach-vm` |
| `detach_volume` | `POST .../$actions/detach-vm` |
| `create_volume_snapshot` | `POST .../recovery-points` with `volumeGroupRecoveryPoints` |
| `list_volume_snapshots` | `GET .../recovery-points` with OData filter |
| `destroy_volume_snapshot` | `DELETE .../recovery-points/{id}` |

**Important:** On attach, the `device` parameter is the Nutanix **SCSI bus index** (integer), not a Linux path like `/dev/sdb`.

### 4.3 Images (Phase 3)

| Libcloud method | Nutanix API |
|-----------------|-------------|
| `get_image` | `GET .../content/images/{id}` |
| `create_image` | `POST .../content/images` with `VmDiskSource` from VM disk |
| `delete_image` | `DELETE .../content/images/{id}` |
| `ex_create_image_from_url` | `POST .../content/images` with `UrlSource` |

Image types: `DISK_IMAGE`, `ISO_IMAGE`.

---

## 5. Implementation layout

```
libcloud/
├── common/nutanix.py          # Connection, paths, payloads, task helpers
├── compute/
│   ├── drivers/nutanix.py     # NutanixNodeDriver
│   ├── providers.py           # Provider registration
│   └── types.py               # Provider.NUTANIX
└── test/compute/
    ├── test_nutanix.py        # Unit tests (mocked HTTP)
    ├── test_nutanix_emulator.py
    └── fixtures/nutanix/      # JSON fixtures

contrib/docker/nutanix/        # Docker test harness
stoplight_mock/                # Local v4 emulator (optional)
```

### 5.1 Connection layer (`NutanixConnection`)

- HTTPS to Prism Central (default port **9440**)
- Basic auth headers on every request
- `_paged_request()` for OData pagination
- `_wait_for_task()` for async polling

### 5.2 Path helpers

Functions build canonical v4 paths:

- `vmm_path()`, `clustermgmt_path()`, `networking_path()`
- `volumes_path()`, `dataprotection_path()`, `prism_path()`

### 5.3 Payload builders

Pure functions construct JSON bodies aligned with OpenAPI:

- `build_vm_create_payload`
- `build_volume_group_create_payload`
- `build_recovery_point_create_payload`
- `build_image_create_payload`, `build_image_url_source`, `build_image_vm_disk_source`

---

## 6. Synthetic sizes

Unlike DigitalOcean “droplet sizes,” Nutanix has no fixed flavor catalog in this driver. `list_sizes()` returns four **presets** defined in `SYNTHETIC_SIZES`:

| ID | vCPUs | RAM (MiB) | Disk (MiB) |
|----|-------|-----------|------------|
| small | 1 | 2048 | 20480 |
| medium | 2 | 4096 | 51200 |
| large | 4 | 8192 | 102400 |
| xlarge | 8 | 16384 | 204800 |

Use `ex_vcpus`, `ex_memory_mib`, `ex_disk_size_mib` on `create_node()` to override.

---

## 7. Common `ex_*` kwargs pattern

Most async methods accept:

| Kwarg | Default | Meaning |
|-------|---------|---------|
| `ex_wait` | `True` | Wait for Prism task completion |
| `ex_wait_timeout` | `600` | Task poll timeout (seconds) |

Listing methods accept pagination/filter kwargs listed in section 3.3.

---

## 8. Testing strategy

| Layer | How |
|-------|-----|
| **Unit** | `requests_mock` / mocked connection; fixtures in `fixtures/nutanix/` |
| **Integration** | `stoplight_mock` emulator on `:9440`; `NUTANIX_INTEGRATION_TESTS=1` |
| **Docker** | `contrib/docker/nutanix/run_tests.sh` |

Run:

```bash
cd contrib/docker/nutanix && ./run_tests.sh
NUTANIX_INTEGRATION_TESTS=1 ./run_tests.sh integration
```

---

## 9. Known limitations

- **Single Prism Central endpoint** — no built-in multi-PC routing.
- **AHV only** — ESXi VM APIs not exposed.
- **Read-only networking** — subnets listed but not created/deleted via Libcloud.
- **No SSH key API** — cloud-init SSH keys supported via `NodeAuthSSHKey` on create only.
- **Emulator gaps** — local mock implements subset of v4; unhandled routes proxy to Prism schema mock.
- **Power actions** — driver uses spec-canonical action names; verify against your PC version.

---

## 10. Further reading

- Nutanix v4 OpenAPI (local): `stoplight_mock/spec/openapi.json`
- Developer guide with examples: `NUTANIX_LIBCLOUD_DEVELOPER_GUIDE.md`
- Official Libcloud compute API: https://libcloud.readthedocs.io/en/stable/compute/api.html
