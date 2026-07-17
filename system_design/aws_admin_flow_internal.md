# AWS Admin Provisioning Flow — Internal API Trace

This document annotates every HTTP request emitted during a run of `./scripts/provision_aws.sh`, as captured in `run_aws_admin.log.stderr`. The execution follows a textbook **discover-then-provision** pattern orchestrated through a libcloud REST API (port `8765`) with Dex-based OAuth2 authentication (port `5556`).

**Credentials:** `aws-admin` (LDAP-backed Dex user)  
**Target region:** `ap-southeast-1` (Singapore)  
**Provisioned node:** `libcloud-demo-1782900426` — `t3.micro` — Ubuntu 22.04 (`Cloud9Ubuntu22-2026-06-23T14-03`)

---

## Request Inventory

12 HTTP requests total across 9 unique URL patterns, organised into 5 phases:

| # | Line | Method | URL | Phase |
|---|------|--------|-----|-------|
| 1 | 16 | `GET` | `http://localhost:5556/dex/auth?...` | Auth — OAuth2 initiate |
| 2 | 17 | `POST` | `http://localhost:5556/dex/auth/lldap/login?...` | Auth — LDAP login |
| 3 | 18 | `GET` | `http://localhost:8765/v1/auth/me` | Identity verify |
| 4 | 47 | `POST` | `http://localhost:8765/v1/connections:test` | Connectivity test |
| 5 | 91 | `GET` | `http://localhost:8765/v1/compute/locations` | Discovery — regions |
| 6 | 132 | `GET` | `http://localhost:8765/v1/compute/sizes` | Discovery — sizes (1st) |
| 7 | 21926 | `GET` | `http://localhost:8765/v1/compute/images?name=%2AUbuntu%2A` | Discovery — images (1st) |
| 8 | 164999 | `GET` | `http://localhost:8765/v1/compute/nodes` | Discovery — existing nodes |
| 9 | 165128 | `GET` | `http://localhost:8765/v1/compute/images?name=%2AUbuntu%2A` | Discovery — images (2nd) |
| 10 | 308201 | `GET` | `http://localhost:8765/v1/compute/sizes` | Selection — sizes (2nd) |
| 11 | 329997 | `GET` | `http://localhost:8765/v1/compute/subnets` | Selection — subnets |
| 12 | 330075 | `POST` | `http://localhost:8765/v1/compute/nodes` | **PROVISION — create node** |

10 read-only / 1 connection-test / 1 mutating (provisioning).

---

## Phase 1: OAuth2 Authentication (Dex + LDAP)

### 1. `GET http://localhost:5556/dex/auth`

```
GET /dex/auth?client_id=libcloud-rest
    &redirect_uri=http%3A%2F%2F127.0.0.1%3A8766%2Foauth%2Fcallback
    &response_type=code
    &scope=openid+email+profile
    &state=libcloud-dex
```

**Meaning:** Initiate the OAuth2 **authorization code** flow. The libcloud CLI (acting as a confidential client `libcloud-rest`) redirects the user to the Dex identity provider. The requested scopes (`openid`, `email`, `profile`) are standard OIDC claims. The `state` parameter (`libcloud-dex`) binds the request to the local session to prevent CSRF.

> This is the **start of the login handshake** — no credentials are sent yet; the user is redirected to Dex's login UI.

---

### 2. `POST http://localhost:5556/dex/auth/lldap/login`

```
POST /dex/auth/lldap/login?back=&state=zhk3znl3cukejdjd7toh6ptkb
Body: login=aws-admin (+ password)
```

**Meaning:** The user submits their **LDAP credentials** via Dex's LLDP connector. The `state` parameter (now a Dex-generated nonce `zhk3znl3cukejdjd7toh6ptkb`) links this login POST to the authorization request initiated in step 1. On success, Dex issues an authorization code that the CLI exchanges for an access token (the token exchange happens internally and is not logged as a separate HTTP line — it is absorbed into the subsequent `Authorization: Bearer` header).

> This is the **actual authentication event** — the user proves their identity to Dex.

---

## Phase 2: Identity Verification

### 3. `GET http://localhost:8765/v1/auth/me`

```
Authorization: Bearer ***REDACTED***
Accept: application/json
→ HTTP 200
```

**Meaning:** The CLI calls the libcloud REST API's introspection endpoint to **verify the bearer token is valid** and retrieve the authenticated user's profile. The response confirms the session belongs to `aws-admin`. This is the first API call after obtaining the token — a sanity check that the auth flow succeeded.

> **Listing/prep:** Verifies *who* is about to provision resources.

---

## Phase 3: AWS Connectivity Test

### 4. `POST http://localhost:8765/v1/connections:test`

```json
{
    "provider": "aws",
    "config": {
        "region": "ap-southeast-1",
        "secure": true
    }
}
```

**Meaning:** The CLI asks the libcloud backend to **validate AWS credentials and network reachability** for the `ap-southeast-1` region before attempting any resource operations. This is a custom RPC-style endpoint (`:test` suffix) that performs a lightweight AWS API call (likely `DescribeRegions` or `GetCallerIdentity`) to confirm the key/secret are valid and the region is reachable.

> **Listing/prep:** Validates the AWS connection *before* making any resource calls. Fails fast if credentials are bad.

---

## Phase 4: Resource Discovery (Enumeration)

### 5. `GET http://localhost:8765/v1/compute/locations`

```
X-Provider-Connection: ***REDACTED***
→ HTTP 200
```

**Meaning:** **List AWS regions and availability zones.** The libcloud `list_locations()` call enumerates all geographic locations where resources can be provisioned. The response includes region names (e.g., `ap-southeast-1`, `us-east-1`), countries, and availability zones within each region.

> **Listing:** Discovers *where* resources can be placed.

---

### 6. `GET http://localhost:8765/v1/compute/sizes` (1st call)

```
X-Provider-Connection: ***REDACTED***
→ HTTP 200
```

**Meaning:** **List available EC2 instance types.** This is the libcloud `list_sizes()` call, which enumerates instance sizes like `t2.micro`, `t3.small`, `m5.large`, etc., along with their vCPU, RAM, and disk specifications.

> **Listing:** Discovers *what hardware profiles* are available for provisioning.

---

### 7. `GET http://localhost:8765/v1/compute/images?name=%2AUbuntu%2A` (1st call)

```
X-Provider-Connection: ***REDACTED***
→ HTTP 200
```

**Meaning:** **Search for Ubuntu AMIs.** The query parameter `name=%2AUbuntu%2A` decodes to `*Ubuntu*` — a wildcard search for all machine images whose name contains "Ubuntu". This is the libcloud `list_images(ex_filters={"name": "*Ubuntu*"})` call. The response includes dozens of Ubuntu AMIs across different versions (20.04, 22.04, 24.04), architectures (x86_64, ARM64), and editions (standard, Deep Learning, EKS-optimised, etc.).

> **Listing:** Discovers *what OS images* are available to boot from.

---

### 8. `GET http://localhost:8765/v1/compute/nodes` (1st call)

```
X-Provider-Connection: ***REDACTED***
→ HTTP 200
```

**Meaning:** **List existing EC2 instances.** This is the libcloud `list_nodes()` call, which returns all currently running (and stopped) instances in the target region. The log shows an empty response — no VMs exist yet, confirming this is a greenfield deployment.

> **Listing:** Discovers *what already exists* — prevents naming collisions and informs capacity decisions.

---

### 9. `GET http://localhost:8765/v1/compute/images?name=%2AUbuntu%2A` (2nd call)

```
X-Provider-Connection: ***REDACTED***
→ HTTP 200
```

**Meaning:** **Re-fetch Ubuntu AMIs** after the node listing. The script iterates over the image catalog a second time, this time to apply selection filters and pick a specific image. This second call isolates the selection logic from the initial discovery — the script likely filters for the most recent LTS release on the target architecture.

> **Listing:** Refines the image catalog to select the *specific AMI* to boot.

---

## Phase 5: Target Selection & Provisioning

### 10. `GET http://localhost:8765/v1/compute/sizes` (2nd call)

```
X-Provider-Connection: ***REDACTED***
→ HTTP 200
```

**Meaning:** **Re-fetch instance sizes.** The script re-queries the size catalog to locate the specific size `t3.micro` by ID, confirming its availability and retrieving its metadata (vCPU count, RAM, architecture `x86_64`).

> **Selection:** Picks the *specific instance type* for the new node.

---

After this call, the script logs its final selections:

```
Selected image=Cloud9Ubuntu22-2026-06-23T14-03
Selected size=t3.micro arch=x86_64
```

---

### 11. `GET http://localhost:8765/v1/compute/subnets`

```
X-Provider-Connection: ***REDACTED***
→ HTTP 200
```

**Meaning:** **List VPC subnets.** Before creating a node, the script needs to know which subnets are available to place the instance into. The libcloud REST API exposes this as a compute-adjacent resource (though subnets are technically a networking concern). The response provides subnet IDs in the target VPC.

> **Selection:** Discovers *which subnet* to attach the new instance to.

---

### 12. `POST http://localhost:8765/v1/compute/nodes` ➤ **PROVISION**

```json
{
    "name": "libcloud-demo-1782900426",
    "size": {
        "id": "t3.micro"
    },
    "image": {
        "id": "ami-..."
    },
    "location": {
        "id": "ap-southeast-1a"
    },
    "...": "..."
}
```

**Meaning:** **CREATE a new EC2 instance.** This is the **sole mutating call** in the entire trace — all prior requests were discovery and validation. This `POST` maps to libcloud's `create_node()` method. The request body specifies:

| Field | Value | Derived from |
|-------|-------|--------------|
| `name` | `libcloud-demo-1782900426` | Auto-generated (timestamp suffix) |
| `size.id` | `t3.micro` | Step 10 |
| `image` | `Cloud9Ubuntu22-2026-06-23T14-03` (AMI ID) | Step 9 |
| `location` | Availability zone in `ap-southeast-1` | Step 5 |
| `subnet` | Selected subnet ID | Step 11 |

The backend translates this into an AWS `RunInstances` API call against the EC2 endpoint for `ap-southeast-1`.

> ➤ **PROVISIONING:** This is the call that actually creates the cloud resource — everything before it was preparation.

---

## Reference URLs (Informational Only)

The log also contains five `https://` URLs embedded in AMI description fields — these are **not outbound HTTP requests** from the script, but rather content returned inside API response payloads:

| URL | Context |
|-----|---------|
| `https://aws.amazon.com/releasenotes/aws-deep-learning-base-gpu-ami-ubuntu-20-04/` | Deep Learning AMI (20.04) release notes |
| `https://aws.amazon.com/releasenotes/aws-deep-learning-base-gpu-ami-ubuntu-22-04/` | Deep Learning AMI (22.04) release notes |
| `https://aws.amazon.com/releasenotes/aws-deep-learning-base-gpu-ami-ubuntu-24-04/` | Deep Learning AMI (24.04) release notes |
| `https://docs.aws.amazon.com/dlami/latest/devguide/appendix-ami-release-notes.html` | AWS DLAMI documentation |
| `https://awsdocs-neuron.readthedocs-hosted.com/en/latest/dlami/index.html` | AWS Neuron DLAMI docs |

These links appear in the description metadata of Deep Learning AMIs returned by the image search (steps 7 & 9). The log captures them because they were part of the verbose response dump; the script itself never fetches them.

---

## Summary

```
Authenticate (Dex/LDAP)
    │
    ▼
Verify Identity (GET /v1/auth/me)
    │
    ▼
Test AWS Connectivity (POST /v1/connections:test)
    │
    ▼
┌─────────────────────────────────────┐
│  DISCOVERY PHASE (read-only)         │
│                                     │
│  1. List locations (regions/zones)  │
│  2. List sizes (instance types)     │
│  3. Search images (*Ubuntu*)        │
│  4. List existing nodes (none)      │
│  5. Re-fetch images (select one)    │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│  SELECTION PHASE (read-only)        │
│                                     │
│  6. Re-fetch sizes (pick t3.micro)  │
│  7. List subnets (pick one)         │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│  PROVISIONING (mutating)            │
│                                     │
│  8. CREATE NODE                     │
│     name: libcloud-demo-1782900426  │
│     size: t3.micro                  │
│     image: Cloud9Ubuntu22            │
│     region: ap-southeast-1          │
└─────────────────────────────────────┘
```

**10 of 12 calls are read-only enumeration** — the script exhaustively discovers the AWS environment before making a single provisioning call. This pattern ensures the provisioned resource is compatible with the region, subnet, and available instance types, and avoids naming conflicts with existing nodes.
