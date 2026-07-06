
Based on ARCHITECTURE.md (the "API Endpoint Tables" section, lines 673–2202), the libcloud.rest project is a FastAPI wrapper around Apache Libcloud's
  Nutanix and AWS drivers. It exposes 52 REST endpoints grouped into 7 categories. The server is stateless for connections (no persistence — every call
  carries a connection object).

  1. Auth APIs — /v1/auth (5 endpoints)

  Purpose: token lifecycle and identity.

  ┌───┬────────┬───────────────────────────┬───────────────────────────────────────────────────────────────────────────────────────────┐
  │ # │ Method │ Path                      │ Purpose                                                                                   │
  ├───┼────────┼───────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
  │ 1 │ POST   │ /v1/auth/login            │ Validate credentials, issue JWT access token (HS256, 15 min) + opaque refresh token (8 h) │
  ├───┼────────┼───────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
  │ 2 │ POST   │ /v1/auth/refresh          │ Renew an expired access token using a refresh token                                       │
  ├───┼────────┼───────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
  │ 3 │ POST   │ /v1/auth/logout           │ Revoke the access-token JTI and optionally the refresh token                              │
  ├───┼────────┼───────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
  │ 4 │ GET    │ /v1/auth/me               │ Return current token's username, tenant, scope, allowed providers, session id             │
  ├───┼────────┼───────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
  │ 5 │ POST   │ /v1/auth/token/introspect │ Admin-only (RFC 7662-style) decode/validate an arbitrary token                            │
  └───┴────────┴───────────────────────────┴───────────────────────────────────────────────────────────────────────────────────────────┘

  2. Provider API — /v1/providers (1 endpoint)

  ┌───┬────────┬───────────────┬────────────────────────────────────────────────────────────────────────────────────────────┐
  │ # │ Method │ Path          │ Purpose                                                                                    │
  ├───┼────────┼───────────────┼────────────────────────────────────────────────────────────────────────────────────────────┤
  │ 6 │ GET    │ /v1/providers │ Static discovery list of supported providers (aws, nutanix) and their supported operations │
  └───┴────────┴───────────────┴────────────────────────────────────────────────────────────────────────────────────────────┘

  3. Connection APIs — /v1/connections (1 endpoint)

  ┌─────┬──────┬───────────────┬───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ #   │ Meth │ Path          │ Purpose                                                                                                                   │
  │     │ od   │               │                                                                                                                           │
  ├─────┼──────┼───────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ 7   │ POST │ /v1/connectio │ Build a driver from a client-supplied connection and report its capabilities (volumes, snapshots, key pairs,              │
  │     │      │ ns:test       │ wait_until_running, auth modes). The server does not persist connections.                                                 │
  └─────┴──────┴───────────────┴───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

  4. Compute APIs — /v1/compute (25 endpoints, #11–35)

  All require a Bearer token + connection; every handler calls policy_engine.authorize_connection() first.

  Locations / Images / Sizes (#11–15) — discovery
  • GET /v1/compute/locations — AWS regions/AZs via list_locations(); Nutanix clusters via ex_list_clusters()
  • GET /v1/compute/images — list images (AWS filter *Ubuntu* default, overridable via name)
  • POST /v1/compute/images — Nutanix only: ex_create_image_from_url() or create_image() from a VM (async-capable)
  • DELETE /v1/compute/images/{image_id} — delete image (both)
  • GET /v1/compute/sizes — instance types via list_sizes()

  Nodes / VMs (#16–23) — full VM lifecycle
  • GET /v1/compute/nodes, GET /v1/compute/nodes/{node_id} — list/get VMs
  • POST /v1/compute/nodes — create VM (size/image/location/auth/network/tags/provider_options; async-capable; the richest endpoint)
  • PATCH /v1/compute/nodes/{node_id} — update (Nutanix name/desc/memory), resize (AWS), or tag
  • POST /v1/compute/nodes/{node_id}:start|:stop|:reboot — power actions
  • DELETE /v1/compute/nodes/{node_id} — destroy VM (sync or async)

  Volumes (#24–29) — block storage lifecycle
  • GET /v1/compute/volumes — list/get volumes
  • POST /v1/compute/volumes — create volume (AWS ex_volume_type/ex_encrypted/ex_iops; Nutanix ex_storage_container; optional snapshot restore;
    async-capable)
  • PATCH /v1/compute/volumes/{volume_id} — modify (AWS size/type/iops) or tag
  • DELETE /v1/compute/volumes/{volume_id} — destroy
  • POST /v1/compute/volumes/{volume_id}:attach / :detach — attach/detach to a node

  Snapshots (#30–32)
  • GET /v1/compute/snapshots — list (by id, by volume_id, or all)
  • POST /v1/compute/snapshots — create_volume_snapshot() (async-capable)
  • DELETE /v1/compute/snapshots/{snapshot_id} — destroy

  Key Pairs (#33–35) — AWS only
  • GET /v1/compute/key-pairs, POST /v1/compute/key-pairs (import or generate), DELETE /v1/compute/key-pairs/{name}

  5. Network APIs — /v1/compute tag network (15 endpoints, #36–50)

  Networks / VPCs (#36–39)
  • GET /v1/compute/networks — AWS ex_list_networks() / Nutanix ex_list_vpcs()
  • POST /v1/compute/networks — create VPC (AWS ex_create_network; Nutanix ex_create_vpc)
  • PATCH /v1/compute/networks/{network_id} — tag (both) or rename/repurpose (Nutanix ex_update_vpc)
  • DELETE /v1/compute/networks/{network_id} — delete VPC

  Subnets (#40–43)
  • GET /v1/compute/subnets — ex_list_subnets() / ex_get_subnet()
  • POST /v1/compute/subnets — AWS ex_create_subnet(name, vpc, cidr, az); Nutanix ex_create_subnet(...) (VLAN/OVERLAY, cluster, gateway, etc.)
  • PATCH /v1/compute/subnets/{subnet_id} — actions: update, nat (Nutanix), auto_public_ip/auto_ipv6 (AWS ex_modify_subnet_attribute), tag
  • DELETE /v1/compute/subnets/{subnet_id} — ex_delete_subnet()

  Storage Containers (#44) — Nutanix only
  • GET /v1/compute/storage-containers — ex_list_storage_containers_vmm() (with ex_get_storage_container_vmm fallbacks)

  Security Groups (#45–47) — Nutanix only
  • GET, POST, DELETE /v1/compute/security-groups[/{group_id}] — list/create/delete via ex_*_security_group

  Load Balancers (#48–50) — Nutanix only
  • GET, POST, DELETE /v1/compute/load-balancers[/{lb_id}] — list/create/delete via ex_*_load_balancer

  6. Job API — /v1/jobs (1 endpoint)

  ┌─────┬─────┬────────────┬─────────────────────────────────────────────────┬─────────────────────────────────────────────────────────────────────────────┐
  │ #   │ Met │ Path       │ Purpose                                         │                                                                             │
  │     │ hod │            │                                                 │                                                                             │
  ├─────┼─────┼────────────┼─────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────┤
  │ 51  │ GET │ /v1/jobs/{ │ Poll status of an async operation (lifecycle    │ failed). Owner-scoped: requester must own the job unless caller has         │
  │     │     │ job_id}    │ `pending → running → completed                  │ admin:connections:read`. Sensitive fields redacted.                         │
  └─────┴─────┴────────────┴─────────────────────────────────────────────────┴─────────────────────────────────────────────────────────────────────────────┘

  7. Health API (1 endpoint)

  ┌────┬────────┬─────────┬─────────────────────────────────────────────┐
  │ #  │ Method │ Path    │ Purpose                                     │
  ├────┼────────┼─────────┼─────────────────────────────────────────────┤
  │ 52 │ GET    │ /health │ Liveness probe returning { "status": "ok" } │
  └────┴────────┴─────────┴─────────────────────────────────────────────┘

  Cross-cutting purposes

  • Uniform abstraction: every resource endpoint translates REST request models into the appropriate libcloud driver call (AWS EC2 vs Nutanix
    NutanixNodeDriver), normalizing provider differences behind one API surface.
  • Authorization gate: policy_engine.authorize_connection() enforces JWT scopes + provider allowlists + OpenFGA relationship checks (can_connect,
    can_use, can_provision/can_read) on every compute/network route.
  • Async support: POST /nodes, POST /volumes, POST /snapshots, POST /images, and DELETE /nodes/{id} accept execution.mode=async and return a job_id for
    polling via endpoint #51.
  • Capability probing: endpoint #7 lets clients discover what a connection supports before issuing resource calls.

  Note: the numbering jumps from 7 → 11 (no #8–10) in ARCHITECTURE.md, indicating some originally planned endpoints were removed — most notably the
  list/create/get/delete connection-persistence endpoints, which the doc explicitly notes have been removed ("The server does not persist connections").
