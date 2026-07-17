
This is a classic enterprise integration problem. The good news is the architecture does not need to change — only the **authentication flow** needs to be clarified.

## The Core Misunderstanding to Resolve First

There are **two completely different types of "credentials"** in play here, and conflating them is the source of the apparent problem:

| Credential Type | What it is | Where it lives | Who manages it |
|---|---|---|---|
| **User login password** | The password a human uses to log into the system | AD/LDAP (as a hash, verified by AD) | AD/LDAP administrators |
| **Cloud provider secrets** | API keys, access tokens, dynamic credentials for AWS/GCP/Azure etc. | Vault (as dynamic secrets or static secrets) | Cloud Owner via Vault |

**Nothing in the architecture requires migrating user passwords into Vault.** User passwords never need to leave AD. Vault does not store or verify human login credentials — it only stores cloud provider secrets.

## What Vault's LDAP Auth Method Actually Does

When you configure `auth/ldap` in Vault, Vault does **not** import or replicate passwords. Instead: [hashicorp](https://www.hashicorp.com/en/blog/a-golden-path-to-secure-cloud-provisioning-with-the-infrastructure-cloud)

1. A user presents their AD username + password to Vault (or to libcloud REST, which passes it through)
2. Vault performs an **LDAP bind** against the existing AD server using those credentials in real time
3. AD verifies the hash and returns success/failure — the password never leaves AD
4. Vault then reads the user's group memberships from AD via an LDAP search
5. Based on those groups, Vault maps to internal policies and issues a **Vault token**

AD remains the **sole authority for password verification**. This works with any LDAP-compatible directory — OpenLDAP, Active Directory, FreeIPA, or LLDAP — without migration.

## Recommended Architecture with Legacy AD

```
User (username + password)
        │
        ▼
libcloud REST API
        │  ← passes credentials for Vault LDAP auth bind
        ▼
Vault auth/ldap  ──── LDAP bind (real-time) ────► Existing AD / Legacy LDAP
        │              (AD verifies hash,                (no migration needed)
        │               returns group memberships)
        │
        ▼
Vault issues short-lived token
scoped to policies matching AD groups
        │
        ▼
libcloud REST uses token to fetch
cloud provider credentials from Vault
```

LLDAP in your earlier design was simply a **convenient lightweight option** for greenfield deployments. If an AD server already exists, you point `auth/ldap` at AD instead of LLDAP — the rest of the architecture is identical.

## Practical Configuration Advice

**1. Point Vault LDAP auth directly at AD — no migration needed:**
```bash
vault write auth/ldap/config \
  url="ldaps://your-ad-server:636" \
  userdn="CN=Users,DC=corp,DC=example,DC=com" \
  groupdn="CN=Groups,DC=corp,DC=example,DC=com" \
  groupattr="memberOf" \
  binddn="CN=vault-svc,CN=Users,DC=corp,DC=example,DC=com" \
  bindpass="<service-account-password>" \
  userattr="sAMAccountName" \
  insecure_tls=false
```
Vault uses a dedicated **read-only service account** (not admin) to search AD. No user password touches Vault. [developer.hashicorp](https://developer.hashicorp.com/vault/tutorials/policies)

**2. Map existing AD groups to Vault policies directly:**
```bash
vault write auth/ldap/groups/cloud-admins policies=cloud-admin-policy
vault write auth/ldap/groups/cloud-readonly policies=cloud-readonly-policy
```
You reuse existing AD groups as-is, or create new AD groups specifically for cloud access roles — whichever fits your AD governance model.

**3. If AD groups cannot be created freely (locked-down AD environment):**
Use Vault's `groupfilter` and `userattr` to derive policies from existing AD attributes (department, title, OU membership) rather than requiring new groups. This avoids any AD schema changes.

**4. For OpenFGA tuple reconciliation:**
The `openfga-tuple-reconcile.py` script simply changes its LDAP query target from LLDAP to AD — the logic is identical since both speak standard LDAP. Group membership queries (`memberOf` or `member` attribute) work the same way against AD.

## What to Actually Migrate (Almost Nothing)

| Item | Migrate to Vault? | Action |
|---|---|---|
| User passwords | ❌ Never | Leave in AD; Vault binds against AD in real time |
| User accounts | ❌ No | AD remains the identity source |
| AD group memberships | ❌ No | Vault reads them live via LDAP search |
| Cloud provider API keys | ✅ Yes | These are the only things that go into Vault — and they likely don't exist in AD at all today |
| Cloud provider IAM roles | ✅ Yes | Vault dynamic secrets engine generates these on demand |

The only "migration" work is **creating Vault secrets engines and roles for each cloud provider** — which you would have to do regardless of whether LLDAP or AD is the identity source.

## One Genuine Concern: Kerberos / NTLM-only AD Environments

If the AD environment is configured to **only accept Kerberos or NTLM** authentication and has LDAP simple binds disabled (uncommon but possible in hardened environments), then Vault's LDAP auth method cannot bind directly. In that case:

- **Best option**: Enable LDAPS (LDAP over TLS with simple bind) for the Vault service account on the AD side — this is a minimal AD configuration change, not a migration
- **Alternative**: Use Vault's **OIDC auth method** with AD FS (Active Directory Federation Services) as the OIDC provider, which keeps all authentication fully within the Microsoft stack
- **Last resort**: A thin identity proxy (e.g. Keycloak with AD backend) that speaks OIDC to Vault and LDAP/Kerberos to AD

In most enterprise AD environments, LDAPS simple bind for a service account is already permitted and this concern does not apply.


##########################
##########################
##########################

The missing piece is: **how does a user's identity flow from AD/LLDAP through to OpenFGA**, and **what does the OpenFGA authorization model actually look like** for libcloud REST API paths. Let me fill this in completely.

## The Auth Flow

The earlier architecture diagram skipped the step where libcloud REST gets the user's identity to pass to OpenFGA. Here is the complete flow:

```
User (username + password / token)
        │
        ▼
libcloud REST API  (receives request with Authorization header)
        │
        ├─── Step 1: Authenticate user
        │    Option A: Vault LDAP auth bind → returns Vault token + policies
        │    Option B: OIDC token (from AD FS / Keycloak) → validated by libcloud REST
        │
        ├─── Step 2: Extract identity
        │    Resolve username + group memberships from token claims or Vault token metadata
        │
        ├─── Step 3: OpenFGA Check (BEFORE executing the request)
        │    Ask: "does user:<username> have relation:<action> on object:<resource>?"
        │    If DENY → return 403 immediately
        │    If ALLOW → proceed
        │
        ├─── Step 4: Fetch cloud credentials from Vault
        │    (only reached if OpenFGA allowed the request)
        │
        └─── Step 5: Execute via libcloud → Cloud Provider
```

OpenFGA sits as a **middleware authorization gate** inside libcloud REST — every inbound request is checked before any cloud operation is attempted.

***

## OpenFGA Authorization Model for libcloud REST

### Type Definitions

The model needs four types: `user`, `role`, `provider`, and `api_resource`.

```python
model
  schema 1.1

type user

type role
  relations
    define member: [user]

type provider
  # e.g. object: provider:aws, provider:gcp, provider:azure, provider:nutanix
  relations
    define admin:   [role#member]
    define operate: [role#member]
    define readonly: [role#member]

type api_resource
  # e.g. object: api_resource:compute#provision
  # Each HTTP method+path combination is an api_resource
  relations
    define can_execute: [role#member] or admin from provider or operate from provider or readonly from provider
```

In practice, the cleanest model maps **each logical API capability** (not raw HTTP path) to a relation on `api_resource`, with conditions inherited through the provider relationship. This avoids tuple explosion.

***

### API Path → Relation Mapping

This is the core table that a developer must encode in the OpenFGA model. Each libcloud REST endpoint maps to a relation + resource object.

| HTTP Method | libcloud REST Path | OpenFGA Object | OpenFGA Relation | Minimum Role |
|---|---|---|---|---|
| GET | `/compute/{provider}/nodes` | `api:compute.list` | `can_read` | `readonly` |
| GET | `/compute/{provider}/nodes/{id}` | `api:compute.list` | `can_read` | `readonly` |
| POST | `/compute/{provider}/nodes` | `api:compute.provision` | `can_write` | `operator` |
| POST | `/compute/{provider}/nodes/{id}/action` | `api:compute.action` | `can_write` | `operator` |
| DELETE | `/compute/{provider}/nodes/{id}` | `api:compute.destroy` | `can_delete` | `admin` |
| GET | `/compute/{provider}/sizes` | `api:compute.meta` | `can_read` | `readonly` |
| GET | `/compute/{provider}/images` | `api:compute.meta` | `can_read` | `readonly` |
| POST | `/compute/{provider}/keypairs` | `api:compute.keypair` | `can_write` | `operator` |
| DELETE | `/compute/{provider}/keypairs/{id}` | `api:compute.keypair` | `can_delete` | `admin` |
| GET | `/storage/{provider}/buckets` | `api:storage.list` | `can_read` | `readonly` |
| POST | `/storage/{provider}/buckets` | `api:storage.bucket` | `can_write` | `operator` |
| DELETE | `/storage/{provider}/buckets/{id}` | `api:storage.bucket` | `can_delete` | `admin` |
| PUT | `/storage/{provider}/buckets/{id}/objects` | `api:storage.object` | `can_write` | `operator` |
| GET | `/storage/{provider}/buckets/{id}/objects` | `api:storage.object` | `can_read` | `readonly` |
| GET | `/network/{provider}/networks` | `api:network.list` | `can_read` | `readonly` |
| POST | `/network/{provider}/floatingips` | `api:network.floatingip` | `can_write` | `operator` |
| DELETE | `/network/{provider}/floatingips/{id}` | `api:network.floatingip` | `can_delete` | `admin` |
| GET | `/admin/users` | `api:admin.users` | `can_read` | `cloud-owner` |
| POST | `/admin/users` | `api:admin.users` | `can_write` | `cloud-owner` |
| POST | `/admin/vault/rotate` | `api:admin.vault` | `can_execute` | `cloud-owner` |

***

### Role → Relation → API Access Matrix

```
cloud-owner
  │  can_read, can_write, can_delete, can_execute on ALL api_resource objects
  │  admin on ALL provider objects
  │
cloud-admin
  │  can_read, can_write, can_delete on compute/storage/network api_resource objects
  │  operate on ALL provider objects (no admin-level destructive ops)
  │
cloud-operator-{aws|gcp|azure|...}   (provider-scoped)
  │  can_read, can_write on compute/storage/network for THAT provider only
  │  operate on provider:{aws} only
  │
cloud-readonly-{aws|gcp|azure|...}
     can_read on ALL api_resource objects for THAT provider only
     readonly on provider:{aws} only
```

Provider-scoped roles are the key insight — a user can be `operator` on `provider:aws` but `readonly` on `provider:gcp`, and OpenFGA enforces this per-request without any application-level if/else logic.

***

### Example Tuples Written at Role Assignment

When `chain-role-assign.sh` runs for a new cloud operator on AWS:

```bash
# user alice is a member of the cloud-operator-aws role
fga tuple write user:alice member role:cloud-operator-aws

# the cloud-operator-aws role has "operate" on provider:aws
fga tuple write role:cloud-operator-aws#member operate provider:aws

# (these provider→api_resource tuples are written once at system setup, not per user)
fga tuple write role:cloud-operator-aws#member can_read  api:compute.list
fga tuple write role:cloud-operator-aws#member can_write api:compute.provision
fga tuple write role:cloud-operator-aws#member can_write api:compute.action
# ... etc for all operator-level resources
```

When alice calls `POST /compute/aws/nodes`, libcloud REST checks:
```
user:alice  can_write  api:compute.provision
```
OpenFGA traverses: `alice` → member of `role:cloud-operator-aws` → which has `can_write` on `api:compute.provision` → **ALLOW**.

***

## Where This Fits in the Script Inventory

Two scripts from the earlier inventory now have concrete implementations:

- **`openfga-tuple-reconcile.py`** — when it syncs LLDAP/AD group memberships, it writes the `user:<x> member role:<y>` tuples. The `role → provider` and `role → api_resource` tuples are **static** and written once at setup time (not per user), so the reconciler only touches the user→role edge.

- **`chain-role-assign.sh`** — after adding the user to the LLDAP group, it calls `openfga-tuple-write.sh user:<x> member role:<y>`. No per-API-path tuple is needed per user because access is inherited through the role.

This design keeps the tuple count at **O(users × roles)** rather than **O(users × API paths)**, which is the correct OpenFGA pattern for RBAC at scale. [openfga](https://openfga.dev/docs/concepts)
