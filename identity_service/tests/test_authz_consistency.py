#!/usr/bin/env python3
"""AuthZ consistency matrix for the identity service (portal backend).

Regression net for the bug where the portal showed "Provision Nutanix" (via
/api/session capabilities) but POST /api/provision/nutanix returned
403 authz_forbidden: /api/session derived capabilities with
UserService._fga_principal (full internal id for pending users) while the verb
routes used main._principal (always stripped "int-"). Any future divergence
between the capability mapping and the verb-route mapping fails this test.

What it checks, for every user in CASES x every cloud x every verb
(resources / provision / provision-private / deprovision / update):

  1. RBAC matrix   — the route gate matches the expected allow/deny for that
                     user (expectations are hardcoded here from rbac_design.md,
                     NOT derived from OpenFGA, so the test is independent).
  2. Consistency   — the route gate outcome equals the capability flag that
                     GET /api/session reports for the same user+cloud
                     (canView <-> resources, canProvision <-> provision AND
                     deprovision, canUpdate <-> update). This is the exact
                     invariant the bug violated.
  3. Denied routes — return 403 with error code "authz_forbidden".

It runs IN-PROCESS (FastAPI TestClient) against the real app code and the real
OpenFGA store, with LibcloudProxy stubbed so NO VMs are ever created, patched,
or deleted. Pending (federated, not-yet-LLDAP-linked) users are injected into
app.users._pending_users, which is the only way to exercise their code path —
that in-memory registry is what keys them by full internal id in OpenFGA.

Run it inside the identity-service container (needs its env: FGA_*, LLDAP_*,
DEX_*, SESSION_SECRET):

    docker cp identity_service/tests/test_authz_consistency.py identity-service:/tmp/
    docker exec -e PYTHONPATH=/app identity-service python /tmp/test_authz_consistency.py

verify_authz_matrix.sh does both steps for you, plus the live HTTP matrix.
Exit status: 0 = all pass, 1 = any failure.
"""

from __future__ import annotations

import sys
import time

import jwt

# --- Stub the cloud proxy BEFORE the app is created, so no real VM is ever
# --- touched. The unit under test is the identity-service authZ layer, not
# --- the proxy (the proxy's replay mechanics are covered by verify_provision.sh).
from app import libcloud_proxy


def _stub_list_nodes(self, cloud):
    key = "region" if cloud == "aws" else "cluster"
    return {"nodes": [], key: "stub"}


def _stub_provision(self, cloud, vm_name):
    return {"provider": cloud, "vmName": vm_name, "status": "provisioned",
            "steps": ["stubbed-proxy"], "node": {"id": "stub-node"}}


def _stub_provision_private(self, cloud, pair_name):
    # Cloud-parametric like the real proxy: aws -> provision_aws_private.sh,
    # nutanix -> provision_nutanix_bastion_private.sh.
    return {"provider": cloud, "vmName": pair_name, "bastionName": f"{pair_name}-bastion",
            "internalName": f"{pair_name}-internal", "status": "provisioned", "exitCode": 0}


def _stub_deprovision(self, cloud, vm_name, vm_id):
    return {"provider": cloud, "vmId": vm_id, "vmName": vm_name, "status": "deprovisioned"}


def _stub_update_node(self, cloud, vm_id, updates):
    return {"provider": cloud, "vmId": vm_id, "status": "updated"}


libcloud_proxy.LibcloudProxy.list_nodes = _stub_list_nodes
libcloud_proxy.LibcloudProxy.provision = _stub_provision
libcloud_proxy.LibcloudProxy.provision_private = _stub_provision_private
libcloud_proxy.LibcloudProxy.deprovision = _stub_deprovision
libcloud_proxy.LibcloudProxy.update_node = _stub_update_node

import app.users as users_mod  # noqa: E402
from app.config import get_settings  # noqa: E402

# --- Test matrix -------------------------------------------------------------
# (internalUserId, session role, pending?, {cloud: (canView, canProvision, canUpdate)})
#
# pending?=True injects the user into app.users._pending_users, i.e. simulates a
# federated (Google/GitHub) login that a SuperAdmin later granted a role. Their
# OpenFGA tuples are keyed by the FULL internal id (e.g. user:int-admin) — the
# exact shape that triggered the original 403 bug.
#
# LLDAP-user expectations come from the seeded store (openfga_bootstrap):
#   owner/admin of a tenant: view+provision+deprovision+update on THAT cloud only
#   viewer of a tenant:      view on THAT cloud only
#   superadmin:              global read-only; provision/update nowhere by default
CASES = [
    ("int-aws-owner", "owner", False, {"aws": (True, True, True), "nutanix": (False, False, False)}),
    ("int-aws-admin", "admin", False, {"aws": (True, True, True), "nutanix": (False, False, False)}),
    ("int-aws-viewer", "viewer", False, {"aws": (True, False, False), "nutanix": (False, False, False)}),
    ("int-ntnx-owner", "owner", False, {"aws": (False, False, False), "nutanix": (True, True, True)}),
    ("int-ntnx-admin", "admin", False, {"aws": (False, False, False), "nutanix": (True, True, True)}),
    ("int-ntnx-viewer", "viewer", False, {"aws": (False, False, False), "nutanix": (True, False, False)}),
    ("int-superadmin", "superadmin", False, {"aws": (True, False, False), "nutanix": (True, False, False)}),
    # Pending (federated) users — the reported bug class. int-admin holds
    # user:int-admin owner+admin tuples on BOTH tenants in the live store.
    ("int-admin", "owner", True, {"aws": (True, True, True), "nutanix": (True, True, True)}),
    # A pending user with NO tuples at all: denied everywhere, and the denial
    # must still be consistent between /api/session and the verb routes.
    ("int-pending-notuples", "pending", True, {"aws": (False, False, False), "nutanix": (False, False, False)}),
]

# verb -> (method, path template, body, capability flag that gates it)
VERBS = [
    ("resources", "GET", "/api/resources/{cloud}", None, "canView"),
    ("provision", "POST", "/api/provision/{cloud}", {"vmName": "authz-test-vm"}, "canProvision"),
    # The private-pair (bastion + internal) button shares the canProvision gate
    # (Nutanix owner/admin only). For users WITH the grant on AWS, the route
    # answers 400 not_supported (Nutanix-only scenario) — still "not 403", so
    # the allow expectation and the consistency invariant both hold.
    ("provision-private", "POST", "/api/provision-private/{cloud}", {"vmName": "authz-test-pair"}, "canProvision"),
    # Deprovisioning is gated on can_provision by design (write scope).
    ("deprovision", "POST", "/api/deprovision/{cloud}", {"vmId": "authz-no-such-vm", "vmName": "x"}, "canProvision"),
    ("update", "POST", "/api/update/{cloud}", {"vmId": "authz-no-such-vm", "name": "x"}, "canUpdate"),
]

PASS = 0
FAIL = 0
FAILURES: list[str] = []


def report(ok: bool, name: str, detail: str = "") -> None:
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        FAILURES.append(name)
        print(f"  FAIL  {name}\n        {detail}")


def main() -> int:
    from fastapi.testclient import TestClient
    from app.main import app  # create_app() runs here, with the stubbed proxy

    s = get_settings()
    client = TestClient(app)

    def cookie_for(internal_id: str, role: str) -> dict[str, str]:
        now = int(time.time())
        token = jwt.encode(
            {"internalUserId": internal_id, "role": role,
             "email": f"{internal_id}@libcloud.local", "linkedIdentities": [],
             "sid": "authz-test", "iat": now, "exp": now + 3600, "jti": "authz-test"},
            s.session_secret, algorithm="HS256")
        return {s.session_cookie_name: token}

    for internal_id, role, is_pending, clouds in CASES:
        print(f"[case] {internal_id} (role={role}, pending={is_pending})")
        if is_pending:
            users_mod._pending_users[internal_id] = {
                "internalUserId": internal_id,
                "email": f"{internal_id}@libcloud.local",
                "displayName": internal_id,
                "role": role,
                "linkedIdentities": ["google:authz-test"],
                "createdAt": "",
            }
        jar = cookie_for(internal_id, role)

        # 1. Capability flags as the portal renders them.
        r = client.get("/api/session", cookies=jar)
        if r.status_code != 200:
            report(False, f"{internal_id} GET /api/session", f"http={r.status_code} body={r.text[:200]}")
            continue
        flags = {c["cloud"]: c for c in r.json().get("clouds", [])}

        for cloud, (exp_view, exp_prov, exp_upd) in clouds.items():
            expected_flags = {"canView": exp_view, "canProvision": exp_prov, "canUpdate": exp_upd}
            got = flags.get(cloud, {})
            report(
                all(got.get(k) is v for k, v in expected_flags.items()),
                f"{internal_id} session flags[{cloud}] == {expected_flags}",
                f"got {got}",
            )

            # 2. Verb-route gates: match the RBAC matrix AND the session flags.
            for verb, method, path, body, gate_flag in VERBS:
                allowed_expected = expected_flags[gate_flag]
                kwargs = {"cookies": jar}
                if body is not None:
                    kwargs["json"] = body
                resp = client.request(method, path.format(cloud=cloud), **kwargs)
                allowed_actual = resp.status_code != 403

                ok = allowed_actual == allowed_expected
                # Denied must be a proper authz_forbidden, not some other 403.
                if not allowed_expected:
                    err = ""
                    try:
                        err = resp.json().get("error", "")
                    except Exception:
                        pass
                    ok = ok and resp.status_code == 403 and err == "authz_forbidden"
                # Consistency invariant: gate outcome == flag the portal saw.
                consistent = allowed_actual == bool(got.get(gate_flag))
                report(
                    ok and consistent,
                    f"{internal_id} {verb}/{cloud} -> {'allow' if allowed_expected else 'deny '}",
                    f"http={resp.status_code} expected_allow={allowed_expected} "
                    f"session_flag={got.get(gate_flag)} body={resp.text[:160]}",
                )

    print()
    print(f"=== Summary: {PASS} passed, {FAIL} failed ===")
    if FAIL:
        print("Failed checks:")
        for f in FAILURES:
            print(f"  - {f}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
