#!/usr/bin/env python3
"""End-to-end verification of the company→department flow via the REAL portal
OIDC login (three logins: superadmin, company admin, department admin).

Run INSIDE the identity-service container (it needs httpx + the app package):

  cd /home/ubuntu/libcloud_nutanix
  set -a; source dex/generated/dex.env; source test_script/scripts/generated/users.env; set +a
  docker exec -i \
    -e SUPER_PW="$LIBCLOUD_SUPERADMIN_PASSWORD" \
    -e USER03_PW="$LIBCLOUD_USER_03_PASSWORD" \
    -e USER04_PW="$LIBCLOUD_USER_04_PASSWORD" \
    identity-service python3 /opt/libcloud-scripts/scripts/e2e_department_flow.py

What it checks:
  1. superadmin logs in, creates company `e2e-browser-corp` (admin = user03).
  2. user03 logs in (role company_admin), session.company matches, creates an
     AWS department `e2e-browser-eng` (owner = user04) + stores a credential.
  3. user04 logs in (role owner), can provision AWS, cannot provision Nutanix.

It cleans up all test tuples + Vault secrets before and after, so it is safe to
re-run. Passwords come from the sourced env files (superadmin + user03/user04).
It uses user03/user04 (not user01/user02) so it never collides with companies a
user may have created manually via the UI.
"""
from __future__ import annotations

import os
import re
import sys
import urllib.error
import urllib.request

import httpx

sys.path.insert(0, "/app")  # the identity-service app package lives at /app/app

from app.fga import FgaService
from app.vault import get_vault_service

API = os.environ.get("E2E_API", "http://127.0.0.1:8766")
CORP = os.environ.get("E2E_CORP", "e2e-browser-corp")
DEPT = os.environ.get("E2E_DEPT", "e2e-browser-eng")

fga = FgaService()
vault = get_vault_service()
root = os.environ.get("VAULT_ROOT_TOKEN", "")
addr = os.environ.get("VAULT_ADDR", "http://vault:8200").rstrip("/")

_results: list[bool] = []


def check(label: str, cond: bool) -> None:
    _results.append(bool(cond))
    print(("PASS" if cond else "FAIL"), label)


def cleanup_corp(corp: str, dept: str) -> None:
    """Delete every OpenFGA tuple (subject OR object) + Vault secret/role/policy
    belonging to this test company/department. Matches both directions because
    `tenant:<dept> parent provider:aws` has the tenant as the SUBJECT."""
    markers = (
        f"company:{corp}", f"tenant:{dept}", f"aws_region:{dept}",
        f"nutanix_cluster:{dept}", f"vault_user:libcloud-{dept}",
    )
    to_del = [t for t in fga.list_tuples()
              if any(m in t["object"] or m in t["user"] for m in markers)]
    if to_del:
        fga._delete(to_del)
        print(f"  cleanup {corp}: deleted {len(to_del)} tuples")
    for p in (f"/v1/secret/data/libcloud/{dept}",
              f"/v1/secret/data/libcloud-vault-auth/libcloud-{dept}",
              f"/v1/auth/approle/role/libcloud-{dept}",
              f"/v1/sys/policies/acl/libcloud-read-{dept}"):
        req = urllib.request.Request(addr + p, method="DELETE", headers={"X-Vault-Token": root})
        try:
            urllib.request.urlopen(req, timeout=10)
        except urllib.error.HTTPError:
            pass


def portal_login(uid: str, password: str):
    """Full browser OIDC flow for the libcloud-portal client -> session cookie."""
    c = httpx.Client(timeout=30, follow_redirects=False)
    r = c.get(f"{API}/api/auth/begin",
              params={"provider": "lldap", "redirect_uri": "http://localhost:3000/auth/callback"})
    d = r.json()
    authz = re.sub(r"http://[^/]+/dex", "http://dex:5556/dex", d["authorizeUrl"])
    state = d["state"]
    r = c.get(authz, follow_redirects=True)
    m = re.search(r'action="(/dex/auth/[^"]+)"', r.text)
    r = c.post("http://dex:5556" + m.group(1).replace("&amp;", "&"),
               data={"login": uid, "password": password}, follow_redirects=False)
    code = re.search(r"[?&]code=([^&]+)", r.headers.get("location", "")).group(1)
    r = c.post(f"{API}/api/auth/exchange",
               json={"provider": "lldap", "code": code, "state": state,
                     "redirectUri": "http://localhost:3000/auth/callback"})
    return c, r.json()


def main() -> int:
    cleanup_corp(CORP, DEPT)  # pre-clean any prior run

    sa, s = portal_login("superadmin", os.environ["SUPER_PW"])
    check("superadmin role", s.get("role") == "superadmin")
    check("create company 200",
          sa.post(f"{API}/api/companies", json={"name": CORP, "adminUserId": "int-user03"}).status_code == 200)

    ca, s = portal_login("user03", os.environ["USER03_PW"])
    check("company_admin role", s.get("role") == "company_admin")
    sess = ca.get(f"{API}/api/session").json()
    check("session.company == corp", sess.get("company") == CORP)
    check("create dept 200",
          ca.post(f"{API}/api/companies/{CORP}/departments",
                  json={"name": DEPT, "cloud": "aws", "ownerUserId": "int-user04",
                        "credential": {"key": "E2EKEY", "secret": "E2ESECRET"}}).status_code == 200)
    deps = ca.get(f"{API}/api/companies/{CORP}/departments").json()["departments"]
    check("company admin lists dept", any(d["id"] == DEPT and d["cloud"] == "aws" for d in deps))

    da, s = portal_login("user04", os.environ["USER04_PW"])
    check("dept admin role=owner", s.get("role") == "owner")
    clouds = {c["cloud"]: c for c in s.get("clouds", [])}
    check("dept admin can provision aws", clouds.get("aws", {}).get("canProvision") is True)
    check("dept admin cannot provision nutanix", clouds.get("nutanix", {}).get("canProvision") is not True)

    cleanup_corp(CORP, DEPT)  # post-clean
    print("---")
    print(f"{sum(_results)}/{len(_results)} checks passed")
    return 0 if all(_results) else 1


if __name__ == "__main__":
    sys.exit(main())
