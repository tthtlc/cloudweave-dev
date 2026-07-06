# Nutanix on Apache Libcloud — Developer Guide

Hands-on guide for every API implemented by `NutanixNodeDriver`. For architecture and design rationale, see [NUTANIX_LIBCLOUD_CONCEPTUAL_GUIDE.md](NUTANIX_LIBCLOUD_CONCEPTUAL_GUIDE.md).

---

## Prerequisites

```bash
pip install apache-libcloud
# Development / tests:
cd contrib/docker/nutanix && ./run_tests.sh
```

Optional local emulator:

```bash
cd stoplight_mock && docker compose up -d
# Prism mock :4010, stateful shim :9440
```

---

## 1. Instantiate the driver

```python
from libcloud.compute.providers import get_driver
from libcloud.compute.types import Provider

NutanixNodeDriver = get_driver(Provider.NUTANIX)

driver = NutanixNodeDriver(
    key="admin",                    # Prism Central username
    secret="your-password",         # Prism Central password
    host="prism-central.example.com",
    port=9440,                      # default
    secure=True,                    # HTTPS (default)
    api_version="v4.0",             # default
    verify_ssl_cert=True,           # set False for self-signed / emulator
)
```

**Emulator / lab (self-signed TLS):**

```python
driver = NutanixNodeDriver(
    key="admin",
    secret="password",
    host="localhost",
    port=9440,
    verify_ssl_cert=False,
)
```

---

## 2. Discover infrastructure

### 2.1 Clusters (locations)

```python
locations = driver.list_locations()
for loc in locations:
    print(loc.id, loc.name, loc.extra)
# NodeLocation id = cluster extId
```

### 2.2 Subnets

```python
subnets = driver.ex_list_subnets()
for subnet in subnets:
    print(subnet["extId"], subnet["name"])

# With OData filter:
subnets = driver.ex_list_subnets(ex_filter="name eq 'vlan-100'")
```

### 2.3 Storage containers

```python
containers = driver.ex_list_storage_containers()
for sc in containers:
    print(sc.get("extId"), sc.get("name"))
```

### 2.4 Images

```python
images = driver.list_images()
for img in images:
    print(img.id, img.name, img.extra.get("image_type"), img.extra.get("size_bytes"))
```

### 2.5 Sizes (synthetic presets)

```python
sizes = driver.list_sizes()
for size in sizes:
    print(size.id, size.ram, "MiB RAM", size.extra.get("vcpus"), "vCPUs")
```

### 2.6 Existing VMs

```python
nodes = driver.list_nodes()
for node in nodes:
    print(node.id, node.name, node.state, node.private_ips)

# Filter by name (server-side OData):
nodes = driver.list_nodes(ex_filter="name eq 'web-01'")
```

---

## 3. Compute — VM lifecycle

### 3.1 Create a VM

Minimal example:

```python
from libcloud.compute.base import NodeAuthSSHKey

cluster = driver.list_locations()[0]
size = driver.list_sizes()[1]          # medium
image = driver.list_images()[0]

node = driver.create_node(
    name="app-server-01",
    size=size,
    image=image,
    location=cluster,
    ex_subnet="<subnet-ext-id>",
    ex_storage_container="<storage-container-ext-id>",
)
print(node.id, node.name, node.state)
```

With SSH public key (cloud-init):

```python
auth = NodeAuthSSHKey(name="deploy", pubkey="ssh-rsa AAAA... user@host")

node = driver.create_node(
    name="app-server-02",
    size=size,
    image=image,
    location=cluster,
    ex_subnet="<subnet-ext-id>",
    auth=auth,
)
```

Override sizing:

```python
node = driver.create_node(
    name="app-server-03",
    size=size,
    image=image,
    location=cluster,
    ex_cluster=cluster.id,           # alternative to location=
    ex_vcpus=4,
    ex_memory_mib=8192,
    ex_disk_size_mib=102400,
    ex_description="Production web tier",
    ex_power_on=True,
    ex_wait=True,
    ex_wait_timeout=600,
)
```

### 3.2 Get a single VM

```python
node = driver.ex_get_node("vm-ext-id-uuid")
print(node.state, node.extra.get("power_state"), node.private_ips)
```

### 3.3 Power management

```python
driver.start_node(node)    # POST .../$actions/power-on
driver.stop_node(node)     # POST .../$actions/shutdown
driver.reboot_node(node)   # POST .../$actions/reboot

# Skip task wait:
driver.stop_node(node, ex_wait=False)
```

### 3.4 Destroy a VM

```python
driver.destroy_node(node)
# Returns True on success (waits for task by default)
```

---

## 4. Block storage — volume groups

Nutanix **volume groups** are exposed as Libcloud **`StorageVolume`** objects. Sizes are in **gigabytes**.

### 4.1 List volumes

```python
volumes = driver.list_volumes()
for vol in volumes:
    print(vol.id, vol.name, vol.size, "GB", vol.state)
```

### 4.2 Create a volume

```python
cluster = driver.list_locations()[0]

volume = driver.create_volume(
    size=100,                        # GB
    name="data-vol-01",
    location=cluster,
    ex_storage_container="<storage-container-ext-id>",
    ex_description="Application data disk",
)
print(volume.id, volume.size, volume.extra.get("size_bytes"))
```

Create from an existing snapshot (clone):

```python
snapshots = driver.list_volume_snapshots(existing_volume)
volume = driver.create_volume(
    size=100,
    name="restored-vol",
    location=cluster,
    snapshot=snapshots[0],           # uses recovery point reference
)
```

### 4.3 Get volume details

```python
volume = driver.ex_get_volume("volume-group-ext-id")
print(volume.extra["disks"], volume.extra["vm_attachments"])
```

### 4.4 Attach / detach to VM

```python
# device = SCSI bus index (integer), NOT /dev/sdb
driver.attach_volume(node, volume, device="2")

# Detach (uses stored attachment or single attachment):
driver.detach_volume(volume)

# Multiple attachments — specify VM:
driver.detach_volume(volume, ex_vm_ext_id=node.id)
```

List attachments:

```python
attachments = driver.ex_list_volume_vm_attachments(volume.id)
for att in attachments:
    print(att.get("extId"), att.get("index"))
```

### 4.5 Destroy a volume

```python
driver.destroy_volume(volume)
```

---

## 5. Volume snapshots (recovery points)

Snapshots use the **dataprotection** recovery-point API.

### 5.1 Create snapshot

```python
snapshot = driver.create_volume_snapshot(
    volume,
    name="daily-backup-2024-06-15",
)
print(snapshot.id, snapshot.name, snapshot.state)
```

### 5.2 List snapshots for a volume

```python
snapshots = driver.list_volume_snapshots(volume)
for snap in snapshots:
    print(snap.id, snap.name, snap.created, snap.extra.get("status"))
```

Custom filter:

```python
snapshots = driver.list_volume_snapshots(
    volume,
    ex_filter="name eq 'daily-backup-2024-06-15'",
)
```

### 5.3 Get snapshot details

```python
snapshot = driver.ex_get_volume_snapshot("recovery-point-ext-id", volume=volume)
```

### 5.4 Delete snapshot

```python
driver.destroy_volume_snapshot(snapshot)
```

---

## 6. Images

### 6.1 Get image

```python
image = driver.get_image("image-ext-id")
print(image.name, image.extra.get("image_type"), image.extra.get("size_bytes"))
```

### 6.2 Create image from VM disk

Captures the first VM disk (or use `ex_disk_index` / `ex_disk_ext_id`):

```python
image = driver.create_image(
    node,
    name="golden-web-image",
    description="Baseline after hardening",
    ex_disk_index=0,
)
print(image.id, image.name)
```

Explicit disk ID:

```python
image = driver.create_image(
    node,
    name="data-disk-image",
    ex_disk_ext_id="disk-ext-id-uuid",
)
```

### 6.3 Create image from URL

```python
image = driver.ex_create_image_from_url(
    name="ubuntu-22.04.iso",
    url="https://releases.example.com/ubuntu-22.04-server.iso",
    ex_image_type="ISO_IMAGE",
    ex_allow_insecure_url=False,
)
```

### 6.4 Delete image

```python
driver.delete_image(image)
```

---

## 7. Task inspection

For debugging async operations:

```python
task = driver.ex_get_task("task-ext-id-uuid")
print(task.get("status"), task.get("progressPercentage"))
print(task.get("entitiesAffected"))
print(task.get("completionDetails"))
```

Disable automatic task wait when you want to poll manually:

```python
volume = driver.create_volume(
    size=50,
    name="fast-vol",
    location=cluster,
    ex_wait=False,
)
# volume.extra["task_ext_id"] contains task reference
```

---

## 8. End-to-end examples

### 8.1 Provision VM with data volume

```python
cluster = driver.list_locations()[0]
size = driver.list_sizes()[0]
image = driver.list_images()[0]
subnet_id = driver.ex_list_subnets()[0]["extId"]
container_id = driver.ex_list_storage_containers()[0]["extId"]

node = driver.create_node(
    name="worker-01",
    size=size,
    image=image,
    location=cluster,
    ex_subnet=subnet_id,
    ex_storage_container=container_id,
)

volume = driver.create_volume(
    size=50,
    name="worker-01-data",
    location=cluster,
    ex_storage_container=container_id,
)

driver.attach_volume(node, volume, device="1")
```

### 8.2 Backup volume and restore to new volume

```python
snapshot = driver.create_volume_snapshot(volume, name="pre-upgrade")

new_volume = driver.create_volume(
    size=volume.size,
    name="worker-01-data-restored",
    location=cluster,
    snapshot=snapshot,
    ex_storage_container=container_id,
)
```

### 8.3 Golden image workflow

```python
node = driver.create_node(
    name="image-builder",
    size=size,
    image=image,
    location=cluster,
    ex_subnet=subnet_id,
)

# ... configure VM ...

golden = driver.create_image(node, name="prod-golden-v1")
verified = driver.get_image(golden.id)

driver.destroy_node(node)
```

---

## 9. Pagination and filtering reference

Applicable to most list/`ex_list_*` methods:

```python
driver.list_nodes(
    ex_page=0,
    ex_page_size=50,
    ex_filter="name eq 'web-01'",
    ex_select="extId,name,powerState",
    ex_orderby="name asc",
    ex_limit=10,           # max total records (list_nodes only)
)
```

---

## 10. Error handling

```python
from libcloud.common.types import LibcloudError, InvalidCredsError

try:
    driver.list_nodes()
except InvalidCredsError:
    print("Bad username/password")
except LibcloudError as e:
    print("API error:", e)
```

Common causes:

- Missing `location` / `ex_cluster` on create
- Missing subnet or storage container when PC requires them
- Task timeout (`ex_wait_timeout`) on slow operations
- 409/428 without valid ETag (should be handled by driver)

---

## 11. API coverage checklist

| Category | Method | Implemented |
|----------|--------|:-----------:|
| **Discovery** | `list_locations` | ✅ |
| | `ex_list_clusters` | ✅ |
| | `ex_list_subnets` | ✅ |
| | `ex_list_storage_containers` | ✅ |
| | `list_sizes` | ✅ (synthetic) |
| **Compute** | `list_nodes` | ✅ |
| | `create_node` | ✅ |
| | `destroy_node` | ✅ |
| | `start_node` / `stop_node` / `reboot_node` | ✅ |
| | `ex_get_node` | ✅ |
| **Images** | `list_images` | ✅ |
| | `get_image` | ✅ |
| | `create_image` | ✅ |
| | `delete_image` | ✅ |
| | `ex_create_image_from_url` | ✅ |
| **Volumes** | `list_volumes` | ✅ |
| | `create_volume` | ✅ |
| | `destroy_volume` | ✅ |
| | `attach_volume` / `detach_volume` | ✅ |
| | `ex_get_volume` | ✅ |
| | `ex_list_volume_vm_attachments` | ✅ |
| **Snapshots** | `create_volume_snapshot` | ✅ |
| | `list_volume_snapshots` | ✅ |
| | `destroy_volume_snapshot` | ✅ |
| | `ex_get_volume_snapshot` | ✅ |
| **Tasks** | `ex_get_task` | ✅ |
| **Not implemented** | key pairs, deploy_node, DNS, object storage | ❌ |

---

## 12. Running tests in Docker

```bash
# Unit tests only
cd contrib/docker/nutanix
./run_tests.sh

# Unit + integration (emulator on host:9440)
cd stoplight_mock && docker compose up -d
cd contrib/docker/nutanix
NUTANIX_INTEGRATION_TESTS=1 ./run_tests.sh integration
```

Environment variables for integration:

| Variable | Default |
|----------|---------|
| `NUTANIX_EMULATOR_HOST` | `host.docker.internal` |
| `NUTANIX_EMULATOR_PORT` | `9440` |
| `NUTANIX_EMULATOR_USER` | `admin` |
| `NUTANIX_EMULATOR_PASSWORD` | `password` |
| `NUTANIX_INTEGRATION_TESTS` | `1` to enable |

---

## 13. Related files

| File | Purpose |
|------|---------|
| `libcloud/compute/drivers/nutanix.py` | Driver implementation |
| `libcloud/common/nutanix.py` | Connection & helpers |
| `contrib/docker/nutanix/NUTANIX_LIBCLOUD_CONCEPTUAL_GUIDE.md` | Architecture & mapping |
| `docs/compute/drivers/nutanix.rst` | Sphinx documentation entry |
