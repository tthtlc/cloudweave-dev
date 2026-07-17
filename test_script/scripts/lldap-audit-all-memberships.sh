#!/usr/bin/env bash
# lldap-audit-all-memberships.sh
# ==============================
# Dump the full LLDAP group→member matrix to a dated CSV. Monthly access-review
# artifact. One row per (group, member) pair; groups with no members still emit
# a header-style row with an empty member so the review can confirm an empty
# group is intentionally empty.
#
# Usage:
#   lldap-audit-all-memberships.sh [--out PATH] [--stdout]
#
# --out PATH : write CSV to PATH (default generated/audit/lldap_memberships_<date>.csv)
# --stdout   : also print the CSV to stdout (otherwise only the path is printed)
#
# Env (via scripts/lldap_common.sh):
#   LLDAP_URL, LLDAP_ADMIN_USER, LLDAP_LDAP_USER_PASS, LLDAP_AUDIT_LOG, LLDAP_ACTOR
#
# Exit codes:
#   0  CSV written
#   3  LLDAP admin auth failed
#   5  network / unexpected error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lldap_common.sh
source "${SCRIPT_DIR}/lldap_common.sh"

OPT_OUT=""; OPT_STDOUT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)    OPT_OUT="$2"; shift 2 ;;
    --stdout) OPT_STDOUT=1; shift ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

lldap_login || exit 3

out=$(mktemp); lldap_graphql '{"query":"{ groups { id displayName users { id email displayName } } }"}' "$out"; http="${LLDAP_HTTP_CODE}"
if ! [[ "${http}" =~ ^2 ]]; then
  echo "ERROR: GraphQL query failed (http=${http})" >&2; cat "$out" >&2; rm -f "$out"; exit 5
fi

date_tag="$(date -u +%Y%m%dZ)"
[[ -n "${OPT_OUT}" ]] || OPT_OUT="${REPO_ROOT}/generated/audit/lldap_memberships_${date_tag}.csv"
mkdir -p "$(dirname "${OPT_OUT}")"

python3 - "$out" "${OPT_OUT}" "${OPT_STDOUT}" <<'PY'
import csv, json, sys, datetime
src, path, to_stdout = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = json.load(open(src))
groups = (d.get("data") or {}).get("groups") or []
generated_at = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
rows = []
for g in groups:
    members = g.get("users") or []
    if not members:
        rows.append([generated_at, g.get("id"), g.get("displayName"), "", "", "", "EMPTY_GROUP"])
    for m in members:
        rows.append([generated_at, g.get("id"), g.get("displayName"),
                     m.get("id"), m.get("email"), m.get("displayName"), "MEMBER"])

def write_to(fh):
    w = csv.writer(fh)
    w.writerow(["generated_at", "group_id", "group_name", "user_id", "user_email",
                "user_displayname", "membership"])
    w.writerows(rows)

with open(path, "w", newline="") as fh:
    write_to(fh)
if to_stdout:
    write_to(sys.stdout)
print(f"audit CSV written: {path} ({len(rows)} rows across {len(groups)} groups)", file=sys.stderr)
PY
rm -f "$out"

lldap_audit "{\"ts\":\"$(lldap_now)\",\"event\":\"lldap_audit_all_memberships\",\"actor\":\"${ACTOR}\",\"out\":\"${OPT_OUT}\",\"result\":\"written\"}"
echo "${OPT_OUT}"
exit 0
