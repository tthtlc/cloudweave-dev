
now explain the schema relationship inside OpenFGA: in user/relationship/object --> why or what is the meaning of user=provider:aws,relation=provider, and object=aws_region:aws                                                                                                                                   
                                                                                                                                                                                                                                                                                                                     

    Grepped, read 5 greps, 3 files
    … 5 earlier items hidden
    Grepped "...ovision|define provider|define parent" in openfga_postgres/openfga_bootstrap.py
    Read openfga_postgres/openfga_bootstrap.py lines 174-393
    Read openfga_postgres/openfga_bootstrap.py lines 505-564

  Here's the explanation of the OpenFGA schema and that specific tuple.

  OpenFGA tuple basics

  In OpenFGA every relationship is a triple: user · relation · object, read as _"subject user stands in relation to object"_. The word "user" is a historical misnomer — it's really the subject of the tuple, and it can be any of:

  • a human principal: user:alice
  • another typed object: provider:aws, tenant:aws
  • a userset (object + relation): group:eng#member

  Which subject types are legal for a given relation is declared in the type's metadata.relations.<rel>.directly_related_user_types.

  The tuple in question

   openfga_postgres/openfga_bootstrap.py lines 529-529

      {"user": "provider:aws", "relation": "provider", "object": "aws_region:aws"},

  Read plainly: "the subject provider:aws is the provider of the object aws_region:aws." In domain terms: _the AWS region resource aws_region:aws is attached to / served by the AWS provider provider:aws._

  This is a parent-style link from a backend resource up to its provider object — not a grant to a human. It is legal because the aws_region type explicitly allows a provider object as the subject of its provider relation:

   openfga_postgres/openfga_bootstrap.py lines 390-393

              "metadata": {
                  "relations": {
                      "provider": {
                          "directly_related_user_types": [{"type": "provider"}]

  and the relation itself is a plain direct assignment:

   openfga_postgres/openfga_bootstrap.py lines 327-330

              "type": "aws_region",
              "relations": {
                  "provider": {"this": {}},
                  "tenant": {"this": {}},

  Why this tuple exists — the tupleToUserset bridge

  The provider link is what lets aws_region inherit access decisions from the provider object. Look at how aws_region.can_read and can_provision are computed:

   openfga_postgres/openfga_bootstrap.py lines 351-388

                  "can_read": {
                      "union": {
                          "child": [
                              {"computedUserset": {"relation": "viewer"}},
                              {"computedUserset": {"relation": "operator"}},
                              {"computedUserset": {"relation": "tenant_viewer"}},
                              {"computedUserset": {"relation": "tenant_admin"}},
                              {"computedUserset": {"relation": "tenant_owner"}},
                              {
                                  "tupleToUserset": {
                                      "tupleset": {"relation": "provider"},
                                      "computedUserset": {"relation": "can_use"},
                                  }
                              },
                          ]
                      }
                  },
                  "can_provision": {
                      "intersection": {
                          "child": [
                              {
                                  "union": {
                                      "child": [
                                          {"computedUserset": {"relation": "operator"}},
                                          {"computedUserset": {"relation": "tenant_admin"}},
                                          {"computedUserset": {"relation": "tenant_owner"}},
                                      ]
                                  }
                              },
                              {
                                  "tupleToUserset": {
                                      "tupleset": {"relation": "provider"},
                                      "computedUserset": {"relation": "can_use"},
                                  }
                              },
                          ]
                      }
                  },

  The tupleToUserset rewrite reads: _"for this aws_region, walk the tuples whose relation is provider (i.e. find provider:aws), then compute that object's can_use userset."_ So the tuple provider:aws → provider → aws_region:aws is the edge that the rewrite traverses. Without it, OpenFGA would have no way
  to know which provider backs the region, and can_read/can_provision could never resolve the provider-side branch.

  Concretely, when you ask Check(user:aws-owner, can_provision, aws_region:aws):
  1. can_provision is an intersection of two conditions — both must hold.
  2. Branch A: aws-owner is operator/tenant_admin/tenant_owner on the region — resolved via the tenant tuple (tenant:aws → tenant → aws_region:aws, line 530) plus tenant:aws's owner relation.
  3. Branch B: tupleToUserset over the provider tuple (line 529) lands on provider:aws, then evaluates provider:aws.can_use, which itself fans out through provider.parent → tenant:aws.member (line 521) to the tenant's owner/admin/viewer.
  4. Both branches pass for aws-owner → allowed.

  So the provider tuple is the provider-side gate ("you may only touch this region if you can_use the provider that owns it"), while the tenant tuple is the role-propagation gate ("your owner/admin/viewer role on the tenant decides read vs. provision").

  The two parallel parent links on aws_region

  aws_region:aws is deliberately wired to two parents, each carrying a different responsibility:

  ┌─────────────────────────────────────────────────────┬──────────┬────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ Tuple                                               │ Relation │ Purpose in the model                                                                                                                                                                               │
  ├─────────────────────────────────────────────────────┼──────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ provider:aws → provider → aws_region:aws (line 529) │ provider │ tupleToUserset bridge to provider.can_use — gates whether the caller may use the AWS provider at all (read + provision).                                                                           │
  ├─────────────────────────────────────────────────────┼──────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ tenant:aws → tenant → aws_region:aws (line 530)     │ tenant   │ tupleToUserset bridge to tenant.admin/owner/viewer (the tenant_admin/tenant_owner/tenant_viewer computedUsersets) — propagates the caller's role so the region can distinguish read vs. provision. │
  └─────────────────────────────────────────────────────┴──────────┴────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

  They are kept separate because the two questions are independent:

  • _"Is this region part of the AWS provider?"_ → answered by the provider link.
  • _"What role does the caller have on the owning tenant?"_ → answered by the tenant link.

  can_provision requires both (intersection): you need a privileged role on the tenant and use-rights on the provider. can_read accepts either the role-based branches or the provider can_use branch (union), so a viewer who is a tenant member can read even though they can't provision.

  Where the provider's can_use itself comes from

  To close the loop, provider:aws.can_use is not stored directly — it's computed from the provider's own parent link:

   openfga_postgres/openfga_bootstrap.py lines 299-312

                  "can_use": {
                      "union": {
                          "child": [
                              {"this": {}},
                              {"computedUserset": {"relation": "allowed"}},
                              {
                                  "tupleToUserset": {
                                      "tupleset": {"relation": "parent"},
                                      "computedUserset": {"relation": "member"},
                                  }
                              },
                          ]
                      }
                  },

  with the parent tuple:

   openfga_postgres/openfga_bootstrap.py lines 521-521

      {"user": "tenant:aws", "relation": "parent", "object": "provider:aws"},

  So the full privilege chain for aws_region:aws is:

  user:aws-owner ──owner──▶ tenant:aws ──parent──▶ provider:aws ──provider──▶ aws_region:aws
          (tenant role)        (tenant→provider)      (provider.can_use)         (region can_provision/can_read)

  TL;DR

  user=provider:aws, relation=provider, object=aws_region:aws is not a grant to a person. It is the "this AWS region is backed by the AWS provider" edge. The "user" slot is just OpenFGA's name for the tuple subject, and here the subject is another object (provider:aws), which is explicitly permitted by
  the aws_region type's metadata. The model's tupleToUserset rewrites on can_read and can_provision traverse exactly this edge to inherit the provider's can_use decision, making it the provider-side gate that — together with the parallel tenant edge (role propagation) — decides who can read vs. provision
  the region.




