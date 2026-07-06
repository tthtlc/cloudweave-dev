# keylog → logging location → libcloud REST answering endpoint

This document takes each question in [`keylog.md`](keylog.md) and:

1. **Rewrites it into where the log is generated** — which component in the
   stack is the only (or best) place that can observe the event, the exact
   file/hook the line should be written to, and the minimum fields the line
   must carry so the question is answerable.
2. **Maps it to a libcloud REST (`../libcloud.rest`) endpoint** that answers
   the question by reading that log (and correlating across components). The
   endpoint set is proposed as a new `/v1/audit/*` surface on the existing
   FastAPI gateway, modelled on the existing `/v1/auth/*` surface and the
   query scripts in `../openfga_my/scripts/*-query.sh`.

The mapping is consistent with
[`security_logging_gap_analysis.md`](security_logging_gap_analysis.md) §3
(the 20-row change table) and with the per-component ownership in §4 — this
file is the *question-level* view, that file is the *change-level* view.

---

## 0. Architecture recap (only the parts that matter for logging)

From `../*/ARCHITECTURE.md`:

```
LLDAP :3890/:17170  ──bind──►  Dex :5556  ──JWT──►  libcloud REST :8765  ──► AWS / Nutanix
        ▲                          ▲                       │
        │                          │                       ├─► OpenFGA :8080 (Check)
   Vault auth/ldap                 │                       └─► Vault :8200 (read secret/data/libcloud/<tenant>)
        │                          │
        └───── real-time bind ─────┘  (Vault + Dex both bind to LLDAP per login)
```

Each component owns a distinct event class:

| Component (per ARCHITECTURE.md) | Owns the answer to | Today's log sink |
|---|---|---|
| **LLDAP** (`lldap/ARCHITECTURE.md`) — LDAP bind/search on `3890`, GraphQL/auth on `17170`, no OpenLDAP `auditlog` overlay | A1, A5, A6 (bind side), E3 | `generated/lldap_audit.log` (admin-script actions only); native bind events only on stdout |
| **Dex** (`dex/ARCHITECTURE.md`) — OIDC issuer, LDAP connector to LLDAP, in-memory storage, single client `libcloud-rest` | A2, A3, A5 (login side) | stdout glog; nothing persisted |
| **Vault** (`vault/ARCHITECTURE.md`) — `auth/ldap` method binds LLDAP in real time, KV v2 at `secret/libcloud/*`, native audit device **not enabled** | A4, C1–C6, F1 | `generated/vault_audit.log` (admin scripts only); native device OFF |
| **OpenFGA server** (`openfga_my/ARCHITECTURE.md`) — `/stores/{id}/check`, tuple Write/Delete, model id | B2, B3, B4 | stdout; `generated/openfga_audit.log` (admin scripts only) |
| **libcloud REST** (`libcloud.rest/ARCHITECTURE.md`) — `RequestIDMiddleware`, `policy_engine.authorize_connection`, `audit_auth_event` in `app/auth/identity.py` | B1, B6, D1, D3, A3 (token-decode side), A6 | `data/auth_audit.log` (`oidc_token_decoded` only, **no IP, no request_id**) |
| **libcloud drivers** (`libcloud/ARCHITECTURE.md`) — AWS EC2 Query API, Nutanix v4 REST | D1 (cloud-side `request_id`/task `extId`) | not captured |
| **openfga_my scripts** — `create_tenant.sh`, `set_tenant_credentials.py`, `idp_login.py`, `superadmin_auth.sh`, offboard chain | E1, E2, E3, A3 (host-script side) | stderr only (E2); `generated/lldap_audit.log` (E3) |

Two cross-cutting primitives already exist in `libcloud.rest/app`:

- `app/common/middleware.py::RequestIDMiddleware` — sets
  `request.state.request_id` and echoes `X-Request-ID` (gap analysis #2:
  **not yet forwarded** to OpenFGA / Vault / cloud calls).
- `app/auth/identity.py::audit_auth_event` — the JSONL writer behind
  `data/auth_audit.log` (gap analysis #4: missing `source_ip` and
  `request_id`).

These two are the seams the new logging hangs off.

---

## 1. The `/v1/audit/*` REST surface (proposed)

A single new router in `libcloud.rest` answers every question below. It is
gated by a new scope `audit:read` (granted to `superadmin` only by default,
plus any principal with a `*-owner` suffix via the existing role-suffix rule
in `identity.py::_role_suffix`). It reads the JSONL files the components
above write, applies the same filters the bash query scripts already apply,
and returns the standard `{ "data": [...], "meta": { "request_id": ... } }`
envelope. Every endpoint accepts the correlation key `request_id` so a single
REST call can be joined across components.

| Endpoint | Backing log(s) | Answers |
|---|---|---|
| `GET /v1/audit/auth/binds` | `generated/lldap_bind_audit.log` | A1, A5, A6 |
| `GET /v1/audit/auth/dex-logins` | `generated/dex_login_audit.log` | A2, A3, A5 |
| `GET /v1/audit/auth/vault-ldap` | Vault native audit device (`/vault/audit/audit.log`) filtered to `auth/ldap/login/*` | A4, A5 |
| `GET /v1/audit/auth/tokens` | `data/auth_audit.log` | A3, A6 |
| `GET /v1/audit/access` | `data/rest_access.log` (new) | B1, B2, B6, D1, D3 |
| `GET /v1/audit/access/by-user/{principal}` | `data/rest_access.log` | B2 |
| `GET /v1/audit/denials` | `generated/openfga_denial.log` + 403s from `data/rest_access.log` | B2 |
| `GET /v1/audit/cloud-ops` | `data/rest_access.log` joined to `cloud_request_id` | D1, D3 |
| `GET /v1/audit/lifecycle/tenants` | `generated/tenant_audit.log` | E2 |
| `GET /v1/audit/lifecycle/groups` | `generated/lldap_audit.log` (group ops) | E3 |
| `GET /v1/audit/lifecycle/offboard-gaps` | `generated/offboard_reconcile.log` | E1 |
| `GET /v1/audit/integrity` | stat all of the above + `chattr +a`/size/mtime | F3 |

All endpoints share query params: `?from=<iso>&to=<iso>&principal=<p>
&request_id=<id>&ip=<ip>&limit=<n>&cursor=<token>`. The router is a thin
read layer — it never writes to the audit files (so it cannot weaken F3).

The implementation skeleton (no business logic, just the read/filter that
today lives in three bash scripts):

```python
# app/audit/routes.py  (new)
# app/audit/service.py (new) — reads JSONL, applies filters, returns list[dict]
# app/audit/models.py  (new) — AuditEvent, AuditQueryParams
# app/main.py          — mount the new router
# app/config/settings.py — audit_log_dir, audit_*_file paths, audit_read_scope
```

This mirrors the existing `app/auth/` layout (`routes.py` / `service.py` /
`models.py` / `dependencies.py`) and reuses `get_current_claims` +
`require_scopes("audit:read")` from `app/auth/dependencies.py`.

---

## 2. Per-question mapping

For each question: **rewrite into where the log is generated**, then the
**REST endpoint that answers it**.

### A. Identity & authentication

#### A1 — Who authenticated to LLDAP (bind), from which IP, when, and did the bind succeed or fail?

- **Generated where:** LLDAP is the only component that sees the bind — both
  Dex's service-account bind (`uid=admin,…`) and Vault's `auth/ldap` bind and
  the user's own bind during Dex login all hit `lldap:3890`. Per
  `lldap/ARCHITECTURE.md` LLDAP has no OpenLDAP `auditlog` overlay, so the
  source is the LLDAP container **stdout** (it logs bind DN + result per
  bind). Capture it (gap analysis #8) and parse into a new structured file:
  `generated/lldap_bind_audit.log` JSONL with
  `{ts, bind_dn, client_ip, client_host, bind_type: service|user, result: success|fail, reason}`.
  `client_ip` is the IP of the calling container (Dex / Vault / host script)
  as LLDAP sees it on `libcloud_net`.
- **Answered by:** `GET /v1/audit/auth/binds?bind_dn=…&ip=…&result=fail`.

#### A2 — Who logged in to Dex (user, OAuth client, redirect_uri, IP) and was the login successful?

- **Generated where:** Dex is the only component that observes the OIDC
  login (the LDAP connector's user bind happens *inside* Dex; LLDAP only
  sees Dex's source IP, not the browser IP). Per `dex/ARCHITECTURE.md` the
  `libcloud-rest` client and `skipApprovalScreen: true` mean there is exactly
  one client. Persist Dex stdout (gap analysis #7) and parse the login +
  token endpoints into `generated/dex_login_audit.log` JSONL with
  `{ts, user_id (LLDAP uid), client_id, redirect_uri, ip (browser/host), result, connector_id: lldap}`.
  Host scripts (`idp_login.py`, `superadmin_auth.sh`) append the same shape
  (gap analysis #12) so script logins are not a blind spot.
- **Answered by:** `GET /v1/audit/auth/dex-logins?principal=…&ip=…&result=fail`.

#### A3 — Who obtained a Dex-issued JWT (sub, aud, iss, jti, expiry) and when — including from host scripts?

- **Generated where:** Two sources, both required.
  1. **Dex token endpoint** — `generated/dex_login_audit.log` carries the
     issuance side (`sub`, `aud=libcloud-rest`, `iss=http://dex:5556/dex`,
     `jti`, `exp`). This is the only place host-script token acquisition is
     visible (scripts hit `/token` directly).
  2. **libcloud REST token decode** — `data/auth_audit.log` via
     `app/auth/identity.py::audit_auth_event` already writes
     `oidc_token_decoded` with `principal/issuer/sub/email`. Per gap analysis
     #4 it must add `source_ip` (from `request.client.host`) and
     `request_id` (from `request.state.request_id`) and `jti`/`exp` so a
     presented token can be joined back to its Dex issuance line by
     `sub + jti`.
- **Answered by:** `GET /v1/audit/auth/tokens?principal=…&jti=…` (decode
  side) and `GET /v1/audit/auth/dex-logins?result=success` (issuance side);
  the `jti` is the join key.

#### A4 — Who authenticated to Vault via the LDAP auth method (user, policies issued, token TTL, IP)?

- **Generated where:** Vault is the only component that sees the
  `auth/ldap/login/<uid>` call and the policies it maps to (per
  `vault/ARCHITECTURE.md` §6.1, Vault binds LLDAP in real time, then maps
  LLDAP groups → ACL policies via `auth/ldap/groups/*`). The native audit
  device is **not enabled** today (gap analysis #5). Enable
  `vault audit enable file file=/vault/audit/audit.log` in
  `vault_bootstrap.py`; the device logs every request/response including
  `auth/ldap/login/<uid>` with `user`, `policies`, `token_ttl`,
  `remote_address`. libcloud REST reads the file via the existing
  `VAULT_TOKEN` (needs a new `audit:read`-capable token or a root-token
  proxy call from the audit service).
- **Answered by:** `GET /v1/audit/auth/vault-ldap?principal=…&result=fail`.

#### A5 — Are there brute-force / credential-stuffing patterns against LLDAP, Dex, or Vault? Was there any failed logins?

- **Generated where:** This is a **derived** question — no single component
  emits "brute force"; it is a count over A1 + A2 + A4 failure lines. The
  raw events must exist first (see A1, A2, A4). The aggregation is done in
  the audit service: per-principal, per-IP failure counts in a sliding
  window, with thresholds.
- **Answered by:** `GET /v1/audit/auth/brute-force?window=15m&threshold=5`
  (a new derived endpoint that reads the three logs above and returns
  `{principal, ip, fails_lldap, fails_dex, fails_vault, total, first_ts,
  last_ts}` for any tuple crossing the threshold).

#### A6 — Did a user authenticate from a new / off-hours / unexpected IP or host?

- **Generated where:** Derived from A1 + A2 + A4 + the libcloud REST access
  log (B1). Requires `source_ip` on every auth line (gap analysis #4) and on
  the access log (gap analysis #1). "New/unexpected" needs a baseline of
  prior IPs per principal — computed by the audit service from historical
  lines.
- **Answered by:** `GET /v1/audit/auth/anomalies?principal=…` returning
  `{principal, ip, first_seen, last_seen, off_hours: bool, novel: bool}`.

### B. Authorization & access control

#### B1 — For each libcloud REST call: who called, what URL, what provider, what `auth_binding`, what was the OpenFGA decision, and what was the final HTTP status?

- **Generated where:** libcloud REST is the **only** component that sees all
  five fields in one place (the JWT caller, the URL, the `connection` object
  that carries `provider` + `auth_binding`, the OpenFGA `Check` result from
  `app/auth/policy.py::_enforce_openfga`, and the final HTTP status). Today
  only `oidc_token_decoded` is logged. Per gap analysis #1 add an
  `AccessLogMiddleware` in `app/common/middleware.py` writing
  `data/rest_access.log` JSONL with
  `{ts, request_id, principal, source_ip, http_method, path, provider,
  auth_binding, scope_required, fga_decision: allow|deny, fga_relation,
  fga_object, status_code, duration_ms, error_code, break_glass}`.
  `auth_binding` comes from `connection.auth_binding` (the tenant id used
  for the OpenFGA backend object — see `libcloud.rest/ARCHITECTURE.md`
  §"OpenFGA Fine-Grained Authorization"). The OpenFGA decision is captured
  by having `policy.py` stash the last `Check` result onto
  `request.state.fga_decision` before the route runs, so the middleware can
  read it on the way out.
- **Answered by:** `GET /v1/audit/access?principal=…&provider=…&
  auth_binding=…&request_id=…&status=403`.

#### B2 — For each authenticated user, what are all the libcloud REST calls in sequence: who called, what URL, date time stamp?

- **Generated where:** Same `data/rest_access.log` as B1 — the sequence is
  just B1 ordered by `ts` for one `principal`. This is the per-user slice of
  the access log; no new emitter needed once B1 exists.
- **Answered by:** `GET /v1/audit/access/by-user/{principal}?from=…&to=…`
  ordered by `ts`, with `request_id` on every row so the sequence can be
  followed across the OpenFGA/Vault/cloud logs.

### D. Resource & cloud operations

#### D1 — What cloud resources did a user create/modify/destroy, on which tenant/region/cluster, and what was the cloud-side request id?

- **Generated where:** Two components must contribute.
  1. **libcloud REST** — the access log (B1) records `principal`, the verb
     (`POST/PATCH/DELETE /v1/compute/nodes` etc.), `provider`, and
     `auth_binding` (tenant). It does **not** have the cloud-side
     `request_id`.
  2. **libcloud drivers** — per gap analysis #9, capture
     `ResponseMetadata.RequestId` from AWS EC2 responses and the Nutanix
     task `extId`/`ext_id` from Nutanix v4 responses, return it through
     `app/compute/service.py` and `app/network/service.py`, and have the
     access middleware write it as `cloud_request_id` on the line. The
     tenant/region/cluster is `provider + auth_binding + connection.config`
     (region for AWS, cluster for Nutanix — already in the access log).
- **Answered by:** `GET /v1/audit/cloud-ops?principal=…&verb=destroy&
  cloud_request_id=…` returning the access-log row joined to the cloud
  request id; the cloud provider's own log (CloudTrail / Prism Audit) is
  then joinable on `cloud_request_id`.

#### D3 — Was there access to an unexpected cloud region/cluster for that tenant?

- **Generated where:** Derived from B1 + D1. The access log already carries
  `provider`, `auth_binding` (tenant), and `connection.config.region`
  (AWS) / `connection.config.host` (Nutanix cluster). The audit service
  compares the region/cluster seen on each call against the tenant's
  expected set (from OpenFGA tuples: which `aws_region:<x>` /
  `nutanix_cluster:<x>` objects the tenant parents — see
  `openfga_my/ARCHITECTURE.md` §6.1).
- **Answered by:** `GET /v1/audit/cloud-ops?unexpected=true` returning rows
  where `region/cluster ∉ tenant.expected`.

### E. Lifecycle & offboarding

#### E1 — Was a user offboarded in LLDAP but still has OpenFGA tuples / Vault tokens / leases?

- **Generated where:** No single component sees all three states. Per gap
  analysis #14, a scheduled `offboarding-reconcile` job (in `openfga_my`)
  reads: (a) disabled users from LLDAP (via GraphQL), (b) OpenFGA tuples
  still referencing `user:<uid>` (via `openfga-tuple-audit.py`), (c) Vault
  leases/tokens for that user (via the native audit device + `vault list
  sys/leases`). It writes `generated/offboard_reconcile.log` JSONL with
  `{ts, principal, lldap_state: disabled, fga_tuples: [...], vault_leases:
  [...], gap: true}`.
- **Answered by:** `GET /v1/audit/lifecycle/offboard-gaps` returning the
  latest reconcile report.

#### E2 — Was a tenant created or deleted, and by whom (must be superadmin-gated)?

- **Generated where:** The `openfga_my` scripts `create_tenant.sh` (and a
  new `delete_tenant.sh`) are the only paths that mint/delete a tenant. Per
  gap analysis #13 they append to `generated/tenant_audit.log` JSONL with
  `{ts, actor (superadmin), jti (from SUPERADMIN_JWT), action:
  tenant_create|tenant_delete, tenant, result}`. The superadmin-gating is
  enforced by `vault_bootstrap.py`'s `SUPERADMIN_JWT` check pattern (per
  `vault/ARCHITECTURE.md` §6.3) — the script refuses to run without a valid
  superadmin JWT.
- **Answered by:** `GET /v1/audit/lifecycle/tenants?tenant=…&actor=…`.

#### E3 — Was an LLDAP group created/deleted and a member added/removed, by whom?

- **Generated where:** The `openfga_my` LLDAP admin scripts
  (`lldap-group-add-member.sh`, group create/delete) already write
  `generated/lldap_audit.log` with `actor` + `result` (per gap analysis §0,
  E3 is the one lifecycle question *already covered*). Add the `actor ==
  target_user` self-assignment check (gap analysis #11) so B5-style abuse is
  visible in the same file.
- **Answered by:** `GET /v1/audit/lifecycle/groups?actor=…&action=…`.

### F. Audit integrity & defense evasion

#### F3 — Are audit logs protected against tampering (append-only, shipped off-host, retained)?

- **Generated where:** This is a *property of the log files themselves*,
  not an event in any application. Per gap analysis #16/#17 it is enforced
  by `setup.sh`: `chattr +a` on every `*_audit.log` / `auth_audit.log` /
  `rest_access.log` / `openfga_denial.log`, `logrotate` with `copytruncate`
  per the sysmon2 retention table (Vault 3y, REST 3y, FGA 1y, LLDAP 3y),
  and an append-only syslog shipper to an off-host collector. The audit
  service cannot attest to its own integrity from inside, so it reports the
  *observable* signals: file mode, `chattr` flags, size, mtime, last
  rotation, and whether the syslog shipper is reachable.
- **Answered by:** `GET /v1/audit/integrity` returning
  `[{file, mode, append_only: bool, size, mtime, last_rotated, shipped:
  bool}]` for every audit file. A SIEM outside the host is the real
  attestation; this endpoint is the convenience view.

---

## 3. What libcloud REST contributes vs. what it cannot

| libcloud REST does | libcloud REST cannot (other component must) |
|---|---|
| Provide the `/v1/audit/*` **read surface** that answers every question above uniformly, with one auth/scope gate and one correlation key (`request_id`). | Emit LLDAP bind lines (A1) — LLDAP must. |
| Be the **only** place that emits the B1/B2/D1/D3 access log (it is the single chokepoint for JWT + URL + `connection` + OpenFGA decision + HTTP status). | Emit Dex login lines (A2/A3 issuance) — Dex must. |
| Propagate `request_id` (gap #2) so its access log is the join key for OpenFGA / Vault / cloud logs. | Emit Vault `auth/ldap` lines (A4) — Vault's native audit device must. |
| Capture `cloud_request_id` (gap #9) from the libcloud drivers it already calls. | Make itself tamper-evident (F3) — host-level `chattr +a` + off-host shipper must. |
| Gate every audit read behind `audit:read` (superadmin / owner) so the audit surface is not a new exfiltration path. | Detect offboard dangling state (E1) on its own — needs the reconcile job that also reads LLDAP + OpenFGA + Vault. |

In short: libcloud REST is the **correlation hub** (B1/B2/D1/D3 live entirely
inside it; A3/B2/D1 also need its `request_id` propagation to join to other
components) and the **uniform query front door** (`/v1/audit/*`). The raw
events for A1/A2/A4/E1/E2/F3 still have to be emitted by LLDAP, Dex, Vault,
the openfga_my scripts, and the host — exactly the P0/P1 changes in
`security_logging_gap_analysis.md` §3.
