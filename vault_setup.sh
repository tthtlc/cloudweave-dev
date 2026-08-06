#● Here's the complete guide:
#
#  Script purpose and when to run each
#
#  setup.sh — first time only
#
#  Run once to bootstrap the entire stack (LLDAP, Dex, OpenFGA, Vault, users, policies, credentials). Takes ~5 minutes.
#
#  cd /home/ubuntu/libcloud_nutanix
#  ./setup.sh
#
#  After this, everything should work. No need to run fix_vault_token.sh or recover_vault.sh.
#
#  ---
#  fix_vault_token.sh — every ~30 days (token refresh)
#
#  The Vault service token has a 32-day TTL. When it expires, the API returns 502 rest_error / Vault secret read failed / permission denied. This script issues a fresh token without losing any data.
#
#  Symptom: curl http://localhost:3000/api/resources/nutanix (with session cookie) returns:
#  {"error":"rest_error","message":"libcloud REST GET /v1/compute/nodes failed","details":{"status":503,"body":"...permission denied..."}}
#
#  Fix:
#  ./fix_vault_token.sh
#
#  ---
#  recover_vault.sh — nuclear option (Vault data lost/re-initialized)
#
#  Only when both the root token AND service token return 403 — meaning Vault was re-initialized and the new keys were never saved. Destroys all Vault data.
#
#  Symptom: fix_vault_token.sh fails with:
#  curl: (22) The requested URL returned error: 403
#  And this also fails:
#  curl -s -X POST http://localhost:8200/v1/sys/generate-root/attempt
#  # returns "permission denied"
#
#  Fix:
#  ./recover_vault.sh
#
#  ---
#  Decision flowchart
#
#  setup.sh (fresh install)
#         │
#         ▼
#  Everything works ──► wait 30 days ──► 502 error?
#                                              │
#                                              ▼
#                                     ./fix_vault_token.sh
#                                              │
#                                       works? ──yes──► done
#                                          │
#                                         no (403)
#                                          │
#                                          ▼
#                                 ./recover_vault.sh
#
#
