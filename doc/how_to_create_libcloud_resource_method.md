# How to Create / Modify / Deprecate a libcloud Resource Method (compute / network / storage)

This guide covers adding a **new resource method** to an **existing** libcloud
driver in `../libcloud` — e.g. a new `ex_*` Nutanix operation, a new EC2
helper, or a new storage operation — and surfacing it through the libcloud
REST API. It is the per-resource counterpart to
[how_to_create_libcloud_cloud_driver.md](how_to_create_libcloud_cloud_driver.md)
(which adds a whole new cloud).

> **What a resource method is here.** A method on a libcloud driver that
> performs one operation against one resource type. The Nutanix compute
> driver exposes the full set: `list_nodes`, `create_node`, `destroy_node`,
> `reboot_node`, `start_node`, `stop_node`, `ex_get_node`, `ex_update_node`,
> `ex_list_subnets`, `ex_create_subnet`, `ex_update_subnet`,
> `ex_delete_subnet`, `ex_list_vpcs`, `ex_create_vpc`, `ex_update_vpc`,
> `ex_delete_vpc`, `ex_list_storage_containers`, `ex_list_templates`,
> `ex_list_security_groups`, `ex_create_security_group`,
> `ex_delete_security_group`, `ex_list_load_balancers`,
> `ex_create_load_balancer`, `ex_delete_load_balancer`, `list_volumes`,
> `create_volume`, `destroy_volume`, `attach_volume`, `detach_volume`,
> `create_volume_snapshot`, `list_volume_snapshots`,
> `destroy_volume_snapshot`, `ex_get_volume`, `ex_get_volume_snapshot`,
> `ex_list_volume_vm_attachments`, `ex_get_task`, `ex_list_clusters`,
> `list_images`, `get_image`, `create_image`,
> `ex_create_image_from_url`, `delete_image`, `list_sizes`,
> `list_locations`. (Full list in `libcloud/compute/drivers/nutanix.py`.)

---

## 0. The three hops a new method touches

```
REST URL (routes.py)  →  ComputeService / NetworkService method  →  libcloud driver method  →  cloud API
```

So "add a resource method" usually means **three** edits:
1. the **libcloud driver** method (`libcloud/compute/drivers/<cloud>.py` and
   maybe a payload builder in `libcloud/common/<cloud>.py`);
2. the **libcloud.rest service** method that calls it
   (`app/compute/service.py` or `app/network/service.py` or
   `app/storage/service.py`);
3. the **libcloud.rest route** that exposes it — see
   [how_to_create_libcloud_rest_endpoint.md](how_to_create_libcloud_rest_endpoint.md).

This guide focuses on step 1; steps 2–3 are cross-linked.

---

## 1. Prerequisites

- `../libcloud` is checked out and the driver you are extending exists.
- You know the cloud API path + request/response shape for the operation.
- For mutating Nutanix calls: you understand the async task pattern
  (`_execute_async_mutation` + task polling).

---

## 2. ADD a resource method (example: `ex_list_volume_groups` on Nutanix)

### Step 1 — Add a path / payload builder if needed

`libcloud/common/nutanix.py`:

```python
def volumes_path(api_version=DEFAULT_API_VERSION, *parts):
    return f"/api/volumes/{api_version}/config/" + "/".join(parts)
```

(Most paths already exist: `vmm_path`, `networking_path`, `clustermgmt_path`,
`prism_path`, `volumes_path`, `dataprotection_path`.)

### Step 2 — Add the driver method

`libcloud/compute/drivers/nutanix.py`:

```python
def ex_list_volume_groups(self, **kwargs):
    """List Nutanix volume groups."""
    path = volumes_path() + "volume-groups"
    resp = self.connection.request(path, params=kwargs)
    return [self._to_volume_group(item) for item in resp.get("data", [])]
```

Conventions to follow (from the existing driver):
- **Reads** (`list_*`, `ex_list_*`, `ex_get_*`) → synchronous `self.connection.request(...)`.
- **Mutating** calls (`create_*`, `update_*`, `delete_*`, power actions) →
  go through `_execute_async_mutation(method, path, data=..., headers=...)`,
  which POSTs, reads the task reference, polls `ex_get_task(task_id)` until
  `SUCCEEDED`, and returns the entity. Add an `_etag` header from
  `_get_vm_etag` / `_get_volume_group_etag` / `_get_recovery_point_etag` for
  PUT/DELETE where the cloud requires it.
- Add a `_to_<entity>` adapter that converts the cloud JSON into a libcloud
  base object (`Node`, `NodeImage`, `NodeSize`, `NodeLocation`,
  `StorageVolume`, `VolumeSnapshot`, or a driver-specific extra dict).
- Add the method to `libcloud.compute.base.NodeDriver`'s API surface only if
  it is generic; otherwise keep it as `ex_*` (provider-specific).

### Step 3 — Add a test

`libcloud/test/compute/test_nutanix.py` (and `test_nutanix_emulator.py`
against the stoplight mock — see
[how_to_create_stoplight_mock_endpoint.md](how_to_create_stoplight_mock_endpoint.md)):

```python
def test_ex_list_volume_groups(self):
    driver = self._make_driver()
    driver.connection.request = mock.Mock(return_value={"data": [{...}]})
    groups = driver.ex_list_volume_groups()
    self.assertEqual(len(groups), 1)
```

```bash
python3 -m pytest libcloud/test/compute/test_nutanix.py
```

### Step 4 — Surface it through libcloud.rest

1. **Service** — add a method in `app/compute/service.py` (or
   `app/network/service.py` / `app/storage/service.py`) that calls the new
   driver method. If the method takes provider-specific options, allowlist
   them in `AWS_ALLOWED_EX` / `NUTANIX_ALLOWED_EX` (see
   `app/compute/service.py`).
2. **Route** — add the URL in `app/<domain>/routes.py` with the right
   `require_scopes(...)` + `policy_engine.authorize_connection(...)`. See
   [how_to_create_libcloud_rest_endpoint.md](how_to_create_libcloud_rest_endpoint.md).
3. Recreate the REST API and run `./system_validate.sh`.

### Step 5 — Mock the endpoint (if Nutanix)

If you are developing against the stoplight mock, add a stateful mock for
the new path — see
[how_to_create_stoplight_mock_endpoint.md](how_to_create_stoplight_mock_endpoint.md).

---

## 3. MODIFY a resource method

| Change | Where |
|--------|-------|
| Change the request path / payload | `libcloud/common/<cloud>.py` builder + the driver method |
| Change the response mapping | the `_to_<entity>` adapter in the driver |
| Change which `ex_*` options are allowlisted through the REST API | `AWS_ALLOWED_EX` / `NUTANIX_ALLOWED_EX` in `app/compute/service.py` |
| Change async → sync (or vice versa) | swap `_execute_async_mutation` for `self.connection.request` (or the reverse) |

Update the tests; recreate the REST API if the REST surface changed.

---

## 4. DEPRECATE a resource method

1. Remove the REST route and the service method (see
   [how_to_create_libcloud_rest_endpoint.md](how_to_create_libcloud_rest_endpoint.md) §3).
2. Remove the driver method and its `_to_<entity>` adapter if unused elsewhere.
3. Remove the payload builder if unused elsewhere.
4. Remove the test and any stoplight mock for the path.
5. Run the driver test suite + `./system_validate.sh`.

> If the method is part of the libcloud base `NodeDriver` API (not `ex_*`),
> deprecating it may break other drivers — prefer raising
> `NotImplementedError` for a release before removing.

---

## 5. VERIFY

```bash
# Driver-level:
python3 -m pytest libcloud/test/compute/test_<cloud>.py

# REST-level (after wiring):
curl -s -H "Authorization: Bearer <jwt>" \
  "http://localhost:8765/v1/compute/<resource>?connection=<urlencoded-json>" | jq

# End-to-end:
./system_validate.sh
```

---

## 6. Files touched

| File | What changes |
|------|--------------|
| `libcloud/compute/drivers/<cloud>.py` | new / changed / removed method + `_to_<entity>` adapter |
| `libcloud/common/<cloud>.py` | new / changed / removed path / payload builder |
| `libcloud/test/compute/test_<cloud>*.py` | test |
| `../libcloud.rest/app/<domain>/service.py` | service method calling the driver |
| `../libcloud.rest/app/<domain>/routes.py` | REST URL (separate guide) |
| `../libcloud.rest/app/compute/service.py` | `*_ALLOWED_EX` allowlist (if new `ex_*` options) |
| `../stoplight_mock/mock/server.js` | mock endpoint (Nutanix only, separate guide) |

---

## 7. Quick reference

| Action | Command |
|--------|---------|
| Run driver tests | `python3 -m pytest libcloud/test/compute/test_<cloud>.py` |
| Run emulator tests | `python3 -m pytest libcloud/test/compute/test_nutanix_emulator.py` |
| REST endpoint guide | [how_to_create_libcloud_rest_endpoint.md](how_to_create_libcloud_rest_endpoint.md) |
| Mock endpoint guide | [how_to_create_stoplight_mock_endpoint.md](how_to_create_stoplight_mock_endpoint.md) |
| Reference driver | `libcloud/compute/drivers/nutanix.py` |
