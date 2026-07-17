  Are all the REST API authenticated before processing?" — i.e., "is every libcloud REST endpoint gated by authentication
  before its handler runs, and are there any anonymous/unauthenticated endpoints?"

  The closest existing questions are:

  ┌───────────────────────────────────────────────────┬────────────────────────────────────────────────┬─────────────────────────────────────────────────────┐
  │ Existing Q                                        │ What it actually asks                          │ Why it's not the same                               │
  ├───────────────────────────────────────────────────┼────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
  │ q1 OpenFGA enforcing OIDC authn?                  │ Authn on OpenFGA's API, not the libcloud REST  │ Different surface                                   │
  │                                                   │ API                                            │                                                     │
  ├───────────────────────────────────────────────────┼────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
  │ q9 Who authenticated and when?                    │ Attribution of sessions that did authenticate  │ Doesn't ask about coverage / bypass                 │
  ├───────────────────────────────────────────────────┼────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
  │ q26 Direct OpenFGA access bypassing the REST API  │ Callers skipping the REST API to hit OpenFGA   │ Opposite direction — about OpenFGA, not REST        │
  │                                                   │                                                │ coverage                                            │
  ├───────────────────────────────────────────────────┼────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
  │ q15 Did a readonly/denied principal attempt a     │ Authz on mutating verbs                        │ Assumes authn already happened                      │
  │ write?                                            │                                                │                                                     │
  └───────────────────────────────────────────────────┴────────────────────────────────────────────────┴─────────────────────────────────────────────────────┘

  So the specific question — "are all REST API endpoints authenticated before processing, and is there any endpoint that bypasses authn/authz?" — is not asked
  anywhere in the pack. This is a real gap, because the codebase is explicitly designed with a bypass path: make_authorized_router() wraps provisioning
  routers in AuthorizedAPIRoute, but auth/providers/health deliberately stay on plain APIRouter ("so they bypass the policy table" —
  app/auth/authorized_route.py:131-133), and /health is added directly on the app (app/main.py:35-37).

  Other similar REST-API-security questions that are missing

  These are the same class of question (endpoint-level security coverage of the REST API) and are absent from the 32-question pack. Grouped by theme:

  Authentication coverage
  1. Are all REST endpoints authenticated before processing? (the one you asked) — which routes are exempt (/health, /v1/auth/login, /v1/providers/*?) and
     is each exemption justified/documented?
  2. Is the bearer token accepted only from the Authorization header (never query string, which leaks into docker logs/nginx access logs)?
  3. Are long-lived/static/bootstrap tokens accepted on any route (e.g., admin/backdoor)?
  4. Is token validation actually run on every request, or is any result cached/skipped (e.g., a "trusted internal" fast path)?

  Authorization coverage
  5. Is every route registered through AuthorizedAPIRoute, or do any handlers use plain APIRouter and thus bypass the policy table? (today:
     auth/providers/health)
  6. Does every "{method} {path}" have a policies.json entry, and does a missing entry truly fail-closed (500 policy_unknown_operation) in production —
     verified, not assumed?
  7. For connection_required=false routes, is check_scopes alone sufficient? Could a low-scope principal reach an admin-only endpoint that has no connection
     requirement?
  8. Are all mutating verbs (POST/PUT/DELETE/PATCH) gated by a mutating scope, and is there any GET that performs a state change (side effect through a read
     verb)?
  9. Are action-conditional scopes (authz_scope_by_body_field) tamper-proof — can a client pick a less-privileged scope by sending an unexpected body field
     value?

  Input trust / injection
  10. Is the X-Provider-Connection header validated against the caller's tenant/allowed_providers, or can a user inject an arbitrary provider/auth_binding
      (IDOR / cross-tenant)?
  11. Are all request bodies validated by Pydantic models (no Request/raw-body handlers that skip validation)?
  12. Are provider-supplied strings (node names, image IDs, bucket names) sanitized before being passed to libcloud drivers / shell / SQL?
  13. Is the OpenAPI/Swagger UI (/docs, /openapi.json) exposed in production? (info disclosure of the full attack surface)

  Transport / exposure
  14. Is HTTPS enforced on the libcloud REST API itself (uvicorn), not just OpenFGA? (q3 only checks OpenFGA TLS)
  15. Are CORS headers configured, and is the API reachable cross-origin from browsers?
  16. Is there a per-endpoint / per-principal rate limit or throttle?

  Response hygiene / DoS
  17. Do error responses leak stack traces / internal paths (debug mode on)?
  18. Are provider credentials ever returned in a response body or written to logs?
  19. Are request bodies size-limited (DoS via large payloads / multipart uploads)?
  20. Is there replay protection (nonce/jti) on mutating requests?

  Verifiability
  21. Can we enumerate, from logs alone, the full list of routes that bypassed authn/authz in a given window? (today: no — bypass routes aren't tagged in
      auth_audit.log or the access log)

  If you want, I can add these as a new "Tier 7 — REST API surface coverage" section in question_based_logging.md and generate matching q33–q53 functions in
  security_log_queries.sh (the runnable ones — e.g., enumerate bypass routes by diffing the OpenAPI spec against policies.json, grep /docs exposure, check
  uvicorn TLS). Say the word and I'll do it.

