# Multi-Tenant Implementation via `auth_binding`

## Example values of `auth_binding`

### Seeded defaults (always present)

| Value | Provider | Purpose |
|---|---|---|
| `"aws"` | AWS | Default AWS tenant — the built-in seeded tenant |
| `"nutanix"` | Nutanix | Default Nutanix tenant — the built-in seeded tenant |

These are hardcoded in:
- `identity_service/app/config.py:133-134` → `aws_auth_binding = "aws"`, `ntnx_auth_binding = "nutanix"`
- `libcloud.rest/app/connections/credentials.py:27` → `_PROVIDER_TO_DEFAULT_BINDING = {"aws": "aws", "nutanix": "nutanix"}`

### Multi-tenant examples (created via `scripts/create_tenant.sh`)

| Value | Meaning |
|---|---|
| `"aws-dev"` | A separate AWS dev/sandbox account, isolated from the default `"aws"` tenant |
| `"aws-prod"` | A production AWS account |
| `"aws-staging"` | Staging environment |

These are arbitrary strings — any new tenant gets its own `auth_binding` string, its own OpenFGA tuples, and its own Vault path `secret/data/libcloud/<auth_binding>`.

### In practice — what a client sends

```json
// Default AWS tenant
{"provider": "aws", "config": {"region": "ap-southeast-1"}, "auth_binding": "aws"}

// Default Nutanix tenant
{"provider": "nutanix", "config": {"host": "...", "port": 9440}, "auth_binding": "nutanix"}

// A separate dev AWS tenant (multi-tenant)
{"provider": "aws", "config": {"region": "us-east-1"}, "auth_binding": "aws-dev"}
```

### How it resolves

```
auth_binding: "aws"       → OpenFGA object: aws_region:aws
                          → Vault path:     secret/data/libcloud/aws

auth_binding: "aws-dev"   → OpenFGA object: aws_region:aws-dev
                          → Vault path:     secret/data/libcloud/aws-dev

auth_binding: "nutanix"   → OpenFGA object: nutanix_cluster:nutanix
                          → Vault path:     secret/data/libcloud/nutanix
```

The key point: `auth_binding` is an **arbitrary tenant id string**. The seeded defaults are `"aws"` and `"nutanix"`, but `scripts/create_tenant.sh` can mint new ones like `"aws-dev"`, `"acme-corp"`, etc. — whatever name the tenant gets. There's no enum or fixed list; authorization is enforced by OpenFGA relations, not by a hardcoded allowlist of binding values.
