#!/usr/bin/env python3
"""enumerate_openfga.py — enumerate all internals of the running OpenFGA server.

Walks the full OpenFGA HTTP API surface (see ../openfga_sdk.md) against the
server defined by ./generated/fga.env and prints a consolidated report:

  0. Health                 GET  /healthz
  1. Store/model admin      GET  /stores, GET /stores/{id},
                            GET  /stores/{id}/authorization-models[/{model}],
                            GET  /stores/{id}/assertions/{model}
  2. Tuple data access      POST /stores/{id}/read (all pages),
                            GET  /stores/{id}/changes (full history)
  3. Permission queries     POST /check (per stored tuple),
                            POST /batch-check (same set, cross-checked),
                            POST /expand (per unique object#relation),
                            POST /list-objects (per unique user/relation/type),
                            POST /list-users (per unique object#relation x user type)
  4. Interop/experimental   probe POST /stores/{id}/authzen/v1/evaluation

The script is READ-ONLY: the mutating management APIs (create/delete store,
write authorization model, write/delete tuples, write assertions) are listed
in the report header but deliberately not exercised against the live server.

Auth: OpenFGA runs with Dex OIDC (aud=libcloud-rest). Token resolution mirrors
test_script/scripts/openfga_common.sh:
  1. $FGA_API_TOKEN
  2. $SUPERADMIN_JWT
  3. <repo_root>/generated/tokens/superadmin.jwt (if unexpired)
Otherwise run ./test_script/scripts/superadmin_auth.sh first.

Usage:
  python3 openfga_postgres/enumerate_openfga.py [--store-id ID] [--max-queries N]
                                                [--out FILE] [--quiet]
Stdlib only; no third-party packages required.
"""

import argparse
import base64
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
FGA_ENV = SCRIPT_DIR / "generated" / "fga.env"
DEFAULT_TOKEN_PATH = REPO_ROOT / "generated" / "tokens" / "superadmin.jwt"
DEFAULT_OUT = SCRIPT_DIR / "generated" / "enumeration_report.json"

PAGE_SIZE = 100


# --------------------------------------------------------------------------- #
# Config / auth
# --------------------------------------------------------------------------- #

def load_env_file(path):
    vals = {}
    if path.is_file():
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            vals[k.strip()] = v.strip()
    return vals


def jwt_exp(token):
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return int(json.loads(base64.urlsafe_b64decode(payload)).get("exp", 0))
    except Exception:
        return 0


def resolve_token():
    import os
    for env in ("FGA_API_TOKEN", "SUPERADMIN_JWT"):
        tok = os.environ.get(env, "").strip()
        if tok:
            return tok, f"${env}"
    if DEFAULT_TOKEN_PATH.is_file():
        tok = DEFAULT_TOKEN_PATH.read_text().strip()
        if tok and jwt_exp(tok) > time.time():
            return tok, str(DEFAULT_TOKEN_PATH)
    return None, None


# --------------------------------------------------------------------------- #
# HTTP helpers
# --------------------------------------------------------------------------- #

class FgaClient:
    def __init__(self, base_url, token):
        self.base = base_url.rstrip("/")
        self.token = token

    def request(self, method, path, body=None, raw_query=None):
        url = f"{self.base}{path}"
        if raw_query:
            url += "?" + urllib.parse.urlencode(raw_query)
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": f"Bearer {self.token}",
        })
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                text = r.read().decode() or "{}"
                return r.status, json.loads(text)
        except urllib.error.HTTPError as e:
            try:
                return e.code, json.loads(e.read().decode() or "{}")
            except Exception:
                return e.code, {"error": "unparseable response body"}
        except urllib.error.URLError as e:
            return 0, {"error": str(e)}

    def get_paginated(self, path, key):
        """GET with continuation_token pagination; returns the merged list.

        Stops when the token is empty, when a page comes back empty, or when
        the token stops advancing. The empty-page/non-advancing guards matter
        for /changes: at the end of the changelog OpenFGA returns an empty
        page plus a *standing* token (meant for poll-style watching), which
        would otherwise loop forever.
        """
        items, token = [], ""
        while True:
            q = {"page_size": PAGE_SIZE}
            if token:
                q["continuation_token"] = token
            code, d = self.request("GET", path, raw_query=q)
            if code != 200:
                raise RuntimeError(f"GET {path} -> HTTP {code}: {d}")
            page = d.get(key, [])
            items.extend(page)
            new_token = d.get("continuation_token") or ""
            if not new_token or new_token == token or not page:
                return items
            token = new_token

    def post_paginated(self, path, key, base_body=None):
        items, token = [], ""
        while True:
            body = dict(base_body or {})
            body["page_size"] = PAGE_SIZE
            if token:
                body["continuation_token"] = token
            code, d = self.request("POST", path, body=body)
            if code != 200:
                raise RuntimeError(f"POST {path} -> HTTP {code}: {d}")
            page = d.get(key, [])
            items.extend(page)
            new_token = d.get("continuation_token") or ""
            if not new_token or new_token == token or not page:
                return items
            token = new_token


# --------------------------------------------------------------------------- #
# Enumeration
# --------------------------------------------------------------------------- #

def enumerate_server(client, args, report):
    out = report["sections"] = {}

    # -- 0. Health -------------------------------------------------------------
    code, _ = client.request("GET", "/healthz")
    out["health"] = {"endpoint": "GET /healthz", "http_code": code,
                     "ok": code == 200}

    # -- 1a. Stores ------------------------------------------------------------
    stores = client.get_paginated("/stores", "stores")
    out["stores"] = stores

    if args.store_id:
        stores = [s for s in stores if s["id"] == args.store_id]
        if not stores:
            raise RuntimeError(f"--store-id {args.store_id} not found on server")

    per_store = out["per_store"] = {}

    for store in stores:
        sid = store["id"]
        entry = per_store[sid] = {"name": store.get("name")}

        # -- 1b. Get store -----------------------------------------------------
        code, d = client.request("GET", f"/stores/{sid}")
        entry["get_store"] = {"http_code": code, "store": d}

        # -- 1c. Authorization models (all versions, fully fetched) ------------
        model_summaries = client.get_paginated(
            f"/stores/{sid}/authorization-models", "authorization_models")
        entry["authorization_models"] = model_summaries

        models_full = {}
        for m in model_summaries:
            code, d = client.request(
                "GET", f"/stores/{sid}/authorization-models/{m['id']}")
            if code == 200:
                models_full[m["id"]] = d.get("authorization_model", d)
        entry["authorization_models_full"] = models_full

        # -- 1d. Assertions (per model version) --------------------------------
        assertions = {}
        for m in model_summaries:
            code, d = client.request(
                "GET", f"/stores/{sid}/assertions/{m['id']}")
            assertions[m["id"]] = (d.get("assertions", []) if code == 200
                                   else {"http_code": code, "error": d})
        entry["assertions"] = assertions

        # -- 2a. Tuples (read all) ----------------------------------------------
        tuples = client.post_paginated(f"/stores/{sid}/read", "tuples")
        entry["tuples"] = tuples

        # -- 2b. Changes (full tuple history) -----------------------------------
        try:
            changes = client.get_paginated(f"/stores/{sid}/changes", "changes")
        except RuntimeError as e:
            changes = {"error": str(e)}
        entry["changes"] = changes

        # -- 3. Permission queries, derived from the stored tuples -------------
        # Use the configured model if set and present, else the newest version.
        model_ids = [m["id"] for m in model_summaries]
        model_id = (args.model_id if args.model_id in model_ids
                    else (model_summaries[0]["id"] if model_summaries else None))
        entry["queries_model_id"] = model_id

        keys = [t["key"] for t in tuples if "key" in t]
        entry["queries"] = run_queries(client, sid, model_id, keys,
                                       args.max_queries)

        # -- 4. Interop / experimental (AuthZEN) — probe only -------------------
        code, d = client.request("POST", f"/stores/{sid}/authzen/v1/evaluation",
                                 body={})
        entry["authzen_probe"] = {
            "endpoint": f"POST /stores/{sid}/authzen/v1/evaluation",
            "http_code": code,
            "enabled": code not in (404, 405, 501),
            "response": d,
        }

    return report


def run_queries(client, sid, model_id, keys, max_q):
    """Run check / batch-check / expand / list-objects / list-users derived
    from the stored tuple keys. Each category is capped at max_q calls."""
    res = {"checks": [], "batch_check": None, "expands": [],
           "list_objects": [], "list_users": []}
    if not model_id:
        res["note"] = "no authorization model on store; queries skipped"
        return res

    def body(extra):
        b = {"authorization_model_id": model_id}
        b.update(extra)
        return b

    # -- check: every stored tuple must hold -----------------------------------
    truncated = len(keys) > max_q
    for k in keys[:max_q]:
        code, d = client.request("POST", f"/stores/{sid}/check",
                                 body=body({"tuple_key": k}))
        res["checks"].append({"tuple_key": k, "http_code": code,
                              "allowed": d.get("allowed"),
                              "error": None if code == 200 else d})
    if truncated:
        res["checks_truncated"] = f"first {max_q} of {len(keys)} tuples"

    # -- batch-check: same set, cross-checked ----------------------------------
    # OpenFGA caps batch-check at 50 checks per request -> chunk.
    BATCH_CHUNK = 50
    if keys:
        per_corr, http_codes = {}, []
        for off in range(0, min(len(keys), max_q), BATCH_CHUNK):
            chunk = [{"tuple_key": k, "correlation_id": f"c{off + i}"}
                     for i, k in enumerate(keys[off:off + BATCH_CHUNK])]
            code, d = client.request("POST", f"/stores/{sid}/batch-check",
                                     body=body({"checks": chunk}))
            http_codes.append(code)
            if code == 200:
                per_corr.update({cid: v.get("allowed")
                                 for cid, v in d.get("result", {}).items()})
            else:
                res["batch_check"] = {
                    "http_code": code, "sent": len(keys[:max_q]),
                    "returned": len(per_corr), "results": per_corr,
                    "mismatches_vs_check": [], "error": d}
                break
        else:
            mismatches = []
            for i, chk in enumerate(res["checks"]):
                cid = f"c{i}"
                if cid in per_corr and per_corr[cid] != chk["allowed"]:
                    mismatches.append({"correlation_id": cid,
                                       "check": chk["allowed"],
                                       "batch_check": per_corr[cid]})
            res["batch_check"] = {
                "http_code": http_codes[-1], "sent": len(per_corr) or len(chunk),
                "returned": len(per_corr), "results": per_corr,
                "mismatches_vs_check": mismatches, "error": None,
            }

    # -- expand: every unique object#relation ----------------------------------
    obj_rel = sorted({(k["object"], k["relation"]) for k in keys})
    for obj, rel in obj_rel[:max_q]:
        code, d = client.request("POST", f"/stores/{sid}/expand",
                                 body=body({"tuple_key": {"object": obj,
                                                          "relation": rel}}))
        res["expands"].append({"object": obj, "relation": rel,
                               "http_code": code,
                               "tree": d.get("tree") if code == 200 else None,
                               "error": None if code == 200 else d})
    if len(obj_rel) > max_q:
        res["expands_truncated"] = f"first {max_q} of {len(obj_rel)} pairs"

    # -- list-objects: every unique (user, relation, object-type) --------------
    u_r_t = sorted({(k["user"], k["relation"], k["object"].split(":")[0])
                    for k in keys})
    for user, rel, typ in u_r_t[:max_q]:
        code, d = client.request(
            "POST", f"/stores/{sid}/list-objects",
            body=body({"user": user, "relation": rel, "type": typ}))
        res["list_objects"].append({
            "user": user, "relation": rel, "type": typ, "http_code": code,
            "objects": d.get("objects") if code == 200 else None,
            "error": None if code == 200 else d})
    if len(u_r_t) > max_q:
        res["list_objects_truncated"] = f"first {max_q} of {len(u_r_t)} combos"

    # -- list-users: every unique (object#relation) x user type ----------------
    # This OpenFGA version validates user_filters to exactly 1 item, so issue
    # one call per user type and merge the results per object#relation pair.
    user_types = sorted({k["user"].split(":")[0].split("#")[0] for k in keys})
    calls = 0
    budget_exhausted = False
    for obj, rel in obj_rel[:max_q]:
        otype, _, oid = obj.partition(":")
        merged, errors, first_code = [], [], None
        for utype in user_types:
            if calls >= max_q:
                budget_exhausted = True
                break
            calls += 1
            code, d = client.request(
                "POST", f"/stores/{sid}/list-users",
                body=body({"object": {"type": otype, "id": oid},
                           "relation": rel,
                           "user_filters": [{"type": utype}]}))
            if first_code is None:
                first_code = code
            if code == 200:
                merged.extend(d.get("users", []))
            else:
                errors.append({"user_type": utype, "http_code": code,
                               "error": d})
        res["list_users"].append({
            "object": obj, "relation": rel, "http_code": first_code,
            "users": merged if not errors or merged else None,
            "calls": len(user_types) if not budget_exhausted else None,
            "error": errors or None})
    if len(obj_rel) > max_q or budget_exhausted:
        res["list_users_truncated"] = (
            f"capped at {max_q} list-users calls"
            f" ({len(obj_rel)} object#relation pairs x {len(user_types)} user types)")

    return res


# --------------------------------------------------------------------------- #
# Report rendering
# --------------------------------------------------------------------------- #

def fmt_user(u):
    """Render a list-users entry: {"object"|"userset"|"typed_wildcard": ...}."""
    if not isinstance(u, dict):
        return str(u)
    if "object" in u:
        o = u["object"]
        return f"{o.get('type')}:{o.get('id')}"
    if "userset" in u:
        s = u["userset"]
        return f"{s.get('type')}:{s.get('id')}#{s.get('relation')}"
    if "typed_wildcard" in u:
        return f"{u['typed_wildcard'].get('type')}:*"
    return u.get("user", json.dumps(u))


def print_report(report, quiet=False):
    s = report["sections"]
    p = print

    p("=" * 72)
    p(f"OpenFGA enumeration — {report['server']}  ({report['timestamp']})")
    p(f"token source: {report['token_source']}")
    p("read-only: mutating APIs (create/delete store, write model/assertions/")
    p("tuples) are part of the API surface but are NOT exercised here.")
    p("=" * 72)

    p(f"\n[0] Health: GET /healthz -> HTTP {s['health']['http_code']}"
      f" ({'ok' if s['health']['ok'] else 'FAIL'})")

    p(f"\n[1] Stores: {len(s['stores'])} found")
    for st in s["stores"]:
        p(f"  - {st['id']}  name={st.get('name')!r}  created={st.get('created_at')}")

    for sid, e in s["per_store"].items():
        p(f"\n{'-' * 72}\nStore {sid} ({e.get('name')})")

        p(f"\n  Authorization models: {len(e['authorization_models'])} version(s)")
        for m in e["authorization_models"]:
            full = e["authorization_models_full"].get(m["id"], {})
            types = {t["type"]: sorted(r for r in t.get("relations", {}))
                     for t in full.get("type_definitions", [])}
            p(f"    - {m['id']}  schema={m.get('schema_version')}")
            if not quiet:
                for t, rels in types.items():
                    p(f"        type {t!r}: relations={rels}")

        n_assert = {mid: (len(a) if isinstance(a, list) else a)
                    for mid, a in e["assertions"].items()}
        p(f"\n  Assertions per model version: "
          f"{ {mid: n for mid, n in n_assert.items()} }")

        tuples = e["tuples"]
        p(f"\n[2] Tuples: {len(tuples)} stored (POST /read)")
        for t in (tuples if not quiet else tuples[:20]):
            k = t["key"]
            p(f"    {k['user']}  {k['relation']}  {k['object']}"
              f"   ({t.get('timestamp', '')})")
        if quiet and len(tuples) > 20:
            p(f"    ... and {len(tuples) - 20} more (see JSON report)")

        changes = e["changes"]
        if isinstance(changes, list):
            writes = sum(1 for c in changes if "WRITE" in c.get("operation", ""))
            dels = sum(1 for c in changes if "DELETE" in c.get("operation", ""))
            p(f"\n  Change history: {len(changes)} change(s)"
              f" ({writes} writes, {dels} deletes)")
        else:
            p(f"\n  Change history: unavailable: {changes}")

        q = e["queries"]
        p(f"\n[3] Permission queries (model {e['queries_model_id']})")
        if "note" in q:
            p(f"    {q['note']}")
        else:
            ok = sum(1 for c in q["checks"] if c["allowed"] is True)
            bad = [c for c in q["checks"] if c["allowed"] is not True]
            p(f"    check:        {len(q['checks'])} run, {ok} allowed"
              + (f", {len(bad)} NOT allowed (unexpected for stored tuples!)"
                 if bad else "")
              + (f"  [{q['checks_truncated']}]" if q.get("checks_truncated") else ""))
            for c in bad:
                p(f"      DENIED: {c['tuple_key']} (http {c['http_code']})"
                  f" {c.get('error') or ''}")
            bc = q["batch_check"]
            if bc:
                p(f"    batch-check:  HTTP {bc['http_code']}, "
                  f"{bc['returned']}/{bc['sent']} results, "
                  f"{len(bc['mismatches_vs_check'])} mismatch(es) vs check")
            exp_err = sum(1 for x in q["expands"] if x["error"])
            p(f"    expand:       {len(q['expands'])} object#relation pair(s)"
              f" expanded, {exp_err} error(s)"
              + (f"  [{q['expands_truncated']}]" if q.get("expands_truncated") else ""))
            if not quiet:
                for x in q["expands"]:
                    p(f"      {x['object']}#{x['relation']}")
            lo_err = sum(1 for x in q["list_objects"] if x["error"])
            total_objs = sum(len(x["objects"] or []) for x in q["list_objects"])
            p(f"    list-objects: {len(q['list_objects'])} user/relation/type "
              f"combo(s), {total_objs} object(s) total, {lo_err} error(s)"
              + (f"  [{q['list_objects_truncated']}]"
                 if q.get("list_objects_truncated") else ""))
            if not quiet:
                for x in q["list_objects"]:
                    p(f"      {x['user']} {x['relation']} {x['type']}"
                      f" -> {x['objects'] if x['objects'] is not None else x['error']}")
            lu_err = sum(1 for x in q["list_users"] if x["error"])
            p(f"    list-users:   {len(q['list_users'])} object#relation pair(s),"
              f" {lu_err} error(s)"
              + (f"  [{q['list_users_truncated']}]" if q.get("list_users_truncated") else ""))
            if not quiet:
                for x in q["list_users"]:
                    users = [fmt_user(u) for u in (x["users"] or [])]
                    p(f"      {x['object']}#{x['relation']}"
                      f" -> {users if x['users'] is not None else x['error']}")

        az = e["authzen_probe"]
        p(f"\n[4] AuthZEN (experimental): HTTP {az['http_code']} — "
          f"{'ENABLED' if az['enabled'] else 'not enabled on this server'}")


# --------------------------------------------------------------------------- #

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--store-id", help="enumerate only this store "
                    "(default: all stores on the server)")
    ap.add_argument("--model-id", help="model to use for permission queries "
                    "(default: FGA_MODEL_ID from fga.env if present, else newest)")
    ap.add_argument("--max-queries", type=int, default=500,
                    help="cap per query category (default 500)")
    ap.add_argument("--out", default=str(DEFAULT_OUT),
                    help=f"JSON report path (default {DEFAULT_OUT})")
    ap.add_argument("--quiet", action="store_true",
                    help="summary only on stdout (full data still in JSON report)")
    args = ap.parse_args()

    env = load_env_file(FGA_ENV)
    import os
    api_url = os.environ.get("FGA_API_URL") or env.get("FGA_API_URL",
                                                       "http://localhost:8080")
    args.model_id = (args.model_id or os.environ.get("FGA_MODEL_ID")
                     or env.get("FGA_MODEL_ID"))

    token, token_source = resolve_token()
    if not token:
        print("FATAL: no OpenFGA bearer token. Set FGA_API_TOKEN / SUPERADMIN_JWT,\n"
              "       ensure generated/tokens/superadmin.jwt is unexpired, or run\n"
              "       ./test_script/scripts/superadmin_auth.sh", file=sys.stderr)
        return 3

    client = FgaClient(api_url, token)
    report = {
        "server": api_url,
        "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "token_source": token_source,
        "note": "read-only enumeration; mutating management APIs not exercised",
    }

    try:
        enumerate_server(client, args, report)
    except RuntimeError as e:
        print(f"FATAL: {e}", file=sys.stderr)
        return 4

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, indent=2) + "\n")

    print_report(report, quiet=args.quiet)
    print(f"\nFull JSON report: {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
