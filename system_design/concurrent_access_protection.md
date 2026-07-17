To protect against concurrent system making parallel changes to the resources, one strategy to be used will be to ensure all WRITE must immediately be preceeded by READ and confirm them as CLEAN and Original, and if yes, same as original, then implement the changes instantaneously.


The document rbac_v2.md is proposing some changes:



Traditional RBAC cannot express the multi-tenant, hierarchical resource relationships required by the CMP. A user may be a `viewer` on one VM but an `operator` on another, within the same project, under the same tenant. OpenFGA implements Google's Zanzibar model, where access is determined by **relationships between entities** (users, groups, resources, and parent resources) rather than static role assignments. ReBAC is a superset of RBAC and natively covers ABAC scenarios when attributes are expressed as relationships. [openfga](https://openfga.dev/docs/authorization-concepts)


