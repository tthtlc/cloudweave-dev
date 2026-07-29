"""End-to-end authorization tests for the route-class + policy-table design.

These verify that route handlers contain no authz logic yet are still
authorized by ``AuthorizedAPIRoute`` reading ``app/auth/policies.json``.
"""

import pytest

from app.auth.models import TokenClaims
from app.auth.policy import PolicyEngine
from app.common.errors import APIError
from app.compute import service as compute_service
from app.jobs.worker import job_store


def test_check_scopes_passes_with_granted_scope(mint_token):
    eng = PolicyEngine()
    claims = TokenClaims(
        sub="u", iss="i", aud="a", iat=0, nbf=0, exp=0, jti="j",
        scope="jobs:read", tenant_id="t", allowed_providers=["*"], session_id="s",
    )
    eng.check_scopes(claims, ["jobs:read"])  # no raise


def test_check_scopes_rejects_missing_scope(mint_token):
    eng = PolicyEngine()
    claims = TokenClaims(
        sub="u", iss="i", aud="a", iat=0, nbf=0, exp=0, jti="j",
        scope="compute:read", tenant_id="t", allowed_providers=["*"], session_id="s",
    )
    with pytest.raises(APIError) as exc:
        eng.check_scopes(claims, ["jobs:read"])
    assert exc.value.code == "auth_insufficient_scope"
    assert exc.value.status_code == 403


# --------------------------------------------------------------------------- #
# Live route tests
# --------------------------------------------------------------------------- #
def test_list_locations_authorized(client, auth_headers, connection_header, monkeypatch, mint_token):
    monkeypatch.setattr(compute_service.compute_service, "list_locations", lambda conn: [])
    token = mint_token(["compute:location:read"])
    r = client.get(
        "/v1/compute/locations",
        headers=auth_headers(token, connection_header),
    )
    assert r.status_code == 200, r.text
    assert r.json()["data"] == []


def test_list_locations_compute_read_alias_accepted(client, auth_headers, connection_header, monkeypatch, mint_token):
    # compute:read is an alias for compute:location:read (READ_SCOPE_ALIASES).
    monkeypatch.setattr(compute_service.compute_service, "list_locations", lambda conn: [])
    token = mint_token(["compute:read"])
    r = client.get(
        "/v1/compute/locations",
        headers=auth_headers(token, connection_header),
    )
    assert r.status_code == 200, r.text


def test_list_locations_rejected_without_scope(client, auth_headers, connection_header, mint_token):
    token = mint_token(["jobs:read"])  # no compute scopes
    r = client.get(
        "/v1/compute/locations",
        headers=auth_headers(token, connection_header),
    )
    assert r.status_code == 403
    assert r.json()["error"]["code"] == "auth_insufficient_scope"


def test_missing_token_is_401(client, connection_header, mint_token):
    r = client.get(
        "/v1/compute/locations",
        headers={"X-Provider-Connection": connection_header},
    )
    assert r.status_code == 401


def test_missing_connection_is_400(client, auth_headers, mint_token):
    token = mint_token(["compute:location:read"])
    r = client.get("/v1/compute/locations", headers=auth_headers(token))
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "invalid_connection"


def test_update_node_action_update_requires_node_update_scope(client, auth_headers, connection_header, monkeypatch, mint_token):
    monkeypatch.setattr(compute_service.compute_service, "update_node", lambda conn, nid, body: {"id": nid})
    # action=update -> authz_scope compute:node:update
    token = mint_token(["compute:node:update"])
    r = client.patch(
        "/v1/compute/nodes/node_1",
        json={"action": "update", "name": "new"},
        headers=auth_headers(token, connection_header),
    )
    assert r.status_code == 200, r.text


def test_update_node_action_resize_rejected_with_only_update_scope(client, auth_headers, connection_header, monkeypatch, mint_token):
    # action=resize -> authz_scope compute:node:power; token only has node:update.
    monkeypatch.setattr(compute_service.compute_service, "update_node", lambda conn, nid, body: {"id": nid})
    token = mint_token(["compute:node:update"])
    r = client.patch(
        "/v1/compute/nodes/node_1",
        json={"action": "resize", "new_size_id": "s-1"},
        headers=auth_headers(token, connection_header),
    )
    assert r.status_code == 403
    assert r.json()["error"]["code"] == "auth_insufficient_scope"


def test_update_node_action_resize_allowed_with_power_scope(client, auth_headers, connection_header, monkeypatch, mint_token):
    monkeypatch.setattr(compute_service.compute_service, "update_node", lambda conn, nid, body: {"id": nid})
    token = mint_token(["compute:node:power"])
    r = client.patch(
        "/v1/compute/nodes/node_1",
        json={"action": "resize", "new_size_id": "s-1"},
        headers=auth_headers(token, connection_header),
    )
    assert r.status_code == 200, r.text


def test_jobs_connectionless_scope_gate(client, auth_headers, mint_token):
    token = mint_token(["jobs:read"])
    job = job_store.create(
        operation="x",
        requested_by="tester",
        token_jti="j",
        connection_target="aws:default",
        provider="aws",
        scope_snapshot="jobs:read",
        request_payload_redacted={},
    )
    r = client.get(f"/v1/jobs/{job.id}", headers=auth_headers(token))
    assert r.status_code == 200, r.text
    assert r.json()["data"]["id"] == job.id


def test_jobs_rejected_without_jobs_read_scope(client, auth_headers, mint_token):
    token = mint_token(["compute:read"])
    job = job_store.create(
        operation="x",
        requested_by="tester",
        token_jti="j",
        connection_target="aws:default",
        provider="aws",
        scope_snapshot="jobs:read",
        request_payload_redacted={},
    )
    r = client.get(f"/v1/jobs/{job.id}", headers=auth_headers(token))
    assert r.status_code == 403


def test_admin_policies_reload_requires_admin_scope(client, auth_headers, mint_token):
    token = mint_token(["jobs:read"])
    r = client.post("/v1/admin/policies:reload", headers=auth_headers(token))
    assert r.status_code == 403


def test_admin_policies_reload_succeeds_with_admin_scope(client, auth_headers, mint_token):
    token = mint_token(["admin:connections:read"])
    r = client.post("/v1/admin/policies:reload", headers=auth_headers(token))
    assert r.status_code == 200, r.text
    assert r.json()["data"]["reloaded"] is True
    assert r.json()["data"]["entries"] == 63
