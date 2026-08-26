***

## Nutanix AHV Provisioning (aCLI)

### Architecture Overview

| Component | Network/VLAN | Purpose |
|---|---|---|
| Bastion Host | VLAN 100 (with external routing) | SSH jump server |
| Internal Server 1–3 | VLAN 200 (isolated) | Application servers |

All commands are run via SSH into the CVM and entering the `acli` shell. [nutanixbible](https://www.nutanixbible.com/19b-cli.html)

### Step 1: Create Networks (VLANs)

```bash
acli net.create vlan100-external vlan=100
acli net.create vlan200-internal vlan=200
```

Verify network creation: [magander](https://magander.se/create-nutanix-ahv-virtual-machine-via-command-line/)

```bash
acli net.list
```

Assign an IP pool to the external VLAN for bastion IP assignment:

```bash
acli net.update_vlan100-external ip_config="
  {
    \"network\": \"10.1.100.0/24\",
    \"default_gateway\": \"10.1.100.1\",
    \"dhcp_server\": null,
    \"ip_pool\": [\"10.1.100.10-10.1.100.50\"]
  }"
```

Assign an IP pool to the internal VLAN:

```bash
acli net.update_vlan200-internal ip_config="
  {
    \"network\": \"10.1.200.0/24\",
    \"default_gateway\": \"10.1.200.1\",
    \"dhcp_server\": null,
    \"ip_pool\": [\"10.1.200.10-10.1.200.50\"]
  }"
```

### Step 2: Upload the Base OS Image

Upload a CentOS/Ubuntu qcow2 image to the Prism Image Service: [youtube](https://www.youtube.com/watch?v=f5HpijqXoU8)

```bash
acli image.create centos7-base \
  image_type=kDiskImage \
  source_url=http://your-repo/centos7.qcow2
```

Verify the image is available:

```bash
acli image.list
```

List available storage containers:

```bash
ncli ctr ls | grep Name
```

### Step 3: Create the Bastion Host VM

```bash
# Create the VM with 2 vCPUs and 4GB RAM
acli vm.create bastion-host num_vcpus=2 num_cores_per_vcpu=1 memory=4G

# Attach the OS disk from the uploaded image
acli vm.disk_create bastion-host clone_from_image=centos7-base

# Add a data disk (20GB) on the default storage container
acli vm.disk_create bastion-host bus=scsi create_size=20G container=default

# Attach NIC to the external VLAN with a specific IP
acli vm.nic_create bastion-host network=vlan100-external request_ip=true

# Power on the VM
acli vm.on bastion-host
```

### Step 4: Create 3 Internal Server VMs

Use a loop to create all three internal servers: [virtuallyvtrue](https://virtuallyvtrue.com/2019/11/21/nutanix-vm-handling-administration-via-scripts/)

```bash
for i in 1 2 3; do
  # Create the VM
  acli vm.create internal-server-$i num_vcpus=2 num_cores_per_vcpu=1 memory=4G

  # Attach OS disk from the base image
  acli vm.disk_create internal-server-$i clone_from_image=centos7-base

  # Add a data disk (20GB)
  acli vm.disk_create internal-server-$i bus=scsi create_size=20G container=default

  # Attach NIC to the internal VLAN (no external routing)
  acli vm.nic_create internal-server-$i network=vlan200-internal request_ip=true

  # Power on
  acli vm.on internal-server-$i
done
```

### Step 5: Verify VM Creation and IP Assignment

```bash
# List all VMs and their status
acli vm.list

# Get detailed info including IP addresses
acli vm.get bastion-host
acli vm.get internal-server-1
acli vm.get internal-server-2
acli vm.get internal-server-3
```

### Step 6: Nutanix Flow Network Security (Firewall Rules)

Nutanix Flow Network Security provides microsegmentation through Prism Central, using category-based security policies. While Flow is primarily managed through the Prism Central UI or REST API, you can also interact with it programmatically. [nutanix](https://www.nutanix.com/content/dam/nutanix/documents/certifications/flow-network-security-guide.pdf)

#### 6a: Assign Categories to VMs

Categories are the foundation of Flow policies — VMs are grouped by category values, and policies reference these values: [nutanixbible](https://www.nutanixbible.com/12a-book-of-network-services-flow-network-security.html)

```bash
# Assign category "AppRole" to each VM via Prism Central REST API
# (Run from a host with API access to Prism Central)

PC_IP="prism-central-ip"
PC_USER="admin"
PC_PASS="your-password"

# Assign bastion to AppRole=bastion
curl -k -u $PC_USER:$PC_PASS \
  -X POST \
  -H "Content-Type: application/json" \
  https://$PC_IP:9440/api/nutanix/v3/services/nutanix_v3/vms/bastion-uuid \
  -d '{
    "metadata": {"kind": "vm", "categories": {"AppRole": "bastion"}},
    "spec": {"name": "bastion-host", "resources": {}}
  }'

# Assign internal servers to AppRole=internal
for uuid in internal-uuid-1 internal-uuid-2 internal-uuid-3; do
  curl -k -u $PC_USER:$PC_PASS \
    -X POST \
    -H "Content-Type: application/json" \
    https://$PC_IP:9440/api/nutanix/v3/services/nutanix_v3/vms/$uuid \
    -d "{
      \"metadata\": {\"kind\": \"vm\", \"categories\": {\"AppRole\": \"internal\"}},
      \"spec\": {\"name\": \"internal-server\", \"resources\": {}}
    }"
done
```

#### 6b: Create Flow Security Policies via REST API

Create an isolation policy that blocks all traffic between the `internal` category VMs and external networks, except for SSH from the bastion: [nutanix](https://www.nutanix.dev/2021/06/21/network-automation-nutanix-flow-security-policies-via-rest-api/)

```bash
# Create a security policy: Allow SSH from bastion to internal, block all else
curl -k -u $PC_USER:$PC_PASS \
  -X POST \
  -H "Content-Type: application/json" \
  https://$PC_IP:9440/api/nutanix/v3/services/network_security_rules \
  -d '{
    "spec": {
      "name": "bastion-to-internal-ssh",
      "resources": {
        "allow_list": [
          {
            "peer_specification_type": "CATEGORY",
            "peer_category_filter": {"AppRole": "bastion"},
            "protocol": "TCP",
            "transport": {"tcp_port_range_list": [{"start_port": 22, "end_port": 22}]}
          }
        ],
        "target_category_filter": {"AppRole": "internal"},
        "action": "APPLY",
        "is_policy_active": true
      }
    },
    "metadata": {"kind": "network_security_rule"}
  }'
```

Create a default-deny policy for the internal segment:

```bash
curl -k -u $PC_USER:$PC_PASS \
  -X POST \
  -H "Content-Type: application/json" \
  https://$PC_IP:9440/api/nutanix/v3/services/network_security_rules \
  -d '{
    "spec": {
      "name": "internal-default-deny",
      "resources": {
        "allow_list": [],
        "target_category_filter": {"AppRole": "internal"},
        "action": "APPLY",
        "is_policy_active": true
      }
    },
    "metadata": {"kind": "network_security_rule"}
  }'
```

#### 6c: Verify Policy Realization

Check that policies have been realized (enforced) on the VMs: [portal.nutanix](https://portal.nutanix.com/docs/Nutanix-Flow-Network-Security-VLAN-Guide-v4_2_0:mul-rule-realization-status-pc-c.html)

```bash
# Via Prism Central REST API
curl -k -u $PC_USER:$PC_PASS \
  -X GET \
  https://$PC_IP:9440/api/nutanix/v3/services/network_security_rules \
  | python3 -m json.tool
```

### Step 7: Routing Configuration (Nutanix Flow Virtual Networking)

If using Nutanix Flow Virtual Networking (VPC), configure routing between the external and internal VLANs through a virtual router or external gateway: [saptarshi-biswas-999.medium](https://saptarshi-biswas-999.medium.com/policy-based-routing-within-nutanix-vpc-using-paloalto-networks-vm-series-firewall-9e53d788a682)

#### Option A: External Router/Gateway

Configure your physical network's router/firewall (e.g., Palo Alto, FortiGate) to handle inter-VLAN routing:

```
# Router configuration (example for a Linux-based router or firewall):
# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1

# Route between VLAN 100 (10.1.100.0/24) and VLAN 200 (10.1.200.0/24)
# VLAN 100 interface
ip addr add 10.1.100.1/24 dev eth0.100
# VLAN 200 interface
ip addr add 10.1.200.1/24 dev eth0.200

# Firewall rules: allow SSH from VLAN 100 to VLAN 200 only
iptables -A FORWARD -i eth0.100 -o eth0.200 -p tcp --dport 22 -j ACCEPT
iptables -A FORWARD -i eth0.200 -o eth0.100 -m state --state ESTABLISHED,RELATED -j ACCEPT
# Default deny
iptables -A FORWARD -j DROP

# NAT for internal VLAN egress (optional, if internet access needed)
iptables -t nat -A POSTROUTING -s 10.1.200.0/24 -o eth0 -j MASQUERADE
```

#### Option B: Nutanix Flow VPC with NAT

If using Nutanix Flow Virtual Networking with VPCs, configure a VPC with external subnets and NAT: [portal.nutanix](https://portal.nutanix.com/page/documents/solutions/details?targetId=TN-2207-NKP-Flow-Virtual-Networking:bastion-host.html)

```bash
# Create a VPC via Prism Central REST API
curl -k -u $PC_USER:$PC_PASS \
  -X POST \
  -H "Content-Type: application/json" \
  https://$PC_IP:9440/api/nutanix/v3/services/vpcs \
  -d '{
    "spec": {
      "name": "prod-vpc",
      "resources": {
        "common_domain_name_server_ip_list": [{"ip": "8.8.8.8"}],
        "external_subnet_list": [{"external_subnet_reference": "external-subnet-uuid"}]
      }
    },
    "metadata": {"kind": "vpc"}
  }'
```

### Nutanix Network Diagram Summary

```
External Network
       ↓
  VLAN 100 (10.1.100.0/24)
       └── Bastion Host (SSH:22 from corp IP)
              ↓ (Flow policy: SSH only to internal)
       ┌── Router/Firewall (inter-VLAN routing) ──┐
       ↓                                          ↓
  VLAN 200 (10.1.200.0/24)
       ├── Internal Server 1 (SSH:22 from bastion)
       ├── Internal Server 2 (SSH:22 from bastion)
       └── Internal Server 3 (SSH:22 from bastion)
```

## Post-Provisioning Hardening (Both Platforms)

On each server, apply these baseline configurations:

```bash
# Disable root SSH login
sudo sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

# Disable password authentication (key-only)
sudo sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

# Restart SSH
sudo systemctl restart sshd

# Enable and configure firewalld (on internal servers)
sudo systemctl enable firewalld
sudo systemctl start firewalld

# Allow SSH from bastion IP only
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.1.100.10" port port="22" protocol="tcp" accept'

# Drop all other inbound
sudo firewall-cmd --permanent --set-default-zone=drop
sudo firewall-cmd --reload
```
