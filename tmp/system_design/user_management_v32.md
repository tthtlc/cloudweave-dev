
Below is a concrete draft for extending `openfga_bootstrap.py::LIBCLOUD_MODEL` and `INITIAL_TUPLES` so you can support Company A / Company B isolation, plus fine-grained AWS permissions such as S3 provisioning, VPC provisioning, billing, and reporting, while keeping LLDAP as the identity source and OpenFGA as the authorization source. 

## Model draft

This draft keeps your existing `platform`, `tenant`, and API/provider linkage concepts, because those already drive authentication-to-authorization flow and tenant-scoped backend propagation in the current system.  The main change is to add company-scoped AWS account and AWS capability objects instead of relying only on `tenant:aws` with derived coarse permissions. 

```python
LIBCLOUD_MODEL = r"""
model
  schema 1.1

type user

type platform
  relations
    define superadmin: [user]
    define can_manage_platform: superadmin

type tenant
  relations
    define owner: [user]
    define admin: [user]
    define viewer: [user]

    define member: owner or admin or viewer
    define can_assign_owner: owner
    define can_assign_admin: owner
    define can_assign_viewer: owner or admin
    define can_manage_credentials: owner

    define can_read: member
    define can_provision_base: owner or admin
    define can_view_billing_base: owner
    define can_run_reports_base: owner or admin

type libcloud_api
  relations
    define parent: [tenant]
    define can_connect: member from parent

type provider
  relations
    define parent: [tenant]
    define allowed: [user, tenant#member]
    define can_use: allowed or member from parent

type aws_account
  relations
    define tenant: [tenant]
    define owner: owner from tenant
    define admin: admin from tenant
    define viewer: viewer from tenant

    define can_read: owner or admin or viewer
    define can_provision_base: owner or admin
    define can_view_billing_base: owner or admin
    define can_run_reports_base: owner or admin

type aws_capability
  relations
    define account: [aws_account]

    define s3_provisioner: [user]
    define ec2_provisioner: [user]
    define vpc_provisioner: [user]
    define iam_reader: [user]
    define billing_reader: [user]
    define report_runner: [user]

    define can_read: can_read from account
    define can_provision_s3: s3_provisioner or can_provision_base from account
    define can_provision_ec2: ec2_provisioner or can_provision_base from account
    define can_provision_vpc: vpc_provisioner or can_provision_base from account
    define can_view_iam: iam_reader or can_read from account
    define can_view_billing: billing_reader or can_view_billing_base from account
    define can_run_reports: report_runner or can_run_reports_base from account
"""
```

This structure preserves your current break-glass and tenant administration pattern, where `owner` remains the high-trust role and `admin` remains operational but limited. 

## Tuple draft

Your current store is seeded by `INITIAL_TUPLES`, including user-role tuples and structural tuples that connect tenants to the API and providers.  The following draft extends that same style for two companies with isolated AWS tenants and per-account capability scopes. 

```python
INITIAL_TUPLES = [
    # Platform bootstrap
    {"user": "user:superadmin", "relation": "superadmin", "object": "platform:main"},

    # Break-glass ownership
    {"user": "user:superadmin", "relation": "owner", "object": "tenant:companyA-aws"},
    {"user": "user:superadmin", "relation": "owner", "object": "tenant:companyB-aws"},

    # Company A tenant roles
    {"user": "user:companya-owner",  "relation": "owner",  "object": "tenant:companyA-aws"},
    {"user": "user:companya-admin",  "relation": "admin",  "object": "tenant:companyA-aws"},
    {"user": "user:companya-viewer", "relation": "viewer", "object": "tenant:companyA-aws"},

    # Company B tenant roles
    {"user": "user:companyb-owner",  "relation": "owner",  "object": "tenant:companyB-aws"},
    {"user": "user:companyb-admin",  "relation": "admin",  "object": "tenant:companyB-aws"},
    {"user": "user:companyb-viewer", "relation": "viewer", "object": "tenant:companyB-aws"},

    # API connectivity
    {"user": "tenant:companyA-aws", "relation": "parent", "object": "libcloud_api:main"},
    {"user": "tenant:companyB-aws", "relation": "parent", "object": "libcloud_api:main"},

    # Provider connectivity
    {"user": "tenant:companyA-aws", "relation": "parent", "object": "provider:aws-companyA"},
    {"user": "tenant:companyB-aws", "relation": "parent", "object": "provider:aws-companyB"},

    # Tenant -> AWS account links
    {"user": "tenant:companyA-aws", "relation": "tenant", "object": "aws_account:companyA-prod"},
    {"user": "tenant:companyA-aws", "relation": "tenant", "object": "aws_account:companyA-dev"},
    {"user": "tenant:companyB-aws", "relation": "tenant", "object": "aws_account:companyB-prod"},

    # AWS account -> capability objects
    {"user": "aws_account:companyA-prod", "relation": "account", "object": "aws_capability:companyA-prod-s3"},
    {"user": "aws_account:companyA-prod", "relation": "account", "object": "aws_capability:companyA-prod-ec2"},
    {"user": "aws_account:companyA-prod", "relation": "account", "object": "aws_capability:companyA-prod-vpc"},
    {"user": "aws_account:companyA-prod", "relation": "account", "object": "aws_capability:companyA-prod-billing"},
    {"user": "aws_account:companyA-prod", "relation": "account", "object": "aws_capability:companyA-prod-reporting"},

    {"user": "aws_account:companyA-dev", "relation": "account", "object": "aws_capability:companyA-dev-s3"},
    {"user": "aws_account:companyA-dev", "relation": "account", "object": "aws_capability:companyA-dev-vpc"},

    {"user": "aws_account:companyB-prod", "relation": "account", "object": "aws_capability:companyB-prod-s3"},
    {"user": "aws_account:companyB-prod", "relation": "account", "object": "aws_capability:companyB-prod-vpc"},
    {"user": "aws_account:companyB-prod", "relation": "account", "object": "aws_capability:companyB-prod-billing"},
    {"user": "aws_account:companyB-prod", "relation": "account", "object": "aws_capability:companyB-prod-reporting"},

    # Fine-grained examples: Company A
    {"user": "user:alice", "relation": "viewer",          "object": "tenant:companyA-aws"},
    {"user": "user:alice", "relation": "s3_provisioner",  "object": "aws_capability:companyA-prod-s3"},
    {"user": "user:alice", "relation": "billing_reader",  "object": "aws_capability:companyA-prod-billing"},
    {"user": "user:alice", "relation": "report_runner",   "object": "aws_capability:companyA-prod-reporting"},

    {"user": "user:bob",   "relation": "admin",           "object": "tenant:companyA-aws"},
    {"user": "user:bob",   "relation": "vpc_provisioner", "object": "aws_capability:companyA-prod-vpc"},

    # Fine-grained examples: Company B
    {"user": "user:carol", "relation": "viewer",          "object": "tenant:companyB-aws"},
    {"user": "user:carol", "relation": "report_runner",   "object": "aws_capability:companyB-prod-reporting"},
]
```

With these tuples, Alice can read Company A’s AWS account via `viewer`, provision S3 because she is an `s3_provisioner`, access billing because she is a `billing_reader`, and run reports because she is a `report_runner`, but she cannot provision VPC because no `vpc_provisioner` tuple exists for her. Bob can administer Company A’s tenant and provision VPC, while Carol is isolated to Company B only.

## LLDAP mapping

Your current system already has scripts for user onboarding, group membership management, and OpenFGA tuple management, so the cleanest implementation is group-to-tuple synchronization rather than manual tuple authoring per user.  LLDAP remains the source of identity and human-friendly administration, while OpenFGA remains the runtime authorization layer. 

Recommended LLDAP groups:

```text
grp-companyA-aws-owner
grp-companyA-aws-admin
grp-companyA-aws-viewer
grp-companyA-aws-prod-s3-provisioner
grp-companyA-aws-prod-vpc-provisioner
grp-companyA-aws-prod-billing-reader
grp-companyA-aws-prod-report-runner

grp-companyB-aws-owner
grp-companyB-aws-admin
grp-companyB-aws-viewer
grp-companyB-aws-prod-s3-provisioner
grp-companyB-aws-prod-vpc-provisioner
grp-companyB-aws-prod-billing-reader
grp-companyB-aws-prod-report-runner
```

Suggested mapping rules:

| LLDAP group | OpenFGA tuple |
|---|---|
| `grp-companyA-aws-viewer` | `user:<uid> viewer tenant:companyA-aws` |
| `grp-companyA-aws-admin` | `user:<uid> admin tenant:companyA-aws` |
| `grp-companyA-aws-owner` | `user:<uid> owner tenant:companyA-aws` |
| `grp-companyA-aws-prod-s3-provisioner` | `user:<uid> s3_provisioner aws_capability:companyA-prod-s3` |
| `grp-companyA-aws-prod-vpc-provisioner` | `user:<uid> vpc_provisioner aws_capability:companyA-prod-vpc` |
| `grp-companyA-aws-prod-billing-reader` | `user:<uid> billing_reader aws_capability:companyA-prod-billing` |
| `grp-companyA-aws-prod-report-runner` | `user:<uid> report_runner aws_capability:companyA-prod-reporting` |

This matches the existing operational model in your document, where LLDAP scripts manage users and groups and OpenFGA scripts manage authorization tuples. 

## Example checks

You already have `scripts/openfga-check.sh` for permission verification, so these are the kinds of checks this model enables. 

For Alice:

```bash
scripts/openfga-check.sh user:alice can_read aws_account:companyA-prod
# expected: true

scripts/openfga-check.sh user:alice can_provision_s3 aws_capability:companyA-prod-s3
# expected: true

scripts/openfga-check.sh user:alice can_provision_vpc aws_capability:companyA-prod-vpc
# expected: false

scripts/openfga-check.sh user:alice can_view_billing aws_capability:companyA-prod-billing
# expected: true

scripts/openfga-check.sh user:alice can_run_reports aws_capability:companyA-prod-reporting
# expected: true

scripts/openfga-check.sh user:alice can_read aws_account:companyB-prod
# expected: false
```

For Bob:

```bash
scripts/openfga-check.sh user:bob can_provision_vpc aws_capability:companyA-prod-vpc
# expected: true

scripts/openfga-check.sh user:bob can_view_billing aws_capability:companyA-prod-billing
# expected: true via account admin, if you keep admin billing visibility
```

If you want billing to be excluded from tenant admins, change `define can_view_billing_base: owner or admin` on `aws_account` to `define can_view_billing_base: owner` only.

## Implementation notes

The biggest design choice is whether `admin` should automatically inherit broad provisioning on all AWS capability objects. In the draft above, `admin` inherits `can_provision_base` at the account level, which then flows into service provisioning permissions, so it behaves as a broad infrastructure operator unless you choose to narrow it.

If you want stricter least privilege, use this version instead:

- `tenant.admin` keeps tenant operational rights.
- `aws_account.can_provision_base` is only `owner`.
- Every real infrastructure change requires explicit capability tuples such as `s3_provisioner` or `vpc_provisioner`.

That stricter variant is often better for multi-company environments because it prevents tenant admins from silently becoming full-service AWS admins.

## Recommended final shape

Given your questions, I would recommend this production shape:

- LLDAP stores users and groups. 
- OpenFGA stores company-scoped authorization tuples. 
- Each company gets its own `tenant:<company>-aws`. 
- Each AWS account gets its own `aws_account:*`.
- Each privileged domain gets its own `aws_capability:*` object, such as S3, VPC, billing, and reporting.
- `owner` is reserved for company-level control and credential management, matching your current privilege summary. 
- `admin` is tenant-scoped operational admin, but fine-grained AWS actions are still explicit tuples.
- Company A and Company B never share tenant objects, which enforces admin isolation through object boundaries just as your current model already enforces AWS-versus-Nutanix isolation. 

Would you like the next step to be a stricter least-privilege version of the model, or a migration plan from the current `tenant:aws` layout to `tenant:companyA-aws` and `tenant:companyB-aws`?
