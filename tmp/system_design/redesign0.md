
OpenFGA is designed exactly for your use case: all authorization data — the model schema, relationship tuples (users, groups, resources, and their relations), and permission configurations — is stored in a **database backend** and managed through a **transactional API**, not files. This directly addresses every concern you raised about dynamic updates, reconfiguration, and scalability. [deepwiki](https://deepwiki.com/openfga/openfga/1-overview)

***

## Architecture Overview

Your cloud portal implementation would consist of three layers: [deepwiki](https://deepwiki.com/openfga/openfga/1-overview)

```
┌─────────────────────────────────────────┐
│         Cloud Portal Application         │
│   (VMs, Networks, Logs, Users, Groups)   │
└──────────────┬──────────────────────────┘
               │ SDK calls (Go/Python/JS)
               ▼
┌─────────────────────────────────────────┐
│           OpenFGA Server                 │
│  (Authorization Model + Tuple Engine)    │
│  Write API · Check API · ListObjects    │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│        Database (PostgreSQL/MySQL)       │
│  Stores: authorization models,           │
│  relationship tuples, stores             │
└─────────────────────────────────────────┘
```

OpenFGA uses a pluggable storage interface (`OpenFGADatastore`) with production-ready backends for PostgreSQL and MySQL. The database holds two categories of data: **authorization models** (versioned schema definitions) and **relationship tuples** (the actual `user → relation → object` mappings). [infoq](https://www.infoq.com/news/2023/05/open-fine-grained-authorization/)

***

## Authorization Model for Your Cloud Portal

This is the DSL model you'd define for users, groups, and cloud resources with role-based access: [openfga](https://openfga.dev/docs/modeling/getting-started)

```
model
  schema 1.1

type user

type group
  relations
    define member: [user, group#member]

type cloud_account
  relations
    define admin: [user, group#member]
    define operator: [user, group#member]
    define viewer: [user, group#member]
    define member: admin or operator or viewer

type vm
  relations
    define parent: [cloud_account]
    define owner: [user, group#member]
    define operator: [user, group#member]
    define viewer: [user, group#member]

    define can_start:       owner or operator or admin from parent
    define can_stop:        owner or operator or admin from parent
    define can_view:        viewer or operator or owner or viewer from parent
    define can_delete:      owner or admin from parent
    define can_update_tags: owner or operator

type network
  relations
    define parent: [cloud_account]
    define admin: [user, group#member]
    define viewer: [user, group#member]

    define can_view:        viewer or admin or viewer from parent
    define can_modify:      admin or admin from parent

type logfile
  relations
    define parent: [vm, network, cloud_account]
    define viewer: [user, group#member]
    define auditor: [user, group#member]

    define can_read:        viewer or auditor or viewer from parent
    define can_export:      auditor
```

Key design points in this model:

- **Roles** (`owner`, `operator`, `viewer`, `admin`, `auditor`) are directly assignable relations on each resource type. [openfga](https://openfga.dev/docs/modeling/roles-and-permissions)
- **Permissions** (`can_start`, `can_stop`, `can_view`, etc.) are computed relations using `or` (union) and `from parent` (tuple-to-userset for hierarchy inheritance). [deepwiki](https://deepwiki.com/grafana/openfga/2.1-authorization-model)
- The `parent` relation on `vm`, `network`, and `logfile` enables hierarchical access — if you're an `admin` on the parent `cloud_account`, you inherit permissions on child resources. [openfga](https://openfga.dev/docs/interacting/managing-relationships-between-objects)
- Groups support nested membership via `group#member` recursive expansion. [deepwiki](https://deepwiki.com/openfga/openfga/1-overview)

***

## Writing Relationship Tuples (Runtime Data)

All user-resource-group assignments are written via the **Write API** as relationship tuples. This is your runtime data — stored in the database, not files: [openfga](https://openfga.dev/docs/getting-started/update-tuples)

```python
# Assign user to a group
await fga_client.write({
    "writes": [
        {"user": "user:alice", "relation": "member", "object": "group:devops"}
    ]
})

# Assign role on a VM
await fga_client.write({
    "writes": [
        {"user": "group:devops#member", "relation": "operator", "object": "vm:web-01"}
    ]
})

# Set parent relationship (hierarchy)
await fga_client.write({
    "writes": [
        {"user": "cloud_account:acct-123", "relation": "parent", "object": "vm:web-01"}
    ]
})
```

The Write API supports atomic writes and deletes in a single transactional request (up to 100 tuples per call), and includes `on_duplicate: "ignore"` and `on_missing: "ignore"` options for bulk imports. [openfga](https://openfga.dev/docs/getting-started/update-tuples)

***

## Why File-Based Updates Are a Bad Design

| Concern | File-Based | OpenFGA API + Database |
|---|---|---|
| **Concurrency** | Race conditions on simultaneous writes; file locks needed | ACID transactions in PostgreSQL/MySQL  [deepwiki](https://deepwiki.com/openfga/openfga/1-overview) |
| **Consistency** | Partial writes leave system in inconsistent state | Atomic batch writes — all succeed or all fail  [openfga](https://openfga.dev/docs/getting-started/update-tuples) |
| **Audit trail** | No built-in audit log; relies on filesystem timestamps | Database-backed with queryable tuple history  [deepwiki](https://deepwiki.com/openfga/openfga/1-overview) |
| **Performance** | File I/O bottleneck under load; no caching | In-memory check cache, fast-path resolution, parallel evaluation  [deepwiki](https://deepwiki.com/openfga/openfga/1-overview) |
| **Validation** | No schema validation on file content | API validates tuples against the authorization model before accepting writes  [deepwiki](https://deepwiki.com/openfga/openfga/1-overview) |
| **Scalability** | Single-node filesystem; no horizontal scaling | Multi-instance OpenFGA servers sharing one database backend  [deepwiki](https://deepwiki.com/openfga/openfga/1-overview) |
| **Access control** | Any process with file access can modify permissions | API-level authentication (bearer tokens, OIDC) gates all mutations  [openfga](https://openfga.dev/docs/getting-started/setup-openfga/configure-openfga) |
| **Distributed access** | Files must be synced across nodes | API is network-accessible via HTTP/gRPC from any service  [deepwiki](https://deepwiki.com/openfga/openfga/1-overview) |

Files are acceptable only for **initial bootstrap or migration** — you can write a script that reads a YAML/JSON file and calls the Write API to load tuples into OpenFGA's database. After that, all mutations go through the API. [openfga](https://openfga.dev/docs/interacting)

***

## Database: Yes, It's Required

OpenFGA **requires** a persistent storage backend for production. The in-memory option is explicitly marked as "not production ready": [infoq](https://www.infoq.com/news/2023/05/open-fine-grained-authorization/)

| Storage Engine | Status | Use Case |
|---|---|---|
| PostgreSQL | Production ready | Recommended for production  [deepwiki](https://deepwiki.com/openfga/openfga/1-overview) |
| MySQL | Production ready | Alternative persistent backend  [deepwiki](https://deepwiki.com/openfga/openfga/1-overview) |
| SQLite | Beta | Single-node or testing  [deepwiki](https://deepwiki.com/openfga/openfga/1-overview) |
| Memory | Dev only | Local development and testing  [deepwiki](https://deepwiki.com/openfga/openfga/1-overview) |

The database stores everything: authorization models (versioned), relationship tuples, and store metadata. There is no separate "configuration file" that holds runtime permission data — it's all in the database. [deepwiki](https://deepwiki.com/openfga/openfga/1-overview)

***

## Dynamic Reconfiguration and Adding New Entities

### Adding New Users, Groups, or Resources

Simply write new tuples via the API — no model change needed: [openfga](https://openfga.dev/docs/interacting)

```python
# New user joins
await fga_client.write({
    "writes": [{"user": "user:charlie", "relation": "member", "object": "group:network-admins"}]
})

# New VM created in portal
await fga_client.write({
    "writes": [
        {"user": "cloud_account:acct-456", "relation": "parent", "object": "vm:db-01"},
        {"user": "group:dba#member", "relation": "owner", "object": "vm:db-01"}
    ]
})

# Grant viewer access to a logfile
await fga_client.write({
    "writes": [{"user": "user:dave", "relation": "viewer", "object": "logfile:vm-web-01-syslog"}]
})
```

### Adding New Relations or Permissions

When you need finer-grained permissions (e.g., `can_snapshot` on VMs, or a new `auditor` role on networks), you push a **new versioned authorization model** via the API: [openfga](https://openfga.dev/docs/modeling/migrating)

```python
# Push new model version
new_model = """
model
  schema 1.1

type vm
  relations
    define parent: [cloud_account]
    define owner: [user, group#member]
    define operator: [user, group#member]
    define viewer: [user, group#member]

    define can_start:       owner or operator or admin from parent
    define can_stop:        owner or operator or admin from parent
    define can_view:        viewer or operator or owner or viewer from parent
    define can_delete:      owner or admin from parent
    define can_update_tags: owner or operator
    define can_snapshot:    owner or operator        # NEW
    define can_resize:     owner or admin from parent # NEW
"""

await fga_client.write_authorization_model(new_model)
```

Key properties of model versioning: [openfga](https://openfga.dev/docs/modeling/migrating)

- Old model remains active until you explicitly switch — existing tuples are preserved across model versions.
- You can specify `authorization_model_id` per API call, allowing gradual rollout (e.g., canary a new model on one service while others use the old one). [openfga](https://openfga.dev/docs/getting-started/tuples-api-best-practices)
- The model is validated upon creation to ensure it's well-formed and can be evaluated efficiently. [deepwiki](https://deepwiki.com/openfga/openfga/1-overview)

### Full Reconfiguration

Every aspect is reconfigurable at runtime through the API: [openfga](https://openfga.dev/docs/interacting)

| What | How | Downtime |
|---|---|---|
| Add/remove user access | Write/Delete tuples | None |
| Add/remove group membership | Write/Delete tuples | None |
| Add/remove resource hierarchy | Write/Delete `parent` tuples | None |
| Add new permission | Push new model version, switch `authorization_model_id` | None (gradual rollout) |
| Rename a relation | Push new model with migration strategy  [openfga](https://openfga.dev/docs/modeling/migrating) | None (dual-write period) |
| Add entirely new resource type | Push new model version with new `type` block | None |

***

## End-to-End Check Flow

When your portal needs to authorize an action, it calls the **Check API**: [deepwiki](https://deepwiki.com/openfga/openfga/1-overview)

```python
response = await fga_client.check({
    "user": "user:alice",
    "relation": "can_start",
    "object": "vm:web-01"
})
# response.allowed == True/False
```

Internally, OpenFGA's `CheckResolver` traverses the `RelationshipGraph` — following group membership expansion, parent hierarchy inheritance, and computed relation rewrites — to determine the boolean result, all backed by database queries with multi-layer caching. [deepwiki](https://deepwiki.com/openfga/openfga/1-overview)

***

## Recommended Deployment

For your cloud portal in production:

1. **OpenFGA server** deployed as a container (Docker/Kubernetes) with PostgreSQL as the datastore. [deepwiki](https://deepwiki.com/openfga/openfga/1-overview)
2. **Portal backend** uses the OpenFGA SDK (Go, Python, or Node.js) to call Check/Write/ListObjects APIs. [github](https://github.com/openfga/js-sdk)
3. **Bootstrap script** reads an initial YAML file of users/groups/resources and calls the Write API to seed the database — this is the only time files are involved. [openfga](https://openfga.dev/docs/interacting)
4. **All subsequent changes** (new users, new resources, role changes, permission refinements) go through the API, which persists to PostgreSQL with ACID guarantees. [openfga](https://openfga.dev/docs/getting-started/update-tuples)
5. **Model evolution** is managed through versioned model pushes, with the ability to run old and new models simultaneously during migration. [openfga](https://openfga.dev/docs/getting-started/tuples-api-best-practices)

***

One thing to consider as you plan the implementation: how will your portal's resource lifecycle (VM creation/deletion, network provisioning) synchronize with OpenFGA tuple writes — will you use a webhook/event-driven approach where cloud resource creation events trigger tuple writes, or will the portal application code write tuples inline during resource provisioning?
