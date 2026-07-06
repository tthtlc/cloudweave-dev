#!/usr/bin/env bash
# vault-audit-log-query.sh — query the Vault audit log for accesses to a path.
#
# Cloud Admin / Owner tool. Used to verify expected access patterns or
# investigate anomalous activity. Vault audit devices (file / syslog) record
# every request as a JSON line; this script filters the last N hours of
# audit-log entries by path prefix and (optionally) by auth identity.
#
# In this deployment Vault runs in a container and the file audit device (when
# enabled) writes to a path inside the container. The script therefore accepts
# either:
#   * --audit-file PATH       a host-side readable copy of the audit log, or
#   * --container <name>      docker exec into the Vault container and read its
#                             configured file-audit path (resolved via
#                             /sys/audit), or
#   * (default)               read /sys/audit to find the file device, then try
#                             docker exec vault cat <file>.
#
# Usage:
#   vault-audit-log-query.sh --path <prefix> [--hours N] [--user <id>]
#       [--audit-file PATH | --container <name>]
#       [--json] [--vault-token <t>]
#
# Options:
#   --path <prefix>    only entries whose request.path starts with this prefix
#   --hours N          look back N hours (default 24)
#   --user <id>        filter by auth.display_name / identity.id
#   --audit-file PATH  host-side audit log file
#   --container <name> Vault container name (default: vault)
#   --json             print raw JSONL matching entries
#   --vault-token <t>  needed to read /sys/audit if no --audit-file
#   -h, --help
#
# Exit codes:
#   0  query complete (may have zero matches)
#   2  usage
#   3  no Vault token / Vault unreachable / no audit device configured
#   4  audit log could not be read
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vault_common.sh
source "${SCRIPT_DIR}/vault_common.sh"

PATH_PREFIX=""
HOURS=24
USER_FILTER=""
AUDIT_FILE=""
CONTAINER="vault"
JSON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)        PATH_PREFIX="$2"; shift 2 ;;
    --hours)       HOURS="$2"; shift 2 ;;
    --user)        USER_FILTER="$2"; shift 2 ;;
    --audit-file)  AUDIT_FILE="$2"; shift 2 ;;
    --container)   CONTAINER="$2"; shift 2 ;;
    --json)        JSON=1; shift ;;
    --vault-token) VAULT_TOKEN_ARG="$2"; shift 2 ;;
    -h|--help)     sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$PATH_PREFIX" ]] || { echo "ERROR: --path is required" >&2; exit 2; }
[[ "$HOURS" =~ ^[0-9]+$ ]] || { echo "ERROR: --hours must be a number" >&2; exit 2; }

# Resolve the audit log source.
if [[ -z "$AUDIT_FILE" ]]; then
  # Read /sys/audit to find a file device and its path.
  vault_get "sys/audit"
  audit_http="$VAULT_HTTP_CODE"
  audit_body=$(cat "$VAULT_OUT")
  if [[ "$audit_http" == "200" ]]; then
    AUDIT_FILE=$(BODY="$audit_body" python3 -c '
import json, os
try:
    d = json.loads(os.environ["BODY"]).get("data", {})
    for k, v in d.items():
        if v.get("type") == "file":
            p = v.get("options", {}).get("file_path") or v.get("file_path")
            if p: print(p); break
except Exception:
    pass
')
  fi
  if [[ -n "$AUDIT_FILE" ]]; then
    echo "Vault audit file device path: ${AUDIT_FILE} (in container ${CONTAINER})." >&2
    if ! docker exec "$CONTAINER" test -r "$AUDIT_FILE" 2>/dev/null; then
      echo "ERROR: cannot read ${AUDIT_FILE} inside container '${CONTAINER}'." >&2
      echo "       Copy the audit log to the host and re-run with --audit-file PATH." >&2
      exit 4
    fi
  else
    echo "ERROR: no file audit device configured, and no --audit-file given." >&2
    echo "       Enable one with: vault audit enable file file_path=/vault/audit/audit.log" >&2
    exit 3
  fi
fi

# Stream the audit log (host file or via docker exec) into a python filter that:
#   - skips HMAC-prefixed lines it cannot decode (Vault audit logs are HMAC'd;
#     the *path* field is NOT hmac-shielded when using a non-obfuscating config,
#     but in obfuscate mode the path may be hmac'd. We match on the raw path
#     string when present, otherwise on the hmac path field verbatim.)
#   - keeps only entries within the last --hours based on auth.metadata / time.
#   - filters by path prefix and (optional) user.
stream_cmd=()
if [[ -f "$AUDIT_FILE" ]]; then
  stream_cmd=(cat "$AUDIT_FILE")
else
  stream_cmd=(docker exec "$CONTAINER" cat "$AUDIT_FILE")
fi

PATH_PREFIX_E="$PATH_PREFIX" \
HOURS_E="$HOURS" \
USER_E="$USER_FILTER" \
JSON_E="$JSON" \
"${stream_cmd[@]}" 2>/dev/null | python3 - <<'PY'
import json, os, sys, time, datetime

prefix = os.environ["PATH_PREFIX_E"]
hours = int(os.environ["HOURS_E"])
user = os.environ["USER_E"]
as_json = os.environ["JSON_E"] == "1"
cutoff = time.time() - hours * 3600

def parse_time(entry):
    # Vault audit entries have a top-level "time" field (RFC3339).
    t = entry.get("time")
    if not t: return None
    try:
        return datetime.datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None

matches = []
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: entry = json.loads(line)
    except Exception: continue
    req = entry.get("request") or {}
    path = req.get("path") or ""
    if not path.startswith(prefix): continue
    if user:
        auth = entry.get("auth") or {}
        ident = (auth.get("display_name") or auth.get("metadata", {}).get("username")
                 or (entry.get("identity") or {}).get("id") or "")
        if user not in ident: continue
    t = parse_time(entry)
    if t is not None and t < cutoff: continue
    matches.append(entry)

if as_json:
    for m in matches:
        print(json.dumps(m))
else:
    # Compact triage lines: time | type | path | who | result
    for m in matches:
        t = m.get("time", "")
        typ = m.get("type", "")
        req = m.get("request") or {}
        auth = m.get("auth") or {}
        who = auth.get("display_name") or (auth.get("metadata") or {}).get("username") or "-"
        err = (m.get("error") or "")
        op = req.get("operation") or req.get("method") or ""
        line = f"{t}  {typ:5}  {op:6}  {req.get('path','')}  by={who}"
        if err: line += f"  ERR={err}"
        print(line)
print(f"({len(matches)} matching entries in the last {hours}h under {prefix})", file=sys.stderr)
PY

vault_audit "{\"ts\":\"$(vault_now)\",\"actor\":\"${ACTOR}\",\"action\":\"audit-log-query\",\"path\":\"${PATH_PREFIX}\",\"hours\":${HOURS},\"user\":\"${USER_FILTER}\"}"
exit 0
