
Below is a detailed, CLI-driven provisioning guide for deploying **1 bastion host + 3 internal servers** on both **AWS** and **Nutanix AHV**, including firewall and routing configurations for each platform.

***

## AWS Provisioning (AWS CLI)

### Architecture Overview

| Component | Subnet | CIDR | Purpose |
|---|---|---|---|
| Bastion Host | Public | 10.0.0.0/24 | SSH jump server, internet-facing |
| Internal Server 1–3 | Private | 10.0.16.0/24 | Application servers, no direct internet |

### Step 1: Create the VPC

```bash
AWS_VPC=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --query 'Vpc.VpcId' \
  --output text)

aws ec2 create-tags \
  --resources $AWS_VPC \
  --tags Key=Name,Value=prod-vpc
```

Enable DNS hostname resolution and DNS support: [dev](https://dev.to/mkabumattar/how-to-setup-bastion-host-on-aws-using-aws-cli-l9o)

```bash
aws ec2 modify-vpc-attribute \
  --vpc-id $AWS_VPC \
  --enable-dns-hostnames "{\"Value\":true}"

aws ec2 modify-vpc-attribute \
  --vpc-id $AWS_VPC \
  --enable-dns-support "{\"Value\":true}"
```

### Step 2: Create Public and Private Subnets

```bash
AWS_PUBLIC_SUBNET=$(aws ec2 create-subnet \
  --vpc-id $AWS_VPC \
  --cidr-block 10.0.0.0/24 \
  --query 'Subnet.SubnetId' \
  --output text)

AWS_PRIVATE_SUBNET=$(aws ec2 create-subnet \
  --vpc-id $AWS_VPC \
  --cidr-block 10.0.16.0/24 \
  --query 'Subnet.SubnetId' \
  --output text)

aws ec2 create-tags --resources $AWS_PUBLIC_SUBNET --tags Key=Name,Value=public-subnet
aws ec2 create-tags --resources $AWS_PRIVATE_SUBNET --tags Key=Name,Value=private-subnet
```

Enable auto-assign public IP on the public subnet: [dev](https://dev.to/mkabumattar/how-to-setup-bastion-host-on-aws-using-aws-cli-l9o)

```bash
aws ec2 modify-subnet-attribute \
  --subnet-id $AWS_PUBLIC_SUBNET \
  --map-public-ip-on-launch
```

### Step 3: Create and Attach Internet Gateway

```bash
AWS_INTERNET_GATEWAY=$(aws ec2 create-internet-gateway \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)

aws ec2 attach-internet-gateway \
  --vpc-id $AWS_VPC \
  --internet-gateway-id $AWS_INTERNET_GATEWAY
```

### Step 4: Create NAT Gateway for Private Subnet Egress

Allocate an Elastic IP and create the NAT Gateway in the public subnet: [dev](https://dev.to/mkabumattar/how-to-setup-bastion-host-on-aws-using-aws-cli-l9o)

```bash
AWS_ELASTIC_IP=$(aws ec2 allocate-address \
  --domain vpc \
  --query 'AllocationId' \
  --output text)

AWS_NAT_GATEWAY=$(aws ec2 create-nat-gateway \
  --subnet-id $AWS_PUBLIC_SUBNET \
  --allocation-id $AWS_ELASTIC_IP \
  --query 'NatGateway.NatGatewayId' \
  --output text)
```

Wait for the NAT Gateway to become available:

```bash
aws ec2 wait nat-gateway-available --nat-gateway-ids $AWS_NAT_GATEWAY
```

### Step 5: Configure Route Tables

**Public route table** — routes `0.0.0.0/0` to the Internet Gateway:

```bash
AWS_PUBLIC_ROUTE_TABLE=$(aws ec2 create-route-table \
  --vpc-id $AWS_VPC \
  --query 'RouteTable.RouteTableId' \
  --output text)

aws ec2 create-route \
  --route-table-id $AWS_PUBLIC_ROUTE_TABLE \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $AWS_INTERNET_GATEWAY

aws ec2 associate-route-table \
  --route-table-id $AWS_PUBLIC_ROUTE_TABLE \
  --subnet-id $AWS_PUBLIC_SUBNET
```

**Private route table** — routes `0.0.0.0/0` to the NAT Gateway:

```bash
AWS_PRIVATE_ROUTE_TABLE=$(aws ec2 create-route-table \
  --vpc-id $AWS_VPC \
  --query 'RouteTable.RouteTableId' \
  --output text)

aws ec2 create-route \
  --route-table-id $AWS_PRIVATE_ROUTE_TABLE \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id $AWS_NAT_GATEWAY

aws ec2 associate-route-table \
  --route-table-id $AWS_PRIVATE_ROUTE_TABLE \
  --subnet-id $AWS_PRIVATE_SUBNET
```

### Step 6: Create Security Groups (Firewall Rules)

**Bastion Security Group** — allows SSH from your IP only:

```bash
AWS_BASTION_SG=$(aws ec2 create-security-group \
  --group-name bastion-sg \
  --description "Security group for bastion host" \
  --vpc-id $AWS_VPC \
  --query 'GroupId' \
  --output text)

# Inbound: SSH from your corporate IP only
aws ec2 authorize-security-group-ingress \
  --group-id $AWS_BASTION_SG \
  --protocol tcp \
  --port 22 \
  --cidr YOUR_CORPORATE_IP/32

# Outbound: allow all
aws ec2 authorize-security-group-egress \
  --group-id $AWS_BASTION_SG \
  --protocol all \
  --port all \
  --cidr 0.0.0.0/0
```

**Internal Servers Security Group** — allows SSH from bastion SG only, plus app traffic:

```bash
AWS_INTERNAL_SG=$(aws ec2 create-security-group \
  --group-name internal-sg \
  --description "Security group for internal servers" \
  --vpc-id $AWS_VPC \
  --query 'GroupId' \
  --output text)

# Inbound: SSH from bastion security group only
aws ec2 authorize-security-group-ingress \
  --group-id $AWS_INTERNAL_SG \
  --protocol tcp \
  --port 22 \
  --source-security-group-id $AWS_BASTION_SG

# Inbound: application port (e.g., 8080) from VPC only
aws ec2 authorize-security-group-ingress \
  --group-id $AWS_INTERNAL_SG \
  --protocol tcp \
  --port 8080 \
  --cidr 10.0.0.0/16

# Outbound: allow all
aws ec2 authorize-security-group-egress \
  --group-id $AWS_INTERNAL_SG \
  --protocol all \
  --port all \
  --cidr 0.0.0.0/0
```

### Step 7: Create a Key Pair

```bash
aws ec2 create-key-pair \
  --key-name prod-keypair \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/prod-keypair.pem

chmod 400 ~/.ssh/prod-keypair.pem
```

### Step 8: Get the Latest AMI ID

```bash
AWS_AMI=$(aws ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' \
  --output text)
```

### Step 9: Launch the Bastion Host

```bash
AWS_BASTION=$(aws ec2 run-instances \
  --image-id $AWS_AMI \
  --count 1 \
  --instance-type t3.micro \
  --key-name prod-keypair \
  --security-group-ids $AWS_BASTION_SG \
  --subnet-id $AWS_PUBLIC_SUBNET \
  --associate-public-ip-address \
  --query 'Instances[0].InstanceId' \
  --output text)

aws ec2 create-tags \
  --resources $AWS_BASTION \
  --tags Key=Name,Value=bastion-host
```

### Step 10: Launch 3 Internal Servers

```bash
for i in 1 2 3; do
  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $AWS_AMI \
    --count 1 \
    --instance-type t3.micro \
    --key-name prod-keypair \
    --security-group-ids $AWS_INTERNAL_SG \
    --subnet-id $AWS_PRIVATE_SUBNET \
    --query 'Instances[0].InstanceId' \
    --output text)

  aws ec2 create-tags \
    --resources $INSTANCE_ID \
    --tags Key=Name,Value=internal-server-$i
done
```

### Step 11: SSH Proxy Through Bastion

Configure `~/.ssh/config` for proxy jumping:

```
Host bastion
  HostName <BASTION_PUBLIC_IP>
  User ec2-user
  IdentityFile ~/.ssh/prod-keypair.pem

Host internal-*
  User ec2-user
  IdentityFile ~/.ssh/prod-keypair.pem
  ProxyJump bastion
```

Then connect to internal servers:

```bash
ssh internal-server-1
```

### AWS Network Diagram Summary

```
Internet → IGW → Public Subnet (10.0.0.0/24)
                      ├── Bastion Host (SSH:22 from corp IP)
                      └── NAT Gateway
                              ↓
                    Private Subnet (10.0.16.0/24)
                      ├── Internal Server 1 (SSH:22 from bastion SG)
                      ├── Internal Server 2 (SSH:22 from bastion SG)
                      └── Internal Server 3 (SSH:22 from bastion SG)
```

