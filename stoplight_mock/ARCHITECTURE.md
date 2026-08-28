# Architecture — Nutanix OpenAPI Mock Stack

This document summarizes the Docker-based mocking environment for the Nutanix
OpenAPI specification: how the containers are wired together, what the
OpenAPI specification covers, and which Nutanix REST API endpoints are mocked
statefully by the emulator shim versus which are answered schema-only by
Stoplight Prism.

---

## 1. Overview

The stack is a two-tier mock of Nutanix Prism Central's v4 REST API:

1. **Stoplight Prism** — a stateless OpenAPI 3 mock server. It serves
   schema-valid (but static/example) responses for **every** path declared in
   the merged Nutanix v4 OpenAPI document.
2. **Node.js emulator shim** — a stateful Express front-end that intercepts
   the subset of endpoints which require real CRUD behaviour and async task
   semantics, then proxies everything else through to Prism.

```
┌────────────────────┐
│  Client (Terraform │
│  / curl / SDK)     │
└─────────┬──────────┘
          │ HTTPS :9440 (self-signed)
          ▼
┌─────────────────────────────────────────────┐
│  Node.js emulator shim (mock/server.js)     │
│  • Stateful in-memory Maps                  │
│  • VM/Subnet/VPC/FIP/NSP/VolumeGroup/...    │
│    CRUD + task lifecycle simulation         │
│  • Nutanix v4 envelopes ($objectType, …)    │
│  • Catch-all reverse proxy → Prism          │
└─────────┬───────────────────────────────────┘
          │ HTTP :4010 (unmatched routes)
          ▼
┌─────────────────────────────────────────────┐
│  Stoplight Prism 5 (stoplight/prism:5)      │
│  • Reads spec/openapi.json (read-only)      │
│  • Schema-valid contract mocking only       │
└─────────────────────────────────────────────┘
```

Source of wiring: `docker-compose.yml`.

---

## 2. Docker Compose services

File: `docker-compose.yml`

The stack now mocks **four** Nutanix v4 minor versions side-by-side — one
Prism (schema-only) mock plus one stateful emulator per version, each on its
own host port:

| Version | Prism service | Prism host port | Emulator service | Emulator host port |
|---------|---------------|-----------------|------------------|--------------------|
| v4.0    | `prism`       | `127.0.0.1:4010`| `emulator`       | `0.0.0.0:9440`     |
| v4.1    | `prism-41`    | `127.0.0.1:4011`| `emulator-41`    | `0.0.0.0:9441`     |
| v4.2    | `prism-42`    | `127.0.0.1:4012`| `emulator-42`    | `0.0.0.0:9442`     |
| v4.3    | `prism-43`    | `127.0.0.1:4013`| `emulator-43`    | `0.0.0.0:9443`     |

Each `prism*` service runs `stoplight/prism:5` with
`mock -h 0.0.0.0 -p 4010 -m false /spec/openapi{,-v4.1,-v4.2,-v4.3}.json`
(mounts `./spec:/spec:ro`). Prism serves static (example) responses because its
dynamic-vs-static flag `-d`/`--dynamic` is **not** passed — `-m` is the
multiprocess flag and has nothing to do with static-vs-dynamic mocking. Each
`emulator*` service builds `./mock`, exposes internal
port `9440`, and sets two env vars:

* `PRISM_URL` — points at its matching Prism (e.g. `http://prism-41:4010`).
* `API_VERSION` — the minor version (`v4.0` … `v4.3`) used to build the
  `/api/{ns}/{version}/...` paths and to select the AHV VM path shape
  (`/api/vmm/v4.x/ahv/config/vms` for v4.1+).

Note: the older `tmp/README.md` also describes a `terraform` service, but the
current `docker-compose.yml` only defines the Prism + emulator pairs. Terraform
is now invoked from the host or via the helper scripts in `tmp/`.

---

## 3. The merged OpenAPI specification

Source file: `spec/openapi.json` (≈ 12.6 MB, 487 paths, 2206 schemas, 109 tags).

It is produced by `scripts/merge-specs.js`, which merges the per-namespace YAML
specs (prefixed with `/api` for `paths`, plus `schemas` and `tags`) into the
combined OpenAPI 3.0.1 document.

> **Note:** `merge-specs.js:8` hardcodes `const V40_DIR = path.resolve('/work/mock/v40')`
> and writes to `/work/spec/openapi.json`. The directory `mock/v40/` **does not exist**
> (the `mock/` dir contains only `Dockerfile`, `entrypoint.sh`, `package.json`,
> `server.js`), and no compose service mounts `/work/mock` — so the documented v4.0
> build is **not runnable as written**. The v4.0 namespace YAMLs actually live in
> `/home/ubuntu/libcloud_nutanix/nutanix_swagger/`.

### 3.1 Nutanix REST API namespaces included in the merged spec

The merged spec combines all of the following Nutanix v4 namespace specs
(from `scripts/merge-specs.js`):

| Nutanix namespace (spec file) | REST API prefix (`/api/{ns}/...`) | Domain |
|-------------------------------|-----------------------------------|--------|
| `swagger-vmm-v4.0-all.yaml`             | `/api/vmm/v4.0/...`              | Virtual Machine Management (VMs, images, storage containers, CD-ROMs, categories) |
| `swagger-networking-v4.0-all.yaml`      | `/api/networking/v4.0/...`       | Networking (subnets, VPCs, floating IPs, network security policies) |
| `swagger-clustermgmt-v4.0-all.yaml`     | `/api/clustermgmt/v4.0/...` (also served as `cluster-mgmt`) | Cluster management |
| `swagger-prism-v4.0-all.yaml`           | `/api/prism/v4.0/...`            | Prism Central core (tasks, etc.) |
| `swagger-storage-v4.0.a3-all.yaml`      | `/api/storage/v4.0/...`          | Storage |
| `swagger-volumes-v4.0-all.yaml`         | `/api/volumes/v4.0/...`          | Volume groups / vDisks |
| `swagger-iam-v4.0-all.yaml`             | `/api/iam/v4.0/...`              | Identity & Access Management |
| `swagger-files-v4.0-all.yaml`           | `/api/files/v4.0/...`            | Files / file server |
| `swagger-security-v4.0-all.yaml`        | `/api/security/v4.0/...`         | Security |
| `swagger-monitoring-v4.0-all.yaml`      | `/api/monitoring/v4.0/...`       | Monitoring / alerts |
| `swagger-licensing-v4.0-all.yaml`       | `/api/licensing/v4.0/...`        | Licensing |
| `swagger-aiops-v4.0-all.yaml`           | `/api/aiops/v4.0/...`            | AIOps |
| `swagger-datapolicies-v4.0-all.yaml`    | `/api/datapolicies/v4.0/...`     | Data policies |
| `swagger-dataprotection-v4.0-all.yaml`  | `/api/dataprotection/v4.0/...`   | Data protection / recovery points |
| `swagger-lifecycle-v4.0-all.yaml`       | `/api/lifecycle/v4.0/...`        | Lifecycle (Lcm) |
| `swagger-microseg-v4.0-all.yaml`        | `/api/microseg/v4.0/...`         | Micro-segmentation (flow / NSP) |
| `swagger-objects-v4.0-all.yaml`         | `/api/objects/v4.0/...`          | Objects store |
| `swagger-opsmgmt-v4.0-all.yaml`         | `/api/opsmgmt/v4.0/...`          | Ops management |
| `swagger-multidomain-v4.2-all.yaml`     | `/api/multidomain/v4.2/...`      | Multi-domain management (v4.2) |

Prism serves all 487 of these paths schema-only. Security schemes are
deliberately stripped during merge so Prism does **not** enforce auth on mock
responses.

### 3.2 Path version variants

For `v4.0`, `API_VERSIONS` is `['v4.0.a1', 'v4.0', 'v4.0/ahv']` and
`pathVariants(ns, category, resource)` expands each route to all three, e.g.
`/api/vmm/{v4.0.a1|v4.0|v4.0/ahv}/config/vms`:

- `v4.0.a1` — legacy pre-release path
- `v4.0`    — stable v4 path
- `v4.0/ahv`— path used by the Nutanix Terraform provider v2.2.1

This only applies to `pathVariants`-based routes. Three routes use a single
`${API_VERSION}` path instead of the three variants: volume groups
(`/api/volumes/${API_VERSION}/config/volume-groups`, server.js:890), recovery
points (`/api/dataprotection/${API_VERSION}/config/recovery-points`, server.js:1043),
and the images content path (`/api/vmm/${API_VERSION}/content/images`, server.js:822).

---

## 4. APIs mocked statefully by the emulator shim

File: `mock/server.js` (Express, port 9440, HTTPS with self-signed cert
generated by `mock/entrypoint.sh`).

The shim keeps in-memory `Map`s for each resource type and simulates the
Nutanix async pattern: mutating calls return `202` with a `TaskReference`
envelope; the task transitions `QUEUED → RUNNING → SUCCEEDED` over
`TASK_TRANSITION_MS` (200 ms) and is polled via the Prism tasks endpoint.

### 4.1 Endpoints and the Nutanix namespace they belong to

| Namespace (REST prefix) | Resource | Methods handled by the shim |
|--------------------------|----------|------------------------------|
| **vmm** (`/api/vmm/v4.0*/config`) | VMs (`vms`) | `POST` (create), `GET` (list + `$filter=name eq '...'`), `GET /:extId`, `PUT /:extId` (update), `DELETE /:extId`, `POST /:extId/power-state/:action`, `POST /:extId/$actions/:action` (power-on, power-off, guest-shutdown, reset, guest-reboot) |
| **vmm** (`/api/vmm/v4.0*/config`) | Images (`images`) | `GET` (list), `GET /:extId` |
| **vmm** (content) (`/api/vmm/v4.0/content/images`) | Images (v4 content path) | `POST` (create from URL or VM-disk `ext_id`), `DELETE /:extId` |
| **clustermgmt** (`/api/clustermgmt|vmm|cluster-mgmt/v4.0*/config`) | Storage containers (`storage-containers`) | `GET` (list), `GET /:extId` |
| **prism** (`/api/prism/v4.0*/config`) | Tasks (`tasks`) | `GET /:extId` — returns `prism.v4.config.Task` envelope (`$fv: v4.r2`) so both AHV and networking Go clients can poll |
| **clustermgmt** (`/api/cluster-mgmt|clustermgmt/v4.0*/config`) | Clusters (`clusters`) | `GET` (list), `GET /:extId` |
| **networking** (`/api/networking/v4.0*/config`) | Subnets (`subnets`) | `GET` (list + filter), `GET /:extId`, `POST` (create), `PUT /:extId`, `DELETE /:extId` |
| **networking** (`/api/networking/v4.0*/config`) | VPCs (`vpcs`) | `GET` (list + filter), `GET /:extId`, `POST`, `PUT /:extId`, `DELETE /:extId` |
| **networking** (`/api/networking/v4.0*/config`) | Floating IPs (`floating-ips`) | `GET` (list + filter), `GET /:extId`, `POST` (auto-assigns `192.168.0.x`), `DELETE /:extId` |
| **microseg** (`/api/microseg/v4.0*/config`) | Network Security Policies (`policies`) | `GET` (list + filter), `GET /:extId`, `POST`, `DELETE /:extId` |
| **volumes** (`/api/volumes/v4.0/config`) | Volume Groups (`volume-groups`) | `POST`, `GET` (list + filter), `GET /:extId`, `DELETE /:extId`, `GET /:volumeGroupExtId/disks`, `GET /:volumeGroupExtId/vm-attachments`, `POST /:extId/$actions/attach-vm`, `POST /:extId/$actions/detach-vm` |
| **dataprotection** (`/api/dataprotection/v4.0/config`) | Recovery Points (`recovery-points`) | `POST`, `GET` (list + `$filter=volumeGroupExtId eq '...'`), `GET /:extId`, `DELETE /:extId` |
| (emulator-local) | Health (`/health`) | `GET` — returns counts of every in-memory store |
| (emulator-local) | Session login (`/api/nutanix/v1/session`) | `POST` — reads the Basic `Authorization` header, mints a UUID token, stores it in an in-memory `sessions` Map, and returns `Set-Cookie: NTNX_IAM_SESSION=<token>; Path=/; HttpOnly` |

### 4.2 Seed reference data

Bootstrapped in `mock/server.js` and visible to every namespace above:

| Resource            | extId                                  | Name |
|---------------------|----------------------------------------|------|
| Cluster             | `00000000-0000-0000-0000-000000000001` | emulator-cluster |
| Subnet              | `00000000-0000-0000-0000-000000000002` | emulator-primary-subnet |
| Image               | `00000000-0000-0000-0000-000000000003` | emulator-ubuntu-2204 |
| Image               | `00000000-0000-0000-0000-000000000004` | emulator-centos-9 |
| Storage Container   | `00000000-0000-0000-0000-000000000005` | emulator-default-container |

### 4.3 Response envelope conventions

The shim reproduces the Nutanix v4 wire format so the official Go SDK /
Terraform provider can deserialize the responses:

- **AHV / VMM / volumes / dataprotection** — `$objectType` from
  `vmm.v4.ahv.config.*` / `prism.v4.config.*`, `$reserved.$fv = "v4.r0"`.
  Task references use `prism.v4.config.TaskReference`.
- **Networking** (subnets, VPCs, FIPs, NSPs) — `$objectType` from
  `networking.v4.config.*`, `$reserved.$fv = "v4.r2"`. Task references use
  `prism.v4.config.TaskReference` with `$fv = "v4.r2"` (the networking Go
  client checks both).
- **Tasks** — always served as `prism.v4.config.Task` with `$fv = "v4.r2"`
  so they can be polled by both the AHV and networking clients.
- Request bodies are accepted in either `snake_case` (curl/smoke tests) or
  `camelCase` (Go SDK); responses are always emitted in `camelCase` via
  `deepConvert(..., toCamelCase)`.

### 4.4 Catch-all proxy to Prism

Any path not matched by the routes above falls through to
`createProxyMiddleware({ target: PRISM_URL })`. Because `express.json()`
consumes the body stream, the proxy's `proxyReq` hook re-serializes and
re-writes the JSON body for `POST/PATCH/PUT/DELETE` before forwarding. Proxy
errors return `502 { message: 'Prism unavailable' }`.

This means: **every endpoint that exists in the merged spec but is not in
§4.1 is still mockable — it is answered by Prism with a schema-valid
example response.** That covers the remaining namespaces in §3.1 (iam,
files, security, monitoring, licensing, aiops, datapolicies, lifecycle,
microseg, objects, opsmgmt, multidomain) plus any vmm/networking/cluster
endpoint the shim does not handle explicitly.

---

## 5. Build & runtime artifacts

| Path | Purpose |
|------|---------|
| `docker-compose.yml`        | Defines 4 Prism + 4 emulator services (§2), one pair per v4 minor version |
| `spec/openapi.json`         | Merged v4.0 spec consumed by `prism` (487 paths, 2206 schemas) |
| `spec/openapi-v4.{1,2,3}.json` | Merged v4.1/v4.2/v4.3 specs consumed by `prism-41/42/43` |
| `scripts/merge-specs.js`    | Builds `spec/openapi.json` from per-namespace YAML (hardcoded to `/work/mock/v40`, which no compose service mounts — see §3) |
| `scripts/merge_specs.py`    | Builds `spec/openapi-v4.{1,2,3}.json` from `nutanix_swagger/` |
| `scripts/myrun.sh`          | Test-runner snippet (`NUTANIX_HOST=... ./test_read.sh --version ...` plus a `curl --insecure` example). Not a build helper. |
| `mock/Dockerfile`           | `node:20-alpine` + curl + openssl; copies `server.js`, exposes 9440, healthcheck |
| `mock/entrypoint.sh`        | Waits for Prism readiness (version-aware probe), generates self-signed TLS cert, execs `node server.js` |
| `mock/server.js`            | The stateful shim (all routes in §4) + Prism catch-all proxy; `API_VERSION` env selects the version |
| `mock/package.json`         | Dependencies: `express`, `uuid`, `http-proxy-middleware` |
| `scripts/test.sh`           | Consolidated test runner (§7) — replaces `prism-test.sh`, `smoke-test.sh`, `test-emulator.sh` |

---

## 6. Operational notes / known limitations

- **State is in-memory only.** All `Map` stores are lost on `emulator`
  container restart; nothing is persisted to disk or a volume.
- **Auth is bypassed.** The shim accepts any credentials; security schemes
  are stripped from the merged spec so Prism also does not enforce auth.
- **Session-cookie handshake** (`mock/server.js:351-365`). `POST /api/nutanix/v1/session`
  reads the Basic `Authorization` header to extract the username, mints a UUID,
  stores it in an in-memory `sessions` Map, and returns
  `Set-Cookie: NTNX_IAM_SESSION=<token>; Path=/; HttpOnly`. This exists so the
  libcloud driver can switch from per-request Basic auth to cookie reuse after
  its first login. It is **not fidelity-accurate**: real Prism Central uses the
  cookie name `NTNX_IGW_SESSION`, `/api/nutanix/v1/session` is not a real
  endpoint, and the minted token is never validated on later requests.
- **No real Nutanix semantics.** The shim validates the API contract shape,
  not business logic (no cluster capacity checks, no real task workflows,
  no UUID relationship enforcement beyond a few lookups like
  image-from-VM-disk and volume-group VM attach).
- **Terraform provider caveat.** The Nutanix Terraform provider v2.2.1 Go
  SDK is sensitive to exact `$objectType` discriminators; mismatched
  discriminators on create-VM responses can crash the provider. Tune the
  envelopes in `mock/server.js` (§4.3) if you hit
  `OneOfCreateVmApiResponseData.UnmarshalJSON` errors.
- **`./terraform`** configuration referenced by `tmp/README.md` lives under
  `tmp/terraform/` and `tmp/terraform-network/`, not in the top-level
  `docker-compose.yml`.

### Fidelity gaps (verified against source)

- **No ETag / If-Match support** anywhere in `mock/server.js` — the driver's
  optimistic-concurrency dance is silently skipped, so concurrency control is
  **untested**.
- **No real task engine.** `makeTask()` (server.js:123-139) transitions
  `QUEUED → RUNNING → SUCCEEDED` via two `setTimeout` calls scheduled at task
  creation: `RUNNING` fires at `TASK_TRANSITION_MS` (200 ms; server.js:20) and
  `SUCCEEDED` at `TASK_TRANSITION_MS * 2` (400 ms). Every task therefore
  succeeds 400 ms after creation. There are no failure states.
- **`stop_node` returns a bogus success.** The libcloud driver sends power action
  `shutdown`, but the shim's `powerMap` (server.js:455) only maps `power-on`,
  `power-off`, `guest-shutdown`, `reset`, `guest-reboot` — so the VM's power state
  is left unchanged while a `202` success task is still returned.
- **Auth bypass is a no-op middleware** (`app.use((_req, _res, next) => next())`,
  server.js:1124), and `merge-specs.js:93-117` strips `security` / `securitySchemes`
  during merge so Prism never enforces auth.
- **State is in-memory** — all `Map` stores are lost on restart.
- **Network exposure** — emulators are published on `0.0.0.0:9440-9443` with a
  self-signed certificate and no authentication.

---

## 7. Test suite (read/write split)

The test suite is split by whether it mutates backend state:

| Script | Scope |
|--------|-------|
| `scripts/test_read.sh`  | **Read-only** — enumeration + GET operations only (Prism list/get + path validation, emulator health & seed data, unknown-resource 404s, Prism proxy). Issues no POST/PUT/DELETE. |
| `scripts/test_write.sh` | **Write** — create / update / delete (Prism mutation validation, VM lifecycle, networking, volume groups, recovery points) plus the GETs that verify the mutations. |
| `scripts/lib.sh`        | Shared harness (sourced by both): arg parsing, per-version URLs/paths, `req`/`check`/`check_body`/`poll_task`, banner/summary. |
| `scripts/test.sh`       | Thin wrapper that runs `test_read.sh` then `test_write.sh`. |

These replace `prism-test.sh`, `smoke-test.sh` and `test-emulator.sh`.

Two output modes (both scripts):

* **quiet** (default) — one `✓`/`✗` line per check plus a summary.
* **`--verbose` / `-v`** — additionally prints every HTTP request in detail:
  method, full URL, headers, body, response status and response body.

Version selection via `--version` (default `v4.0`; also accepts `4.1`,
`v4.1.0`, …), which maps to the matching Prism/emulator host ports in §2:

```
./scripts/test_read.sh                        # v4.0 read-only, quiet
./scripts/test_write.sh --version v4.3 --verbose
./scripts/test.sh -V 4.1                      # both read + write
```

Exit code = number of failed checks. The v4.0 run also exercises the legacy
`v4.0.a1` / bare `/v4.0/` path variants; v4.1+ use the canonical
`/api/vmm/v4.x/ahv/config/vms` AHV path.
