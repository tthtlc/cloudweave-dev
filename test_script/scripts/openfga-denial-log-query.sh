#!/usr/bin/env bash
# openfga-denial-log-query.sh — query authorization denial events in the last N hours.
#
# Aggregates denials from three sources:
#   1. libcloud REST auth audit log (container /app/data/auth_audit.log, JSONL):
#      any record whose event/decision indicates a denial (event=*deny*,
#      decision=deny, status=403, code=auth_provider_denied).
#   2. libcloud REST HTTP access log (docker logs): responses with status 403.
#   3. OpenFGA audit log (generated/openfga_audit.log, JSONL): action=check with
#      result=false (authorization denials at the FGA layer).
#
# Usage:
#   openfga-denial-log-query.sh [--hours N] [--json] [--actor <user>]
#   openfga-denial-log-query.sh --hours 24 --json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=openfga_common.sh
source "${SCRIPT_DIR}/openfga_common.sh"

HOURS=1
JSON_OUT=0
ACTOR="${LIBCLOUD_USER}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hours) HOURS="$2"; shift 2;;
    --json) JSON_OUT=1; shift;;
    --actor) ACTOR="$2"; shift 2;;
    -h|--help) sed -n '2,14p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ "$HOURS" =~ ^[0-9]+$ ]] || { echo "--hours must be an integer" >&2; exit 2; }

REST_CTR="${LIBCLOUD_REST_CONTAINER:-libcloud-rest-api}"
REST_AUDIT=$(docker exec "$REST_CTR" cat /app/data/auth_audit.log 2>/dev/null || true)
REST_403=$(docker logs --since "${HOURS}h" "$REST_CTR" 2>&1 | grep -E ' 403 (Forbidden|\")' || true)
FGA_AUDIT_LOG="${REPO_ROOT}/generated/openfga_audit.log"
FGA_AUDIT=$(cat "$FGA_AUDIT_LOG" 2>/dev/null || true)

python3 - "$HOURS" "$JSON_OUT" "$ACTOR" <<PY
import json, sys, datetime, re
hours, json_out, actor = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=hours)

def parse_ts(s):
    if not s: return None
    s = s.strip()
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ"):
        try:
            d = datetime.datetime.strptime(s, fmt)
            if d.tzinfo is None: d = d.replace(tzinfo=datetime.timezone.utc)
            return d
        except Exception: pass
    try:
        d = datetime.datetime.fromisoformat(s.replace("Z","+00:00"))
        return d if d.tzinfo else d.replace(tzinfo=datetime.timezone.utc)
    except Exception: return None

denials = []  # {ts, source, principal, resource, detail}

# 1. REST auth audit log: denial-ish records.
rest_audit = """${REST_AUDIT}"""
for line in rest_audit.splitlines():
    line = line.strip()
    if not line: continue
    try: rec = json.loads(line)
    except Exception: continue
    ts = parse_ts(rec.get("ts"))
    if not ts or ts < cutoff: continue
    ev = str(rec.get("event","")).lower()
    dec = str(rec.get("decision","")).lower()
    code = str(rec.get("code","")).lower()
    status = rec.get("status")
    is_denial = ("deny" in ev or "denied" in ev or dec == "deny"
                 or "auth_provider_denied" in code or status == 403)
    if is_denial:
        denials.append({"ts": rec.get("ts"), "source": "rest-auth-audit",
                        "principal": rec.get("principal") or rec.get("user") or "?",
                        "resource": rec.get("path") or rec.get("resource") or "?",
                        "detail": rec.get("code") or rec.get("event") or ""})

# 2. REST HTTP access log: 403 responses (uvicorn: '... "METHOD /path ..." 403 ...').
rest_403 = """${REST_403}"""
uv_re = re.compile(r'^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) .*?"(?P<m>[A-Z]+) (?P<path>[^ ]+).*?" 403 ')
for line in rest_403.splitlines():
    m = uv_re.search(line)
    if not m: continue
    ts = parse_ts(m.group("ts").replace(" ", "T") + "Z")
    if not ts or ts < cutoff: continue
    denials.append({"ts": m.group("ts"), "source": "rest-http-403", "principal": "-",
                    "resource": m.group("path"), "detail": m.group("m") + " 403"})

# 3. OpenFGA audit log: check result=false.
fga_audit = """${FGA_AUDIT}"""
for line in fga_audit.splitlines():
    line = line.strip()
    if not line: continue
    try: rec = json.loads(line)
    except Exception: continue
    if rec.get("action") != "check": continue
    if rec.get("result") not in (False, "false"): continue
    ts = parse_ts(rec.get("ts"))
    if not ts or ts < cutoff: continue
    t = rec.get("tuple", {})
    denials.append({"ts": rec.get("ts"), "source": "openfga-check",
                    "principal": (t.get("user") or "?"),
                    "resource": (t.get("relation","")+" "+t.get("object","")).strip() or "?",
                    "detail": "check denied"})

denials.sort(key=lambda d: d["ts"])
if json_out:
    print(json.dumps({"hours": hours, "count": len(denials), "denials": denials}, indent=2))
else:
    print(f"Authorization denials in last {hours}h: {len(denials)}")
    if denials:
        print(f"{'ts':<26} {'source':<18} {'principal':<24} {'resource':<30} detail")
        for d in denials:
            print(f"{d['ts']:<26} {d['source']:<18} {d['principal']:<24} {d['resource']:<30} {d['detail']}")
# audit the query itself
import os
print(json.dumps({"ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
      "actor": actor, "action": "denial-log-query", "hours": hours,
      "count": len(denials), "result": "ok"}), file=sys.stderr)
PY

# emit to the OpenFGA audit log as well
fga_audit "{\"ts\":\"$(fga_now)\",\"actor\":\"${ACTOR}\",\"action\":\"denial-log-query\",\"hours\":${HOURS},\"result\":\"ok\"}"
