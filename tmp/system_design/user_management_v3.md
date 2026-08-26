
In the current design, users live in LLDAP, but AWS access is actually decided by OpenFGA tuples assigned to `user:<uid>` subjects after authentication through Dex.  The key limitation is that the active model only gives you coarse tenant roles—`owner`, `admin`, and `viewer`—so it does not natively support “S3 provisioning but no VPC provisioning” without a model refinement.

## Current model

Today, the only role-bearing relations for a tenant are `owner`, `admin`, and `viewer`, and permissions such as `can_read`, `can_provision`, `can_assign_*`, and backend access are derived from those roles rather than granted directly.  For AWS specifically, the seeded examples are `aws-owner`, `aws-admin`, and `aws-viewer` on `tenant:aws`, and those tenant roles propagate to the AWS backend object through the `tenant` relation.

| Current role | Effective privilege |
|---|---|
| `owner` on `tenant:aws` | Can assign owner/admin/viewer, manage backend credentials, provision, and read.  |
| `admin` on `tenant:aws` | Can assign viewer, provision, and read, but cannot assign admin/owner and cannot manage credentials.  |
| `viewer` on `tenant:aws` | Read-only and enumeration only; cannot provision or assign roles.  |

## User creation

In the present system, creating a different AWS user is a two-step process: create the identity in LLDAP and then grant an OpenFGA role tuple for the AWS tenant.  The user can be created with `scripts/lldap-user-onboard.sh`, while the authorization grant is wriwritten with `scripts/openfga-tuple-write.sh` as `(user:<uid>, owner|admin|viewer, tenant:aws)`. 

That means your current answer to question 1 is: **yes, you can create different AWS users now, but only at the coarse role level of viewer/admin/owner**. To support “read + provisioning for S3, but no VPC/network provisioning,” refine the model so LLDAP remains the identity source, while OpenFGA adds service-scoped capabilities that are assigned per user or via synchronized LLDAP groups.

A practical refinement is to introduce capability tuples like these:

- `aws_reader`
- `aws_s3_provisioner`
- `aws_ec2_provisioner`
- `aws_vpc_provisioner`
- `aws_iam_viewer`
- `billing_reader`
- `report_runner`

Then define permissions as combinations of **action + scope**, for example:

- `can_read` on `aws_account:companyA-prod`
- `can_provision` on `aws_service:s3:companyA-prod`
- `can_provision` on `aws_service:vpc:companyA-prod`
- `can_view_billing` on `billing:companyA`
- `can_run_reports` on `reporting:companyA`

## Privilege variations

Other privilege combinations are best modeled as separate capability sets rather than trying to overload `admin` and `viewer`. In the current model, only read/provision/assignment/credential-management are represented, so reporting and billing need new relations and probably new object types.

A clean pattern is:

| Use case | Recommended capability set |
|---|---|
| Read-only AWS operations | `aws_reader` |
| S3 provisioning only | `aws_reader` + `aws_s3_provisioner` |
| Network team | `aws_reader` + `aws_vpc_provisioner` |
| Finance team | `billing_reader` + `report_runner` |
| Platform admin without billing | `aws_reader` + `aws_ec2_provisioner` + `aws_s3_provisioner` + `aws_vpc_provisioner` |
| Audit/reporting user | `aws_reader` + `report_runner` |

For administration, I would treat LLDAP groups as the operator-facing abstraction and translate each group membership into OpenFGA tuples. For example, a user added to `grp-companyA-aws-s3-provisioner` would receive the tuples that grant S3 provisioning only within Company A’s AWS scope.

## Company isolation

Your third requirement should be implemented as **tenant-per-company**, not as a single shared AWS tenant with many admins. The current model already enforces isolation by tenant, because roles are granted on `tenant:*` objects and access propagates only through the structural tuples linked to that tenant.

So instead of one `tenant:aws`, create separate tenants such as:

- `tenant:companyA-aws`
- `tenant:companyB-aws`

Then bind each tenant only to its own AWS account, regions, resources, billing scope, and reports, and assign admins only within that tenant. With that layout, `user:alice` can be `admin` on `tenant:companyA-aws` and have no relation at all to `tenant:companyB-aws`, which prevents Company A’s admin from seeing or managing Company B.

A good target model would look like this:

1. LLDAP stores users and groups.
2. A sync job maps LLDAP groups to OpenFGA tuples.
3. OpenFGA grants capabilities on company-scoped AWS objects.
4. Each company gets its own tenant boundary, resource scopes, and admin set.
5. `owner` becomes rare and high-risk; most operators get narrowly scoped capability roles.

Would you like me to draft the exact OpenFGA model extension and tuple naming scheme for Company A / Company B?
