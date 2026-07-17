"""Shared helpers for the OpenFGA Group-2 Python tools (reconcile / audit).

Centralises:
  * environment loading from the same .env files the bash scripts use,
  * bearer-token resolution for OpenFGA (FGA_API_TOKEN > SUPERADMIN_JWT >
    generated/tokens/superadmin.jwt-if-not-expired),
  * a tiny urllib OpenFGA client (read/write/delete/check/list),
  * a tiny urllib LLDAP GraphQL client (admin login + group/member listing),
  * the LLDAP-group -> OpenFGA-tuple mapping convention + managed-tuple
    predicate,
  * JSONL audit emission to generated/openfga_audit.log.

Pure stdlib; no third-party deps.
"""
from __future__ import annotations

import base64
import json
import os
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

REPO_ROOT = Path(__file__).resolve().parents[2]

# --------------------------------------------------------------------------- #
# Environment loading
# --------------------------------------------------------------------------- #
def load_env_files(files: List[Path]) -> None:
    """Set os.environ from KEY=VALUE files. Existing env wins (skip if set)."""
    for f in files:
        if not f.exists():
            continue
        for raw in f.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.strip()
            if not k or k in os.environ and os.environ[k] != "":
                continue
            os.environ[k] = v.strip().strip('"').strip("'")


def bootstrap_env() -> None:
    load_env_files([
        REPO_ROOT / ".env",
        REPO_ROOT / "test_script" / "generated" / "dex.env",
        REPO_ROOT / "openfga_postgres" / "generated" / "fga.env",
        REPO_ROOT / "dex" / "generated" / "dex.env",
        REPO_ROOT / "lldap" / ".env",
    ])


# --------------------------------------------------------------------------- #
# Token resolution
# --------------------------------------------------------------------------- #
def _jwt_exp(tok: str) -> int:
    try:
        p = tok.split(".")[1]
        p += "=" * (-len(p) % 4)
        return int(json.loads(base64.urlsafe_b64decode(p)).get("exp", 0))
    except Exception:
        return 0


def resolve_fga_token() -> Optional[str]:
    if os.environ.get("FGA_API_TOKEN", "").strip():
        return os.environ["FGA_API_TOKEN"]
    if os.environ.get("SUPERADMIN_JWT", "").strip():
        return os.environ["SUPERADMIN_JWT"]
    jp = REPO_ROOT / "generated" / "tokens" / "superadmin.jwt"
    if jp.exists() and jp.stat().st_size > 100:
        tok = jp.read_text().strip()
        exp = _jwt_exp(tok)
        if exp and exp > int(time.time()):
            return tok
    return None


# --------------------------------------------------------------------------- #
# OpenFGA client (urllib)
# --------------------------------------------------------------------------- #
class FgaClient:
    def __init__(self) -> None:
        self.base = os.environ.get("FGA_API_URL", "http://localhost:8080").rstrip("/")
        self.store = os.environ["FGA_STORE_ID"]
        self.model = os.environ["FGA_MODEL_ID"]
        self.token = resolve_fga_token()
        if not self.token:
            raise SystemExit(
                "No OpenFGA bearer token: set FGA_API_TOKEN/SUPERADMIN_JWT or "
                "ensure generated/tokens/superadmin.jwt is valid."
            )

    def _req(self, method: str, path: str, payload: Optional[dict] = None) -> dict:
        url = self.base + path
        data = json.dumps(payload).encode() if payload is not None else None
        h = {"Content-Type": "application/json", "Accept": "application/json"}
        if self.token:
            h["Authorization"] = f"Bearer {self.token}"
        req = urllib.request.Request(url, data=data, method=method, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read().decode() or "{}")
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", "replace")
            raise FgaHttpError(e.code, method, path, body) from None

    def read_all_tuples(self) -> List[dict]:
        out, tok = [], ""
        while True:
            p = {"page_size": 100}
            if tok:
                p["continuation_token"] = tok
            d = self._req("POST", f"/stores/{self.store}/read", p)
            for t in d.get("tuples", []):
                k = t.get("key", {})
                out.append({"user": k.get("user"), "relation": k.get("relation"),
                            "object": k.get("object")})
            tok = d.get("continuation_token") or ""
            if not tok:
                break
        return out

    def write(self, triples: List[dict]) -> dict:
        if not triples:
            return {}
        return self._req("POST", f"/stores/{self.store}/write",
                         {"authorization_model_id": self.model,
                          "writes": {"tuple_keys": triples}})

    def delete(self, triples: List[dict]) -> dict:
        if not triples:
            return {}
        return self._req("POST", f"/stores/{self.store}/write",
                         {"authorization_model_id": self.model,
                          "deletes": {"tuple_keys": triples}})

    def check(self, user: str, rel: str, obj: str) -> bool:
        d = self._req("POST", f"/stores/{self.store}/check",
                      {"authorization_model_id": self.model,
                       "tuple_key": {"user": user, "relation": rel, "object": obj}})
        return bool(d.get("allowed", False))


class FgaHttpError(Exception):
    def __init__(self, status: int, method: str, path: str, body: str):
        super().__init__(f"{method} {path} -> HTTP {status}: {body}")
        self.status, self.body = status, body


# --------------------------------------------------------------------------- #
# LLDAP GraphQL client
# --------------------------------------------------------------------------- #
class LldapClient:
    def __init__(self) -> None:
        host = os.environ.get("LLDAP_URL") or (
            f"http://localhost:{os.environ.get('LLDAP_HTTP_PORT','17170')}")
        self.url = host.rstrip("/")
        self.user = os.environ.get("LLDAP_ADMIN_USER", "admin")
        pw = (os.environ.get("LLDAP_ADMIN_PW") or os.environ.get("LLDAP_LDAP_USER_PASS")
              or os.environ.get("LLDAP_ADMIN_PASSWORD"))
        if not pw:
            raise SystemExit("LLDAP admin password not set (LLDAP_LDAP_USER_PASS / "
                             "LLDAP_ADMIN_PASSWORD in ../lldap/.env).")
        self.pw = pw
        self.jwt = ""

    def login(self) -> None:
        body = json.dumps({"username": self.user, "password": self.pw}).encode()
        req = urllib.request.Request(f"{self.url}/auth/simple/login", data=body,
                                     method="POST",
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=15) as r:
            d = json.loads(r.read().decode() or "{}")
        self.jwt = d.get("token", "")
        if not self.jwt:
            raise SystemExit("LLDAP login returned no token.")

    def _gql(self, query: str) -> dict:
        if not self.jwt:
            self.login()
        body = json.dumps({"query": query}).encode()
        req = urllib.request.Request(f"{self.url}/api/graphql", data=body, method="POST",
                                     headers={"Content-Type": "application/json",
                                              "Authorization": f"Bearer {self.jwt}"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read().decode() or "{}")
        except urllib.error.HTTPError as e:
            raise SystemExit(f"LLDAP GraphQL HTTP {e.code}: {e.read().decode('replace')}")

    def list_groups_with_members(self) -> List[dict]:
        q = "{ groups { id displayName users { id email displayName } } }"
        d = self._gql(q)
        groups = (d.get("data") or {}).get("groups") or []
        out = []
        for g in groups:
            members = [m.get("id") for m in (g.get("users") or []) if m.get("id")]
            out.append({"name": g.get("displayName") or "", "id": g.get("id"),
                        "members": sorted(members)})
        return out

    def list_users(self) -> List[dict]:
        q = "{ users { id email displayName } }"
        d = self._gql(q)
        return (d.get("data") or {}).get("users") or []


# --------------------------------------------------------------------------- #
# LLDAP group -> OpenFGA tuple mapping
# --------------------------------------------------------------------------- #
MANAGED_RELATIONS = {"owner", "admin", "viewer", "superadmin"}

def load_map_file(path: Optional[str]) -> Dict[str, Tuple[str, str]]:
    """JSON: {group_name: {"relation":..,"object":..}}."""
    m: Dict[str, Tuple[str, str]] = {}
    if not path:
        return m
    p = Path(path)
    if not p.exists():
        raise SystemExit(f"--map-file not found: {path}")
    for k, v in json.loads(p.read_text()).items():
        m[k] = (v["relation"], v["object"])
    return m


def group_to_tuple(group_name: str, explicit: Dict[str, Tuple[str, str]]) -> Optional[Tuple[str, str]]:
    """Map an LLDAP group name to an OpenFGA (relation, object) managed tuple.

    Convention (when not in explicit map):
      platform-superadmin                 -> (superadmin, platform:main)
      tenant-<cloud>-<owner|admin|viewer> -> (<role>, tenant:<cloud>)
    Groups not matching are ignored (return None).
    """
    if group_name in explicit:
        return explicit[group_name]
    if group_name == "platform-superadmin":
        return ("superadmin", "platform:main")
    parts = group_name.split("-")
    if len(parts) == 3 and parts[0] == "tenant" and parts[2] in ("owner", "admin", "viewer"):
        return (parts[2], f"tenant:{parts[1]}")
    return None


def is_managed_tuple(t: dict) -> bool:
    """A user->role tuple on tenant:/platform: that the reconciler may sync."""
    u, r, o = t.get("user"), t.get("relation"), t.get("object")
    if not u or not u.startswith("user:"):
        return False
    if r not in MANAGED_RELATIONS:
        return False
    if o and (o.startswith("tenant:") or o.startswith("platform:")):
        return True
    return False


# --------------------------------------------------------------------------- #
# Audit
# --------------------------------------------------------------------------- #
def now_iso() -> str:
    import datetime
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def audit(line: dict) -> None:
    log = Path(os.environ.get("FGA_AUDIT_LOG", str(REPO_ROOT / "generated" / "openfga_audit.log")))
    log.parent.mkdir(parents=True, exist_ok=True)
    s = json.dumps(line)
    print(s)  # also surface on stdout for visibility
    with log.open("a", encoding="utf-8") as fh:
        fh.write(s + "\n")
