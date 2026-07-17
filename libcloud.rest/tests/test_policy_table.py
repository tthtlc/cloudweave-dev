"""Unit tests for the external, hot-reloadable policy table."""

import json
import os
import time

import pytest

from app.auth.policy_table import PolicyTable
from app.common.errors import APIError


def _write(path, data):
    with open(path, "w") as fh:
        json.dump(data, fh)


def test_load_and_get(tmp_path):
    f = tmp_path / "policies.json"
    _write(f, {
        "_comment": "metadata is ignored",
        "GET /v1/compute/locations": {
            "scopes_any_of": ["compute:location:read", "compute:read"],
            "authz_scope": "compute:location:read",
        },
    })
    table = PolicyTable(str(f))
    entry = table.get("GET /v1/compute/locations")
    assert entry["scopes_any_of"] == ["compute:location:read", "compute:read"]
    assert entry["authz_scope"] == "compute:location:read"
    # defaults applied
    assert entry["capability"] is None
    assert entry["connection_required"] is True


def test_unknown_operation_fail_closed(tmp_path):
    f = tmp_path / "policies.json"
    _write(f, {"GET /v1/compute/locations": {"scopes_any_of": ["compute:read"]}})
    table = PolicyTable(str(f))
    with pytest.raises(APIError) as exc:
        table.get("DELETE /v1/does/not/exist")
    assert exc.value.code == "policy_unknown_operation"
    assert exc.value.status_code == 500


def test_invalid_entry_missing_scopes(tmp_path):
    f = tmp_path / "policies.json"
    _write(f, {"GET /x": {"capability": None}})
    with pytest.raises(APIError) as exc:
        PolicyTable(str(f))
    assert exc.value.code == "policy_table_invalid"


def test_hot_reload_on_mtime_change(tmp_path):
    f = tmp_path / "policies.json"
    _write(f, {"GET /x": {"scopes_any_of": ["compute:read"]}})
    table = PolicyTable(str(f))
    assert table.get("GET /x")["scopes_any_of"] == ["compute:read"]

    # Bump mtime into the future so the stat check sees a change.
    _write(f, {"GET /x": {"scopes_any_of": ["compute:location:read"]}})
    future = time.time() + 5
    os.utime(str(f), (future, future))

    assert table.get("GET /x")["scopes_any_of"] == ["compute:location:read"]


def test_explicit_reload(tmp_path):
    f = tmp_path / "policies.json"
    _write(f, {"GET /x": {"scopes_any_of": ["compute:read"]}})
    table = PolicyTable(str(f))
    _write(f, {"GET /x": {"scopes_any_of": ["compute:network:read"]}})
    future = time.time() + 5
    os.utime(str(f), (future, future))
    entries = table.reload()
    assert entries["GET /x"]["scopes_any_of"] == ["compute:network:read"]
