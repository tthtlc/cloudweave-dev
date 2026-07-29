#!/usr/bin/env bash
# =============================================================================
# generate.sh — Generate sample HTTP request/response pairs for every HTTP
#               interaction in the libcloud portal system.
#
# Usage:  bash generate.sh
# Output: 38 subdirectories under http_flow_examples/, each with:
#           - request.http   (raw HTTP request)
#           - response.http  (raw HTTP response)
#
# See: system_http_flow.md for the full architectural trace.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
COUNT=0

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
_section() {
  echo ""
  echo "=== $* ==="
}

_dir() {
  # $1 = NN-description
  local d="$ROOT/$1"
  mkdir -p "$d"
  echo "  → $1"
  COUNT=$((COUNT + 1))
}

_req() {
  # $1 = directory, $2+ = content (via pipe or heredoc)
  cat > "$ROOT/$1/request.http"
}

_resp() {
  cat > "$ROOT/$1/response.http"
}

# ---------------------------------------------------------------------------
# STAGE 1: Login Initiation
# ---------------------------------------------------------------------------
gen_01_auth_begin() {
  _section "01 — GET /api/auth/begin (Browser → Identity Service)"
  _dir "01-auth-begin"

  _req "01-auth-begin" << 'EOF'
GET /api/auth/begin?provider=lldap&redirect_uri=http://localhost:3000/auth/callback HTTP/1.1
Host: localhost:8766
Accept: application/json
Accept-Language: en-US,en;q=0.9

(empty body — GET request)
EOF

  _resp "01-auth-begin" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 587
Date: Wed, 23 Jul 2026 14:22:01 GMT

{
  "authorizeUrl": "http://login.quest4science.xyz:5556/dex/auth?client_id=libcloud-portal&redirect_uri=http%3A%2F%2Flocalhost%3A3000%2Fauth%2Fcallback&response_type=code&scope=openid+profile+email&state=aB3kXp9qR7sW2vY6uN1mF4dG8jL0oQ5t&code_challenge=KzP9wLm2xR7vQ4nJ8sA1dF6gH0kT3yB5&code_challenge_method=S256&connector_id=lldap",
  "state": "aB3kXp9qR7sW2vY6uN1mF4dG8jL0oQ5t",
  "provider": "lldap"
}
EOF
}

gen_02_dex_authorize() {
  _section "02 — GET /dex/auth (Browser → Dex OIDC Authorization)"
  _dir "02-dex-authorize"

  _req "02-dex-authorize" << 'EOF'
GET /dex/auth?client_id=libcloud-portal&redirect_uri=http%3A%2F%2Flocalhost%3A3000%2Fauth%2Fcallback&response_type=code&scope=openid+profile+email&state=aB3kXp9qR7sW2vY6uN1mF4dG8jL0oQ5t&code_challenge=KzP9wLm2xR7vQ4nJ8sA1dF6gH0kT3yB5&code_challenge_method=S256&connector_id=lldap HTTP/1.1
Host: login.quest4science.xyz:5556
Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8
User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36

(empty body — browser navigation, GET request)
EOF

  _resp "02-dex-authorize" << 'EOF'
HTTP/1.1 302 Found
Location: /dex/auth/local?req=cnm6k4qj2p7w9b5d&state=aB3kXp9qR7sW2vY6uN1mF4dG8jL0oQ5t
Set-Cookie: dex_session=eyJhbGciOiJIUzI1NiJ9...; Path=/; HttpOnly; SameSite=Lax
Date: Wed, 23 Jul 2026 14:22:02 GMT

(empty body — 302 redirect to Dex LDAP login form)
EOF
}

gen_03_dex_callback() {
  _section "03 — GET /auth/callback (Dex → Browser redirect with auth code)"
  _dir "03-dex-callback"

  _req "03-dex-callback" << 'EOF'
GET /auth/callback?code=dex-abc123def456ghi789jkl012mno345pqr&state=aB3kXp9qR7sW2vY6uN1mF4dG8jL0oQ5t HTTP/1.1
Host: localhost:3000
Accept: text/html,application/xhtml+xml
User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36

(empty body — browser redirect from Dex after successful authentication)
EOF

  _resp "03-dex-callback" << 'EOF'
# NOTE: This is a browser-to-SPA navigation, not an API call.
# The React SPA at localhost:3000 handles /auth/callback client-side.
# AuthCallbackPage.js reads `code` and `state` from the URL query params
# and calls POST /api/auth/exchange (see 04-auth-exchange).
#
# No HTTP response is generated here — the SPA renders client-side.
EOF
}

# ---------------------------------------------------------------------------
# STAGE 2: Token Exchange
# ---------------------------------------------------------------------------
gen_04_auth_exchange() {
  _section "04 — POST /api/auth/exchange (Browser → Identity Service)"
  _dir "04-auth-exchange"

  _req "04-auth-exchange" << 'EOF'
POST /api/auth/exchange HTTP/1.1
Host: localhost:8766
Content-Type: application/json
Accept: application/json
Content-Length: 221

{
  "provider": "lldap",
  "code": "dex-abc123def456ghi789jkl012mno345pqr",
  "state": "aB3kXp9qR7sW2vY6uN1mF4dG8jL0oQ5t",
  "redirectUri": "http://localhost:3000/auth/callback"
}
EOF

  _resp "04-auth-exchange" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Set-Cookie: libcloud_portal_sid=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpbnRlcm5hbFVzZXJJZCI6ImludC1hd3MtYWRtaW4iLCJyb2xlIjoiYWRtaW4iLCJlbWFpbCI6ImFkbWluQGV4YW1wbGUuY29tIiwibGlua2VkSWRlbnRpdGllcyI6WyJsbGRhcDpDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiXSwic2lkIjoiYTEyYjM0YzU2ZDdlOGY5MCIsImlhdCI6MTc1MzQ4NjkyMSwiZXhwIjoxNzUzNTE1NzIxLCJqdGkiOiJlMTIzZjQ1Nmc3ODloMDEyIn0.SIGNATURE_HERE; HttpOnly; SameSite=Lax; Path=/; Max-Age=28800
Content-Length: 403
Date: Wed, 23 Jul 2026 14:22:03 GMT

{
  "internalUserId": "int-aws-admin",
  "role": "admin",
  "linkedIdentities": [
    "lldap:CiQgT1JURV9VU0VFOkJMQk9DSw=="
  ],
  "email": "aws-admin@libcloud.local",
  "clouds": [
    {
      "cloud": "aws",
      "canView": true,
      "canProvision": true,
      "canUpdate": true
    },
    {
      "cloud": "nutanix",
      "canView": true,
      "canProvision": false,
      "canUpdate": false
    }
  ]
}
EOF
}

gen_04b_auth_exchange_collapse() {
  _section "04b — POST /api/auth/exchange → Identity Collapse Required"
  _dir "04b-auth-exchange-collapse"

  _req "04b-auth-exchange-collapse" << 'EOF'
POST /api/auth/exchange HTTP/1.1
Host: localhost:8766
Content-Type: application/json
Accept: application/json
Content-Length: 223

{
  "provider": "github",
  "code": "dex-gh789xyz012abc345def678ghi901jkl",
  "state": "cD4eF5gH6iJ7kL8mN9oP0qR1sT2uV3wX",
  "redirectUri": "http://localhost:3000/auth/callback"
}
EOF

  _resp "04b-auth-exchange-collapse" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 612
Date: Wed, 23 Jul 2026 14:22:04 GMT

{
  "needsIdentityCollapse": true,
  "collapseCandidates": [
    {
      "internalUserId": "int-aws-admin",
      "email": "admin@example.com",
      "displayName": "AWS Admin",
      "role": "admin",
      "linkedIdentities": ["lldap:CiQgT1JURV9VU0VFOkJMQk9DSw=="]
    }
  ],
  "pendingIdentity": {
    "provider": "github",
    "subject": "github:12345678",
    "email": "admin@example.com"
  },
  "pendingToken": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJwcm92aWRlciI6ImdpdGh1YiIsInN1YmplY3QiOiJnaXRodWI6MTIzNDU2NzgiLCJlbWFpbCI6ImFkbWluQGV4YW1wbGUuY29tIiwiaWF0IjoxNzUzNDg2OTI0LCJleHAiOjE3NTM0ODcyMjQsImp0aSI6ImFiY2RlZjEyMzQ1Njc4OTAiLCJ0eXBlIjoicGVuZGluZ19pZGVudGl0eSJ9.SIGNATURE"
}
EOF
}

gen_05_dex_token_exchange() {
  _section "05 — POST /dex/token (Identity Service → Dex, Server-to-Server)"
  _dir "05-dex-token-exchange"

  _req "05-dex-token-exchange" << 'EOF'
POST /dex/token HTTP/1.1
Host: dex:5556
Content-Type: application/x-www-form-urlencoded
Accept: application/json
Content-Length: 415

grant_type=authorization_code&
code=dex-abc123def456ghi789jkl012mno345pqr&
redirect_uri=http%3A%2F%2Flocalhost%3A3000%2Fauth%2Fcallback&
client_id=libcloud-portal&
client_secret=ZXhhbXBsZS1wb3J0YWwtc2VjcmV0LWtleS0xMjM0NTY3OA&
code_verifier=aB3kXp9qR7sW2vY6uN1mF4dG8jL0oQ5tcD4eF5gH6iJ7kL8mN9oP0qR1sT2uV3wXyZ
EOF

  _resp "05-dex-token-exchange" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Cache-Control: no-store
Pragma: no-cache
Content-Length: 1427
Date: Wed, 23 Jul 2026 14:22:03 GMT

{
  "access_token": "eyJhbGciOiJSUzI1NiIsImtpZCI6IjExMjIzMzQ0NTU2Njc3ODg5OSJ9.eyJpc3MiOiJodHRwOi8vbG9naW4ucXVlc3Q0c2NpZW5jZS54eXo6NTU1Ni9kZXgiLCJzdWIiOiJDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiLCJhdWQiOiJsaWJjbG91ZC1wb3J0YWwiLCJleHAiOjE3NTM0OTA1MjEsImlhdCI6MTc1MzQ4NjkyMSwiYXRfaGFzaCI6ImFiYzEyMyIsImVtYWlsIjoiYXdzLWFkbWluQGxpYmNsb3VkLmxvY2FsIiwiZW1haWxfdmVyaWZpZWQiOnRydWUsIm5hbWUiOiJBV1MgQWRtaW4ifQ.SIGNATURE",
  "token_type": "bearer",
  "expires_in": 3600,
  "refresh_token": "ChlDZXgtcmVmcmVzaC10b2tlbi1leGFtcGxlLTEyMzQ1Njc4OTBhYmNkZWY",
  "id_token": "eyJhbGciOiJSUzI1NiIsImtpZCI6IjExMjIzMzQ0NTU2Njc3ODg5OSJ9.eyJpc3MiOiJodHRwOi8vbG9naW4ucXVlc3Q0c2NpZW5jZS54eXo6NTU1Ni9kZXgiLCJzdWIiOiJDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiLCJhdWQiOiJsaWJjbG91ZC1wb3J0YWwiLCJleHAiOjE3NTM0OTA1MjEsImlhdCI6MTc1MzQ4NjkyMSwibm9uY2UiOiJhYmMxMjMiLCJhdF9oYXNoIjoiZGVmNDU2IiwiZW1haWwiOiJhd3MtYWRtaW5AbGliY2xvdWQubG9jYWwiLCJlbWFpbF92ZXJpZmllZCI6dHJ1ZSwibmFtZSI6IkFXUyBBZG1pbiJ9.SIGNATURE"
}
EOF
}

gen_06_dex_jwks() {
  _section "06 — GET /dex/keys (Identity Service → Dex, JWKS fetch)"
  _dir "06-dex-jwks"

  _req "06-dex-jwks" << 'EOF'
GET /dex/keys HTTP/1.1
Host: dex:5556
Accept: application/json
User-Agent: PyJWKClient/2.8.0

(empty body — GET request, cached by PyJWKClient)
EOF

  _resp "06-dex-jwks" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Cache-Control: public, max-age=3600
Content-Length: 1432
Date: Wed, 23 Jul 2026 14:22:03 GMT

{
  "keys": [
    {
      "use": "sig",
      "kty": "RSA",
      "kid": "112233445566778899aabbccddeeff00",
      "alg": "RS256",
      "n": "0vx7agoebGcQSuuPiLgXfpt4cPZ7YbAMJHZRj9xP9Y8q9eB3xL5mN2pQ7rS8tU1vW4xY6zA0bC2dE4fG6hI8jK0lM2nO4pQ6rS8tU1vW4xY6zA0bC2dE4fG6hI8jK0lM2n",
      "e": "AQAB"
    }
  ]
}
EOF
}

# ---------------------------------------------------------------------------
# STAGE 3: Identity Collapse
# ---------------------------------------------------------------------------
gen_07_auth_collapse() {
  _section "07 — POST /api/auth/collapse (Browser → Identity Service)"
  _dir "07-auth-collapse"

  _req "07-auth-collapse" << 'EOF'
POST /api/auth/collapse HTTP/1.1
Host: localhost:8766
Content-Type: application/json
Accept: application/json
Content-Length: 351

{
  "targetInternalUserId": "int-aws-admin",
  "pendingIdentity": {
    "provider": "github",
    "subject": "github:12345678",
    "email": "admin@example.com"
  },
  "pendingToken": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJwcm92aWRlciI6ImdpdGh1YiIsInN1YmplY3QiOiJnaXRodWI6MTIzNDU2NzgiLCJlbWFpbCI6ImFkbWluQGV4YW1wbGUuY29tIiwiaWF0IjoxNzUzNDg2OTI0LCJleHAiOjE3NTM0ODcyMjQsImp0aSI6ImFiY2RlZjEyMzQ1Njc4OTAiLCJ0eXBlIjoicGVuZGluZ19pZGVudGl0eSJ9.SIGNATURE",
  "decision": "link"
}
EOF

  _resp "07-auth-collapse" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Set-Cookie: libcloud_portal_sid=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpbnRlcm5hbFVzZXJJZCI6ImludC1hd3MtYWRtaW4iLCJyb2xlIjoiYWRtaW4iLCJlbWFpbCI6ImFkbWluQGV4YW1wbGUuY29tIiwibGlua2VkSWRlbnRpdGllcyI6WyJsbGRhcDpDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiLCJnaXRodWI6MTIzNDU2NzgiXSwic2lkIjoiYjIzYzQ1ZDY3ZTg5ZjAxMiIsImlhdCI6MTc1MzQ4NjkyNSwiZXhwIjoxNzUzNTE1NzI1LCJqdGkiOiJmMTIzNDU2Nzg5MGFiY2RlZiJ9.SIGNATURE; HttpOnly; SameSite=Lax; Path=/; Max-Age=28800
Content-Length: 420
Date: Wed, 23 Jul 2026 14:22:05 GMT

{
  "internalUserId": "int-aws-admin",
  "role": "admin",
  "linkedIdentities": [
    "lldap:CiQgT1JURV9VU0VFOkJMQk9DSw==",
    "github:12345678"
  ],
  "email": "admin@example.com",
  "clouds": [
    {
      "cloud": "aws",
      "canView": true,
      "canProvision": true,
      "canUpdate": true
    },
    {
      "cloud": "nutanix",
      "canView": true,
      "canProvision": false,
      "canUpdate": false
    }
  ]
}
EOF
}

# ---------------------------------------------------------------------------
# STAGE 4: Session Restoration
# ---------------------------------------------------------------------------
gen_08_session_restore() {
  _section "08 — GET /api/session (Browser → Identity Service, page reload)"
  _dir "08-session-restore"

  _req "08-session-restore" << 'EOF'
GET /api/session HTTP/1.1
Host: localhost:8766
Accept: application/json
Cookie: libcloud_portal_sid=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpbnRlcm5hbFVzZXJJZCI6ImludC1hd3MtYWRtaW4iLCJyb2xlIjoiYWRtaW4iLCJlbWFpbCI6ImFkbWluQGV4YW1wbGUuY29tIiwibGlua2VkSWRlbnRpdGllcyI6WyJsbGRhcDpDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiXSwic2lkIjoiYTEyYjM0YzU2ZDdlOGY5MCIsImlhdCI6MTc1MzQ4NjkyMSwiZXhwIjoxNzUzNTE1NzIxLCJqdGkiOiJlMTIzZjQ1Nmc3ODloMDEyIn0.SIGNATURE

(empty body — GET request)
EOF

  _resp "08-session-restore" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 403
Date: Wed, 23 Jul 2026 14:30:15 GMT

{
  "internalUserId": "int-aws-admin",
  "role": "admin",
  "linkedIdentities": [
    "lldap:CiQgT1JURV9VU0VFOkJMQk9DSw=="
  ],
  "email": "aws-admin@libcloud.local",
  "clouds": [
    {
      "cloud": "aws",
      "canView": true,
      "canProvision": true,
      "canUpdate": true
    },
    {
      "cloud": "nutanix",
      "canView": true,
      "canProvision": false,
      "canUpdate": false
    }
  ]
}
EOF
}

# ---------------------------------------------------------------------------
# STAGE 5: Logout
# ---------------------------------------------------------------------------
gen_09_logout_portal() {
  _section "09 — POST /api/logout (Browser → Identity Service)"
  _dir "09-logout-portal"

  _req "09-logout-portal" << 'EOF'
POST /api/logout HTTP/1.1
Host: localhost:8766
Content-Type: application/json
Accept: application/json
Cookie: libcloud_portal_sid=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpbnRlcm5hbFVzZXJJZCI6ImludC1hd3MtYWRtaW4iLCJyb2xlIjoiYWRtaW4iLCJlbWFpbCI6ImFkbWluQGV4YW1wbGUuY29tIiwibGlua2VkSWRlbnRpdGllcyI6WyJsbGRhcDpDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiXSwic2lkIjoiYTEyYjM0YzU2ZDdlOGY5MCIsImlhdCI6MTc1MzQ4NjkyMSwiZXhwIjoxNzUzNTE1NzIxLCJqdGkiOiJlMTIzZjQ1Nmc3ODloMDEyIn0.SIGNATURE
Content-Length: 2

{}
EOF

  _resp "09-logout-portal" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Set-Cookie: libcloud_portal_sid=; Max-Age=0; HttpOnly; SameSite=Lax; Path=/
Content-Length: 22
Date: Wed, 23 Jul 2026 14:45:00 GMT

{
  "logged_out": true
}
EOF
}

gen_10_dex_token_revoke() {
  _section "10 — POST /dex/token/revoke (Identity Service → Dex, RFC 7009)"
  _dir "10-dex-token-revoke"

  _req "10-dex-token-revoke" << 'EOF'
POST /dex/token/revoke HTTP/1.1
Host: dex:5556
Content-Type: application/x-www-form-urlencoded
Accept: application/json
Content-Length: 255

token=ChlDZXgtcmVmcmVzaC10b2tlbi1leGFtcGxlLTEyMzQ1Njc4OTBhYmNkZWY&
token_type_hint=refresh_token&
client_id=libcloud-portal&
client_secret=ZXhhbXBsZS1wb3J0YWwtc2VjcmV0LWtleS0xMjM0NTY3OA
EOF

  _resp "10-dex-token-revoke" << 'EOF'
HTTP/1.1 200 OK
Cache-Control: no-store
Pragma: no-cache
Content-Length: 0
Date: Wed, 23 Jul 2026 14:45:00 GMT

(empty body — successful revocation)
EOF
}

gen_11_dex_rp_logout() {
  _section "11 — Dex RP-Initiated Logout — NOT AVAILABLE with stock Dex"
  _dir "11-dex-rp-logout"

  _req "11-dex-rp-logout" << 'EOF'
# NOTE: No HTTP request is made here.
#
# Stock Dex (ghcr.io/dexidp/dex:v2.41.1) has NO RP-initiated logout endpoint.
# GET /dex/auth/logout returns 404 "Invalid client_id ("")" because the path
# matches the connector-login route /dex/auth/{connector}, which parses the
# query as an authorization request and requires a client_id. Dex also keeps
# no browser SSO cookie, so there is nothing IdP-side to clear — every
# /dex/auth request re-prompts the connector login form.
#
# Logout therefore ends at step 10 (refresh-token revocation). The portal SPA
# navigates client-side to /login after POST /api/logout returns.
EOF

  _resp "11-dex-rp-logout" << 'EOF'
# No HTTP response — see request.http for why this flow does not exist.
EOF
}

# ---------------------------------------------------------------------------
# STAGE 6a: Provisioner Service-Account Auth (Identity Svc → Dex)
# ---------------------------------------------------------------------------
gen_12_provisioner_dex_authorize() {
  _section "12 — GET /dex/auth (Identity Service → Dex, Provisioner Login Form)"
  _dir "12-provisioner-dex-authorize"

  _req "12-provisioner-dex-authorize" << 'EOF'
GET /dex/auth?client_id=libcloud-rest&redirect_uri=http%3A%2F%2F127.0.0.1%3A8766%2Foauth%2Fcallback&response_type=code&scope=openid+email+profile&state=libcloud-dex&connector_id=lldap HTTP/1.1
Host: dex:5556
Accept: text/html,application/xhtml+xml
User-Agent: python-httpx/0.27.0

(empty body — GET request, follows redirects to LDAP login form)
EOF

  _resp "12-provisioner-dex-authorize" << 'EOF'
HTTP/1.1 200 OK
Content-Type: text/html; charset=utf-8
Set-Cookie: dex_session=eyJhbGciOiJIUzI1NiJ9.provisioner-session; Path=/; HttpOnly; SameSite=Lax
Content-Length: 2847
Date: Wed, 23 Jul 2026 14:22:10 GMT

<!DOCTYPE html>
<html lang="en">
<head><title>Dex — Log In</title></head>
<body>
  <div class="theme-panel">
    <h2>Log in to Your Account</h2>
    <form method="post" action="/dex/auth/local?req=cnm6k4qj2p7w9b5d">
      <div class="theme-form-row">
        <label for="login">Email Address</label>
        <input type="text" id="login" name="login" autofocus />
      </div>
      <div class="theme-form-row">
        <label for="password">Password</label>
        <input type="password" id="password" name="password" />
      </div>
      <button type="submit" class="theme-btn--primary">Login</button>
    </form>
  </div>
</body>
</html>
EOF
}

gen_13_provisioner_dex_login() {
  _section "13 — POST /dex/auth/local (Identity Service → Dex, Submit Credentials)"
  _dir "13-provisioner-dex-login"

  _req "13-provisioner-dex-login" << 'EOF'
POST /dex/auth/local?req=cnm6k4qj2p7w9b5d HTTP/1.1
Host: dex:5556
Content-Type: application/x-www-form-urlencoded
Accept: text/html,application/xhtml+xml
User-Agent: python-httpx/0.27.0
Content-Length: 62

login=aws-admin&password=EXAMPLE_AWS_ADMIN_PASSWORD_12345678
EOF

  _resp "13-provisioner-dex-login" << 'EOF'
HTTP/1.1 302 Found
Location: http://127.0.0.1:8766/oauth/callback?code=dex-prov-abc123xyz789&state=libcloud-dex
Set-Cookie: dex_session=eyJhbGciOiJIUzI1NiJ9.authenticated-session; Path=/; HttpOnly; SameSite=Lax
Date: Wed, 23 Jul 2026 14:22:11 GMT

(empty body — 302 redirect; Identity Service captures `code` from Location header, does NOT follow)
EOF
}

gen_14_provisioner_dex_token() {
  _section "14 — POST /dex/token (Identity Service → Dex, Provisioner Token Exchange)"
  _dir "14-provisioner-dex-token"

  _req "14-provisioner-dex-token" << 'EOF'
POST /dex/token HTTP/1.1
Host: dex:5556
Content-Type: application/x-www-form-urlencoded
Accept: application/json
Content-Length: 343

grant_type=authorization_code&
code=dex-prov-abc123xyz789&
redirect_uri=http%3A%2F%2F127.0.0.1%3A8766%2Foauth%2Fcallback&
client_id=libcloud-rest&
client_secret=ZXhhbXBsZS1saWJjbG91ZC1yZXN0LXNlY3JldC0xMjM0NTY3ODkwYWJjZGVm
EOF

  _resp "14-provisioner-dex-token" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Cache-Control: no-store
Pragma: no-cache
Content-Length: 1183
Date: Wed, 23 Jul 2026 14:22:11 GMT

{
  "access_token": "eyJhbGciOiJSUzI1NiIsImtpZCI6IjExMjIzMzQ0NTU2Njc3ODg5OSJ9.eyJpc3MiOiJodHRwOi8vbG9naW4ucXVlc3Q0c2NpZW5jZS54eXo6NTU1Ni9kZXgiLCJzdWIiOiJDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiLCJhdWQiOiJsaWJjbG91ZC1yZXN0IiwiZXhwIjoxNzUzNDkwNTMxLCJpYXQiOjE3NTM0ODY5MzEsImVtYWlsIjoiYXdzLWFkbWluQGxpYmNsb3VkLmxvY2FsIiwibmFtZSI6IkFXUyBBZG1pbiJ9.PROVISIONER_SIGNATURE",
  "token_type": "bearer",
  "expires_in": 3600,
  "refresh_token": "ChlEZXgtcHJvdmlzaW9uZXItcmVmcmVzaC10b2tlbi0xMjM0NTY3ODkw"
}
EOF
}

gen_14b_provisioner_token_refresh() {
  _section "14b — POST /dex/token (Identity Service → Dex, Refresh Provisioner Token)"
  _dir "14b-provisioner-token-refresh"

  _req "14b-provisioner-token-refresh" << 'EOF'
POST /dex/token HTTP/1.1
Host: dex:5556
Content-Type: application/x-www-form-urlencoded
Accept: application/json
Content-Length: 278

grant_type=refresh_token&
refresh_token=ChlEZXgtcHJvdmlzaW9uZXItcmVmcmVzaC10b2tlbi0xMjM0NTY3ODkw&
client_id=libcloud-rest&
client_secret=ZXhhbXBsZS1saWJjbG91ZC1yZXN0LXNlY3JldC0xMjM0NTY3ODkwYWJjZGVm
EOF

  _resp "14b-provisioner-token-refresh" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Cache-Control: no-store
Pragma: no-cache
Content-Length: 1194
Date: Wed, 23 Jul 2026 15:22:11 GMT

{
  "access_token": "eyJhbGciOiJSUzI1NiIsImtpZCI6IjExMjIzMzQ0NTU2Njc3ODg5OSJ9.eyJpc3MiOiJodHRwOi8vbG9naW4ucXVlc3Q0c2NpZW5jZS54eXo6NTU1Ni9kZXgiLCJzdWIiOiJDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiLCJhdWQiOiJsaWJjbG91ZC1yZXN0IiwiZXhwIjoxNzUzNDk0MTMxLCJpYXQiOjE3NTM0OTA1MzEsImVtYWlsIjoiYXdzLWFkbWluQGxpYmNsb3VkLmxvY2FsIiwibmFtZSI6IkFXUyBBZG1pbiJ9.REFRESHED_SIGNATURE",
  "token_type": "bearer",
  "expires_in": 3600,
  "refresh_token": "ChlEZXgtcHJvdmlzaW9uZXItcmVmcmVzaC10b2tlbi12Mi0xMjM0NTY3ODkw"
}
EOF
}

# ---------------------------------------------------------------------------
# STAGE 6c: OpenFGA Requests (Identity Service → OpenFGA)
# ---------------------------------------------------------------------------
gen_15_openfga_read() {
  _section "15 — POST /stores/{id}/read (Identity Service → OpenFGA, List Tuples)"
  _dir "15-openfga-read"

  _req "15-openfga-read" << 'EOF'
POST /stores/01J5K7M9P2R4V6W8/stores/01J5K7M9P2R4V6W8/read HTTP/1.1
Host: openfga:8081
Content-Type: application/json
Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6IjExMjIzMzQ0NTU2Njc3ODg5OSJ9.eyJpc3MiOiJodHRwOi8vbG9naW4ucXVlc3Q0c2NpZW5jZS54eXo6NTU1Ni9kZXgiLCJzdWIiOiJDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiLCJhdWQiOiJsaWJjbG91ZC1yZXN0IiwiZXhwIjoxNzUzNDkwNTMxLCJpYXQiOjE3NTM0ODY5MzEsImVtYWlsIjoiYXdzLWFkbWluQGxpYmNsb3VkLmxvY2FsIiwibmFtZSI6IkFXUyBBZG1pbiJ9.PROVISIONER_SIGNATURE
Accept: application/json
Content-Length: 97

{
  "page_size": 100
}
EOF

  _resp "15-openfga-read" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 1423
Date: Wed, 23 Jul 2026 14:22:12 GMT

{
  "tuples": [
    {
      "key": {
        "user": "user:superadmin",
        "relation": "superadmin",
        "object": "platform:main"
      }
    },
    {
      "key": {
        "user": "user:aws-admin",
        "relation": "admin",
        "object": "tenant:aws"
      }
    },
    {
      "key": {
        "user": "user:ntnx-owner",
        "relation": "owner",
        "object": "tenant:nutanix"
      }
    },
    {
      "key": {
        "user": "user:aws-viewer",
        "relation": "viewer",
        "object": "tenant:aws"
      }
    },
    {
      "key": {
        "user": "user:superadmin",
        "relation": "can_read",
        "object": "aws_region:aws"
      }
    },
    {
      "key": {
        "user": "user:superadmin",
        "relation": "can_read",
        "object": "nutanix_cluster:nutanix"
      }
    },
    {
      "key": {
        "user": "user:aws-admin",
        "relation": "can_provision",
        "object": "aws_region:aws"
      }
    },
    {
      "key": {
        "user": "user:aws-admin",
        "relation": "can_update",
        "object": "aws_region:aws"
      }
    }
  ],
  "continuation_token": ""
}
EOF
}

gen_16_openfga_check() {
  _section "16 — POST /stores/{id}/check (Identity Service → OpenFGA, AuthZ Check)"
  _dir "16-openfga-check"

  _req "16-openfga-check" << 'EOF'
POST /stores/01J5K7M9P2R4V6W8/check HTTP/1.1
Host: openfga:8081
Content-Type: application/json
Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6IjExMjIzMzQ0NTU2Njc3ODg5OSJ9.eyJpc3MiOiJodHRwOi8vbG9naW4ucXVlc3Q0c2NpZW5jZS54eXo6NTU1Ni9kZXgiLCJzdWIiOiJDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiLCJhdWQiOiJsaWJjbG91ZC1yZXN0IiwiZXhwIjoxNzUzNDkwNTMxLCJpYXQiOjE3NTM0ODY5MzEsImVtYWlsIjoiYXdzLWFkbWluQGxpYmNsb3VkLmxvY2FsIiwibmFtZSI6IkFXUyBBZG1pbiJ9.PROVISIONER_SIGNATURE
Accept: application/json
Content-Length: 190

{
  "authorization_model_id": "01J5K7M9P2R4V6W8",
  "tuple_key": {
    "user": "user:aws-admin",
    "relation": "can_provision",
    "object": "aws_region:aws"
  }
}
EOF

  _resp "16-openfga-check" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 38
Date: Wed, 23 Jul 2026 14:22:12 GMT

{
  "allowed": true
}
EOF
}

gen_17_openfga_write() {
  _section "17 — POST /stores/{id}/write (Identity Service → OpenFGA, Write Tuples)"
  _dir "17-openfga-write"

  _req "17-openfga-write" << 'EOF'
POST /stores/01J5K7M9P2R4V6W8/write HTTP/1.1
Host: openfga:8081
Content-Type: application/json
Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6IjExMjIzMzQ0NTU2Njc3ODg5OSJ9.eyJpc3MiOiJodHRwOi8vbG9naW4ucXVlc3Q0c2NpZW5jZS54eXo6NTU1Ni9kZXgiLCJzdWIiOiJDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiLCJhdWQiOiJsaWJjbG91ZC1yZXN0IiwiZXhwIjoxNzUzNDkwNTMxLCJpYXQiOjE3NTM0ODY5MzEsImVtYWlsIjoiYXdzLWFkbWluQGxpYmNsb3VkLmxvY2FsIiwibmFtZSI6IkFXUyBBZG1pbiJ9.PROVISIONER_SIGNATURE
Accept: application/json
Content-Length: 233

{
  "authorization_model_id": "01J5K7M9P2R4V6W8",
  "writes": {
    "tuple_keys": [
      {
        "user": "user:int-pending-a1b2c3d4",
        "relation": "viewer",
        "object": "tenant:aws"
      }
    ]
  }
}
EOF

  _resp "17-openfga-write" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 2
Date: Wed, 23 Jul 2026 14:22:12 GMT

{}
EOF
}

# ---------------------------------------------------------------------------
# STAGE 6d: libcloud REST API Requests (Identity Service → REST API :8765)
# ---------------------------------------------------------------------------
gen_18_rest_auth_me() {
  _section "18 — POST /v1/auth/me (Identity Service → libcloud REST, Token Validation)"
  _dir "18-rest-auth-me"

  _req "18-rest-auth-me" << 'EOF'
POST /v1/auth/me HTTP/1.1
Host: libcloud-rest-api:8765
Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6IjExMjIzMzQ0NTU2Njc3ODg5OSJ9.eyJpc3MiOiJodHRwOi8vbG9naW4ucXVlc3Q0c2NpZW5jZS54eXo6NTU1Ni9kZXgiLCJzdWIiOiJDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiLCJhdWQiOiJsaWJjbG91ZC1yZXN0IiwiZXhwIjoxNzUzNDkwNTMxLCJpYXQiOjE3NTM0ODY5MzEsImVtYWlsIjoiYXdzLWFkbWluQGxpYmNsb3VkLmxvY2FsIiwibmFtZSI6IkFXUyBBZG1pbiJ9.PROVISIONER_SIGNATURE
Accept: application/json
Content-Length: 0

(empty body)
EOF

  _resp "18-rest-auth-me" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 387
Date: Wed, 23 Jul 2026 14:22:12 GMT

{
  "sub": "CiQgT1JURV9VU0VFOkJMQk9DSw==",
  "principal": "aws-admin",
  "email": "aws-admin@libcloud.local",
  "name": "AWS Admin",
  "scopes": [
    "compute:read",
    "compute:node:create",
    "compute:node:delete",
    "compute:node:update",
    "compute:image:read",
    "compute:size:read",
    "compute:location:read",
    "compute:network:read"
  ],
  "allowed_providers": ["aws"],
  "iss": "http://login.quest4science.xyz:5556/dex",
  "aud": "libcloud-rest"
}
EOF
}

gen_19_rest_connection_test() {
  _section "19 — POST /v1/connections:test (Identity Service → libcloud REST, Connection Test)"
  _dir "19-rest-connection-test"

  _req "19-rest-connection-test" << 'EOF'
POST /v1/connections:test HTTP/1.1
Host: libcloud-rest-api:8765
Content-Type: application/json
Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6IjExMjIzMzQ0NTU2Njc3ODg5OSJ9.eyJpc3MiOiJodHRwOi8vbG9naW4ucXVlc3Q0c2NpZW5jZS54eXo6NTU1Ni9kZXgiLCJzdWIiOiJDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiLCJhdWQiOiJsaWJjbG91ZC1yZXN0IiwiZXhwIjoxNzUzNDkwNTMxLCJpYXQiOjE3NTM0ODY5MzEsImVtYWlsIjoiYXdzLWFkbWluQGxpYmNsb3VkLmxvY2FsIiwibmFtZSI6IkFXUyBBZG1pbiJ9.PROVISIONER_SIGNATURE
X-Provider-Connection: {"provider":"aws","config":{"region":"ap-southeast-1","secure":true},"auth_binding":"aws"}
Accept: application/json
Content-Length: 93

{
  "provider": "aws",
  "config": {
    "region": "ap-southeast-1",
    "secure": true
  },
  "auth_binding": "aws"
}
EOF

  _resp "19-rest-connection-test" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 143
Date: Wed, 23 Jul 2026 14:22:13 GMT

{
  "connected": true,
  "provider": "aws",
  "region": "ap-southeast-1",
  "message": "Successfully connected to AWS ap-southeast-1"
}
EOF
}

gen_20_rest_list_locations() {
  _section "20 — GET /v1/compute/locations (Identity Service → libcloud REST)"
  _dir "20-rest-list-locations"

  _req "20-rest-list-locations" << 'EOF'
GET /v1/compute/locations HTTP/1.1
Host: libcloud-rest-api:8765
Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6IjExMjIzMzQ0NTU2Njc3ODg5OSJ9.eyJpc3MiOiJodHRwOi8vbG9naW4ucXVlc3Q0c2NpZW5jZS54eXo6NTU1Ni9kZXgiLCJzdWIiOiJDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiLCJhdWQiOiJsaWJjbG91ZC1yZXN0IiwiZXhwIjoxNzUzNDkwNTMxLCJpYXQiOjE3NTM0ODY5MzEsImVtYWlsIjoiYXdzLWFkbWluQGxpYmNsb3VkLmxvY2FsIiwibmFtZSI6IkFXUyBBZG1pbiJ9.PROVISIONER_SIGNATURE
X-Provider-Connection: {"provider":"aws","config":{"region":"ap-southeast-1","secure":true},"auth_binding":"aws"}
Accept: application/json

(empty body — GET request)
EOF

  _resp "20-rest-list-locations" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 356
Date: Wed, 23 Jul 2026 14:22:13 GMT

{
  "data": [
    {
      "id": "ap-southeast-1a",
      "name": "ap-southeast-1a",
      "country": "Singapore",
      "available": true
    },
    {
      "id": "ap-southeast-1b",
      "name": "ap-southeast-1b",
      "country": "Singapore",
      "available": true
    },
    {
      "id": "ap-southeast-1c",
      "name": "ap-southeast-1c",
      "country": "Singapore",
      "available": true
    }
  ]
}
EOF
}

gen_21_rest_list_sizes() {
  _section "21 — GET /v1/compute/sizes (Identity Service → libcloud REST, Instance Types)"
  _dir "21-rest-list-sizes"

  _req "21-rest-list-sizes" << 'EOF'
GET /v1/compute/sizes HTTP/1.1
Host: libcloud-rest-api:8765
Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6IjExMjIzMzQ0NTU2Njc3ODg5OSJ9.eyJpc3MiOiJodHRwOi8vbG9naW4ucXVlc3Q0c2NpZW5jZS54eXo6NTU1Ni9kZXgiLCJzdWIiOiJDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiLCJhdWQiOiJsaWJjbG91ZC1yZXN0IiwiZXhwIjoxNzUzNDkwNTMxLCJpYXQiOjE3NTM0ODY5MzEsImVtYWlsIjoiYXdzLWFkbWluQGxpYmNsb3VkLmxvY2FsIiwibmFtZSI6IkFXUyBBZG1pbiJ9.PROVISIONER_SIGNATURE
X-Provider-Connection: {"provider":"aws","config":{"region":"ap-southeast-1","secure":true},"auth_binding":"aws"}
Accept: application/json

(empty body — GET request)
EOF

  _resp "21-rest-list-sizes" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 823
Date: Wed, 23 Jul 2026 14:22:13 GMT

{
  "data": [
    {
      "id": "t2.micro",
      "name": "t2.micro",
      "ram": 1024,
      "disk": 0,
      "bandwidth": 0,
      "price": "0.0116",
      "extra": {
        "vcpu": 1,
        "architecture": "x86_64"
      }
    },
    {
      "id": "t2.small",
      "name": "t2.small",
      "ram": 2048,
      "disk": 0,
      "bandwidth": 0,
      "price": "0.023",
      "extra": {
        "vcpu": 1,
        "architecture": "x86_64"
      }
    },
    {
      "id": "t3.medium",
      "name": "t3.medium",
      "ram": 4096,
      "disk": 0,
      "bandwidth": 0,
      "price": "0.0416",
      "extra": {
        "vcpu": 2,
        "architecture": "x86_64"
      }
    }
  ]
}
EOF
}

gen_22_rest_list_images() {
  _section "22 — GET /v1/compute/images (Identity Service → libcloud REST)"
  _dir "22-rest-list-images"

  _req "22-rest-list-images" << 'EOF'
GET /v1/compute/images?name=*ubuntu* HTTP/1.1
Host: libcloud-rest-api:8765
Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6IjExMjIzMzQ0NTU2Njc3ODg5OSJ9.eyJpc3MiOiJodHRwOi8vbG9naW4ucXVlc3Q0c2NpZW5jZS54eXo6NTU1Ni9kZXgiLCJzdWIiOiJDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiLCJhdWQiOiJsaWJjbG91ZC1yZXN0IiwiZXhwIjoxNzUzNDkwNTMxLCJpYXQiOjE3NTM0ODY5MzEsImVtYWlsIjoiYXdzLWFkbWluQGxpYmNsb3VkLmxvY2FsIiwibmFtZSI6IkFXUyBBZG1pbiJ9.PROVISIONER_SIGNATURE
X-Provider-Connection: {"provider":"aws","config":{"region":"ap-southeast-1","secure":true},"auth_binding":"aws"}
Accept: application/json

(empty body — GET request)
EOF

  _resp "22-rest-list-images" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 528
Date: Wed, 23 Jul 2026 14:22:13 GMT

{
  "data": [
    {
      "id": "ami-0df99b4a3c16e8f7a",
      "name": "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-20260701",
      "extra": {
        "architecture": "x86_64",
        "owner_id": "099720109477",
        "state": "available",
        "root_device_type": "ebs",
        "virtualization_type": "hvm"
      }
    },
    {
      "id": "ami-0a1b2c3d4e5f6g7h8",
      "name": "ubuntu/images/hvm-ssd/ubuntu-noble-24.04-amd64-server-20260715",
      "extra": {
        "architecture": "x86_64",
        "owner_id": "099720109477",
        "state": "available",
        "root_device_type": "ebs",
        "virtualization_type": "hvm"
      }
    }
  ]
}
EOF
}

gen_23_rest_list_subnets() {
  _section "23 — GET /v1/compute/subnets (Identity Service → libcloud REST)"
  _dir "23-rest-list-subnets"

  _req "23-rest-list-subnets" << 'EOF'
GET /v1/compute/subnets HTTP/1.1
Host: libcloud-rest-api:8765
Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6IjExMjIzMzQ0NTU2Njc3ODg5OSJ9.eyJpc3MiOiJodHRwOi8vbG9naW4ucXVlc3Q0c2NpZW5jZS54eXo6NTU1Ni9kZXgiLCJzdWIiOiJDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiLCJhdWQiOiJsaWJjbG91ZC1yZXN0IiwiZXhwIjoxNzUzNDkwNTMxLCJpYXQiOjE3NTM0ODY5MzEsImVtYWlsIjoiYXdzLWFkbWluQGxpYmNsb3VkLmxvY2FsIiwibmFtZSI6IkFXUyBBZG1pbiJ9.PROVISIONER_SIGNATURE
X-Provider-Connection: {"provider":"aws","config":{"region":"ap-southeast-1","secure":true},"auth_binding":"aws"}
Accept: application/json

(empty body — GET request)
EOF

  _resp "23-rest-list-subnets" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 314
Date: Wed, 23 Jul 2026 14:22:14 GMT

{
  "data": [
    {
      "id": "subnet-0a1b2c3d4e5f6g7h8",
      "name": "default-ap-southeast-1a",
      "cidr_block": "172.31.0.0/20",
      "availability_zone": "ap-southeast-1a",
      "state": "available",
      "vpc_id": "vpc-0a1b2c3d4e5f6g7h8"
    }
  ]
}
EOF
}

gen_24_rest_list_nodes() {
  _section "24 — GET /v1/compute/nodes (Identity Service → libcloud REST, List VMs)"
  _dir "24-rest-list-nodes"

  _req "24-rest-list-nodes" << 'EOF'
GET /v1/compute/nodes HTTP/1.1
Host: libcloud-rest-api:8765
Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6IjExMjIzMzQ0NTU2Njc3ODg5OSJ9.eyJpc3MiOiJodHRwOi8vbG9naW4ucXVlc3Q0c2NpZW5jZS54eXo6NTU1Ni9kZXgiLCJzdWIiOiJDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiLCJhdWQiOiJsaWJjbG91ZC1yZXN0IiwiZXhwIjoxNzUzNDkwNTMxLCJpYXQiOjE3NTM0ODY5MzEsImVtYWlsIjoiYXdzLWFkbWluQGxpYmNsb3VkLmxvY2FsIiwibmFtZSI6IkFXUyBBZG1pbiJ9.PROVISIONER_SIGNATURE
X-Provider-Connection: {"provider":"aws","config":{"region":"ap-southeast-1","secure":true},"auth_binding":"aws"}
Accept: application/json

(empty body — GET request)
EOF

  _resp "24-rest-list-nodes" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 674
Date: Wed, 23 Jul 2026 14:22:14 GMT

{
  "data": [
    {
      "id": "i-0a1b2c3d4e5f6g7h8",
      "name": "libcloud-demo-1753486800",
      "state": "running",
      "size": "t2.micro",
      "public_ips": ["13.228.145.89"],
      "private_ips": ["172.31.16.42"],
      "created_at": "2026-07-21T10:15:00Z",
      "image": "ami-0df99b4a3c16e8f7a",
      "extra": {
        "instance_type": "t2.micro",
        "availability_zone": "ap-southeast-1a",
        "vpc_id": "vpc-0a1b2c3d4e5f6g7h8",
        "subnet_id": "subnet-0a1b2c3d4e5f6g7h8"
      }
    }
  ]
}
EOF
}

gen_25_rest_create_node() {
  _section "25 — POST /v1/compute/nodes (Identity Service → libcloud REST, Create VM)"
  _dir "25-rest-create-node"

  _req "25-rest-create-node" << 'EOF'
POST /v1/compute/nodes HTTP/1.1
Host: libcloud-rest-api:8765
Content-Type: application/json
Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6IjExMjIzMzQ0NTU2Njc3ODg5OSJ9.eyJpc3MiOiJodHRwOi8vbG9naW4ucXVlc3Q0c2NpZW5jZS54eXo6NTU1Ni9kZXgiLCJzdWIiOiJDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiLCJhdWQiOiJsaWJjbG91ZC1yZXN0IiwiZXhwIjoxNzUzNDkwNTMxLCJpYXQiOjE3NTM0ODY5MzEsImVtYWlsIjoiYXdzLWFkbWluQGxpYmNsb3VkLmxvY2FsIiwibmFtZSI6IkFXUyBBZG1pbiJ9.PROVISIONER_SIGNATURE
X-Provider-Connection: {"provider":"aws","config":{"region":"ap-southeast-1","secure":true},"auth_binding":"aws"}
Accept: application/json
Content-Length: 287

{
  "name": "libcloud-demo-1753486931",
  "size": {
    "id": "t2.micro"
  },
  "image": {
    "id": "ami-0df99b4a3c16e8f7a"
  },
  "network": {
    "public_ip": true,
    "subnet_id": "subnet-0a1b2c3d4e5f6g7h8"
  },
  "provider_options": {}
}
EOF

  _resp "25-rest-create-node" << 'EOF'
HTTP/1.1 201 Created
Content-Type: application/json
Content-Length: 457
Date: Wed, 23 Jul 2026 14:22:18 GMT

{
  "data": {
    "id": "i-0b2c3d4e5f6g7h8i9",
    "name": "libcloud-demo-1753486931",
    "state": "pending",
    "size": "t2.micro",
    "public_ips": [],
    "private_ips": ["172.31.16.99"],
    "created_at": "2026-07-23T14:22:18Z",
    "image": "ami-0df99b4a3c16e8f7a",
    "extra": {
      "instance_type": "t2.micro",
      "availability_zone": "ap-southeast-1a",
      "vpc_id": "vpc-0a1b2c3d4e5f6g7h8",
      "subnet_id": "subnet-0a1b2c3d4e5f6g7h8",
      "launch_time": "2026-07-23T14:22:18Z"
    }
  }
}
EOF
}

gen_26_rest_update_node() {
  _section "26 — PATCH /v1/compute/nodes/{id} (Identity Service → libcloud REST, Update VM)"
  _dir "26-rest-update-node"

  _req "26-rest-update-node" << 'EOF'
PATCH /v1/compute/nodes/i-0a1b2c3d4e5f6g7h8 HTTP/1.1
Host: libcloud-rest-api:8765
Content-Type: application/json
Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6IjExMjIzMzQ0NTU2Njc3ODg5OSJ9.eyJpc3MiOiJodHRwOi8vbG9naW4ucXVlc3Q0c2NpZW5jZS54eXo6NTU1Ni9kZXgiLCJzdWIiOiJDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiLCJhdWQiOiJsaWJjbG91ZC1yZXN0IiwiZXhwIjoxNzUzNDkwNTMxLCJpYXQiOjE3NTM0ODY5MzEsImVtYWlsIjoiYXdzLWFkbWluQGxpYmNsb3VkLmxvY2FsIiwibmFtZSI6IkFXUyBBZG1pbiJ9.PROVISIONER_SIGNATURE
X-Provider-Connection: {"provider":"aws","config":{"region":"ap-southeast-1","secure":true},"auth_binding":"aws"}
Accept: application/json
Content-Length: 160

{
  "action": "update",
  "name": "libcloud-demo-renamed",
  "new_size_id": "t2.small",
  "tag_key": "Environment",
  "tag_value": "staging"
}
EOF

  _resp "26-rest-update-node" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 443
Date: Wed, 23 Jul 2026 14:22:19 GMT

{
  "data": {
    "id": "i-0a1b2c3d4e5f6g7h8",
    "name": "libcloud-demo-renamed",
    "state": "running",
    "size": "t2.small",
    "public_ips": ["13.228.145.89"],
    "private_ips": ["172.31.16.42"],
    "created_at": "2026-07-21T10:15:00Z",
    "extra": {
      "instance_type": "t2.small",
      "availability_zone": "ap-southeast-1a",
      "tags": {
        "Environment": "staging"
      }
    }
  }
}
EOF
}

gen_27_rest_delete_node() {
  _section "27 — DELETE /v1/compute/nodes/{id} (Identity Service → libcloud REST, Delete VM)"
  _dir "27-rest-delete-node"

  _req "27-rest-delete-node" << 'EOF'
DELETE /v1/compute/nodes/i-0a1b2c3d4e5f6g7h8 HTTP/1.1
Host: libcloud-rest-api:8765
Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6IjExMjIzMzQ0NTU2Njc3ODg5OSJ9.eyJpc3MiOiJodHRwOi8vbG9naW4ucXVlc3Q0c2NpZW5jZS54eXo6NTU1Ni9kZXgiLCJzdWIiOiJDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiLCJhdWQiOiJsaWJjbG91ZC1yZXN0IiwiZXhwIjoxNzUzNDkwNTMxLCJpYXQiOjE3NTM0ODY5MzEsImVtYWlsIjoiYXdzLWFkbWluQGxpYmNsb3VkLmxvY2FsIiwibmFtZSI6IkFXUyBBZG1pbiJ9.PROVISIONER_SIGNATURE
X-Provider-Connection: {"provider":"aws","config":{"region":"ap-southeast-1","secure":true},"auth_binding":"aws"}
Accept: application/json

(empty body — DELETE request)
EOF

  _resp "27-rest-delete-node" << 'EOF'
HTTP/1.1 204 No Content
Content-Length: 0
Date: Wed, 23 Jul 2026 14:22:45 GMT

(empty body — successful deletion)
EOF
}

# ---------------------------------------------------------------------------
# STAGE 6b: Portal Cloud Operation Endpoints (Browser → Identity Service)
# ---------------------------------------------------------------------------
gen_28_portal_list_resources() {
  _section "28 — GET /api/resources/{cloud} (Browser → Identity Service, List Resources)"
  _dir "28-portal-list-resources"

  _req "28-portal-list-resources" << 'EOF'
GET /api/resources/aws HTTP/1.1
Host: localhost:8766
Accept: application/json
Cookie: libcloud_portal_sid=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpbnRlcm5hbFVzZXJJZCI6ImludC1hd3MtYWRtaW4iLCJyb2xlIjoiYWRtaW4iLCJlbWFpbCI6ImFkbWluQGV4YW1wbGUuY29tIiwibGlua2VkSWRlbnRpdGllcyI6WyJsbGRhcDpDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiXSwic2lkIjoiYTEyYjM0YzU2ZDdlOGY5MCIsImlhdCI6MTc1MzQ4NjkyMSwiZXhwIjoxNzUzNTE1NzIxLCJqdGkiOiJlMTIzZjQ1Nmc3ODloMDEyIn0.SIGNATURE

(empty body — GET request)
EOF

  _resp "28-portal-list-resources" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 458
Date: Wed, 23 Jul 2026 14:25:00 GMT

{
  "region": "ap-southeast-1",
  "nodes": [
    {
      "id": "i-0a1b2c3d4e5f6g7h8",
      "name": "libcloud-demo-1753486800",
      "state": "running",
      "size": "t2.micro"
    },
    {
      "id": "i-0b2c3d4e5f6g7h8i9",
      "name": "libcloud-demo-1753486931",
      "state": "pending",
      "size": "t2.micro"
    }
  ]
}
EOF
}

gen_29_portal_provision() {
  _section "29 — POST /api/provision/{cloud} (Browser → Identity Service, Provision VM)"
  _dir "29-portal-provision"

  _req "29-portal-provision" << 'EOF'
POST /api/provision/aws HTTP/1.1
Host: localhost:8766
Content-Type: application/json
Accept: application/json
Cookie: libcloud_portal_sid=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpbnRlcm5hbFVzZXJJZCI6ImludC1hd3MtYWRtaW4iLCJyb2xlIjoiYWRtaW4iLCJlbWFpbCI6ImFkbWluQGV4YW1wbGUuY29tIiwibGlua2VkSWRlbnRpdGllcyI6WyJsbGRhcDpDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiXSwic2lkIjoiYTEyYjM0YzU2ZDdlOGY5MCIsImlhdCI6MTc1MzQ4NjkyMSwiZXhwIjoxNzUzNTE1NzIxLCJqdGkiOiJlMTIzZjQ1Nmc3ODloMDEyIn0.SIGNATURE
Content-Length: 72

{
  "vmName": "my-test-vm"
}
EOF

  _resp "29-portal-provision" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 821
Date: Wed, 23 Jul 2026 14:25:05 GMT

{
  "provider": "aws",
  "vmName": "my-test-vm",
  "status": "provisioned",
  "message": "Provisioned via libcloud REST replay of provision_aws.sh",
  "steps": [
    "idp_login (Dex -> OIDC token, audience libcloud-rest)",
    "build_aws_connection_param (auth_binding=aws, NO creds in client)",
    "POST /v1/auth/me -> 200 OK",
    "POST /v1/connections:test -> 200 OK",
    "GET /v1/compute/locations -> 200 OK",
    "GET /v1/compute/sizes -> 200 OK",
    "GET /v1/compute/images -> 200 OK",
    "GET /v1/compute/subnets -> 200 OK",
    "GET /v1/compute/nodes -> 200 OK",
    "resolve IMAGE_ID=ami-0df99b4a3c16e8f7a SIZE_ID=t2.micro SUBNET_ID=subnet-0a1b2c3d4e5f6g7h8 (arch=x86_64)",
    "POST /v1/compute/nodes -> 201 OK"
  ],
  "node": {
    "id": "i-0b2c3d4e5f6g7h8i9",
    "name": "my-test-vm",
    "state": "pending",
    "size": "t2.micro"
  }
}
EOF
}

gen_30_portal_deprovision() {
  _section "30 — POST /api/deprovision/{cloud} (Browser → Identity Service, Deprovision VM)"
  _dir "30-portal-deprovision"

  _req "30-portal-deprovision" << 'EOF'
POST /api/deprovision/aws HTTP/1.1
Host: localhost:8766
Content-Type: application/json
Accept: application/json
Cookie: libcloud_portal_sid=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpbnRlcm5hbFVzZXJJZCI6ImludC1hd3MtYWRtaW4iLCJyb2xlIjoiYWRtaW4iLCJlbWFpbCI6ImFkbWluQGV4YW1wbGUuY29tIiwibGlua2VkSWRlbnRpdGllcyI6WyJsbGRhcDpDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiXSwic2lkIjoiYTEyYjM0YzU2ZDdlOGY5MCIsImlhdCI6MTc1MzQ4NjkyMSwiZXhwIjoxNzUzNTE1NzIxLCJqdGkiOiJlMTIzZjQ1Nmc3ODloMDEyIn0.SIGNATURE
Content-Length: 75

{
  "vmId": "i-0a1b2c3d4e5f6g7h8",
  "vmName": "libcloud-demo-1753486800"
}
EOF

  _resp "30-portal-deprovision" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 512
Date: Wed, 23 Jul 2026 14:30:00 GMT

{
  "provider": "aws",
  "vmId": "i-0a1b2c3d4e5f6g7h8",
  "vmName": "libcloud-demo-1753486800",
  "status": "deprovisioned",
  "message": "deprovision_aws.sh exit=0",
  "exitCode": 0,
  "stdout": "[+] Acquiring libcloud-rest token via Dex LDAP login...\n[+] OpenFGA can_provision check: ALLOWED\n[+] DELETE /v1/compute/nodes/i-0a1b2c3d4e5f6g7h8 -> 204\n[+] VM i-0a1b2c3d4e5f6g7h8 deprovisioned successfully.",
  "stderr": ""
}
EOF
}

gen_31_portal_update() {
  _section "31 — POST /api/update/{cloud} (Browser → Identity Service, Update VM)"
  _dir "31-portal-update"

  _req "31-portal-update" << 'EOF'
POST /api/update/aws HTTP/1.1
Host: localhost:8766
Content-Type: application/json
Accept: application/json
Cookie: libcloud_portal_sid=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpbnRlcm5hbFVzZXJJZCI6ImludC1hd3MtYWRtaW4iLCJyb2xlIjoiYWRtaW4iLCJlbWFpbCI6ImFkbWluQGV4YW1wbGUuY29tIiwibGlua2VkSWRlbnRpdGllcyI6WyJsbGRhcDpDaVFnVDFKVVJWOVVWVkZPSUZKQlRrVlYiXSwic2lkIjoiYTEyYjM0YzU2ZDdlOGY5MCIsImlhdCI6MTc1MzQ4NjkyMSwiZXhwIjoxNzUzNTE1NzIxLCJqdGkiOiJlMTIzZjQ1Nmc3ODloMDEyIn0.SIGNATURE
Content-Length: 139

{
  "vmId": "i-0a1b2c3d4e5f6g7h8",
  "name": "renamed-vm",
  "newSizeId": "t2.small",
  "tagKey": "Environment",
  "tagValue": "production"
}
EOF

  _resp "31-portal-update" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 613
Date: Wed, 23 Jul 2026 14:25:30 GMT

{
  "provider": "aws",
  "vmId": "i-0a1b2c3d4e5f6g7h8",
  "status": "updated",
  "message": "Updated VM i-0a1b2c3d4e5f6g7h8 via libcloud REST PATCH /v1/compute/nodes/i-0a1b2c3d4e5f6g7h8",
  "steps": [
    "idp_login (Dex -> OIDC token, audience libcloud-rest)",
    "POST /v1/auth/me -> 200 OK",
    "PATCH /v1/compute/nodes/i-0a1b2c3d4e5f6g7h8 -> 200 OK"
  ],
  "node": {
    "id": "i-0a1b2c3d4e5f6g7h8",
    "name": "renamed-vm",
    "state": "running",
    "size": "t2.small"
  }
}
EOF
}

# ---------------------------------------------------------------------------
# STAGE 7a: Admin User Management Endpoints
# ---------------------------------------------------------------------------
gen_32_admin_list_users() {
  _section "32 — GET /api/users (Browser → Identity Service, List Users — SuperAdmin)"
  _dir "32-admin-list-users"

  _req "32-admin-list-users" << 'EOF'
GET /api/users HTTP/1.1
Host: localhost:8766
Accept: application/json
Cookie: libcloud_portal_sid=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpbnRlcm5hbFVzZXJJZCI6ImludC1zdXBlcmFkbWluIiwicm9sZSI6InN1cGVyYWRtaW4iLCJlbWFpbCI6InN1cGVyYWRtaW5AbGliY2xvdWQubG9jYWwiLCJsaW5rZWRJZGVudGl0aWVzIjpbImxsZGFwOkNpUWdUMUpVUlc5VVZWRk9JRkpCVGtWViJdLCJzaWQiOiJmZWRjYmE5ODc2NTQzMjEwIiwiaWF0IjoxNzUzNDg2OTIxLCJleHAiOjE3NTM1MTU3MjEsImp0aSI6IjBmMWUyZDNjNGI1YTZkODcifQ.SUPERADMIN_SIGNATURE

(empty body — GET request)
EOF

  _resp "32-admin-list-users" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 923
Date: Wed, 23 Jul 2026 14:26:00 GMT

{
  "users": [
    {
      "internalUserId": "int-superadmin",
      "email": "superadmin@libcloud.local",
      "displayName": "Super Admin",
      "role": "superadmin",
      "linkedIdentities": ["lldap:CiQgT1JURV9VU0VFOkJMQk9DSw=="],
      "createdAt": "2026-07-01T00:00:00Z"
    },
    {
      "internalUserId": "int-aws-admin",
      "email": "aws-admin@libcloud.local",
      "displayName": "AWS Admin",
      "role": "admin",
      "linkedIdentities": ["lldap:CiQgT1JURV9VU0VFOkJMQk9DSw=="],
      "createdAt": "2026-07-01T00:00:00Z"
    },
    {
      "internalUserId": "int-ntnx-owner",
      "email": "ntnx-owner@libcloud.local",
      "displayName": "Nutanix Owner",
      "role": "owner",
      "linkedIdentities": ["lldap:CiQgT1JURV9VU0VFOkJMQk9DSw=="],
      "createdAt": "2026-07-01T00:00:00Z"
    },
    {
      "internalUserId": "int-pending-a1b2c3d4",
      "email": "github-user@example.com",
      "displayName": "github user",
      "role": "pending",
      "linkedIdentities": ["github:12345678"],
      "createdAt": "2026-07-23T14:22:04Z"
    }
  ]
}
EOF
}

gen_33_admin_set_role() {
  _section "33 — PATCH /api/users/{id}/role (Browser → Identity Service, Set User Role)"
  _dir "33-admin-set-role"

  _req "33-admin-set-role" << 'EOF'
PATCH /api/users/int-pending-a1b2c3d4/role HTTP/1.1
Host: localhost:8766
Content-Type: application/json
Accept: application/json
Cookie: libcloud_portal_sid=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpbnRlcm5hbFVzZXJJZCI6ImludC1zdXBlcmFkbWluIiwicm9sZSI6InN1cGVyYWRtaW4iLCJlbWFpbCI6InN1cGVyYWRtaW5AbGliY2xvdWQubG9jYWwiLCJsaW5rZWRJZGVudGl0aWVzIjpbImxsZGFwOkNpUWdUMUpVUlc5VVZWRk9JRkpCVGtWViJdLCJzaWQiOiJmZWRjYmE5ODc2NTQzMjEwIiwiaWF0IjoxNzUzNDg2OTIxLCJleHAiOjE3NTM1MTU3MjEsImp0aSI6IjBmMWUyZDNjNGI1YTZkODcifQ.SUPERADMIN_SIGNATURE
Content-Length: 119

{
  "role": "viewer",
  "tenant": "aws"
}
EOF

  _resp "33-admin-set-role" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 224
Date: Wed, 23 Jul 2026 14:26:30 GMT

{
  "internalUserId": "int-pending-a1b2c3d4",
  "email": "github-user@example.com",
  "displayName": "github user",
  "role": "viewer",
  "linkedIdentities": ["github:12345678"],
  "tenant": "aws"
}
EOF
}

gen_34_admin_set_email() {
  _section "34 — PATCH /api/users/{id}/email (Browser → Identity Service, Set User Email)"
  _dir "34-admin-set-email"

  _req "34-admin-set-email" << 'EOF'
PATCH /api/users/int-aws-admin/email HTTP/1.1
Host: localhost:8766
Content-Type: application/json
Accept: application/json
Cookie: libcloud_portal_sid=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpbnRlcm5hbFVzZXJJZCI6ImludC1zdXBlcmFkbWluIiwicm9sZSI6InN1cGVyYWRtaW4iLCJlbWFpbCI6InN1cGVyYWRtaW5AbGliY2xvdWQubG9jYWwiLCJsaW5rZWRJZGVudGl0aWVzIjpbImxsZGFwOkNpUWdUMUpVUlc5VVZWRk9JRkpCVGtWViJdLCJzaWQiOiJmZWRjYmE5ODc2NTQzMjEwIiwiaWF0IjoxNzUzNDg2OTIxLCJleHAiOjE3NTM1MTU3MjEsImp0aSI6IjBmMWUyZDNjNGI1YTZkODcifQ.SUPERADMIN_SIGNATURE
Content-Length: 60

{
  "email": "new-aws-admin@libcloud.local"
}
EOF

  _resp "34-admin-set-email" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 204
Date: Wed, 23 Jul 2026 14:27:00 GMT

{
  "internalUserId": "int-aws-admin",
  "email": "new-aws-admin@libcloud.local",
  "displayName": "AWS Admin",
  "role": "admin",
  "linkedIdentities": ["lldap:CiQgT1JURV9VU0VFOkJMQk9DSw=="],
  "createdAt": "2026-07-01T00:00:00Z"
}
EOF
}

gen_35_admin_disable_user() {
  _section "35 — POST /api/users/{id}/disable (Browser → Identity Service, Disable User)"
  _dir "35-admin-disable-user"

  _req "35-admin-disable-user" << 'EOF'
POST /api/users/int-aws-admin/disable HTTP/1.1
Host: localhost:8766
Content-Type: application/json
Accept: application/json
Cookie: libcloud_portal_sid=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpbnRlcm5hbFVzZXJJZCI6ImludC1zdXBlcmFkbWluIiwicm9sZSI6InN1cGVyYWRtaW4iLCJlbWFpbCI6InN1cGVyYWRtaW5AbGliY2xvdWQubG9jYWwiLCJsaW5rZWRJZGVudGl0aWVzIjpbImxsZGFwOkNpUWdUMUpVUlc5VVZWRk9JRkpCVGtWViJdLCJzaWQiOiJmZWRjYmE5ODc2NTQzMjEwIiwiaWF0IjoxNzUzNDg2OTIxLCJleHAiOjE3NTM1MTU3MjEsImp0aSI6IjBmMWUyZDNjNGI1YTZkODcifQ.SUPERADMIN_SIGNATURE
Content-Length: 0

(empty body)
EOF

  _resp "35-admin-disable-user" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 60
Date: Wed, 23 Jul 2026 14:27:30 GMT

{
  "internalUserId": "int-aws-admin",
  "disabled": true
}
EOF
}

# ---------------------------------------------------------------------------
# STAGE 7b: OpenFGA Tuple CRUD (SuperAdmin Power Screen)
# ---------------------------------------------------------------------------
gen_36_admin_tuples_crud() {
  _section "36 — GET|POST|DELETE /api/tuples (Browser → Identity Service, Tuple CRUD)"
  _dir "36-admin-tuples-crud"

  _req "36-admin-tuples-crud" << 'EOF'
# --- Example A: List all tuples ---
GET /api/tuples HTTP/1.1
Host: localhost:8766
Accept: application/json
Cookie: libcloud_portal_sid=...superadmin_session...

(empty body — GET request)


# --- Example B: Write tuples ---
POST /api/tuples HTTP/1.1
Host: localhost:8766
Content-Type: application/json
Accept: application/json
Cookie: libcloud_portal_sid=...superadmin_session...

{
  "writes": [
    {
      "user": "user:int-pending-a1b2c3d4",
      "relation": "viewer",
      "object": "tenant:aws"
    }
  ]
}


# --- Example C: Delete tuples ---
DELETE /api/tuples HTTP/1.1
Host: localhost:8766
Content-Type: application/json
Accept: application/json
Cookie: libcloud_portal_sid=...superadmin_session...

{
  "deletes": [
    {
      "user": "user:int-pending-a1b2c3d4",
      "relation": "viewer",
      "object": "tenant:aws"
    }
  ]
}
EOF

  _resp "36-admin-tuples-crud" << 'EOF'
# --- Example A: List all tuples response ---
HTTP/1.1 200 OK
Content-Type: application/json

{
  "tuples": [
    {"user": "user:superadmin", "relation": "superadmin", "object": "platform:main"},
    {"user": "user:aws-admin", "relation": "admin", "object": "tenant:aws"},
    {"user": "user:ntnx-owner", "relation": "owner", "object": "tenant:nutanix"},
    {"user": "user:aws-viewer", "relation": "viewer", "object": "tenant:aws"}
  ]
}


# --- Example B: Write tuples response ---
HTTP/1.1 200 OK
Content-Type: application/json

{
  "written": 1
}


# --- Example C: Delete tuples response ---
HTTP/1.1 200 OK
Content-Type: application/json

{
  "deleted": 1
}
EOF
}

# ---------------------------------------------------------------------------
# STAGE 7c: LLDAP HTTP Admin Operations
# ---------------------------------------------------------------------------
gen_37_lldap_admin_login() {
  _section "37 — POST /auth/simple/login (Identity Service → LLDAP, Admin Auth)"
  _dir "37-lldap-admin-login"

  _req "37-lldap-admin-login" << 'EOF'
POST /auth/simple/login HTTP/1.1
Host: lldap:17170
Content-Type: application/json
Accept: application/json
Content-Length: 61

{
  "username": "admin",
  "password": "EXAMPLE_LLDAP_ADMIN_PASSWORD_12345678"
}
EOF

  _resp "37-lldap-admin-login" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 247
Date: Wed, 23 Jul 2026 14:27:01 GMT

{
  "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VybmFtZSI6ImFkbWluIiwicm9sZSI6ImFkbWluIiwiaWF0IjoxNzUzNDg2OTIxLCJleHAiOjE3NTM0OTA1MjF9.LLDAP_ADMIN_JWT_SIGNATURE"
}
EOF
}

gen_38_lldap_graphql_update() {
  _section "38 — POST /api/graphql (Identity Service → LLDAP, UpdateUser Email)"
  _dir "38-lldap-graphql-update"

  _req "38-lldap-graphql-update" << 'EOF'
POST /api/graphql HTTP/1.1
Host: lldap:17170
Content-Type: application/json
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VybmFtZSI6ImFkbWluIiwicm9sZSI6ImFkbWluIiwiaWF0IjoxNzUzNDg2OTIxLCJleHAiOjE3NTM0OTA1MjF9.LLDAP_ADMIN_JWT_SIGNATURE
Accept: application/json
Content-Length: 207

{
  "query": "mutation UpdateUser($user: UpdateUserInput!) { updateUser(user: $user) { ok } }",
  "variables": {
    "user": {
      "id": "aws-admin",
      "email": "new-aws-admin@libcloud.local"
    }
  }
}
EOF

  _resp "38-lldap-graphql-update" << 'EOF'
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 36
Date: Wed, 23 Jul 2026 14:27:01 GMT

{
  "data": {
    "updateUser": {
      "ok": true
    }
  }
}
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  libcloud Portal — HTTP Flow Example Generator              ║"
  echo "║  See: system_http_flow.md for architectural context         ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Output directory: $ROOT"
  echo ""

  # Clean and recreate
  rm -rf "$ROOT"/0[1-9]* "$ROOT"/1[0-9]* "$ROOT"/2[0-9]* "$ROOT"/3[0-9]*
  COUNT=0

  # Stage 1: Login Initiation
  gen_01_auth_begin
  gen_02_dex_authorize
  gen_03_dex_callback

  # Stage 2: Token Exchange
  gen_04_auth_exchange
  gen_04b_auth_exchange_collapse
  gen_05_dex_token_exchange
  gen_06_dex_jwks

  # Stage 3: Identity Collapse
  gen_07_auth_collapse

  # Stage 4: Session Restoration
  gen_08_session_restore

  # Stage 5: Logout
  gen_09_logout_portal
  gen_10_dex_token_revoke
  gen_11_dex_rp_logout

  # Stage 6a: Provisioner Service-Account Auth
  gen_12_provisioner_dex_authorize
  gen_13_provisioner_dex_login
  gen_14_provisioner_dex_token
  gen_14b_provisioner_token_refresh

  # Stage 6c: OpenFGA
  gen_15_openfga_read
  gen_16_openfga_check
  gen_17_openfga_write

  # Stage 6d: libcloud REST API
  gen_18_rest_auth_me
  gen_19_rest_connection_test
  gen_20_rest_list_locations
  gen_21_rest_list_sizes
  gen_22_rest_list_images
  gen_23_rest_list_subnets
  gen_24_rest_list_nodes
  gen_25_rest_create_node
  gen_26_rest_update_node
  gen_27_rest_delete_node

  # Stage 6b: Portal Cloud Operations
  gen_28_portal_list_resources
  gen_29_portal_provision
  gen_30_portal_deprovision
  gen_31_portal_update

  # Stage 7a: Admin User Management
  gen_32_admin_list_users
  gen_33_admin_set_role
  gen_34_admin_set_email
  gen_35_admin_disable_user

  # Stage 7b: OpenFGA Tuple CRUD
  gen_36_admin_tuples_crud

  # Stage 7c: LLDAP Admin HTTP
  gen_37_lldap_admin_login
  gen_38_lldap_graphql_update

  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  Done. Generated $COUNT directories with request/response pairs."
  echo "  Files: $(find "$ROOT" -name '*.http' | wc -l) total (.http)"
  echo "  $(find "$ROOT" -type d -mindepth 1 | wc -l) subdirectories under $ROOT"
  echo "═══════════════════════════════════════════════════════════════"
}

main "$@"
