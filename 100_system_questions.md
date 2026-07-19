# 100 Questions About the libcloud Nutanix System

Generated from all `system_design/*.md` files and the full codebase.

---

## 1. Architecture & Layering (Questions 1–15)

1. **Why does the system use a three-tier security model (Dex → libcloud REST scopes → OpenFGA) instead of a single authorization layer?** What specific failure modes does each layer catch that the others would miss?

2. **What is the rationale for making libcloud REST a "provider-neutral REST facade" rather than a transparent HTTP reverse proxy to AWS/Nutanix?** What are the concrete trade-offs in terms of client compatibility, latency, and feature coverage?

3. **How does the `connection` object serve as the routing key across all three layers?** What happens if a client omits `auth_binding` — which defaults kick in, and could a viewer accidentally escalate by picking a different binding?

4. **Why does the architecture separate the Dex JWT `iss` (logical identifier) from the JWKS fetch URL (physical reachability)?** In what Docker networking scenarios do these diverge, and what breaks when they are mistakenly set to the same value?

5. **The system currently uses sqlite/in-memory for OpenFGA in the demo stack. What specific concurrency bugs, data-loss scenarios, or consistency violations become possible under concurrent provisioning that the proposed PostgreSQL migration would prevent?**

6. **Why does the design treat the `superadmin` role as a "ClusterRole" analogue rather than just another tenant owner?** What bootstrap and break-glass operations can only `superadmin` perform that tenant owners cannot?

7. **How does the `principal_map.json` indirection (by_sub, by_email, legacy_username_aliases) decouple OpenFGA tuples from IdP changes?** If an organization migrates from LLDAP to Entra ID, exactly which files change and which stay identical?

8. **What is the architectural justification for embedding JWT scopes in `identity.py` as code-config rather than storing them in OpenFGA alongside resource-level relations?** Could scope-to-role mappings also be modeled as OpenFGA tuples, and what would be gained or lost?

9. **The design document lists 12 design domains (multi-tenancy, IAM, provider abstraction, provisioning, policy, cost, observability, data model, API design, security, deployment, and architecture layering). Which of these are already implemented in the current stack, which are partially implemented, and which remain purely aspirational?**

10. **Why does the system have two separate Docker Compose projects (openfga_my/ and libcloud.rest/) instead of a single unified compose file?** What operational complexity does this split introduce for startup ordering, network sharing, and teardown?

11. **How does the `parent` relation on tenants propagate membership to `libcloud_api:main` and `provider:*` objects?** Trace the exact tupleToUserset chain that lets `aws-viewer` satisfy `can_connect` on `libcloud_api:main` without a direct tuple.

12. **The architecture says OpenFGA `can_provision` is an `intersection` (requires both tenant role AND `can_use` on the linked provider), unlike Kubernetes' purely additive RBAC. What specific cross-tenant attack would succeed if `can_provision` were modeled as a `union` instead?**

13. **Why does the system use stable application principal slugs (`user:aws-admin`) rather than raw Dex `sub` values or Entra GUIDs as OpenFGA user IDs?** Walk through the exact data migration that would be required if tuples were keyed to raw IdP `sub` values and the IdP changed.

14. **The design references a "Phase 2" migration to external IdPs (Entra/AD). What are the exact 5 files that must change, and which 8 files/components must NOT change, to keep the OpenFGA tuples invariant across the migration?**

15. **How does the Vault credential brokerage pattern (server reads cloud creds from Vault after OpenFGA authorization) differ from the alternative of embedding cloud creds in the client `connection` object?** What attack does the Vault pattern prevent that client-supplied credentials would enable?

---

## 2. Identity & Authentication (Questions 16–30)

16. **Why does Dex no longer store users directly (`enablePasswordDB`/`staticPasswords` removed) and instead authenticate against LLDAP over LDAP?** What operational benefits does this separation provide for user lifecycle management?

17. **The Dex LDAP connector emits an opaque/encoded `sub` for LDAP users. Why is email-based mapping in `principal_map.json` therefore required rather than optional?** What exactly happens in `resolve_principal()` when only `by_sub` entries exist but Dex emits a base64-encoded `sub`?

18. **What is the issuer topology problem — why must OpenFGA's `--authn-oidc-issuer` be `http://dex:5556/dex` (in-container DNS) while host-side scripts use `http://localhost:5556/dex/keys` for JWKS?** What would break if both used `localhost`?

19. **After Dex rotates its OIDC signing keys (every 6 hours with `storage: memory`), OpenFGA's cached JWKS goes stale. Why doesn't `coreos/go-oidc` do a kid-miss → JWKS refetch, and what is the exact timeline of the outage window from rotation to recovery under the current lazy-restart workaround?**

20. **The `openfga_ensure_fresh.sh` script uses a time-based throttle (marker file + TTL) rather than comparing actual key IDs. If Dex rotates keys at t=0 and the marker was written at t-10 with TTL=3600, how long does the outage last and why?** What three manual interventions can clear it immediately?

21. **Why does the libcloud REST API handle Dex key rotation gracefully (PyJWKClient refetches on kid-miss) while OpenFGA does not?** What library-level difference between Python's PyJWT and Go's `coreos/go-oidc` causes this asymmetry?

22. **The `superadmin` JWT gates Vault bootstrap, OpenFGA bootstrap, and LLDAP user CRUD. If the `superadmin` password is lost, what is the exact recovery procedure?** Is there any backdoor, or is the system permanently ungated?

23. **Why does the system use Dex as the OIDC issuer even though LLDAP has its own authentication endpoint (`/auth/simple/login`)?** What would break if libcloud REST accepted LLDAP-issued tokens directly instead of Dex-issued JWTs?

24. **The `principal_map.json` resolution order is: `by_sub` → `by_email` → `legacy_username_aliases` → `sub` if already a known slug → fail closed. What is the security implication if `by_email` were checked BEFORE `by_sub`?** Could an attacker who controls an email address hijack a principal?

25. **How does `_role_suffix()` in `identity.py` automatically assign scopes to newly created per-tenant users (`aws-dev-owner`, `aws-dev-admin`, `aws-dev-viewer`) without editing `PRINCIPAL_SCOPES`?** What naming convention must the LLDAP `uid` follow for this to work?

26. **The Phase 2 migration plan says "do not change the OAuth `client_id` (`libcloud-rest`), the issuer URL, or any OpenFGA tuple object name." Why is the `client_id` stability important — which components hard-code or cache it?**

27. **What is the difference between `OIDC_ISSUER_URL` (used for JWT `iss` validation) and `OIDC_JWKS_URL` (used for signature verification) in the libcloud REST configuration?** Why might these be different URLs in a Docker setup but identical in a Kubernetes setup?

28. **The system supports both OIDC mode and local JWT mode. What is the local JWT mode used for, and why is it disabled under OIDC?** Could both modes run simultaneously, and what confusion would that create?

29. **How does `verify_superadmin_jwt.py` validate the superadmin JWT locally without calling Dex?** What specific claims does it check (iss, sub, aud, exp), and what attack would succeed if it skipped the `sub=superadmin` check?

30. **The scripts' password resolution order is: `LIBCLOUD_PASSWORD` env → `LIBCLOUD_PASSWORD_<ROLE>` env → dev defaults (if `ALLOW_DEV_DEFAULTS=1`) → fail. What bug occurred when `LIBCLOUD_PASSWORD` from an earlier `cloud-admin` run leaked into a `cloud-readonly` invocation?** Why does the fix use per-user `LIBCLOUD_PASSWORD_CLOUD_*` instead?

---

## 3. Authorization & OpenFGA (Questions 31–45)

31. **The OpenFGA model defines `can_provision` on backend objects as an `intersection` of (tenant admin/owner OR operator) AND (`can_use` on the linked provider). Trace the exact evaluation path that makes `Check(user:aws-admin, can_provision, nutanix_cluster:lab)` return `false` — which specific sub-condition fails?**

32. **Why are there 17 seeded tuples (not 16 or 18)?** Could any of these tuples be derived at query time through model rewrites instead of being explicitly stored, and what would be the trade-off?

33. **The 25 `VALIDATION_CHECKS` in `openfga_bootstrap.py` form an effective permissions matrix. Which specific check case verifies cross-cloud isolation (an AWS user attempting Nutanix), and which verifies delegated administration (owner can assign admin, admin cannot assign owner)?**

34. **`can_manage_credentials` on a tenant is `owner`-only. How does `set_tenant_credentials.py` enforce this at the script level before writing to Vault?** What stops an `aws-admin` from calling the Vault API directly, bypassing the script's OpenFGA check?

35. **The design says "OpenFGA has no native auth" and recommends OIDC authn via Dex. Now that `--authn-method=oidc` is implemented, what specific attack is prevented that was possible when OpenFGA ran with `--authn-method=none`?**

36. **How does `PolicyEngine._enforce_openfga()` in `policy.py` forward the caller's Dex JWT to OpenFGA as `Authorization: Bearer`?** Why is it important that the same JWT authenticates both the REST API call and the OpenFGA call, rather than using a separate service account?

37. **The authorization check sequence runs: `can_connect` → `can_use` → `can_provision` (or `can_read`). Why is `can_connect` checked first, before `can_use`?** What would happen if the order were reversed — could a `cloud-denied` user learn information about provider availability?

38. **What is the distinction between `can_provision` on a `tenant:*` object vs. `can_provision` on an `aws_region:*` object?** Why are both defined in the model, and which one does `policy.py` actually check at runtime?

39. **The `routes that intentionally skip OpenFGA` include `POST /v1/connections:test`. What is the security justification for this skip?** Could a `cloud-denied` user probe connection validity through this route and learn whether AWS credentials are valid?

40. **How does `enforce_credential_policy()` in `connections/credentials.py` implement defense-in-depth against client-supplied cloud credentials?** Even if an attacker bypasses this check and includes `key`/`secret` in the `connection`, would the driver actually use them, or would Vault credentials take precedence?

41. **The `auth_binding` field in the connection object selects the per-tenant backend object and Vault secret. What is the current gap in `policy.py` that still derives the OpenFGA backend object from `connection.config.region` instead of `connection.auth_binding`?** What per-tenant isolation leak does this create?

42. **Why does `create_tenant.sh` need `SUPERADMIN_JWT` gating?** Could a tenant owner create a new sub-tenant without superadmin involvement under the current model, and if not, what model change would enable self-service tenant creation?

43. **The model supports delegated administration: `can_assign_owner` (owner-only), `can_assign_admin` (owner-only), `can_assign_viewer` (owner or admin). Why can't admins assign other admins?** What organizational risk does this restriction mitigate?

44. **How many tuples would be needed to model per-resource RBAC (e.g., individual VM ownership) under the proposed Phase 3 resource-level model?** If a tenant has 100 VMs and 10 users, how does the tuple count scale with and without `parent`-based inheritance?

45. **What is the exact JSON payload that `fga_client.py` sends to OpenFGA's `/check` endpoint?** What `authorization_model_id` does it use, and what happens if the model ID in `generated/fga.env` doesn't match the store's current model?

---

## 4. Secrets, Vault & Credential Management (Questions 46–55)

46. **The secrets inventory classifies files into five categories: delete now, move to offline backup, move to encrypted password manager, keep but harden, and keep as-is. For `generated/dex.env` specifically: under what conditions can it be safely deleted from the host, and what breaks if it is deleted while provisioning scripts are still in use?**

47. **Why does the Vault unseal key need to be stored offline rather than alongside the Vault data volume?** If both the `vault-data` volume and `generated/vault.env` (containing the unseal key) are on the same host, what attack defeats Vault's encryption guarantees?

48. **The libcloud REST API currently uses a single `VAULT_TOKEN` (either root or scoped `libcloud-rest-read`). How would per-tenant Vault AppRoles (one RoleID/SecretID per tenant) reduce the blast radius if the REST API container is compromised?** What OpenFGA relation would gate AppRole issuance?

49. **How does `vault_bootstrap.py`'s `SUPERADMIN_JWT` gating prevent an attacker who gains access to the Docker host from initializing a rogue Vault instance and reading cloud credentials?** What specific check does the bootstrap perform with the JWT before proceeding?

50. **What is the difference between the `key`/`secret` stored in Vault at `secret/data/libcloud/<tenant>` and the `LIBCLOUD_AWS_PROD_KEY`/`LIBCLOUD_AWS_PROD_SECRET` in `.env`?** Why does the design say to blank the `.env` values once Vault is seeded, and what is the fallback behavior if Vault is unreachable?

51. **The `generated/dex.env` file contains plaintext user passwords, but the running servers (Dex, LLDAP, OpenFGA, libcloud REST) never read it. Which components DO read it, and why?** Could the scripts be rewritten to eliminate the need for this file entirely?

52. **What is the Vault credential read path in a typical request?** Trace the exact call chain: `build_driver()` → `effective_credentials()` → `enforce_credential_policy()` → `resolve_server_credentials()` → `VaultClient.read_secret()`. At which point would a missing Vault secret surface as an error, and what error code would the client see?

53. **The design recommends replacing the Vault root token with a path-scoped `libcloud-rest-read` token. What exact Vault policy grants read-only access to `secret/data/libcloud/*` and `secret/metadata/libcloud/*` while denying all other paths?** What would a `sys/*` call return with this token?

54. **How does `set_tenant_credentials.py` gate credential writes on `can_manage_credentials` (owner-only)?** What prevents a malicious `aws-admin` from writing credentials to `secret/data/libcloud/aws` by calling the Vault API directly with a stolen root token?

55. **The `generated/tokens/*.jwt` and `generated/tokens/*.json` files are classified as "delete now and repeatedly." What is the difference between these two file types, and why are the `.json` files (containing refresh tokens) more dangerous to retain than the `.jwt` files (containing access tokens)?**

---

## 5. Multi-Tenancy & Isolation (Questions 56–65)

56. **How does the system enforce that an `aws-admin` has zero authority in `tenant:nutanix` without any explicit "deny" tuples?** Trace the exact OpenFGA model logic that makes `can_use provider:nutanix` fail for a user who is only a member of `tenant:aws`.

57. **The design document says multi-tenancy isolation strategy (shared DB, schema-per-tenant, or DB-per-tenant) is "not yet decided." For the current OpenFGA tuple store, what isolation model is used?** If a second tenant (`aws-dev`) is created via `create_tenant.sh`, can its users see or modify `tenant:aws` tuples?

58. **What is the tenant lifecycle for creation?** Walk through every step of `create_tenant.sh`: LLDAP user creation, OpenFGA tuple writes (9 tuples), backend object creation, and Vault path setup. Which step is the atomicity boundary, and what happens if the script fails halfway?

59. **The per-tenant credential model maps each tenant to its own Vault path and OpenFGA backend object. How does `connection.auth_binding` select the correct tenant at runtime?** If a client sends `auth_binding=aws` but `provider=nutanix`, what error is returned and at which layer?

60. **What offboarding steps are required when removing a user?** The design says: delete LLDAP user, delete all `user:<uid> * *` OpenFGA tuples, revoke Vault leases. What happens if only the LLDAP user is deleted but the OpenFGA tuples remain — can the user still authenticate and access resources?

61. **The design recommends "at least one owner per tenant, preferably two for resilience." What is the operational lockout scenario if a tenant has exactly one owner and that owner's LLDAP account is disabled or deleted?** How does `superadmin` recover this situation?

62. **Why does `superadmin` have `owner` on every tenant as break-glass?** What specific operations can `superadmin` perform on a tenant that the tenant's own owner cannot (e.g., bootstrap, cross-tenant visibility)?

63. **How does the `_role_suffix()` convention in `identity.py` scale to dynamically created tenants?** If `create_tenant.sh` creates `aws-dev-owner`, `aws-dev-admin`, and `aws-dev-viewer`, what scopes and `allowed_providers` does each automatically receive without any edit to `PRINCIPAL_SCOPES`?

64. **The `tenant` relation on backend objects (`tenant:aws tenant aws_region:ap-southeast-1`) is what propagates per-cloud roles to the backend. If this tuple were accidentally deleted, what specific checks would start failing, and would the failure be "denied" (safe) or "error" (potentially unsafe)?**

65. **What is the distinction between a "tenant" (organizational boundary with users and credentials) and a "backend object" (cloud resource like `aws_region:ap-southeast-1`)?** Could one tenant span multiple AWS regions, or is there a 1:1 mapping?

---

## 6. API Design & REST Gateway (Questions 66–75)

66. **Why does libcloud REST require cloud credentials to be passed server-side from Vault rather than client-supplied in the `connection` object?** What specific attack does `enforce_credential_policy()` prevent by rejecting any `connection.credentials.key`/`secret`?

67. **The API uses Google-style custom methods (`POST /v1/connections:test`) instead of REST-style sub-resources (`POST /v1/connections/test`). What is the design rationale for this choice, and does it affect how scopes are mapped to routes?**

68. **How does the three-hop URL mapping work: libcloud REST endpoint → Libcloud driver method → cloud API?** Pick `POST /v1/compute/nodes` for AWS and trace the exact transformation from the JSON request body to the EC2 `RunInstances` Query API call.

69. **What happens when a client calls a provider-specific operation on the wrong cloud (e.g., a Nutanix-only `ex_list_clusters` through the AWS driver)?** Where is `provider_capability_unsupported` raised, and what HTTP status code does the client receive?

70. **The API surface includes both `GET /v1/compute/networks` and `GET /v1/compute/subnets` under the `/compute` prefix. Why are network resources under `/compute` rather than a separate `/v1/networking` prefix?** Is this a design choice or an artifact of how Libcloud organizes drivers?

71. **How does `parse_connection_query()` handle the `connection` object for GET/DELETE requests where the connection is passed as a URL query parameter?** What size limitations does this impose, and at what connection JSON size would a GET request fail?

72. **The standard response envelope is `{ "data": ..., "meta": { "request_id": ... } }`. Is `request_id` propagated to OpenFGA and Vault calls for distributed tracing?** If not, how would you correlate a failed OpenFGA check in the OpenFGA logs with the originating REST API request?

73. **The API supports optional async execution via `execution.mode: async` with a `job_id` return. How does the jobs system track ownership — what prevents user A from polling user B's job status?** Is the `requested_by == claims.sub` check sufficient, or can an admin view all jobs?

74. **How does `build_driver()` in `providers/factory.py` map `connection.provider` strings (`"aws"`, `"nutanix"`) to Libcloud driver classes?** What would need to change to add a third provider (e.g., GCP or Azure) — which files must be touched and in what order?

75. **The API defines scopes like `compute:node:create`, `compute:read`, `compute:network:read`. Where is the authoritative list of all scopes defined, and how does a new route author declare which scope it requires?** What happens if a route uses a scope not listed in `ALL_SCOPES`?

---

## 7. Provisioning, Scripts & Operations (Questions 76–85)

76. **The provisioning scripts perform advisory OpenFGA pre-checks (`fga_check`) before calling the REST API, but the REST API re-runs the same checks at enforcement time. Why have both?** What security property would be lost if the scripts skipped their pre-checks and relied solely on the API's enforcement?

77. **`setup.sh` orchestrates a complex multi-step bootstrap. What is the exact ordering: Dex config render → container start → OpenFGA bootstrap → Vault bootstrap → env sync → Dex restart?** Why must Dex be restarted after bootstrap, and what specific failure occurs if this step is skipped?

78. **The `common.sh` script force-loads `generated/dex.env`, `generated/fga.env`, and `generated/authentik.env` over inherited shell exports. What specific bugs occurred when `_load_env_file` only set variables if unset/empty?** Why does "always win over inherited shell exports" matter for CI/CD environments?

79. **How does `idp_login.py` drive the Dex OAuth authorization code flow programmatically?** What HTML form does it POST to, how does it extract the authorization code, and what does it exchange it for at `/dex/token`?

80. **The token cache at `generated/tokens/{user}.json` stores refresh tokens. When does `idp_login.py` use a cached token vs. perform a full re-login?** What specific 401 error triggers cache deletion, and why is this important after Dex secret rotation?

81. **`create_tenant.sh` generates random passwords via `secrets.token_urlsafe()` for new tenant users and appends them to `openfga_my/generated/dex.env`. However, `common.sh` force-loads from `../dex/generated/dex.env`. What inconsistency does this create, and how must the operator provide the new tenant's password to provisioning scripts?**

82. **What are the five services that the scripts call (Dex, LLDAP, OpenFGA, Vault, libcloud REST), and which specific endpoints does each script use?** Which of these services enforces its own authentication, and which rely on the caller being on a trusted network?

83. **The `deprovision_aws.sh` script tears down resources. Does it also clean up OpenFGA tuples for the destroyed resources?** If not, what is the tuple drift scenario — can tuples for deleted VMs accumulate and cause authorization confusion?

84. **The `VERBOSE=1` mode in provisioning scripts enables HTTP tracing with secrets redacted. What specific redaction logic is applied, and could a partially-redacted AWS secret key be reconstructed from the logged output?**

85. **What is the purpose of `openfga_ensure_fresh.sh`'s throttle mechanism (marker file + TTL)?** Why is a time-based throttle insufficient to guarantee JWKS freshness, and what would a key-content-based check look like instead?

---

## 8. Security, Logging & Auditing (Questions 86–95)

86. **The security questions document identifies 16 existing log sources (L1–L16). Which security questions can currently be answered with existing logs, and which 5 questions have critical gaps (no log exists today)?**

87. **How does the `auth_audit.log` (L1) record each OIDC token decode?** What specific fields are captured (`ts`, `event`, `principal`, `issuer`, `subject`, `email`), and what critical field is missing that prevents correlating an audit event with an OpenFGA denial?

88. **The OpenFGA gRPC decision log (L4) captures every Check with `raw_request` (user, relation, object) and `raw_response` (allowed bool). If a `cloud-denied` user triggers a denial, can you identify which user from the OpenFGA logs alone, or must you join with L1 by timestamp?**

89. **The OpenFGA Postgres changelog table (L6) records tuple inserts and deletes with `store`, `object_type`, `object_id`, `relation`, `_user`, `operation`, `ulid`, and `inserted_at`. What critical field is missing — how do you determine WHO wrote a tuple?** Is the actor inferable from any other log?

90. **The security questions document says "Vault audit logging is not enabled" and identifies it as the highest-leverage no-code improvement. What specific command enables Vault file audit, and what questions (Q21, Q23) become answerable once it is on?**

91. **The `X-Request-ID` header is set by `RequestIDMiddleware` but is not written into the uvicorn access log (L2) and not forwarded to OpenFGA or Vault. What end-to-end traceability is lost as a result?** What one-line config change would add `X-Request-ID` to the access log?

92. **The design identifies a "scanning/brute-force" detection gap: the OpenFGA Postgres log (L8) shows `FATAL: password authentication failed for user "strapi"/"wog"/"postgres"` and `unsupported frontend protocol`. What does this traffic pattern suggest, and what network hardening would eliminate it?**

93. **The Dex log (L9) shows `login successful` with `connector_id`, `username`, `email`, and `request_id`. How would you query for all failed login attempts for a specific user?** Could you distinguish between "wrong password" and "user not found" from the Dex logs alone?

94. **The `generated/dex.env` and `libcloud.rest/.env` files contain secrets on disk. What is the specific `chmod` recommendation, and are these files covered by `.gitignore`?** Which subdirectories (`dex/`, `vault/`, `lldap/`) lack `.gitignore` files and risk accidental credential commits?

95. **What is the difference between `authz_fga_denied` (403) and `authz_fga_error` (503) in the libcloud REST error taxonomy?** Which one indicates a policy decision ("you are not allowed") vs. an infrastructure failure ("the authorization service is broken"), and why is this distinction critical for alerting?

---

## 9. Runtime, Failures & Edge Cases (Questions 96–100)

96. **What is the exact failure mode when Dex rotates its OIDC signing keys and OpenFGA's cached JWKS is stale?** Trace the error propagation path: Dex rotation → new `kid` in token → OpenFGA `invalid_claims` → `fga_client.py` HTTPError → `authz_fga_error` 503 → client sees every authorized endpoint fail. How long can this outage last under the current lazy-restart workaround?

97. **The design notes that `libcloud REST container could not reach Dex JWKS` because `OIDC_JWKS_URL=http://localhost:5556/dex/keys` resolves to the container's own localhost, not the host. What other services are affected by this same `localhost`-inside-container problem?** Why does `host.docker.internal` work for Desktop but not for Linux, and what is the Linux alternative?

98. **If `FGA_ENABLED=false` is set in `libcloud.rest/.env`, what authorization checks are skipped?** Would a `cloud-denied` user be able to provision resources, or would the scope and provider gates still block them? Is there any scenario where `FGA_ENABLED=false` is the correct production setting?

99. **What happens when `principal_map.json` is missing from the libcloud REST data volume?** The symptom is `auth_user_unknown` with an opaque `sub` in the details. Why does `_load_map()` fall back to empty maps, and why does the opaque `sub` have no scopes in `PRINCIPAL_SCOPES`?

100. **The system implements concurrent access protection by requiring "all WRITE must immediately be preceded by READ and confirm them as CLEAN and Original." Is this optimistic concurrency control implemented anywhere in the current codebase, or is it only a design proposal?** If two `aws-admin` users simultaneously call `POST /v1/compute/nodes` with the same parameters, what prevents double-provisioning?
