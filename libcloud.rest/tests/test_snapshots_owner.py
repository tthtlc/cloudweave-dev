"""Tests for GET /v1/compute/snapshots?owner=... (AWS owner scoping).

The EC2 driver's list_snapshots() without an owner returns ALL public
snapshots (DescribeSnapshots default — tens of thousands), so inventory
callers pass owner="self". The driver is faked at
``app.compute.service.build_driver``; no AWS backend needed.
"""

from types import SimpleNamespace

import pytest

from app.compute import service as compute_service_module


class FakeEC2Driver:
    def __init__(self):
        self.owner_seen = None
        self.snapshots = [
            SimpleNamespace(id="snap-1", name="bkp", state="completed", extra={}),
        ]

    def list_snapshots(self, snapshot=None, owner=None):
        self.owner_seen = owner
        return self.snapshots


@pytest.fixture
def fake_driver(monkeypatch):
    driver = FakeEC2Driver()
    monkeypatch.setattr(compute_service_module, "build_driver", lambda connection: driver)
    return driver


@pytest.fixture
def read_headers(mint_token, auth_headers, connection_header):
    return auth_headers(mint_token(["compute:read"]), connection_header)


def test_list_snapshots_default_has_no_owner(client, fake_driver, read_headers):
    r = client.get("/v1/compute/snapshots", headers=read_headers)
    assert r.status_code == 200, r.text
    assert fake_driver.owner_seen is None
    assert [s["id"] for s in r.json()["data"]] == ["snap-1"]


def test_list_snapshots_owner_self_passed_through(client, fake_driver, read_headers):
    r = client.get("/v1/compute/snapshots?owner=self", headers=read_headers)
    assert r.status_code == 200, r.text
    assert fake_driver.owner_seen == "self"
    assert r.json()["data"][0]["state"] == "completed"
