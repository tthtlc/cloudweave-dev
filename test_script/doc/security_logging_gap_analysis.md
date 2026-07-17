# Security Logging — Questions, Components, and Required Changes

This document answers three questions:

1. **What are the important security-related questions the system must be able
   to answer?** (§1)
2. **Which components can answer each through explicit logging — and what is
   already logged today vs. what is missing?** (§2)
3. **What changes are needed to close the gaps?** (§3, the consolidated table
   for consideration)

> **Important baseline note.** Everything in `doc/sysmon2/` (the "Security
> Monitoring Architecture", "Lightweight Statistics & Monitoring
> Instrumentation", and "Nutanix Tenant FinOps & Monitoring" documents) is
> **design-stage only — none of it is implemented.** There is no SIEM, no
> log shipper, no OpenTelemetry collector, no Wazuh, no correlation rules,
> and no centralised observability pipeline in the stack today. The
> "current state" in §0 below is therefore derived **only from the actual
> code** (the script-level JSONL audit emitters and the libcloud REST
> `auth_audit` hook), not from `sysmon2/`. `sysmon2/` is referenced purely
> as the target design that the changes in §3 move the system toward.

This document is the actionable companion to that design. It focuses on the
**per-component instrumentation gaps** that prevent the system from
answering the questions today, with concrete file-level changes.

---

## 0. Current logging state (gap-analysis baseline)

Derived from the actual code (scripts + libcloud REST app), not from the
`sysmon2/` design docs.

| Component | What IS logged today (structured JSONL) | What is NOT logged (gaps) |
|-----------|------------------------------------------|---------------------------|
| **LLDAP** | `generated/lldap_audit.log` — admin-script actions only (onboard / offboard / group add/remove / group create/delete / password reset), with `actor` + `result`. | Native LDAP **bind/search** audit (Dex's bind, Vault's bind, user logins) is not captured; no failed-bind log; no IP on binds. |
| **Dex** | Nothing persisted. Dex logs to stdout (glog-style) but no login/token-issuance structured log is captured to a file. | Login success/failure, token issuance (`sub`, `aud`, `client_id`, `redirect_uri`, IP), refresh-token issuance. |
| **OpenFGA (server)** | Nothing structured. The container logs to stdout; `--log-level` / JSON / OTEL are not configured in `docker-compose.yml`. | `Check` decisions (allow/deny with user/relation/object/IP), `Write`/`Delete` of tuples, model-id used per call. |
| **OpenFGA (admin scripts)** | `generated/openfga_audit.log` — `tuple-write` / `tuple-delete` only, with `actor` + triple + result. | `Check` decisions, model pushes, store creation, reconciler runs. |
| **Vault (server)** | **Native audit device is NOT enabled** (`vault-audit-log-query.sh` reports "no file audit device configured"). | Every request/response (read/write/lease/auth) — Vault blocks requests it cannot log, so this is the single biggest gap. |
| **Vault (admin scripts)** | `generated/vault_audit.log` — every admin script via `vault_common.sh`, with `actor` + action + result. | Runtime reads by the libcloud REST API; external access; policy/secrets-engine/audit-device mutations (these need the native device). |
| **libcloud REST** | `data/auth_audit.log` — only `oidc_token_decoded` events, with `principal`/`issuer`/`sub`/`email` but **no `source_ip`, no `request_id`**. | Per-request access log; OpenFGA denial log; Vault-read log; `cloud_request_id`; `request_id` propagation to FGA/Vault; `source_ip`. |
| **libcloud REST (middleware)** | `RequestIDMiddleware` sets `request.state.request_id` + `X-Request-ID` response header. | The id is **not forwarded** to OpenFGA/Vault/cloud calls; no access log consumes it. |
| **Host scripts** (`idp_login.py`, `set_tenant_credentials.py`, `superadmin_auth.sh`) | Print to stderr. | No structured audit line (who logged in to Dex as whom, from where, what tenant creds were written). |
| **Cloud providers** (AWS CloudTrail / Nutanix Prism Audit) | Native logs exist out-of-band. | libcloud REST does not record the cloud-side `request_id` / task `extId`, so cloud logs cannot be joined to REST logs. |
| **stoplight_mock** | N/A (mock, no auth). | — |

---

## 1. The important security questions

Grouped by category. Each question has an ID (Q-id) used in §2 and §3.

### A. Identity & authentication

| ID | Question |
|----|----------|
| A1 | Who authenticated to LLDAP (bind), from which IP, when, and did the bind succeed or fail? |
| A2 | Who logged in to Dex (user, OAuth client, redirect_uri, IP) and was the login successful? |
| A3 | Who obtained a Dex-issued JWT (sub, aud, iss, jti, expiry) and when — including from host scripts? |
| A4 | Who authenticated to Vault via the LDAP auth method (user, policies issued, token TTL, IP)? |
| A5 | Are there brute-force / credential-stuffing patterns against LLDAP, Dex, or Vault? |
| A6 | Did a user authenticate from a new / off-hours / unexpected IP or host? |

### B. Authorization & access control

| ID | Question |
|----|----------|
| B1 | For each libcloud REST call: who called, what URL, what provider, what `auth_binding`, what was the OpenFGA decision, and what was the final HTTP status? |
| B2 | Was an OpenFGA `Check` denied — for which user/relation/object, and was it followed by a success elsewhere (bypass)? |
| B3 | Were OpenFGA tuples written/deleted outside the reconciler, or by an unexpected actor? |
| B4 | Was the OpenFGA authorization model swapped (model id mismatch with the pinned id in libcloud REST)? |
| B5 | Did someone self-assign a role (LLDAP group add where `actor == target_user`)? |
| B6 | Was break-glass (`superadmin`) used, and for which operation? |

### C. Secrets & credentials

| ID | Question |
|----|----------|
| C1 | Who read which Vault secret, when, from which IP, with which token? |
| C2 | Who wrote / rotated / destroyed a Vault static secret or a cloud secrets-engine root cred? |
| C3 | Who requested a dynamic credential (lease id), and was that lease ever renewed/revoked? |
| C4 | Was a cloud credential used **outside** libcloud REST (cloud provider log has no matching libcloud request)? |
| C5 | Was a credential used **after** its lease expiry? |
| C6 | Was a Vault policy / LDAP-group binding / secrets engine / audit device modified? |

### D. Resource & cloud operations

| ID | Question |
|----|----------|
| D1 | What cloud resources did a user create/modify/destroy, on which tenant/region/cluster, and what was the cloud-side request id? |
| D2 | Was there mass destruction (many destroys in a short window)? |
| D3 | Was there access to an unexpected cloud region/cluster for that tenant? |

### E. Lifecycle & offboarding

| ID | Question |
|----|----------|
| E1 | Was a user offboarded in LLDAP but still has OpenFGA tuples / Vault tokens / leases? |
| E2 | Was a tenant created or deleted, and by whom (must be superadmin-gated)? |
| E3 | Was an LLDAP group created/deleted and a member added/removed, by whom? |

### F. Audit integrity & defense evasion

| ID | Question |
|----|----------|
| F1 | Was the Vault audit device tampered with or disabled? |
| F2 | Was logging itself modified (audit toggle flipped, audit file path changed, log level lowered)? |
| F3 | Are audit logs protected against tampering (append-only, shipped off-host, retained)? |

---

## 2. Components that can answer each question (and current state)

| Q-id | Primary component(s) | Current state | Gap to close |
|------|----------------------|---------------|--------------|
| A1 | LLDAP (LDAP bind audit) | Script-audit only; no native bind log | Capture LLDAP container stdout + add a bind/search audit path; record `bindDN`, `client_ip`, `result` |
| A2 | Dex (login/token log) | Not persisted | Capture Dex stdout to a structured file; parse login + token-issuance events |
| A3 | Dex + libcloud REST + host scripts | REST logs `oidc_token_decoded` without IP/request_id; host scripts only stderr | Add `source_ip` + `request_id` to `audit_auth_event`; host scripts append to `generated/dex_login_audit.log` |
| A4 | Vault (native audit device) | **Not enabled** | `vault audit enable file …` in `vault_bootstrap.py`; capture `auth/ldap/login/*` entries |
| A5 | LLDAP + Dex + Vault | No failed-auth correlation source | A1 + A2 + A4 provide the raw events; add failed-bind/login counters |
| A6 | LLDAP + Dex + Vault + libcloud REST | No IP on most events | A1 + A2 + A4 + B1 (source_ip) |
| B1 | libcloud REST (per-request access log) | **Does not exist** | New `AccessLogMiddleware` writing `data/rest_access.log` with the full field set |
| B2 | libcloud REST (OpenFGA denial log) | **Does not exist** (aspirational `generated/openfga_denial.log`) | Emit a denial line from `policy.py::_enforce_openfga` on every False `Check` |
| B3 | OpenFGA server (tuple write/delete log) | Only admin scripts audit their own writes | Enable OpenFGA structured JSON logging; capture `Write`/`Delete` events |
| B4 | OpenFGA server + libcloud REST | No model-id pin/check | Log `authorization_model_id` on every Check; libcloud REST warns on mismatch with pinned id |
| B5 | LLDAP (group add) | Script logs `actor` + `user` but no self-assignment check | Add `actor == user` detection in `lldap-group-add-member.sh` and log a `self_role_assign` event |
| B6 | libcloud REST + OpenFGA | REST can see `sub=superadmin` but no special flag | Tag access-log lines with `break_glass=true` when `principal == superadmin`; alert on destructive ops |
| C1 | Vault (native audit device) | **Not enabled** (REST's runtime reads are invisible) | Enable audit device; the REST API's reads at `secret/data/libcloud/*` become auditable |
| C2 | Vault (native) + admin scripts | Admin-script actions logged; root-cred rotate logged | Native device captures the REST API's writes too; ensure `set_tenant_credentials.py` also appends to `vault_audit.log` |
| C3 | Vault (native) | **Not enabled** | Audit device logs `<engine>/creds/<role>` reads + `sys/leases/renew`/`revoke` |
| C4 | Cloud provider logs + libcloud REST | REST does not record `cloud_request_id` | Capture AWS `ResponseMetadata.RequestId` / Nutanix task `extId` into the access log; correlate with CloudTrail/Prism |
| C5 | Vault + cloud provider | No lease-expiry vs cloud-call correlation | Native audit device + cloud logs (C4) + a SIEM rule |
| C6 | Vault (native) | **Not enabled** | Audit device logs `sys/policies/acl/*`, `sys/mounts/*`, `sys/audit/*`, `auth/ldap/groups/*` |
| D1 | libcloud REST + cloud provider | REST has no access log; no cloud_request_id | B1 access log + C4 cloud_request_id |
| D2 | libcloud REST | No access log | B1 + a SIEM count rule on `destroy`/`delete` verbs |
| D3 | libcloud REST + cloud provider | No access log | B1 access log records `provider` + `auth_binding`; SIEM correlates with cloud region |
| E1 | LLDAP + OpenFGA + Vault | Offboard chain logs each step, but no **dangling-state detector** | Add a scheduled `offboarding-reconcile` job that reports users disabled in LLDAP but still having tuples/leases |
| E2 | openfga_my scripts (`create_tenant.sh`) | Script prints; not audited | Append a `tenant_create` / `tenant_delete` line to `generated/tenant_audit.log` with superadmin actor |
| E3 | LLDAP scripts | Already audited in `lldap_audit.log` | (No gap — already covered) |
| F1 | Vault (native) | **Not enabled** | Audit device logs `sys/audit/*` writes/deletes |
| F2 | libcloud REST + Vault | REST has `auth_audit_enabled` toggle but no log of changes to it | Log changes to `auth_audit_enabled` / `auth_audit_file` / `access_log_enabled` settings; Vault audit device logs its own config |
| F3 | All | Logs are local files, no rotation/ship | Add log rotation + ship to a central collector (per sysmon2 doc) |

---

## 3. Required changes (consolidated table for consideration)

Each row is one proposed change. **Priority**: P0 = required to answer a question that today has **no** logging source at all; P1 = required to make an existing log useful for correlation; P2 = hardening / SIEM-readiness. **Effort**: S / M / L.

| # | Change | Component(s) | File(s) to touch | Answers | Priority | Effort |
|---|--------|--------------|------------------|---------|----------|--------|
| 1 | Add a per-request **access log** middleware that writes one JSONL line per request: `request_id`, `user` (principal), `source_ip`, `http_method`, `path`, `provider`, `auth_binding`, `vault_lease_id`, `fga_check_result`, `cloud_request_id`, `duration_ms`, `status_code`, `error`, `break_glass` | libcloud REST | `app/common/middleware.py` (new `AccessLogMiddleware`), `app/main.py` (register), `app/config/settings.py` (`access_log_enabled`, `access_log_file`) | B1, B6, D1, D2, D3, A6 | P0 | M |
| 2 | **Propagate `request_id`** to OpenFGA and Vault outbound calls as `X-Request-ID` (and to AWS/Nutanix driver calls where supported) | libcloud REST | `app/auth/fga_client.py`, `app/connections/vault_client.py`, `app/compute/service.py` + `app/network/service.py` + `app/storage/service.py` (pass `request_id` from `request.state` into service calls) | B1, B2, C1, C4 (join key) | P0 | M |
| 3 | Emit an **OpenFGA denial log** line from `policy.py::_enforce_openfga` on every False `Check`: `request_id`, `user`, `relation`, `object`, `scope`, `reason`, `source_ip` → `generated/openfga_denial.log` | libcloud REST | `app/auth/policy.py`, `app/config/settings.py` (`denial_log_file`) | B2, B4 | P0 | S |
| 4 | Add `source_ip` + `request_id` to `audit_auth_event` (oidc_token_decoded) | libcloud REST | `app/auth/identity.py::audit_auth_event` (signature + fields), `app/auth/oidc_service.py` (pass `request.client.host` + `request.state.request_id`) | A3, A6 | P0 | S |
| 5 | Enable the **Vault native audit device** (file + syslog) in `vault_bootstrap.py`, with `hmac_accessor=false` and `elide_list_responses=true`; mount a volume for `/vault/audit` | Vault | `../openfga_my/vault_bootstrap.py`, `../vault/docker-compose.yml` (volume), `../vault/ARCHITECTURE.md` | A4, C1, C2, C3, C6, F1 | P0 | M |
| 6 | Configure **OpenFGA server structured JSON logging** + OTEL exporter in `docker-compose.yml` (`--log-level=info` + JSON formatter, `--otel-collector`); capture container stdout to `generated/openfga_server.log` | OpenFGA | `../openfga_my/docker-compose.yml`, `setup.sh` (log capture) | B1, B3, B4 | P1 | M |
| 7 | Capture **Dex login / token-issuance** events: persist Dex container stdout to `generated/dex_server.log` and parse login + token endpoints into `generated/dex_login_audit.log` (`user_id`, `client_id`, `redirect_uri`, `ip`, `result`) | Dex + openfga_my | `../dex/docker-compose.yml` (logging), `../openfga_my/setup.sh` (capture), new `scripts/dex_login_audit.py` parser | A2, A3, A5 | P1 | M |
| 8 | Capture **LLDAP container stdout** to `generated/lldap_server.log`; add a small parser for bind/search/login events into `generated/lldap_bind_audit.log` (`bindDN`, `client_ip`, `result`) — LLDAP has no OpenLDAP `auditlog` overlay, so stdout is the source | LLDAP + openfga_my | `../lldap/docker-compose.yml` (logging), new `scripts/lldap_bind_audit.py` | A1, A5, A6 | P1 | M |
| 9 | Capture **`cloud_request_id`** from driver responses (AWS `ResponseMetadata.RequestId`; Nutanix task `extId` / `ext_id`) and return it through the service layer to the access log | libcloud + libcloud REST | `libcloud/compute/drivers/nutanix.py` (+ `aws` EC2 driver extra), `app/compute/service.py` / `app/network/service.py` / `app/storage/service.py` (return `cloud_request_id`), `app/common/middleware.py` (include in access log) | C4, D1 | P1 | M |
| 10 | **Pin + verify the OpenFGA `authorization_model_id`** in libcloud REST: store the expected id in `generated/fga.env`, log + 503 on mismatch | libcloud REST | `app/auth/fga_client.py`, `app/config/settings.py` (`fga_expected_model_id`) | B4 | P1 | S |
| 11 | **Self-role-assignment detection**: in `lldap-group-add-member.sh`, when `actor == user`, emit a `self_role_assign` audit line at WARN; reject unless `--allow-self` | LLDAP scripts | `../openfga_my/scripts/lldap-group-add-member.sh` | B5 | P2 | S |
| 12 | **Host-script audit**: `idp_login.py`, `superadmin_auth.sh`, `set_tenant_credentials.py` append a JSONL line to `generated/dex_login_audit.log` / `generated/tenant_audit.log` (`actor`, `tenant`, `result`, `ip`) | openfga_my scripts | `scripts/idp_login.py`, `scripts/superadmin_auth.sh`, `scripts/set_tenant_credentials.py` | A3, E2, C2 | P1 | S |
| 13 | **Tenant lifecycle audit**: `create_tenant.sh` (and a new `delete_tenant.sh`) append to `generated/tenant_audit.log` with the superadmin actor + JWT `jti` | openfga_my scripts | `scripts/create_tenant.sh`, new `scripts/delete_tenant.sh` | E2 | P2 | S |
| 14 | **Offboarding dangling-state detector**: a scheduled job that lists users disabled in LLDAP but still holding OpenFGA tuples / Vault tokens / leases; writes a report to `generated/offboard_reconcile.log` | openfga_my | new `scripts/offboarding-reconcile.sh` + cron/systemd timer | E1 | P2 | M |
| 15 | **Settings-change audit**: log any change to `auth_audit_enabled` / `auth_audit_file` / `access_log_enabled` / `denial_log_file` / `fga_expected_model_id` at startup and on reload | libcloud REST | `app/config/settings.py` (startup audit line), `app/common/middleware.py` | F2 | P2 | S |
| 16 | **Log rotation + retention**: `logrotate` config for all `generated/*_audit.log`, `data/auth_audit.log`, `data/rest_access.log`, `generated/openfga_denial.log`, `/vault/audit/audit.log` per the sysmon2 retention table (Vault 3y, REST 3y, FGA 1y, LLDAP 3y) | all | new `ops/logrotate.d/libcloud` + `setup.sh` install step | F3 | P2 | S |
| 17 | **Append-only / tamper-evidence**: write audit files with `chattr +a` (Linux) where the host supports it, or ship via append-only syslog to a remote collector | all | `setup.sh` (post-create `chattr +a`), `ops/logrotate.d/libcloud` (copytruncate) | F3 | P2 | S |
| 18 | **`break_glass` tagging**: in the access log / denial log / auth audit, set `break_glass=true` when `principal == superadmin`; add a SIEM rule for destructive ops under break-glass | libcloud REST | `app/common/middleware.py`, `app/auth/policy.py`, `app/auth/identity.py` | B6 | P2 | S |
| 19 | **OpenFGA reconciler audit**: `openfga-tuple-reconcile.py` writes a summary line (added/removed/unchanged counts, actor) to `generated/openfga_audit.log` so reconciler-driven writes are distinguishable from direct writes (B3) | openfga_my | `scripts/openfga-tuple-reconcile.py` | B3 | P2 | S |
| 20 | **REST access-log ingestion by `openfga-denial-log-query.sh`**: extend the query script to also correlate denials with the matching REST access-log line by `request_id` (today it only queries OpenFGA-side denials) | openfga_my | `scripts/openfga-denial-log-query.sh` | B2 | P2 | S |

### Priority summary

- **P0 (no logging source exists today):** #1, #2, #3, #4, #5 — these close the largest blind spots (no REST access log, no denial log, no Vault audit device, no request_id propagation, no source_ip on auth).
- **P1 (existing source is not useful for correlation):** #6, #7, #8, #9, #10, #12 — server-side structured logs for OpenFGA/Dex/LLDAP + cloud_request_id + model-id pin + host-script audit.
- **P2 (hardening / SIEM-readiness):** #11, #13, #14, #15, #16, #17, #18, #19, #20.

### Suggested sequencing

1. Land #5 (Vault audit device) first — Vault blocks requests it cannot log, so this single change turns C1/C2/C3/C6/F1 from "blind" to "covered" with no app code.
2. Land #1 + #2 + #3 + #4 together — they form the libcloud REST correlation fabric (access log + request_id propagation + denial log + source_ip). After this, B1/B2/B6/D1/D2/D3/A3/A6 are answerable.
3. Land #6 + #7 + #8 — server-side structured logs for OpenFGA/Dex/LLDAP, plus #9 cloud_request_id and #10 model-id pin.
4. Land the P2 hardening batch.

After P0 + P1, every question in §1 has at least one explicit logging source. P2 then adds integrity, retention, and detection convenience.

---

## 4. What each component owes (per-component checklist)

| Component | Owes (from §3) |
|-----------|----------------|
| **libcloud REST** | #1 access log middleware, #2 request_id propagation, #3 denial log, #4 source_ip+request_id in auth audit, #9 cloud_request_id capture, #10 model-id pin, #15 settings-change audit, #18 break_glass tagging |
| **Vault** | #5 native audit device (+ volume) |
| **OpenFGA server** | #6 structured JSON logging + OTEL |
| **Dex** | #7 login/token capture |
| **LLDAP** | #8 stdout capture + bind audit parser |
| **libcloud (drivers)** | #9 cloud_request_id return (Nutanix + AWS) |
| **openfga_my scripts** | #7 parser, #8 parser, #11 self-role detection, #12 host-script audit, #13 tenant audit, #14 offboarding reconciler, #19 reconciler audit, #20 denial-query correlation |
| **ops / setup.sh** | #16 logrotate, #17 append-only / ship |
