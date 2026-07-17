#!/usr/bin/env bash
# chain-provider-onboard.sh — pre-work to onboard a new cloud provider.
#
# Cloud Owner tool. Orchestrates the cross-system setup that must happen before
# a new cloud provider can be used through libcloud REST:
#   1. enable the Vault cloud secrets engine (vault-secrets-engine-enable.sh)
#   2. create Vault dynamic-secret roles per permission level
#      (vault-role-create.sh, one per role)
#   3. create the LLDAP groups for the provider (lldap-group-create.sh)
#   4. apply the Vault ACL policies and bind them to the LLDAP groups
#      (vault-policy-apply.sh + vault-ldap-group-bind.sh)
#   5. validate end-to-end with a test dynamic-credential request
#      (vault-dynamic-cred-request.sh)
#
# Prerequisite: the developer must have already added the libcloud driver and
# the OpenFGA relations for the new provider. This script does NOT touch the
# OpenFGA model.
#
# The provider spec is a JSON (or YAML, if PyYAML is installed) document:
#   {
#     "provider": "aws",
#     "mount": "aws",
#     "region": "ap-southeast-1",
#     "root_creds_file": "creds/aws-root.env",
#     "vault_policies": [
#       {"name": "cloud-admin-aws", "file": "policy-files/cloud-admin-aws.hcl"}
#     ],
#     "roles": [
#       {"name": "ec2-admin", "policy_file": "policy-files/ec2-admin.json",
#        "credential_type": "assumed_role", "ttl": "1h", "max_ttl": "4h"}
#     ],
#     "lldap_groups": [
#       {"name": "cloud-admin-aws", "vault_policy": "cloud-admin-aws"}
#     ],
#     "test_role": "ec2-admin"
#   }
#
# Usage:
#   chain-provider-onboard.sh --spec provider.json [--actor <u>] [--dry-run]
#       [--skip-test-cred]
#
# Options:
#   --spec PATH         provider spec file (JSON or YAML)
#   --actor <u>         audit actor
#   --dry-run           plan only
#   --skip-test-cred    skip step 5 (end-to-end credential test)
#   -h, --help
#
# Exit codes:
#   0  provider onboarded
#   2  usage / spec parse error
#   3  a chain step failed (partial state possible)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AUDIT_LOG="${REPO_ROOT}/generated/chain_audit.log"
mkdir -p "$(dirname "$AUDIT_LOG")"

SPEC=""
ACTOR="${USER:-cloud-owner}"
DRY_RUN=0
SKIP_TEST_CRED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec)          SPEC="$2"; shift 2 ;;
    --actor)         ACTOR="$2"; shift 2 ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --skip-test-cred) SKIP_TEST_CRED=1; shift ;;
    -h|--help)       sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$SPEC" && -f "$SPEC" ]] || { echo "ERROR: --spec <file> is required and must exist" >&2; exit 2; }

chain_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
chain_audit() { local line="$1"; echo "$line" >&2; echo "$line" >> "$AUDIT_LOG"; }

SPEC_JSON=$(SPEC_PATH="$SPEC" python3 - <<'PY'
import json, os, sys
raw = open(os.environ["SPEC_PATH"]).read().strip()
obj = None
if raw.startswith("{"):
    obj = json.loads(raw)
else:
    try:
        import yaml
        obj = yaml.safe_load(raw)
    except Exception as e:
        sys.stderr.write(f"ERROR: spec is not valid JSON and PyYAML is unavailable ({e}).\n")
        sys.exit(2)
for k in ("provider", "mount", "root_creds_file"):
    if not obj.get(k):
        sys.stderr.write(f"ERROR: spec missing required field '{k}'\n"); sys.exit(2)
obj.setdefault("roles", [])
obj.setdefault("vault_policies", [])
obj.setdefault("lldap_groups", [])
print(json.dumps(obj))
PY
)

provider=$(printf '%s' "$SPEC_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["provider"])')
mount=$(printf '%s' "$SPEC_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["mount"])')
region=$(printf '%s' "$SPEC_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("region",""))')
root_creds=$(printf '%s' "$SPEC_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["root_creds_file"])')
test_role=$(printf '%s' "$SPEC_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("test_role",""))')
roles_json=$(printf '%s' "$SPEC_JSON" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["roles"]))')
policies_json=$(printf '%s' "$SPEC_JSON" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["vault_policies"]))')
groups_json=$(printf '%s' "$SPEC_JSON" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["lldap_groups"]))')

echo "=== chain-provider-onboard: provider=${provider} mount=${mount} ===" >&2

echo "[1/5] enable Vault secrets engine ${mount}/" >&2
eng_args=(--provider "$provider" --mount "$mount" --root-creds-file "$root_creds")
[[ -n "$region" ]] && eng_args+=(--region "$region")
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  [dry-run] would run vault-secrets-engine-enable.sh ${eng_args[*]}" >&2
else
  if bash "${SCRIPT_DIR}/vault-secrets-engine-enable.sh" "${eng_args[@]}" >/tmp/chain_po1.log 2>&1; then
    echo "  ok" >&2
  else
    rc=$?
    echo "  FAILED (rc=$rc):" >&2; tail -n 20 /tmp/chain_po1.log >&2
    chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-provider-onboard\",\"provider\":\"${provider}\",\"step\":1,\"result\":\"error\",\"rc\":$rc}"
    exit 3
  fi
fi

echo "[2/5] create Vault roles" >&2
role_count=0
role_fail=0
while IFS=$'\t' read -r r_name r_policy r_cred r_ttl r_mttl; do
  [[ -z "$r_name" ]] && continue
  role_count=$((role_count+1))
  ra=("$provider" "$r_name" "$r_policy" --mount "$mount")
  [[ -n "$r_cred" ]] && ra+=(--credential-type "$r_cred")
  [[ -n "$r_ttl" ]]  && ra+=(--ttl "$r_ttl")
  [[ -n "$r_mttl" ]] && ra+=(--max-ttl "$r_mttl")
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  [dry-run] would run vault-role-create.sh ${ra[*]}" >&2
    continue
  fi
  if bash "${SCRIPT_DIR}/vault-role-create.sh" "${ra[@]}" >/tmp/chain_po2.log 2>&1; then
    echo "  role ${r_name}: ok" >&2
  else
    rc=$?
    echo "  role ${r_name}: FAILED (rc=$rc)" >&2; tail -n 10 /tmp/chain_po2.log >&2
    role_fail=$((role_fail+1))
  fi
done < <(RJ="$roles_json" python3 -c '
import json, os
for r in json.loads(os.environ["RJ"]):
    print("\t".join([r.get("name",""), r.get("policy_file",""), r.get("credential_type",""), r.get("ttl",""), r.get("max_ttl","")]))
')
chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-provider-onboard\",\"provider\":\"${provider}\",\"step\":2,\"result\":\"$([[ $role_fail -eq 0 ]] && echo ok || echo partial)\",\"roles\":${role_count},\"failed\":${role_fail}}"
[[ $role_fail -gt 0 && "$DRY_RUN" -ne 1 ]] && { echo "ERROR: ${role_fail} role(s) failed" >&2; exit 3; }

echo "[3/5] create LLDAP groups" >&2
grp_count=0; grp_fail=0
while IFS=$'\t' read -r g_name; do
  [[ -z "$g_name" ]] && continue
  grp_count=$((grp_count+1))
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  [dry-run] would run lldap-group-create.sh --name ${g_name}" >&2
    continue
  fi
  if bash "${SCRIPT_DIR}/lldap-group-create.sh" --name "$g_name" >/tmp/chain_po3.log 2>&1; then
    echo "  group ${g_name}: ok" >&2
  else
    rc=$?
    echo "  group ${g_name}: FAILED (rc=$rc)" >&2; tail -n 10 /tmp/chain_po3.log >&2
    grp_fail=$((grp_fail+1))
  fi
done < <(GJ="$groups_json" python3 -c '
import json, os
for g in json.loads(os.environ["GJ"]):
    print(g.get("name",""))
')
chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-provider-onboard\",\"provider\":\"${provider}\",\"step\":3,\"result\":\"$([[ $grp_fail -eq 0 ]] && echo ok || echo partial)\",\"groups\":${grp_count},\"failed\":${grp_fail}}"
[[ $grp_fail -gt 0 && "$DRY_RUN" -ne 1 ]] && { echo "ERROR: ${grp_fail} group(s) failed" >&2; exit 3; }

echo "[4/5] apply Vault policies + bind to LLDAP groups" >&2
# Apply each named policy.
while IFS=$'\t' read -r p_name p_file; do
  [[ -z "$p_name" ]] && continue
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  [dry-run] would run vault-policy-apply.sh ${p_name} ${p_file}" >&2
  elif bash "${SCRIPT_DIR}/vault-policy-apply.sh" "$p_name" "$p_file" >/tmp/chain_po4a.log 2>&1; then
    echo "  policy ${p_name}: applied" >&2
  else
    rc=$?
    echo "  policy ${p_name}: FAILED (rc=$rc)" >&2; tail -n 10 /tmp/chain_po4a.log >&2
  fi
done < <(PJ="$policies_json" python3 -c '
import json, os
for p in json.loads(os.environ["PJ"]):
    print("\t".join([p.get("name",""), p.get("file","")]))
')
# Bind each LLDAP group -> its vault policy.
while IFS=$'\t' read -r g_name g_pol; do
  [[ -z "$g_name" || -z "$g_pol" ]] && continue
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  [dry-run] would run vault-ldap-group-bind.sh ${g_name} ${g_pol}" >&2
  elif bash "${SCRIPT_DIR}/vault-ldap-group-bind.sh" "$g_name" "$g_pol" >/tmp/chain_po4b.log 2>&1; then
    echo "  bind ${g_name} -> ${g_pol}: ok" >&2
  else
    rc=$?
    echo "  bind ${g_name} -> ${g_pol}: FAILED (rc=$rc)" >&2; tail -n 10 /tmp/chain_po4b.log >&2
  fi
done < <(GJ="$groups_json" python3 -c '
import json, os
for g in json.loads(os.environ["GJ"]):
    print("\t".join([g.get("name",""), g.get("vault_policy","")]))
')
chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-provider-onboard\",\"provider\":\"${provider}\",\"step\":4,\"result\":\"ok\"}"

echo "[5/5] validate end-to-end with a test credential request" >&2
if [[ "$SKIP_TEST_CRED" -eq 1 ]]; then
  echo "  skipped (--skip-test-cred)" >&2
  chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-provider-onboard\",\"provider\":\"${provider}\",\"step\":5,\"result\":\"skipped\"}"
elif [[ -z "$test_role" ]]; then
  echo "  skipped (spec has no test_role)" >&2
  chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-provider-onboard\",\"provider\":\"${provider}\",\"step\":5,\"result\":\"skipped\"}"
elif [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  [dry-run] would run vault-dynamic-cred-request.sh ${mount} ${test_role}" >&2
else
  if bash "${SCRIPT_DIR}/vault-dynamic-cred-request.sh" "$mount" "$test_role" >/tmp/chain_po5.log 2>&1; then
    lease_id=$(grep -oE '"lease_id":"[^"]*"' /tmp/chain_po5.log | head -1 | sed 's/"lease_id":"//;s/"//')
    echo "  ok: test credential issued (lease_id=${lease_id:-?})" >&2
    chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-provider-onboard\",\"provider\":\"${provider}\",\"step\":5,\"result\":\"ok\",\"lease\":\"${lease_id:-}\"}"
  else
    rc=$?
    echo "  FAILED (rc=$rc):" >&2; tail -n 20 /tmp/chain_po5.log >&2
    chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-provider-onboard\",\"provider\":\"${provider}\",\"step\":5,\"result\":\"error\",\"rc\":$rc}"
    exit 3
  fi
fi

echo "=== chain-provider-onboard complete: ${provider} (mount ${mount}) ===" >&2
exit 0
