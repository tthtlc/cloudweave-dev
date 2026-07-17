# How to Create / Modify / Deprecate a Cloud-Provider Driver in libcloud

This guide covers adding a **new cloud-provider driver** to the
`../libcloud` Apache Libcloud fork (the libcloud-side half of "add a new
cloud"). It is the libcloud counterpart to
[how_to_create_libcloud_rest_provider_registry.md](how_to_create_libcloud_rest_provider_registry.md)
and the cross-project [how_to_add_new_tenant.md](how_to_add_new_tenant.md)
Case B.

> **What a driver is here.** A libcloud driver is a subclass of
> `NodeDriver` (compute), `StorageDriver` (storage), etc., that translates
> libcloud's uniform resource model into a specific cloud's native API. The
> current fork ships compute + storage drivers for Nutanix Prism Central v4
> (`libcloud/compute/drivers/nutanix.py`, `libcloud/storage/drivers/nutanix.py`)
> alongside upstream's EC2 driver. Each driver is registered in
> `libcloud/compute/providers.py` (and `libcloud/storage/providers.py`) as
> `Provider.<NAME>: ("module.path", "ClassName")`.

---

## 0. The two-layer pattern (Nutanix as the reference)

The Nutanix driver is split across two files — this is the pattern to copy:

| File | Contents |
|------|----------|
| `libcloud/common/nutanix.py` | Shared connection class (`NutanixConnection`), path builders (`vmm_path`, `networking_path`, `clustermgmt_path`, `prism_path`, `volumes_path`, `dataprotection_path`), payload builders (`build_vm_create_payload`, `build_vpc_create_payload`, …), and helpers (`extract_task_ext_id`, `extract_etag`, `bytes_to_gib`, …). |
| `libcloud/compute/drivers/nutanix.py` | `NutanixNodeDriver(NodeDriver)` with `list_nodes`, `create_node`, `destroy_node`, `ex_list_subnets`, `ex_list_vpcs`, `list_volumes`, `create_volume_snapshot`, … and the `_execute_async_mutation` + task-polling pattern for mutating calls. |

The split keeps the driver file readable and lets the REST API reuse the
payload builders if needed.

---

## 1. Prerequisites

- `../libcloud` is checked out; `python3 -c "import libcloud"` works in the
  venv.
- You have the cloud's API docs (REST paths, auth scheme, async-task
  pattern if any).
- The libcloud.rest side will register the new provider — see
  [how_to_create_libcloud_rest_provider_registry.md](how_to_create_libcloud_rest_provider_registry.md).

---

## 2. ADD a new cloud driver (e.g. GCP compute)

### Step 1 — Add a `Provider` enum entry

`libcloud/compute/providers.py` (and `libcloud/common/types.py` if the
`Provider` enum lives there):

```python
class Provider(Type):
    ...
    GCP = "gcp"   # new
```

### Step 2 — Register the driver class

`libcloud/compute/providers.py` `DRIVERS` map:

```python
DRIVERS = {
    ...
    Provider.GCP: ("libcloud.compute.drivers.gcp", "GCPNodeDriver"),
}
```

### Step 3 — Write the common layer

`libcloud/common/gcp.py` (NEW):
- A `GCPConnection` class (auth, base URL, request helper, error handling).
- Path / payload builders for the resources you will expose.
- Helpers for whatever pagination / async pattern GCP uses.

Mirror `libcloud/common/nutanix.py`.

### Step 4 — Write the driver

`libcloud/compute/drivers/gcp.py` (NEW):

```python
from libcloud.common.gcp import GCPConnection
from libcloud.compute.base import Node, NodeDriver, NodeImage, NodeLocation, NodeSize

class GCPNodeDriver(NodeDriver):
    type = Provider.GCP
    name = "GCP"
    website = "https://cloud.google.com/"
    connectionCls = GCPConnection

    def list_nodes(self, **kwargs): ...
    def list_images(self, location=None, **kwargs): ...
    def list_sizes(self, location=None): ...
    def list_locations(self): ...
    def create_node(self, name, size, image, **kwargs): ...
    def destroy_node(self, node, **kwargs): ...
    # ex_* for GCP-specific extras
```

Mirror `libcloud/compute/drivers/nutanix.py` for structure:
- `NODE_STATE_MAP` mapping the cloud's state strings → libcloud `NodeState`.
- `_to_node`, `_to_image`, `_to_size`, `_to_location` adapters that turn the
  cloud's JSON into libcloud base objects.
- For mutating calls that return a task/operation, implement the
  `_execute_async_mutation` + poll pattern (see Nutanix driver).

### Step 5 — (Optional) storage driver

If the cloud has object storage, repeat for `libcloud/storage/drivers/gcp.py`
and register in `libcloud/storage/providers.py`.

### Step 6 — Tests

Add `libcloud/test/compute/test_gcp.py` mirroring
`libcloud/test/compute/test_nutanix.py` (and `test_nutanix_emulator.py`
against the stoplight mock). Run:

```bash
python3 -m pytest libcloud/test/compute/test_gcp.py
```

### Step 7 — Wire it into libcloud.rest

See [how_to_create_libcloud_rest_provider_registry.md](how_to_create_libcloud_rest_provider_registry.md)
— add `PROVIDER_OBJECT_TYPES["gcp"] = "gcp_region"`, `app/providers/gcp.py`,
and the `factory.py` branch.

---

## 3. MODIFY a driver

| Change | Where |
|--------|-------|
| Add / change a method on an existing driver | the driver file + a test; see [how_to_create_libcloud_resource_method.md](how_to_create_libcloud_resource_method.md) |
| Change a payload / path builder | `libcloud/common/<cloud>.py` |
| Change the API version default | `libcloud/common/<cloud>.py` `DEFAULT_API_VERSION` |
| Change auth / connection | `libcloud/common/<cloud>.py` `<Cloud>Connection` |
| Bump the registered class name | `libcloud/<api>/providers.py` `DRIVERS` |

Re-run the driver's tests; recreate the libcloud REST API if the REST side
calls the changed method.

---

## 4. DEPRECATE / remove a driver

1. Remove the libcloud.rest provider registry entry first — see
   [how_to_create_libcloud_rest_provider_registry.md](how_to_create_libcloud_rest_provider_registry.md) §4
   (offboard tenants, remove `PROVIDER_OBJECT_TYPES` / `PROVIDERS` /
   `factory.py` branch / `app/providers/<id>.py`).
2. Remove the `DRIVERS` entry from `libcloud/compute/providers.py` (and
   `storage/providers.py`).
3. Remove the `Provider.<NAME>` enum entry.
4. Delete `libcloud/compute/drivers/<cloud>.py` and
   `libcloud/common/<cloud>.py` (and the storage driver if any).
5. Delete the tests under `libcloud/test/compute/test_<cloud>*.py`.
6. Remove the stoplight mock namespace if one existed for it — see
   [how_to_create_stoplight_mock_namespace.md](how_to_create_stoplight_mock_namespace.md) §4.

---

## 5. VERIFY

```bash
# The driver imports + registers:
python3 -c "from libcloud.compute.providers import get_driver, Provider; \
  print(get_driver(Provider.GCP))"

# Unit / emulator tests:
python3 -m pytest libcloud/test/compute/test_gcp.py

# Through the REST API (after the registry is wired):
LIBCLOUD_GCP_AUTH_BINDING=gcp LIBCLOUD_USER=gcp-admin ./scripts/provision_gcp.sh
```

---

## 6. Files touched

| File | What changes |
|------|--------------|
| `libcloud/compute/providers.py` | `Provider` enum + `DRIVERS` entry |
| `libcloud/common/<cloud>.py` | NEW — connection + builders |
| `libcloud/compute/drivers/<cloud>.py` | NEW — driver class |
| `libcloud/storage/drivers/<cloud>.py` | NEW (if object storage) |
| `libcloud/test/compute/test_<cloud>*.py` | NEW — tests |
| `../libcloud.rest/app/providers/<id>.py`, `factory.py`, `connections/models.py` | registry (separate guide) |

---

## 7. Quick reference

| Action | Command |
|--------|---------|
| Run driver tests | `python3 -m pytest libcloud/test/compute/test_<cloud>.py` |
| Confirm driver loads | `python3 -c "from libcloud.compute.providers import get_driver, Provider; get_driver(Provider.<NAME>)"` |
| REST-side wiring | [how_to_create_libcloud_rest_provider_registry.md](how_to_create_libcloud_rest_provider_registry.md) |
| Cross-project guide | [how_to_add_new_tenant.md](how_to_add_new_tenant.md) Case B |
| Reference driver | `libcloud/compute/drivers/nutanix.py` + `libcloud/common/nutanix.py` |
