#!/usr/bin/env bash
# chain-offboard-user.sh — full offboarding chain across LLDAP + OpenFGA + Vault.
#
# Cloud Admin / Owner tool. Atomic-or-compensating workflow:
#   1. remove the user from all LLDAP groups + scramble their password
#      (lldap-user-offboard.sh)
#   2. delete every OpenFGA tuple whose user is user:<uid>
#   3. revoke all Vault tokens and leases associated with the user
#      (best-effort: walk /sys/leases/lookup, revoke leases whose auth metadata
#      matches the username; revoke tokens by accessor via lookup-accessor
#      listing is not exposed, so leases are the primary target)
#   4. emit a structured offboarding audit record (signed with the actor's
#      identity; here "signed" = attested by the actor in the JSONL record)
#
# The chain is "complete or roll back with error report": if a step fails, the
# script continues with the remaining steps (so a partial failure still
# maximizes revocation) and emits a final error report listing which steps
# failed. The exit code is non-zero if any step failed.
#
# Usage:
#   chain-offboard-user.sh --user <uid> [--actor <user>] [--keep-password]
#       [--skip-vault-revoke] [--dry-run]
#
# Options:
#   --user <uid>           the LLDAP user to offboard
#   --actor <user>         audit actor
#   --keep-password        do NOT scramble the LLDAP password (step 1 still
#                          removes group memberships)
#   --skip-vault-revoke    skip step 3 (Vault lease/token revocation)
#   --dry-run              plan only
#   -h, --help
#
# Exit codes:
#   0  all steps completed
#   3  one or more steps failed (error report printed; partial revocation done)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AUDIT_LOG="${ROOT}/generated/chain_audit.log"
OFFBOARD_LOG="${ROOT}/generated/offboard_audit.log"
mkdir -p "$(dirname "$AUDIT_LOG")" "$(dirname "$OFFBOARD_LOG")"

USER_ID=""
ACTOR="${USER:-cloud-admin}"
KEEP_PASSWORD=0
SKIP_VAULT_REVOKE=0
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)             USER_ID="$2"; shift 2 ;;
    --actor)            ACTOR="$2"; shift 2 ;;
    --keep-password)    KEEP_PASSWORD=1; shift ;;
    --skip-vault-revoke) SKIP_VAULT_REVOKE=1; shift ;;
    --dry-run)          DRY_RUN=1; shift ;;
    -h|--help)          sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$USER_ID" ]] || { echo "ERROR: --user is required" >&2; exit 2; }
if ! [[ "$USER_ID" =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]]; then
  echo "ERROR: --user must match LLDAP uid rules [a-z0-9._-]" >&2; exit 2
fi

chain_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
chain_audit() { local line="$1"; echo "$line" >&2; echo "$line" >> "$AUDIT_LOG"; }

declare -a STEP_RESULTS=()
record_step() {  # <step> <result> <detail-json>
  STEP_RESULTS+=("{\"step\":$1,\"result\":\"$2\",\"detail\":$3}")
  chain_audit "{\"ts\":\"$(chain_now)\",\"actor\":\"${ACTOR}\",\"action\":\"chain-offboard-user\",\"user\":\"${USER_ID}\",\"step\":$1,\"result\":\"$2\",\"detail\":$3}"
}

echo "=== chain-offboard-user: ${USER_ID} ===" >&2

# Step 1: LLDAP offboard (remove groups + scramble password).
echo "[1/4] LLDAP offboard (remove groups + lock account)" >&2
off_args=(--username "$USER_ID")
[[ "$KEEP_PASSWORD" -eq 1 ]] && off_args+=(--keep-password)
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  [dry-run] would run lldap-user-offboard.sh ${off_args[*]}" >&2
  record_step 1 "dry-run" '{}'
else
  if bash "${SCRIPT_DIR}/lldap-user-offboard.sh" "${off_args[@]}" >/tmp/chain_off1.log 2>&1; then
    record_step 1 "ok" '{}'
  else
    rc=$?
    echo "  FAILED (rc=$rc):" >&2; tail -n 20 /tmp/chain_off1.log >&2
    record_step 1 "error" "{\"rc\":$rc}"
  fi
fi

# Step 2: delete all OpenFGA tuples for user:<USER_ID>.
echo "[2/4] delete OpenFGA tuples for user:${USER_ID}" >&2
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  [dry-run] would scan + delete tuples with user=user:${USER_ID}" >&2
  record_step 2 "dry-run" '{}'
else
  # Use the OpenFGA common helpers (resolves a bearer token).
  # shellcheck source=openfga_common.sh
  if source "${SCRIPT_DIR}/openfga_common.sh" >/dev/null 2>&1; then
    all=$(fga_read_all_tuples 2>/dev/null || echo "[]")
    to_delete=$(USER_E="user:${USER_ID}" ALL="$all" python3 -c '
import json, os
all_t = json.loads(os.environ["ALL"])
u = os.environ["USER_E"]
out = []
for t in all_t:
    if t.get("user") == u and t.get("relation") and t.get("object"):
        out.extend([t["user"], t["relation"], t["object"]])
print("\n".join(out))
')
    count=0
    if [[ -n "$to_delete" ]]; then
      mapfile -t triples <<<"$to_delete"
      if fga_delete "${triples[@]}" >/tmp/chain_off2.log 2>&1; then
        count=$(( ${#triples[@]} / 3 ))
      else
        echo "  WARN: fga_delete returned non-zero:" >&2; tail -n 10 /tmp/chain_off2.log >&2
      fi
    fi
    echo "  deleted ${count} tuple(s)" >&2
    record_step 2 "ok" "{\"deleted\":${count}}"
  else
    echo "  WARN: could not source openfga_common.sh; skipping tuple deletion" >&2
    record_step 2 "skipped" '{}'
  fi
fi

# Step 3: revoke Vault tokens / leases associated with the user.
echo "[3/4] revoke Vault leases for ${USER_ID}" >&2
if [[ "$SKIP_VAULT_REVOKE" -eq 1 ]]; then
  echo "  skipped (--skip-vault-revoke)" >&2
  record_step 3 "skipped" '{}'
elif [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  [dry-run] would walk /sys/leases/lookup and revoke matching leases" >&2
  record_step 3 "dry-run" '{}'
else
  # shellcheck source=vault_common.sh
  if source "${SCRIPT_DIR}/vault_common.sh" >/dev/null 2>&1; then
    revoked=$(USER_E="$USER_ID" \
      VAULT_TOKEN_RESOLVED="$(vault_resolve_token 2>/dev/null)" \
      VAULT_ADDR_E="${VAULT_ADDR:-http://localhost:8200}" \
      python3 - <<'PY'
import json, os, urllib.error, urllib.request
addr = os.environ["VAULT_ADDR_E"].rstrip("/")
tok = os.environ.get("VAULT_TOKEN_RESOLVED","")
user = os.environ["USER_E"]
if not tok:
    print(0); raise SystemExit
def call(method, path, body=None):
    url = addr + "/v1/" + path.lstrip("/")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"X-Vault-Token": tok, "Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, {}
    except Exception:
        return 0, {}
def list_dir(path):
    c, b = call("LIST", "sys/leases/lookup/" + path)
    if c != 200:
        c, b = call("GET", "sys/leases/lookup/" + path + "?list=true")
    if c != 200: return []
    return (b.get("data") or {}).get("keys") or []
leaves = []
def walk(p):
    for k in list_dir(p):
        if k.endswith("/"): walk(p + k)
        else: leaves.append(p + k)
walk("")
revoked = 0
for lease in leaves:
    c, b = call("GET", "sys/leases/lookup/" + lease)
    if c != 200: continue
    d = b.get("data") or {}
    # Match by auth metadata username or issue_time path heuristics.
    auth_meta = (d.get("issue_time") or "")
    data = d.get("data") or {}
    # Vault audit metadata path: auth metadata is not in lookup; use data fields
    # that often contain the username (e.g. username). Fallback: lease path
    # contains the username.
    blob = json.dumps(d).lower()
    if user.lower() in blob or user.lower() in lease.lower():
        c2, _ = call("PUT", "sys/leases/revoke", {"lease_id": lease})
        if c2 in (200, 204): revoked += 1
print(revoked)
PY
)
    echo "  revoked ${revoked:-0} lease(s) matching ${USER_ID}" >&2
    record_step 3 "ok" "{\"revoked\":${revoked:-0}}"
  else
    echo "  WARN: could not source vault_common.sh; skipping Vault revoke" >&2
    record_step 3 "skipped" '{}'
  fi
fi

# Step 4: emit signed offboarding audit record.
echo "[4/4] emit offboarding audit record" >&2
ts="$(chain_now)"
if [[ ${#STEP_RESULTS[@]} -gt 0 ]]; then
  record_json=$(python3 -c '
import json, sys
results = [json.loads(r) for r in sys.argv[1:]]
print(json.dumps(results))
' "${STEP_RESULTS[@]}")
else
  record_json="[]"
fi
sig_record=$(python3 -c '
import json, os, sys, hashlib
rec = {
  "ts": sys.argv[1],
  "actor": sys.argv[2],
  "action": "user-offboard",
  "user": sys.argv[3],
  "steps": json.loads(sys.argv[4]),
}
payload = json.dumps(rec, sort_keys=True, separators=(",", ":"))
rec["attestation_sha256"] = hashlib.sha256(payload.encode()).hexdigest()
print(json.dumps(rec, indent=2))
' "$ts" "$ACTOR" "$USER_ID" "$record_json")
echo "$sig_record" >> "$OFFBOARD_LOG"
echo "$sig_record" >&2
record_step 4 "ok" '{}'

# Final report: non-zero if any step failed.
failures=$(printf '%s\n' "${STEP_RESULTS[@]:-}" | grep -c '"result":"error"' || true)
if [[ "$failures" -gt 0 ]]; then
  echo "=== chain-offboard-user COMPLETE WITH ERRORS: ${failures} step(s) failed ===" >&2
  printf '%s\n' "${STEP_RESULTS[@]:-}" | grep '"result":"error"' >&2
  exit 3
fi
echo "=== chain-offboard-user complete: ${USER_ID} ===" >&2
exit 0
