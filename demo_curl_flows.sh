#!/usr/bin/env bash
# demo_curl_flows.sh — demonstrate the HTTP flows between the dockers.
#
# Sections:
#   A. Direct discovery curls to every docker (health, .well-known, JWKS)
#   B. Login at Dex as an LLDAP user (portal client libcloud-portal)
#   C. Exchange the code at identity_service -> portal cookie
#   D. Use the portal cookie to access cloud resources via identity_service
#   E. Logout
#   F. Demonstrate the portal cookie is now blocked (frontend blocked)
#   G. Direct Dex login as aws-admin via libcloud-rest client (server-to-server)
#   H. Demonstrate libcloud.rest STILL accepts that token after portal logout
#   I. Direct curls to OpenFGA, Vault, LLDAP
#
# Run: bash demo_curl_flows.sh
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# ── config ────────────────────────────────────────────────────────────────
# PUBLIC_HOSTNAME is read from the environment (set in root .env by setup.sh).
PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME}"
DEX_HOST=http://localhost:5556
# The issuer MUST match Dex's configured issuer (in-container: http://dex:5556/dex).
# Host-side scripts use localhost:5556 to reach Dex, but the JWT iss claim is
# dex:5556/dex. For validation, match the issuer, not the reachable URL.
DEX_ISSUER="http://dex:5556/dex"
IDENTITY=http://localhost:8766
REST=http://localhost:8765
OPENFGA=http://localhost:8080
LLDAP_LDAP=localhost:3890
LLDAP_HTTP=http://localhost:17170
VAULT=http://localhost:8200
PORTAL=http://localhost:3000

# From dex/generated/dex.env (in the repo)
PORTAL_CLIENT=libcloud-portal
PORTAL_SECRET=l33WEHol5lO3CkSXZv7Bw14587VgIHWB_YbxO0oll74
PORTAL_REDIRECT="http://${PUBLIC_HOSTNAME}:3000/auth/callback"

REST_CLIENT=libcloud-rest
REST_SECRET=kPV2bAbb0oOIeUqqvAlZAvrZtqbOULlPILWZn4f5egk
REST_REDIRECT=http://127.0.0.1:8766/oauth/callback

# From dex/generated/dex.env — an LLDAP service-account user
USER=aws-admin
PASS=SA-8dp2YSE6nCCB2Yt3X67QMMHS

# From openfga_postgres/generated/fga.env
FGA_STORE=01KXFQ6JWFD2MZKFDFSHYNNNXE
FGA_MODEL=01KXWWZY8424AMK2B443FH7TQ0

# From libcloud.rest/.env (synced from vault/generated/vault.env)
VAULT_TOKEN=$(grep '^VAULT_TOKEN=' "$REPO_ROOT/libcloud.rest/.env" | cut -d= -f2)

JAR=/tmp/demo_cookies.txt
rm -f "$JAR"; touch "$JAR"

hr() { printf '\n═══ %s ═══════════════════════════════════════════════════\n' "$1"; }

# ── A. Discovery curls to every docker ─────────────────────────────────────
hr "A. Discovery — every docker's health / metadata endpoint"

echo "→ Portal (:3000)";              curl -sS "$PORTAL/" -o /dev/null -w "  HTTP %{http_code}\n"
echo "→ identity_service (:8766)";     curl -sS "$IDENTITY/health" -w "  HTTP %{http_code}\n"
echo "→ libcloud.rest (:8765)";        curl -sS "$REST/health" -w "  HTTP %{http_code}\n"
echo "→ Dex (:5556) .well-known";      curl -sS "$DEX_HOST/dex/.well-known/openid-configuration" | head -c 200; echo
echo "→ Dex JWKS";                     curl -sS "$DEX_HOST/dex/keys" | head -c 200; echo
echo "→ OpenFGA (:8080) ready";        curl -sS "$OPENFGA/healthz" -w "  HTTP %{http_code}\n" || true
echo "→ OpenFGA stores";               curl -sS "$OPENFGA/stores" | head -c 300; echo
echo "→ LLDAP (:17170) health";       curl -sS "$LLDAP_HTTP/health" -w "  HTTP %{http_code}\n"
echo "→ Vault (:8200) health";         curl -sS "$VAULT/v1/sys/health" -w "  HTTP %{http_code}\n"


# ── B. Login at Dex as aws-admin (portal client) ────────────────────────────
hr "B. Login at Dex as $USER via portal client $PORTAL_CLIENT"

# 1. identity_service /api/auth/begin mints state + PKCE verifier, returns authorize URL
BEGIN=$(curl -sS "$IDENTITY/api/auth/begin?provider=lldap")
echo "begin response: $BEGIN"
STATE=$(echo "$BEGIN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])')
AUTH_URL=$(echo "$BEGIN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["authorizeUrl"])')
echo "state: $STATE"
echo "authorizeUrl: $AUTH_URL"

# 2. GET the authorize URL -> Dex returns the LDAP login form HTML
FORM_HTML=$(curl -sS -c "$JAR" "$AUTH_URL")
# Extract the form action URL (relative, starts with /dex/auth/...)
ACTION=$(echo "$FORM_HTML" | grep -oP 'action="\K[^"]+' | head -1 | sed 's/&amp;/\&/g')
LOGIN_URL="$DEX_HOST$ACTION"
echo "login form POST URL: $LOGIN_URL"

# 3. POST credentials; don't follow redirects — capture the Location header
REDIR_HEADERS=$(curl -sS -D - -o /dev/null -b "$JAR" -c "$JAR" \
  -X POST "$LOGIN_URL" \
  --data-urlencode "login=$USER" \
  --data-urlencode "password=$PASS")
echo "$REDIR_HEADERS" | grep -i '^location:'

# The Location chain ends at redirect_uri?code=...&state=...
# Walk the redirects manually until we find code=
CODE=""
LOC=$(echo "$REDIR_HEADERS" | grep -i '^location:' | head -1 | sed 's/^[Ll]ocation: //' | tr -d '\r')
while [ -n "$LOC" ]; do
  if echo "$LOC" | grep -q 'code='; then
    CODE=$(echo "$LOC" | grep -oP 'code=\K[^&]+')
    break
  fi
  case "$LOC" in
    http*) NEXT_URL="$LOC" ;;
    /*)    NEXT_URL="$DEX_HOST$LOC" ;;
    *)     NEXT_URL="$LOC" ;;
  esac
  REDIR_HEADERS=$(curl -sS -D - -o /dev/null -b "$JAR" -c "$JAR" "$NEXT_URL")
  LOC=$(echo "$REDIR_HEADERS" | grep -i '^location:' | head -1 | sed 's/^[Ll]ocation: //' | tr -d '\r')
done
echo "authorization code: $CODE"

# ── C. Exchange the code at identity_service -> portal cookie ──────────────
hr "C. Exchange code at identity_service /api/auth/exchange"

EXCHANGE=$(curl -sS -c "$JAR" -b "$JAR" \
  -X POST "$IDENTITY/api/auth/exchange" \
  -H 'Content-Type: application/json' \
  -d "{\"state\":\"$STATE\",\"code\":\"$CODE\",\"provider\":\"lldap\",\"redirectUri\":\"$PORTAL_REDIRECT\"}")
echo "exchange response: $EXCHANGE"
echo "portal cookie jar:"; grep libcloud_portal_sid "$JAR" || echo "  (no portal cookie captured — check exchange)"

# ── D. Use the portal cookie to access cloud resources ────────────────────
hr "D. Use portal cookie to call identity_service /api/resources/aws"

curl -sS -b "$JAR" "$IDENTITY/api/session" | python3 -m json.tool 2>/dev/null || curl -sS -b "$JAR" "$IDENTITY/api/session"
echo
curl -sS -b "$JAR" -w "\n  HTTP %{http_code}\n" "$IDENTITY/api/resources/aws"

# ── E. Logout ──────────────────────────────────────────────────────────────
hr "E. Logout at identity_service /api/logout"

curl -sS -b "$JAR" -c "$JAR" -X POST "$IDENTITY/api/logout" -w "\n  HTTP %{http_code}\n"
echo "portal cookie after logout:"; grep libcloud_portal_sid "$JAR" || echo "  (cookie deleted by server)"

# ── F. Demonstrate the portal cookie is now blocked ────────────────────────
hr "F. After logout — portal cookie is rejected (frontend blocked)"

echo "→ /api/session with stale cookie:"
curl -sS -b "$JAR" -w "\n  HTTP %{http_code}\n" "$IDENTITY/api/session"
echo "→ /api/resources/aws with stale cookie:"
curl -sS -b "$JAR" -w "\n  HTTP %{http_code}\n" "$IDENTITY/api/resources/aws"


# ── G. Direct Dex login as aws-admin via libcloud-rest client ──────────────
hr "G. BYPASS: log in to Dex directly as $USER via libcloud-rest client"
hr "   (the same flow identity_service's ProvisionerAuth runs internally)"

# This is the server-to-server flow from idp_login.py — no PKCE, just
# client_secret. Anyone with the LLDAP password + the libcloud-rest client
# secret (which is in dex/generated/dex.env in the repo) can do this.
JAR2=/tmp/demo_cookies2.txt; rm -f "$JAR2"; touch "$JAR2"

PARAMS="client_id=$REST_CLIENT&redirect_uri=$(python3 -c 'import urllib.parse;print(urllib.parse.quote("'"$REST_REDIRECT"'",safe=""))')&response_type=code&scope=openid+email+profile&state=bypass-$(date +%s)&connector_id=lldap"
FORM_HTML=$(curl -sS -c "$JAR2" "$DEX_HOST/dex/auth?$PARAMS")
ACTION=$(echo "$FORM_HTML" | grep -oP 'action="\K[^"]+' | head -1 | sed 's/&amp;/\&/g')
LOGIN_URL="$DEX_HOST$ACTION"

REDIR_HEADERS=$(curl -sS -D - -o /dev/null -b "$JAR2" -c "$JAR2" \
  -X POST "$LOGIN_URL" \
  --data-urlencode "login=$USER" \
  --data-urlencode "password=$PASS")
CODE=""
LOC=$(echo "$REDIR_HEADERS" | grep -i '^location:' | head -1 | sed 's/^[Ll]ocation: //' | tr -d '\r')
while [ -n "$LOC" ]; do
  if echo "$LOC" | grep -q 'code='; then
    CODE=$(echo "$LOC" | grep -oP 'code=\K[^&]+'); break
  fi
  case "$LOC" in http*) NEXT_URL="$LOC" ;; /*) NEXT_URL="$DEX_HOST$LOC" ;; *) NEXT_URL="$LOC" ;; esac
  REDIR_HEADERS=$(curl -sS -D - -o /dev/null -b "$JAR2" -c "$JAR2" "$NEXT_URL")
  LOC=$(echo "$REDIR_HEADERS" | grep -i '^location:' | head -1 | sed 's/^[Ll]ocation: //' | tr -d '\r')
done
echo "authorization code (libcloud-rest audience): $CODE"

# Exchange the code for tokens — audience libcloud-rest
TOKENS=$(curl -sS -X POST "$DEX_HOST/dex/token" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "code=$CODE" \
  --data-urlencode "redirect_uri=$REST_REDIRECT" \
  --data-urlencode "client_id=$REST_CLIENT" \
  --data-urlencode "client_secret=$REST_SECRET")
echo "token response (truncated): $(echo "$TOKENS" | head -c 200)..."
ACCESS_TOKEN=$(echo "$TOKENS" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
REFRESH_TOKEN=$(echo "$TOKENS" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("refresh_token",""))')
echo "access_token (first 60 chars): ${ACCESS_TOKEN:0:60}..."

# ── H. libcloud.rest STILL accepts this token after portal logout ─────────
hr "H. Call libcloud.rest DIRECTLY with the libcloud-rest token"
hr "   (identity_service is bypassed entirely; portal logout did nothing to stop this)"

CONN='{"provider":"aws","config":{"region":"ap-southeast-1","secure":true},"auth_binding":"aws"}'
echo "→ GET /v1/auth/me (token introspection at the REST API):"
curl -sS -H "Authorization: Bearer $ACCESS_TOKEN" \
     -H "X-Provider-Connection: $CONN" \
     -w "\n  HTTP %{http_code}\n" "$REST/v1/auth/me"

echo "→ GET /v1/compute/nodes (list AWS nodes — bypasses identity_service):"
curl -sS -H "Authorization: Bearer $ACCESS_TOKEN" \
     -H "X-Provider-Connection: $CONN" \
     -w "\n  HTTP %{http_code}\n" "$REST/v1/compute/nodes"

echo "→ POST /v1/connections:test (verify the REST API accepts the connection):"
curl -sS -X POST -H "Authorization: Bearer $ACCESS_TOKEN" \
     -H "X-Provider-Connection: $CONN" \
     -H 'Content-Type: application/json' \
     -d "$CONN" -w "\n  HTTP %{http_code}\n" "$REST/v1/connections:test"

# Show that the token still works because libcloud.rest is stateless — it
# validates the JWT against Dex JWKS per request and has no idea the portal
# user "logged out." The portal cookie is irrelevant to libcloud.rest.
echo
echo "NOTE: libcloud.rest returned 200 because:"
echo "  1. The access_token is a valid Dex-issued JWT (aud=libcloud-rest)."
echo "  2. libcloud.rest is stateless — it has no portal-session store to check."
echo "  3. The portal logout only deleted the identity_service cookie."
echo "  4. Dex's SSO session is also still alive (the browser cookie on Dex's domain)."

# ── I. Direct curls to OpenFGA, Vault, LLDAP ───────────────────────────────
hr "I. Direct curls to the other dockers"

echo "→ OpenFGA /check: can aws-admin can_provision aws_region:aws?"
curl -sS -X POST "$OPENFGA/stores/$FGA_STORE/check" \
  -H 'Content-Type: application/json' \
  -d "{\"authorization_model_id\":\"$FGA_MODEL\",\"tuple_key\":{\"user\":\"user:aws-admin\",\"relation\":\"can_provision\",\"object\":\"aws_region:aws\"}}" \
  -w "\n  HTTP %{http_code}\n"

echo "→ OpenFGA /read: first page of tuples"
curl -sS -X POST "$OPENFGA/stores/$FGA_STORE/read" \
  -H 'Content-Type: application/json' \
  -d "{\"authorization_model_id\":\"$FGA_MODEL\",\"page_size\":5}" \
  | python3 -m json.tool 2>/dev/null | head -40

echo "→ Vault: read the AWS backend credentials (secret/data/libcloud/aws)"
curl -sS -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT/v1/secret/data/libcloud/aws" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print({k:"<redacted>" if k in ("AWS_ACCESS_KEY_ID","AWS_SECRET_ACCESS_KEY","LIBCLOUD_AWS_PROD_KEY","LIBCLOUD_AWS_PROD_SECRET") else v for k,v in d.get("data",{}).get("data",{}).items()})' 2>/dev/null \
  || curl -sS -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT/v1/secret/data/libcloud/aws" | head -c 300
echo

echo "→ Vault: list secrets under secret/metadata/libcloud/"
curl -sS -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT/v1/secret/metadata/libcloud/" -w "\n  HTTP %{http_code}\n"

echo "→ LLDAP HTTP/GraphQL: list users (admin bind via HTTP basic)"
LLDAP_ADMIN_PASS=$(grep '^LLDAP_LDAP_USER_PASS=' "$REPO_ROOT/lldap/.env" | cut -d= -f2)
curl -sS -u "admin:$LLDAP_ADMIN_PASS" \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ users { id uid email displayName } }"}' \
  "$LLDAP_HTTP/graphql" | head -c 400; echo

echo "→ LLDAP LDAP search: ou=people,dc=libcloud,dc=local"
ldapsearch -x -H ldap://$LLDAP_LDAP \
  -D "uid=admin,ou=people,dc=libcloud,dc=local" -w "$LLDAP_ADMIN_PASS" \
  -b "ou=people,dc=libcloud,dc=local" "(objectClass=person)" cn mail uid 2>/dev/null | head -20 \
  || echo "  (ldapsearch not installed — install with: sudo apt-get install ldap-utils)"

hr "Done. Key takeaway: portal logout only clears the identity_service cookie."
echo "libcloud.rest is stateless and accepts any valid Dex-issued JWT with aud=libcloud-rest,"
echo "regardless of whether the portal session is alive. Anyone with an LLDAP password + the"
echo "libcloud-rest client secret (both in the repo's .env files) can bypass identity_service"
echo "entirely and call libcloud.rest directly."
