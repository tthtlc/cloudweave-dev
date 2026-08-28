# Architecture — Vendored Apache libcloud + Nutanix Prism Central v4 Driver

This document describes the vendored Apache libcloud tree under `libcloud/` and
the custom driver it carries for Nutanix Prism Central v4. It supersedes the
previous `ARCHITECTURE.md`, which was a bare `def <method>(...)` dump with no
prose and which silently omitted several methods. All line numbers refer to the
files as they exist at the time of writing.

---

## 1. What this tree is

`libcloud/` is a vendored fork of Apache libcloud. The fork's only meaningful
change for this repo is the addition of a Nutanix Prism Central **v4** compute
driver plus its supporting connection layer:

| File | Role |
|------|------|
| `libcloud/libcloud/common/nutanix.py` | `NutanixConnection`, `NutanixResponse`, path/payload helpers |
| `libcloud/libcloud/compute/drivers/nutanix.py` | `NutanixNodeDriver` (the registered, cookie-capable variant) |
| `libcloud/libcloud/compute/drivers/nutanix_no_cookie.py` | `NutanixNodeDriver` (unregistered, Basic-auth-only variant) |
| `libcloud/libcloud/compute/providers.py:110` | driver registration |

Registration is a normal libcloud provider-table entry
(`libcloud/compute/providers.py:110`):

```python
Provider.NUTANIX: ("libcloud.compute.drivers.nutanix", "NutanixNodeDriver"),
```

The registered module is `...drivers.nutanix` (not `nutanix_no_cookie`), so
`get_driver(Provider.NUTANIX)` returns the **cookie-capable** class. The driver
sets `type = Provider.NUTANIX` and `connectionCls = NutanixConnection`
(`compute/drivers/nutanix.py:93-97`).

---

## 2. Connection and authentication

`NutanixConnection` is a `ConnectionUserAndKey` subclass
(`common/nutanix.py:139`). Class-level defaults:

| Attribute | Default | Source |
|-----------|---------|--------|
| `host` | `"localhost"` | `common/nutanix.py:157` |
| `port` | `9440` | `common/nutanix.py:158` |
| `responseCls` | `NutanixResponse` | `common/nutanix.py:159` |
| `login_path` | `None` | `common/nutanix.py:164` |

`login_path` is the opt-in switch between two authentication modes.

### 2.1 Mode (a) — per-request HTTP Basic (default)

When `login_path` is `None`, every request is authenticated with a fresh
`Authorization: Basic` header. `add_default_headers`
(`common/nutanix.py:259-271`) sets:

- `Accept: application/json`
- `Content-Type: application/json`
- `NTNX-Request-Id` — a fresh UUID from `new_request_id()` (which is literally
  `str(uuid.uuid4())`, `common/nutanix.py:398-399`)
- `Authorization: Basic base64(user_id:key)` — built by `_basic_auth_header`
  (`common/nutanix.py:203-207`)

`key` is the Prism Central username and `secret` the password (libcloud's
conventional `user_id`/`key` pairing).

### 2.2 Mode (b) — session cookie (opt-in)

When `login_path` is set, `_get_auth_token` (`common/nutanix.py:218-257`) POSTs
`login_path` with the Basic auth headers and an empty body, reads the
`Set-Cookie` response header, and caches it as `self.session_cookie`. Later
requests then send `Cookie:` instead of `Authorization`
(`common/nutanix.py:264-267`). This mirrors `VCloudConnection._get_auth_token`
and lets the caller stop re-fetching the Nutanix username/password (e.g. from
Vault) on every call — the cookie becomes the credential carrier after the
first login.

`login_path` is injected on the connection by the driver in `__init__` when the
driver was constructed with `login_path` (`compute/drivers/nutanix.py:159-160`),
and `session_cookie` can be pre-seeded the same way
(`compute/drivers/nutanix.py:161-162`).

### 2.3 Login fallback and failure

- If the login endpoint returns a cookie, it is cached and returned
  (`common/nutanix.py:240-243`).
- If it returns `401`/`403`, `_get_auth_token` raises `InvalidCredsError`
  (`common/nutanix.py:246-251`).
- If it returns anything else with **no** `Set-Cookie` header, `login_path` is
  permanently set to `None` and the connection reverts to per-request Basic
  auth instead of failing every request (`common/nutanix.py:253-257`).

`_get_auth_token` is invoked from the head of `request()`
(`common/nutanix.py:273-277`), so a login attempt (or a cheap cached no-op)
precedes every request.

---

## 3. No automatic re-auth (known gap)

`_get_auth_token` is guarded by:

```python
if self.session_cookie or not self.login_path:
    return
```

(`common/nutanix.py:226`). Once a cookie is cached it is never refreshed and
there is no 401-retry path — a later `401` simply propagates as
`InvalidCredsError` from `NutanixResponse.parse_error`
(`common/nutanix.py:100-101`).

The REST layer adds an in-process cache on top of this:
`libcloud.rest/app/connections/session_cache.py` keys a `dict` by
`nutanix:<host>:<port>` with a 3600s TTL and a `threading.Lock`
(`session_cache.py:21-27`). Its module docstring claims that a later 401
"surfaces to the caller; the next request will re-authenticate"
(`session_cache.py:11-14`) — but that re-authentication is the REST layer's
responsibility, **not** the driver's: the driver never auto-re-auths once a
cookie is cached. Treat this as a known gap: the cookie-carrying connection has
no self-healing path after the session expires or is revoked.

---

## 4. Two known defects in the cookie flow

Both are real bugs that only pass against the emulator (which never validates
cookies).

### 4.1 Set-Cookie is replayed verbatim as a Cookie header

`_get_auth_token` stores the **entire** `Set-Cookie` header value, e.g.
`NTNX_IAM_SESSION=xyz; Path=/; HttpOnly`, in `self.session_cookie`
(`common/nutanix.py:240-242`), and `add_default_headers` replays it verbatim as
the `Cookie` request header (`common/nutanix.py:264-267`). A `Cookie` request
header must carry only `name=value` pairs — the `Path=`/`HttpOnly` attributes
are response-only directives and are malformed there. The unit test
`test_login_path_derives_cookie_from_set_cookie` actually asserts this exact
behaviour (`test_nutanix.py:578-608`), confirming it is the intended code, but
it is wrong against a real Prism Central.

### 4.2 The cookie name and login path are not real Prism

The cookie name in play is `NTNX_IAM_SESSION` (from the emulator), not Prism
Central's real gateway cookie `NTNX_IGW_SESSION`, and
`/api/nutanix/v1/session` is not a real Prism endpoint. The driver documents
this indirectly in `_get_auth_token`'s fallback comment, which notes that "real
Prism Central v4 ... authenticates per-request with Basic auth and has no REST
session endpoint" (`common/nutanix.py:253-256`). The cookie flow is therefore
an emulator-only convenience; against production Prism Central the correct path
is per-request Basic auth.

---

## 5. TLS verification

`verify_ssl_cert` defaults to `True` in both the driver
(`compute/drivers/nutanix.py:134`) and the connection
(`common/nutanix.py:179`), but the connection's copy is **vestigial**: it is
assigned to `self.verify_ssl_cert` (`common/nutanix.py:198`) and never read
again.

The real control lives in the driver's `__init__`:

```python
if not self.verify_ssl_cert:
    self.connection.connection.ca_cert = False
```

(`compute/drivers/nutanix.py:163-164`). This works because the underlying HTTP
layer passes `ca_cert` into `requests`' `verify` argument: `http.py` exposes a
`verification` property that returns `ca_cert if ca_cert is not None else
verify` (`http.py:213-218`) and `request()` passes it as `verify=self.verification`
(`http.py:231`).

Because the emulator uses a self-signed certificate, tests and scripts routinely
disable verification: the test harness constructs the driver with
`verify_ssl_cert=False` (`test_nutanix.py:59`), and the mock's curl scripts use
`--insecure` (`stoplight_mock/scripts/myrun.sh:24`).

---

## 6. Request shape and path helpers

Paths are composed by `api_path(namespace, api_version, resource_path)`, which
returns `/api/<namespace>/<api_version>/<resource>` (`common/nutanix.py:365-367`),
with per-namespace wrappers (`common/nutanix.py:370-395`):

| Helper | Namespace | Example |
|--------|-----------|---------|
| `vmm_path` | `vmm` | `/api/vmm/v4.0/ahv/config/vms` |
| `clustermgmt_path` | `clustermgmt` | `/api/clustermgmt/v4.0/config/clusters` |
| `networking_path` | `networking` | `/api/networking/v4.0/config/subnets` |
| `microseg_path` | `microseg` | `/api/microseg/v4.0/config/policies` |
| `prism_path` | `prism` | `/api/prism/v4.0/config/tasks/{id}` |
| `volumes_path` | `volumes` | `/api/volumes/v4.0/config/volume-groups` |
| `dataprotection_path` | `dataprotection` | `/api/dataprotection/v4.0/config/recovery-points` |

List requests are paged by `_paged_request` (`common/nutanix.py:289-327`): it
clamps `$limit` to `[1, MAX_PAGE_SIZE]` (100, `common/nutanix.py:74-76`) and
walks `$page` until a page returns fewer than `$limit` items. Optional
`$filter`/`$select`/`$orderby` come from `_build_list_params`
(`compute/drivers/nutanix.py:1211-1219`) via `ex_filter`/`ex_select`/`ex_orderby`
kwargs.

---

## 7. Async task model

Writes (create/update/delete/actions) return `202` with a `TaskReference`
whose `extId` is the task UUID (`extract_task_ext_id`,
`common/nutanix.py:757-761`). Unless `ex_wait=False`, `_wait_for_task`
(`common/nutanix.py:329-355`) polls
`GET /api/prism/<ver>/config/tasks/{id}` with a 600s timeout and a 2.0s
interval until status is `SUCCEEDED`. On a terminal failure it raises
`LibcloudError` carrying the task's `errorMessages`; an unrecognised
non-pending status ends the poll without error. After success the created
entity's `extId` is read from `entitiesAffected`
(`extract_entity_ext_id_from_task`, `common/nutanix.py:771-778`).

---

## 8. Optimistic concurrency (read-ETag-then-If-Match)

Mutations that need conditional writes follow a read-ETag-then-`If-Match`
pattern: GET the resource, then `extract_etag` strips surrounding quotes from
the `ETag` header (case-insensitive match, `common/nutanix.py:764-768`), then
PUT/DELETE/action with `If-Match: <etag>`. When no ETag is present the header
is simply omitted (`headers = {"If-Match": etag} if etag else {}`).

Used by:

| Operation | Method | Source |
|-----------|--------|--------|
| `ex_update_node` | `PUT .../vms/{extId}` | `compute/drivers/nutanix.py:432-441` |
| `destroy_node` | `DELETE .../vms/{extId}` | `compute/drivers/nutanix.py:382-394` |
| power actions | `POST .../vms/{extId}/$actions/{action}` | `compute/drivers/nutanix.py:1103-1117` |
| `destroy_volume` | `DELETE .../volume-groups/{extId}` | `compute/drivers/nutanix.py:919-921` |
| `destroy_volume_snapshot` | `DELETE .../recovery-points/{extId}` | `compute/drivers/nutanix.py:1044-1046` |
| `delete_image` | `DELETE .../content/images/{extId}` | `compute/drivers/nutanix.py:263-267` (etag via `_get_image_etag`, `:1143-1147`) |

The dedicated `_get_*_etag` helpers are `_get_vm_etag` (`:1119`),
`_get_volume_group_etag` (`:1125`), `_get_recovery_point_etag` (`:1134`), and
`_get_image_etag` (`:1143`).

**Testing caveat:** the stoplight emulator does not return `ETag` headers, so in
practice every `_get_*_etag` call returns `None` there and the `If-Match` branch
is effectively untested against the emulator. Only the unit tests exercise the
header-present path (e.g. `test_delete_image`, `test_destroy_volume`,
`test_start_stop_reboot_destroy`, which inject `{"ETag": ...}` explicitly).

---

## 9. Representative flows (real paths)

| Flow | Request | Notes |
|------|---------|-------|
| List VMs | `GET /api/vmm/<ver>/ahv/config/vms` | `list_nodes`, `compute/drivers/nutanix.py:178-199` |
| Create VM | `POST /api/vmm/<ver>/ahv/config/vms` | `create_node`, body from `build_vm_create_payload` |
| Update VM | `PUT .../vms/{extId}` (If-Match) | `ex_update_node` |
| Delete VM | `DELETE .../vms/{extId}` (If-Match) | `destroy_node` |
| Power on | `POST .../vms/{extId}/$actions/power-on` | `start_node` → `_vm_power_action` |
| Shutdown | `POST .../vms/{extId}/$actions/shutdown` | `stop_node` |
| Reboot | `POST .../vms/{extId}/$actions/reboot` | `reboot_node` |

`build_vm_create_payload` (`common/nutanix.py:441-559`) emits camelCase v4
fields: `name`, `cluster.extId`, `numSockets`, `numCoresPerSocket`,
`memorySizeBytes` (converted from MiB via `mib_to_bytes`), `powerState` (`ON`/
`OFF`), `disks[].backingInfo` (flat `VmDisk` fields with no `vmDisk` wrapper),
and `guestCustomization.config.cloudInitScript` (base64 `value` plus
`datasourceType=CONFIG_DRIVE_V2`). NICs use `nics[].networkInfo` on v4.0-v4.2
and `nics[].nicNetworkInfo` (with the `$objectType` discriminator
`vmm.v4.ahv.config.VirtualEthernetNicNetworkInfo`) on v4.3 — see the version
branch at `common/nutanix.py:529-533`.

---

## 10. `nutanix.py` vs `nutanix_no_cookie.py`

A `diff` of the two files confirms they are otherwise identical; the only
differences are in `nutanix.py`:

1. The `login_path`/`session_cookie` keyword documentation in the class
   docstring (`compute/drivers/nutanix.py:82-90`).
2. The `login_path=None, session_cookie=None` kwargs on `__init__`
   (`compute/drivers/nutanix.py:135-136`).
3. The block forwarding those values onto the connection
   (`compute/drivers/nutanix.py:158-162`).
4. The `ex_authenticate()` method (`compute/drivers/nutanix.py:165-176`).

Both classes are named `NutanixNodeDriver` and share `connectionCls =
NutanixConnection`. Only `nutanix.py` is registered (`compute/providers.py:110`);
`nutanix_no_cookie.py` is an unregistered alternate that can only ever use
per-request Basic auth because it never forwards `login_path`/`session_cookie`
to the connection.

`ex_authenticate()` (`compute/drivers/nutanix.py:166-176`) is the public hook
the REST layer uses to derive (and then persist) a session cookie: it calls
`connection._get_auth_token()` and returns `connection.session_cookie`, or
`None` in Basic-auth mode.

---

## 11. Method inventory

Generated from the actual sources (replaces the old stale list, which omitted at
least `ex_list_hosts`, `ex_get_host`, `ex_get_host_bmc_info`, `ex_authenticate`,
and `_get_image_etag`).

### 11.1 `NutanixNodeDriver` (`compute/drivers/nutanix.py`)

| Area | Methods |
|------|---------|
| Construction / auth | `__init__` (:126), `ex_authenticate` (:166) |
| Nodes | `list_nodes` (:178), `create_node` (:301), `destroy_node` (:382), `reboot_node` (:396), `start_node` (:399), `stop_node` (:402), `ex_get_node` (:405), `ex_update_node` (:413), `ex_get_task` (:444), `_vm_power_action` (:1103), `_to_node` (:1221) |
| Images | `list_images` (:201), `get_image` (:212), `create_image` (:220), `ex_create_image_from_url` (:247), `delete_image` (:263), `ex_list_templates` (:718), `_create_image_resource` (:1149), `_get_image_etag` (:1143), `_to_image` (:1267) |
| Sizes / locations / hosts | `list_sizes` (:276), `list_locations` (:298), `ex_list_clusters` (:452), `ex_list_hosts` (:463), `ex_get_host` (:489), `ex_get_host_bmc_info` (:511), `ex_list_storage_containers` (:686), `ex_get_storage_container` (:696), `ex_list_storage_containers_vmm` (:710), `ex_get_storage_container_vmm` (:714), `_to_location` (:1287), `_to_host` (:1304), `_to_bmc_info` (:1347) |
| Volumes | `list_volumes` (:851), `create_volume` (:862), `destroy_volume` (:914), `attach_volume` (:930), `detach_volume` (:959), `ex_get_volume` (:1055), `_list_volume_disks` (:1195), `_get_volume_group_etag` (:1125), `_to_volume` (:1361) |
| Snapshots / recovery points | `create_volume_snapshot` (:990), `list_volume_snapshots` (:1022), `destroy_volume_snapshot` (:1039), `ex_get_volume_snapshot` (:1065), `_get_recovery_point_etag` (:1134), `_to_volume_snapshot` (:1421) |
| Networking | `ex_list_subnets` (:536), `ex_get_subnet` (:546), `ex_create_subnet` (:554), `ex_update_subnet` (:595), `ex_delete_subnet` (:615), `ex_list_vpcs` (:620), `ex_get_vpc` (:630), `ex_create_vpc` (:638), `ex_update_vpc` (:663), `ex_delete_vpc` (:681), `ex_list_load_balancers` (:790), `ex_get_load_balancer` (:801), `ex_create_load_balancer` (:815), `ex_delete_load_balancer` (:843), `ex_list_volume_vm_attachments` (:1079) |
| Security groups (microseg) | `ex_list_security_groups` (:728), `ex_get_security_group` (:738), `ex_create_security_group` (:752), `ex_delete_security_group` (:782) |
| Shared helpers | `_execute_async_mutation` (:1092), `_get_vm_etag` (:1119), `_build_list_params` (:1211), `_list_volume_vm_attachments` (:1208) |

**Key pairs:** there are no dedicated key-pair CRUD methods. SSH key injection
is supported via the libcloud `create_node` feature flag
(`features = {"create_node": ["ssh_key"]}`, `:98`): when `auth` carries a
`pubkey`, `create_node` writes a `#cloud-config` `ssh_authorized_keys` stanza
into `guestCustomization.config.cloudInitScript` (`:324-330`).

### 11.2 `NutanixConnection` + module helpers (`common/nutanix.py`)

| Area | Members |
|------|---------|
| Response / connection | `NutanixResponse` (:90), `NutanixConnection` (:139) |
| Auth internals | `_basic_auth_header` (:203), `_get_auth_headers` (:209), `_get_auth_token` (:218), `add_default_headers` (:259) |
| Request / task plumbing | `request` (:273), `_request` (:279), `_paged_request` (:289), `_wait_for_task` (:329), `encode_data` (:357) |
| Path helpers | `api_path` (:365), `vmm_path` (:370), `clustermgmt_path` (:374), `networking_path` (:378), `microseg_path` (:382), `prism_path` (:386), `volumes_path` (:390), `dataprotection_path` (:394) |
| Misc helpers | `new_request_id` (:398), `extract_ips_from_nics` (:402), `mib_to_bytes` (:425), `bytes_to_mib` (:429), `gib_to_bytes` (:433), `bytes_to_gib` (:437) |
| Payload builders | `build_vm_create_payload` (:441), `build_volume_group_create_payload` (:562), `build_recovery_point_create_payload` (:590), `build_image_url_source` (:601), `build_image_vm_disk_source` (:612), `build_vpc_create_payload` (:619), `build_subnet_create_payload` (:638), `build_image_create_payload` (:713) |
| Extractors | `extract_vm_disk_ext_id` (:735), `extract_task_ext_id` (:757), `extract_etag` (:764), `extract_entity_ext_id_from_task` (:771), `extract_task_completion_detail` (:781) |

---

## 12. Testing

- **Unit tests:** `libcloud/libcloud/test/compute/test_nutanix.py`, with JSON
  fixtures under `libcloud/libcloud/test/compute/fixtures/nutanix/`. Two test
  classes: `NutanixNodeDriverTests` (payload shapes, state/IP mapping, task
  polling, volume/snapshot flows) and `NutanixSessionAuthTests` (Basic-vs-cookie
  header selection, `Set-Cookie` capture, 401 rejection, and the no-cookie →
  Basic fallback). Auth/cookie/etag behaviour is exercised by injecting
  `MagicMock` responses with explicit `headers={"ETag": ...}` /
  `headers={"set-cookie": ...}`.

- **Schema-parity validator:**
  `libcloud/scripts/validate_nutanix_schema_parity.py`. It is a **field-presence
  check, not full JSON-Schema validation** (`validate_nutanix_schema_parity.py:23-29`).
  For each version v4.0-v4.3 it loads the corresponding `nutanix_swagger/` spec
  (`swagger-<ns>-<version>-all.yaml`), runs the payload builders
  (`build_vm_create_payload`, `build_image_create_payload`,
  `build_volume_group_create_payload`, `build_subnet_create_payload`,
  `build_vpc_create_payload`, `build_recovery_point_create_payload`), flattens
  the request schema (`$ref` + `allOf` resolution), and asserts that every key
  the driver emits is a real schema property. It specifically guards the shapes
  this driver cares about: flat `backingInfo` (no `vmDisk` wrapper),
  `config.cloudInitScript` (not `cloudInit.userData`), and the v4.3
  `nicNetworkInfo` rename (`validate_nutanix_schema_parity.py:134-187`).
  Recovery-point checks run only for v4.1-v4.3 (the spec does not exist for
  v4.0).

---

## 13. REST-layer integration (how the driver is built)

The repo's REST service does not construct the driver directly; it goes through
`libcloud.rest/app/providers/nutanix.py:create_nutanix_driver`, which maps a
`ConnectionConfig` onto `NutanixNodeDriver(...)` kwargs — host, port, secure,
`api_version`, `verify_ssl_cert`, and the optional `login_path`/`session_cookie`
(`libcloud.rest/app/providers/nutanix.py:14-24`). The session cookie it passes
in is looked up from the in-process cache in
`libcloud.rest/app/connections/session_cache.py` (see section 3).
