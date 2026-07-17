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
    linkedIdentities: ["google:108214000000000000002"],
    createdAt: "2025-02-10T00:00:00Z",
  },
  {
    internalUserId: "int-admin-0002",
    email: "admin@libcloud.local",
    displayName: "Cloud Admin",
    role: "admin",
    linkedIdentities: ["github:67890", "google:108214000000000000003"],
    createdAt: "2025-03-15T00:00:00Z",
  },
  {
    internalUserId: "int-viewer-0003",
    email: "viewer@libcloud.local",
    displayName: "Read-only Viewer",
    role: "viewer",
    linkedIdentities: ["github:11111"],
    createdAt: "2025-04-20T00:00:00Z",
  },
];

// Mock catalog/resource snapshots returned by GET /api/resources/{aws,nutanix}.
export const MOCK_AWS_RESOURCES = {
  region: "ap-southeast-1",
  nodes: [
    { id: "i-0abc123", name: "libcloud-demo-1", state: "running", size: "t3.micro" },
    { id: "i-0def456", name: "libcloud-demo-2", state: "stopped", size: "t3.small" },
  ],
};

export const MOCK_NUTANIX_RESOURCES = {
  cluster: "nutanix",
  nodes: [
    { id: "ntnx-1", name: "libcloud-ntnx-1", state: "running", size: "small" },
  ],
};

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
