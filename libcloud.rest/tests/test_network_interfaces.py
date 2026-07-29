"""Functional tests for GET /v1/compute/network-interfaces (AWS ENI listing).

The EC2 driver is faked at ``app.network.service.build_driver`` so no AWS
backend is needed; the tests exercise route registration, the policies.json
scope gate (compute:network:read), the id filter and the response serializer.
"""

from types import SimpleNamespace

import pytest

from app.network import service as network_service_module


class FakeEC2Driver:
    def __init__(self):
        self.interfaces = [
            SimpleNamespace(
                id="eni-1",
                name="eni-1",
                state="in-use",
                extra={"subnet_id": "subnet-pub", "vpc_id": "vpc-1"},
            ),
            SimpleNamespace(
                id="eni-2",
                name="eni-2",
                state="available",
                extra={"subnet_id": "subnet-priv", "vpc_id": "vpc-1"},
            ),
        ]

    def ex_list_network_interfaces(self):
        return self.interfaces


@pytest.fixture
def fake_driver(monkeypatch):
    driver = FakeEC2Driver()
    monkeypatch.setattr(network_service_module, "build_driver", lambda connection: driver)
    return driver


@pytest.fixture
def read_headers(mint_token, auth_headers, connection_header):
    return auth_headers(mint_token(["compute:network:read"]), connection_header)


def test_list_network_interfaces(client, fake_driver, read_headers):
    r = client.get("/v1/compute/network-interfaces", headers=read_headers)
    assert r.status_code == 200, r.text
    items = r.json()["data"]
    assert [i["id"] for i in items] == ["eni-1", "eni-2"]
    assert items[0]["state"] == "in-use"
    assert items[0]["subnet_id"] == "subnet-pub"
    assert items[0]["vpc_id"] == "vpc-1"


def test_list_network_interfaces_id_filter(client, fake_driver, read_headers):
    r = client.get("/v1/compute/network-interfaces?id=eni-2", headers=read_headers)
    assert r.status_code == 200, r.text
    items = r.json()["data"]
    assert len(items) == 1 and items[0]["id"] == "eni-2"


def test_list_network_interfaces_scope_gate(client, fake_driver, mint_token,
                                            auth_headers, connection_header):
    token = mint_token(["compute:node:create"])  # no read scope -> denied
    r = client.get("/v1/compute/network-interfaces",
                   headers=auth_headers(token, connection_header))
    assert r.status_code == 403, r.text


def test_list_network_interfaces_unsupported(client, monkeypatch, read_headers):
    # A driver without ex_list_network_interfaces -> 501 (e.g. Nutanix).
    monkeypatch.setattr(
        network_service_module, "build_driver", lambda connection: SimpleNamespace()
    )
    r = client.get("/v1/compute/network-interfaces", headers=read_headers)
    assert r.status_code == 501, r.text
