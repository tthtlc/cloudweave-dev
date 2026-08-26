enumerate all existing implemented openfga rules. 

Here is the complete set of OpenFGA rules currently implemented. They all live in the authorization model registered by openfga_postgres/openfga_bootstrap.py (the LIBCLOUD_MODEL dict, schema 1.1). The model defines 6 object types and the relations/rewrites below.

  Type: user

  A plain subject type — no relations. It is the principal referenced by every tuple (user:<lldap-uid>).

  Type: platform (platform:main)

  ┌─────────────────────┬──────────────────────────────┬─────────────────────────────────────────────────────────────────────────────────────────┐
  │ Relation            │ Rule                         │ Meaning                                                                                 │
  ├─────────────────────┼──────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────┤
  │ superadmin          │ this                         │ Direct assignment only — user:X superadmin platform:main must be written explicitly.    │
  ├─────────────────────┼──────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────┤
  │ can_manage_platform │ computedUserset → superadmin │ Whoever is superadmin on the platform can manage it (the only "break-glass" privilege). │
  └─────────────────────┴──────────────────────────────┴─────────────────────────────────────────────────────────────────────────────────────────┘

  Type: tenant (tenant:aws, tenant:nutanix)

  ┌────────────────────────┬────────────────────────────────────────┬──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ Relation               │ Rule                                   │ Meaning                                                                                                                                                                                  │
  ├────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ owner / admin / viewer │ this                                   │ Direct role assignment per tenant.                                                                                                                                                       │
  ├────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ member                 │ union of this ∪ owner ∪ admin ∪ viewer │ Anyone directly added, or holding any of the three roles, is a member. Used by libcloud_api.can_connect and provider.can_use to propagate tenant membership to the API/provider objects. │
  ├────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ can_assign_owner       │ computedUserset → owner                │ Only tenant owners can assign the owner role.                                                                                                                                            │
  ├────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ can_assign_admin       │ computedUserset → owner                │ Only tenant owners can assign the admin role (admins cannot promote peers).                                                                                                              │
  ├────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ can_assign_viewer      │ union of owner ∪ admin                 │ Owners and admins can assign viewer.                                                                                                                                                     │
  ├────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ can_manage_credentials │ computedUserset → owner                │ Backend cloud credentials for the tenant can be updated only by the tenant owner (and superadmin, who is owner on both tenants via seed tuples). Admins/viewers are denied.              │
  ├────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ can_provision          │ union of admin ∪ owner                 │ Admins and owners can provision on the tenant.                                                                                                                                           │
  ├────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ can_read               │ union of viewer ∪ admin ∪ owner        │ All three roles can read.                                                                                                                                                                │
  └────────────────────────┴────────────────────────────────────────┴──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

  Type: libcloud_api (libcloud_api:main)

  ┌─────────────┬─────────────────────────────────────────────────┬──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ Relation    │ Rule                                            │ Meaning                                                                                                                                                                  │
  ├─────────────┼─────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ parent      │ this                                            │ Direct assignment — a tenant is linked as parent via tenant:<t> parent libcloud_api:main.                                                                                │
  ├─────────────┼─────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ can_connect │ union of this ∪ tupleToUserset(parent → member) │ A user can connect to the REST API if directly granted, or if they are a member of any tenant that parents this API. This is the gate the REST API's /v1/auth/me checks. │
  └─────────────┴─────────────────────────────────────────────────┴──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

  Type: provider (provider:aws, provider:nutanix)

  ┌──────────┬───────────────────────────────────────────────────────────┬──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ Relation │ Rule                                                      │ Meaning                                                                                                                                                                      │
  ├──────────┼───────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ parent   │ this                                                      │ Direct link from a tenant: tenant:<t> parent provider:<p>.                                                                                                                   │
  ├──────────┼───────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ allowed  │ this                                                      │ Direct per-user allow grant.                                                                                                                                                 │
  ├──────────┼───────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ can_use  │ union of this ∪ allowed ∪ tupleToUserset(parent → member) │ A user may use a provider if directly granted, directly allowed, or a member of the tenant that parents the provider. Enforced by the REST API as the can_use provider gate. │
  └──────────┴───────────────────────────────────────────────────────────┴──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

  Type: aws_region (aws_region:<binding>, e.g. aws_region:aws)

  ┌────────────────────────────┬─────────────────────────────────────────────────────────────────────────────────┬───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ Relation                   │ Rule                                                                            │ Meaning                                                                                                                                                                                       │
  ├────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ provider / tenant /        │ this                                                                            │ Direct links: provider:aws provider aws_region:aws, tenant:aws tenant aws_region:aws, and direct per-user operator/viewer.                                                                    │
  │ operator / viewer          │                                                                                 │                                                                                                                                                                                               │
  ├────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ tenant_admin               │ tupleToUserset(tenant → admin)                                                  │ Resolves the tenant linked via the tenant relation and yields its admin users.                                                                                                                │
  ├────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ tenant_owner               │ tupleToUserset(tenant → owner)                                                  │ Same, for owner.                                                                                                                                                                              │
  ├────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ tenant_viewer              │ tupleToUserset(tenant → viewer)                                                 │ Same, for viewer.                                                                                                                                                                             │
  ├────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ can_read                   │ union of viewer ∪ operator ∪ tenant_viewer ∪ tenant_admin ∪ tenant_owner ∪      │ Read access: direct viewer/operator, any tenant role via the tenant link, or anyone who can_use the parent provider.                                                                          │
  │                            │ tupleToUserset(provider → can_use)                                              │                                                                                                                                                                                               │
  ├────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ can_provision              │ intersection of (union operator ∪ tenant_admin ∪ tenant_owner) ∩                │ Provisioning requires BOTH a tenant admin/owner/operator role AND can_use on the parent provider. This is the rule that enforces cross-cloud isolation (an aws-admin is not a member of       │
  │                            │ tupleToUserset(provider → can_use)                                              │ tenant:nutanix, so the first operand is empty for nutanix_cluster:nutanix).                                                                                                                   │
  └────────────────────────────┴─────────────────────────────────────────────────────────────────────────────────┴───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

  Type: nutanix_cluster (nutanix_cluster:nutanix)

  Identical shape to aws_region:

  ┌───────────────────────────────────────┬───────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ Relation                              │ Rule                                                                                                          │
  ├───────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ provider / tenant / operator / viewer │ this                                                                                                          │
  ├───────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ tenant_admin                          │ tupleToUserset(tenant → admin)                                                                                │
  ├───────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ tenant_owner                          │ tupleToUserset(tenant → owner)                                                                                │
  ├───────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ tenant_viewer                         │ tupleToUserset(tenant → viewer)                                                                               │
  ├───────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ can_read                              │ union of viewer ∪ operator ∪ tenant_viewer ∪ tenant_admin ∪ tenant_owner ∪ tupleToUserset(provider → can_use) │
  ├───────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ can_provision                         │ intersection of (union operator ∪ tenant_admin ∪ tenant_owner) ∩ tupleToUserset(provider → can_use)           │
  └───────────────────────────────────────┴───────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

  Seed tuples (the relationships the bootstrap actually writes)

  From INITIAL_TUPLES in the same file:

  • user:superadmin superadmin platform:main
  • user:superadmin owner tenant:aws / user:superadmin owner tenant:nutanix (break-glass)
  • user:aws-owner owner tenant:aws, user:aws-admin admin tenant:aws, user:aws-viewer viewer tenant:aws
  • user:ntnx-owner owner tenant:nutanix, user:ntnx-admin admin tenant:nutanix, user:ntnx-viewer viewer tenant:nutanix
  • tenant:aws parent libcloud_api:main, tenant:nutanix parent libcloud_api:main
  • tenant:aws parent provider:aws, tenant:nutanix parent provider:nutanix
  • provider:aws provider aws_region:aws, tenant:aws tenant aws_region:aws
  • provider:nutanix provider nutanix_cluster:nutanix, tenant:nutanix tenant nutanix_cluster:nutanix

  At runtime the portal's identity service (identity_service/app/fga.py) writes additional user:<principal> <role> tenant:<cloud> tuples via assign_role/write_tuples (the superadmin tuples screen), but those are data, not new model rules.

  Validated behavior (the VALIDATION_CHECKS contract)

  The bootstrap asserts these expected outcomes, which double as the canonical statement of the policy:

  • superadmin: can_manage_platform, can_connect, can_use on both providers, can_provision on both backends → all True.
  • aws-owner: can_connect, can_use provider:aws, can_provision aws_region:aws, can_assign_admin tenant:aws → True.
  • aws-admin: can_use provider:aws, can_provision aws_region:aws, can_assign_viewer tenant:aws → True; can_assign_admin tenant:aws → False.
  • can_manage_credentials: True for aws-owner/ntnx-owner/superadmin (on their tenants); False for admins/viewers and for aws-owner on tenant:nutanix (cross-tenant denied).
  • aws-viewer: can_use provider:aws, can_read aws_region:aws → True; can_provision, can_assign_viewer → False.
  • Cross-cloud isolation: aws-admin can_use provider:nutanix and can_provision nutanix_cluster:nutanix → False.
  • ntnx-admin: can_use/can_provision on nutanix → True. ntnx-viewer: can_read → True, can_provision → False.
  • cloud-denied (authenticated in Dex but no tuples): can_connect libcloud_api:main → False.

  That is the complete set of OpenFGA rules implemented today: 6 type definitions, 22 distinct relations (with the rewrites above), 17 seed tuples, and 28 validated check expectations.
