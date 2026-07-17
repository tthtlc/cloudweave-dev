# How to Create / Modify / Delete a stoplight_mock Namespace (OpenAPI Merge)

This guide covers the **merged OpenAPI specification** in
`../stoplight_mock` (`spec/openapi.json`): adding a new Nutanix v4 namespace
spec to the merge, re-merging, and dropping a namespace. It is the spec-side
companion to [how_to_create_stoplight_mock_endpoint.md](how_to_create_stoplight_mock_endpoint.md).

> **What a namespace is here.** The merged spec is produced by
> `scripts/merge-specs.js`, which runs inside a throwaway `node:20-alpine`
> container (`myrun.sh`) and reads the per-namespace YAML specs from
> `mock/v40/`, merges their `paths` (each prefixed with `/api`), `schemas`,
> and `tags`, and writes the combined OpenAPI 3.0.1 document
> (`spec/openapi.json`, ~12.6 MB, 487 paths, 2206 schemas, 109 tags).
> Security schemes are deliberately stripped during merge so Prism does not
> enforce auth on mock responses. Adding a namespace = adding a YAML file to
> `mock/v40/` and re-running the merge.

---

## 0. The namespaces currently merged

From `scripts/merge-specs.js`:

| Namespace spec file | REST prefix | Domain |
|---------------------|-------------|--------|
| `swagger-vmm-v4.0-all.yaml` | `/api/vmm/v4.0/...` | VMs, images, storage containers, CD-ROMs, categories |
| `swagger-networking-v4.0-all.yaml` | `/api/networking/v4.0/...` | subnets, VPCs, FIPs, NSPs |
| `swagger-clustermgmt-v4.0-all.yaml` | `/api/clustermgmt/v4.0/...` (also `cluster-mgmt`) | cluster management |
| `swagger-prism-v4.0-all.yaml` | `/api/prism/v4.0/...` | Prism core (tasks) |
| `swagger-storage-v4.0.a3-all.yaml` | `/api/storage/v4.0/...` | storage |
| `swagger-volumes-v4.0-all.yaml` | `/api/volumes/v4.0/...` | volume groups / vDisks |
| `swagger-iam-v4.0-all.yaml` | `/api/iam/v4.0/...` | IAM |
| `swagger-files-v4.0-all.yaml` | `/api/files/v4.0/...` | files |
| `swagger-security-v4.0-all.yaml` | `/api/security/v4.0/...` | security |
| `swagger-monitoring-v4.0-all.yaml` | `/api/monitoring/v4.0/...` | monitoring / alerts |
| `swagger-licensing-v4.0-all.yaml` | `/api/licensing/v4.0/...` | licensing |
| `swagger-aiops-v4.0-all.yaml` | `/api/aiops/v4.0/...` | AIOps |
| `swagger-datapolicies-v4.0-all.yaml` | `/api/datapolicies/v4.0/...` | data policies |
| `swagger-dataprotection-v4.0-all.yaml` | `/api/dataprotection/v4.0/...` | data protection / recovery points |
| `swagger-lifecycle-v4.0-all.yaml` | `/api/lifecycle/v4.0/...` | lifecycle (Lcm) |
| `swagger-microseg-v4.0-all.yaml` | `/api/microseg/v4.0/...` | micro-segmentation |
| `swagger-objects-v4.0-all.yaml` | `/api/objects/v4.0/...` | objects store |
| `swagger-opsmgmt-v4.0-all.yaml` | `/api/opsmgmt/v4.0/...` | ops management |
| `swagger-multidomain-v4.2-all.yaml` | `/api/multidomain/v4.2/...` | multi-domain (v4.2) |

---

## 1. Prerequisites

- `../stoplight_mock` is up.
- You have the new namespace's OpenAPI YAML (downloaded from the Nutanix
  OpenAPI portal).
- Docker is available (`merge-specs.js` runs in a `node:20-alpine` container).

---

## 2. ADD a namespace (e.g. `swagger-acme-v4.0-all.yaml`)

### Step 1 — Drop the YAML into `mock/v40/`

```bash
cp swagger-acme-v4.0-all.yaml ../stoplight_mock/mock/v40/
```

### Step 2 — Teach `scripts/merge-specs.js` about it

Add an entry to whatever list the script iterates (mirror the existing
entries — file name, namespace, REST prefix). The script:

1. Reads each per-namespace YAML from `mock/v40/`.
2. Prefixes every path with `/api`.
3. Merges `paths`, `schemas`, and `tags` into the combined document.
4. Strips security schemes.
5. Writes `spec/openapi.json`.

### Step 3 — Re-merge + restart Prism

```bash
cd ../stoplight_mock
./myrun.sh
```

`myrun.sh` runs `merge-specs.js` in a `node:20-alpine` container and
restarts Prism so it re-reads `spec/openapi.json`. Prism serves **every**
path in the merged spec schema-only (`-m false` disables dynamic mocking).

### Step 4 — (Optional) add stateful shim routes for the new namespace

Prism already serves the new paths with schema-valid examples. Add routes
to `mock/server.js` only for the subset that needs stateful CRUD + task
lifecycle — see
[how_to_create_stoplight_mock_endpoint.md](how_to_create_stoplight_mock_endpoint.md).

### Step 5 — Smoke-test

```bash
../stoplight_mock/scripts/smoke-test.sh
# confirm a new path is served (schema-only by Prism):
curl -k https://localhost:9440/api/acme/v4.0/config/something | jq
```

---

## 3. MODIFY a namespace

| Change | How |
|--------|-----|
| New path / schema in an existing namespace | update the YAML in `mock/v40/`, re-run `myrun.sh` |
| Bump a namespace API version (e.g. v4.0 → v4.2) | add the new YAML alongside (see `multidomain` v4.2), update `merge-specs.js`, re-merge |
| Change the `/api` prefix logic | `scripts/merge-specs.js` |
| Change security-scheme stripping | `scripts/merge-specs.js` (currently strips all) |

Re-running `myrun.sh` rewrites `spec/openapi.json` and restarts Prism. The
emulator shim is unaffected unless you also edit `mock/server.js`.

---

## 4. DELETE / drop a namespace

1. Remove the YAML from `mock/v40/`.
2. Remove the entry from `scripts/merge-specs.js`.
3. Re-run `myrun.sh` so Prism stops serving those paths.
4. Remove any stateful shim routes for that namespace from `mock/server.js`
   — see [how_to_create_stoplight_mock_endpoint.md](how_to_create_stoplight_mock_endpoint.md) §4.
5. Remove any libcloud driver methods + tests that depended on those paths
   — see [how_to_create_libcloud_resource_method.md](how_to_create_libcloud_resource_method.md) §4.

---

## 5. VERIFY

```bash
# Prism is healthy and serving the new merged spec:
docker compose -f ../stoplight_mock/docker-compose.yml ps prism
docker compose -f ../stoplight_mock/docker-compose.yml logs --tail=20 prism

# Path count + a sample path from the new namespace:
python3 -c "import json; s=json.load(open('../stoplight_mock/spec/openapi.json')); \
  print(len(s['paths'])); [print(p) for p in s['paths'] if p.startswith('/api/acme/')][:5]"

# Smoke test:
../stoplight_mock/scripts/smoke-test.sh
```

---

## 6. Files touched

| File | What changes |
|------|--------------|
| `../stoplight_mock/mock/v40/swagger-<ns>-*.yaml` | NEW / updated / removed namespace spec |
| `../stoplight_mock/scripts/merge-specs.js` | namespace entry in the merge list |
| `../stoplight_mock/spec/openapi.json` | re-generated (do not hand-edit) |
| `../stoplight_mock/mock/server.js` | (only if stateful routes added) |
| `../stoplight_mock/scripts/smoke-test.sh` | (optional) assertions for the new paths |

---

## 7. Quick reference

| Action | Command |
|--------|---------|
| Re-merge + restart Prism | `cd ../stoplight_mock && ./myrun.sh` |
| Restart emulator only | `docker compose -f ../stoplight_mock/docker-compose.yml up -d --build emulator` |
| Smoke test | `../stoplight_mock/scripts/smoke-test.sh` |
| Path count | `python3 -c "import json; print(len(json.load(open('../stoplight_mock/spec/openapi.json'))['paths']))"` |
| Stateful route guide | [how_to_create_stoplight_mock_endpoint.md](how_to_create_stoplight_mock_endpoint.md) |
