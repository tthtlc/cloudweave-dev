# Nutanix VM Emulator + Terraform Provisioning

A container-based development environment that emulates the Nutanix v4 VM API using
**Stoplight Prism** (OpenAPI schema mocking) fronted by a **stateful Node.js shim**
that handles VM CRUD and task polling. The stack also includes a **pre-built
Terraform container** with the Nutanix provider v2.2.1 loaded from a local
filesystem mirror — no registry access needed after the initial image build.

```
┌──────────────────┐
│ Terraform 1.9.8  │  docker compose run --rm terraform <cmd>
│ nutanix provider │
│ v2.2.1 (mirror)  │
└────────┬─────────┘
         │ HTTPS :9440
         ▼
┌─────────────────────┐
│ Node.js Shim (:9440)│
│ • VM CRUD (stateful)│
│ • Task polling      │
│ • Seed ref data     │
│ • Nutanix v4 format │
└─────────┬───────────┘
          │ unmatched routes
          ▼
┌─────────────────────┐
│ Stoplight Prism     │
│ (:4010)             │
│ Schema validation   │
│ Contract mocking    │
└─────────────────────┘
```

## Quick Start

```bash
# 1. Build and start the emulator (Prism + shim)
docker compose up -d

# 2. Wait for healthy and run smoke test
docker compose ps
./scripts/smoke-test.sh

# 3. Run Terraform commands
docker compose run --rm terraform init
docker compose run --rm terraform plan
docker compose run --rm terraform apply -auto-approve
docker compose run --rm terraform destroy -auto-approve
```

## Architecture

| Component | Port | Protocol | Purpose |
|-----------|------|----------|---------|
| **Stoplight Prism** | 4010 | HTTP | Reads `spec/openapi.json`, serves schema-valid mock responses |
| **Node.js Shim** | 9440 | HTTPS | Stateful VM CRUD, task lifecycle simulation, seed data, Nutanix v4 response format with `$objectType` discriminators |
| **Terraform** | — | — | Utility container (not long-running). Pre-loaded with Nutanix provider v2.2.1 via filesystem mirror |

The shim handles VM, task, cluster, subnet, image, and storage-container routes.
All unmatched routes are proxied to Prism for schema-based mocking.

## Terraform Container

The Terraform container (`docker compose run --rm terraform <cmd>`) includes:

- **Terraform CLI 1.9.8**
- **Nutanix provider v2.2.1** — pre-downloaded from GitHub releases and stored in a filesystem mirror at `/terraform/providers/`
- **Provider resolution** — the `terraform.rc` CLI config forces the Nutanix provider to resolve from the local mirror (no registry calls needed after image build)
- **Workspace volume** — the `./terraform` directory is mounted to `/workspace`, so `.terraform`, lock files, and state persist across container runs

```bash
# Common commands
docker compose run --rm terraform init
docker compose run --rm terraform plan
docker compose run --rm terraform apply -auto-approve
docker compose run --rm terraform destroy -auto-approve
docker compose run --rm terraform state list
docker compose run --rm terraform output

# Debug with full logging
docker compose run --rm -e TF_LOG=DEBUG terraform apply -auto-approve 2>&1 | tee debug.log
```

## Seed Reference Data

Pre-seeded UUIDs available in every emulator instance:

| Resource | extId | Name |
|----------|-------|------|
| Cluster | `00000000-0000-0000-0000-000000000001` | emulator-cluster |
| Subnet | `00000000-0000-0000-0000-000000000002` | emulator-primary-subnet |
| Image | `00000000-0000-0000-0000-000000000003` | emulator-ubuntu-2204 |
| Image | `00000000-0000-0000-0000-000000000004` | emulator-centos-9 |
| Storage Container | `00000000-0000-0000-0000-000000000005` | emulator-default-container |

## API Endpoints

All paths support multiple version prefixes:
- `/api/{ns}/v4.0.a1/config/{res}`
- `/api/{ns}/v4.0/config/{res}`
- `/api/{ns}/v4.0/ahv/config/{res}` ← used by Nutanix provider v2.2.1

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/vmm/v*/config/vms` | Create VM → returns task |
| `GET` | `/api/vmm/v*/config/vms` | List VMs |
| `GET` | `/api/vmm/v*/config/vms/{extId}` | Get VM |
| `PUT` | `/api/vmm/v*/config/vms/{extId}` | Update VM → returns task |
| `DELETE` | `/api/vmm/v*/config/vms/{extId}` | Delete VM → returns task |
| `POST` | `/api/vmm/v*/config/vms/{extId}/power-state/{action}` | Power on/off/reset |
| `GET` | `/api/prism/v*/config/tasks/{extId}` | Get task status |
| `GET` | `/api/cluster-mgmt/v*/config/clusters` | List clusters |
| `GET` | `/api/networking/v*/config/subnets` | List subnets |
| `GET` | `/api/vmm/v*/config/images` | List images |
| `GET` | `/api/vmm/v*/config/storage-containers` | List storage containers |

## Response Format

The emulator returns Nutanix v4 API responses with `$objectType` discriminators
and `$reserved` version annotations:

```json
{
  "data": {
    "$objectType": "prism.v4.ahv.config.TaskReference",
    "$reserved": {"$fv": "v4.r0"},
    "extId": "7c5a5277-20c9-4cca-a0bc-0c198611dcd3"
  }
}
```

Request bodies are accepted in both `snake_case` (curl/smoke tests) and
`camelCase` (Nutanix Go SDK). Responses are always camelCase.

## Project Structure

```
.
├── docker-compose.yml          # Prism + emulator + terraform services
├── spec/
│   └── openapi.json            # Nutanix v4 VMM OpenAPI 3.0 spec
├── mock/
│   ├── Dockerfile              # Node.js emulator image
│   ├── entrypoint.sh           # Wait-for-prism + TLS cert generation
│   ├── package.json
│   └── server.js               # Stateful shim (Express, HTTPS)
├── terraform/
│   ├── Dockerfile              # Terraform image with Nutanix provider mirror
│   ├── terraform.rc            # CLI config for local provider mirror
│   ├── versions.tf             # Provider v2.2.1, Terraform ~> 1.9
│   ├── variables.tf            # Input variables with emulator defaults
│   ├── main.tf                 # nutanix_virtual_machine_v2 resource
│   └── terraform.tfvars.example
├── scripts/
│   └── smoke-test.sh           # Curl-based integration test (14 checks)
└── README.md
```

## Known Limitations

- **Terraform apply → provider crash**: The Nutanix provider v2.2.1 SDK crashes
  when parsing the emulator's create-VM response. This is because the SDK's
  `OneOfCreateVmApiResponseData.UnmarshalJSON` uses `$objectType` discriminators
  that must exactly match the generated SDK model. Resolve this by:
  1. Run with `TF_LOG=DEBUG` to see the exact response the provider receives
  2. Compare against real Prism Central responses (or SDK source at
     `ntnx-api-golang-clients/vmm-go-client/v4/models/vmm/v4/ahv/config/`)
  3. Update `mock/server.js` response `$objectType` and structure to match

- **No real Nutanix semantics**: The emulator validates API contracts, not
  Nutanix business logic (async workflow constraints, UUID relationships,
  cluster validations).

- **In-memory state**: VM state is lost on container restart. Mount a volume
  and add file-based persistence to `server.js` for durable state.

- **Auth is bypassed**: The shim accepts any credentials. Real Prism Central
  uses HTTP Basic auth or JWT tokens.

- **Fixed seed data**: Clusters, subnets, images, and storage containers are
  hardcoded. Edit `mock/server.js` Maps to add or change seed data.
