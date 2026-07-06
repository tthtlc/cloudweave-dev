from pydantic import BaseModel, Field


class LoginRequest(BaseModel):
    username: str
    password: str
    requested_scopes: list[str] = Field(default_factory=list)


class RefreshRequest(BaseModel):
    refresh_token: str


class IntrospectRequest(BaseModel):
    token: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int
    refresh_token: str
    scope: str


class UserRecord(BaseModel):
    username: str
    password_hash: str
    tenant_id: str = "default"
    scopes: list[str] = Field(default_factory=list)
    allowed_providers: list[str] = Field(default_factory=lambda: ["*"])


class TokenClaims(BaseModel):
    sub: str
    iss: str
    aud: str
    iat: int
    nbf: int
    exp: int
    jti: str
    scope: str
    tenant_id: str
    allowed_providers: list[str]
    session_id: str
    # Raw bearer token, retained so the policy engine can forward it to
    # downstream resource servers (e.g. OpenFGA when OpenFGA runs with OIDC
    # authn). Not serialized into responses; populated by the decode path.
    access_token: str | None = None
