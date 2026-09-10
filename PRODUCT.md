# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

The portal serves the full role ladder as one coherent product; no single role is
the primary audience.

- **Platform operator / superadmin** — runs the system. Creates companies and
  departments, assigns roles, manages the authorization graph, and inspects the
  whole RBAC model (OpenFGA explorer). Control-plane only: can read everything
  and grant anything, but cannot itself provision.
- **Company admin** — administers a company (a grouping), creates its departments
  (tenants), and assigns department roles.
- **Tenant owner / admin** ("department administrator") — provisions, edits,
  lists, and destroys their department's VMs, and manages their own
  admin/viewer members and the tenant credential.
- **Tenant viewer** — read-only visibility into resources.

There is also a non-portal audience: the **cloud operator / admin**, who runs
`setup.sh`, the `test_script/` operator scripts, and the CLI login tooling. They
do not use the SPA.

## Product Purpose

A **multi-tenant, self-service cloud provisioning portal**. A user signs in
through a browser and — subject to a relationship-based authorization model —
provisions, edits, lists, or destroys virtual machines on one of two backends
(AWS and Nutanix Prism Central). The user never holds cloud credentials; the
platform holds them in Vault and acts on the user's behalf.

This is a **reference / demo system**: a runnable, air-gapped lab that
demonstrates the architecture, with seeded demo tenants (`aws`, `nutanix`),
seeded users (including a deliberately-unauthorized `cloud-denied`), and
Nutanix emulators standing in for a real cluster. It is not (yet) a product
deployed for a specific organization.

## Positioning

Two things together, neither sufficient alone:

1. **The secure architecture itself.** The enforced **separation of concerns** —
   no component both decides permission and holds the credential — with
   fail-closed, relationship-based authorization (OpenFGA) at every enforcement
   point. This is the mechanism a neighboring system cannot truthfully copy.
2. **The provisioning capability.** A usable, self-service path for non-experts
   to provision VMs across AWS and Nutanix without touching a credential.

The architecture is the point; the portal is what makes that architecture real.

## Operating Context

- Deployed as Docker containers on one shared external bridge network
  (`libcloud_net`); every service except the portal, the OpenFGA visualizer, and
  the Nutanix emulators binds to `127.0.0.1`. The portal on port 3000 is the
  single front door and reverse proxy.
- Air-gapped lab. Real AWS/Nutanix accounts are replaced by seeded credentials
  and Nutanix emulators (Stoplight Prism, v4.0–v4.3) so the stack exercises
  without a real cluster.
- Bootstrap and lifecycle are scripted: `setup.sh` (build-free, air-gapped) and
  `rebuild_all.sh` (online rebuild) start it; `docker_teardown.sh` destroys it;
  `migrate2internal/` moves it to an air-gapped host. ~90 operator/verification
  scripts live under `test_script/`.
- Authentication is a real OIDC flow (Dex + LLDAP), including a scripted
  headless login for CLI/operator tooling. Bootstrap privilege is gated on a real
  superadmin login, not a static backdoor.

## Capabilities and Constraints

- **Tenancy model**: company → department → cloud. A **department is exactly a
  `tenant`**, bound to one cloud (aws|nutanix), one credential, and one Vault
  AppRole. Roles: owner/admin/viewer within a tenant, `company_admin` within a
  company, and platform-wide `superadmin`. Seeded tenants: `aws`, `nutanix`.
- **Authorization**: OpenFGA (schema 1.1) relationship model. Backend-object
  writes require an *intersection* (tenant admin/owner **and** `provider.can_use`),
  which is the intended kill switch. The libcloud REST API's policy table is
  fail-closed (unmapped route → 500, not pass-through).
- **Secrets**: Vault (KV v2), one AppRole per tenant; the REST API logs in with
  the AppRole to read a tenant credential. Human passwords live in LLDAP, not
  Vault. Client-supplied credentials are rejected by default.
- **Terminology** (durable): "department" == "tenant"; "company" is a grouping;
  "provisioner" is the `aws-admin`/`ntnx-admin` service account the
  identity-service uses to reach the backend on any user's behalf; superadmin is
  control-plane only.
- **Known security gaps are documented, not hidden** (ARCHITECTURE.md §9): live
  secrets were committed to git history, the session cookie signing key defaults
  to a placeholder, role checks trust the self-asserted cookie role, OpenFGA
  authenticates but does not authorize its own write API, and there is no TLS in
  the stack. These are real, acknowledged constraints of the reference system.

**Open decision:** whether this reference system will be hardened toward
production (the §9 findings remediated, TLS terminated, secrets rotated) has not
been decided.

## Brand Commitments

The project carries the name **"libcloud"** (`libcloud-role-portal`, base DN
`dc=libcloud,dc=local`, domain `libcloud.local`) but has no formal brand: no
logo, no voice guide, no palette or typography commitments. The current SPA is a
utilitarian role dashboard, not a designed surface.

## Evidence on Hand

- Extensive architecture/security documentation: root `ARCHITECTURE.md` plus
  per-subsystem `ARCHITECTURE.md` files, `SUMMARY.md` (session-log consolidation),
  `authentiation.md`, `onboard-user-runbook.md`, `design_company_department.md`,
  `vault_internal_mine.md`, `SCRIPTS.md`.
- A 27-slide system walkthrough deck (`presentation/`) with a generator, plus
  HTML walkthroughs (onboard-user-chain, internal-exchanges).
- Provisioning traces and operator logs (`.log`, `.out`, `.stderr` files).
- Seeded demo data: 8 LLDAP users, 30 inert pool users, 2 tenants, 48 OpenFGA
  tuples, emulated Nutanix clusters.

**Absences future work must not fabricate:** there are no real customers,
testimonials, benchmarks, or case studies. Do not invent them.

## Product Principles

1. **Separation of concerns is load-bearing.** No component may both decide
   permission and hold the credential; identity, session, authorization, secrets,
   and cloud abstraction stay split across five services.
2. **Fail closed.** An unmapped, undecidable, or undiscoverable authorization
   decision denies by default, never allows.
3. **One front door.** The user's browser talks only to the portal; every other
   service is loopback-bound, and the user never touches a cloud credential.
4. **Reference-grade and honest.** The system exists to demonstrate the
   architecture; its known gaps are documented openly rather than papered over.
5. **Serve the full role ladder as one product.** Superadmin, company admin,
   owner, admin, and viewer are equally the audience of the portal, not an
   afterthought to the operator tooling.
