
Migrate the existing Authentik-based identity setup to Dex (https://dexidp.io) as the new OIDC provider for a new environment. The current environment uses Authentik as the primary IdP and OIDC issuer. The target design must use Dex as the OIDC issuer for applications, while minimizing future migration effort when moving from temporary local/static credentials to federated authentication through Active Directory, Microsoft Entra ID, Authentik, or another upstream IdP. Dex supports a built-in local connector with enablePasswordDB: true and staticPasswords, and Dex can also authenticate users through an upstream OIDC provider, so the design must intentionally separate temporary bootstrap identity data from the long-term federated identity model.

Authentik is the existing IdP and OIDC provider, which after authentication will pass HTTP message to OpenFGA for authorizations, before continuing to the libcloud REST API (source code ../libcloud.rest).

Consult ARCHITECTURE.md and ../libcloud.rest/REST_API_REFERENCE.md.
Make Dex the stable OIDC layer for clients, so future changes in upstream identity source require minimal client-side rework.

Migration strategy
Phase 1 (at present): temporary bootstrap using Dex local users with enablePasswordDB: true and staticPasswords.
Phase 2 (planning for future): switch authentication to an upstream provider with minimal application changes.

Explain exactly how to structure config, claim mapping, usernames, group names, subject handling, and authorization inputs so that Phase 1 and Phase 2 are compatible.
Avoid patterns that tightly couple authorization to Dex local-only identifiers unless a stable aliasing/mapping layer is introduced.

Create exactly three initial bootstrap users in Dex staticPasswords, each with bcrypt password hashes as placeholders and realistic emails/usernames:

cloud-admin: administrative user with provisioning privileges in cloud environments.
cloud-readonly: standard user who can only read cloud information, for example list users, list VMs, list networks, list cloud resources.
cloud-denied: authenticated user who is denied any access to the libcloud REST API through OpenFGA policy.

Ensure the user attributes and claims emitted through Dex can later be matched or remapped to identities from Active Directory, or Entra with minimal authorization churn. Dex local users in staticPasswords require fields such as email, hash, username, and userID, so include those explicitly.

The existing OpenFGA model for the libcloud REST API authorization layer remains.

Explain how to keep the OpenFGA subject identifiers stable across migration, for example by using an application-owned principal ID or a stable external identity mapping layer rather than directly depending on transient IdP-specific subject formats.

Claims and identity mapping

Recommended the minimal claim set the application should trust from Dex: email and username

Propose a strategy so that local bootstrap users and federated upstream users can both resolve to the same application principal representation.

Discuss tradeoffs of using sub, email, immutable external ID, or group claims as authorization inputs.

Prefer a model that does not break when migrating from static Dex users to upstream Entra identities.

Clearly state that staticPasswords is a temporary bootstrap measure only.
Provide some audit logging features.

Treat Dex as the long-lived OIDC abstraction boundary.

Keep authorization semantics in OpenFGA independent from whether authentication came from Dex local users, Active Directory, or Microsoft Entra ID.

Prefer deterministic naming for roles, groups, and principals.

Use clear YAML, JSON, and OpenFGA examples.

Do not hand-wave the identity mapping problem; provide a concrete recommendation.
