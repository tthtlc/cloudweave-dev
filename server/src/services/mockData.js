// Mock dataset used when REACT_APP_MOCK_MODE=true.
//
// Models the "internal user" abstraction the backend identity service owns.
// Each internal user has:
//   - internalUserId  : stable platform identity (NOT the provider subject)
//   - email           : display + collapse heuristic
//   - role            : superadmin | owner | admin | viewer
//   - linkedIdentities: array of "provider:subject" strings (google:/github:)
//
// The predefined superadmin is pregenerated (never goes through first-login).

export const MOCK_USERS = [
  {
    internalUserId: "int-superadmin-0000",
    email: "superadmin@libcloud.local",
    displayName: "Root Superadmin",
    role: "superadmin",
    linkedIdentities: ["google:108214000000000000001"],
    createdAt: "2025-01-01T00:00:00Z",
  },
  {
    internalUserId: "int-owner-0001",
    email: "owner@libcloud.local",
    displayName: "Tenant Owner",
    role: "owner",
    tenant: "aws",
    linkedIdentities: ["google:108214000000000000002"],
    createdAt: "2025-02-10T00:00:00Z",
  },
  {
    internalUserId: "int-admin-0002",
    email: "admin@libcloud.local",
    displayName: "Cloud Admin",
    role: "admin",
    tenant: "aws",
    linkedIdentities: ["github:67890", "google:108214000000000000003"],
    createdAt: "2025-03-15T00:00:00Z",
  },
  {
    internalUserId: "int-viewer-0003",
    email: "viewer@libcloud.local",
    displayName: "Read-only Viewer",
    role: "viewer",
    tenant: "aws",
    linkedIdentities: ["github:11111"],
    createdAt: "2025-04-20T00:00:00Z",
  },
  {
    internalUserId: "int-owner-ntnx-0004",
    email: "ntnx-owner@libcloud.local",
    displayName: "Nutanix Tenant Owner",
    role: "owner",
    tenant: "nutanix",
    linkedIdentities: ["google:108214000000000000004"],
    createdAt: "2025-05-01T00:00:00Z",
  },
  {
    internalUserId: "int-admin-ntnx-0005",
    email: "ntnx-admin@libcloud.local",
    displayName: "Nutanix Cloud Admin",
    role: "admin",
    tenant: "nutanix",
    linkedIdentities: ["github:22222", "google:108214000000000000005"],
    createdAt: "2025-05-02T00:00:00Z",
  },
  {
    internalUserId: "int-viewer-ntnx-0006",
    email: "ntnx-viewer@libcloud.local",
    displayName: "Nutanix Read-only Viewer",
    role: "viewer",
    tenant: "nutanix",
    linkedIdentities: ["github:33333"],
    createdAt: "2025-05-03T00:00:00Z",
  },
];

// Seed OpenFGA tuples for the superadmin tuples screen in mock mode.
export const MOCK_TUPLES = [
  { user: "user:superadmin", relation: "superadmin", object: "platform:main" },
  { user: "user:superadmin", relation: "owner", object: "tenant:aws" },
  { user: "user:superadmin", relation: "owner", object: "tenant:nutanix" },
  { user: "user:aws-owner", relation: "owner", object: "tenant:aws" },
  { user: "user:aws-admin", relation: "admin", object: "tenant:aws" },
  { user: "user:aws-viewer", relation: "viewer", object: "tenant:aws" },
  { user: "user:ntnx-owner", relation: "owner", object: "tenant:nutanix" },
  { user: "user:ntnx-admin", relation: "admin", object: "tenant:nutanix" },
  { user: "user:ntnx-viewer", relation: "viewer", object: "tenant:nutanix" },
  { user: "tenant:aws", relation: "parent", object: "libcloud_api:main" },
  { user: "tenant:nutanix", relation: "parent", object: "libcloud_api:main" },
];

// Mock catalog/resource snapshots returned by GET /api/resources/{aws,nutanix}.
// Cloned per-call in mockApi.js so the Deprovision button can mutate the list
// in mock mode (mirrors the backend deleting the node via deprovision_aws.sh).
// `categories` mirrors the identity service's AWS inventory fan-out
// (_AWS_CATEGORY_SPECS in identity_service/app/libcloud_proxy.py): same group
// titles, column keys and row shapes as the real backend.
export const MOCK_AWS_RESOURCES = {
  region: "ap-southeast-1",
  nodes: [
    { id: "i-0abc123", name: "libcloud-demo-1", state: "running", size: "t3.small", public_ips: ["54.254.10.20"], private_ips: ["10.0.0.10"] },
    { id: "i-0def456", name: "libcloud-demo-2", state: "stopped", size: "t3.small", public_ips: [], private_ips: ["10.0.0.11"] },
  ],
  categories: [
    {
      group: "Where a VM can land", key: "vpcs", title: "VPCs",
      columns: [{ key: "id", label: "ID" }, { key: "name", label: "Name" }, { key: "cidr", label: "CIDR" }, { key: "state", label: "State" }],
      rows: [{ id: "vpc-0aa11", name: "libcloud-private-vpc", cidr: "10.0.0.0/16", state: "available" }],
    },
    {
      group: "Where a VM can land", key: "subnets", title: "Subnets",
      columns: [{ key: "id", label: "ID" }, { key: "name", label: "Name" }, { key: "cidr", label: "CIDR" }, { key: "vpc", label: "VPC" }, { key: "az", label: "AZ" }],
      rows: [
        { id: "subnet-pub1", name: "libcloud-public-subnet", cidr: "10.0.0.0/24", vpc: "vpc-0aa11", az: "ap-southeast-1a" },
        { id: "subnet-priv1", name: "libcloud-private-subnet", cidr: "10.0.16.0/24", vpc: "vpc-0aa11", az: "ap-southeast-1a" },
      ],
    },
    {
      group: "Networks a VM can join", key: "security_groups", title: "Security Groups",
      columns: [{ key: "id", label: "ID" }, { key: "name", label: "Name" }, { key: "vpc", label: "VPC" }, { key: "ingress", label: "Ingress rules" }, { key: "egress", label: "Egress rules" }],
      rows: [
        { id: "sg-bastion", name: "libcloud-bastion-sg", vpc: "vpc-0aa11", ingress: 1, egress: 1 },
        { id: "sg-internal", name: "libcloud-internal-sg", vpc: "vpc-0aa11", ingress: 2, egress: 1 },
      ],
    },
    {
      group: "Networks a VM can join", key: "network_interfaces", title: "Network Interfaces",
      columns: [{ key: "id", label: "ID" }, { key: "name", label: "Name" }, { key: "state", label: "State" }, { key: "subnet", label: "Subnet" }, { key: "vpc", label: "VPC" }],
      rows: [
        { id: "eni-01", name: "eni-01", state: "in-use", subnet: "subnet-pub1", vpc: "vpc-0aa11" },
        { id: "eni-02", name: "eni-02", state: "in-use", subnet: "subnet-priv1", vpc: "vpc-0aa11" },
      ],
    },
    {
      group: "Networks a VM can join", key: "route_tables", title: "Route Tables",
      columns: [{ key: "id", label: "ID" }, { key: "name", label: "Name" }, { key: "routes", label: "Routes" }, { key: "subnets", label: "Subnets" }],
      rows: [{ id: "rtb-pub1", name: "libcloud-public-rtb", routes: "10.0.0.0/16 -> local, 0.0.0.0/0 -> igw-01", subnets: "subnet-pub1" }],
    },
    {
      group: "Networks a VM can join", key: "internet_gateways", title: "Internet Gateways",
      columns: [{ key: "id", label: "ID" }, { key: "name", label: "Name" }, { key: "vpc", label: "VPC" }, { key: "state", label: "State" }],
      rows: [{ id: "igw-01", name: "libcloud-private-igw", vpc: "vpc-0aa11", state: "available" }],
    },
    {
      group: "Networks a VM can join", key: "floating_ips", title: "Elastic IPs",
      columns: [{ key: "address", label: "Address" }, { key: "instance", label: "Instance" }, { key: "associated", label: "Associated" }],
      rows: [{ address: "54.254.10.20", instance: "i-0abc123", associated: "yes" }],
    },
    {
      group: "Images a VM can boot from", key: "images", title: "AMIs",
      columns: [{ key: "id", label: "ID" }, { key: "name", label: "Name" }],
      rows: [{ id: "ami-0ubuntu1", name: "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-20240601" }],
    },
    {
      group: "Block storage a VM can consume", key: "volumes", title: "EBS Volumes",
      columns: [{ key: "id", label: "ID" }, { key: "name", label: "Name" }, { key: "size", label: "Size (GiB)" }, { key: "state", label: "State" }],
      rows: [
        { id: "vol-01", name: "", size: 8, state: "in-use" },
        { id: "vol-02", name: "", size: 8, state: "in-use" },
      ],
    },
    {
      group: "Block storage a VM can consume", key: "snapshots", title: "EBS Snapshots",
      columns: [{ key: "id", label: "ID" }, { key: "name", label: "Name" }, { key: "volume", label: "Volume" }, { key: "state", label: "State" }],
      rows: [{ id: "snap-01", name: "libcloud-backup", volume: "vol-01", state: "completed" }],
    },
    {
      group: "Object storage", key: "buckets", title: "S3 Buckets",
      columns: [{ key: "name", label: "Name" }],
      rows: [{ name: "libcloud-demo-artifacts" }],
    },
    {
      group: "Access", key: "key_pairs", title: "Key Pairs",
      columns: [{ key: "name", label: "Name" }, { key: "fingerprint", label: "Fingerprint" }],
      rows: [{ name: "libcloud-admin-key", fingerprint: "aa:bb:cc:dd:ee:ff:00:11" }],
    },
  ],
};

export const MOCK_NUTANIX_RESOURCES = {
  cluster: "nutanix",
  nodes: [
    { id: "ntnx-1", name: "libcloud-ntnx-1", state: "running", size: "small", public_ips: [], private_ips: ["10.1.100.50"] },
  ],
  // Mirrors _NTNX_CATEGORY_SPECS in identity_service/app/libcloud_proxy.py
  // (same group titles, column keys and row shapes as the real backend).
  categories: [
    {
      group: "Where a VM can land", key: "clusters", title: "Clusters",
      columns: [{ key: "id", label: "ID" }, { key: "name", label: "Name" }],
      rows: [{ id: "00061ebf-cluster-1", name: "NTNX-POC" }],
    },
    {
      group: "Where a VM can land", key: "vpcs", title: "VPCs",
      columns: [{ key: "id", label: "ID" }, { key: "name", label: "Name" }, { key: "cidr", label: "CIDR" }, { key: "state", label: "State" }],
      rows: [{ id: "vpc-ntnx-1", name: "libcloud-vpc", cidr: "", state: "ACTIVE" }],
    },
    {
      group: "Where a VM can land", key: "subnets", title: "Subnets",
      columns: [{ key: "id", label: "ID" }, { key: "name", label: "Name" }, { key: "cidr", label: "CIDR" }, { key: "vpc", label: "VPC" }],
      rows: [
        { id: "subnet-vlan100", name: "vlan100-external", cidr: "10.1.100.0/24", vpc: "" },
        { id: "subnet-vlan200", name: "vlan200-internal", cidr: "10.1.200.0/24", vpc: "" },
      ],
    },
    {
      group: "Networks a VM can join", key: "security_groups", title: "Security Groups (Flow)",
      columns: [{ key: "id", label: "ID" }, { key: "name", label: "Name" }, { key: "vpc", label: "VPC" }],
      rows: [{ id: "sg-ntnx-1", name: "libcloud-vm-sg", vpc: "vpc-ntnx-1" }],
    },
    {
      group: "Networks a VM can join", key: "load_balancers", title: "Load Balancers",
      columns: [{ key: "id", label: "ID" }, { key: "name", label: "Name" }],
      rows: [],
    },
    {
      group: "Images a VM can boot from", key: "images", title: "Images",
      columns: [{ key: "id", label: "ID" }, { key: "name", label: "Name" }],
      rows: [{ id: "img-ubuntu-cloud", name: "ubuntu-24.04-cloudimg" }],
    },
    {
      group: "Storage a VM can consume", key: "volumes", title: "Volumes (Disks)",
      columns: [{ key: "id", label: "ID" }, { key: "name", label: "Name" }, { key: "size", label: "Size (GiB)" }, { key: "state", label: "State" }],
      rows: [{ id: "disk-ntnx-1", name: "scsi.0", size: 20, state: "attached" }],
    },
    {
      group: "Storage a VM can consume", key: "storage_containers", title: "Storage Containers",
      columns: [{ key: "id", label: "ID" }, { key: "name", label: "Name" }],
      rows: [{ id: "sc-default", name: "default-container" }],
    },
    {
      group: "Object storage", key: "buckets", title: "Object Buckets",
      columns: [{ key: "name", label: "Name" }],
      rows: [{ name: "libcloud-ntnx-artifacts" }],
    },
  ],
};

// Physical hosts (Nutanix cluster nodes) listed inline after "View Nutanix
// Resources" (no separate button). Mirrors the driver's ex_list_hosts ->
// clustermgmt v4 Host entity normalized into snake_case (id, name, cpu_model,
// memory_gib, hypervisor, block_serial/block_model, node_status, ...).
export const MOCK_NUTANIX_HOSTS = [
  {
    id: "host-00000000-0000-0000-0000-000000000001",
    name: "NTNX-POC-A",
    host_type: "HYPER_CONVERGED",
    hypervisor: "AHV 10.0",
    hypervisor_type: "AHV",
    number_of_vms: 4,
    cluster_name: "NTNX-POC",
    cluster_ext_id: "00061ebf-cluster-1",
    num_cpu_cores: 16,
    num_cpu_threads: 32,
    num_cpu_sockets: 2,
    cpu_capacity_hz: 2400000000,
    cpu_frequency_hz: 2400000000,
    cpu_model: "Intel(R) Xeon(R) CPU E5-2640 v4 @ 2.40GHz",
    memory_size_bytes: 137438953472,
    memory_gib: 128,
    block_serial: "19FM6F160445",
    block_model: "NX-3060-G5",
    gpu_driver_version: null,
    gpu_list: [],
    node_status: "ON",
    maintenance_state: "normal",
    is_degraded: false,
    is_secure_booted: false,
    boot_time_usecs: 1700000000000000,
    rackable_unit_uuid: "3014d025-f76d-41ac-ba05-d213b2e6bb41",
    bmc_ip: "192.168.1.101",
    bmc_status: "VALID",
  },
  {
    id: "host-00000000-0000-0000-0000-000000000002",
    name: "NTNX-POC-B",
    host_type: "HYPER_CONVERGED",
    hypervisor: "AHV 10.0",
    hypervisor_type: "AHV",
    number_of_vms: 6,
    cluster_name: "NTNX-POC",
    cluster_ext_id: "00061ebf-cluster-1",
    num_cpu_cores: 20,
    num_cpu_threads: 40,
    num_cpu_sockets: 2,
    cpu_capacity_hz: 2600000000,
    cpu_frequency_hz: 2600000000,
    cpu_model: "Intel(R) Xeon(R) Silver 4214 CPU @ 2.20GHz",
    memory_size_bytes: 274877906944,
    memory_gib: 256,
    block_serial: "19FM6F160446",
    block_model: "NX-3060-G6",
    gpu_driver_version: null,
    gpu_list: [],
    node_status: "ON",
    maintenance_state: "normal",
    is_degraded: false,
    is_secure_booted: true,
    boot_time_usecs: 1700000000000000,
    rackable_unit_uuid: "3014d025-f76d-41ac-ba05-d213b2e6bb42",
    bmc_ip: "192.168.1.102",
    bmc_status: "VALID",
  },
  {
    id: "host-00000000-0000-0000-0000-000000000003",
    name: "NTNX-POC-C",
    host_type: "COMPUTE_ONLY",
    hypervisor: "AHV 10.0",
    hypervisor_type: "AHV",
    number_of_vms: 0,
    cluster_name: "NTNX-POC",
    cluster_ext_id: "00061ebf-cluster-1",
    num_cpu_cores: 16,
    num_cpu_threads: 32,
    num_cpu_sockets: 2,
    cpu_capacity_hz: 2400000000,
    cpu_frequency_hz: 2400000000,
    cpu_model: "Intel(R) Xeon(R) CPU E5-2640 v4 @ 2.40GHz",
    memory_size_bytes: 68719476736,
    memory_gib: 64,
    block_serial: "19FM6F160447",
    block_model: "NX-3060-G5",
    gpu_driver_version: null,
    gpu_list: [],
    node_status: "OFF",
    maintenance_state: "in_maintenance",
    is_degraded: true,
    is_secure_booted: false,
    boot_time_usecs: null,
    rackable_unit_uuid: "3014d025-f76d-41ac-ba05-d213b2e6bb43",
    bmc_ip: null,
    bmc_status: "UNAVAILABLE",
  },
];

// Simulated deprovision result. The real backend shells out to
// test_script/scripts/deprovision_<cloud>.sh (curl DELETE /v1/compute/nodes/{id}
// after the OpenFGA can_provision check); the mock just reports success.
export const MOCK_DEPROVISION_RESULT = (provider, vmId, vmName) => ({
  provider,
  vmId: vmId || "",
  vmName: vmName || "",
  status: "deprovisioned",
  message: `Deprovisioned ${vmId || vmName} via deprovision_${provider}.sh (mock).`,
  exitCode: 0,
});

// Simulated update (edit) result. The real backend re-runs the OpenFGA
// can_update check then PATCHes /v1/compute/nodes/{id} (NodeUpdateRequest); the
// mock just reports success and applies the edited fields to the in-memory node.
export const MOCK_UPDATE_RESULT = (provider, vmId, fields) => ({
  provider,
  vmId: vmId || "",
  status: "updated",
  message: `Updated VM ${vmId || ""} via PATCH /v1/compute/nodes/{id} (mock).`,
  fields,
});

// Simulated provisioning result. Real backend must follow the exact call
// order from test_script/scripts/provision_aws.sh and provision_nutanix.sh.
export const MOCK_PROVISION_RESULT = (provider, vmName) => ({
  provider,
  vmName,
  status: "queued",
  message: `Provisioning request accepted (mock). Backend must replay the ${provider} script sequence.`,
  steps: provider === "aws" ? MOCK_AWS_STEPS : MOCK_NUTANIX_STEPS,
});

// Mirrors provision_aws.sh orchestration order. The frontend never invents
// cloud API calls; it just describes the contract the backend must honor.
export const MOCK_AWS_STEPS = [
  "idp_login (Dex -> OIDC token)",
  "build_aws_connection_param (region + auth_binding, NO creds in client)",
  "GET /v1/me",
  "GET /v1/connection/test",
  "GET /v1/compute/locations",
  "GET /v1/compute/sizes",
  "GET /v1/compute/images?name=<filter>",
  "GET /v1/compute/nodes",
  "resolve IMAGE_ID/SIZE_ID (architecture-compatible)",
  "GET /v1/compute/subnets",
  "POST /v1/compute/nodes  (name, size, image, network.public_ip, subnet_id)",
  "optional teardown_libcloud_vms (if TEARDOWN_VMS=1)",
];

export const MOCK_NUTANIX_STEPS = [
  "idp_login (Dex -> OIDC token)",
  "build_nutanix_connection_param (auth_binding, NO creds in client)",
  "GET /v1/me",
  "GET /v1/connection/test",
  "GET /v1/compute/locations",
  "GET /v1/compute/sizes",
  "GET /v1/compute/images",
  "GET /v1/compute/storage-containers",
  "GET /v1/compute/nodes",
  "resolve CLUSTER_ID/IMAGE_ID/SIZE_ID/SUBNET_ID",
  "POST /v1/compute/nodes  (name, size, image, location, network.subnet_id)",
  "optional teardown_libcloud_vms (if TEARDOWN_VMS=1)",
];

// Simulated private-pair (bastion + internal) provisioning result. The real
// backend shells out to test_script/scripts/provision_aws_private.sh
// (aws_bastion_internal_server.md) or provision_nutanix_bastion_private.sh
// (nutanix_bastion_internal_server.md) after the OpenFGA can_provision gate;
// the mock reports success and echoes the script's step order as stdout.
export const MOCK_PROVISION_PRIVATE_RESULT = (provider, pairName) => ({
  provider,
  vmName: pairName,
  bastionName: `${pairName}-bastion`,
  internalName: `${pairName}-internal`,
  status: "provisioned",
  message: `${provider === "aws" ? "provision_aws_private.sh" : "provision_nutanix_bastion_private.sh"} exit=0 (mock).`,
  exitCode: 0,
  stdout: (provider === "aws" ? MOCK_AWS_PRIVATE_STEPS : MOCK_NUTANIX_PRIVATE_STEPS).join("\n"),
});

// Mirrors provision_aws_private.sh orchestration order.
export const MOCK_AWS_PRIVATE_STEPS = [
  "idp_login (Dex -> OIDC token)",
  "OpenFGA can_connect/can_use/can_provision checks (aws_region:<binding>)",
  "build_aws_connection_param (region + auth_binding, NO creds in client)",
  "GET /v1/me",
  "GET /v1/connection/test",
  "GET /v1/compute/locations",
  "GET /v1/compute/sizes",
  "GET /v1/compute/images?name=<filter>",
  "GET /v1/compute/nodes",
  "resolve IMAGE_ID/SIZE_ID (architecture-compatible)",
  "ensure VPC libcloud-private-vpc (10.0.0.0/16)",
  "ensure public subnet libcloud-public-subnet (10.0.0.0/24, auto-assign public IP)",
  "ensure private subnet libcloud-private-subnet (10.0.16.0/24, no internet route)",
  "ensure internet gateway + attach to VPC",
  "ensure public route table (0.0.0.0/0 -> IGW, associated with public subnet)",
  "ensure security groups (bastion: ssh/22 from operator CIDR; internal: ssh/22 from bastion SG + app port from VPC)",
  "ensure key pair (private key saved chmod 400 on first create)",
  "POST /v1/compute/nodes  (bastion VM -> public subnet + public IP)",
  "POST /v1/compute/nodes  (internal VM -> private subnet, NO public IP)",
  "GET /v1/compute/nodes  (summary)",
  "optional teardown_libcloud_vms (if TEARDOWN_VMS=1)",
];

// Mirrors provision_nutanix_bastion_private.sh orchestration order.
export const MOCK_NUTANIX_PRIVATE_STEPS = [
  "idp_login (Dex -> OIDC token)",
  "build_nutanix_connection_param (auth_binding, NO creds in client)",
  "GET /v1/me",
  "GET /v1/connection/test",
  "GET /v1/compute/locations",
  "GET /v1/compute/images",
  "GET /v1/compute/subnets",
  "GET /v1/compute/storage-containers",
  "GET /v1/compute/nodes",
  "resolve CLUSTER_ID/IMAGE_ID/STORAGE_CONTAINER_ID",
  "ensure subnet vlan100-external (VLAN 100, 10.1.100.0/24 + IPAM pool)",
  "ensure subnet vlan200-internal (VLAN 200, 10.1.200.0/24 + IPAM pool, isolated)",
  "POST /v1/compute/nodes  (bastion host -> vlan100-external)",
  "POST /v1/compute/nodes  (internal server -> vlan200-internal, no internet)",
  "GET /v1/compute/nodes/{id}  (verify both VMs)",
  "optional teardown_libcloud_vms (if TEARDOWN_VMS=1)",
];

// ---------------------------------------------------------------------------
// Mock OpenFGA store, models, assertions, changes for the superadmin explorer
// page. Mirrors the shape of the OpenFGA REST API responses.
// ---------------------------------------------------------------------------

export const MOCK_OPENFGA_STORE = {
  id: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
  name: "libcloud-rest-store",
  created_at: "2025-01-15T08:00:00Z",
  updated_at: "2025-06-01T12:30:00Z",
};

export const MOCK_OPENFGA_MODELS = {
  authorization_models: [
    {
      id: "01ARZ3NDEKTSV4RRFFQ69G5FAM",
      schema_version: "1.1",
      type_definitions: [
        { type: "user" },
        {
          type: "tenant",
          relations: {
            parent: {},
            owner: { directly_related_user_types: [{ type: "user" }] },
            admin: { directly_related_user_types: [{ type: "user" }, { type: "tenant", relation: "owner" }] },
            viewer: { directly_related_user_types: [{ type: "user" }, { type: "tenant", relation: "admin" }] },
          },
        },
        {
          type: "platform",
          relations: {
            superadmin: { directly_related_user_types: [{ type: "user" }] },
            global_reader: { directly_related_user_types: [{ type: "user" }, { type: "platform", relation: "superadmin" }] },
          },
        },
        {
          type: "provider",
        },
        {
          type: "aws_region",
          relations: {
            can_read: { directly_related_user_types: [{ type: "user" }, { type: "tenant", relation: "viewer" }, { type: "platform", relation: "global_reader" }] },
            can_provision: { directly_related_user_types: [{ type: "user" }, { type: "tenant", relation: "admin" }] },
            can_update: { directly_related_user_types: [{ type: "user" }, { type: "tenant", relation: "admin" }] },
            parent: { directly_related_user_types: [{ type: "tenant" }] },
          },
        },
        {
          type: "nutanix_cluster",
          relations: {
            can_read: { directly_related_user_types: [{ type: "user" }, { type: "tenant", relation: "viewer" }, { type: "platform", relation: "global_reader" }] },
            can_provision: { directly_related_user_types: [{ type: "user" }, { type: "tenant", relation: "admin" }] },
            can_update: { directly_related_user_types: [{ type: "user" }, { type: "tenant", relation: "admin" }] },
            parent: { directly_related_user_types: [{ type: "tenant" }] },
          },
        },
      ],
    },
  ],
};

export const MOCK_OPENFGA_ASSERTIONS = {
  authorization_model_id: "01ARZ3NDEKTSV4RRFFQ69G5FAM",
  assertions: [
    {
      tuple_key: { user: "user:superadmin", relation: "superadmin", object: "platform:main" },
      expectation: true,
    },
    {
      tuple_key: { user: "user:aws-admin", relation: "admin", object: "tenant:aws" },
      expectation: true,
    },
    {
      tuple_key: { user: "user:aws-viewer", relation: "can_read", object: "aws_region:aws" },
      expectation: true,
    },
    {
      tuple_key: { user: "user:aws-admin", relation: "can_provision", object: "nutanix_cluster:nutanix" },
      expectation: false,
    },
  ],
};

export const MOCK_OPENFGA_CHANGES = {
  changes: [
    {
      tuple_key: { user: "user:superadmin", relation: "superadmin", object: "platform:main" },
      operation: "TUPLE_OPERATION_WRITE",
      timestamp: "2025-03-01T10:00:00Z",
    },
    {
      tuple_key: { user: "user:aws-owner", relation: "owner", object: "tenant:aws" },
      operation: "TUPLE_OPERATION_WRITE",
      timestamp: "2025-03-01T10:05:00Z",
    },
    {
      tuple_key: { user: "user:aws-admin", relation: "admin", object: "tenant:aws" },
      operation: "TUPLE_OPERATION_WRITE",
      timestamp: "2025-03-01T10:10:00Z",
    },
    {
      tuple_key: { user: "user:aws-viewer", relation: "viewer", object: "tenant:aws" },
      operation: "TUPLE_OPERATION_WRITE",
      timestamp: "2025-03-02T09:00:00Z",
    },
    {
      tuple_key: { user: "user:ntnx-owner", relation: "owner", object: "tenant:nutanix" },
      operation: "TUPLE_OPERATION_WRITE",
      timestamp: "2025-03-03T14:00:00Z",
    },
    {
      tuple_key: { user: "user:ntnx-admin", relation: "admin", object: "tenant:nutanix" },
      operation: "TUPLE_OPERATION_WRITE",
      timestamp: "2025-03-03T14:05:00Z",
    },
  ],
  continuation_token: "",
};

// Simplified mapping of REST API routes to required scopes/roles, mirroring
// libcloud.rest/app/auth/policies.json for the superadmin explorer page.
export const MOCK_REST_API_POLICIES = {
  "_comment": "Authorization policy table (mock). Keyed by 'METHOD path_template'.",
  "GET /v1/compute/locations": {
    "scopes_any_of": ["compute:location:read", "compute:read"],
    "authz_scope": "compute:location:read",
  },
  "GET /v1/compute/images": {
    "scopes_any_of": ["compute:image:read", "compute:read"],
    "authz_scope": "compute:image:read",
  },
  "GET /v1/compute/sizes": {
    "scopes_any_of": ["compute:size:read", "compute:read"],
    "authz_scope": "compute:size:read",
  },
  "GET /v1/compute/nodes": {
    "scopes_any_of": ["compute:read"],
  },
  "GET /v1/compute/nodes/{node_id}": {
    "scopes_any_of": ["compute:read"],
  },
  "POST /v1/compute/nodes": {
    "scopes_any_of": ["compute:node:create"],
    "capability": "create_node",
  },
  "PATCH /v1/compute/nodes/{node_id}": {
    "scopes_any_of": ["compute:node:power", "compute:node:update"],
    "authz_scope_by_body_field": {
      "field": "action",
      "map": { "update": "compute:node:update", "resize": "compute:node:power", "tag": "compute:node:power" },
    },
  },
  "POST /v1/compute/nodes/{node_id}:start": {
    "scopes_any_of": ["compute:node:power"],
  },
  "POST /v1/compute/nodes/{node_id}:stop": {
    "scopes_any_of": ["compute:node:power"],
  },
  "POST /v1/compute/nodes/{node_id}:reboot": {
    "scopes_any_of": ["compute:node:power"],
  },
  "DELETE /v1/compute/nodes/{node_id}": {
    "scopes_any_of": ["compute:node:delete"],
    "capability": "destroy_node",
  },
  "GET /v1/compute/volumes": {
    "scopes_any_of": ["compute:volume:manage", "compute:read"],
    "authz_scope": "compute:read",
  },
  "POST /v1/compute/volumes": {
    "scopes_any_of": ["compute:volume:manage"],
    "capability": "volumes",
  },
  "PATCH /v1/compute/volumes/{volume_id}": {
    "scopes_any_of": ["compute:volume:manage"],
  },
  "DELETE /v1/compute/volumes/{volume_id}": {
    "scopes_any_of": ["compute:volume:manage"],
  },
  "POST /v1/compute/volumes/{volume_id}:attach": {
    "scopes_any_of": ["compute:volume:manage"],
  },
  "POST /v1/compute/volumes/{volume_id}:detach": {
    "scopes_any_of": ["compute:volume:manage"],
  },
  "GET /v1/compute/snapshots": {
    "scopes_any_of": ["compute:snapshot:manage", "compute:read"],
    "authz_scope": "compute:read",
  },
  "POST /v1/compute/snapshots": {
    "scopes_any_of": ["compute:snapshot:manage"],
    "capability": "snapshots",
  },
  "DELETE /v1/compute/snapshots/{snapshot_id}": {
    "scopes_any_of": ["compute:snapshot:manage"],
  },
  "GET /v1/compute/networks": {
    "scopes_any_of": ["compute:network:read", "compute:read"],
    "authz_scope": "compute:network:read",
  },
  "POST /v1/compute/networks": {
    "scopes_any_of": ["compute:network:manage"],
  },
  "DELETE /v1/compute/networks/{network_id}": {
    "scopes_any_of": ["compute:network:manage"],
  },
  "GET /v1/jobs/{job_id}": {
    "scopes_any_of": ["jobs:read"],
    "connection_required": false,
  },
};
