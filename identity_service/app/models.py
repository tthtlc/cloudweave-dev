from __future__ import annotations

from typing import Any

from pydantic import BaseModel, Field


# --- /api/auth/exchange -----------------------------------------------------
# Per-cloud authorization the portal uses to render only the tenant(s) the
# logged-in user can access (rbac_design.md: roles are per-tenant, so the UI must
# match the user's tenant). Computed live from OpenFGA so it stays correct after
# role changes.
class CloudCapability(BaseModel):
    cloud: str
    canView: bool
    canProvision: bool
    canUpdate: bool = False


class ExchangeRequest(BaseModel):
    provider: str | None = None
    code: str
    state: str
    redirectUri: str | None = Field(default=None, alias="redirectUri")


class CollapseCandidate(BaseModel):
    internalUserId: str
    email: str
    displayName: str
    role: str
    linkedIdentities: list[str]


class ExchangeResponse(BaseModel):
    internalUserId: str | None = None
    role: str | None = None
    linkedIdentities: list[str]
    email: str
    needsIdentityCollapse: bool = False
    collapseCandidates: list[CollapseCandidate] = []
    pendingIdentity: dict[str, str] | None = None
    # Server-issued, single-use token binding the Dex-verified pending identity
    # to this collapse attempt. Required by /api/auth/collapse when
    # needsIdentityCollapse is true. The client must NOT supply its own subject.
    pendingToken: str | None = None
    # Per-cloud capabilities for the resolved user (empty during collapse flow).
    clouds: list[CloudCapability] = []
    # The company the user is the main admin of (company_admin only). Mirrors
    # /api/session so the SPA can route to the company dashboard without an
    # extra round-trip after login.
    company: str | None = None


# --- /api/auth/collapse -----------------------------------------------------
class PendingIdentity(BaseModel):
    provider: str
    subject: str
    email: str


class CollapseRequest(BaseModel):
    targetInternalUserId: str | None = None
    pendingIdentity: PendingIdentity | None = None  # ignored by the server; kept for API symmetry
    decision: str  # "link" | "keep"
    # Required: the server-issued token from /api/auth/exchange proving the
    # caller actually authenticated this identity via Dex.
    pendingToken: str


# --- /api/users -------------------------------------------------------------
class RoleUpdateRequest(BaseModel):
    role: str
    tenant: str | None = None  # Required when assigning a role to a pending (non-LLDAP) user


class EmailUpdateRequest(BaseModel):
    email: str


class TupleItem(BaseModel):
    user: str
    relation: str
    object: str


class TupleWriteRequest(BaseModel):
    writes: list[TupleItem] = []
    deletes: list[TupleItem] = []


# --- /api/provision ---------------------------------------------------------
class ProvisionRequest(BaseModel):
    vmName: str | None = None


# --- /api/deprovision -------------------------------------------------------
# The portal's per-row Deprovision button sends the VM id (preferred, precise)
# and name. The backend forwards VM_ID to test_script/scripts/deprovision_aws.sh
# which DELETEs /v1/compute/nodes/{id} after re-running the OpenFGA can_provision
# check. Either field may be omitted; VM_ID takes precedence when both are set.
class DeprovisionRequest(BaseModel):
    vmId: str | None = None
    vmName: str | None = None


# --- /api/update -------------------------------------------------------------
# The portal's per-row Edit button sends the VM id plus the editable VM
# parameters. The backend re-runs the OpenFGA can_update check, then PATCHes
# /v1/compute/nodes/{id} on the libcloud REST API (NodeUpdateRequest). All
# fields except vmId are optional; only the supplied fields are forwarded.
class UpdateRequest(BaseModel):
    vmId: str
    name: str | None = None
    newSizeId: str | None = None
    memoryMib: int | None = None
    tagKey: str | None = None
    tagValue: str | None = None


# --- /api/companies / departments (design_company_department.md §6) ---------
class CreateCompanyRequest(BaseModel):
    name: str
    adminUserId: str


class CredentialInput(BaseModel):
    # key/secret are the generic AWS/Nutanix credential pair (AWS access key +
    # secret, or Nutanix admin username + password). `host` is the Nutanix Prism
    # Central URL (empty for AWS), stored alongside in Vault.
    key: str = ""
    secret: str = ""
    host: str = ""


class CreateDepartmentRequest(BaseModel):
    name: str
    # A department may bind to one or more providers (aws, nutanix). `clouds` is
    # the primary multi-provider field; `cloud` is kept for back-compat with
    # single-provider callers and is folded into `clouds` by the route.
    clouds: list[str] = []
    ownerUserId: str
    # Per-provider backend credentials, keyed by cloud id ("aws" | "nutanix").
    # `credential` (single) is back-compat; it maps to the first cloud.
    credentials: dict[str, CredentialInput] = {}
    cloud: str | None = None
    credential: CredentialInput | None = None


class CredentialUpdateRequest(BaseModel):
    key: str
    secret: str


class UpdateCompanyRequest(BaseModel):
    name: str | None = None
    adminUserId: str | None = None


class UpdateDepartmentRequest(BaseModel):
    name: str | None = None
    clouds: list[str] | None = None
    ownerUserId: str | None = None
    # Per-provider backend credentials, keyed by cloud id ("aws" | "nutanix"),
    # written to Vault when the company admin adds a provider to an existing
    # department (the create form already collects these). A blank/omitted
    # credential leaves that provider's existing secret untouched.
    credentials: dict[str, CredentialInput] = {}


class DepartmentUserUpdateRequest(BaseModel):
    role: str  # owner | admin | viewer
    department: str | None = None  # move the member to another department


# --- /api/session -----------------------------------------------------------
class SessionResponse(BaseModel):
    internalUserId: str
    role: str
    linkedIdentities: list[str]
    email: str
    clouds: list[CloudCapability] = []
    company: str | None = None


# Generic OK envelope used by several endpoints.
class OkResponse(BaseModel):
    data: Any = None


# --- /api/openfga/* (superadmin explorer) ------------------------------------
class OpenFgaListUsersRequest(BaseModel):
    object: str
    relation: str
    user_filters: list[dict[str, str]] = []


class OpenFgaListObjectsRequest(BaseModel):
    type: str
    relation: str
    user: str


class OpenFgaExpandRequest(BaseModel):
    relation: str
    object: str
