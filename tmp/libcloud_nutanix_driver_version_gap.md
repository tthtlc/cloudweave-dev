# Libcloud Nutanix driver — v4.0 vs v4.1/v4.2/v4.3 gap analysis

Generated against the OpenAPI specs in `./nutanix_swagger` and the driver code in
`libcloud/libcloud/compute/drivers/nutanix.py` + `libcloud/libcloud/common/nutanix.py`.

## Headline

1. The driver is a **single hand-written v4.0 implementation** with one
   `api_version` string interpolated into every URL. It is **not generated from,
   nor validated against, the specs in `./nutanix_swagger`** (those feed the
   `stoplight_mock` emulator only).
2. The **only path-level incompatibility** is that two namespaces the driver uses
   — `microseg` (security groups) and `dataprotection` (volume snapshots) — **do
   not exist at v4.0**. They are v4.1+ only. So the driver's `v4.0` default is
   already broken for those feature areas.
3. Every other route, and every field the driver *emits* in its create/update
   payloads, is **present and unchanged across v4.0 → v4.3**. All per-version
   schema changes are **additive** (new optional fields), so pointing
   `api_version` at `v4.1`/`v4.2`/`v4.3` is largely safe for the
   vmm/networking/clustermgmt/volumes surfaces.
4. Independent of version, the driver's VM-disk payload shape does **not** match
   the spec's discriminated-`oneOf` shape (see §4) — a latent correctness issue,
   not a version delta.

---

## 1. Method → namespace → version availability

`ok` = the exact route exists in that version's spec. `NO-NS` = the namespace
does not exist at all in that version.

| Driver method(s) | Namespace / route | v4.0 | v4.1 | v4.2 | v4.3 |
|---|---|---|---|---|---|
| `list_nodes`, `create_node`, `destroy_node`, `ex_get_node`, `ex_update_node`, `reboot/start/stop_node` | `vmm` `ahv/config/vms` (+ `$actions/power-on|shutdown|reboot`) | ok | ok | ok | ok |
| `list_images`, `get_image`, `create_image`, `delete_image` | `vmm` `content/images` | ok | ok | ok | ok |
| `ex_list_templates` | `vmm` `content/templates` | ok | ok | ok | ok |
| `list_locations`, `ex_list_clusters` | `clustermgmt` `config/clusters` | ok | ok | ok | ok |
| `ex_list_storage_containers`, `ex_get_storage_container` | `clustermgmt` `config/storage-containers` | ok | ok | ok | ok |
| `ex_list/get/create/update/delete_subnet` | `networking` `config/subnets` | ok | ok | ok | ok |
| `ex_list/get/create/update/delete_vpc` | `networking` `config/vpcs` | ok | ok | ok | ok |
| `ex_list/get/create/delete_load_balancer` | `networking` `config/floating-ips` | ok | ok | ok | ok |
| `ex_get_task` | `prism` `config/tasks/{id}` | ok | ok | ok | ok |
| `list_volumes`, `create_volume`, `destroy_volume`, `attach_volume`, `detach_volume`, `ex_get_volume`, `ex_list_volume_vm_attachments` | `volumes` `config/volume-groups` (+ `$actions/attach-vm|detach-vm`, `/disks`, `/vm-attachments`) | ok | ok | ok | ok |
| `ex_list/get/create/delete_security_group` | `microseg` `config/policies` | **NO-NS** | ok | ok | ok |
| `create_volume_snapshot`, `list_volume_snapshots`, `destroy_volume_snapshot`, `ex_get_volume_snapshot` | `dataprotection` `config/recovery-points` | **NO-NS** | ok | ok | ok |

`list_sizes` is synthetic (no API call).

Consequence: with the default `api_version="v4.0"`, the **security-group** and
**volume-snapshot** methods construct `/api/microseg/v4.0/...` and
`/api/dataprotection/v4.0/...`, which 404 on a true v4.0 Prism Central.

---

## 2. Per-version payload deltas (top-level create/update schemas)

All changes are **additive** unless noted. Nothing the driver emits is removed.

### VM create — `POST /vmm/{v}/ahv/config/vms` (`required=[]` at schema level)

| Version | New top-level fields |
|---|---|
| v4.1 | `project` |
| v4.2 | `customAttributes`, `vmGuestCustomizationStatus` |
| v4.3 | `nextScheduledReboot`, `projectExtId`, `sourceVmProfile` |

Driver emits `name, cluster, numSockets, numCoresPerSocket, memorySizeBytes,
powerState, description, categories, disks, nics, guestCustomization` — all
present in every version.

### Image create — `POST /vmm/{v}/content/images` (`required=[name, type]`)

| Version | New top-level fields |
|---|---|
| v4.2 | `ownerName` |
| v4.3 | `contentRepositoryExtId`, `contentRepositoryName`, `isSharedWithAllProjects`, `projectExtId` |

Driver emits `name, type, source, description, clusterLocationExtIds,
categoryExtIds` — stable.

### Volume group create — `POST /volumes/{v}/config/volume-groups`

| Version | Delta |
|---|---|
| v4.1 | +`attachments` |
| v4.2 | +`hydrationStatus` |
| v4.3 | +`projectExtId`, **−`enabledAuthentications`** (not emitted by driver) |

Driver emits `name, clusterReference, disks, description` — stable.

### Subnet create — `POST /networking/{v}/config/subnets` (`required=[name, subnetType]`)

| Version | New top-level fields |
|---|---|
| v4.1 | `clusterNameList`, `clusterReferenceList`, `externalDhcpServers` |
| v4.2 | `layer2StretchReference` |

Driver emits `name, subnetType, isExternal, description, clusterReference,
vpcReference, networkId, ipConfig` — stable (note: uses singular
`clusterReference`, which is valid in all versions).

### VPC create — `POST /networking/{v}/config/vpcs` (`required=[name]`)

| Version | New top-level fields |
|---|---|
| v4.2 | `kubernetesClusters` |

Driver emits `name, vpcType, description, externalSubnets` — stable.

### Floating IP create — `POST /networking/{v}/config/floating-ips` (`required=[name]`)

No changes across v4.0–v4.3 (identical property set). Driver emits `name,
vpcReference, floatingIp` — stable.

### Security policy create — `POST /microseg/{v}/config/policies` (`required=[name, type]`, v4.1+ only)

| Version | New top-level fields |
|---|---|
| v4.2 | `isIpv4AddressScope`, `isIpv6AddressScope` |
| v4.3 | `appliedToEntityGroupReferences`, `destinationEntityGroupReferences`, `sourceEntityGroupReferences`, `isSharedWithAllProjects`, `priority`, `projectExtId` |

Driver emits `name, type, state, description, vpcReferences, rules` — present in
all v4.1–v4.3.

### Recovery point create — `POST /dataprotection/{v}/config/recovery-points` (v4.1+ only)

| Version | New top-level fields |
|---|---|
| v4.2 | `sourceLocation`, `totalExclusiveUsageBytes` |

Driver emits `name, volumeGroupRecoveryPoints[].volumeGroupExtId` — stable.

### attach-vm / detach-vm — `POST /volumes/{v}/config/volume-groups/{id}/$actions/*`

`required=[extId]`, props `[extId, index]` — identical in all four versions.
Driver emits `{extId, index}` — correct.

---

## 3. Nested fields the driver emits — all stable across versions

Verified identical presence in v4.0/v4.1/v4.2/v4.3:

- VM disk: `disks[].diskAddress.busType/index`, `diskSizeBytes`,
  `dataSource.reference.imageExtId` (`ImageReference.imageExtId` present in all;
  v4.3 adds optional `storageCluster`), `storageContainer.extId`.
- VM NIC: `nics[].networkInfo.subnet.extId`, `ipv4Config.ipAddress.value`,
  `ipv4Config.ipAddress.prefixLength`, `ipv4Config.shouldAssignIp` — all present
  in every version. **But** the `networkInfo` field itself is **deprecated in
  v4.3** in favour of `nicNetworkInfo` (see §4.1); the inner shape is unchanged.
- Image source: `source.url` (required), `source.shouldAllowInsecureUrl`,
  `source.basicAuth`, discriminator `$objectType: vmm.v4.content.UrlSource`
  (all present; v4.1+ also add `OvaUrlSource`, v4.3 adds
  `ObjectsLiteSource`/`OvaVmSource`).
- Subnet `ipConfig[].ipv4`: `ipSubnet.ip.value`, `ipSubnet.prefixLength`,
  `defaultGatewayIp.value`, `poolList[].startIp/endIp.value`,
  `dhcpServerAddress.value` — all present in all networking versions.
- Volume group: `disks[].storageContainerId`, `disks[].diskDataSourceReference`,
  `clusterReference`.
- Recovery point: `volumeGroupRecoveryPoints[].volumeGroupExtId`.

---

## 4. Confirmed payload bugs (version-independent — wrong for v4.0–v4.3 alike)

These were validated against the spec **and** Nutanix's official v4 Python SDK
(`nutanixdev/code-samples` → `python/v4api_sdk/create_vm.py`). Two defects in
`build_vm_create_payload` (+ the SSH-key path in `compute/drivers/nutanix.py`).

### 4.0 `backingInfo` has a `vmDisk` wrapper key that does not exist

The spec's `Disk.backingInfo` is a flat `oneOf [VmDisk, ADSFVolumeGroupReference]`
(no `vmDisk` key anywhere in any version; `Disk.backingInfo` is never deprecated).
The official SDK does `Disk(backing_info=VmDisk(...))` — flat.

```python
# driver (common/nutanix.py:403, 408, 423) — WRONG
disks.append({"backingInfo": {"vmDisk": vm_disk}})

# spec + SDK — CORRECT
disks.append({"backingInfo": vm_disk})   # diskSizeBytes / dataSource / storageContainer sit flat
```

`dataSource.reference.imageExtId` and `storageContainer.extId` are already
correct; only the wrapper key is wrong. Do **not** add `$objectType` — the spec
marks it `required`, but the official SDK omits it and the API infers the type.

### 4.1 `guestCustomization` uses the wrong shape

Spec: `GuestCustomizationParams = {config}`, `CloudInit = {datasourceType,
metadata, cloudInitScript}`, `cloudInitScript = Userdata{value}`.

```python
# driver (common/nutanix.py:456-462; compute/drivers/nutanix.py:296-299) — WRONG
{"guestCustomization": {"cloudInit": {"userData": "#cloud-config\n..."}}}

# spec + SDK — CORRECT (value is base64-encoded)
{"guestCustomization": {"config": {"cloudInitScript": {"value": "<b64>"}, "datasourceType": "CONFIG_DRIVE_V2"}}}
```

## 4.2 Version-specific delta: NIC `networkInfo` → `nicNetworkInfo` (v4.3)

`Nic.networkInfo` (`NicNetworkInfo`) is valid v4.0–v4.2, but is **marked
`deprecated: true` in v4.3**, replaced by `nicNetworkInfo`. The inner shape
(`subnet.extId`, `ipv4Config.*`) is identical. Same for NIC `backingInfo` →
`nicBackingInfo` (the driver never emits NIC `backingInfo`, so irrelevant).

For full v4.3 conformance the driver should emit `nicNetworkInfo` instead of
`networkInfo` when `api_version == "v4.3"`.

Other minor deltas (non-breaking):
- `ImageReference.imageExtId` becomes **required** in v4.1+ (optional in v4.0).
- Additive optional fields: VmDisk `vmDiskHydrationInfo` (v4.2), `serialId` /
  `externalStorageInfo` (v4.3); Disk `customAttributes` (v4.2); ImageReference
  `storageCluster` (v4.2).

---

## 5. What "actually catering to" v4.1–v4.3 would require

1. **A version → namespace capability map.** Guard `microseg`/`dataprotection`
   behind `v4.1+` (they silently 404 at v4.0 today), and treat the `storage`
   namespace's real version (`v4.0.a3`) distinctly from bare `v4.0`.
2. **Per-version payload builders**, if you want to emit the *new* fields
   (project, customAttributes, sourceVmProfile, etc.) rather than just survive
   their absence.
3. **Exposure of the v4.1+ namespaces the driver ignores entirely**: `lifecycle`,
   `monitoring`, `licensing`, `security`, `datapolicies`, `objects`,
   `multidomain`, microseg `address-groups`.
4. **Fix the two confirmed payload bugs** (§4: drop the `vmDisk` wrapper; fix
   `guestCustomization` shape) and, for v4.3, emit `nicNetworkInfo` in place of
   the deprecated `networkInfo`. Then validate each payload builder against every
   version's schema (add a fixture-based parity test per version).
5. **Real-world version strings**: Nutanix PCs carry minor/patch suffixes
   (`v4.0.a3`, `v4.0.b1`, `v4.0.b2`). The driver hard-codes a bare `"v4.0"`;
   decide whether to accept the full string or resolve an alias.
