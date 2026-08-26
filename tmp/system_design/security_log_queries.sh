#!/usr/bin/env bash
# =============================================================================
# Security log-query pack for the libcloud_nutanix stack.
# Each function answers one security question using ONLY existing logs:
#   - libcloud auth_audit.log            (container volume api-data)
#   - libcloud uvicorn access log        (docker logs libcloud-rest-api)
#   - OpenFGA gRPC decision log          (docker logs openfga, tab-separated)
#   - OpenFGA Postgres datastore         (db `openfga` in container openfga-postgres)
#   - OpenFGA Postgres server log        (docker logs openfga-postgres)
#   - Dex log                            (docker logs dex, JSON-per-line)
#   - LLDAP log                          (docker logs lldap)
#   - Vault log                          (docker logs vault)
#   - Docker/compose state               (docker ps / inspect)
#
# Usage:
#   ./system_design/security_log_queries.sh           # run every query
#   ./system_design/security_log_queries.sh q13       # run one query
#   source ... && q13                                 # or source & call
#
# Notes:
#   * `docker logs` only shows what is still in the json-file buffer; if a
#     container was restarted the buffer is fresh. Persistent sources are
#     auth_audit.log (volume) and the Postgres `changelog`/`tuple` tables.
#   * OpenFGA log lines are:  <ts>\t<LEVEL>\t<event>\t<json>   (4 tab fields).
# =============================================================================

set -euo pipefail

# --- shared helpers ----------------------------------------------------------
AUTH_AUDIT="/var/lib/docker/volumes/libcloudrest_api-data/_data/auth_audit.log"
[ -r "$AUTH_AUDIT" ] || AUTH_AUDIT=""   # fall back to docker exec below

# All gRPC request-completion JSON from OpenFGA (filters out health checks).
ofga_reqs() {
  docker logs openfga 2>&1 \
    | awk -F'\t' '$3=="grpc_req_complete"{print $4}'
}

# auth_audit.log lines (host volume first, else docker exec).
auth_audit() {
  if [ -n "${AUTH_AUDIT:-}" ]; then
    cat "$AUTH_AUDIT"
  else
    docker exec libcloud-rest-api cat /app/data/auth_audit.log 2>/dev/null
  fi
}

psql_openfga() { docker exec openfga-postgres psql -U openfga -d openfga -t -A -F'|' "$@"; }

hdr() { printf '\n\033[1;36m=== Q%s: %s ===\033[0m\n' "$1" "$2"; }

# =============================================================================
# Tier 1 — Architecture / config posture (static)
# =============================================================================

q1() { hdr 1 "Is OpenFGA enforcing OIDC authn on its API?"
  docker logs openfga 2>&1 \
    | grep 'starting openfga service' | tail -1 \
    | sed 's/.*"Authn":/"Authn":/' \
    | grep -oE '"Authn":\{[^}]*\}' || echo "no startup config line in buffer"
}

q2() { hdr 2 "Is OpenFGA per-store AccessControl enabled?"
  docker logs openfga 2>&1 \
    | grep 'starting openfga service' | tail -1 \
    | grep -oE '"AccessControl":\{[^}]*\}' || true
}

q3() { hdr 3 "Is TLS enabled on OpenFGA HTTP/gRPC?"
  docker logs openfga 2>&1 | grep -i 'TLS is disabled' || echo "no TLS warning in buffer"
}

q4() { hdr 4 "Which OAuth clients are registered in Dex (secret exposure check)"
  echo "-- config.yaml clients --"
  grep -nE 'id:|name:|secret:' dex/config.yaml | sed -n '/client/,/redirectURIs/p'
  echo "-- generated env --"
  sed -n 's/\(.*SECRET.*\)=.*/\1=<redacted-present>/p' dex/generated/dex.env 2>/dev/null || true
}

q5() { hdr 5 "Dex signing-key rotation cadence"
  docker logs dex 2>&1 | grep -E 'keys rotated|keys expired, rotating' | tail -10
}

q6() { hdr 6 "Is Vault audit logging enabled?"
  docker exec -e VAULT_ADDR=http://127.0.0.1:8200 vault vault audit list 2>&1 \
    || echo "(403 = token lacks sys/audit; root needed to confirm/enable)"
}

q7() { hdr 7 "Does libcloud REST hold a root or scoped Vault token?"
  TOK=$(grep -E '^VAULT_TOKEN=' vault/generated/vault.env | head -1 | cut -d= -f2)
  echo "token prefix: ${TOK:0:8}…"
  docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN="$TOK" vault \
    vault token lookup-self 2>&1 | grep -E 'policies|renewable|ttl|path' || true
}

q8() { hdr 8 "Which ports are exposed externally?"
  docker ps --format '{{.Names}}\t{{.Ports}}' | awk '{print $1":\t"$2}'
}

# =============================================================================
# Tier 2 — Runtime authn / authz (who did what, allow/deny)
# =============================================================================

q9() { hdr 9 "Who authenticated and when (principal / subject / email)"
  auth_audit | tail -20
}

q10() { hdr 10 "Was each token issued by the expected Dex issuer?"
  auth_audit | jq -r '[.ts,.principal,.issuer] | @tsv' | sort -u
}

q11() { hdr 11 "LDAP login success/failure per user"
  docker logs dex 2>&1 \
    | jq -r 'select(.msg=="login successful" or .msg=="login failed")
             | [.time,.msg,.username,.email] | @tsv' 2>/dev/null | tail -20
}

q12() { hdr 12 "Per-call OpenFGA Check allow/deny (user, relation, object, allowed)"
  ofga_reqs \
    | jq -r 'select(.grpc_method=="Check" and .grpc_service!="grpc.health.v1.Health")
             | [.request_id,
                (.raw_request.tuple_key.user // "-"),
                (.raw_request.tuple_key.relation // "-"),
                (.raw_request.tuple_key.object // "-"),
                ((.raw_response.allowed // "n/a")|tostring)] | @tsv' 2>/dev/null | tail -30
}

q13() { hdr 13 "Which principal triggered an authorization denial?"
  echo "-- OpenFGA denials (allowed=false) --"
  ofga_reqs \
    | jq -r 'select(.grpc_method=="Check" and .grpc_service!="grpc.health.v1.Health"
                   and (.raw_response.allowed|not))
             | [.request_id,.peer.address,
                (.raw_request.tuple_key.user // "-"),
                (.raw_request.tuple_key.relation // "-"),
                (.raw_request.tuple_key.object // "-")] | @tsv' 2>/dev/null
  echo "-- libcloud 403 responses --"
  docker logs libcloud-rest-api 2>&1 | grep -E '403' || true
  echo "-- libcloud fga error lines --"
  docker logs libcloud-rest-api 2>&1 | grep -E 'OpenFGA check failed|authz_fga' || true
}

q14() { hdr 14 "Token/session reuse frequency per subject (replay/sharing signal)"
  auth_audit | jq -r '.subject' | sort | uniq -c | sort -rn
}

q15() { hdr 15 "Did a readonly/denied principal attempt a write (POST/PUT/DELETE)?"
  echo "-- readonly/denied token decodes by minute --"
  auth_audit \
    | jq -r 'select(.principal|test("readonly|denied|viewer"))
             | [.ts[0:16],.principal] | @tsv' | sort
  echo "-- write methods in API access log --"
  docker logs libcloud-rest-api 2>&1 \
    | grep -oE '"(POST|PUT|DELETE) [^ ]* HTTP' | sort | uniq -c | sort -rn
}

q16() { hdr 16 "Did a tenant user reach into another tenant's provider?"
  ofga_reqs \
    | jq -r 'select(.grpc_method=="Check" and (.raw_request.tuple_key.relation|test("can_use|can_provision")))
             | [(.raw_request.tuple_key.user),
                (.raw_request.tuple_key.relation),
                (.raw_request.tuple_key.object),
                (.raw_response.allowed|tostring)] | @tsv' 2>/dev/null
}

q17() { hdr 17 "OpenFGA 503 / unavailable / error surface"
  docker logs libcloud-rest-api 2>&1 \
    | grep -E 'authz_fga_error|authz_fga_unavailable|OpenFGA check failed|503' || true
  echo "-- non-zero grpc_code on FGA service calls --"
  ofga_reqs \
    | jq -r 'select(.grpc_service!="grpc.health.v1.Health" and (.grpc_code//0)!=0)
             | [.request_id,.grpc_method,.grpc_code] | @tsv' 2>/dev/null
}

# =============================================================================
# Tier 3 — Authorization-state changes (privilege changes)
# =============================================================================

q18() { hdr 18 "Who granted/revoked which OpenFGA tuple and when?"
  echo "-- changelog (0=insert,1=delete) --"
  psql_openfga -c "select inserted_at, operation, relation, _user,
                          object_type||':'||object_id as object
                   from changelog order by inserted_at desc limit 30;"
  echo "-- Write calls in FGA log (actor only if JWT forwarded) --"
  ofga_reqs \
    | jq -r 'select(.grpc_method=="Write")
             | [.request_id,.peer.address,
                (.raw_request.writes|tostring),
                (.raw_request.deletes|tostring)] | @tsv' 2>/dev/null | tail -10
}

q19() { hdr 19 "When was the authorization model created/changed?"
  psql_openfga -c "select store_id, substr(id,1,10) as model_id, inserted_at
                   from authorization_model order by inserted_at desc;"
  ofga_reqs \
    | jq -r 'select(.grpc_method=="WriteAuthorizationModel")
             | [.request_id,.peer.address] | @tsv' 2>/dev/null
}

q20() { hdr 20 "Has the live tuple table drifted vs changelog?"
  local tins tdels trows
  trows=$(psql_openfga -c 'select count(*) from tuple;')
  tins=$(psql_openfga -c 'select count(*) from changelog where operation=0;')
  tdels=$(psql_openfga -c 'select count(*) from changelog where operation=1;')
  echo "tuple rows:    ${trows:-?}"
  echo "changelog ins: ${tins:-?}"
  echo "changelog del: ${tdels:-?}"
  psql_openfga -c "select relation, count(*) from tuple group by relation order by relation;"
}

# =============================================================================
# Tier 4 — Secret / credential access
# =============================================================================

q21() { hdr 21 "Who read which cloud credential from Vault, and when?"
  echo "GAP: Vault audit not enabled. Enable with:"
  echo "  docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=<root> vault \\"
  echo "    vault audit enable file file_path=/vault/audit/audit.log"
  echo "Until then only failures are visible (see q22)."
}

q22() { hdr 22 "Failed Vault reads (missing binding / unreachable)"
  docker logs libcloud-rest-api 2>&1 \
    | grep -E 'Vault read failed|server_credentials_missing|server_credentials_unavailable' || true
}

q23() { hdr 23 "Vault token used from an unexpected source / seal state"
  docker logs vault 2>&1 | grep -iE 'sealed|unsealed|audit|token|auth' | tail -20 || true
}

# =============================================================================
# Tier 5 — Incident / anomaly detection
# =============================================================================

q24() { hdr 24 "Brute-force / scanning attempts against exposed ports"
  echo "-- Postgres auth failures --"
  docker logs openfga-postgres 2>&1 | grep -E 'FATAL:|password authentication failed|unsupported frontend' | tail -20
  echo "-- LLDAP malformed-header probes --"
  docker logs lldap 2>&1 | grep -iE 'invalid Header|error|FATAL' | tail -10
  echo "-- libcloud malformed HTTP --"
  docker logs libcloud-rest-api 2>&1 | grep -E 'Invalid HTTP request received' | tail -10
  echo "-- external IPs hitting API (non-localhost) --"
  docker logs libcloud-rest-api 2>&1 \
    | grep -oE 'INFO: +[0-9.]+:[0-9]+' | awk '{print $2}' | cut -d: -f1 \
    | sort | uniq -c | sort -rn | head
}

q25() { hdr 25 "Spike in token decodes / Check calls per principal"
  echo "-- auth_audit per-principal counts --"
  auth_audit | jq -r '.principal' | sort | uniq -c | sort -rn
  echo "-- Check calls per peer in FGA log --"
  ofga_reqs | jq -r 'select(.grpc_method=="Check" and .grpc_service!="grpc.health.v1.Health") | .peer.address' 2>/dev/null \
    | sort | uniq -c | sort -rn | head
  echo "-- live Prometheus counters --"
  curl -s http://localhost:2112/metrics 2>/dev/null \
    | grep -E 'openfga_request_duration|grpc_server_handled' | head -20 || true
}

q26() { hdr 26 "Direct OpenFGA access bypassing the REST API"
  ofga_reqs \
    | jq -r 'select(.grpc_service!="grpc.health.v1.Health")
             | [.peer.address,.grpc_method,.user_agent] | @tsv' 2>/dev/null \
    | sort -u
}

q27() { hdr 27 "Container restarts / crashes / OOMs"
  docker ps --format '{{.Names}}\t{{.Status}}'
  echo "-- boot/shutdown events --"
  docker logs openfga 2>&1 | grep -E 'starting openfga service|HTTP server shut down' | tail -10
  docker logs libcloud-rest-api 2>&1 | grep -iE 'started server|application startup|shutting down' | tail -10
}

q28() { hdr 28 "Dex key-rotation continuity (any skipped/tampered window?)"
  docker logs dex 2>&1 | grep -E 'keys rotated|keys expired' | awk '{print $1, $2}' | sort
}

q29() { hdr 29 "Long-lived tokens leaked into logs/artifacts"
  echo "-- scan host log/ dir for bearer tokens --"
  grep -rniE 'Bearer [A-Za-z0-9._-]{40,}|hvs\.[A-Za-z0-9_-]{20,}|refresh_token' log/ 2>/dev/null | head -10 || true
  echo "-- generated token artifacts --"
  ls -la generated/tokens/ 2>/dev/null || true
}

q30() { hdr 30 "End-to-end request chain reconstruction (correlation-id check)"
  echo "-- Does libcloud log X-Request-ID in access log? --"
  docker logs libcloud-rest-api 2>&1 | grep -i 'request-id' | head -3 || echo "NO (GAP: not in access log)"
  echo "-- Does OpenFGA receive a forwarded id? --"
  ofga_reqs | jq -r 'keys[]' 2>/dev/null | grep -i request || true
  echo "-- Trace enabled? --"
  docker logs openfga 2>&1 | grep 'starting openfga service' | tail -1 \
    | grep -oE '"Trace":\{[^}]*\}' || true
}

# =============================================================================
# Tier 6 — Integrity / retention
# =============================================================================

q31() { hdr 31 "Was the tuple table modified outside the API (direct DB write)?"
  echo "-- direct (non-openfga) DB connections in pg log --"
  docker logs openfga-postgres 2>&1 | grep -E 'FATAL|connection received|authentication' | tail -20
  echo "-- changelog vs tuple consistency --"
  q20
}

q32() { hdr 32 "Are audit logs tamper-protected / retained?"
  echo "-- auth_audit.log perms & size --"
  docker exec libcloud-rest-api ls -la /app/data/auth_audit.log 2>&1 || ls -la "$AUTH_AUDIT" 2>/dev/null
  echo "-- docker log driver + rotation (empty = no rotation) --"
  for c in libcloud-rest-api openfga dex openfga-postgres lldap vault; do
    printf '%-20s ' "$c"
    docker inspect "$c" --format '{{.HostConfig.LogConfig.Type}} {{json .HostConfig.LogConfig.Config}}'
  done
}

# =============================================================================
ALL="q1 q2 q3 q4 q5 q6 q7 q8 q9 q10 q11 q12 q13 q14 q15 q16 q17 q18 q19 q20 \
     q21 q22 q23 q24 q25 q26 q27 q28 q29 q30 q31 q32"

if [ $# -gt 0 ]; then
  for f in "$@"; do "$f"; done
else
  for f in $ALL; do "$f"; done
fi
