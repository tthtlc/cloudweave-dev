from __future__ import annotations

from typing import Any

from pydantic import BaseModel, Field


# --- /api/auth/exchange -----------------------------------------------------
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


# --- /api/session -----------------------------------------------------------
class SessionResponse(BaseModel):
    internalUserId: str
    role: str
    linkedIdentities: list[str]
    email: str


# Generic OK envelope used by several endpoints.
class OkResponse(BaseModel):
    data: Any = None
