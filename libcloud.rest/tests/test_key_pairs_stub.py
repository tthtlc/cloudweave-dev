"""Test for GET /v1/compute/key-pairs with a driver that only has the base
stub: NodeDriver.list_key_pairs raises NotImplementedError (e.g. Nutanix),
which hasattr() cannot detect. The API must answer 501, not 500.
"""

from types import SimpleNamespace

import pytest

from app.compute import service as compute_service_module


class BaseStubDriver:
    """Mimics a driver without a real list_key_pairs implementation."""

    def list_key_pairs(self):
        raise NotImplementedError("list_key_pairs not implemented for this driver")


@pytest.fixture
def stub_driver(monkeypatch):
    monkeypatch.setattr(
        compute_service_module, "build_driver", lambda connection: BaseStubDriver()
    )


def test_list_key_pairs_base_stub_returns_501(client, stub_driver, mint_token,
                                              auth_headers, connection_header):
    headers = auth_headers(mint_token(["compute:read"]), connection_header)
    r = client.get("/v1/compute/key-pairs", headers=headers)
    assert r.status_code == 501, r.text
    assert r.json()["error"]["code"] == "provider_capability_unsupported"
