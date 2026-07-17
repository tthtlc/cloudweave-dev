# How to Create / Modify / Delete a stoplight_mock Stateful Endpoint (+ Seed Data)

This guide covers the **stateful emulator shim** in `../stoplight_mock`
(`mock/server.js`): adding a new mocked Nutanix v4 endpoint that needs real
CRUD behaviour + async task semantics, changing its envelope / transitions,
and removing one. It also covers adding **seed reference data**.

> **What a mock endpoint is here.** The stack is a two-tier mock:
> **Stoplight Prism** serves schema-valid static responses for **every**
> path in the merged OpenAPI spec (487 paths); the **Node.js emulator shim**
> (`mock/server.js`, port 9440, HTTPS self-signed) intercepts the **subset**
> that needs stateful CRUD + task lifecycle and proxies everything else to
> Prism. So "add a mock endpoint" means: add a route to the shim that needs
> real behaviour. Endpoints that only need schema-valid example responses
> are already handled by Prism (no code).

---

## 0. The shim's conventions

| Convention | Detail |
|------------|--------|
| Path variants | Every route is expanded to `v4.0.a1`, `v4.0`, `v4.0/ahv` via `pathVariants(ns, category, resource)` (`API_VERSIONS`). |
| State | In-memory `Map`s per resource (`vmStore`, `taskStore`, `volumeGroupStore`, `recoveryPointStore`, `vpcStore`, `fipStore`, `nspStore`, `clusters`, `subnets`, `images`, `storageContainers`). Lost on container restart. |
| Async pattern | Mutating calls return `202` + a `TaskReference` envelope; the task transitions `QUEUED → RUNNING → SUCCEEDED` over `TASK_TRANSITION_MS` (200 ms) and is polled via the Prism tasks endpoint. |
| Envelopes | AHV/VMM/volumes/dataprotection use `$objectType` from `vmm.v4.ahv.config.*` / `prism.v4.config.*`, `$reserved.$fv = "v4.r0"`. Networking (subnets/VPCs/FIPs/NSPs) uses `networking.v4.config.*`, `$fv = "v4.r2"`. Tasks always `prism.v4.config.Task` `$fv = "v4.r2"`. |
| Case | Request bodies accepted in `snake_case` (curl) or `camelCase` (Go SDK); responses always `camelCase` via `deepConvert(..., toCamelCase)`. |
| Catch-all | Any path not matched falls through to `createProxyMiddleware({ target: PRISM_URL })`; the proxy re-serializes the JSON body for mutating verbs. |
| Auth | Bypassed (security schemes stripped from the merged spec). |

Seed reference data (in `mock/server.js`):

| Resource | extId | Name |
|----------|-------|------|
| Cluster | `00000000-0000-0000-0000-000000000001` | emulator-cluster |
| Subnet | `00000000-0000-0000-0000-000000000002` | emulator-primary-subnet |
| Image | `00000000-0000-0000-0000-000000000003` | emulator-ubuntu-2204 |
| Image | `00000000-0000-0000-0000-000000000004` | emulator-centos-9 |
| Storage Container | `00000000-0000-0000-0000-000000000005` | emulator-default-container |

---

## 1. Prerequisites

- `../stoplight_mock` is up (`docker compose up -d`); the `emulator` + `prism`
  services are healthy.
- The path you are mocking exists in the merged OpenAPI spec (`spec/openapi.json`)
  — if not, see [how_to_create_stoplight_mock_namespace.md](how_to_create_stoplight_mock_namespace.md).
- You have decided the route belongs in the **shim** (stateful) and not just
  Prism (schema-only).

---

## 2. ADD a stateful endpoint (example: `volume-groups` CRUD)

### Step 1 — Add an in-memory store + seed data (if needed)

At the top of `mock/server.js` next to the other stores:

```js
const volumeGroupStore = new Map();
// optional seed:
volumeGroupStore.set('00000000-0000-0000-0000-000000000010', {
  ext_id: '00000000-0000-0000-0000-000000000010',
  name: 'emulator-vg-0',
  ...
});
```

### Step 2 — Register the routes with all path variants

Use `pathVariants(ns, category, resource)` to expand to the three API
versions, e.g. `/api/volumes/{v4.0.a1|v4.0|v4.0/ahv}/config/volume-groups`.

```js
const VG_PATHS = pathVariants('volumes', 'config', 'volume-groups');

app.get(VG_PATHS, (req, res) => {
  // list (+ optional $filter on volumeGroupExtId)
  const items = [...volumeGroupStore.values()].map(deepConvert(toCamelCase));
  res.json({ data: items, total_available: items.length });
});

app.post(VG_PATHS, (req, res) => {
  const body = deepConvert(req.body, toSnakeCase);
  const extId = uuidv4();
  volumeGroupStore.set(extId, { ext_id: extId, ...body });
  const task = makeTask('CREATE_VOLUME_GROUP', [{ ext_id: extId }]);
  res.status(202).json({
    $objectType: 'vmm.v4.ahv.config.TaskReference',
    $reserved: { $fv: 'v4.r0' },
    ext_id: task.ext_id,
  });
});

app.get(`${VG_PATHS}/:extId`, (req, res) => {
  const vg = volumeGroupStore.get(req.params.extId);
  if (!vg) return res.status(404).json({ message: 'not found' });
  res.json({ data: deepConvert(vg, toCamelCase) });
});

app.delete(`${VG_PATHS}/:extId`, (req, res) => {
  if (!volumeGroupStore.has(req.params.extId))
    return res.status(404).json({ message: 'not found' });
  volumeGroupStore.delete(req.params.extId);
  const task = makeTask('DELETE_VOLUME_GROUP', [{ ext_id: req.params.extId }]);
  res.status(202).json({ $objectType: 'vmm.v4.ahv.config.TaskReference',
    $reserved: { $fv: 'v4.r0' }, ext_id: task.ext_id });
});
```

### Step 3 — Use the right envelope + task `$fv`

- AHV/VMM/volumes/dataprotection → `$objectType` from `vmm.v4.ahv.config.*`,
  `$fv = "v4.r0"`.
- Networking → `networking.v4.config.*`, `$fv = "v4.r2"`.
- Tasks (polled via `/api/prism/v4.0*/config/tasks/:extId`) → always
  `prism.v4.config.Task` with `$fv = "v4.r2"` (so both AHV and networking Go
  clients can poll).

### Step 4 — Rebuild + restart the emulator

```bash
docker compose -f ../stoplight_mock/docker-compose.yml up -d --build emulator
```

### Step 5 — Smoke-test

```bash
../stoplight_mock/scripts/smoke-test.sh
# or curl directly against https://localhost:9440 (self-signed):
curl -k https://localhost:9440/api/volumes/v4.0/config/volume-groups | jq
```

### Step 6 — Add / extend a libcloud driver method against the new endpoint

See [how_to_create_libcloud_resource_method.md](how_to_create_libcloud_resource_method.md)
and `libcloud/test/compute/test_nutanix_emulator.py`.

---

## 3. MODIFY an endpoint

| Change | Where |
|--------|-------|
| Change envelope / `$fv` | the route handlers in `mock/server.js` |
| Change task transition timing | `TASK_TRANSITION_MS` constant |
| Change filter semantics | the `$filter` parsing in the relevant `GET` handler |
| Add a sub-resource (e.g. `volume-groups/:id/disks`) | a new `app.get` route under the existing path |
| Change seed data | the `Map` initializer at the top of `server.js` |

Restart the `emulator` container (state is in-memory, so seed data is
re-applied on every restart).

---

## 4. DELETE an endpoint

1. Remove the route handlers from `mock/server.js`.
2. Remove the in-memory `Map` + seed data if no other route uses it.
3. Restart the emulator.
4. The path **still works** (Prism answers it with a schema-valid example)
  unless you also removed it from the merged spec — see
  [how_to_create_stoplight_mock_namespace.md](how_to_create_stoplight_mock_namespace.md) §4.
5. Update / remove the libcloud driver method that called it — see
  [how_to_create_libcloud_resource_method.md](how_to_create_libcloud_resource_method.md) §4.

---

## 5. VERIFY

```bash
# Emulator health (counts of every in-memory store):
curl -k https://localhost:9440/health | jq

# Smoke test (health, seed data, VM CRUD lifecycle, path variants):
../stoplight_mock/scripts/smoke-test.sh

# Confirm unmatched paths still fall through to Prism:
curl -k https://localhost:9440/api/<ns>/v4.0/.../something-only-prism-knows | jq
```

---

## 6. Files touched

| File | What changes |
|------|--------------|
| `../stoplight_mock/mock/server.js` | new / changed / removed routes + store + seed data |
| `../stoplight_mock/mock/package.json` | only if a new npm dependency is needed |
| `../stoplight_mock/scripts/smoke-test.sh` | new assertions for the endpoint |
| `libcloud/test/compute/test_nutanix_emulator.py` | emulator-backed driver test |

The merged OpenAPI spec (`spec/openapi.json`) is **not** edited for an
existing path — only when adding a namespace (separate guide).

---

## 7. Quick reference

| Action | Command |
|--------|---------|
| Rebuild + restart emulator | `docker compose -f ../stoplight_mock/docker-compose.yml up -d --build emulator` |
| Health | `curl -k https://localhost:9440/health \| jq` |
| Smoke test | `../stoplight_mock/scripts/smoke-test.sh` |
| Logs | `docker compose -f ../stoplight_mock/docker-compose.yml logs -f emulator` |
| Reference | `mock/server.js` (existing VM / subnet / VPC / FIP / NSP / volume-group / recovery-point routes) |
| Add a namespace | [how_to_create_stoplight_mock_namespace.md](how_to_create_stoplight_mock_namespace.md) |
