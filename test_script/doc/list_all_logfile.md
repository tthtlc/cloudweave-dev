 summarize the list of all the implemented log files.                                                                                                         
                                                                                                                                                               

  Let me verify by searching the actual code for log files that are written (not the captured run output in log/).

    Grepped "...OG=|auth_audit_file|audit_file|denial" in /home/ubuntu/libcloud_nutanix
    Found 454 matches 

  Let me confirm the cloud-operation audit log and the openfga/lldap common audit defaults.

    Grepped 4 greps
    Grepped "...LOG=|LLDAP_AUDIT_LOG=|cloud_audit_log" in /home/ubuntu/libcloud_nutanix/openfga_my/scripts
    Grepped "audit|AUDIT|log" in ...loud_nutanix/openfga_my/scripts/cloud_common.sh
    Grepped "FGA_AUDIT_LOG|AUDIT_LOG" in ...ud_nutanix/openfga_my/scripts/openfga_common.sh
    Grepped "OFFBOARD_LOG|record_step|chain_audit" in ...tanix/openfga_my/scripts/chain-offboard-user.sh

  Here is the verified summary of actually-implemented audit log files (each written by real code, JSONL format, append-only). I checked the writer
  functions in each common helper and the libcloud REST app — not the design docs.

  Implemented audit log files

  ┌─────┬────────┬──────────┬─────────────┬──────────────────────────────────────────────────────┬─────────────────────────────────────────────────────────┐
  │ #   │ File   │ Writer   │ Default     │ What it records                                      │ Triggered by                                            │
  │     │        │ (code)   │ path var    │                                                      │                                                         │
  ├─────┼────────┼──────────┼─────────────┼──────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────┤
  │ 1   │ genera │ lldap_co │ LLDAP_AUDIT │ LLDAP admin actions: lldap_create_user,              │ lldap-user-onboard.sh, lldap-user-offboard.sh,          │
  │     │ ted/ll │ mmon.sh: │ _LOG        │ lldap_user_offboard, lldap_group_create,             │ lldap-group-create.sh, lldap-group-add-member.sh,       │
  │     │ dap_au │ :lldap_a │             │ lldap_group_add_member, lldap_user_password_reset,   │ lldap-group-remove-member.sh, lldap-group-delete.sh,    │
  │     │ dit.lo │ udit     │             │ etc. — actor, result, http                           │ lldap-user-password-reset.sh,                           │
  │     │ g      │          │             │                                                      │ lldap-admin-cred-rotate.sh,                             │
  │     │        │          │             │                                                      │ lldap-audit-all-memberships.sh                          │
  ├─────┼────────┼──────────┼─────────────┼──────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────┤
  │ 2   │ genera │ openfga_ │ FGA_AUDIT_L │ OpenFGA tuple writes/deletes — actor, action         │ openfga-tuple-write.sh, openfga-tuple-delete.sh (+      │
  │     │ ted/op │ common.s │ OG          │ (tuple-write/tuple-delete), tuple, result            │ queried by openfga-denial-log-query.sh,                 │
  │     │ enfga_ │ h::fga_a │             │                                                      │ openfga-tuple-audit.py)                                 │
  │     │ audit. │ udit     │             │                                                      │                                                         │
  │     │ log    │          │             │                                                      │                                                         │
  ├─────┼────────┼──────────┼─────────────┼──────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────┤
  │ 3   │ genera │ vault_co │ VAULT_AUDIT │ Every Vault admin action — actor, action, result,    │ All vault-*.sh admin scripts                            │
  │     │ ted/va │ mmon.sh: │ _LOG        │ http (policy-apply, ldap-group-bind,                 │                                                         │
  │     │ ult_au │ :vault_a │             │ secrets-engine-enable, role-create,                  │                                                         │
  │     │ dit.lo │ udit     │             │ dynamic-cred-request, static-secret-rotate,          │                                                         │
  │     │ g      │          │             │ root-cred-rotate, lease-renew/revoke, token-lookup,  │                                                         │
  │     │        │          │             │ audit-log-query, etc.)                               │                                                         │
  ├─────┼────────┼──────────┼─────────────┼──────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────┤
  │ 4   │ genera │ cloud_co │ CLOUD_AUDIT │ Cloud operations through the REST API — actor,       │ cloud-node-provision.sh, cloud-node-action.sh,          │
  │     │ ted/cl │ mmon.sh: │ _LOG        │ action                                               │ cloud-keypair-manage.sh,                                │
  │     │ oud_au │ :cloud_a │             │ (node-provision/node-<action>/keypair-*/bucket-creat │ cloud-storage-bucket-create.sh,                         │
  │     │ dit.lo │ udit     │             │ e/bucket-delete/object-upload/object-download/floati │ cloud-storage-bucket-delete.sh,                         │
  │     │ g      │          │             │ ngip-allocate/floatingip-release),                   │ cloud-storage-object-upload.sh,                         │
  │     │        │          │             │ provider, result, node_id/name/bucket                │ cloud-storage-object-download.sh,                       │
  │     │        │          │             │                                                      │ cloud-floatingip-allocate.sh,                           │
  │     │        │          │             │                                                      │ cloud-floatingip-release.sh                             │
  ├─────┼────────┼──────────┼─────────────┼──────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────┤
  │ 5   │ genera │ each     │ AUDIT_LOG   │ Chain orchestration steps — actor, action            │ chain-offboard-user.sh, chain-onboard-user.sh,          │
  │     │ ted/ch │ chain    │             │ (chain-offboard-user/chain-onboard-user/chain-role-a │ chain-role-assign.sh, chain-role-revoke.sh,             │
  │     │ ain_au │ script's │             │ ssign/chain-role-revoke/chain-provider-onboard/chain │ chain-provider-onboard.sh,                              │
  │     │ dit.lo │ chain_au │             │ -presharedkey-rotate/chain-diagnose-access),         │ chain-presharedkey-rotate.sh, chain-diagnose-access.sh  │
  │     │ g      │ dit()    │             │ step, result, detail                                 │                                                         │
  ├─────┼────────┼──────────┼─────────────┼──────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────┤
  │ 6   │ genera │ chain-of │ OFFBOARD_LO │ Signed offboarding summary record (per-user, with    │ chain-offboard-user.sh only                             │
  │     │ ted/of │ fboard-u │ G           │ SHA-256 signature over the step results)             │                                                         │
  │     │ fboard │ ser.sh   │             │                                                      │                                                         │
  │     │ _audit │ (step 4) │             │                                                      │                                                         │
  │     │ .log   │          │             │                                                      │                                                         │
  ├─────┼────────┼──────────┼─────────────┼──────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────┤
  │ 7   │ data/a │ app/auth │ settings    │ oidc_token_decoded only — principal, issuer, sub,    │ libcloud REST OidcAuthService.decode_access_token       │
  │     │ uth_au │ /identit │ auth_audit_ │ email, source="oidc" (no source_ip, no request_id)   │                                                         │
  │     │ dit.lo │ y.py::au │ file        │                                                      │                                                         │
  │     │ g      │ dit_auth │ (gated by   │                                                      │                                                         │
  │     │        │ _event   │ auth_audit_ │                                                      │                                                         │
  │     │        │          │ enabled)    │                                                      │                                                         │
  └─────┴────────┴──────────┴─────────────┴──────────────────────────────────────────────────────┴─────────────────────────────────────────────────────────┘

  Implemented, but not dedicated audit files (process stdout / container logs)

  ┌────────────────┬─────────────────────────────────────────────────────┬─────────────────────────────────────────────────────────────────────────────────┐
  │ Source         │ Where                                               │ What                                                                            │
  ├────────────────┼─────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────┤
  │ libcloud REST  │ app/auth/fga_client.py,                             │ Error lines only ("OpenFGA check failed: …", "Vault read failed for …: …") — no │
  │ Python logging │ app/connections/vault_client.py, etc. → uvicorn     │ success/decision audit, no file                                                 │
  │                │ stdout → Docker container logs                      │                                                                                 │
  ├────────────────┼─────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────┤
  │ X-Request-ID   │ app/common/middleware.py::RequestIDMiddleware       │ Generates/propagates request_id into request.state and the response             │
  │ response       │                                                     │ meta.request_id; not written to any file and not forwarded to                   │
  │ header         │                                                     │ OpenFGA/Vault/cloud calls                                                       │
  └────────────────┴─────────────────────────────────────────────────────┴─────────────────────────────────────────────────────────────────────────────────┘

  Referenced in docs/scripts but NOT actually written (aspirational)

  ┌──────────────────────────────────────────────────────────────────────────┬─────────────────────────────────────────────────────────────────────────────┐
  │ File                                                                     │ Why it's not implemented                                                    │
  ├──────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────┤
  │ generated/openfga_denial.log                                             │ Referenced in how-to docs and openfga-denial-log-query.sh comments, but the │
  │                                                                          │ query script only reads auth_audit.log + container logs + openfga_audit.log │
  │                                                                          │ (check=false). No code writes this file.                                    │
  ├──────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────┤
  │ generated/dex_audit.log                                                  │ Mentioned as "if present" in how_to_rotate_dex_preshared_key.md; no writer  │
  │                                                                          │ exists.                                                                     │
  ├──────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────┤
  │ generated/dex_login_audit.log, generated/lldap_bind_audit.log,           │ All proposed in security_logging_gap_analysis.md — none implemented.        │
  │ generated/tenant_audit.log, generated/dex_server.log,                    │                                                                             │
  │ generated/lldap_server.log, data/rest_access.log, /vault/audit/audit.log │                                                                             │
  └──────────────────────────────────────────────────────────────────────────┴─────────────────────────────────────────────────────────────────────────────┘

  Not audit logs (don't confuse with the above)

  • openfga_my/log/*.log (e.g. aws_admin.log, 4jul.log, dex.log, error*.log) — developer run captures / tee of stderr, not structured audit.
  • vault/vault.log — a captured server log from a manual run; "not used by the container" per vault/ARCHITECTURE.md.
  • generated/vault.env, generated/dex.env, generated/fga.env — generated config/secret outputs, not logs.

  Net

  7 implemented audit log files, all JSONL, all on the host under generated/ (6 of them) plus one in-container data/auth_audit.log. All are emitted by the
  openfga_my admin scripts (via the four *_common.sh helpers + the chain scripts) and the single libcloud REST auth hook. There is no server-side audit 
  logging implemented for LLDAP, Dex, OpenFGA, or Vault (native audit device not enabled) — every implemented log is either an admin-script action log or
  the one REST auth-decode event.


