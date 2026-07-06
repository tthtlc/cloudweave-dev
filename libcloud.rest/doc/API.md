# Libcloud REST API Reference

Base URL (default): `http://localhost:8765`

Interactive docs: `http://localhost:8765/docs`

## Architecture

- Clients authenticate to **this API** with username/password and receive a JWT.
- **Provider credentials are supplied by the client** on every compute/network call inside a `connection` object.
- The server is **stateless** with respect to cloud accounts — it does not store regions, hosts, or provider keys in Docker or on disk.
- The server validates JWT scopes, builds the Libcloud driver from the supplied connection, and proxies the operation.

### Provider connection object

Every compute/network call includes a `connection` object that tells the API which provider to use and how to authenticate:

```json
{
  "provider": "aws",
  "config": {
    "region": "us-east-1",
    "secure": true
  },
  "credentials": {
    "key": "AKIAIOSFODNN7EXAMPLE",
    "secret": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  }
}
```

Nutanix example:

```json
{
  "provider": "nutanix",
  "config": {
    "host": "prism.example.com",
    "port": 9440,
    "secure": true,
    "api_version": "v4.0",
    "verify_ssl_cert": false
  },
  "credentials": {
    "key": "admin",
    "secret": "your-password"
  }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `provider` | `"aws"` \| `"nutanix"` | Yes | Cloud provider |
| `config.region` | string | AWS | AWS region (e.g. `us-east-1`) |
| `config.host` | string | Nutanix | Prism Central hostname |
| `config.port` | int | No | Prism Central port (default `9440`) |
| `config.secure` | bool | No | Use HTTPS (default `true`) |
| `config.api_version` | string | No | Nutanix API version (default `v4.0`) |
| `config.verify_ssl_cert` | bool | No | Verify TLS certificate (Nutanix) |
| `credentials.key` | string | Yes | AWS access key ID or Nutanix username |
| `credentials.secret` | string | Yes | AWS secret access key or Nutanix password |

### How to pass `connection`

| Request type | Where to put `connection` |
|--------------|---------------------------|
| **GET / DELETE** | `connection` query parameter — URL-encoded JSON |
| **POST / PATCH** | `"connection": { ... }` field in the JSON body |

Helper (bash) to build a query parameter for AWS:

```bash
CONNECTION=$(python3 -c "
import json, os, urllib.parse
conn = {
    'provider': 'aws',
    'config': {'region': os.environ.get('AWS_REGION', 'us-east-1'), 'secure': True},
    'credentials': {
        'key': os.environ['LIBCLOUD_AWS_PROD_KEY'],
        'secret': os.environ['LIBCLOUD_AWS_PROD_SECRET'],
    },
}
print(urllib.parse.quote(json.dumps(conn, separators=(',', ':'))))
")
```

Python clients can use `clients/common/connection.py`:

```python
from clients.common.connection import aws_connection, nutanix_connection, encode_connection

conn = aws_connection(region="us-east-1")
# GET:  ?connection=<encode_connection(conn)>
# POST: {"connection": conn, ...}
```

---

## Authentication

### 1. Login

```bash
curl -s -X POST http://localhost:8765/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{
    "username": "admin",
    "password": "changeme",
    "requested_scopes": [
      "compute:read",
      "compute:node:create",
      "compute:node:delete",
      "compute:node:power",
      "compute:node:update",
      "compute:volume:manage",
      "compute:snapshot:manage",
      "compute:network:read",
      "compute:network:manage",
      "compute:image:read",
      "compute:image:manage",
      "compute:keypair:manage",
      "jobs:read"
    ]
  }'
```

Save `data.access_token` from the response. All protected calls use:

```bash
-H "Authorization: Bearer $TOKEN"
```

JWT tokens include `allowed_providers` (e.g. `["*"]` for unrestricted access). The server checks that `connection.provider` is permitted for the token.

### 2. Other auth endpoints

| Method | Path | Auth | Body |
|--------|------|------|------|
| POST | `/v1/auth/refresh` | No | `{"refresh_token":"..."}` |
| POST | `/v1/auth/logout` | Bearer | `{"refresh_token":"..."}` (optional) |
| GET | `/v1/auth/me` | Bearer | — |
| POST | `/v1/auth/token/introspect` | Bearer (admin) | `{"token":"..."}` |

### Scopes

| Scope | Used for |
|-------|----------|
| `compute:read` | List/get nodes, volumes, networks (read alias) |
| `compute:location:read` | List locations/clusters |
| `compute:image:read` | List images |
| `compute:size:read` | List sizes |
| `compute:node:create` | Create nodes |
| `compute:node:delete` | Delete nodes |
| `compute:node:power` | Start/stop/reboot |
| `compute:node:update` | Update node metadata (Nutanix) |
| `compute:volume:manage` | Volume CRUD, attach/detach |
| `compute:snapshot:manage` | Snapshot create/delete |
| `compute:network:read` | List VPCs, subnets, security groups |
| `compute:network:manage` | Create/update/delete networking |
| `compute:image:manage` | Create/delete images |
| `compute:keypair:manage` | Key pair CRUD (AWS) |
| `jobs:read` | Poll async jobs |
| `admin:connections:read` | Token introspection |

---

## Response format

**Success:**

```json
{
  "data": { },
  "meta": { "request_id": "req_..." }
}
```

**Error:**

```json
{
  "error": {
    "code": "auth_insufficient_scope",
    "message": "...",
    "details": { }
  },
  "meta": { "request_id": "req_..." }
}
```

Common error codes: `invalid_connection` (400), `auth_provider_denied` (403), `auth_insufficient_scope` (403).

---

## Platform endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/health` | No | Health check |
| GET | `/v1/providers` | No | List supported providers |
| POST | `/v1/connections:test` | Bearer | Test a client-supplied connection |
| GET | `/v1/jobs/{job_id}` | Bearer | Get async job status |

### Test a connection

```bash
curl -s -X POST http://localhost:8765/v1/connections:test \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "provider": "aws",
    "config": {"region": "us-east-1", "secure": true},
    "credentials": {"key": "AKIA...", "secret": "..."}
  }'
```

---

## Catalog (read-only)

All GET catalog endpoints require `?connection=<url-encoded-json>`.

### Locations / clusters

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8765/v1/compute/locations?connection=${CONNECTION}"
```

### Sizes

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8765/v1/compute/sizes?connection=${CONNECTION}"
```

### Images

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8765/v1/compute/images?connection=${CONNECTION}"
```

### Storage containers (Nutanix only)

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8765/v1/compute/storage-containers?connection=${CONNECTION}"
```

---

## Nodes (VMs / EC2 instances)

| Method | Path | Scope |
|--------|------|-------|
| GET | `/v1/compute/nodes?connection=` | `compute:read` |
| GET | `/v1/compute/nodes/{id}?connection=` | `compute:read` |
| POST | `/v1/compute/nodes` | `compute:node:create` |
| PATCH | `/v1/compute/nodes/{id}` | `compute:node:update` or `compute:node:power` |
| DELETE | `/v1/compute/nodes/{id}?connection=` | `compute:node:delete` |
| POST | `/v1/compute/nodes/{id}:start?connection=` | `compute:node:power` |
| POST | `/v1/compute/nodes/{id}:stop?connection=` | `compute:node:power` |
| POST | `/v1/compute/nodes/{id}:reboot?connection=` | `compute:node:power` |

Node responses include `provider` and `target` (e.g. `aws:us-east-1`) instead of a server-side connection ID.

### Provision Nutanix VM

```bash
curl -s -X POST http://localhost:8765/v1/compute/nodes \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "connection": {
      "provider": "nutanix",
      "config": {
        "host": "prism.example.com",
        "port": 9440,
        "secure": true,
        "api_version": "v4.0",
        "verify_ssl_cert": false
      },
      "credentials": {"key": "admin", "secret": "password"}
    },
    "name": "web-01",
    "size": {"id": "small"},
    "image": {"id": "IMAGE_EXT_ID"},
    "location": {"id": "CLUSTER_EXT_ID"},
    "network": {"subnet_id": "SUBNET_EXT_ID"},
    "provider_options": {
      "ex_description": "Demo VM",
      "ex_disk_size_mib": 20480,
      "ex_storage_container": "STORAGE_CONTAINER_EXT_ID"
    }
  }'
```

### Provision AWS EC2 instance

```bash
curl -s -X POST http://localhost:8765/v1/compute/nodes \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "connection": {
      "provider": "aws",
      "config": {"region": "us-east-1", "secure": true},
      "credentials": {"key": "AKIA...", "secret": "..."}
    },
    "name": "web-01",
    "size": {"id": "t3.micro"},
    "image": {"id": "ami-0123456789abcdef0"},
    "network": {
      "subnet_id": "subnet-0123456789abcdef0",
      "public_ip": true
    },
    "auth": {"type": "key_pair", "key_name": "my-key"},
    "tags": {"env": "dev", "owner": "platform"}
  }'
```

### Update Nutanix VM

```bash
curl -s -X PATCH http://localhost:8765/v1/compute/nodes/VM_EXT_ID \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "connection": {
      "provider": "nutanix",
      "config": {"host": "prism.example.com", "port": 9440},
      "credentials": {"key": "admin", "secret": "password"}
    },
    "action": "update",
    "name": "web-01-renamed",
    "memory_mib": 4096
  }'
```

### Power actions

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8765/v1/compute/nodes/NODE_ID:stop?connection=${CONNECTION}"
```

### Delete node

```bash
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8765/v1/compute/nodes/NODE_ID?connection=${CONNECTION}"
```

---

## Networks (VPC)

| Method | Path | Scope |
|--------|------|-------|
| GET | `/v1/compute/networks?connection=` | `compute:network:read` |
| GET | `/v1/compute/networks?connection=&id=` | `compute:network:read` |
| POST | `/v1/compute/networks` | `compute:network:manage` |
| PATCH | `/v1/compute/networks/{id}` | `compute:network:manage` |
| DELETE | `/v1/compute/networks/{id}?connection=` | `compute:network:manage` |

POST/PATCH bodies include `"connection": { ... }` alongside resource fields. GET/DELETE use the `connection` query parameter.

---

## Subnets, volumes, snapshots, images, key pairs, security groups, load balancers

Same pattern as nodes and networks:

- **GET / DELETE** — `?connection=<url-encoded-json>`
- **POST / PATCH** — `"connection": { ... }` in the JSON body

See interactive docs at `/docs` for full request schemas per endpoint.

---

## Async jobs

Long-running creates accept `"execution": {"mode": "async"}` in the request body. Poll with:

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8765/v1/jobs/job_abc123"
```

Job records use `connection_target` (e.g. `aws:us-east-1`) instead of a connection ID. Credentials in stored job payloads are redacted.

Supported async operations: `create_node`, `create_volume`, `destroy_node`, `create_snapshot`, `create_image`.

---

## End-to-end provisioning workflows

### AWS

```bash
export BASE=http://localhost:8765
export TOKEN=$(curl -s -X POST $BASE/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"changeme","requested_scopes":["compute:read","compute:network:manage","compute:node:create","compute:volume:manage"]}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["access_token"])')

AWS_CONN='{"provider":"aws","config":{"region":"us-east-1","secure":true},"credentials":{"key":"AKIA...","secret":"..."}}'

# 1. VPC
curl -s -X POST $BASE/v1/compute/networks -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"connection\":$AWS_CONN,\"name\":\"demo-vpc\",\"cidr_block\":\"10.1.0.0/16\"}"

# 2. Subnet, volume, EC2 — same connection object in each POST body
```

### Nutanix

```bash
NTNX_CONN='{"provider":"nutanix","config":{"host":"prism.example.com","port":9440,"secure":true,"api_version":"v4.0","verify_ssl_cert":false},"credentials":{"key":"admin","secret":"..."}}'

curl -s -X POST $BASE/v1/compute/subnets -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"connection\":$NTNX_CONN,\"name\":\"ext-vlan\",\"subnet_type\":\"VLAN\",\"cluster_id\":\"CLUSTER_ID\",\"is_external\":true}"
```

---

## Full endpoint index (44 paths)

| # | Method | Path |
|---|--------|------|
| 1 | GET | `/health` |
| 2 | POST | `/v1/auth/login` |
| 3 | POST | `/v1/auth/refresh` |
| 4 | POST | `/v1/auth/logout` |
| 5 | GET | `/v1/auth/me` |
| 6 | POST | `/v1/auth/token/introspect` |
| 7 | GET | `/v1/providers` |
| 8 | POST | `/v1/connections:test` |
| 9 | GET | `/v1/compute/locations` |
| 10 | GET | `/v1/compute/sizes` |
| 11 | GET | `/v1/compute/images` |
| 12 | POST | `/v1/compute/images` |
| 13 | DELETE | `/v1/compute/images/{image_id}` |
| 14 | GET | `/v1/compute/nodes` |
| 15 | GET | `/v1/compute/nodes/{node_id}` |
| 16 | POST | `/v1/compute/nodes` |
| 17 | PATCH | `/v1/compute/nodes/{node_id}` |
| 18 | DELETE | `/v1/compute/nodes/{node_id}` |
| 19 | POST | `/v1/compute/nodes/{node_id}:start` |
| 20 | POST | `/v1/compute/nodes/{node_id}:stop` |
| 21 | POST | `/v1/compute/nodes/{node_id}:reboot` |
| 22 | GET | `/v1/compute/volumes` |
| 23 | POST | `/v1/compute/volumes` |
| 24 | PATCH | `/v1/compute/volumes/{volume_id}` |
| 25 | DELETE | `/v1/compute/volumes/{volume_id}` |
| 26 | POST | `/v1/compute/volumes/{volume_id}:attach` |
| 27 | POST | `/v1/compute/volumes/{volume_id}:detach` |
| 28 | GET | `/v1/compute/snapshots` |
| 29 | POST | `/v1/compute/snapshots` |
| 30 | DELETE | `/v1/compute/snapshots/{snapshot_id}` |
| 31 | GET | `/v1/compute/key-pairs` |
| 32 | POST | `/v1/compute/key-pairs` |
| 33 | DELETE | `/v1/compute/key-pairs/{name}` |
| 34 | GET | `/v1/compute/networks` |
| 35 | POST | `/v1/compute/networks` |
| 36 | PATCH | `/v1/compute/networks/{network_id}` |
| 37 | DELETE | `/v1/compute/networks/{network_id}` |
| 38 | GET | `/v1/compute/subnets` |
| 39 | POST | `/v1/compute/subnets` |
| 40 | PATCH | `/v1/compute/subnets/{subnet_id}` |
| 41 | DELETE | `/v1/compute/subnets/{subnet_id}` |
| 42 | GET | `/v1/compute/storage-containers` |
| 43 | GET | `/v1/compute/security-groups` |
| 44 | POST | `/v1/compute/security-groups` |
| 45 | DELETE | `/v1/compute/security-groups/{group_id}` |
| 46 | GET | `/v1/compute/load-balancers` |
| 47 | POST | `/v1/compute/load-balancers` |
| 48 | DELETE | `/v1/compute/load-balancers/{lb_id}` |
| 49 | GET | `/v1/jobs/{job_id}` |

All compute/network GET and DELETE endpoints require the `connection` query parameter.
