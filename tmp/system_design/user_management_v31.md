
Yes — the clean refinement is to keep **LLDAP for identity and groups**, but extend OpenFGA from coarse tenant roles into company-scoped, capability-based authorization for AWS.  Your current model already separates authentication from authorization, so the main change is to add finer AWS object types and relations, then map LLDAP groups to those OpenFGA tuples. 

## Target design

Right now, only `owner`, `admin`, and `viewer` are directly assigned, and everything else is derived from them, so the model cannot express per-service AWS permissions like “S3 provisioning only” or “billing but no infrastructure changes.”  The refinement is to preserve tenant boundaries, but introduce AWS account, service, and business-function objects with explicit capability relations. 

A practical object model is:

```fga
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

    define can_read: owner or admin or viewer
    define can_provision_all: owner or admin
    define can_view_billing: owner
    define can_run_reports: owner or admin
```

This preserves your existing semantics for platform and tenant administration, which are already documented in the current model. 

## AWS extension

To support combinations like “read + S3 provisioning but no VPC,” define AWS resources below each company tenant instead of making the whole tenant the only authorization scope. The current model already propagates tenant roles to `aws_region` objects, so this is a natural extension of the same pattern. 

A more expressive extension would be:

```fga
type aws_account
  relations
    define tenant: [tenant]
    define owner: owner from tenant
    define admin: admin from tenant
    define viewer: viewer from tenant

    define can_read: owner or admin or viewer
    define can_view_billing: owner or admin
    define can_run_reports: owner or admin

type aws_service
  relations
    define account: [aws_account]

    define s3_provisioner: [user]
    define ec2_provisioner: [user]
    define vpc_provisioner: [user]
    define iam_reader: [user]
    define billing_reader: [user]
    define report_runner: [user]

    define can_read: can_read from account
    define can_provision_s3: s3_provisioner
    define can_provision_ec2: ec2_provisioner
    define can_provision_vpc: vpc_provisioner
    define can_view_iam: iam_reader or can_read from account
    define can_view_billing: billing_reader or can_view_billing from account
    define can_run_reports: report_runner or can_run_reports from account
```

With this pattern, `aws_service` objects can be things like `aws_service:companyA-prod-s3`, `aws_service:companyA-prod-vpc`, and `aws_service:companyA-prod-billing`. A user can then hold service-specific capabilities without becoming a general AWS admin.

## Naming scheme

Use company- and environment-scoped object names so every tuple is obviously bounded to one tenant. This is important because your present model already relies on object-level separation for cross-cloud isolation, and the same approach should be used for cross-company AWS isolation. 

Recommended object naming:

| Object type | Example object id | Purpose |
|---|---|---|
| `tenant` | `tenant:companyA-aws` | Company A AWS boundary |
| `tenant` | `tenant:companyB-aws` | Company B AWS boundary |
| `aws_account` | `aws_account:companyA-prod` | Company A production AWS account |
| `aws_account` | `aws_account:companyA-dev` | Company A development AWS account |
| `aws_service` | `aws_service:companyA-prod-s3` | S3-scoped permissions |
| `aws_service` | `aws_service:companyA-prod-vpc` | VPC/network-scoped permissions |
| `aws_service` | `aws_service:companyA-prod-billing` | Billing-scoped permissions |
| `aws_service` | `aws_service:companyA-prod-reporting` | Reporting-scoped permissions |

Recommended LLDAP group naming:

- `grp-companyA-aws-owner`
- `grp-companyA-aws-admin`
- `grp-companyA-aws-viewer`
- `grp-companyA-aws-s3-provisioner`
- `grp-companyA-aws-vpc-provisioner`
- `grp-companyA-aws-billing-reader`
- `grp-companyA-aws-report-runner`

These groups should be operator-facing, while OpenFGA tuples remain the enforcement layer.

## Example tuples

For a user who should have read access everywhere in Company A, S3 provisioning only, billing access, but no VPC provisioning, the tuples could look like:

```text
user:alice viewer tenant:companyA-aws
tenant:companyA-aws tenant aws_account:companyA-prod
aws_account:companyA-prod account aws_service:companyA-prod-s3
aws_account:companyA-prod account aws_service:companyA-prod-vpc
aws_account:companyA-prod account aws_service:companyA-prod-billing
aws_account:companyA-prod account aws_service:companyA-prod-reporting

user:alice s3_provisioner aws_service:companyA-prod-s3
user:alice billing_reader aws_service:companyA-prod-billing
user:alice report_runner aws_service:companyA-prod-reporting
```

That yields this effective result:

| Capability | Alice |
|---|---|
| Read AWS account objects | Yes, through `viewer` on `tenant:companyA-aws` |
| Provision S3 | Yes, through `s3_provisioner` |
| Provision VPC | No, because no `vpc_provisioner` tuple exists |
| View billing | Yes, through `billing_reader` |
| Run reports | Yes, through `report_runner` |
| Access Company B | No, because she has no tuples on Company B objects |

For a stronger operator, such as a network admin for Company A:

```text
user:bob admin tenant:companyA-aws
user:bob vpc_provisioner aws_service:companyA-prod-vpc
```

Bob can read and perform tenant-level admin functions allowed by your model, but only gets explicit network provisioning where you assign it.

## Company isolation

To satisfy “Company A admin must not access Company B admin,” do **not** model all companies under one shared AWS tenant. The current system already enforces isolation by object membership and relation propagation, so the right refinement is one AWS tenant per company with separate downstream objects. 

Use this structure:

```text
tenant:companyA-aws
tenant:companyB-aws

tenant:companyA-aws tenant aws_account:companyA-prod
tenant:companyB-aws tenant aws_account:companyB-prod
```

Then assign:

```text
user:alice admin tenant:companyA-aws
user:carol admin tenant:companyB-aws
```

Because `alice` has no relation on `tenant:companyB-aws`, she will not inherit any `can_read`, `can_provision_*`, billing, or reporting permissions for Company B. This is the same isolation principle your current model uses to keep AWS users from having Nutanix relations. 

## Sync workflow

The operational workflow should remain simple: create users in LLDAP, place them into groups, and have a sync job translate group membership into OpenFGA tuples. Your current environment already has scripts for LLDAP user/group management and OpenFGA tuple writes, so this refinement fits the existing operational model rather than replacing it. 

Suggested mapping logic:

1. `scripts/lldap-user-onboard.sh` creates the user in LLDAP. 
2. The user is added to one or more LLDAP groups such as `grp-companyA-aws-viewer` or `grp-companyA-aws-s3-provisioner`. 
3. A reconciliation job reads group membership and writes tuples with `scripts/openfga-tuple-write.sh`, or removes them with `scripts/openfga-tuple-delete.sh`. 
4. Authorization checks continue to use OpenFGA `Check()` and object listing scripts already present in the platform. 

A minimal mapping table would be:

| LLDAP group | OpenFGA tuple produced |
|---|---|
| `grp-companyA-aws-viewer` | `user:<uid> viewer tenant:companyA-aws` |
| `grp-companyA-aws-admin` | `user:<uid> admin tenant:companyA-aws` |
| `grp-companyA-aws-owner` | `user:<uid> owner tenant:companyA-aws` |
| `grp-companyA-aws-s3-provisioner` | `user:<uid> s3_provisioner aws_service:companyA-prod-s3` |
| `grp-companyA-aws-vpc-provisioner` | `user:<uid> vpc_provisioner aws_service:companyA-prod-vpc` |
| `grp-companyA-aws-billing-reader` | `user:<uid> billing_reader aws_service:companyA-prod-billing` |
| `grp-companyA-aws-report-runner` | `user:<uid> report_runner aws_service:companyA-prod-reporting` |

## Recommended rules

Keep `owner` very limited because in your current model it already includes role assignment and backend credential management, which makes it a high-risk privilege.  Use `admin` only for tenant administration, and push day-to-day AWS function access into service-scoped capabilities such as `s3_provisioner`, `vpc_provisioner`, `billing_reader`, and `report_runner`. 

A practical policy set is:

- `viewer`: read-only tenant membership.
- `admin`: tenant operations, but not automatic access to every AWS function.
- `owner`: rare, break-glass, company-level control.
- Fine-grained AWS permissions: always separate tuples on `aws_service:*` objects.
- Billing and reporting: separate business permissions, not hidden inside infrastructure admin.
- Company isolation: one tenant per company, one object tree per company.

Would you like me to turn this into a concrete `openfga_bootstrap.py::LIBCLOUD_MODEL` draft plus sample `INITIAL_TUPLES` for Company A and Company B?
