#!/usr/bin/env bash
# chain-diagnose-access.sh — triage "user X cannot do Y on Z".
#
# Cloud Admin diagnostic chain. Walks every layer that contributes to an
# allow/deny decision and prints a structured triage report indicating which
# layer (if any) is denying access:
#   1. LLDAP group membership — does the user belong to any group mapped to
#      the requested relation/object?
#   2. OpenFGA tuple existence — is there an explicit user:<uid> <r> <o> tuple?
#   3. OpenFGA Check() — does the engine return allowed?
#   4. Vault policy for the user's role — does the Vault LDAP group binding
#      grant a policy that would let the user fetch backend credentials?
#
# Usage:
#   chain-diagnose-access.sh --user <uid> --relation <r> --object <o>
#       [--check-relation <r>] [--check-object <o>] [--map-file <path>]
#       [--json] [--actor <u>]
#
# Options:
#   --user <uid>           the user to diagnose (LLDAP uid; OpenFGA user:<uid>)
#   --relation <r>         the relation being asked about (default check relation)
#   --object <o>           the object being asked about
#   --check-relation <r>   the OpenFGA Check relation (default --relation)
#   --check-object <o>     the OpenFGA Check object   (default --object)
#   --map-file <path>      explicit reconciler mapping (group -> (rel,obj))
#   --json                 print the report as JSON
#   --actor <u>            audit actor
#   -h, --help
#
# Exit codes:
#   0  diagnosis produced (regardless of allow/deny; the report is the output)
#   2  usage
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AUDIT_LOG="${ROOT}/generated/chain_audit.log"
mkdir -p "$(dirname "$AUDIT_LOG")"

OPT_USER=""; OPT_REL=""; OPT_OBJ=""
OPT_CHECK_REL=""; OPT_CHECK_OBJ=""
MAP_FILE=""
JSON=0
ACTOR="${USER:-cloud-admin}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)           OPT_USER="$2"; shift 2 ;;
    --relation)       OPT_REL="$2"; shift 2 ;;
    --object)         OPT_OBJ="$2"; shift 2 ;;
    --check-relation) OPT_CHECK_REL="$2"; shift 2 ;;
    --check-object)   OPT_CHECK_OBJ="$2"; shift 2 ;;
    --map-file)       MAP_FILE="$2"; shift 2 ;;
    --json)           JSON=1; shift ;;
    --actor)          ACTOR="$2"; shift 2 ;;
    -h|--help)        sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$OPT_USER" && -n "$OPT_OBJ" ]] || { echo "ERROR: --user and --object are required" >&2; exit 2; }
: "${OPT_REL:=can_provision}"
: "${OPT_CHECK_REL:=$OPT_REL}"
: "${OPT_CHECK_OBJ:=$OPT_OBJ}"

chain_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
chain_audit() { local line="$1"; echo "$line" >&2; echo "$line" >> "$AUDIT_LOG"; }

fga_user="user:${OPT_USER}"

# Layer 1: LLDAP group membership.
echo "[1/4] LLDAP group membership for ${OPT_USER}" >&2
lldap_groups_json="[]"
if groups_out=$(bash "${SCRIPT_DIR}/lldap-user-list-groups.sh" --username "$OPT_USER" --format json 2>/dev/null); then
  lldap_groups_json=$(printf '%s' "$groups_out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([g["displayName"] for g in d.get("groups",[])]))')
fi
echo "  groups: ${lldap_groups_json}" >&2

# Derive which LLDAP group(s) map to the requested (relation, object).
mapped_groups=$(MAP_FILE_E="$MAP_FILE" GJ="$lldap_groups_json" REL="$OPT_REL" OBJ="$OPT_OBJ" \
  PYTHONPATH="${SCRIPT_DIR}" python3 - <<'PY' 2>/dev/null || echo "[]"
import os, json
try:
    import openfga_pylib as lib
    lib.bootstrap_env()
    mf = os.environ.get("MAP_FILE_E") or None
    explicit = lib.load_map_file(mf) if mf else None
    groups = json.loads(os.environ["GJ"])
    rel, obj = os.environ["REL"], os.environ["OBJ"]
    matched = []
    for g in groups:
        m = lib.group_to_tuple(g, explicit)
        if m and m[0] == rel and m[1] == obj:
            matched.append(g)
    print(json.dumps(matched))
except Exception as e:
    print("[]")
PY
)
echo "  groups mapped to ${OPT_REL} ${OPT_OBJ}: ${mapped_groups}" >&2

# Layer 2: OpenFGA tuple existence.
echo "[2/4] OpenFGA tuple existence for ${fga_user} ${OPT_REL} ${OPT_OBJ}" >&2
tuple_exists="false"
if source "${SCRIPT_DIR}/openfga_common.sh" >/dev/null 2>&1; then
  all=$(fga_read_all_tuples 2>/dev/null || echo "[]")
  tuple_exists=$(ALL="$all" U="$fga_user" R="$OPT_REL" O="$OPT_OBJ" python3 -c '
import json, os
all_t = json.loads(os.environ["ALL"])
u, r, o = os.environ["U"], os.environ["R"], os.environ["O"]
print("true" if any(t.get("user")==u and t.get("relation")==r and t.get("object")==o for t in all_t) else "false")
')
fi
echo "  explicit tuple present: ${tuple_exists}" >&2

# Layer 3: OpenFGA Check().
echo "[3/4] OpenFGA Check ${fga_user} ${OPT_CHECK_REL} ${OPT_CHECK_OBJ}" >&2
check_allowed="error"
check_rc=99
if check_out=$(bash "${SCRIPT_DIR}/openfga-check.sh" "$fga_user" "$OPT_CHECK_REL" "$OPT_CHECK_OBJ" 2>/dev/null); then
  check_rc=0; check_allowed="true"
elif [[ $? -eq 1 ]]; then
  check_rc=1; check_allowed="false"
else
  check_allowed="error"
fi
echo "  check -> ${check_allowed} (rc=${check_rc})" >&2

# Layer 4: Vault policy for the user's role.
echo "[4/4] Vault policy for ${OPT_USER}'s role" >&2
vault_policies="[]"
if source "${SCRIPT_DIR}/vault_common.sh" >/dev/null 2>&1; then
  # For each LLDAP group the user is in, look up the Vault LDAP group binding.
  vault_policies=$(GJ="$lldap_groups_json" \
    VAULT_TOKEN_RESOLVED="$(vault_resolve_token 2>/dev/null)" \
    VAULT_ADDR_E="${VAULT_ADDR:-http://localhost:8200}" \
    python3 - <<'PY' 2>/dev/null || echo "[]"
import json, os, urllib.error, urllib.request
addr = os.environ["VAULT_ADDR_E"].rstrip("/")
tok = os.environ.get("VAULT_TOKEN_RESOLVED","")
groups = json.loads(os.environ["GJ"])
if not tok:
    print("[]"); raise SystemExit
def call(path):
    url = addr + "/v1/" + path.lstrip("/")
    req = urllib.request.Request(url, headers={"X-Vault-Token": tok})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except Exception:
        return 0, {}
out = []
for g in groups:
    c, b = call("auth/ldap/groups/" + g)
    if c != 200: continue
    pols = (b.get("data") or {}).get("policies") or []
    if isinstance(pols, str): pols = [p.strip() for p in pols.split(",") if p.strip()]
    out.append({"group": g, "policies": pols})
print(json.dumps(out))
PY
)
fi
echo "  vault bindings: ${vault_policies}" >&2

# Build the triage verdict.
verdict=$(MAPPED="$mapped_groups" TUPLE="$tuple_exists" ALLOWED="$check_allowed" python3 - <<'PY'
import json, os
mapped = json.loads(os.environ["MAPPED"])
tuple_exists = os.environ["TUPLE"] == "true"
allowed = os.environ["ALLOWED"]
if allowed == "true":
    print("ALLOWED — all layers pass")
elif mapped:
    if not tuple_exists:
        print("DENIED at OpenFGA — LLDAP group mapped but no explicit tuple (reconciler lag? run openfga-tuple-reconcile.py)")
    else:
        print("DENIED at OpenFGA — tuple present but Check returned denied (model relation / context issue)")
else:
    print("DENIED at LLDAP — user is not in a group mapped to this relation/object")
PY
)

report=$(python3 -c '
import json, sys
print(json.dumps({
  "user": sys.argv[1],
  "relation": sys.argv[2],
  "object": sys.argv[3],
  "lldap_groups": json.loads(sys.argv[4]),
  "mapped_groups": json.loads(sys.argv[5]),
  "openfga_tuple_present": sys.argv[6] == "true",
  "openfga_check": sys.argv[7],
  "vault_bindings": json.loads(sys.argv[8]),
  "verdict": sys.argv[9],
}, indent=2))
' "$OPT_USER" "$OPT_REL" "$OPT_OBJ" "$lldap_groups_json" "$mapped_groups" "$tuple_exists" "$check_allowed" "$vault_policies" "$verdict")

if [[ "$JSON" -eq 1 ]]; then
  printf '%s\n' "$report"
else
  echo
  echo "=== TRIAGE REPORT ==="
  printf '%s\n' "$report" | python3 -m json.tool
  echo "verdict: ${verdict}"
fi >&2

chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-diagnose-access\",\"user\":\"${OPT_USER}\",\"relation\":\"${OPT_REL}\",\"object\":\"${OPT_OBJ}\",\"check\":\"${check_allowed}\",\"verdict\":\"${verdict}\"}"
exit 0
