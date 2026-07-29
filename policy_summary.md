
 what are the policies decided at different layer in the current design: dex + lldap, vault, identity services, openfga, and libcloud.rest REST layer.        
                                                                                                                                                               

  Let me gather the policy enforcement details from each layer to give a grounded answer.

    Grepped, globbed 1 grep, 2 globs
    Grepped "...use|principal_map|audience|iss|verify" in libcloud.rest/app/auth
    Globbed "libcloud.rest/app/auth/*.py" in .
    Globbed "system_design/RBAC_SECURITY_DESIGN.md" in .

  Here's the policy layering in the current design, from the outside in. Each layer decides something different and trusts the inner layers.

  1. Dex + LLDAP — authentication ("who you are")

  ┌───────────────────────────────────────┬────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ Decides                               │ How                                                                                                            │
  ├───────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ User identity (uid, email, name,      │ LLDAP holds the directory; Dex's LDAP connector binds to LLDAP and maps idAttr=uid → sub, emailAttr=mail →     │
  │ groups)                               │ email, nameAttr=cn → name                                                                                      │
  ├───────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Password verification                 │ LLDAP (Argon2-hashed)                                                                                          │
  ├───────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Token issuance (iss, aud, kid, exp)   │ Dex mints the JWT. iss=http://login.quest4science.xyz:5556/dex, aud=libcloud-rest                              │
  ├───────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Connector selection                   │ Dex connector_id pinning                                                                                       │
  │ (lldap/google/github)                 │                                                                                                                │
  ├───────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Client registration + redirect-URI    │ Dex staticClients (libcloud-rest, libcloud-portal) — rejects unknown client_id                                 │
  │ allow-list                            │                                                                                                                │
  ├───────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Signing-key rotation                  │ Dex storage: memory rotates every 6h; OpenFGA v1.16.0 RefreshUnknownKID self-heals                             │
  ├───────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ client_secret validation              │ Dex validates on token exchange                                                                                │
  └───────────────────────────────────────┴────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

  Dex does NO authorization — it only authenticates and mints tokens. The sub/email claims become the principal that downstream layers authorize.

  2. Vault — credential storage & read gate

  ┌─────────────────────┬───────────────────────────────────────────────────────────────────────────────────────────────────────────────────┬──────────────┐
  │ Decides             │ How                                                                                                               │              │
  ├─────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────┼──────────────┤
  │ Who can READ cloud  │ Vault issues a read-only token to libcloud-rest (policy libcloud-rest-read); libcloud-rest can only read          │              │
  │ backend creds       │ secret/data/libcloud/<binding>, never write                                                                       │              │
  ├─────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────┼──────────────┤
  │ Where creds live    │ `secret/data/libcloud/<aws                                                                                        │ nutanix>`    │
  │                     │                                                                                                                   │ per-tenant   │
  ├─────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────┼──────────────┤
  │ Who can WRITE creds │ Not Vault's decision — gated by OpenFGA can_manage_credentials (owner only) via set_tenant_credentials.py, which  │              │
  │                     │ authenticates to Vault as the user (not the libcloud-rest read token)                                             │              │
  └─────────────────────┴───────────────────────────────────────────────────────────────────────────────────────────────────────────────────┴──────────────┘

  3. Identity service — session & orchestration (not authz)

  ┌─────────────────────────┬──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ Decides                 │ How                                                                                                                          │
  ├─────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Session lifecycle       │ /api/auth/begin → Dex authorize URL; /api/auth/exchange → code-for-token + session cookie; /api/session → validate           │
  ├─────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Role derivation (UX)    │ FgaService.role_for(principal) calls OpenFGA /check for can_manage_platform / owner / admin → returns                        │
  │                         │ superadmin/owner/admin/viewer. Frontend role checks are UX-only (fga.py:80-82)                                               │
  ├─────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ User provisioning       │ create/modify/delete LLDAP users — gated by superadmin JWT                                                                   │
  │ (LLDAP)                 │                                                                                                                              │
  ├─────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Provision/deprovision   │ Shells out to deprovision_<cloud>.sh with the provisioner token; the actual authz is delegated to libcloud.rest + OpenFGA    │
  │ orchestration           │                                                                                                                              │
  └─────────────────────────┴──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

  The identity service is a policy enforcement orchestrator, not a policy decision point — it delegates every authz decision to OpenFGA and libcloud.rest.

  4. OpenFGA — authorization (the ReBAC source of truth)

  This is the actual policy decision point. The model (openfga_postgres/openfga_bootstrap.py) defines:

  ┌────────────────────────────────┬───────────────────────────────────────────────┬───────────────────────────────────────────────────────────────────────┐
  │ Relation                       │ Who holds it                                  │ Decides                                                               │
  ├────────────────────────────────┼───────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────┤
  │ can_manage_platform            │ superadmin                                    │ platform-level admin (assign owner, global policy, IAM mapping,       │
  │                                │                                               │ tenant lifecycle)                                                     │
  ├────────────────────────────────┼───────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────┤
  │ can_assign_owner               │ superadmin (via can_manage_platform)          │ who can grant/revoke tenant owners — not owner-grantable (no          │
  │                                │                                               │ privilege escalation)                                                 │
  ├────────────────────────────────┼───────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────┤
  │ can_assign_admin /             │ owner                                         │ tenant membership administration                                      │
  │ can_assign_viewer              │                                               │                                                                       │
  ├────────────────────────────────┼───────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────┤
  │ can_manage_credentials         │ owner                                         │ who can write cloud creds to Vault                                    │
  ├────────────────────────────────┼───────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────┤
  │ can_provision                  │ owner ∪ admin                                 │ create/delete VMs                                                     │
  ├────────────────────────────────┼───────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────┤
  │ can_update                     │ owner ∪ admin                                 │ edit VM params                                                        │
  ├────────────────────────────────┼───────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────┤
  │ can_read                       │ owner ∪ admin ∪ viewer ∪ superadmin(via       │ enumerate/view                                                        │
  │                                │ global_reader)                                │                                                                       │
  ├────────────────────────────────┼───────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────┤
  │ can_use(provider:<cloud>)      │ per-cloud binding                             │ per-cloud boundary enforcement                                        │
  ├────────────────────────────────┼───────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────┤
  │ can_connect                    │ on libcloud_api:main                          │ API access gate                                                       │
  └────────────────────────────────┴───────────────────────────────────────────────┴───────────────────────────────────────────────────────────────────────┘

  Every /check requires a Dex-issued JWT (OIDC authn: iss+aud+signature via JWKS). The authz decision is on the tuple's user principal, not the API caller's
  subject — so the provisioner service-account token can check user:<principal> tuples (fga.py:89-96).

  5. libcloud.rest REST — policy enforcement point (per-request gate)

  Every route goes through authorized_route.py + PolicyEngine (libcloud.rest/app/auth/policy.py). Route handlers contain zero authz logic
  (authorized_route.py:4).

  ┌───────────────────────────────┬─────────────────────────────────────────────────────────────────────────────────────────────┬──────────────────────────┐
  │ Gate                          │ Decides                                                                                     │ Where                    │
  ├───────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────┼──────────────────────────┤
  │ Token validation              │ JWT signature (JWKS), iss, aud, exp — must match Dex                                        │ oidc_service.py:55-66    │
  ├───────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────┼──────────────────────────┤
  │ Principal mapping             │ sub/email → principal slug via principal_map (by_sub / by_email)                            │ identity.py:106-150      │
  ├───────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────┼──────────────────────────┤
  │ Policy table lookup           │ METHOD path_template → {scopes_any_of, authz_scope, capability, connection_required}.       │ policy_table.py:110-122, │
  │                               │ Missing entry = 500 fail-closed                                                             │ policies.json            │
  ├───────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────┼──────────────────────────┤
  │ Scope check                   │ token must hold ≥1 of scopes_any_of (with READ_SCOPE_ALIASES expansion)                     │ policy.py:98-112         │
  ├───────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────┼──────────────────────────┤
  │ Credential policy             │ enforce_credential_policy(connection) — connection must have the required creds             │ policy.py:145            │
  ├───────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────┼──────────────────────────┤
  │ OpenFGA authz (for            │ can_connect on libcloud_api:main + can_use(provider:<cloud>) + can_provision (write scopes) │ policy.py:73-97          │
  │ connection_required routes)   │ / can_read (read scopes) on the backend object                                              │                          │
  ├───────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────┼──────────────────────────┤
  │ Driver capability             │ optional capability check (e.g. driver supports the operation)                              │ policy.py:150            │
  └───────────────────────────────┴─────────────────────────────────────────────────────────────────────────────────────────────┴──────────────────────────┘

  The enforcement order (authorized_route.py:84-120):
  1. Look up policy entry (fail-closed if missing).
  2. Validate token + map principal.
  3. If connection_required: resolve provider connection → authorize_connection (scope + credential + OpenFGA).
  4. If connection_required=false: check_scopes only.

  Trust flow (who trusts whom)

  Browser → Dex+LLDAP (authn → JWT)
    → identity-service (session + role-for-UX, delegates authz)
      → libcloud.rest (per-request: scope + credential + OpenFGA /check)
        → OpenFGA (ReBAC decision on the tuple principal)
        → Vault (read creds, read-only token)
          → cloud provider (actual operation)

  Key principle: authz is decided once (OpenFGA) and enforced at the edge (libcloud.rest). The identity service never makes an authz decision for resource
  operations — it only derives a UX role and orchestrates. Dex never decides authz. Vault only gates credential reads. This separation is what lets the same
  Dex-issued JWT flow through all layers (same iss/aud) while each layer applies its own concern.

                                                                                                                                                               
  what is the purpose of kid in the JWT token                                                                                                                  
                                                                                                                                                               

  What kid is

  The kid (Key ID) is an optional header field in a JWT that identifies which key was used to sign the token. It's not part of the payload (claims) — it's
  in the JOSE header:

  {"alg": "RS256", "kid": "f9208cef5c3fe5957b3ce58fd3e2c93a7ddeedea", "typ": "JWT"}

  The token we saw earlier in this session had exactly this: eyJhbGciOiJSUzI1NiIsImtpZCI6ImY5MjA4Y2Vm... — the kid is f9208cef....

  Why it exists

  An issuer (like Dex) typically rotates its signing keys and publishes multiple valid public keys at once in its JWKS (JSON Web Key Set) document — the old
  key(s) remain valid for a grace period while tokens signed by them expire, and new tokens are signed by the new key. The kid tells the verifier which of 
  those public keys to use to verify this specific token's signature.

  Without kid, the verifier would have to try every key in the JWKS against the signature until one works — wasteful, and ambiguous if two keys share the
  same algorithm. With kid, the verifier does a direct hash-table lookup: jwks[kid] → the exact public key → verify.

  The rotation problem (exactly what we hit)

  This is the core of the Dex 6-hourly issue we debugged:

  1. Dex signs tokens with key A (kid=A). OpenFGA fetches the JWKS, caches {A: pubkey_A}.
  2. Every 6h, Dex rotates: new tokens are signed with key B (kid=B). The JWKS now publishes {A, B} (or just {B} after the grace period).
  3. OpenFGA's cached JWKS still only has {A}. A token arrives with kid=B.
  4. Without RefreshUnknownKID: the verifier looks up B in the cache, doesn't find it, returns ErrKIDNotFound immediately → invalid_claims. Every call
     fails until OpenFGA is restarted (forcing a fresh JWKS fetch). This was the v1.8.16 behavior.
  5. With RefreshUnknownKID: true (OpenFGA v1.16.0, PR #3101): the verifier sees an unknown kid, triggers a background JWKS refetch (rate-limited 1/min),
     and the next token with kid=B succeeds. The single token that triggered the refresh fails, but the system self-heals.

  So kid is the mechanism that makes key rotation work — and also the mechanism that exposes stale-JWKS bugs when the verifier doesn't refresh on an unknown
  kid.

  In this system specifically

  • Dex (storage: memory) rotates its signing key every 6h. Each rotation produces a new kid (a hash of the key, e.g. f9208cef...). Dex publishes its
    current keys at http://dex:5556/dex/keys (the JWKS endpoint).
  • OpenFGA fetches that JWKS, caches it by kid, and on each /check looks up the token's kid to verify the signature. v1.16.0's RefreshUnknownKID makes it
    refetch on a kid it doesn't have cached.
  • libcloud.rest (oidc_service.py) does the same via PyJWKClient — fetches Dex's JWKS, looks up kid, verifies.

  TL;DR

  kid = "which key signed me." It lets a verifier pick the right public key out of a rotating JWKS to verify the signature. It's the linchpin of signing-key
  rotation, and the reason a stale JWKS cache (not knowing a new kid) breaks token validation — which is the entire Dex 6h / OpenFGA invalid_claims saga we
  just fixed.


