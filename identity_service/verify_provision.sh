#!/usr/bin/env bash
# Verification script for Path 2 (real provision_*.sh replay).
#
# Exercises the identity-service provisioning replay end-to-end against the
# libcloud REST API. By default it provisions a real EC2/Nutanix VM and then
# tears it down (so you don't pay for a leftover instance). Set TEARDOWN=0 to
# keep the VM, or CLOUD=nutanix to test Nutanix.
#
# Usage:
#   ./verify_provision.sh                       # AWS, provision + teardown
#   CLOUD=nutanix ./verify_provision.sh         # Nutanix
#   TEARDOWN=0 ./verify_provision.sh             # keep the VM
#   BASE_URL=http://login.quest4science.xyz:8766 ./verify_provision.sh
#
# Exit status: 0 if the replay reaches POST /v1/compute/nodes with 200, 1 otherwise.

set -u

BASE_URL="${BASE_URL:-http://localhost:8766}"
BASE_URL="${BASE_URL%/}"
CLOUD="${CLOUD:-aws}"
TEARDOWN="${TEARDOWN:-1}"
VM_NAME="libcloud-verify-${CLOUD}-$(date +%s)"

# Provision directly via the proxy module inside the container (bypasses the
# cookie authZ on /api/provision/*, which requires a portal session). This
# tests the replay mechanics; the portal session authZ is covered by
# verify_auth.sh.
echo "=== Path 2 verification: provision_${CLOUD}.sh replay ==="
echo "    BASE_URL=$BASE_URL  CLOUD=$CLOUD  VM_NAME=$VM_NAME  TEARDOWN=$TEARDOWN"
echo

RESULT="$(docker exec identity-service python3 -c "
from app.idp_login import _token_cache
_token_cache.clear()
from app.libcloud_proxy import LibcloudProxy
import json
print(json.dumps(LibcloudProxy().provision('${CLOUD}', '${VM_NAME}')))
")"

echo "$RESULT" | python3 -m json.tool

STATUS="$(printf '%s' "$RESULT" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status",""))')"
NODE_ID="$(printf '%s' "$RESULT" | python3 -c 'import sys,json; d=json.load(sys.stdin); n=d.get("node") or {}; print(n.get("id") or n.get("instance_id") or "")')"

echo
if [ "$STATUS" = "provisioned" ]; then
  echo "  PASS  provision replay -> status=provisioned (node=${NODE_ID:-?})"
else
  echo "  FAIL  provision replay -> status=$STATUS (see steps above)"
  echo "        'invalid_claims' means token validation failed (iss/aud/exp) — check"
  echo "        Dex/OpenFGA OIDC config; OpenFGA v1.16.0+ self-refreshes JWKS on kid-miss."
  exit 1
fi

if [ "$TEARDOWN" = "1" ] && [ -n "$NODE_ID" ]; then
  echo
  echo "  Tearing down ${NODE_ID} ..."
  docker exec identity-service python3 -c "
from app.idp_login import ProvisionerAuth
from app.config import get_settings
import httpx, json
s = get_settings()
tok = ProvisionerAuth().get_token('${CLOUD}')
if '${CLOUD}' == 'aws':
    conn = {'provider':'aws','config':{'region':s.aws_region,'secure':True},'auth_binding':'aws'}
else:
    conn = {'provider':'nutanix','config':{'host':s.ntnx_host,'port':s.ntnx_port,'secure':True,'api_version':s.ntnx_api_version,'verify_ssl_cert':s.ntnx_verify_ssl},'auth_binding':'nutanix'}
h = {'Authorization':f'Bearer {tok}','Accept':'application/json','X-Provider-Connection':json.dumps(conn)}
r = httpx.Client(timeout=60).delete(f'{s.libcloud_rest_url}/v1/compute/nodes/${NODE_ID}', headers=h)
print('  delete ->', r.status_code, r.text[:120])
"
fi

echo
echo "=== Summary: provision_${CLOUD}.sh replay OK ==="
exit 0
