
 show me the table of the mapping between the user and privileges to access the libcloud REST API server.                                                     
                                                                                                                                                               

  Searching the codebase for user-to-privilege mappings for the libcloud REST API.

    Grepped, globbed, read 3 greps, 2 globs, 1 file
    … 3 earlier items hidden
    Read authorization.md
    Globbed "**/principal_map.json" in .
    Grepped "...nied|VALIDATION_CHECKS|INITIAL_TUPLES" in .

  Checking Dex users, principal mapping, and JWT scopes for a complete picture.

    Read, grepped 4 files, 1 grep
    … 2 earlier items hidden
    Grepped "...|cloud-admin|cloud-readonly|principal" in /home/ubuntu/libcloud_nutanix/libcloud.rest
    Read ...loud_nutanix/libcloud.rest/app/auth/identity.py
    Read ARCHITECTURE.md lines 250-329

  The libcloud REST API uses three stacked layers: Dex identity → principal slug → JWT scopes (API operations) → OpenFGA policy (provider/backend access).
  Here is the full mapping.

  1. Users → principals → OpenFGA subjects

  ┌────────────────┬───────────────────────────────┬────────────────────┬─────────────────────┬─────────────┬────────────────┬──────────────────────────┐
  │ Dex user       │ Email                         │ OIDC sub (Phase 1) │ OpenFGA subject     │ Role        │ Tenant         │ Backend role             │
  ├────────────────┼───────────────────────────────┼────────────────────┼─────────────────────┼─────────────┼────────────────┼──────────────────────────┤
  │ cloud-admin    │ cloud-admin@libcloud.local    │ cloud-admin        │ user:cloud-admin    │ role:admin  │ tenant:default │ operator (AWS + Nutanix) │
  ├────────────────┼───────────────────────────────┼────────────────────┼─────────────────────┼─────────────┼────────────────┼──────────────────────────┤
  │ cloud-readonly │ cloud-readonly@libcloud.local │ cloud-readonly     │ user:cloud-readonly │ role:reader │ tenant:default │ viewer (AWS + Nutanix)   │
  ├────────────────┼───────────────────────────────┼────────────────────┼─────────────────────┼─────────────┼────────────────┼──────────────────────────┤
  │ cloud-denied   │ cloud-denied@libcloud.local   │ cloud-denied       │ (none — no tuples)  │ —           │ —              │ Denied at can_connect    │
  └────────────────┴───────────────────────────────┴────────────────────┴─────────────────────┴─────────────┴────────────────┴──────────────────────────┘

  Legacy script aliases (also in data/principal_map.json):

  ┌────────────────────┬───────────────────┐
  │ Legacy name        │ Maps to principal │
  ├────────────────────┼───────────────────┤
  │ admin, provisioner │ cloud-admin       │
  ├────────────────────┼───────────────────┤
  │ reader             │ cloud-readonly    │
  ├────────────────────┼───────────────────┤
  │ outsider           │ cloud-denied      │
  └────────────────────┴───────────────────┘

  ────────────────────────────────────────

  2. OpenFGA privileges (what actually gates REST API cloud access)

  These are the checks libcloud REST runs on every compute/network route with a connection (can_connect → can_use → can_provision / can_read):

  ┌──────────┬────────────────────────┬────────────────┬─────────────────────┬───────────────────────────────┬───────┬───────────────────────────┬─────────┐
  │ Principa │ Connect to             │ Use            │ Use                 │ Provision                     │ Read  │ Provision                 │ Read    │
  │ l        │ API<br>libcloud_api:ma │ AWS<br>provide │ Nutanix<br>provider │ AWS<br>aws_region:ap-southeas │ AWS   │ Nutanix<br>nutanix_cluste │ Nutanix │
  │          │ in                     │ r:aws          │ :nutanix            │ t-1                           │       │ r:lab                     │         │
  ├──────────┼────────────────────────┼────────────────┼─────────────────────┼───────────────────────────────┼───────┼───────────────────────────┼─────────┤
  │ cloud-ad │ ✓                      │ ✓              │ ✓                   │ ✓                             │ ✓     │ ✓                         │ ✓       │
  │ min      │                        │                │                     │                               │       │                           │         │
  ├──────────┼────────────────────────┼────────────────┼─────────────────────┼───────────────────────────────┼───────┼───────────────────────────┼─────────┤
  │ cloud-re │ ✓                     │ ✓             │ ✓                  │ ✗                            │ ✓    │ ✗                        │ ✓      │
  │ adonly   │                        │                │                     │                               │       │                           │         │
  ├──────────┼────────────────────────┼────────────────┼─────────────────────┼───────────────────────────────┼───────┼───────────────────────────┼─────────┤
  │ cloud-de │ ✗                     │ ✗             │ ✗                  │ ✗                            │ ✗    │ ✗                        │ ✗      │
  │ nied     │                        │                │                     │                               │       │                           │         │
  └──────────┴────────────────────────┴────────────────┴─────────────────────┴───────────────────────────────┴───────┴───────────────────────────┴─────────┘

  cloud-denied is authenticated in Dex but has zero OpenFGA tuples, so all policy checks fail.

  ────────────────────────────────────────

  3. JWT API scopes (libcloud REST operation layer)

  After OIDC login, libcloud REST assigns scopes from the resolved principal (identity.py), not from Dex claims:

  ┌────────┬─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┬─────────┐
  │ Princi │ JWT scopes                                                                                                                          │ Provide │
  │ pal    │                                                                                                                                     │ rs      │
  │        │                                                                                                                                     │ allowed │
  ├────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┼─────────┤
  │ cloud- │ compute:read, compute:image:read, compute:size:read, compute:location:read, compute:node:create, compute:node:delete,               │ * (all) │
  │ admin  │ compute:node:power, compute:node:update, compute:volume:manage, compute:snapshot:manage, compute:network:read,                      │         │
  │        │ compute:network:manage, compute:keypair:manage, jobs:read                                                                           │         │
  ├────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┼─────────┤
  │ cloud- │ compute:read, compute:image:read, compute:size:read, compute:location:read, compute:network:read, jobs:read                         │ aws,    │
  │ readon │                                                                                                                                     │ nutanix │
  │ ly     │                                                                                                                                     │         │
  ├────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┼─────────┤
  │ cloud- │ Same read scopes as readonly*                                                                                                       │ aws,    │
  │ denied │                                                                                                                                     │ nutanix │
  └────────┴─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┴─────────┘

  \*cloud-denied gets read scopes in the JWT, but OpenFGA blocks access before any cloud operation succeeds.

  Write operations require both the JWT scope and OpenFGA can_provision; read operations require JWT read scope and OpenFGA can_read.

  ────────────────────────────────────────

  4. Routes that skip OpenFGA

  ┌───────────────────────────┬───────────────────────────────┐
  │ Route                     │ What is checked               │
  ├───────────────────────────┼───────────────────────────────┤
  │ GET /v1/auth/me           │ JWT only                      │
  ├───────────────────────────┼───────────────────────────────┤
  │ POST /v1/connections:test │ JWT scope only (compute:read) │
  ├───────────────────────────┼───────────────────────────────┤
  │ POST /v1/auth/login       │ Local auth (no OpenFGA)       │
  └───────────────────────────┴───────────────────────────────┘

  ────────────────────────────────────────

  5. End-to-end flow

  Dex login (email/password)
    → OIDC token sub/email
    → principal_map.json → cloud-admin | cloud-readonly | cloud-denied
    → JWT scopes from PRINCIPAL_SCOPES
    → OpenFGA checks on user:{principal}
    → Cloud API call (if all layers pass)

  Sources: authorization.md, data/principal_map.json, dex/config.yaml, and ../libcloud.rest/app/auth/identity.py. Demo passwords live in generated/dex.env
  if you need to test each user.

                                                                                                                                                               
  should be done at the OpenFGA level                                                                                                                          
                                                                                                                                                               

  Reviewing the OpenFGA model and tuples to present the user→privilege mapping at that layer only.

    Read 2 files
    Read openfga_bootstrap.py lines 170-519
    Read ...bcloud_nutanix/libcloud.rest/app/auth/policy.py

  You're right — for libcloud REST API access, the authoritative mapping is OpenFGA, not JWT scopes in identity.py. Dex only establishes identity;
  principal_map.json maps that to a stable OpenFGA subject (user:{principal}). Policy is then decided by tuples and computed relations.

  User → OpenFGA subject → role

  ┌──────────────────────┬──────────────────────────┬──────────────────────┬─────────────────────────┬────────────────────────────────────────┐
  │ Dex user / principal │ OpenFGA subject          │ Role membership      │ Tenant                  │ Notes                                  │
  ├──────────────────────┼──────────────────────────┼──────────────────────┼─────────────────────────┼────────────────────────────────────────┤
  │ cloud-admin          │ user:cloud-admin         │ member → role:admin  │ member → tenant:default │ Full operator access                   │
  ├──────────────────────┼──────────────────────────┼──────────────────────┼─────────────────────────┼────────────────────────────────────────┤
  │ cloud-readonly       │ user:cloud-readonly      │ member → role:reader │ member → tenant:default │ Viewer only                            │
  ├──────────────────────┼──────────────────────────┼──────────────────────┼─────────────────────────┼────────────────────────────────────────┤
  │ cloud-denied         │ (no OpenFGA user tuples) │ —                    │ —                       │ Authenticated in Dex; denied by policy │
  └──────────────────────┴──────────────────────────┴──────────────────────┴─────────────────────────┴────────────────────────────────────────┘

  Legacy aliases (admin, provisioner → cloud-admin; reader → cloud-readonly; outsider → cloud-denied) resolve to the same OpenFGA subjects via
  principal_map.json.

  ────────────────────────────────────────

  Effective OpenFGA privileges (libcloud REST checks)

  These are the relations libcloud REST enforces today via policy.py → OpenFGA Check:

  ┌─────────┬────────────────────┬──────────────┬─────────────────┬─────────────────────────────┬───────────────┬──────────────────────┬───────────────────┐
  │ Princip │ can_connect<br>lib │ can_use<br>p │ can_use<br>prov │ can_provision<br>aws_region │ can_read<br>a │ can_provision<br>nut │ can_read<br>nutan │
  │ al      │ cloud_api:main     │ rovider:aws  │ ider:nutanix    │ :ap-southeast-1             │ ws_region:…   │ anix_cluster:lab     │ ix_cluster:lab    │
  ├─────────┼────────────────────┼──────────────┼─────────────────┼─────────────────────────────┼───────────────┼──────────────────────┼───────────────────┤
  │ cloud-a │ ✓                 │ ✓           │ ✓              │ ✓                          │ ✓            │ ✓                   │ ✓                │
  │ dmin    │                    │              │                 │                             │               │                      │                   │
  ├─────────┼────────────────────┼──────────────┼─────────────────┼─────────────────────────────┼───────────────┼──────────────────────┼───────────────────┤
  │ cloud-r │ ✓                 │ ✓           │ ✓              │ ✗                          │ ✓            │ ✗                   │ ✓                │
  │ eadonly │                    │              │                 │                             │               │                      │                   │
  ├─────────┼────────────────────┼──────────────┼─────────────────┼─────────────────────────────┼───────────────┼──────────────────────┼───────────────────┤
  │ cloud-d │ ✗                 │ ✗           │ ✗              │ ✗                          │ ✗            │ ✗                   │ ✗                │
  │ enied   │                    │              │                 │                             │               │                      │                   │
  └─────────┴────────────────────┴──────────────┴─────────────────┴─────────────────────────────┴───────────────┴──────────────────────┴───────────────────┘

  ────────────────────────────────────────

  How OpenFGA derives those privileges (tuple chain)

  ┌────────────────┬───────────────────────────────────────────────┬──────────────────────────────────────────────────────────────┐
  │ Principal      │ Stored tuples (direct)                        │ Inherited via role                                           │
  ├────────────────┼───────────────────────────────────────────────┼──────────────────────────────────────────────────────────────┤
  │ cloud-admin    │ user:cloud-admin → member → tenant:default    │ role:admin#member → allowed → providers; operator → backends │
  ├────────────────┼───────────────────────────────────────────────┼──────────────────────────────────────────────────────────────┤
  │ cloud-readonly │ user:cloud-readonly → member → tenant:default │ role:reader#member → allowed → providers; viewer → backends  │
  ├────────────────┼───────────────────────────────────────────────┼──────────────────────────────────────────────────────────────┤
  │ cloud-denied   │ (none)                                        │ —                                                            │
  └────────────────┴───────────────────────────────────────────────┴──────────────────────────────────────────────────────────────┘

  Computed relations:

  • can_connect on libcloud_api:main — tenant member via tenant:default → parent → API
  • can_use on provider:* — role allowed on provider or tenant membership
  • can_provision on backend — role operator and can_use on linked provider
  • can_read on backend — role viewer or operator or can_use on linked provider

  ────────────────────────────────────────

  api_scope:* (modeled in OpenFGA, not enforced by REST yet)

  OpenFGA also seeds fine-grained scope grants for model parity:

  ┌────────────────┬────────────────────────────────┬───────────────────────────────────────┐
  │ Principal      │ granted api_scope:compute_read │ granted api_scope:compute_node_create │
  ├────────────────┼────────────────────────────────┼───────────────────────────────────────┤
  │ cloud-admin    │ ✓                             │ ✓                                    │
  ├────────────────┼────────────────────────────────┼───────────────────────────────────────┤
  │ cloud-readonly │ ✓                             │ ✗                                    │
  ├────────────────┼────────────────────────────────┼───────────────────────────────────────┤
  │ cloud-denied   │ ✗                             │ ✗                                    │
  └────────────────┴────────────────────────────────┴───────────────────────────────────────┘

  These are validated in openfga_bootstrap.py (VALIDATION_CHECKS), but libcloud REST does not call OpenFGA for api_scope checks yet — it still uses
  hardcoded scopes in identity.py as a second gate before OpenFGA runs.

  ────────────────────────────────────────

  What OpenFGA checks on each REST call

  For routes with a provider connection, libcloud REST runs:

  1. can_connect → libcloud_api:main
  2. can_use → provider:{aws|nutanix}
  3. Write ops → can_provision on backend; read ops → can_read (fallback can_provision)

  Subject is always user:{resolved_principal} — e.g. user:cloud-admin.

  ────────────────────────────────────────

  Bottom line: User → privilege for API access should and does live in OpenFGA tuples (INITIAL_TUPLES in openfga_bootstrap.py). The JWT scope table in
  identity.py is a transitional duplicate; the intended end state is OpenFGA-only (can_connect / can_use / can_provision / can_read and eventually
  api_scope:* grants).

                                                                                                                                                               
  where is this mapping table stored in the filesystem.                                                                                                        
                                                                                                                                                               

    Globbed, grepped 2 globs, 1 grep
    Globbed "**/principal_map.json" in .
    Globbed "**/principal_map.json" in /home/ubuntu/libcloud_nutanix
    Grepped "INITIAL_TUPLES" in .

  The mapping is split across a few files — there is no single “mapping table” file. Each layer has its own source:

  OpenFGA privileges (the policy mapping)

  ┌──────────────────────────────────────────────────────────────────┬─────────────────────────────────────────────────────────────────────────────────────┐
  │ What                                                             │ Path                                                                                │
  ├──────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
  │ Authorization model (relation definitions: can_connect, can_use, │ /home/ubuntu/libcloud_nutanix/openfga_my/openfga_bootstrap.py — LIBCLOUD_MODEL      │
  │ etc.)                                                            │ (~line 180)                                                                         │
  ├──────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
  │ User → role → tenant → provider → backend tuples                 │ Same file — INITIAL_TUPLES (~line 414)                                              │
  ├──────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
  │ Expected allow/deny matrix (validation)                          │ Same file — VALIDATION_CHECKS (~line 458)                                           │
  ├──────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
  │ Human-readable docs                                              │ /home/ubuntu/libcloud_nutanix/openfga_my/authorization.md                           │
  └──────────────────────────────────────────────────────────────────┴─────────────────────────────────────────────────────────────────────────────────────┘

  At runtime, tuples live in the OpenFGA store (in-memory in this demo). They are seeded from INITIAL_TUPLES when you run setup.sh or openfga_bootstrap.py —
  not read from a separate JSON file on each request.

  ────────────────────────────────────────

  Identity → OpenFGA subject (who becomes user:cloud-admin, etc.)

  ┌───────────────────────────────────────────────┬────────────────────────────────────────────────────────────────────────────┐
  │ What                                          │ Path                                                                       │
  ├───────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────┤
  │ Email/sub → principal slug                    │ /home/ubuntu/libcloud_nutanix/openfga_my/data/principal_map.json           │
  ├───────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────┤
  │ Copy used by libcloud REST container          │ /home/ubuntu/libcloud_nutanix/libcloud.rest/data/principal_map.json        │
  ├───────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────┤
  │ Dex bootstrap users (userID = principal slug) │ /home/ubuntu/libcloud_nutanix/openfga_my/dex/config.yaml (staticPasswords) │
  └───────────────────────────────────────────────┴────────────────────────────────────────────────────────────────────────────┘

  ────────────────────────────────────────

  Transitional duplicate (not OpenFGA — still on disk)

  ┌────────────────────────────────────┬─────────────────────────────────────────────────────────────────────────────────────┐
  │ What                               │ Path                                                                                │
  ├────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
  │ Hardcoded JWT scopes per principal │ /home/ubuntu/libcloud_nutanix/libcloud.rest/app/auth/identity.py — PRINCIPAL_SCOPES │
  ├────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
  │ Runtime OpenFGA enforcement        │ /home/ubuntu/libcloud_nutanix/libcloud.rest/app/auth/policy.py                      │
  └────────────────────────────────────┴─────────────────────────────────────────────────────────────────────────────────────┘

  ────────────────────────────────────────

  Summary: The OpenFGA user→privilege mapping is authored in openfga_my/openfga_bootstrap.py (INITIAL_TUPLES + LIBCLOUD_MODEL). Identity resolution is in
  data/principal_map.json. To change who can provision AWS or Nutanix, edit INITIAL_TUPLES in openfga_bootstrap.py and re-run bootstrap — not identity.py.



