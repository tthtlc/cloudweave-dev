"""Functional tests for the AWS VPC primitives added for the bastion +
internal private server scenario (test_script/scripts/provision_aws_private.sh):

  POST /v1/compute/security-groups/{id}:authorize
  GET/POST /v1/compute/internet-gateways
  GET/POST /v1/compute/route-tables
  POST /v1/compute/route-tables/{id}/routes
  POST /v1/compute/route-tables/{id}:associate

The EC2 driver is faked at ``app.network.service.build_driver`` so no AWS
backend is needed; the tests exercise route registration, the policies.json
scope gate (compute:network:manage / compute:network:read), the service logic
and the response serializers.
"""

from types import SimpleNamespace

import pytest

from app.network import service as network_service_module


class FakeEC2Driver:
    """Minimal in-memory stand-in for the EC2 driver's VPC methods."""

    def __init__(self):
        self.networks = [SimpleNamespace(id="vpc-1", name="libcloud-private-vpc", extra={})]
        self.subnets = [SimpleNamespace(id="subnet-pub", name="public", extra={})]
        self.gateways = []
        self.route_tables = []
        self.sg_rules = []  # (direction, group_id, from_port, to_port, cidr_ips, group_pairs)
        self.attached = []

    # VPCs
    def ex_list_networks(self, network_ids=None):
        if network_ids:
            return [n for n in self.networks if n.id in network_ids]
        return self.networks

    # Subnets
    def ex_list_subnets(self, subnet_ids=None):
        if subnet_ids:
            return [s for s in self.subnets if s.id in subnet_ids]
        return self.subnets

    # Internet gateways
    def ex_list_internet_gateways(self, gateway_ids=None, filters=None):
        out = self.gateways
        if gateway_ids:
            out = [g for g in out if g.id in gateway_ids]
        if filters and "attachment.vpc-id" in filters:
            out = [g for g in out if g.vpc_id == filters["attachment.vpc-id"]]
        return out

    def ex_create_internet_gateway(self, name=None):
        gw = SimpleNamespace(id=f"igw-{len(self.gateways) + 1}", name=name, vpc_id=None,
                             state="available", extra={})
        self.gateways.append(gw)
        return gw

    def ex_attach_internet_gateway(self, gateway, network):
        gateway.vpc_id = network.id
        self.attached.append((gateway.id, network.id))
        return True

    # Route tables
    def ex_list_route_tables(self, route_table_ids=None, filters=None):
        out = self.route_tables
        if route_table_ids:
            out = [t for t in out if t.id in route_table_ids]
        return out

    def ex_create_route_table(self, network, name=None):
        rt = SimpleNamespace(id=f"rtb-{len(self.route_tables) + 1}", name=name,
                             routes=[], subnet_associations=[], extra={})
        self.route_tables.append(rt)
        return rt

    def ex_create_route(self, route_table, cidr, internet_gateway=None, **kw):
        route_table.routes.append(
            SimpleNamespace(cidr=cidr, gateway_id=internet_gateway.id if internet_gateway else None,
                            state="active")
        )
        return True

    def ex_associate_route_table(self, route_table, subnet):
        assoc = SimpleNamespace(id=f"rtbassoc-{subnet.id}", subnet_id=subnet.id)
        route_table.subnet_associations.append(assoc)
        return assoc.id

    # Security group rules
    def ex_authorize_security_group_ingress(self, id, from_port, to_port, cidr_ips=None,
                                            group_pairs=None, protocol="tcp", description=None):
        self.sg_rules.append(("ingress", id, from_port, to_port, cidr_ips, group_pairs))
        return True

    def ex_authorize_security_group_egress(self, id, from_port, to_port, cidr_ips,
                                           group_pairs=None, protocol="tcp"):
        self.sg_rules.append(("egress", id, from_port, to_port, cidr_ips, group_pairs))
        return True

    # Subnet attributes (records (subnet_id, attribute, value))
    def ex_modify_subnet_attribute(self, subnet, attribute="auto_public_ip", value=False):
        if attribute not in ("auto_public_ip", "auto_ipv6"):
            raise ValueError(f"Unsupported attribute: {attribute}")
        self.subnet_attrs = getattr(self, "subnet_attrs", [])
        self.subnet_attrs.append((subnet.id, attribute, value))
        return True


@pytest.fixture
def fake_driver(monkeypatch):
    driver = FakeEC2Driver()
    monkeypatch.setattr(network_service_module, "build_driver", lambda connection: driver)
    return driver


@pytest.fixture
def mgr_headers(mint_token, auth_headers, connection_header):
    return auth_headers(mint_token(["compute:network:manage", "compute:network:read"]),
                        connection_header)


def test_authorize_security_group_rule_ingress_cidr(client, fake_driver, mgr_headers):
    r = client.post(
        "/v1/compute/security-groups/sg-1:authorize",
        headers=mgr_headers,
        json={"direction": "ingress", "protocol": "tcp", "from_port": 22, "to_port": 22,
              "cidr_ips": ["10.0.0.0/16"], "description": "SSH"},
    )
    assert r.status_code == 200, r.text
    assert r.json()["data"]["authorized"] is True
    assert fake_driver.sg_rules == [("ingress", "sg-1", 22, 22, ["10.0.0.0/16"], None)]


def test_authorize_security_group_rule_source_group(client, fake_driver, mgr_headers):
    r = client.post(
        "/v1/compute/security-groups/sg-2:authorize",
        headers=mgr_headers,
        json={"direction": "ingress", "from_port": 22, "to_port": 22,
              "source_group_id": "sg-1"},
    )
    assert r.status_code == 200, r.text
    assert fake_driver.sg_rules[0][5] == [{"group_id": "sg-1"}]


def test_authorize_security_group_rule_requires_source(client, fake_driver, mgr_headers):
    r = client.post(
        "/v1/compute/security-groups/sg-1:authorize",
        headers=mgr_headers,
        json={"direction": "ingress", "from_port": 22, "to_port": 22},
    )
    assert r.status_code == 400, r.text


def test_authorize_security_group_rule_scope_gate(client, fake_driver, mint_token,
                                                  auth_headers, connection_header):
    token = mint_token(["compute:read"])  # read-only token must NOT manage rules
    r = client.post(
        "/v1/compute/security-groups/sg-1:authorize",
        headers=auth_headers(token, connection_header),
        json={"direction": "ingress", "from_port": 22, "to_port": 22, "cidr_ips": ["0.0.0.0/0"]},
    )
    assert r.status_code == 403, r.text
    assert fake_driver.sg_rules == []


def test_internet_gateway_create_attaches_and_lists(client, fake_driver, mgr_headers):
    r = client.post("/v1/compute/internet-gateways", headers=mgr_headers,
                    json={"name": "libcloud-private-igw", "vpc_id": "vpc-1"})
    assert r.status_code == 200, r.text
    data = r.json()["data"]
    assert data["id"] == "igw-1"
    assert fake_driver.attached == [("igw-1", "vpc-1")]

    r = client.get("/v1/compute/internet-gateways?vpc_id=vpc-1", headers=mgr_headers)
    assert r.status_code == 200, r.text
    items = r.json()["data"]
    assert len(items) == 1 and items[0]["vpc_id"] == "vpc-1"


def test_internet_gateway_create_unknown_vpc(client, fake_driver, mgr_headers):
    r = client.post("/v1/compute/internet-gateways", headers=mgr_headers,
                    json={"name": "x", "vpc_id": "vpc-nope"})
    assert r.status_code == 404, r.text


def test_route_table_create_route_and_associate(client, fake_driver, mgr_headers):
    client.post("/v1/compute/internet-gateways", headers=mgr_headers,
                json={"name": "igw", "vpc_id": "vpc-1"})
    r = client.post("/v1/compute/route-tables", headers=mgr_headers,
                    json={"name": "libcloud-public-rtb", "vpc_id": "vpc-1"})
    assert r.status_code == 200, r.text
    rtb_id = r.json()["data"]["id"]
    assert rtb_id == "rtb-1"

    r = client.post(f"/v1/compute/route-tables/{rtb_id}/routes", headers=mgr_headers,
                    json={"cidr_block": "0.0.0.0/0", "internet_gateway_id": "igw-1"})
    assert r.status_code == 200, r.text
    assert r.json()["data"]["created"] is True

    r = client.post(f"/v1/compute/route-tables/{rtb_id}:associate", headers=mgr_headers,
                    json={"subnet_id": "subnet-pub"})
    assert r.status_code == 200, r.text
    assert r.json()["data"]["association_id"] == "rtbassoc-subnet-pub"

    # The serialized route table exposes routes + subnet associations so the
    # provisioning script can stay idempotent.
    r = client.get(f"/v1/compute/route-tables?id={rtb_id}", headers=mgr_headers)
    assert r.status_code == 200, r.text
    data = r.json()["data"][0]
    assert data["routes"] == [{"cidr": "0.0.0.0/0", "gateway_id": "igw-1", "state": "active"}]
    assert data["subnet_associations"] == [{"id": "rtbassoc-subnet-pub", "subnet_id": "subnet-pub"}]


def test_route_table_scope_gate(client, fake_driver, mint_token, auth_headers, connection_header):
    token = mint_token(["compute:read"])
    r = client.post("/v1/compute/route-tables", headers=auth_headers(token, connection_header),
                    json={"name": "x", "vpc_id": "vpc-1"})
    assert r.status_code == 403, r.text
    assert fake_driver.route_tables == []


def test_subnet_auto_public_ip_resolves_subnet_object(client, fake_driver, mgr_headers):
    # Regression: the service must resolve the EC2NetworkSubnet object and pass
    # the driver's own attribute name ("auto_public_ip"), not the AWS API name.
    r = client.patch("/v1/compute/subnets/subnet-pub", headers=mgr_headers,
                     json={"action": "auto_public_ip", "value": True})
    assert r.status_code == 200, r.text
    assert r.json()["data"] == {"id": "subnet-pub", "action": "auto_public_ip", "success": True}
    assert fake_driver.subnet_attrs == [("subnet-pub", "auto_public_ip", True)]


def test_subnet_auto_public_ip_unknown_subnet(client, fake_driver, mgr_headers):
    r = client.patch("/v1/compute/subnets/subnet-nope", headers=mgr_headers,
                     json={"action": "auto_public_ip", "value": True})
    assert r.status_code == 404, r.text


def test_route_table_without_name_tag_serializes(client, fake_driver, mgr_headers):
    # Regression: libcloud<=3.9.1's _to_route_table falls back to
    # tags.get("Name", id) with the *builtin* id() when the table has no Name
    # tag; the serializer must never let that non-str "name" reach the JSON
    # encoder (it 500'd GET /v1/compute/route-tables on real AWS).
    fake_driver.route_tables.append(
        SimpleNamespace(id="rtb-noname", name=id, routes=[], subnet_associations=[], extra={})
    )
    r = client.get("/v1/compute/route-tables", headers=mgr_headers)
    assert r.status_code == 200, r.text
    assert r.json()["data"][0]["name"] is None
