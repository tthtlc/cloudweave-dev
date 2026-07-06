from typing import Any

from pydantic import BaseModel, Field

from app.connections.models import ProviderConnection


class BucketCreateRequest(BaseModel):
    connection: ProviderConnection
    name: str
    # Optional location/region hint (AWS LocationConstraint). Defaults to the
    # connection region when omitted.
    location: str | None = None
    tags: dict[str, str] = Field(default_factory=dict)


class ObjectUploadRequest(BaseModel):
    connection: ProviderConnection
    bucket: str
    object_name: str
    # Base64-encoded object payload (for small uploads via the REST body).
    data_b64: str
    content_type: str | None = None
    metadata: dict[str, str] = Field(default_factory=dict)


class ObjectDownloadRequest(BaseModel):
    connection: ProviderConnection
    bucket: str
    object_name: str


class BucketResponse(BaseModel):
    id: str
    name: str
    provider: str
    target: str
    extra: dict[str, Any] = Field(default_factory=dict)


class ObjectResponse(BaseModel):
    name: str
    bucket: str
    size: int | None = None
    provider: str
    target: str
    extra: dict[str, Any] = Field(default_factory=dict)
