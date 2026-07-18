from __future__ import annotations

from typing import Any

from pydantic import BaseModel, Field


# --- /api/auth/exchange -----------------------------------------------------
class ExchangeRequest(BaseModel):
    provider: str | None = None
    code: str
    state: str
    redirectUri: str = Field(alias="redirectUri")


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


# --- /api/auth/collapse -----------------------------------------------------
class PendingIdentity(BaseModel):
    provider: str
    subject: str
    email: str


class CollapseRequest(BaseModel):
    targetInternalUserId: str | None = None
    pendingIdentity: PendingIdentity
    decision: str  # "link" | "keep"


# --- /api/users -------------------------------------------------------------
class RoleUpdateRequest(BaseModel):
    role: str


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
