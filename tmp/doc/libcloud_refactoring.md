  consider refactoring libcloud.rest - what are the files not needed? what is the purpose of "tests" and are they essential or in use? libcloud.rest for       
  implementing the REST API, are there any authorization logic build into it? is this authorization logic part of OpenFGA?                                     
                                                                                                                                                               
  $ cd /home/ubuntu/libcloud_nutanix/libcloud.rest && head -5 doc/tmp.md doc/conn.md doc/design.md doc/API.md doc/aws_cli_mapping_2_json0.md
    doc/aws_cli_mapping_2_json2.md doc/mylist_ec2.sh 2>/dev/null; echo "---"; head -3 /home/ubuntu/libcloud_nutanix/connection.md
    /home/ubuntu/libcloud_nutanix/error_vs_failure.md 2>/dev/null 366ms
    … 52 output lines hidden · ctrl+o to expand
                                                                                                                                                              
  What is the difference between `authz_fga_denied` (403) and `authz_fga_error` (503) in the libcloud REST error taxonomy?** Which one indicates a       …

    Read libcloud.rest/ARCHITECTURE.md

  Here's my analysis of libcloud.rest/ after reading the code.

  1. Files not needed (refactoring candidates)

  Scratch / chat-export artifacts (safe to delete):
  • doc/tmp.md — scratch notes
  • doc/conn.md — chat transcript dump
  • doc/mylist_ec2.sh — a shell script that doesn't belong in doc/
  • doc/authen/prompt.md — prompt scratch
  • doc/aws_cli_mapping_2_json0.md, doc/aws_cli_mapping_2_json2.md — duplicate variants of aws_cli_mapping_2_json.md
  • doc/design.md — superseded by ARCHITECTURE.md and doc/security_redesign.md
  • Repo-root connection.md, error_vs_failure.md (outside libcloud.rest/) — chat exports, not source

  Build / generated artifacts (should be .gitignored, not committed):
  • .pytest_cache/, every __pycache__/
  • generated/openapi.json, generated/openapi.yaml — produced by scripts/generate_openapi.py

  Empty / placeholder:
  • app/secrets/ — only contains __pycache__, no source. Either implement or remove.

  Large reference data (consider moving out of the repo or into Git LFS):
  • doc/nutanix_yaml/*.yaml — ~5.5 MB of Nutanix swagger specs. Reference-only; not consumed by code.

  Already being cleaned up (per git status): the root-level .dat/.md.old files and the loose libcloud.rest/*.md files are being moved into
  libcloud.rest/doc/. Finish that move and delete the duplicates.

  Possible doc consolidation: ARCHITECTURE.md (111 KB) overlaps heavily with doc/security.md, doc/security_redesign.md, doc/authentication_authorization.md,
  and doc/rest_api_summary.md. Pick one canonical security doc and archive the rest.

  2. Purpose of tests/ — essential and in use

  The tests/ directory is small but real and wired into the authz design:

  • tests/conftest.py — forces AUTH_MODE=local, FGA_ENABLED=false, ALLOW_CLIENT_CREDENTIALS=false before app import, then provides fixtures: mint_token
    (mints locally-valid JWTs with chosen scopes), client (FastAPI TestClient), connection_header, auth_headers.
  • tests/test_authorization.py — end-to-end tests that prove route handlers contain zero authz logic yet are still gated by AuthorizedAPIRoute +
    policies.json (scope pass/fail, compute:read alias, 401 missing token, 400 missing connection, action-conditional scopes for PATCH /nodes/{id},
    connection-less jobs:read gate, admin reload scope).
  • tests/test_policy_table.py — unit tests for PolicyTable: load + defaults, fail-closed on unknown operation, invalid-entry rejection, mtime-based hot
    reload, explicit reload.

  They are run via pytest and are the only verification of the authorization layer. They are essential — do not remove. The only cleanup I'd suggest is
  adding a pytest.ini/pyproject config and a CI step so they actually run on every PR.

  3. Is authorization logic built into libcloud.rest?

  Yes — substantially. It lives almost entirely in app/auth/:

   libcloud.rest/app/auth/authorized_route.py lines 1-2

  class AuthorizedAPIRoute(APIRoute):
      """APIRoute subclass that authorizes every request before the handler runs."""

  The enforcement flow is centralized in AuthorizedAPIRoute.get_route_handler (lines 80–124): it looks up the policy entry for METHOD path in policies.json,
  resolves TokenClaims from the bearer, and either runs policy_engine.authorize_connection (scope + provider allow-list + credential policy + OpenFGA +
  capability check) or, for connection-less routes, policy_engine.check_scopes.

  The supporting pieces:
  • app/auth/policy.py — PolicyEngine: scope check with READ_SCOPE_ALIASES, allowed_providers enforcement, enforce_credential_policy, and _enforce_openfga
    (lines 73–96).
  • app/auth/policy_table.py — hot-reloadable JSON policy table (fail-closed on unknown routes).
  • app/auth/policies.json — the 55-entry policy data.
  • app/auth/identity.py — principal → scopes/providers mapping (PRINCIPAL_SCOPES, PRINCIPAL_PROVIDERS, role-suffix derivation).
  • app/auth/dependencies.py — token decode (local/oidc/hybrid), claims_from_request, connection_from_request, plus the older
    require_scopes/require_any_scopes deps used by the auth router.
  • app/auth/oidc_service.py, app/auth/service.py — token issuance/validation for OIDC and local modes.
  • app/auth/fga_client.py — HTTP client to OpenFGA.

  Route handlers in compute/, network/, storage/, connections/, jobs/, admin/ deliberately contain no authz logic; they just read request.state.connection /
  request.state.authorized_claims.

  4. Is this authorization logic part of OpenFGA?

  No — it is not part of OpenFGA. OpenFGA is a separate external service (an implementation of Google Zanzibar) that the REST API calls as a client. The
  split is:

  • Local to libcloud.rest (always enforced, even with FGA_ENABLED=false): token validation, scope checks (scopes_any_of + READ_SCOPE_ALIASES),
    allowed_providers allow-list, credential policy, principal→scope mapping, capability probing, and the policy table itself.
  • Delegated to OpenFGA (only when FGA_ENABLED=true): the relationship-based checks can_connect, can_use, can_provision, can_read against objects like
    provider:<cloud> and <obj_type>:<binding>. This is in PolicyEngine._enforce_openfga (app/auth/policy.py:73-96) and FgaClient (app/auth/fga_client.py),
    which POSTs to OpenFGA's /stores/{id}/check endpoint, optionally forwarding the caller's Dex JWT as a bearer.

  The tests confirm the separation: they set FGA_ENABLED=false and still exercise the full scope/provider/connection policy locally. So OpenFGA is an
  optional, fine-grained relationship layer layered on top of the API's own coarse-grained scope/principal authorization — it is not where the core authz
  logic lives.

  how is libcloud.rest developed - it is build from ground up by integrating libcloud Apache and combining with another REST API software for Libcloud         
  APache?                                                                                                                                                      
                                                                                                                                                               
  $ cd /home/ubuntu/libcloud_nutanix/libcloud && ls && echo "---" && git log --oneline -5 2>/dev/null; echo "---HEAD---"; git remote -v 2>/dev/null 271ms
    … 37 output lines hidden · ctrl+o to expand
    origin  https://github.com/tthtlc/cloudweave-dev.git (fetch)
    origin  https://github.com/tthtlc/cloudweave-dev.git (push)

  $ cd /home/ubuntu/libcloud_nutanix/libcloud && head -5 README.rst 2>/dev/null; echo "---nutanix driver---"; ls libcloud/compute/drivers/ | grep -i nutanix;
    echo "---check for rest api server in libcloud---"; find . -maxdepth 3 -iname "*rest*" -type d 2>/dev/null | head; ls contrib/ 2>/dev/null | head -20
    379ms
    … 24 output lines hidden · ctrl+o to expand
    utils.py
    utils_test.py

  How libcloud.rest was developed

  Short answer: it is built from the ground up as a custom FastAPI application that integrates the Apache Libcloud Python client library as its cloud-driver
  engine. It is not a fork or extension of any existing "REST API software for Apache Libcloud."

  Evidence from the codebase

  1. Apache Libcloud itself has no REST server to extend.
  Apache Libcloud is a Python client library — a unified interface over cloud provider APIs. The sibling libcloud/ directory is a clone of upstream Apache
  Libcloud (see libcloud/README.rst: "Apache Libcloud - a unified interface for the cloud … a Python library which hides differences between different cloud
  provider APIs"). Its contrib/ directory contains only utility scripts (price scrapers, contributor-list generators, test runners) — there is no REST
  server component. So there is nothing in libcloud to "combine with."

  2. The dependency is the library, not a REST framework.
  libcloud.rest/requirements.txt lists only web-app plumbing — FastAPI, uvicorn, pydantic-settings, pyjwt, passlib, python-dotenv, python-multipart.
  Notably, apache-libcloud is not in requirements.txt because it is installed from a local, likely-modified copy:

   libcloud.rest/Dockerfile lines 13-17

  COPY libcloud.rest/requirements.txt .
  RUN pip install --no-cache-dir -r requirements.txt
  COPY libcloud /libcloud
  RUN pip install --no-cache-dir /libcloud

  So the integration point is the libcloud Python package, not any REST product.

  3. The REST layer is hand-written, layer by layer.
  doc/design.md states the intent plainly: "Target is to implement a REST API wrapper that be used to talk to libcloud API with different enabled drivers."
  The app is organized into the six layers described in that design doc:

  • Transport/OpenAPI — app/main.py (FastAPI factory, router registration, /health)
  • Identity & token service — app/auth/service.py, app/auth/oidc_service.py, app/auth/identity.py
  • Authorization & policy engine — app/auth/authorized_route.py, app/auth/policy.py, app/auth/policy_table.py, app/auth/policies.json,
    app/auth/fga_client.py
  • Secret-backed provider connection registry — app/connections/ (credentials, vault_client, models, dependencies)
  • Libcloud adapter / orchestration — app/providers/factory.py, app/providers/aws.py, app/providers/nutanix.py, and the per-domain services
    app/compute/service.py, app/network/service.py, app/storage/service.py
  • Async job worker — app/jobs/worker.py

  4. The libcloud integration is direct driver construction.
  The providers layer is a thin hand-written adapter that imports libcloud's Python classes and constructs drivers:

   libcloud.rest/app/providers/aws.py lines 1-12

  from libcloud.compute.providers import get_driver
  from libcloud.compute.types import Provider
  from app.connections.models import ConnectionConfig
  def create_aws_driver(key: str, secret: str, config: ConnectionConfig):
      cls = get_driver(Provider.EC2)
      kwargs: dict = {"region": config.region or "us-east-1"}
      if config.secure is not None:
          kwargs["secure"] = config.secure
      return cls(key, secret, **kwargs)

   libcloud.rest/app/providers/nutanix.py lines 1-15

  from libcloud.compute.drivers.nutanix import NutanixNodeDriver
  from app.connections.models import ConnectionConfig
  def create_nutanix_driver(key: str, secret: str, config: ConnectionConfig) -> NutanixNodeDriver:
      return NutanixNodeDriver(
          key,
          secret,
          host=config.host or "localhost",
          port=config.port or 9440,
          secure=config.secure if config.secure is not None else True,
          api_version=config.api_version or "v4.0",
          verify_ssl_cert=config.verify_ssl_cert if config.verify_ssl_cert is not None else True,
      )

  And app/providers/factory.py selects the driver by connection.provider and probes capabilities via hasattr/getattr on the libcloud NodeDriver (lines
  20–39). The service tiers then call libcloud driver methods (driver.list_locations(), driver.create_node(), etc.) and translate the returned libcloud
  objects (Node, NodeImage, NodeSize, NodeLocation) into the API's own Pydantic response models.

  What it is not

  • It is not the official apache/libcloud-rest project (a separate, mostly-inactive Apache repo). No file in this tree imports from or references
    libcloud_rest/libcloud-rest; every import is from libcloud.compute... (the library).
  • It is not a wrapper around an existing REST server. There is no upstream REST server in libcloud to wrap.
  • It is not auto-generated from libcloud's API surface. The routes, models, scope policy table (app/auth/policies.json), and capability allowlists
    (AWS_ALLOWED_EX, NUTANIX_ALLOWED_EX in app/compute/service.py) are all hand-authored.

  Summary

  libcloud.rest is a greenfield FastAPI service, written from scratch, that uses Apache Libcloud strictly as a Python driver library (installed from a local
  clone at ../libcloud). It layers its own identity (Dex/OIDC + local JWT), authorization (in-process policy table + OpenFGA), secret resolution
  (env/Vault), connection registry, and async job system on top of libcloud's NodeDriver interface. The "REST API for libcloud" portion is entirely custom
  code in app/; libcloud contributes only the cloud-provider driver implementations.

                                                                                                                                                               
  what is the purpose of the file "./libcloud.rest/data/principal_map.json" are the same information also available inside openfga (./openfga_postgres)        
  directory?                                                                                                                                                   
                                                                                                                                                               

    Read libcloud.rest/data/principal_map.json

  $ cd /home/ubuntu/libcloud_nutanix/openfga_postgres && ls -la && echo "---" && find . -maxdepth 3 -type f | head -40 295ms
    … 37 output lines hidden · ctrl+o to expand
    ./generated/fga.env
    ./docker-compose.yml

    Read, grepped 3 files, 5 greps
    … 5 earlier items hidden
    Grepped "aws-owner|ntnx|superadmin|email|mail" in openfga_postgres/dex_bootstrap.py
    Grepped "principal_map" in libcloud.rest/app/config/settings.py
    Read libcloud.rest/app/config/settings.py lines 105-144

  Purpose of libcloud.rest/data/principal_map.json

  It is the IdP-claim → stable-principal-slug translation table used at the REST API's front door to normalize whoever just authenticated via Dex/OIDC into
  a stable internal identity.

  Contents (version 2, per-cloud tenant model):

   libcloud.rest/data/principal_map.json lines 1-16

  {
    "version": 2,
    "description": "Maps upstream IdP identifiers to stable libcloud/OpenFGA principal slugs. Per-cloud tenant model (../openfga_my/authorization.md).",
    "by_sub": {},
    "by_email": {
      "superadmin@libcloud.local": "superadmin",
      "aws-owner@libcloud.local": "aws-owner",
      "aws-admin@libcloud.local": "aws-admin",
      "aws-viewer@libcloud.local": "aws-viewer",
      "ntnx-owner@libcloud.local": "ntnx-owner",
      "ntnx-admin@libcloud.local": "ntnx-admin",
      "ntnx-viewer@libcloud.local": "ntnx-viewer",
      "cloud-denied@libcloud.local": "cloud-denied"
    },
    "legacy_username_aliases": {}
  }

  It is loaded by app/auth/identity.py::_load_map() (path comes from settings.principal_map_file = "data/principal_map.json" in app/config/settings.py:111)
  and consumed by resolve_principal() (lines 106–149). Resolution order is by_sub → by_email → legacy_username_aliases → known-slug fallback.

  The resulting slug is then used for two things, both inside libcloud.rest:

  1. Local scope/provider grants. The slug is looked up in PRINCIPAL_SCOPES / PRINCIPAL_PROVIDERS (or derived from its -owner/-admin/-viewer suffix) to
     mint the token's scope and allowed_providers claims — the coarse-grained gate enforced by PolicyEngine.check_scopes / authorize_connection in
     app/auth/policy.py.
  2. The OpenFGA user object. PolicyEngine._fga_user (app/auth/policy.py:43-46) builds user:<slug> and passes it to FgaClient.check/require for the
     relationship-based checks (can_connect, can_use, can_provision, can_read).

  So the file exists because OpenFGA does not know about Dex subjects, emails, or JWT sub values — it only knows abstract user:<slug> principals. Something
  has to translate the IdP identity to that slug, and that something is principal_map.json on the API side.

  Is the same information in openfga_postgres/?

  Partially, but not the same information and not the same file. There are two distinct concerns:

  1. The slug → permission relationships — yes, those live in OpenFGA.
  openfga_postgres/openfga_bootstrap.py seeds the same slugs as OpenFGA tuples (INITIAL_TUPLES, lines 855–880):

   openfga_postgres/openfga_bootstrap.py lines 862-869

      {"user": "user:superadmin", "relation": "superadmin", "object": "platform:main"},
      ...
      {"user": "user:aws-owner", "relation": "owner", "object": "tenant:aws"},
      {"user": "user:aws-admin", "relation": "admin", "object": "tenant:aws"},
      {"user": "user:aws-viewer", "relation": "viewer", "object": "tenant:aws"},
      {"user": "user:ntnx-owner", "relation": "owner", "object": "tenant:nutanix"},
      {"user": "user:ntnx-admin", "relation": "admin", "object": "tenant:nutanix"},
      {"user": "user:ntnx-viewer", "relation": "viewer", "object": "tenant:nutanix"},

  Dex/LLDAP also creates the matching user accounts (dex_bootstrap.py:178-184). So OpenFGA knows that user:aws-owner is owner of tenant:aws, etc.

  2. The IdP-claim → slug mapping — no, that is NOT in OpenFGA.
  OpenFGA has no concept of aws-owner@libcloud.local or of a JWT sub. The email→slug and sub→slug translation exists only in principal_map.json on the
  libcloud.rest side, because that is the component that decodes the Dex JWT and must decide which user:<slug> to present to OpenFGA. Likewise the OAuth
  scope grants per principal (compute:node:create, etc.) are enforced locally in app/auth/identity.py, not in OpenFGA.

  3. The duplicate file in openfga_postgres/data/principal_map.json is a stale, older version.
  It is version 1 with a different principal set (cloud-admin, cloud-readonly, cloud-denied) and legacy aliases (admin/provisioner/reader/outsider):

   openfga_postgres/data/principal_map.json lines 1-16

  {
    "version": 1,
    "description": "Maps upstream IdP identifiers to stable libcloud/OpenFGA principal slugs. Phase 1 Dex userID=sub equals the slug; Phase 2 add Entra
  object IDs under by_sub.",
    "by_sub": {},
    "by_email": {
      "cloud-admin@libcloud.local": "cloud-admin",
      "cloud-readonly@libcloud.local": "cloud-readonly",
      "cloud-denied@libcloud.local": "cloud-denied"
    },
    "legacy_username_aliases": {
      "admin": "cloud-admin",
      "provisioner": "cloud-admin",
      "reader": "cloud-readonly",
      "outsider": "cloud-denied"
    }
  }

  This is the Phase 1 single-tenant model (before the per-cloud aws-* / ntnx-* split). The libcloud.rest one is version 2 and is the one actually loaded at
  runtime (settings.principal_map_file = "data/principal_map.json"). The openfga_postgres copy is not read by the REST API; it looks like a leftover
  seed/reference copy from the earlier phase. openfga_bootstrap.py does not reference principal_map at all (no matches for
  principal_map/by_email/by_sub/PRINCIPAL in that file).

  Summary

  • libcloud.rest/data/principal_map.json translates an incoming Dex/OIDC identity (email/sub) into a stable principal slug. That slug feeds both the
    local scope/provider policy (identity.py) and the OpenFGA user:<slug> object (policy.py:_fga_user).
  • OpenFGA (openfga_postgres/) holds the slug → relationship → object tuples (what each slug is allowed to do), but it does not hold the IdP-claim → slug
    mapping. That mapping is exclusive to principal_map.json on the API side.
  • The openfga_postgres/data/principal_map.json file is a different, older version (v1, cloud-admin/cloud-readonly model) and is not used by the running
    REST API. It is a stale duplicate and a good refactoring/deletion candidate — the canonical copy is libcloud.rest/data/principal_map.json (v2).

                                                                                                                                                               
  can the coarse grain authorization and data/principal_map.json all be done inside the OpenFGA logic, and thus removing unnecessary coding inside             
  libcloud.rest layer?                                                                                                                                         
                                                                                                                                                               

  Short answer: partially yes, but not fully — and moving everything into OpenFGA would be a net regression. The cleanest refactor is to push identity/scope
  assignment up into the IdP (Dex), not sideways into OpenFGA. Here's the breakdown of what can move, what can't, and why.

  What OpenFGA actually is (and isn't)

  OpenFGA is a Zanzibar-style relationship-check engine: it answers "does user:U have relation R to object:O?" It is not an authentication service, it does
  not validate JWT signatures, and it has no concept of HTTP routes, request bodies, or OAuth scope strings. Whatever you ask it, you still have to
  construct the user:/object: strings and call it. So "moving logic into OpenFGA" really means "replace a local lookup with a network call whose inputs I
  still compute locally."

  What can move out of libcloud.rest (and where)

  ┌────────────────────────────────────┬──────────────┬────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ Current code                       │ Can it leave │ Better destination                                                                                 │
  │                                    │ libcloud.res │                                                                                                    │
  │                                    │ t?           │                                                                                                    │
  ├────────────────────────────────────┼──────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ PRINCIPAL_SCOPES /                 │ Yes          │ The IdP (Dex). Let Dex put scope and allowed_providers into the JWT as claims derived from LLDAP   │
  │ PRINCIPAL_PROVIDERS / _role_suffix │              │ groups. libcloud.rest then just reads claims.scope — no local table. This is the standard OAuth    │
  │ in app/auth/identity.py            │              │ pattern.                                                                                           │
  ├────────────────────────────────────┼──────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ data/principal_map.json (email/sub │ Mostly yes   │ The IdP (Dex). If Dex's sub (or a custom claim) is the slug, resolve_principal collapses to        │
  │ → slug)                            │              │ claims.sub and the file is deleted. The v1 file's own description already says this: "Phase 1 Dex  │
  │                                    │              │ userID=sub equals the slug."                                                                       │
  ├────────────────────────────────────┼──────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Local allowed_providers check in   │ Yes          │ OpenFGA's can_use(provider:<cloud>) already mirrors it. Dropping the local check is fine if you    │
  │ authorize_connection               │ (optional)   │ accept OpenFGA as the sole authority and lose the cheap fast-fail.                                 │
  ├────────────────────────────────────┼──────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ _enforce_openfga                   │ Already      │ Already in OpenFGA — no change.                                                                    │
  │ (can_connect/can_use/can_provision │ there        │                                                                                                    │
  │ /can_read)                         │              │                                                                                                    │
  └────────────────────────────────────┴──────────────┴────────────────────────────────────────────────────────────────────────────────────────────────────┘

  So you can realistically delete identity.py's principal→scope/provider tables and principal_map.json by moving that knowledge into Dex/LLDAP. That removes
  real code.

  What cannot move into OpenFGA (and why)

  1. JWT validation = authentication, not authorization. Signature, exp, iss, aud, jti revocation (app/auth/dependencies.py, oidc_service.py, service.py).
     OpenFGA trusts whatever user: string you hand it; it does not verify the bearer token. This must stay in libcloud.rest. Note that fga_client.py
     forwarding the bearer to OpenFGA is OpenFGA authenticating its caller, not OpenFGA validating the user's JWT.

  2. Token minting (login/refresh/logout/introspect). app/auth/routes.py + service.py. OpenFGA is not an IdP; it can't issue tokens.

  3. Route → required-scope resolution (policies.json + AuthorizedAPIRoute). OpenFGA doesn't know about HTTP. To ask OpenFGA "can this user call GET 
     /v1/compute/locations?" you'd have to build the object string route:GET_/v1/compute/locations in libcloud.rest anyway, then seed one tuple per
     (principal, route) — 55 routes × N principals. You don't remove code; you move it from a hot-reloadable JSON file into OpenFGA tuple seeding plus
     object-string construction. You also lose authz_scope_by_body_field (action-conditional scopes on PATCH /nodes/{id}) which is request-body-dependent
     — OpenFGA can't see the body, so libcloud.rest still has to parse it and pick the relation.

  4. Credential policy (enforce_credential_policy). This is input validation (reject client-supplied backend secrets). OpenFGA can't see the request body.
     Must stay.

  5. Driver capability probing (check_driver_capability). This depends on the live libcloud driver (hasattr(driver, "create_volume"), etc.) — a runtime
     property of the cloud, not an authz relationship. Must stay.

  6. Connection-less routes (check_scopes for GET /v1/jobs/{id}, POST /v1/admin/policies:reload). These have no backend object to check against. You'd
     have to invent synthetic OpenFGA objects just to gate them, which is more complexity than the current scope-only check.

  7. Resilience / fail-closed semantics. Today, with FGA_ENABLED=false, local scopes still gate requests (this is exactly what the test suite uses). If
     every authz decision required OpenFGA, an OpenFGA outage becomes a full API outage (the code already maps this to 503 authz_fga_unavailable). The
     local policy layer is the cheap, in-process, no-network-dependency fast path and the fail-closed safety net (policy_unknown_operation → 500).

  8. Latency. _enforce_openfga already issues up to 3 round-trips per request. Moving scope checks there adds more, where today a scope check is one set
     membership test.

  Concrete recommendation

  Instead of "move coarse-grained authz into OpenFGA," do "move identity and scope assignment into the IdP; keep a thin local policy layer; let OpenFGA own 
  relationships."

  1. Delete PRINCIPAL_SCOPES / PRINCIPAL_PROVIDERS / _role_suffix from identity.py. Have Dex emit scope and allowed_providers claims from LLDAP group
     membership. libcloud.rest reads them off the JWT.
  2. Delete data/principal_map.json by making Dex's sub (or a custom principal claim) be the slug. resolve_principal becomes a one-liner. (The v1 file
     already documented this as the Phase 1 plan; the v2 file is a stopgap.)
  3. Delete the stale duplicate openfga_postgres/data/principal_map.json (v1) — it's unused.
  4. Keep policies.json + AuthorizedAPIRoute + PolicyEngine.check_scopes + authorize_connection + enforce_credential_policy + check_driver_capability.
     These are route mapping, input validation, capability checks, and resilience — none of which OpenFGA can do.
  5. Keep the local allowed_providers check as defense-in-depth, or drop it if you trust OpenFGA's can_use — your call, but the local check is a few lines
     and a free fast-fail.

  Net effect: you remove identity.py's principal tables and principal_map.json (real deletion), you stop maintaining a second copy of "who has which
  scopes," and you don't add new network round-trips or a hard OpenFGA dependency to every request. OpenFGA keeps doing what it's good at —
  relationship-based fine-grained checks — and libcloud.rest keeps doing what only it can do (JWT auth, route gating, input validation, capability probing,
  resilience).

  The headline: the unnecessary code is the principal→scope/principal→slug mapping, and its right home is the IdP, not OpenFGA. OpenFGA is the wrong target
  for the coarse-grained layer because it doesn't authenticate, doesn't know HTTP, and can't see the request.



                                                                                                                                                               
  → quit                                                                                                                                                       
                                                                                                                                                               

  GLM 5.2 High · 32.5%                                                                                                                          Run Everything
  ~/libcloud_nutanix · main

  To resume this session: agent --resume=072674c1-24c5-46a0-b494-3558f4c92c49

