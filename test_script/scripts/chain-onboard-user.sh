#!/usr/bin/env bash
# chain-onboard-user.sh — full onboarding chain across LLDAP + OpenFGA + Vault.
#
# Cloud Admin tool. Atomic-or-compensating workflow:
#   1. create the LLDAP user (lldap-user-onboard.sh)
#   2. add the user to each named LLDAP group (lldap-group-add-member.sh),
#      which in turn triggers the OpenFGA tuple reconciler
#   3. explicitly run openfga-tuple-reconcile.py so the new memberships are
#      reflected as relationship tuples
#   4. verify Vault LDAP auth recognises the new group membership by performing
#      an LDAP login to Vault for the new user (best-effort; depends on the
#      Vault LDAP auth method being configured and the user's groups having
#      policy bindings)
#
# The user spec is a JSON (or YAML, if PyYAML is installed) document:
#   {
#     "username": "alice",
#     "display_name": "Alice Admin",
#     "email": "alice@example.com",
#     "password": "InitialPass123!",   # optional; generated + printed if omitted
#     "first_name": "Alice",           # optional
#     "last_name":  "Admin",           # optional
#     "groups": ["cloud-admin-aws", "cloud-ro-gcp"]
#   }
#
# Usage:
#   chain-onboard-user.sh --spec spec.json [--actor <user>] [--dry-run]
#       [--skip-vault-verify] [--print-password]
#
# Options:
#   --spec PATH          user spec file (JSON or YAML)
#   --actor <user>       audit actor (default $USER / cloud-admin)
#   --dry-run            plan only; do not invoke mutating sub-scripts
#   --skip-vault-verify  skip step 4 (Vault LDAP login probe)
#   --print-password     print the (generated) initial password to stdout
#   -h, --help
#
# Env: standard LLDAP/OpenFGA/Vault env (loaded by the sub-scripts).
#
# Exit codes:
#   0  onboarding chain completed
#   2  usage / spec parse error
#   3  a chain step failed (see the per-step messages; partial state possible)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AUDIT_LOG="${REPO_ROOT}/generated/chain_audit.log"
mkdir -p "$(dirname "$AUDIT_LOG")"

SPEC=""
ACTOR="${USER:-cloud-admin}"
DRY_RUN=0
SKIP_VAULT_VERIFY=0
PRINT_PASSWORD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec)             SPEC="$2"; shift 2 ;;
    --actor)            ACTOR="$2"; shift 2 ;;
    --dry-run)          DRY_RUN=1; shift ;;
    --skip-vault-verify) SKIP_VAULT_VERIFY=1; shift ;;
    --print-password)   PRINT_PASSWORD=1; shift ;;
    -h|--help)          sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$SPEC" && -f "$SPEC" ]] || { echo "ERROR: --spec <file> is required and must exist" >&2; exit 2; }

chain_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
chain_audit() {
  local line="$1"
  echo "$line" >&2
  echo "$line" >> "$AUDIT_LOG"
}

# Parse the spec (JSON or YAML) into a normalized JSON object on stdout.
# Validates required fields and generates a password if missing.
SPEC_JSON=$(SPEC_PATH="$SPEC" python3 - <<'PY'
import json, os, sys, secrets, string
raw = open(os.environ["SPEC_PATH"]).read().strip()
obj = None
if raw.startswith("{") or raw.startswith("["):
    obj = json.loads(raw)
else:
    try:
        import yaml
        obj = yaml.safe_load(raw)
    except Exception as e:
        sys.stderr.write(f"ERROR: spec is not valid JSON and PyYAML is unavailable ({e}).\n")
        sys.exit(2)
if not isinstance(obj, dict):
    sys.stderr.write("ERROR: spec must be a JSON/YAML object\n"); sys.exit(2)
for k in ("username", "display_name", "email"):
    if not obj.get(k):
        sys.stderr.write(f"ERROR: spec missing required field '{k}'\n"); sys.exit(2)
groups = obj.get("groups") or []
if not isinstance(groups, list):
    sys.stderr.write("ERROR: spec 'groups' must be a list\n"); sys.exit(2)
gen_pw = ""
if not obj.get("password"):
    a = string.ascii_letters + string.digits
    gen_pw = "".join(secrets.choice(a) for _ in range(24))
    obj["password"] = gen_pw
obj["_generated_password"] = bool(gen_pw)
print(json.dumps(obj))
PY
)

username=$(printf '%s' "$SPEC_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["username"])')
display_name=$(printf '%s' "$SPEC_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["display_name"])')
email=$(printf '%s' "$SPEC_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["email"])')
password=$(printf '%s' "$SPEC_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')
first_name=$(printf '%s' "$SPEC_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("first_name",""))')
last_name=$(printf '%s' "$SPEC_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("last_name",""))')
groups_csv=$(printf '%s' "$SPEC_JSON" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin).get("groups",[])))')
gen_pw=$(printf '%s' "$SPEC_JSON" | python3 -c 'import json,sys; print("1" if json.load(sys.stdin).get("_generated_password") else "0")')

echo "=== chain-onboard-user: ${username} (${display_name}) groups=[${groups_csv}] ===" >&2

step_status() {  # <step> <status> <detail-json>
  chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-onboard-user\",\"user\":\"${username}\",\"step\":$1,\"result\":\"$2\",\"detail\":$3}"
}

# Step 1: create the LLDAP user.
echo "[1/4] create LLDAP user" >&2
onboard_args=(--username "$username" --display-name "$display_name" --email "$email" --password "$password")
[[ -n "$first_name" ]] && onboard_args+=(--first-name "$first_name")
[[ -n "$last_name" ]]  && onboard_args+=(--last-name "$last_name")
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  [dry-run] would run lldap-user-onboard.sh ${onboard_args[*]}" >&2
  step_status 1 "dry-run" '{}'
else
  if bash "${SCRIPT_DIR}/lldap-user-onboard.sh" "${onboard_args[@]}" >/tmp/chain_onboard.log 2>&1; then
    step_status 1 "ok" '{}'
  else
    rc=$?
    echo "  FAILED (rc=$rc):" >&2; tail -n 20 /tmp/chain_onboard.log >&2
    step_status 1 "error" "{\"rc\":$rc}"
    exit 3
  fi
fi

# Step 2: add to each group (each call also triggers the reconciler).
echo "[2/4] assign LLDAP groups" >&2
failed_groups=()
for g in ${groups_csv//,/ }; do
  [[ -z "$g" ]] && continue
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  [dry-run] would add ${username} to ${g}" >&2
    continue
  fi
  if bash "${SCRIPT_DIR}/lldap-group-add-member.sh" --user "$username" --group "$g" >/tmp/chain_group.log 2>&1; then
    echo "  added to ${g}" >&2
  else
    rc=$?
    echo "  WARN: add to ${g} failed (rc=$rc):" >&2; tail -n 10 /tmp/chain_group.log >&2
    failed_groups+=("$g")
  fi
done
step_status 2 "$([[ ${#failed_groups[@]} -eq 0 ]] && echo ok || echo partial)" \
  "{\"groups\":\"${groups_csv}\",\"failed\":$(printf '%s' "${failed_groups[*]-}" | python3 -c 'import json,sys; print(json.dumps(sys.argv[1].split() if sys.argv[1] else []))' "${failed_groups[*]-}")}"

# Step 3: run the OpenFGA tuple reconciler explicitly.
echo "[3/4] run openfga-tuple-reconcile.py" >&2
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  [dry-run] would run reconciler" >&2
  step_status 3 "dry-run" '{}'
else
  if python3 "${SCRIPT_DIR}/openfga-tuple-reconcile.py" >/tmp/chain_reconcile.log 2>&1; then
    step_status 3 "ok" '{}'
  else
    rc=$?
    echo "  WARN: reconciler failed (rc=$rc):" >&2; tail -n 10 /tmp/chain_reconcile.log >&2
    step_status 3 "error" "{\"rc\":$rc}"
  fi
fi

# Step 4: verify Vault LDAP auth recognises the new membership by logging the
# new user in through the Vault LDAP auth method. Best-effort.
echo "[4/4] verify Vault LDAP auth for ${username}" >&2
if [[ "$SKIP_VAULT_VERIFY" -eq 1 ]]; then
  echo "  skipped (--skip-vault-verify)" >&2
  step_status 4 "skipped" '{}'
elif [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  [dry-run] would probe auth/ldap/login/${username}" >&2
  step_status 4 "dry-run" '{}'
else
  # shellcheck source=vault_common.sh
  source "${SCRIPT_DIR}/vault_common.sh" 2>/dev/null || true
  if tok=$(vault_resolve_token 2>/dev/null) && curl -sS -X POST \
      "${VAULT_ADDR:-http://localhost:8200}/v1/auth/ldap/login/${username}" \
      -H "Content-Type: application/json" \
      -d "{\"password\":\"${password}\"}" -o /tmp/chain_vlogin -w "%{http_code}" 2>/dev/null \
      | grep -qE '^200$'; then
    pols=$(python3 -c 'import json; d=json.load(open("/tmp/chain_vlogin")).get("auth",{}).get("policies",[]); print(",".join(pols))' 2>/dev/null || echo "?")
    echo "  OK: Vault LDAP login succeeded; policies=[${pols}]" >&2
    step_status 4 "ok" "{\"policies\":\"${pols}\"}"
  else
    code=$(cat /tmp/chain_vlogin 2>/dev/null | head -c 200)
    echo "  WARN: Vault LDAP login probe failed (no policy binding? LDAP auth not configured?): ${code}" >&2
    step_status 4 "verify-failed" '{}'
  fi
  rm -f /tmp/chain_vlogin
fi

if [[ "$gen_pw" == "1" && "$PRINT_PASSWORD" -eq 1 ]]; then
  printf 'generated initial password for %s: %s\n' "$username" "$password"
fi
echo "=== chain-onboard-user complete: ${username} ===" >&2
exit 0
