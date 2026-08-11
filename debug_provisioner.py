#!/usr/bin/env python3
"""Debug provisioner token against OpenFGA. Run from inside identity-service container."""
import os, urllib.request, urllib.error, ssl, re, json
from urllib.parse import parse_qs, urlparse

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

# Step 1: GET authorize
params = 'client_id=libcloud-rest&redirect_uri=http://127.0.0.1:8766/oauth/callback&response_type=code&scope=openid+email+profile&state=test&connector_id=lldap'
resp = urllib.request.urlopen('http://dex:5556/dex/auth?' + params, context=ctx, timeout=15)
html = resp.read().decode()
m = re.search(r'action="(/dex/auth/[^"]+)"', html)
if not m:
    print('FAIL: No login form action found')
    print(html[:500])
    exit(1)

post_url = 'http://dex:5556' + m.group(1).replace('&amp;', '&')
print(f'[1/3] Login form: {post_url}')

# Step 2: POST credentials (no redirect follow, to capture the code)
user = os.environ.get('LIBCLOUD_USER_AWS_ADMIN', '')
pw = os.environ.get('LIBCLOUD_PASSWORD_AWS_ADMIN', '')
print(f'[2/3] Logging in as: {user}')

# Custom HTTPRedirectHandler that does NOT follow redirects
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None
    def http_error_302(self, req, fp, code, msg, headers):
        return fp
    http_error_303 = http_error_302
    http_error_301 = http_error_302
    http_error_307 = http_error_302

no_redir_opener = urllib.request.build_opener(NoRedirect)
data = urllib.parse.urlencode({'login': user, 'password': pw}).encode()
req = urllib.request.Request(post_url, data=data, method='POST')
resp = no_redir_opener.open(req, timeout=15)
location = resp.headers.get('location', '')
code = parse_qs(urlparse(location).query).get('code', [''])[0]
print(f'[2/3] Status: {resp.status}, code: {code[:16] if code else "MISSING"}...')
if not code:
    body = resp.read().decode()[:500]
    print(f'Response body: {body}')
    exit(1)
print(f'[2/3] Got code: {code[:16]}...')

# Step 3: Exchange code for tokens
secret = os.environ.get('LIBCLOUD_OIDC_CLIENT_SECRET', '')
data = urllib.parse.urlencode({
    'grant_type': 'authorization_code',
    'code': code,
    'redirect_uri': 'http://127.0.0.1:8766/oauth/callback',
    'client_id': 'libcloud-rest',
    'client_secret': secret,
}).encode()
req = urllib.request.Request('http://dex:5556/dex/token', data=data, method='POST')
resp = urllib.request.urlopen(req, context=ctx, timeout=15)
tok = json.loads(resp.read())
access_token = tok.get('access_token', '')
print(f'[3/3] Got access_token length: {len(access_token)}')

if not access_token:
    print('FAIL: empty access_token')
    exit(1)

# Decode JWT without verification to inspect claims
import base64
parts = access_token.split('.')
if len(parts) == 3:
    # Add padding
    padded = parts[1] + '=' * (-len(parts[1]) % 4)
    claims = json.loads(base64.urlsafe_b64decode(padded))
    print(f'\nToken claims:')
    print(f'  iss: {claims.get("iss")}')
    print(f'  aud: {claims.get("aud")}')
    print(f'  sub: {claims.get("sub", "")[:30]}...')
    print(f'  exp: {claims.get("exp")}')
    print(f'  iat: {claims.get("iat")}')
    print(f'  email: {claims.get("email")}')

# Step 4: Test against OpenFGA
store_id = os.environ.get('FGA_STORE_ID', '')
print(f'\nTesting OpenFGA /read (store={store_id})...')
url = f'http://openfga:8080/stores/{store_id}/read'
body = json.dumps({'page_size': 5}).encode()
req = urllib.request.Request(url, data=body, method='POST',
    headers={'Content-Type': 'application/json', 'Authorization': f'Bearer {access_token}'})
try:
    resp = urllib.request.urlopen(req, context=ctx, timeout=10)
    result = json.loads(resp.read())
    print(f'SUCCESS: {len(result.get("tuples", []))} tuples')
except urllib.error.HTTPError as e:
    print(f'FAIL ({e.code}): {e.read().decode()}')
