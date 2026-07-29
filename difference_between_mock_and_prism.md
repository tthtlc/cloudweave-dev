# Difference Between Stoplight Emulator and Stoplight Mock Server (Prism) Container

## Stoplight Mock Server Container → **Prism**

This is the official `stoplight/prism:5` Docker image (the `prism` service in `docker-compose.yml`). It's a **stateless** OpenAPI 3 mock server:

- Runs on port **4010**
- Reads the merged `spec/openapi.json` (487 paths, 2206 schemas)
- Returns **schema-valid but static/example responses** for every path in the spec
- Has **no memory** — it can't do CRUD. A POST "create VM" returns a canned example; a subsequent GET returns the same example, not what you "created"
- Enforces OpenAPI validation (requires `Ntnx-Request-Id`, `If-Match` headers, valid UUIDs, etc.)

## Emulator → Custom Node.js Shim

This is a **custom** Node.js Express server (`emulator` service, built from `stoplight_mock/mock/`). It's a **stateful** shim that wraps Prism:

- Runs on port **9440** (HTTPS with self-signed cert)
- Keeps **in-memory `Map` stores** for VMs, subnets, VPCs, FIPs, volume groups, etc.
- Handles **stateful CRUD** — create a VM, poll the task, GET it back with your data, update it, delete it
- Simulates Nutanix's **async task lifecycle** (`QUEUED → RUNNING → SUCCEEDED` over 200ms)
- **Proxies everything else** to Prism via catch-all proxy — any endpoint not explicitly handled by the shim falls through to Prism for a schema-valid static response

## Architecture

```
Client → Emulator (9440) → [stateful CRUD: VMs, subnets, VPCs, etc.]
                          → [proxy everything else] → Prism (4010) → static examples
```

## Summary

| | Prism container | Emulator shim |
|---|---|---|
| **Official Stoplight?** | Yes (`stoplight/prism:5`) | No — custom Node.js |
| **Stateful?** | No — static examples only | Yes — in-memory CRUD |
| **Port** | 4010 (HTTP) | 9440 (HTTPS) |
| **Best for** | Schema contract validation | Full integration testing (Terraform, SDKs, curl) |

## Why Both Are Needed

The emulator is what makes the mock actually usable for integration testing — without it, Prism alone can't simulate a real Nutanix API where you:
- Create resources and get back unique extIds
- Poll async tasks that transition through states
- Retrieve resources you previously created
- Update or delete resources and see those changes reflected

Prism alone returns the same static example every time, which is fine for contract/schema validation but insufficient for testing real API workflows like VM lifecycle management, networking resource CRUD, or volume group operations.
