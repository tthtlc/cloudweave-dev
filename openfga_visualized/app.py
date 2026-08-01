#!/usr/bin/env python3
"""
OpenFGA RBAC Visualizer - single-file Flask dashboard with its own SSO login.

The dashboard is a separate application: it shows its own authentication
screen and never picks up previously authenticated credentials (no token
files, no shared sessions). Users sign in via the project's Dex SSO
(authorization-code flow); the resulting JWT is kept in a server-side
session and used as the bearer token for OpenFGA, so every API call is
made as the logged-in user. OpenFGA validates the token against
issuer + audience, so the app authenticates through the existing
`libcloud-rest` OIDC client (that is the audience OpenFGA pins).

Sign-in is restricted to the LLDAP superadmin account (see SUPERADMIN_*
below): logins through any other Dex connector (Google, GitHub) or any
other LLDAP user are denied at the OAuth callback.

Once authenticated it renders:
  * the full object hierarchy as an interactive D3 collapsible tree
  * a permission matrix (users x relations) for any object, showing how
    permissions propagate through the model (direct grant vs inherited)
  * an ad-hoc permission checker plus "everything user X can do"
  * the authorization model with human-readable rewrite rules

Configuration (environment variables; defaults match the libcloud project):
  OPENFGA_API_URL      default http://localhost:8080
  OPENFGA_STORE_ID     default 01KXFQ6JWFD2MZKFDFSHYNNNXE
  OPENFGA_MODEL_ID     default 01KXWWZY8424AMK2B443FH7TQ0
  OIDC_ISSUER          default http://login.cloudweave.xyz:5556/dex (derived from PUBLIC_HOSTNAME)
  OIDC_CLIENT_ID       default libcloud-rest (must match OpenFGA's audience)
  OIDC_CLIENT_SECRET   default: read from DEX_CONFIG for OIDC_CLIENT_ID
  DEX_CONFIG           default ../dex/config.yaml
  OAUTH_REDIRECT_URI   default: derived from the request host (must be one of
                       the redirect URIs registered for the client in Dex)
  SUPERADMIN_EMAIL     default superadmin@libcloud.local (LLDAP mail attribute);
                       only this account may sign in
  SUPERADMIN_SUB       default unset; exact Dex `sub` of the LLDAP superadmin
                       (strongest gate - overrides SUPERADMIN_EMAIL when set)
  FLASK_SECRET_KEY     default: generated and stored in ./.flask_secret
  PORT                 dashboard port, default 5050

Run:  python3 app.py   ->  http://localhost:5050
"""

import os
import secrets
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from functools import wraps
from urllib.parse import quote, urlencode

import jwt
import requests
import yaml
from flask import Flask, Response, jsonify, redirect, request, session
from jwt import PyJWKClient

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

API_URL = os.environ.get("OPENFGA_API_URL", "http://localhost:8080").rstrip("/")
STORE_ID = os.environ.get("OPENFGA_STORE_ID", "01KXFQ6JWFD2MZKFDFSHYNNNXE")
MODEL_ID = os.environ.get("OPENFGA_MODEL_ID", "01KXWWZY8424AMK2B443FH7TQ0")
PORT = int(os.environ.get("PORT", "5050"))

OIDC_ISSUER = os.environ.get(
    "OIDC_ISSUER",
    "http://"
    + os.environ.get("PUBLIC_HOSTNAME", "login.cloudweave.xyz")
    + ":5556/dex",
).rstrip("/")
OIDC_CLIENT_ID = os.environ.get("OIDC_CLIENT_ID", "libcloud-rest")
OIDC_SCOPES = os.environ.get("OIDC_SCOPES", "openid profile email groups")

# Access gate: only the LLDAP superadmin may sign in. Dex deliberately
# issues the same token shape for every connector (lldap/google/github) --
# no connector id and no role/group claims in the JWT -- so the gate pins
# the superadmin's identity claims instead. SUPERADMIN_SUB (the exact Dex
# `sub`, a hash of user id + connector id) is the strongest pin: only the
# LLDAP account can produce it. Without it we fall back to the LLDAP `mail`
# attribute, which only LLDAP users under dc=libcloud,dc=local carry.
SUPERADMIN_EMAIL = os.environ.get(
    "SUPERADMIN_EMAIL", "superadmin@libcloud.local"
).lower()
SUPERADMIN_SUB = os.environ.get("SUPERADMIN_SUB", "")

_here = os.path.dirname(os.path.abspath(__file__))
DEX_CONFIG = os.environ.get("DEX_CONFIG", os.path.join(_here, "..", "dex", "config.yaml"))

CACHE_TTL = 30  # seconds for model / tuple cache
CHECK_WORKERS = 8
SESSION_LIFETIME = timedelta(hours=12)

app = Flask(__name__)
app.permanent_session_lifetime = SESSION_LIFETIME


def _load_secret_key():
    key = os.environ.get("FLASK_SECRET_KEY")
    if key:
        return key
    path = os.path.join(_here, ".flask_secret")
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        pass
    key = secrets.token_hex(32)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.write(fd, key.encode())
    os.close(fd)
    return key


app.secret_key = _load_secret_key()


def client_secret():
    """OAuth client secret: env override, else read from the Dex config."""
    sec = os.environ.get("OIDC_CLIENT_SECRET")
    if sec:
        return sec.strip()
    try:
        with open(DEX_CONFIG) as fh:
            cfg = yaml.safe_load(fh)
        for c in cfg.get("staticClients", []):
            if c.get("id") == OIDC_CLIENT_ID:
                return c.get("secret", "")
    except (OSError, yaml.YAMLError):
        pass
    return ""


_discovery_cache = {}


def discovery():
    """OIDC endpoints from the issuer's discovery document (cached)."""
    if not _discovery_cache:
        try:
            r = requests.get(
                f"{OIDC_ISSUER}/.well-known/openid-configuration", timeout=10
            )
            if r.status_code == 200:
                _discovery_cache.update(r.json())
        except requests.RequestException:
            pass
    return {
        "authorization_endpoint": _discovery_cache.get(
            "authorization_endpoint", f"{OIDC_ISSUER}/auth"
        ),
        "token_endpoint": _discovery_cache.get("token_endpoint", f"{OIDC_ISSUER}/token"),
        "jwks_uri": _discovery_cache.get("jwks_uri", f"{OIDC_ISSUER}/keys"),
    }


# --------------------------------------------------------------------------
# Server-side login sessions (the Flask cookie only carries an opaque id)
# --------------------------------------------------------------------------

_sessions = {}  # sid -> {"id_token": str, "user": {...}, "expires": float}


def current_session():
    sid = session.get("sid")
    ent = _sessions.get(sid) if sid else None
    if not ent or ent["expires"] < time.time():
        return None
    return ent


def get_token():
    """Bearer token of the logged-in dashboard user (never from disk/env)."""
    ent = current_session()
    return ent["id_token"] if ent else None


class FGAError(Exception):
    """Raised when the OpenFGA server answers with an error."""


class FGAAuthError(FGAError):
    """OpenFGA rejected the session token (401) - force re-login."""


def _headers(token=None):
    # `token` must be passed explicitly when calling from worker threads:
    # the Flask session proxy only exists in the request thread.
    h = {"Content-Type": "application/json"}
    tok = token or get_token()
    if tok:
        h["Authorization"] = "Bearer " + tok
    return h


def fga_get(path, token=None):
    url = f"{API_URL}/stores/{STORE_ID}/{path}"
    try:
        r = requests.get(url, headers=_headers(token), timeout=15)
    except requests.RequestException as exc:
        raise FGAError(f"cannot reach OpenFGA at {API_URL}: {exc}")
    if r.status_code == 401:
        raise FGAAuthError(f"OpenFGA rejected the login token: {r.text[:200]}")
    if r.status_code != 200:
        raise FGAError(f"GET {path} -> {r.status_code}: {r.text[:300]}")
    return r.json()


def fga_post(path, body, token=None):
    url = f"{API_URL}/stores/{STORE_ID}/{path}"
    try:
        r = requests.post(url, json=body, headers=_headers(token), timeout=30)
    except requests.RequestException as exc:
        raise FGAError(f"cannot reach OpenFGA at {API_URL}: {exc}")
    if r.status_code == 401:
        raise FGAAuthError(f"OpenFGA rejected the login token: {r.text[:200]}")
    if r.status_code != 200:
        raise FGAError(f"POST {path} -> {r.status_code}: {r.text[:300]}")
    return r.json()


# --------------------------------------------------------------------------
# OpenFGA data access (with a small TTL cache)
# --------------------------------------------------------------------------

_cache = {}


def cached(key, fn):
    ent = _cache.get(key)
    if ent and ent[0] > time.time():
        return ent[1]
    val = fn()
    _cache[key] = (time.time() + CACHE_TTL, val)
    return val


def get_model():
    def load():
        if MODEL_ID:
            return fga_get(f"authorization-models/{MODEL_ID}")["authorization_model"]
        return fga_get("authorization-models?page_size=1")["authorization_models"][0]

    return cached("model", load)


def get_tuples():
    def load():
        out, cont = [], None
        while True:
            body = {"page_size": 100}
            if cont:
                body["continuation_token"] = cont
            data = fga_post("read", body)
            for t in data.get("tuples", []):
                k = t["key"]
                out.append(
                    {
                        "user": k["user"],
                        "relation": k["relation"],
                        "object": k["object"],
                        "timestamp": t.get("timestamp"),
                    }
                )
            cont = data.get("continuation_token")
            if not cont:
                return out

    return cached("tuples", load)


def fga_check(user, relation, obj, token=None):
    body = {"tuple_key": {"user": user, "relation": relation, "object": obj}}
    if MODEL_ID:
        body["authorization_model_id"] = MODEL_ID
    return fga_post("check", body, token)


def fga_expand(obj, relation):
    body = {"tuple_key": {"object": obj, "relation": relation}}
    if MODEL_ID:
        body["authorization_model_id"] = MODEL_ID
    return fga_post("expand", body)


# --------------------------------------------------------------------------
# Model helpers
# --------------------------------------------------------------------------


def _get(d, *names):
    for n in names:
        if isinstance(d, dict) and n in d:
            return d[n]
    return None


def summarize_rewrite(rw):
    """Turn an OpenFGA rewrite-rule AST into a short human-readable string."""
    if not rw:
        return "-"
    if "this" in rw:
        return "direct"
    cu = _get(rw, "computedUserset", "computed_userset")
    if cu is not None:
        return "= %s" % (cu.get("relation") or "?")
    tt = _get(rw, "tupleToUserset", "tuple_to_userset")
    if tt is not None:
        ts = (_get(tt, "tupleset") or {}).get("relation", "?")
        cu2 = (_get(tt, "computedUserset", "computed_userset") or {}).get("relation", "?")
        return "%s -> %s" % (ts, cu2)
    for op, sym in (("union", " U "), ("intersection", " & "), ("exclusion", " - ")):
        if op in rw:
            kids = [summarize_rewrite(c) for c in rw[op].get("children", [])]
            return "(" + sym.join(kids) + ")" if len(kids) > 1 else (kids[0] if kids else op)
    return str(rw)[:80]


def model_types(model):
    """Index type definitions by type name."""
    return {td["type"]: td for td in model.get("type_definitions", [])}


def relations_of(model, obj_type):
    td = model_types(model).get(obj_type) or {}
    return list((td.get("relations") or {}).keys())


def model_summary(model):
    out = []
    for td in model.get("type_definitions", []):
        rels = []
        md_rels = ((td.get("metadata") or {}).get("relations")) or {}
        for name, rw in (td.get("relations") or {}).items():
            direct = [
                t.get("type")
                for t in (md_rels.get(name) or {}).get("directly_related_user_types", [])
                if t.get("type")
            ]
            rels.append(
                {"name": name, "summary": summarize_rewrite(rw), "direct": direct}
            )
        out.append({"type": td["type"], "relations": rels})
    return out


# --------------------------------------------------------------------------
# Graph derivation
# --------------------------------------------------------------------------


def split_ref(ref):
    """Split 'type:name' into (type, name)."""
    t, _, n = ref.partition(":")
    return t, n


def build_graph(tuples):
    nodes, hierarchy, grants = {}, [], []
    for t in tuples:
        u, r, o = t["user"], t["relation"], t["object"]
        ot, on = split_ref(o)
        nodes[o] = {"id": o, "type": ot, "name": on}
        if u.startswith("user:"):
            ut, un = split_ref(u)
            nodes[u] = {"id": u, "type": "user", "name": un}
            grants.append({"user": u, "relation": r, "object": o})
        else:
            parent = u.split("#")[0]  # userset refs like obj#relation -> obj
            pt, pn = split_ref(parent)
            nodes.setdefault(parent, {"id": parent, "type": pt, "name": pn})
            hierarchy.append({"parent": parent, "child": o, "relation": r})
    children = {h["child"] for h in hierarchy}
    roots = [n for n in nodes if n not in children and not n.startswith("user:")]
    return {"nodes": sorted(nodes.values(), key=lambda n: n["id"]),
            "hierarchy": hierarchy, "grants": grants, "roots": sorted(roots)}


# --------------------------------------------------------------------------
# API routes
# --------------------------------------------------------------------------


def drop_session():
    sid = session.pop("sid", None)
    if sid:
        _sessions.pop(sid, None)


def require_auth(fn):
    """API routes: valid dashboard login session required."""

    @wraps(fn)
    def wrapper(*a, **kw):
        if not current_session():
            drop_session()
            return jsonify(
                {"error": "authentication required", "auth_required": True}
            ), 401
        return fn(*a, **kw)

    return wrapper


def api(fn):
    """Wrap an API route: FGAAuthError -> 401 (re-login), FGAError -> 502."""

    @wraps(fn)
    def wrapper(*a, **kw):
        try:
            return fn(*a, **kw)
        except FGAAuthError as exc:
            drop_session()
            return jsonify({"error": str(exc), "auth_required": True}), 401
        except FGAError as exc:
            return jsonify({"error": str(exc)}), 502

    return wrapper


@app.get("/api/config")
@require_auth
def api_config():
    ent = current_session()
    return jsonify(
        {
            "api_url": API_URL,
            "store_id": STORE_ID,
            "model_id": MODEL_ID or "(latest)",
            "user": ent["user"],
        }
    )


@app.get("/api/model")
@require_auth
@api
def api_model():
    model = get_model()
    return jsonify(
        {
            "id": model.get("id"),
            "schema_version": model.get("schema_version"),
            "types": model_summary(model),
        }
    )


@app.get("/api/tuples")
@require_auth
@api
def api_tuples():
    return jsonify({"tuples": get_tuples()})


@app.get("/api/graph")
@require_auth
@api
def api_graph():
    return jsonify(build_graph(get_tuples()))


@app.get("/api/check")
@require_auth
@api
def api_check():
    user = request.args.get("user", "").strip()
    relation = request.args.get("relation", "").strip()
    obj = request.args.get("object", "").strip()
    if not (user and relation and obj):
        return jsonify({"error": "user, relation and object are required"}), 400
    res = fga_check(user, relation, obj)
    return jsonify(
        {
            "user": user,
            "relation": relation,
            "object": obj,
            "allowed": bool(res.get("allowed")),
            "resolution": res.get("resolution", ""),
        }
    )


@app.get("/api/expand")
@require_auth
@api
def api_expand():
    obj = request.args.get("object", "").strip()
    relation = request.args.get("relation", "").strip()
    if not (obj and relation):
        return jsonify({"error": "object and relation are required"}), 400
    return jsonify(fga_expand(obj, relation))


@app.get("/api/matrix")
@require_auth
@api
def api_matrix():
    """users x relations check grid for one object (shows propagation)."""
    obj = request.args.get("object", "").strip()
    if not obj:
        return jsonify({"error": "object is required"}), 400
    model = get_model()
    tuples = get_tuples()
    otype = split_ref(obj)[0]
    rels = relations_of(model, otype)
    if not rels:
        return jsonify({"error": f"unknown object type '{otype}'"}), 400
    users = sorted({t["user"] for t in tuples if t["user"].startswith("user:")})
    direct = sorted(
        [t["user"], t["relation"]]
        for t in tuples
        if t["object"] == obj and t["user"].startswith("user:")
    )
    pairs = [(u, r) for u in users for r in rels]
    tok = get_token()  # capture in the request thread; session is not
    # accessible from the worker threads below

    def job(p):
        u, r = p
        try:
            ok = bool(fga_check(u, r, obj, token=tok).get("allowed"))
        except FGAError:
            ok = None
        return u, r, ok

    cells = {}
    with ThreadPoolExecutor(max_workers=CHECK_WORKERS) as ex:
        for u, r, ok in ex.map(job, pairs):
            cells.setdefault(u, {})[r] = ok
    return jsonify(
        {"object": obj, "relations": rels, "users": users, "cells": cells,
         "direct": direct}
    )


@app.get("/api/user_permissions")
@require_auth
@api
def api_user_permissions():
    """Everything the given user is allowed to do, grouped by object."""
    user = request.args.get("user", "").strip()
    if not user:
        return jsonify({"error": "user is required"}), 400
    model = get_model()
    graph = build_graph(get_tuples())
    objects = [n["id"] for n in graph["nodes"] if n["type"] != "user"]
    rel_by_type = {t: relations_of(model, t) for t in model_types(model)}
    pairs = [
        (o, r) for o in objects for r in rel_by_type.get(split_ref(o)[0], [])
    ]
    tok = get_token()  # capture before entering worker threads

    def job(p):
        o, r = p
        try:
            ok = bool(fga_check(user, r, o, token=tok).get("allowed"))
        except FGAError:
            ok = False
        return o, r, ok

    allowed = {}
    with ThreadPoolExecutor(max_workers=CHECK_WORKERS) as ex:
        for o, r, ok in ex.map(job, pairs):
            if ok:
                allowed.setdefault(o, []).append(r)
    return jsonify({"user": user, "objects": objects, "allowed": allowed})


HTML_PAGE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>OpenFGA RBAC Visualizer</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<script src="/static/d3.v7.min.js"></script>
<script>window.d3 || document.write('<script src="https:\/\/d3js.org\/d3.v7.min.js"><\/script>')</script>
<style>
  :root {
    --bg: #f1f5f9; --card: #ffffff; --ink: #0f172a; --muted: #64748b;
    --line: #cbd5e1; --accent: #2563eb; --ok: #16a34a; --bad: #dc2626;
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--ink);
         font: 14px/1.45 -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
  header { background: #0f172a; color: #e2e8f0; padding: 10px 18px;
           display: flex; align-items: center; gap: 16px; flex-wrap: wrap; }
  header h1 { font-size: 17px; margin: 0; font-weight: 600; }
  header .cfg { font-size: 12px; color: #94a3b8; font-family: ui-monospace, Menlo, Consolas, monospace; }
  nav { margin-left: auto; display: flex; gap: 6px; }
  nav button { background: #1e293b; color: #cbd5e1; border: 1px solid #334155;
               padding: 6px 14px; border-radius: 6px; cursor: pointer; font-size: 13px; }
  nav button.active { background: var(--accent); border-color: var(--accent); color: #fff; }
  #banner { background: #fef2f2; color: var(--bad); border-bottom: 1px solid #fecaca;
            padding: 8px 18px; font-size: 13px; display: none; white-space: pre-wrap; }
  main { padding: 16px 18px 40px; }
  section.tab { display: none; }
  section.tab.active { display: block; }
  .card { background: var(--card); border: 1px solid var(--line); border-radius: 10px;
          padding: 14px 16px; margin-bottom: 14px; }
  .controls { display: flex; gap: 14px; align-items: center; flex-wrap: wrap; margin-bottom: 10px; }
  .controls label { font-size: 13px; color: var(--muted); display: flex; gap: 6px; align-items: center; }
  button.act { background: var(--accent); color: #fff; border: 0; border-radius: 6px;
               padding: 6px 12px; cursor: pointer; font-size: 13px; }
  button.sec { background: #e2e8f0; color: var(--ink); border: 0; border-radius: 6px;
               padding: 6px 12px; cursor: pointer; font-size: 13px; }
  select, input[type=text] { padding: 6px 8px; border: 1px solid var(--line);
               border-radius: 6px; font-size: 13px; background: #fff; min-width: 220px; }
  .legend { display: flex; gap: 14px; flex-wrap: wrap; font-size: 12px; color: var(--muted); }
  .legend .dot { display: inline-block; width: 10px; height: 10px; border-radius: 50%;
                 margin-right: 5px; vertical-align: -1px; }
  /* hierarchy */
  #tree-wrap { overflow: hidden; border: 1px solid var(--line); border-radius: 10px; background: #fff; }
  svg#tree { display: block; width: 100%; height: 640px; cursor: grab; }
  .link { fill: none; stroke: #94a3b8; stroke-width: 1.3px; }
  .link-label { font-size: 10px; fill: #64748b; font-style: italic; }
  .node circle { stroke: #fff; stroke-width: 1.5px; cursor: pointer; }
  .node text { font-size: 12px; }
  .node.user text { fill: #64748b; }
  .shared-tag { font-size: 10px; fill: #9333ea; }
  /* matrix */
  table.matrix { border-collapse: collapse; font-size: 12px; }
  table.matrix th, table.matrix td { border: 1px solid var(--line); padding: 4px 7px; text-align: center; }
  table.matrix th.rel { writing-mode: vertical-rl; transform: rotate(180deg);
                        font-size: 11px; max-height: 150px; vertical-align: bottom; }
  table.matrix td.u { text-align: left; font-family: ui-monospace, Menlo, Consolas, monospace; white-space: nowrap; }
  td.c-direct { background: #bbf7d0; color: #14532d; font-weight: 700; }
  td.c-inherit { background: #f0fdf4; color: #16a34a; }
  td.c-none { color: #cbd5e1; }
  /* check */
  .formrow { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; margin-bottom: 10px; }
  #check-result { font-size: 15px; font-weight: 600; padding: 10px 14px; border-radius: 8px; display: none; }
  #check-result.ok { display: block; background: #dcfce7; color: #14532d; }
  #check-result.no { display: block; background: #fee2e2; color: #7f1d1d; }
  #check-result small { display: block; font-weight: 400; color: var(--muted); margin-top: 4px; }
  #expand-out ul { list-style: none; margin: 2px 0 2px 16px; padding-left: 12px; border-left: 1px solid var(--line); }
  #expand-out li { margin: 3px 0; font-size: 13px; }
  .chip { display: inline-block; background: #e0e7ff; color: #3730a3; border-radius: 10px;
          padding: 1px 9px; font-size: 11px; margin: 2px 3px 2px 0; font-family: ui-monospace, Menlo, Consolas, monospace; }
  .objrow { margin: 6px 0; font-size: 13px; }
  .objrow b { font-family: ui-monospace, Menlo, Consolas, monospace; font-weight: 600; }
  /* model */
  .typegrid { display: grid; grid-template-columns: repeat(auto-fill, minmax(360px, 1fr)); gap: 14px; }
  .typecard h3 { margin: 0 0 8px; font-size: 14px; }
  .typecard h3 .tname { font-family: ui-monospace, Menlo, Consolas, monospace; }
  table.rel { border-collapse: collapse; width: 100%; font-size: 12px; }
  table.rel td { border-top: 1px solid #e2e8f0; padding: 4px 6px; vertical-align: top; }
  table.rel td.rname { font-family: ui-monospace, Menlo, Consolas, monospace; white-space: nowrap; font-weight: 600; }
  table.rel td.rsum { font-family: ui-monospace, Menlo, Consolas, monospace; color: var(--muted); }
  .muted { color: var(--muted); font-size: 12px; }
  h2.sec { font-size: 15px; margin: 4px 0 10px; }
</style>
</head>
<body>
<header>
  <h1>OpenFGA RBAC Visualizer</h1>
  <span class="cfg" id="cfg">connecting…</span>
  <nav>
    <button data-tab="hierarchy" class="active">Hierarchy</button>
    <button data-tab="matrix">Permission Matrix</button>
    <button data-tab="check">Check</button>
    <button data-tab="model">Model</button>
    <a href="/logout" style="color:#94a3b8;font-size:13px;align-self:center;margin-left:8px">sign out</a>
  </nav>
</header>
<div id="banner"></div>
<main>

  <section id="tab-hierarchy" class="tab active">
    <div class="card">
      <div class="controls">
        <label><input type="checkbox" id="show-grants" checked> show role grants (users)</label>
        <button class="sec" id="expand-all">Expand all</button>
        <button class="sec" id="collapse-some">Collapse below depth 2</button>
        <span class="muted">Click a node to collapse/expand. Drag to pan, scroll to zoom. Shared objects appear once per parent, marked ⇄.</span>
      </div>
      <div class="legend" id="type-legend"></div>
    </div>
    <div id="tree-wrap"><svg id="tree"><g id="tree-g"></g></svg></div>
  </section>

  <section id="tab-matrix" class="tab">
    <div class="card">
      <h2 class="sec">Who can do what on a given object</h2>
      <div class="controls">
        <label>object <select id="matrix-object"></select></label>
        <span class="legend">
          <span><b style="color:#14532d">●</b> direct grant (tuple exists)</span>
          <span><b style="color:#16a34a">○</b> inherited / computed by the model</span>
          <span><b style="color:#cbd5e1">·</b> no access</span>
        </span>
      </div>
      <div id="matrix-out" class="muted">loading…</div>
    </div>
  </section>

  <section id="tab-check" class="tab">
    <div class="card">
      <h2 class="sec">Does a user have a permission?</h2>
      <div class="formrow">
        <input type="text" id="chk-user" list="dl-users" placeholder="user, e.g. user:aws-viewer">
        <input type="text" id="chk-rel" list="dl-relations" placeholder="relation, e.g. can_read">
        <input type="text" id="chk-obj" list="dl-objects" placeholder="object, e.g. tenant:aws">
        <button class="act" id="chk-go">Check</button>
        <button class="sec" id="chk-expand">Show derivation</button>
      </div>
      <div id="check-result"></div>
      <div id="expand-out"></div>
      <datalist id="dl-users"></datalist>
      <datalist id="dl-objects"></datalist>
      <datalist id="dl-relations"></datalist>
    </div>
    <div class="card">
      <h2 class="sec">Everything a user can do</h2>
      <div class="formrow">
        <input type="text" id="up-user" list="dl-users" placeholder="user, e.g. user:superadmin">
        <button class="act" id="up-go">List permissions</button>
        <span class="muted">Checks every object × relation of the model — shows how far the role propagates.</span>
      </div>
      <div id="up-out"></div>
    </div>
  </section>

  <section id="tab-model" class="tab">
    <div class="card">
      <h2 class="sec">Authorization model <span class="muted" id="model-id"></span></h2>
      <div class="muted">How each relation is derived: <b>direct</b> = writable via tuples,
        <b>= x</b> = alias of relation x, <b>a -&gt; b</b> = follow parent relation a then require b,
        <b>U</b> = union, <b>&amp;</b> = intersection, <b>-</b> = exclusion.
        Chips show which types may be written directly.</div>
    </div>
    <div class="typegrid" id="model-out"></div>
  </section>

</main>
"""
HTML_PAGE += r"""<script>
const TYPE_COLORS = {
  platform: '#7c3aed', tenant: '#2563eb', libcloud_api: '#0891b2',
  provider: '#059669', resource_class: '#d97706', aws_region: '#dc2626',
  nutanix_cluster: '#db2777', user: '#64748b'
};
let GRAPH = null, MODEL = null, FOREST = null, OCCUR = {};
const $ = id => document.getElementById(id);
const enc = encodeURIComponent;
const esc = s => String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
const typeOf = id => id.split(':')[0];
const nameOf = id => { const i = id.indexOf(':'); return i < 0 ? id : id.slice(i+1); };

function showError(msg){ const b=$('banner'); b.style.display='block'; b.textContent=msg; }
async function api(url){
  const r = await fetch(url);
  if(r.status === 401){ window.location.href = '/login'; throw new Error('authentication required'); }
  const j = await r.json().catch(() => ({error:'invalid response from server'}));
  if(!r.ok){ showError(j.error || ('HTTP '+r.status+' for '+url)); throw new Error(j.error||r.status); }
  return j;
}

/* ---------- tabs ---------- */
document.querySelectorAll('nav button').forEach(btn => btn.addEventListener('click', () => {
  document.querySelectorAll('nav button').forEach(b => b.classList.toggle('active', b===btn));
  document.querySelectorAll('section.tab').forEach(s => s.classList.toggle('active', s.id === 'tab-'+btn.dataset.tab));
  if(btn.dataset.tab === 'hierarchy' && GRAPH) renderTree();
}));

/* ---------- hierarchy tree ---------- */
function buildForest(){
  const childMap = {}, grantsByObj = {}; OCCUR = {};
  GRAPH.hierarchy.forEach(h => { (childMap[h.parent] = childMap[h.parent] || []).push({id:h.child, rel:h.relation}); });
  GRAPH.grants.forEach(g => { (grantsByObj[g.object] = grantsByObj[g.object] || []).push(g); });
  const showGrants = $('show-grants').checked;
  function make(id, rel, ancestors){
    OCCUR[id] = (OCCUR[id] || 0) + 1;
    const node = {id:id, rel:rel, user:id.startsWith('user:'), collapsed:false, kids:[]};
    if(ancestors.has(id)) return node;            // cycle guard
    const anc = new Set(ancestors); anc.add(id);
    let kids = (childMap[id] || []).slice();
    if(showGrants) (grantsByObj[id] || []).forEach(g => kids.push({id:g.user, rel:g.relation}));
    node.kids = kids.map(k => make(k.id, k.rel, anc));
    return node;
  }
  FOREST = (GRAPH.roots || []).map(r => make(r, null, new Set()));
}
function countKids(d){
  let n = 0; (d.kids||[]).forEach(k => { n += 1 + countKids(k); }); return n;
}
function setCollapsed(d, depth, maxDepth){
  if(depth >= maxDepth) d.collapsed = true; else d.collapsed = false;
  (d.kids||[]).forEach(k => setCollapsed(k, depth+1, maxDepth));
}
function walk(d, fn){ fn(d); (d.kids||[]).forEach(k => walk(k, fn)); }

function renderTree(){
  buildForest();
  if(!FOREST.length){ return; }
  const data = FOREST.length === 1 ? FOREST[0]
    : {id:'(roots)', rel:null, user:false, collapsed:false, kids:FOREST, synthetic:true};
  const root = d3.hierarchy(data, d => d.collapsed ? null : d.kids);
  d3.tree().nodeSize([24, 210])(root);
  let x0 = Infinity, x1 = -Infinity, y1 = 0;
  root.each(d => { if(d.x < x0) x0 = d.x; if(d.x > x1) x1 = d.x; if(d.y > y1) y1 = d.y; });
  const height = Math.max(320, x1 - x0 + 90);
  const svg = d3.select('#tree');
  svg.style.height = height + 'px';
  if(!svg.node().__zoomInit){
    svg.node().__zoomInit = true;
    svg.call(d3.zoom().scaleExtent([0.25, 3]).on('zoom', ev => {
      d3.select('#tree-g').attr('transform', ev.transform);
    }));
  }
  const g = d3.select('#tree-g');
  g.selectAll('*').remove();
  const inner = g.append('g').attr('transform', 'translate(70,' + (-x0 + 45) + ')');

  inner.selectAll('path.link').data(root.links()).join('path')
    .attr('class', 'link')
    .attr('d', d3.linkHorizontal().x(d => d.y).y(d => d.x));

  inner.selectAll('text.link-label')
    .data(root.links().filter(l => l.target.data.rel)).join('text')
    .attr('class', 'link-label')
    .attr('x', l => (l.source.y + l.target.y) / 2)
    .attr('y', l => (l.source.x + l.target.x) / 2 - 4)
    .text(l => l.target.data.rel);

  const node = inner.selectAll('g.node').data(root.descendants()).join('g')
    .attr('class', d => 'node' + (d.data.user ? ' user' : ''))
    .attr('transform', d => 'translate(' + d.y + ',' + d.x + ')')
    .style('cursor', d => (d.data.kids && d.data.kids.length) ? 'pointer' : 'default')
    .on('click', (ev, d) => {
      if(d.data.kids && d.data.kids.length){ d.data.collapsed = !d.data.collapsed; renderTree(); }
    });

  node.append('circle').attr('r', 6)
    .attr('fill', d => {
      const c = TYPE_COLORS[typeOf(d.data.id)] || '#475569';
      const hasKids = d.data.kids && d.data.kids.length;
      return (hasKids && !d.data.collapsed) ? c : (hasKids ? c : '#fff');
    })
    .attr('stroke', d => TYPE_COLORS[typeOf(d.data.id)] || '#475569')
    .attr('stroke-width', 2);

  node.append('text')
    .attr('dy', '0.31em')
    .attr('x', d => (d.data.kids && d.data.kids.length) ? -11 : 11)
    .attr('text-anchor', d => (d.data.kids && d.data.kids.length) ? 'end' : 'start')
    .text(d => {
      const nm = d.data.synthetic ? d.data.id : nameOf(d.data.id);
      return (d.data.collapsed && d.data.kids && d.data.kids.length)
        ? nm + ' (+' + countKids(d.data) + ')' : nm;
    });

  node.filter(d => OCCUR[d.data.id] > 1 && !d.data.user).append('text')
    .attr('class', 'shared-tag').attr('x', 10).attr('dy', '-0.85em').text('⇄ shared');
}

/* ---------- matrix ---------- */
async function loadMatrix(obj){
  $('matrix-out').textContent = 'running checks…';
  const m = await api('/api/matrix?object=' + enc(obj));
  const direct = new Set(m.direct.map(d => d[0] + '|' + d[1]));
  let h = '<table class="matrix"><tr><th></th>' +
    m.relations.map(r => '<th class="rel">' + esc(r) + '</th>').join('') + '</tr>';
  m.users.forEach(u => {
    h += '<tr><td class="u">' + esc(nameOf(u)) + '</td>';
    m.relations.forEach(r => {
      const ok = m.cells[u] && m.cells[u][r];
      if(ok === true && direct.has(u + '|' + r)) h += '<td class="c-direct" title="direct tuple">●</td>';
      else if(ok === true) h += '<td class="c-inherit" title="inherited via model">○</td>';
      else h += '<td class="c-none">·</td>';
    });
    h += '</tr>';
  });
  $('matrix-out').innerHTML = h + '</table>';
}

/* ---------- check / expand / user permissions ---------- */
async function doCheck(){
  const u = $('chk-user').value.trim(), r = $('chk-rel').value.trim(), o = $('chk-obj').value.trim();
  if(!u || !r || !o) return;
  const j = await api('/api/check?user=' + enc(u) + '&relation=' + enc(r) + '&object=' + enc(o));
  const el = $('check-result');
  el.className = j.allowed ? 'ok' : 'no';
  el.innerHTML = (j.allowed ? 'ALLOWED' : 'DENIED') + ' — ' + esc(u) + ' <b>' + esc(r) + '</b> ' + esc(o) +
    (j.resolution ? '<small>resolution: ' + esc(j.resolution) + '</small>' : '');
}
function expandNode(name, node){
  let h = '<li><b>' + esc(name || node.name || '') + '</b>';
  const leaf = node.leaf;
  if(leaf){
    let users = (leaf.users && leaf.users.users) || [];
    if(typeof users === 'string') users = [users];
    let comp = leaf.computed || [];
    if(!Array.isArray(comp)) comp = [comp];
    comp.forEach(c => { if(c && c.userset) h += ' <span class="chip">computed: ' + esc(c.userset) + '</span>'; });
    users.forEach(u => h += ' <span class="chip">' + esc(u) + '</span>');
    const t2u = leaf.tupleToUserset;
    if(t2u){
      let tc = t2u.computed || [];
      if(!Array.isArray(tc)) tc = [tc];
      tc.forEach(c => { if(c && c.userset)
        h += ' <span class="chip">' + esc((t2u.tupleset || '?') + ' -> ' + c.userset) + '</span>'; });
    }
  }
  ['union', 'intersection', 'difference'].forEach(op => {
    if(node[op] && node[op].nodes){
      h += '<div class="muted">' + op + '</div><ul>' +
        node[op].nodes.map(n => expandNode('', n)).join('') + '</ul>';
    }
  });
  return h + '</li>';
}
async function doExpand(){
  const r = $('chk-rel').value.trim(), o = $('chk-obj').value.trim();
  if(!r || !o) return;
  const j = await api('/api/expand?object=' + enc(o) + '&relation=' + enc(r));
  $('expand-out').innerHTML = '<h2 class="sec">Why: expansion of ' + esc(o) + '#' + esc(r) + '</h2><ul>' +
    expandNode(j.tree && j.tree.root ? j.tree.root.name : '', (j.tree && j.tree.root) || {}) + '</ul>';
}
async function doUserPerms(){
  const u = $('up-user').value.trim();
  if(!u) return;
  $('up-out').textContent = 'running checks for every object…';
  const j = await api('/api/user_permissions?user=' + enc(u));
  const objs = Object.keys(j.allowed).sort();
  let h = '<p class="muted">' + esc(j.user) + ': access on ' + objs.length +
    ' of ' + j.objects.length + ' objects.</p>';
  objs.forEach(o => {
    h += '<div class="objrow"><b>' + esc(o) + '</b><br>' +
      j.allowed[o].map(r => '<span class="chip">' + esc(r) + '</span>').join('') + '</div>';
  });
  $('up-out').innerHTML = h;
}

/* ---------- model ---------- */
async function loadModel(){
  $('model-id').textContent = '— ' + MODEL.id + ' (schema ' + MODEL.schema_version + ')';
  $('model-out').innerHTML = MODEL.types.map(t => {
    let rows = t.relations.map(r =>
      '<tr><td class="rname">' + esc(r.name) + '</td><td class="rsum">' + esc(r.summary) + '</td><td>' +
      r.direct.map(d => '<span class="chip">' + esc(d) + '</span>').join('') + '</td></tr>').join('');
    if(!rows) rows = '<tr><td class="muted" colspan="3">no relations — identity type</td></tr>';
    return '<div class="card typecard"><h3><span class="tname">' + esc(t.type) + '</span> ' +
      '<span class="muted">(' + t.relations.length + ' relations)</span></h3>' +
      '<table class="rel">' + rows + '</table></div>';
  }).join('');
}

/* ---------- boot ---------- */
async function boot(){
  try{
    const cfg = await api('/api/config');
    $('cfg').textContent = 'signed in as ' + (cfg.user.name || cfg.user.email || '?') +
      ' · store ' + cfg.store_id + ' · model ' + cfg.model_id + ' · ' + cfg.api_url;
    const res = await Promise.all([api('/api/graph'), api('/api/model')]);
    GRAPH = res[0]; MODEL = res[1];
  }catch(e){ return; }

  $('type-legend').innerHTML = Object.keys(TYPE_COLORS).map(t =>
    '<span><span class="dot" style="background:' + TYPE_COLORS[t] + '"></span>' + t + '</span>').join('');

  const users = GRAPH.nodes.filter(n => n.type === 'user').map(n => n.id);
  const objs = GRAPH.nodes.filter(n => n.type !== 'user').map(n => n.id);
  $('dl-users').innerHTML = users.map(u => '<option value="' + esc(u) + '">').join('');
  $('dl-objects').innerHTML = objs.map(o => '<option value="' + esc(o) + '">').join('');
  const rels = new Set();
  MODEL.types.forEach(t => t.relations.forEach(r => rels.add(r.name)));
  $('dl-relations').innerHTML = [...rels].sort().map(r => '<option value="' + esc(r) + '">').join('');

  const byType = {};
  GRAPH.nodes.filter(n => n.type !== 'user').forEach(n => { (byType[n.type] = byType[n.type] || []).push(n.id); });
  $('matrix-object').innerHTML = Object.keys(byType).sort().map(t =>
    '<optgroup label="' + esc(t) + '">' +
    byType[t].map(o => '<option value="' + esc(o) + '">' + esc(o) + '</option>').join('') +
    '</optgroup>').join('');
  const def = objs.indexOf('tenant:aws') >= 0 ? 'tenant:aws' : objs[0];
  if(def){ $('matrix-object').value = def; loadMatrix(def).catch(() => {}); }

  renderTree();
  loadModel().catch(() => {});
}
$('show-grants').addEventListener('change', renderTree);
$('expand-all').addEventListener('click', () => { FOREST.forEach(d => walk(d, n => n.collapsed = false)); renderTree(); });
$('collapse-some').addEventListener('click', () => { FOREST.forEach(d => setCollapsed(d, 0, 2)); renderTree(); });
$('matrix-object').addEventListener('change', () => loadMatrix($('matrix-object').value).catch(() => {}));
$('chk-go').addEventListener('click', () => doCheck().catch(() => {}));
$('chk-expand').addEventListener('click', () => doExpand().catch(() => {}));
$('up-go').addEventListener('click', () => doUserPerms().catch(() => {}));
boot();
</script>
</body>
</html>
"""


# --------------------------------------------------------------------------
# Authentication screen (own SSO login - no shared/previous credentials)
# --------------------------------------------------------------------------

LOGIN_PAGE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>OpenFGA RBAC Visualizer - Sign in</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { margin: 0; min-height: 100vh; display: flex; align-items: center;
         justify-content: center; background: #0f172a;
         font: 14px/1.5 -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
  .card { background: #fff; border-radius: 12px; padding: 36px 40px; width: 380px;
          box-shadow: 0 20px 50px rgba(0,0,0,.4); text-align: center; }
  h1 { font-size: 20px; margin: 0 0 6px; color: #0f172a; }
  p.sub { color: #64748b; margin: 0 0 24px; font-size: 13px; }
  a.btn { display: block; background: #2563eb; color: #fff; text-decoration: none;
          padding: 11px 0; border-radius: 8px; font-size: 15px; font-weight: 600; }
  a.btn:hover { background: #1d4ed8; }
  .err { background: #fee2e2; color: #7f1d1d; border-radius: 8px; padding: 8px 12px;
         margin-bottom: 16px; font-size: 13px; display: none; text-align: left; }
  .note { margin-top: 18px; font-size: 12px; color: #94a3b8; }
</style>
</head>
<body>
  <div class="card">
    <h1>OpenFGA RBAC Visualizer</h1>
    <p class="sub">Separate application - sign in with your SSO account.<br>
    Every OpenFGA call is then made as <i>you</i>.</p>
    <div class="err" id="err"></div>
    <a class="btn" href="/auth/start">Sign in with SSO</a>
    <div class="note">Dex SSO &middot; restricted to the LLDAP superadmin account</div>
  </div>
<script>
  const e = new URLSearchParams(location.search).get('error');
  if(e){ const d = document.getElementById('err');
         d.style.display = 'block'; d.textContent = 'Sign-in failed: ' + e; }
</script>
</body>
</html>
"""


def is_superadmin(claims):
    """Access gate: only the LLDAP superadmin account may use the dashboard.

    Google/GitHub (OAuth2 connector) logins never satisfy this: they cannot
    produce the LLDAP `mail` attribute, and their Dex `sub` differs because
    the connector id is hashed into it.
    """
    if SUPERADMIN_SUB:
        return claims.get("sub") == SUPERADMIN_SUB
    return (claims.get("email") or "").lower() == SUPERADMIN_EMAIL


def redirect_uri():
    """Callback URL - must match one of the client's redirectURIs in Dex."""
    return os.environ.get("OAUTH_REDIRECT_URI") or (
        request.host_url.rstrip("/") + "/callback"
    )


@app.get("/login")
def login():
    if current_session():
        return redirect("/")
    return Response(LOGIN_PAGE, mimetype="text/html")


@app.get("/auth/start")
def auth_start():
    state = secrets.token_urlsafe(16)
    nonce = secrets.token_urlsafe(16)
    session.clear()
    session["oauth_state"] = state
    session["oauth_nonce"] = nonce
    params = {
        "client_id": OIDC_CLIENT_ID,
        "redirect_uri": redirect_uri(),
        "response_type": "code",
        "scope": OIDC_SCOPES,
        "state": state,
        "nonce": nonce,
    }
    return redirect(discovery()["authorization_endpoint"] + "?" + urlencode(params))


@app.get("/callback")
def callback():
    if request.args.get("error"):
        return redirect("/login?error=" + request.args["error"])
    if request.args.get("state") != session.pop("oauth_state", None):
        return redirect("/login?error=invalid_state")
    code = request.args.get("code")
    if not code:
        return redirect("/login?error=no_code")
    try:
        tok = requests.post(
            discovery()["token_endpoint"],
            data={
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirect_uri(),
            },
            auth=(OIDC_CLIENT_ID, client_secret()),
            timeout=15,
        )
        if tok.status_code != 200:
            return redirect("/login?error=token_exchange_failed")
        id_token = tok.json().get("id_token")
        if not id_token:
            return redirect("/login?error=no_id_token")
        key = PyJWKClient(discovery()["jwks_uri"]).get_signing_key_from_jwt(id_token)
        claims = jwt.decode(
            id_token, key, algorithms=["RS256"],
            audience=OIDC_CLIENT_ID, issuer=OIDC_ISSUER,
        )
        if claims.get("nonce") != session.pop("oauth_nonce", None):
            return redirect("/login?error=bad_nonce")
    except requests.RequestException:
        return redirect("/login?error=sso_unreachable")
    except jwt.PyJWTError as exc:
        return redirect("/login?error=" + str(exc)[:100])

    if not is_superadmin(claims):
        # Logged so the admin can copy the exact `sub` into SUPERADMIN_SUB.
        app.logger.warning(
            "login denied (LLDAP superadmin only): sub=%s email=%s name=%s",
            claims.get("sub"), claims.get("email"), claims.get("name"),
        )
        return redirect(
            "/login?error=" + quote("only the LLDAP superadmin account may sign in")
        )

    sid = secrets.token_urlsafe(24)
    _sessions[sid] = {
        "id_token": id_token,
        "user": {
            "name": claims.get("name") or claims.get("email") or claims.get("sub"),
            "email": claims.get("email", ""),
        },
        "expires": min(
            float(claims.get("exp", 0)), time.time() + SESSION_LIFETIME.total_seconds()
        ),
    }
    session.clear()
    session["sid"] = sid
    session.permanent = True
    return redirect("/")


@app.get("/logout")
def logout():
    drop_session()
    return redirect("/login")


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------


@app.get("/")
def index():
    if not current_session():
        return redirect("/login")
    return Response(HTML_PAGE, mimetype="text/html")


if __name__ == "__main__":
    print(f"OpenFGA RBAC Visualizer -> http://localhost:{PORT}")
    print(f"  upstream {API_URL}  store {STORE_ID}  model {MODEL_ID or '(latest)'}")
    print(f"  login: Dex SSO at {OIDC_ISSUER} (client {OIDC_CLIENT_ID})")
    app.run(host="0.0.0.0", port=PORT, threaded=True)
