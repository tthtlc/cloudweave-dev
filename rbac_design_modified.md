
Comparing the implemented OpenFGA model in openfga_postgres/openfga_bootstrap.py against rbac_design.md, there are several real inconsistencies and gaps. I'll group them: (A) what matches, (B) direct contradictions, (C) capabilities the redesign requires that aren't modeled, and (D) extra/undocumented
  surface in the OpenFGA model.

  A. What is consistent

  • The four-role taxonomy (SuperAdmin / Owner / Admin / Viewer) matches rbac_design.md lines 11–15.
  • Per-tenant scoping and cross-tenant isolation. The can_provision intersection (tenant role ∩ can_use on the parent provider) enforces that an aws-admin cannot act on nutanix_cluster:nutanix, validated at openfga_bootstrap.py:569–570. This realizes the redesign's "Admin acts only within bound scope"
    / per-tenant isolation intent.
  • Owner = full CRUD + membership within the tenant. can_provision (owner∪admin), can_read, can_assign_admin, can_assign_viewer, can_manage_credentials for owners (openfga_bootstrap.py:224–237) align with the Owner capability list (rbac_design.md:42–59).
  • Viewer = read-only, no provision. can_read includes viewer; can_provision excludes it (openfga_bootstrap.py:565, 574–575), matching rbac_design.md:99–108.

  B. Direct contradictions

  1. SuperAdmin is not "meta-operator only" — it is a full tenant owner by default.

     rbac_design.md:40 says SuperAdmin "controls the multi-cloud platform, not the day-to-day resources inside each tenant unless explicitly added," and the matrix (rbac_design.md:124) shows SuperAdmin resource management = "None (by default)". The implementation instead seeds user:superadmin owner 
  tenant:aws and … tenant:nutanix (openfga_bootstrap.py:507–508) and validates superadmin can_provision aws_region:aws / nutanix_cluster:nutanix = True (openfga_bootstrap.py:542–543). So SuperAdmin has full CRUD on every tenant by default — the opposite of the redesign.

  2. Owner can assign new Owners; the redesign reserves that for SuperAdmin.

     can_assign_owner is computedUserset → owner (openfga_bootstrap.py:224), so a tenant Owner can grant Owner to others. The redesign lists "Assign and revoke tenant Owners" under SuperAdmin (rbac_design.md:28–29) and only "assign/revoke Admin/Viewer" under Owner (rbac_design.md:50). This is a
  privilege-escalation risk under the new design: a compromised Owner can create co-Owners.

  3. Admin can assign Viewer; the redesign says Admin cannot change membership.

     can_assign_viewer = union(owner, admin) (openfga_bootstrap.py:226–233), validated aws-admin can_assign_viewer tenant:aws = True (openfga_bootstrap.py:553). The redesign explicitly states Admins "cannot change tenant membership (cannot assign or revoke Owner/Admin/Viewer)" (rbac_design.md:93–97) and
  the matrix shows Admin tenant membership = "None" (rbac_design.md:126).

  4. SuperAdmin's cross-tenant read visibility is not global/automatic.

     The redesign wants SuperAdmin to have read-only visibility of all tenants by virtue of the role (rbac_design.md:32–34). The implementation grants read access only through per-tenant seed tuples; a new tenant added later would give SuperAdmin nothing unless an owner tuple is also written for it. There
  is no platform → all-tenants read relation.

  C. Capabilities the redesign requires that are not modeled at all

  5. Resource-class scope is entirely missing — the biggest gap.

     The redesign makes "resource class" (EC2/EBS/RDS/VPC; Prism clusters, AHV VMs, Calm apps, etc.) a first-class scope with per-class Admin/Viewer sub-roles: Compute Admin,Continuing from section C, item 5.

  5. Resource-class scope is entirely missing — the biggest gap.

     The redesign makes "resource class" (EC2/EBS/RDS/VPC; Prism clusters, AHV VMs, Calm apps) a first-class scope with per-class Admin/Viewer sub-roles: Compute Admin, Network Admin, Data Admin, Platform/K8s Admin; Infra/Cost/Security Viewer (rbac_design.md:7–15, 63–114). The OpenFGA model has only
  provider → aws_region / nutanix_cluster granularity. There is no object type for "compute" vs "network" vs "data" vs "platform/k8s", and no relation binding an Admin/Viewer to a single resource class. So can_provision is binary over the whole backend — you cannot express "Compute Admin but not Network
  Admin." An aws-admin can delete any VM, volume, or DB in the region.

  6. No tenant lifecycle.

     The redesign has SuperAdmin "create, onboard, and decommission tenants (register AWS accounts, Nutanix projects)" (rbac_design.md:27–29). The model has no create/delete/register relation on tenant; tenants are static seed tuples (openfga_bootstrap.py:502–533). Only two fixed tenants exist
  (tenant:aws, tenant:nutanix), not the dynamic "one tenant per AWS account / Nutanix project" the redesign describes (rbac_design.md:6, 43).

  7. No global-policy / IdP / IAM-mapping relations.

     SuperAdmin's "configure global password/SSO/IdP, logging, guardrails, quotas, RBAC templates" and "manage mappings between RBAC engine and AWS IAM / Nutanix Prism roles" (rbac_design.md:30–38) collapse to the single can_manage_platform blob (openfga_bootstrap.py:197–198). None of these are
  individually modeled, so they cannot be delegated or audited at relation granularity.

  8. No create/update/delete distinction.

     The redesign's "full CRUD on all resource classes" (rbac_design.md:53) implies create/update/delete verbs. The model only has can_provision (create/delete VMs) and can_read. There is no can_update, so an update-vs-delete split cannot be expressed.

  9. No group / service-account principals.

     The redesign says "identities (users, groups, service accounts) just get role bindings" (rbac_design.md:17). Every directly_related_user_types in the model is {type: user} only (openfga_bootstrap.py:202–204, 258–263, 287–290, 317–322, 391–403, 471–484). There is no group type, no service_account
  type, and no group-membership relation, so roles can only be bound to individual humans — not to groups or workload identities.

  D. Extra / undocumented surface in OpenFGA not in the redesign

  10. operator is an undeclared fifth role.

      aws_region / nutanix_cluster carry a direct operator relation that feeds can_provision and can_read (openfga_bootstrap.py:331, 374–376, 412, 454–456). The redesign's role set is exactly four (rbac_design.md:11–15). operator is an out-of-band grant that gives provision power to a user without any
  tenant role — a path that bypasses the documented taxonomy.

  11. allowed on provider is an undocumented direct-grant hatch.

      provider.can_use = this ∪ allowed ∪ tupleToUserset(parent→member) (openfga_bootstrap.py:298–312). The allowed arm lets a specific user can_use a provider without being a tenant member — again outside the four-role model.

  12. Duplicate viewer paths on backends.

      Backends have both a direct viewer relation (openfga_bootstrap.py:332, 402–403) and the propagated tenant_viewer (openfga_bootstrap.py:345–350). The redesign has a single Viewer role; the model has two ways to be a viewer on a backend, which is redundant and a potential audit gap (a direct viewer
  tuple is invisible to tenant-centric tooling).

  13. can_assign_admin and can_assign_owner are both owner-only and indistinguishable in spirit.

      Both are computedUserset → owner (openfga_bootstrap.py:224–225). The redesign separates "Owner assigns Admin/Viewer" from "SuperAdmin assigns Owners" (rbac_design.md:28–29, 50). The model cannot express the SuperAdmin-only owner-assignment the redesign requires (see contradiction #2).

  Summary of the highest-impact problems

  • Privilege escalation / over-grant: SuperAdmin is a full tenant owner by default (contradiction #1), and tenant Owners can mint new Owners (contradiction #2) — both violate the redesign's least-privilege intent.
  • Admin is over-permissioned for membership: Admin can assign Viewer (contradiction #3), which the redesign forbids.
  • No resource-class scoping: the headline feature of the redesign (per-class Admin/Viewer sub-roles) cannot be expressed at all (gap #5).
  • No tenant lifecycle or global governance relations: SuperAdmin's actual job in the redesign is largely unmodeled (gaps #6, #7).
  • Undeclared roles/hatches (operator, allowed, direct viewer) weaken the four-role guarantee the redesign assumes (items 10–12).

  To bring the OpenFGA model in line with rbac_design.md, the minimum changes would be: (1) stop seeding SuperAdmin as tenant owner and add a global read-only relation instead; (2) move can_assign_owner off owner onto a SuperAdmin-gated relation; (3) drop admin from can_assign_viewer; (4) introduce a
  resource_class object type and per-class Admin/Viewer bindings feeding can_provision/can_read; (5) add tenant-lifecycle and global-policy relations under can_manage_platform; and (6) either document or remove the operator/allowed/direct-viewer arms.


