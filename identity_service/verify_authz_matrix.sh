#!/usr/bin/env bash
# AuthZ matrix verification for the identity service (portal backend).
#
# Regression net for the "Provision Nutanix -> 403 authz_forbidden" bug: the
# portal rendered the button from /api/session capabilities while the verb
# routes authorized a DIFFERENT principal (main._principal stripped "int-" for
# pending users; fixed to share UserService._fga_principal). This script fails
# if the capability flags ever diverge from the route gates again, for any
# user in the matrix.
#
# Two layers, both against the identity-service container (the authZ
# enforcement point — this is the docker container under test):
#
#   [A] In-process consistency test (tests/test_authz_consistency.py), run
#       inside the container via FastAPI TestClient. Covers ALL users including
#       pending (federated) users keyed by full internal id — the bug class —
#       with LibcloudProxy stubbed, so it creates/updates/deletes NO real VMs.
#
#   [B] Live HTTP matrix over BASE_URL for every seeded LLDAP user x cloud x
#       verb (resources/provision/deprovision/update). Uses forged session
#       cookies minted with the container's own SESSION_SECRET. Denied verbs
#       must be 403 authz_forbidden; allowed write verbs are probed with bogus
#       VM ids (gate passes, nothing real is touched) unless FULL_LIFECYCLE=1.
#
# Usage:
#   ./verify_authz_matrix.sh                       # gate matrix, no real VMs
#   FULL_LIFECYCLE=1 ./verify_authz_matrix.sh      # also provision+deprovision
#                                                  # a REAL VM per allowed
#                                                  # user/cloud (AWS = real EC2!)
#   BASE_URL=http://login.quest4science.xyz:8766 CONTAINER=identity-service ./verify_authz_matrix.sh
#
# Exit status: 0 if all checks pass, 1 if any fail.

set -u

BASE_URL="${BASE_URL:-http://localhost:8766}"
BASE_URL="${BASE_URL%/}"
CONTAINER="${CONTAINER:-identity-service}"
FULL_LIFECYCLE="${FULL_LIFECYCLE:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0; FAIL=0; SKIP=0
FAILURES=()

pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILURES+=("$1"); }
skip() { printf '  SKIP  %s\n' "$1"; SKIP=$((SKIP+1)); }

# --- expectation matrix (hardcoded from rbac_design.md; NOT derived from -----
# --- OpenFGA, so the test stays independent of the thing it tests) ------------
# view: owner/admin/viewer on own tenant; superadmin everywhere (global reader).
exp_view() {
  case "$1:$2" in
    int-aws-owner:aws|int-aws-admin:aws|int-aws-viewer:aws) echo 1;;
    int-ntnx-owner:nutanix|int-ntnx-admin:nutanix|int-ntnx-viewer:nutanix) echo 1;;
    int-superadmin:aws|int-superadmin:nutanix) echo 1;;
    *) echo 0;;
  esac
}
# write (provision/deprovision/update): owner/admin on own tenant only.
exp_write() {
  case "$1:$2" in
    int-aws-owner:aws|int-aws-admin:aws) echo 1;;
    int-ntnx-owner:nutanix|int-ntnx-admin:nutanix) echo 1;;
    *) echo 0;;
  esac
}

echo "=== AuthZ matrix verification: identity-service ==="
echo "    BASE_URL=$BASE_URL  CONTAINER=$CONTAINER  FULL_LIFECYCLE=$FULL_LIFECYCLE"
echo

# --- [A] in-process consistency test -----------------------------------------
echo "[A] in-process consistency matrix (stubbed proxy; covers pending users)"
docker cp "$SCRIPT_DIR/tests/test_authz_consistency.py" "$CONTAINER":/tmp/test_authz_consistency.py
if docker exec -e PYTHONPATH=/app "$CONTAINER" python /tmp/test_authz_consistency.py; then
  pass "consistency matrix (in-process)"
else
  fail "consistency matrix (in-process)" "see output above"
fi
echo

# --- [B] live HTTP matrix -----------------------------------------------------
echo "[B] live HTTP matrix (forged cookies; bogus vmIds -> no real VMs)"
echo "    minting session cookies via $CONTAINER ..."
TOKENS="$(docker exec "$CONTAINER" python -c "
from app.config import get_settings
import jwt, time
s = get_settings()
now = int(time.time())
users = [('int-aws-owner','owner'),('int-aws-admin','admin'),('int-aws-viewer','viewer'),
         ('int-ntnx-owner','owner'),('int-ntnx-admin','admin'),('int-ntnx-viewer','viewer'),
         ('int-superadmin','superadmin')]
for uid, role in users:
    tok = jwt.encode({'internalUserId':uid,'role':role,'email':uid+'@libcloud.local',
                      'linkedIdentities':[],'sid':'authz-matrix','iat':now,'exp':now+3600,'jti':'m'},
                     s.session_secret, algorithm='HS256')
    print(uid + ' ' + tok)
" 2>/dev/null)"
if [ -z "$TOKENS" ]; then
  echo "FATAL: could not mint cookies via container $CONTAINER"; exit 1
fi
COOKIE_NAME="$(docker exec "$CONTAINER" python -c 'from app.config import get_settings; print(get_settings().session_cookie_name)' 2>/dev/null)"

token_for() { printf '%s\n' "$TOKENS" | awk -v u="$1" '$1==u {print $2}'; }

# http_status <method> <path> <token> [json-body]
http_status() {
  local method="$1" path="$2" tok="$3" body="${4:-}"
  if [ -n "$body" ]; then
    curl -s -o /tmp/m_body -w '%{http_code}' -X "$method" -H "Cookie: $COOKIE_NAME=$tok" \
      -H 'Content-Type: application/json' -d "$body" "$BASE_URL$path"
  else
    curl -s -o /tmp/m_body -w '%{http_code}' -X "$method" -H "Cookie: $COOKIE_NAME=$tok" "$BASE_URL$path"
  fi
}

err_code() { python3 -c 'import sys,json
try: print(json.load(open("/tmp/m_body")).get("error",""))
except Exception: print("")' 2>/dev/null; }

# assert_gate <name> <expected_allow 0|1> <method> <path> <token> [body]
assert_gate() {
  local name="$1" allow="$2" method="$3" path="$4" tok="$5" body="${6:-}"
  local http; http="$(http_status "$method" "$path" "$tok" "$body")"
  if [ "$allow" = "0" ]; then
    if [ "$http" = "403" ] && [ "$(err_code)" = "authz_forbidden" ]; then pass "$name"
    else fail "$name" "want 403 authz_forbidden; got http=$http err=$(err_code) body=$(head -c 160 /tmp/m_body)"; fi
  else
    if [ "$http" != "403" ]; then pass "$name"
    else fail "$name" "want gate PASS (not 403); got 403 body=$(head -c 160 /tmp/m_body)"; fi
  fi
}

for user in int-aws-owner int-aws-admin int-aws-viewer int-ntnx-owner int-ntnx-admin int-ntnx-viewer int-superadmin; do
  TOK="$(token_for "$user")"
  echo "  [user] $user"

  # /api/session capability flags must match the matrix AND the route gates.
  # Keep the session body in its own file: the verb gates below overwrite
  # /tmp/m_body on every call.
  http_status GET /api/session "$TOK" >/dev/null
  cp /tmp/m_body /tmp/m_session
  for cloud in aws nutanix; do
    read -r f_view f_prov f_upd <<<"$(python3 -c "
import json
d = json.load(open('/tmp/m_session'))
c = {x['cloud']: x for x in d.get('clouds', [])}.get('$cloud', {})
print(int(bool(c.get('canView'))), int(bool(c.get('canProvision'))), int(bool(c.get('canUpdate'))))")"
    e_view="$(exp_view "$user" "$cloud")"; e_write="$(exp_write "$user" "$cloud")"
    if [ "$f_view" = "$e_view" ] && [ "$f_prov" = "$e_write" ] && [ "$f_upd" = "$e_write" ]; then
      pass "$user session flags[$cloud] (view=$f_view prov=$f_prov upd=$f_upd)"
    else
      fail "$user session flags[$cloud]" "want view=$e_view prov=$e_write upd=$e_write; got view=$f_view prov=$f_prov upd=$f_upd"
    fi

    # Verb gates.
    assert_gate "$user GET /api/resources/$cloud" "$e_view" GET "/api/resources/$cloud" "$TOK"
    if [ "$e_write" = "1" ]; then
      if [ "$FULL_LIFECYCLE" = "1" ]; then
        http="$(http_status POST "/api/provision/$cloud" "$TOK" '{"vmName":"authz-matrix-'"$cloud"'-'"$(date +%s)"'"}')"
        if [ "$http" = "200" ]; then
          pass "$user POST /api/provision/$cloud (lifecycle)"
          NODE_ID="$(python3 -c 'import json;print((json.load(open("/tmp/m_body")).get("node") or {}).get("id",""))' 2>/dev/null)"
          if [ -n "$NODE_ID" ]; then
            assert_gate "$user POST /api/deprovision/$cloud (cleanup $NODE_ID)" 1 POST "/api/deprovision/$cloud" "$TOK" \
              "{\"vmId\":\"$NODE_ID\",\"vmName\":\"authz-matrix-cleanup\"}"
          fi
        else
          fail "$user POST /api/provision/$cloud (lifecycle)" "want 200; got http=$http body=$(head -c 200 /tmp/m_body)"
        fi
      else
        skip "$user POST /api/provision/$cloud allowed (set FULL_LIFECYCLE=1 to run a real provision+teardown)"
      fi
      assert_gate "$user POST /api/deprovision/$cloud bogus-id" 1 POST "/api/deprovision/$cloud" "$TOK" '{"vmId":"authz-no-such-vm","vmName":"x"}'
      assert_gate "$user POST /api/update/$cloud bogus-id" 1 POST "/api/update/$cloud" "$TOK" '{"vmId":"authz-no-such-vm","name":"x"}'
      # The "Provision Private VM Machine" button shares the can_provision gate.
      # On AWS an allowed call stops at 400 not_supported (Nutanix-only pair);
      # on Nutanix it would create two REAL VMs, so only the in-process stub
      # matrix covers the allowed Nutanix path.
      if [ "$cloud" = "aws" ]; then
        assert_gate "$user POST /api/provision-private/$cloud (nutanix-only)" 1 POST "/api/provision-private/$cloud" "$TOK" '{"vmName":"authz-no-such-pair"}'
      else
        skip "$user POST /api/provision-private/$cloud allowed (real run creates 2 VMs; covered by in-process stub matrix)"
      fi
    else
      assert_gate "$user POST /api/provision/$cloud" 0 POST "/api/provision/$cloud" "$TOK" '{"vmName":"authz-should-not-create"}'
      assert_gate "$user POST /api/provision-private/$cloud" 0 POST "/api/provision-private/$cloud" "$TOK" '{"vmName":"authz-should-not-create"}'
      assert_gate "$user POST /api/deprovision/$cloud" 0 POST "/api/deprovision/$cloud" "$TOK" '{"vmId":"authz-no-such-vm","vmName":"x"}'
      assert_gate "$user POST /api/update/$cloud" 0 POST "/api/update/$cloud" "$TOK" '{"vmId":"authz-no-such-vm","name":"x"}'
    fi
  done
done

# --- summary ------------------------------------------------------------------
echo
echo "=== Summary: $PASS passed, $FAIL failed, $SKIP skipped ==="
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed checks:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
