
https://www.perplexity.ai/search/e7a74699-25d8-478b-b029-56fdc6d750ee

Now I have all the research needed to compile the comprehensive framework document. Let me present it below.

***

# Multi-Cloud Governance and Security Framework for CMP

This document specifies the governance and security architecture for the CMP's brokered control plane, covering centralized secrets management via HashiCorp Vault, fine-grained authorization via OpenFGA, a unified resource integration matrix across AWS/Nutanix/vSphere, an audit logging strategy, and policy-driven workflows for provisioning, rightsizing, and cost attribution in multi-tenant environments.

***

## Centralized Secrets Management (HashiCorp Vault Integration)

### Vault Architecture for Multi-Cloud CMP

The CMP's Vault deployment follows HashiCorp's validated pattern for hybrid and multi-cloud environments: a **performance replication (PR) primary cluster** in the primary cloud (AWS), with PR secondary clusters in each additional cloud or datacenter (Nutanix on-prem, vSphere). Each PR secondary cluster manages its own tokens and leases, serves read traffic locally, and forwards write traffic to the primary—reducing latency for Nutanix/vSphere consumers while maintaining a single source of truth. [developer.hashicorp](https://developer.hashicorp.com/validated-patterns/vault/extend-vault-enterprise-for-hybrid-and-multi-cloud-deployments)

A minimum of **four Vault clusters** are deployed in pairs: primary + DR secondary in Cloud A (AWS), and PR secondary + DR secondary in Cloud B (Nutanix/vSphere on-prem). HashiCorp strongly recommends localizing DR to the same cloud to ensure consistent network conditions during failover. [developer.hashicorp](https://developer.hashicorp.com/validated-patterns/vault/extend-vault-enterprise-for-hybrid-and-multi-cloud-deployments)

### Secrets Consumption Model

| Secret Category | Vault Secrets Engine | Path Structure | Rotation Policy |
|---|---|---|---|
| Cloud provider credentials (root/long-lived) | KV v2 (static) | `secret/cmp/aws/`, `secret/cmp/nutanix/`, `secret/cmp/vsphere/` | 90-day automated rotation |
| Dynamic cloud credentials (per-request) | AWS (STS), Database | `aws/roles/cmp-tenant-{id}` | Short-lived (1-hour TTL) |
| Terraform state encryption keys | Transit | `transit/encrypt/tfstate-tenant-{id}` | Key versioning, auto-rotate annually |
| Database credentials (CMP internal) | Database (PostgreSQL) | `database/creds/cmp-readonly`, `database/creds/cmp-admin` | Dynamic, 30-min TTL |
| PKI/TLS certificates | PKI | `pki/issue/cmp-internal`, `pki/issue/tenant-{id}` | 90-day cert TTL |
| Provider adapter API keys | KV v2 | `secret/cmp/providers/{provider}/api-key` | 60-day rotation |
| KMIP-managed keys (cross-cloud) | KMIP secrets engine | `kmip/` | Centralized lifecycle via Vault KMIP server  [hashicorp](https://www.hashicorp.com/en/products/vault/use-cases/multi-cloud-key-management) |

### Vault Namespace Hierarchy for Multi-Tenancy

Vault Enterprise namespaces provide tenant isolation with path filtering per cloud: [developer.hashicorp](https://developer.hashicorp.com/validated-patterns/vault/extend-vault-enterprise-for-hybrid-and-multi-cloud-deployments)

```
Vault Root Namespace
├── namespace: cmp-platform/          # Platform operator secrets
│   ├── secret/cmp/platform-db-creds
│   └── secret/cmp/semaphore-api-token
├── namespace: tenant-{tenant_id}/   # Per-tenant isolation
│   ├── secret/tenant/aws-credentials
│   ├── secret/tenant/vsphere-credentials
│   ├── aws/roles/tenant-{tenant_id}  # Dynamic STS roles
│   ├── database/creds/tenant-{tenant_id}-db
│   ├── transit/encrypt/tenant-{tenant_id}
│   └── pki/issue/tenant-{tenant_id}
```

Path filters on PR secondary clusters replicate only the namespaces relevant to that cloud region, minimizing cross-cloud replication traffic. For data sovereignty requirements (relevant in Singapore/GDPR contexts), **local mounts** on Nutanix/vSphere clusters store secrets that must not leave the on-prem boundary. [developer.hashicorp](https://developer.hashicorp.com/validated-patterns/vault/extend-vault-enterprise-for-hybrid-and-multi-cloud-deployments)

### CMP–Vault Integration Points

1. **Provider adapter layer**: Adapters request dynamic credentials from Vault per provisioning request—never storing static cloud credentials in the CMP database.
2. **Terraform execution**: SemaphoreUI retrieves cloud credentials and state encryption keys from Vault at task execution time, using short-lived tokens.
3. **API gateway middleware**: The CMP API gateway authenticates against Vault using Kubernetes service account JWT (if CMP runs on K8s) or AppRole, obtaining a Vault token scoped to the requesting tenant's namespace. [developer.hashicorp](https://developer.hashicorp.com/vault/tutorials/secrets-management)
4. **Key management**: Vault's key management secrets engine distributes and rotates cryptographic keys across AWS KMS, Nutanix Karbon, and vSphere TPM from one centralized workflow. [hashicorp](https://www.hashicorp.com/en/products/vault/use-cases/multi-cloud-key-management)

### Secret Rotation & Revocation

- **Automated rotation**: KV v2 secrets use Vault's built-in rotation with versioned access—old versions remain readable during grace period for in-flight requests. [developer.hashicorp](https://developer.hashicorp.com/vault/tutorials/secrets-management)
- **Dynamic credentials (AWS STS)**: Leases auto-expire; no manual revocation needed. The CMP sets TTL to 1 hour, with renewal handled by the Vault agent sidecar. [developer.hashicorp](https://developer.hashicorp.com/vault/tutorials/secrets-management)
- **Emergency revocation**: Platform operators can revoke all leases for a tenant instantly via `vault lease revoke -prefix aws/roles/tenant-{id}`, cutting off all cloud access in seconds.
- **Audit**: All Vault access is logged via Vault's built-in audit device to a separate immutable storage backend. [developer.hashicorp](https://developer.hashicorp.com/validated-patterns/vault/extend-vault-enterprise-for-hybrid-and-multi-cloud-deployments)

***

## Fine-Grained Authorization (OpenFGA ReBAC Model)

### Why ReBAC Over RBAC

Traditional RBAC cannot express the multi-tenant, hierarchical resource relationships required by the CMP. A user may be a `viewer` on one VM but an `operator` on another, within the same project, under the same tenant. OpenFGA implements Google's Zanzibar model, where access is determined by **relationships between entities** (users, groups, resources, and parent resources) rather than static role assignments. ReBAC is a superset of RBAC and natively covers ABAC scenarios when attributes are expressed as relationships. [openfga](https://openfga.dev/docs/authorization-concepts)

### Authorization Model (OpenFGA DSL)

```
model
  schema 1.2

type user

type group
  relations
    define member: [user, group#member]

type tenant
  relations
    define admin: [user, group#member] from admin
    define member: [user, group#member]
    define project: [project]
    define cloud_credential: [cloud_credential]

type project
  relations
    define parent: [tenant]
    define owner: [user, group#member] from parent
    define editor: [user, group#member] from parent
    define viewer: [user, group#member] from parent
    define resource: [virtual_machine, storage_volume, network, database_instance]

type virtual_machine
  relations
    define parent: [project]
    define owner: [user, group#member] from parent
    define operator: [user, group#member] from parent
    define viewer: [user, group#member] from parent
    define can_start: operator or owner
    define can_stop: operator or owner
    define can_resize: owner
    define can_delete: owner
    define can_view: viewer or operator or owner
    define can_tag: operator or owner
```

### Relationship Tuple Examples

| Tuple | Meaning |
|---|---|
| `tenant:acme#admin@user:alice` | Alice is a tenant admin for Acme |
| `tenant:acme#member@group:devops#member` | DevOps group members are members of Acme tenant |
| `project:proj-123#parent@tenant:acme` | proj-123 belongs to tenant Acme |
| `project:proj-123#editor@user:bob` | Bob is an editor of proj-123 (direct assignment) |
| `virtual_machine:vm-456#parent@project:proj-123` | vm-456 belongs to proj-123 |
| `virtual_machine:vm-456#operator@user:carol` | Carol is an operator on vm-456 (direct, overriding inherited) |

Inheritance flows through the graph: if Bob is an `editor` of `project:proj-123`, and `virtual_machine:vm-456#parent@project:proj-123`, then OpenFGA resolves that Bob is an `operator` on vm-456 through the project hierarchy—no explicit tuple needed. [medium](https://medium.com/@anil.goyal0057/fine-grained-authorization-with-openfga-beyond-rbac-366373567889)

### Enforcement Points in the CMP

| Enforcement Point | What is Checked | OpenFGA Check |
|---|---|---|
| API gateway (request entry) | Is the user a member of the tenant in context? | `Check(tenant:{id}, member, user:{id})` |
| Resource listing | Which resources can the user see? | `ListObjects(project:{id}, viewer, user:{id})` |
| VM provisioning request | Can the user create VMs in this project? | `Check(project:{id}, editor, user:{id})` |
| VM start/stop operation | Can the user operate this specific VM? | `Check(virtual_machine:{id}, can_start, user:{id})` |
| VM deletion | Can the user delete this VM? | `Check(virtual_machine:{id}, can_delete, user:{id})` |
| Cost report access | Can the user view this tenant's costs? | `Check(tenant:{id}, member, user:{id})` |
| Policy management | Can the user create/modify governance policies? | `Check(tenant:{id}, admin, user:{id})` |

### Synchronization Strategy

The CMP's primary database (PostgreSQL) is the system of record for resource hierarchies. When a resource is created, moved, or deleted, the CMP writes a relationship tuple to OpenFGA via its API. OpenFGA runs as a dedicated authorization microservice, decoupled from application logic, ensuring separation of concerns and centralized audit of all access decisions. [youtube](https://www.youtube.com/watch?v=sHL5aXHdcUE)

***

## Resource Integration Matrix

The following matrix maps heterogeneous cloud resources to a **unified canonical model** that the CMP uses internally, enabling a single pane of glass across all providers.

| Resource Type | AWS | Nutanix | vSphere | Unified Model | Inventory Sync | Cost Source |
|---|---|---|---|---|---|---|
| Virtual Machine | EC2 Instance | Nutanix VMM v4 VM | vSphere Managed VM | `VirtualMachine` | Poll 15 min  | Cost Explorer API |
| Storage Volume | EBS Volume | Volume Group | VMDK | `StorageVolume` | Poll 15 min | Cost Explorer API |
| Network (VPC) | VPC + Subnets | Subnet + VLAN | Port Group / DVS | `Network` | Poll 30 min | Allocation tag |
| Load Balancer | ELB / ALB / NLB | Nutanix Flow LB | NSX Load Balancer | `LoadBalancer` | Poll 30 min | Cost Explorer API |
| Database | RDS Instance | Nutanix Era DB | VM with DB | `DatabaseInstance` | Poll 1 hour | Cost Explorer API |
| Object Storage | S3 Bucket | Nutanix Objects | Datastore | `ObjectStorage` | Poll 1 hour | Cost Explorer API |
| Security Group | AWS Security Group | Flow Security Policy | Firewall Rules | `SecurityPolicy` | Event-driven | Governance only |
| IAM Identity | IAM Role / User | RBAC Role | Role/Permission | `CloudIdentity` | Poll 1 hour | Governance only |
| Encryption Key | KMS Key | Karbon / Vault | TPM / Vault | `EncryptionKey` | Vault-managed  [hashicorp](https://www.hashicorp.com/en/products/vault/use-cases/multi-cloud-key-management) | Vault billing |
| Resource Tag | Resource Tag | Category + Value | Custom Attribute | `ResourceTag` | Synced with inventory | Allocation tag |
| IP Address | Elastic IP | Nutanix IPAM | IP Assignment | `IPAddress` | Poll 30 min | Allocation tag |
| Snapshot/Backup | AWS Snapshot | Protection Domain | vSphere Snapshot | `BackupSnapshot` | Event + poll | Cost Explorer API |

The full matrix is also available as a downloadable CSV file .

### Canonical Resource Model (ERD)

```
UnifiedResource (abstract)
├── id: UUID (CMP-generated)
├── canonical_type: enum (VirtualMachine, StorageVolume, ...)
├── tenant_id: UUID (FK → Tenant)
├── project_id: UUID (FK → Project)
├── provider: enum (aws, nutanix, vsphere)
├── provider_resource_id: string (native ID, e.g., i-0abc1234)
├── provider_region: string
├── canonical_attributes: JSONB (normalized fields)
├── provider_raw_attributes: JSONB (original API response)
├── tags: JSONB ({key: value, ...})
├── cost_per_hour: decimal (normalized to USD)
├── state: enum (provisioning, running, stopped, terminated, error)
├── discovered_at: timestamp
└── last_synced_at: timestamp
```

### Inventory Reconciliation Pipeline

1. **Discovery poll**: Provider adapters poll cloud APIs at the intervals specified above, fetching resource lists and configurations.
2. **Normalization**: Raw API responses are mapped to the canonical model via adapter-specific transformers.
3. **Diff & reconcile**: CMP compares discovered state against its inventory database—new resources are registered, deleted resources are marked `terminated`, changed attributes trigger drift events.
4. **Event emission**: Drift events are published to the event bus for policy evaluation, cost re-calculation, and audit logging.
5. **Tag enforcement**: During reconciliation, resources missing mandatory tags are flagged for policy violation alerts.

***

## Audit Logging Strategy

### Audit Architecture

A multi-cloud audit strategy must collect, normalize, and store logs from all sources in one place, preserve original logs for forensic accuracy, and enrich them with context for faster triage. [hoop](https://hoop.dev/blog/best-practices-for-managing-multi-cloud-audit-logs)

```
┌─────────────┐  ┌──────────────┐  ┌─────────────────┐
│ CMP Audit   │  │ Vault Audit  │  │ Cloud Provider   │
│ Events      │  │ Device       │  │ CloudTrail/Flow  │
│ (app-level) │  │ (secret access)│ │ (infra-level)    │
└──────┬──────┘  └──────┬───────┘  └────────┬────────┘
       │                │                    │
       └────────┬───────┴────────────────────┘
                ▼
        ┌───────────────┐
        │ Audit Pipeline│  (Fluentd/Vector)
        │ Normalize +   │  Parse, enrich with tenant_id,
        │ Enrich        │  project_id, user_id context
        └───────┬───────┘
                │
        ┌───────┴───────┐
        ▼               ▼
  ┌──────────┐  ┌──────────────┐
  │ Hot Store │  │ Cold Archive │
  │ (30 days) │  │ (7 years)    │
  │ Elastic/  │  │ S3 Glacier /  │
  │ OpenSearch│  │ Nutanix obj   │
  │           │  │ (write-once)  │
  └──────────┘  └──────────────┘
```

### Audit Event Schema

| Field | Type | Description |
|---|---|---|
| `event_id` | UUIDv7 | Globally unique, time-sortable |
| `timestamp` | ISO 8601 | UTC, sub-millisecond precision |
| `tenant_id` | UUID | Tenant context (null for platform events) |
| `actor_id` | UUID | User or service identity |
| `actor_type` | enum | `user`, `service`, `system` |
| `action` | string | e.g., `vm.provision`, `vm.start`, `secret.read`, `policy.violation` |
| `resource_type` | string | Canonical resource type |
| `resource_id` | string | CMP resource UUID or provider resource ID |
| `provider` | enum | `aws`, `nutanix`, `vsphere`, `cmp` |
| `request_id` | UUID | Correlates to API request trace |
| `source_ip` | string | Originating IP |
| `authz_decision` | enum | `allow`, `deny` |
| `authz_reason` | string | OpenFGA relation that granted/denied access |
| `outcome` | enum | `success`, `failure`, `error` |
| `raw_payload` | JSONB | Original request/response for forensic replay |

### Audit Data Sources & Collection

| Source | Collection Method | What is Captured |
|---|---|---|
| CMP application logs | Structured JSON via application logger → Fluentd | All user actions, API calls, policy evaluations, provisioning workflow steps |
| Vault audit device | File or syslog audit device → Fluentd | All secret reads, writes, lease grants/revocations, login events  [developer.hashicorp](https://developer.hashicorp.com/validated-patterns/vault/extend-vault-enterprise-for-hybrid-and-multi-cloud-deployments) |
| AWS CloudTrail | S3 notification → Fluentd | All AWS API calls (EC2, IAM, KMS, Cost Explorer) |
| Nutanix audit logs | Prism API → Fluentd poll | VM lifecycle operations, category changes, user logins |
| vSphere events | vSphere API (EventManager) → Fluentd poll | VM power operations, configuration changes, login events |
| OpenFGA decision logs | OpenFGA API → Fluentd | All authorization check requests and decisions  [openfga](https://openfga.dev/docs/authorization-concepts) |
| SemaphoreUI task logs | API → Fluentd | Terraform plan/apply execution logs, task status changes |

### Audit Principles

- **Immutability**: Cold archive uses write-once (WORM) storage in S3 Glacier or Nutanix Objects with object-lock, preventing tampering. [hoop](https://hoop.dev/blog/best-practices-for-managing-multi-cloud-audit-logs)
- **Normalization**: All events are parsed into the unified schema above, but the `raw_payload` field preserves the original log for forensic accuracy. [hoop](https://hoop.dev/blog/best-practices-for-managing-multi-cloud-audit-logs)
- **Real-time alerting**: Anomaly detection rules (e.g., rapid secret access from unusual IPs, mass resource deletion, denied authorization attempts spike) trigger immediate alerts via the CMP alerting pipeline. [hoop](https://hoop.dev/blog/best-practices-for-managing-multi-cloud-audit-logs)
- **Long-term retention**: Hot store retains 30 days for active querying; cold archive retains 7 years to meet compliance frameworks (SOC 2, ISO 27001). [hoop](https://hoop.dev/blog/best-practices-for-managing-multi-cloud-audit-logs)
- **Access control**: Audit log access is itself audited—only `tenant:admin` can view their tenant's logs, and platform audit logs are restricted to `platform:admin` role. [hoop](https://hoop.dev/blog/best-practices-for-managing-multi-cloud-audit-logs)

***

## Policy-Driven Workflow: Resource Provisioning

### Workflow Overview

```
User Request → AuthZ Check → Catalog Resolution → Policy Validation (OPA)
     → Terraform Plan → Policy Validation (Post-Plan OPA) → Approval Gate
     → Vault Credential Retrieval → Terraform Apply → Resource Registration
     → Tag Enforcement → Cost Attribution → Audit Event Chain
```

### Detailed Steps

**1. Request Submission**
- User submits a provisioning request via the portal (e.g., "Create Standard Linux VM in AWS, project: proj-123").
- API gateway authenticates via OIDC (Keycloak/Authentik), then checks OpenFGA: `Check(project:proj-123, editor, user:{id})`. [openfga](https://openfga.dev/docs/authorization-concepts)

**2. Catalog Resolution**
- The request references a catalog item (e.g., `catalog:std-linux-vm-v1.2`), which is an immutable, versioned blueprint mapping to a Terraform module. [perplexity](https://www.perplexity.ai/search/7be5a413-7556-4f00-a1b3-252537af0d8d)
- The CMP resolves the catalog item to its Terraform module reference, input variables, and provider target.

**3. Pre-Plan Policy Validation (OPA Gate #1)**
- OPA evaluates the request against policy rules before any Terraform execution: [aws.amazon](https://aws.amazon.com/blogs/security/governing-infrastructure-as-code-using-pattern-based-policy-as-code/)

```rego
package cmp.provisioning

# Deny if tenant has exceeded VM quota
deny[msg] {
    input.tenant_id == tenant_id
    count(current_vms) >= tenant_quota
    msg := sprintf("Tenant %s has reached VM quota (%d)", [tenant_id, tenant_quota])
}

# Deny if requested instance type is not in allowed list
deny[msg] {
    not allowed_instance_types[input.instance_type]
    msg := sprintf("Instance type %s is not approved", [input.instance_type])
}

# Deny if mandatory tags are missing
deny[msg] {
    required_tags := {"tenant", "project", "environment", "owner"}
    missing := {t | required_tags[t]; not input.tags[t]}
    count(missing) > 0
    msg := sprintf("Missing required tags: %v", [missing])
}

# Deny if project budget would be exceeded
deny[msg] {
    projected_monthly_cost > project_budget * 1.0
    msg := sprintf("Projected cost exceeds project budget (budget: %.2f, projected: %.2f)", [project_budget, projected_monthly_cost])
}
```

**4. Terraform Plan Execution**
- SemaphoreUI executes `terraform plan` using the catalog item's module, with credentials retrieved from Vault at runtime.
- The plan output (JSON format) is captured and returned to the CMP for post-plan validation.

**5. Post-Plan Policy Validation (OPA Gate #2)**
- OPA evaluates the Terraform plan output against deeper policy rules—this catches issues only visible after Terraform resolves the actual resource graph: [aws.amazon](https://aws.amazon.com/blogs/security/governing-infrastructure-as-code-using-pattern-based-policy-as-code/)

```rego
package cmp.post_plan

# Deny if plan creates public IP without approval
deny[msg] {
    some r
    r.type == "aws_eip"
    r.attributes.associate_public_ip_address == true
    not input.approval_granted
    msg := "Public IP requires approval — request blocked"
}

# Deny if plan creates unencrypted storage
deny[msg] {
    some r
    r.type == "aws_ebs_volume"
    r.attributes.encrypted == false
    msg := "EBS volume must be encrypted"
}

# Deny if plan creates resources in non-approved region
deny[msg] {
    some r
    not approved_regions[r.planned_values.region]
    msg := sprintf("Region %s is not approved for tenant", [r.planned_values.region])
}
```

**6. Approval Gate**
- If policy validation passes and the catalog item's `approval_required` flag is set, the request enters the approval queue.
- Approvers are determined by OpenFGA: `ListObjects(project:proj-123, owner, user:{id})` returns users who can approve. [openfga](https://openfga.dev/docs/authorization-concepts)
- Approval SLA timers enforce escalation (e.g., 4h → escalate to tenant admin).

**7. Terraform Apply & Resource Registration**
- On approval, SemaphoreUI executes `terraform apply`, with credentials from Vault.
- The apply output is parsed; each created resource is registered in the CMP inventory as a `UnifiedResource` with canonical attributes, tags, and cost metadata.
- Relationship tuples are written to OpenFGA: `virtual_machine:vm-{id}#parent@project:proj-123`. [openfga](https://openfga.dev/docs/authorization-concepts)

**8. Post-Provisioning**
- Tag enforcement: The CMP verifies mandatory tags are present on all provisioned resources; if missing, tags are applied via provider API and a drift event is logged.
- Cost attribution: The resource's cost is registered against the tenant/project budget for real-time spend tracking.
- Audit chain: The complete sequence (request → plan → policy → approval → apply → registration) generates 6+ audit events, all correlated by `request_id`.

***

## Policy-Driven Workflow: Rightsizing Recommendations

### Rightsizing Engine Architecture

The rightsizing engine continuously analyzes resource utilization metrics against provider-recommended sizing thresholds, generating actionable recommendations that flow through an approval-gated remediation workflow.

### Recommendation Generation

```python
# Pseudo-logic for rightsizing analysis
def analyze_vm(vm: VirtualMachine, metrics: list[Metric]) -> Recommendation:
    avg_cpu = mean([m.cpu_utilization for m in metrics[-14*24:]])  # 14 days
    avg_mem = mean([m.memory_utilization for m in metrics[-14*24:]])
    peak_cpu = max([m.cpu_utilization for m in metrics[-14*24:]])
    
    if avg_cpu < 15 and avg_mem < 20:
        severity = "high"
        action = "downsize"
        savings_pct = 50
    elif avg_cpu < 30 and avg_mem < 30:
        severity = "medium"
        action = "downsize"
        savings_pct = 25
    elif peak_cpu > 90 or avg_cpu > 80:
        severity = "high"
        action = "upsize"
        savings_pct = -100  # cost increase
    
    return Recommendation(
        resource_id=vm.id,
        severity=severity,
        action=action,
        current_size=vm.instance_type,
        recommended_size=determine_size(avg_cpu, avg_mem, peak_cpu),
        estimated_monthly_savings=vm.cost_per_hour * 730 * (savings_pct / 100),
        confidence=calculate_confidence(metrics),
    )
```

### Recommendation Lifecycle

| Stage | Description | Policy Gate |
|---|---|---|
| Generated | Engine detects under/over-utilized resource | N/A (automated) |
| Validated | OPA checks if the VM is exempt (e.g., production database, tagged `rightsizing-exempt=true`) | OPA gate |
| Notified | Tenant owner receives recommendation via dashboard + email | Notification policy |
| Approved | Owner or tenant admin approves the resize | OpenFGA `can_resize` check |
| Executed | CMP triggers resize via Terraform (force-replace) or provider API (in-place) | Post-execution policy validation |
| Verified | Metrics are monitored for 14 days post-resize to confirm improvement | N/A |

### Rightsizing Policy (OPA)

```rego
package cmp.rightsizing

# Don't recommend rightsizing for exempt resources
skip_recommendation[reason] {
    input.tags["rightsizing-exempt"] == "true"
    reason := "Resource is exempt from rightsizing"
}

# Don't recommend for resources less than 14 days old
skip_recommendation[reason] {
    input.age_days < 14
    reason := sprintf("Resource is only %d days old", [input.age_days])
}

# Only recommend downsizing for non-production during business hours
allow_auto_downsize {
    input.environment != "production"
    input.current_hour >= 9
    input.current_hour <= 17
}

# Production downsizing requires manual approval
require_approval {
    input.environment == "production"
    input.action == "downsize"
}
```

***

## Policy-Driven Workflow: Cost Attribution Tracking

### Tagging Taxonomy (Mandatory Tags)

All resources provisioned through the CMP must carry mandatory tags; the OPA pre-plan gate blocks provisioning if tags are missing: [thegarnetwiki](https://www.thegarnetwiki.com/finops/showback-chargeback-models/)

| Tag Key | Purpose | Example |
|---|---|---|
| `cmp:tenant-id` | Tenant attribution | `acme-corp` |
| `cmp:project-id` | Project/showback | `proj-123` |
| `cmp:environment` | Environment classification | `production` / `staging` / `dev` |
| `cmp:owner` | Cost owner email | `alice@acme.com` |
| `cmp:cost-center` | Finance cost center | `CC-4501` |
| `cmp:billable` | Billable to tenant? | `true` / `false` |

### Cost Data Pipeline

```
Provider Billing APIs          CMP Inventory
├── AWS Cost Explorer API      ├── Resource registry
├── Nutanix billing export     ├── Tag registry
└── vSphere licensing cost     └── Tenant/project mapping
         │                            │
         └──────────┬─────────────────┘
                    ▼
         ┌──────────────────┐
         │ Cost Normalization│  Map provider cost items to
         │ & Attribution     │  UnifiedResource IDs via
         │                   │  tags + provider_resource_id
         └────────┬─────────┘
                  ▼
         ┌──────────────────┐
         │ Showback Ledger   │  Append-only table:
         │ (PostgreSQL)      │  (tenant_id, project_id,
         │                   │  resource_id, date, cost_usd,
         │                   │  provider, tag_set)
         └────────┬─────────┘
                  ▼
         ┌──────────────────┐
         │ Cost Dashboards   │  Per-tenant, per-project,
         │ & Budget Alerts   │  per-environment breakdowns
         └──────────────────┘
```

### Allocation Model

The CMP uses a **hybrid allocation model** combining direct attribution and proportional allocation: [thegarnetwiki](https://www.thegarnetwiki.com/finops/showback-chargeback-models/)

1. **Direct attribution** (40-60% of spend): Resources with `cmp:tenant-id` and `cmp:project-id` tags are directly attributed. [thegarnetwiki](https://www.thegarnetwiki.com/finops/showback-chargeback-models/)
2. **Proportional allocation** (shared costs): Shared infrastructure (e.g., Transit Gateway, shared load balancers, platform monitoring) is distributed proportionally based on usage metrics (request count, data transfer, metric volume per tenant). [thegarnetwiki](https://www.thegarnetwiki.com/finops/showback-chargeback-models/)
3. **Fixed platform fee**: A flat platform service fee covers CMP infrastructure costs, billed to tenants as a separate line item. [thegarnetwiki](https://www.thegarnetwiki.com/finops/showback-chargeback-models/)

### Budget Enforcement Policy (OPA)

```rego
package cmp.cost

# Block provisioning if project budget is exceeded
deny[msg] {
    project_id := input.project_id
    projected_total := current_project_spend[project_id] + input.estimated_monthly_cost
    budget := project_budget[project_id]
    projected_total > budget * budget_threshold
    msg := sprintf("Project %s budget would be exceeded (budget: %.2f, projected: %.2f)", [project_id, budget, projected_total])
}

# Alert (don't block) at 80% budget
warn[msg] {
    project_id := input.project_id
    projected_total := current_project_spend[project_id] + input.estimated_monthly_cost
    budget := project_budget[project_id]
    threshold_80 := budget * 0.8
    threshold_100 := budget * 1.0
    projected_total >= threshold_80
    projected_total < threshold_100
    msg := sprintf("Project %s approaching budget limit (80%% threshold)", [project_id])
}

# Hard block at 100% budget
deny[msg] {
    project_id := input.project_id
    projected_total := current_project_spend[project_id] + input.estimated_monthly_cost
    budget := project_budget[project_id]
    projected_total >= budget
    msg := sprintf("Project %s budget exceeded — provisioning blocked", [project_id])
}
```

### Showback Report Generation

The showback ledger generates daily, weekly, and monthly reports per tenant: [antigravitylab](https://antigravitylab.net/en/articles/agents/antigravity-agent-cost-attribution-multi-tenant-showback-architecture)

```sql
-- Monthly showback per tenant
SELECT
    tenant_id,
    project_id,
    environment,
    SUM(cost_usd) AS total_cost,
    SUM(CASE WHEN allocation_type = 'direct' THEN cost_usd ELSE 0 END) AS direct_cost,
    SUM(CASE WHEN allocation_type = 'proportional' THEN cost_usd ELSE 0 END) AS shared_cost,
    SUM(CASE WHEN allocation_type = 'platform_fee' THEN cost_usd ELSE 0 END) AS platform_fee
FROM showback_ledger
WHERE date_trunc('month', recorded_at) = date_trunc('month', CURRENT_DATE)
GROUP BY tenant_id, project_id, environment
ORDER BY total_cost DESC;
```

The ledger is append-only with idempotency keys (`invocation_id` as UUIDv7) to handle at-least-once delivery from the cost pipeline. No default or "unknown" tenant is allowed—any cost event without a tenant ID causes a pipeline failure and alert, ensuring 100% attribution coverage. [antigravitylab](https://antigravitylab.net/en/articles/agents/antigravity-agent-cost-attribution-multi-tenant-showback-architecture)

***

## Workflow Interaction Summary

| Workflow | OPA Policy Gates | OpenFGA Checks | Vault Operations | Audit Events |
|---|---|---|---|---|
| Provisioning | Pre-plan, post-plan | Project editor, can_create | Credential retrieval, state encryption | 6+ events per request |
| Rightsizing | Exempt check, environment check | can_resize | Credential for resize operation | 3+ events per recommendation |
| Cost attribution | Budget threshold check | Tenant member (report access) | N/A (read-only) | 1 event per cost record |
| Drift detection | Policy compliance check | N/A (system-triggered) | N/A | 1 event per drift detected |

***

## Deployment Considerations

- **Vault**: Deploy 4 clusters minimum (primary + DR in AWS, PR secondary + DR in Nutanix/vSphere on-prem). Use performance replication with path filters to replicate only relevant tenant namespaces to each cloud. Local mounts on the on-prem cluster for data sovereignty. [developer.hashicorp](https://developer.hashicorp.com/validated-patterns/vault/extend-vault-enterprise-for-hybrid-and-multi-cloud-deployments)
- **OpenFGA**: Deploy as a stateless microservice behind the CMP API gateway. Use PostgreSQL as OpenFGA's backing store (shared with CMP or isolated). Synchronize tuples from the CMP resource lifecycle events. [openfga](https://openfga.dev/docs/authorization-concepts)
- **OPA**: Deploy as a sidecar or standalone service. Evaluate policies at two points: pre-plan (request validation) and post-plan (Terraform plan output validation). [env0](https://www.env0.com/blog/open-policy-agent)
- **Audit pipeline**: Fluentd/Vector as the log collector, OpenSearch for hot storage (30-day), S3 Glacier or Nutanix Objects with object-lock for cold archive (7-year retention). [hoop](https://hoop.dev/blog/best-practices-for-managing-multi-cloud-audit-logs)

***

Would you like me to turn any of these sections into deployment-ready specifications (Terraform modules for Vault cluster topology, OpenFGA tuple seeding scripts, or OPA Rego bundles), or shall we focus on the multi-tenancy data model that underpins all of these workflows?
