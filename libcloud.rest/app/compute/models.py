from typing import Any, Literal

from pydantic import BaseModel, Field


class ResourceRef(BaseModel):
    id: str


class NodeAuth(BaseModel):
    type: Literal["ssh_key", "password", "key_pair"] = "ssh_key"
    public_key: str | None = None
    key_name: str | None = None
    password: str | None = None


class NodeNetwork(BaseModel):
    public_ip: bool = False
    subnet_id: str | None = None
    security_group: str | None = None


class ExecutionOptions(BaseModel):
    mode: Literal["sync", "async"] = "sync"
    wait_until_running: bool = False
    timeout_seconds: int = 900


class NodeCreateRequest(BaseModel):
    name: str
    size: ResourceRef
    image: ResourceRef
    location: ResourceRef | None = None
    auth: NodeAuth | None = None
    network: NodeNetwork | None = None
    tags: dict[str, str] = Field(default_factory=dict)
    provider_options: dict[str, Any] = Field(default_factory=dict)
    execution: ExecutionOptions = Field(default_factory=ExecutionOptions)


class VolumeCreateRequest(BaseModel):
    name: str
    size_gb: int
    location: ResourceRef | None = None
    snapshot_id: str | None = None
    provider_options: dict[str, Any] = Field(default_factory=dict)
    execution: ExecutionOptions = Field(default_factory=ExecutionOptions)


class SnapshotCreateRequest(BaseModel):
    volume_id: str
    name: str | None = None
    execution: ExecutionOptions = Field(default_factory=ExecutionOptions)


class NodeUpdateRequest(BaseModel):
    action: Literal["update", "resize", "tag"] = "update"
    name: str | None = None
    description: str | None = None
    memory_mib: int | None = None
    new_size_id: str | None = None
    tag_key: str | None = None
    tag_value: str | None = None


class VolumeUpdateRequest(BaseModel):
    action: Literal["modify", "tag"] = "modify"
    new_size_gb: int | None = None
    volume_type: str | None = None
    iops: int | None = None
    tag_key: str | None = None
    tag_value: str | None = None


class ImageCreateRequest(BaseModel):
    name: str
    url: str | None = None
    vm_id: str | None = None
    description: str | None = None
    execution: ExecutionOptions = Field(default_factory=ExecutionOptions)


class VolumeAttachRequest(BaseModel):
    node_id: str
    device: str | None = None


class KeyPairCreateRequest(BaseModel):
    name: str
    public_key: str | None = None


class NodeResponse(BaseModel):
    id: str
    name: str | None
    state: str
    public_ips: list[str] = Field(default_factory=list)
    private_ips: list[str] = Field(default_factory=list)
    size: str | None = None
    image: str | None = None
    provider: str
    target: str
    extra: dict[str, Any] = Field(default_factory=dict)


class ImageResponse(BaseModel):
    id: str
    name: str | None = None
    extra: dict[str, Any] = Field(default_factory=dict)


class SizeResponse(BaseModel):
    id: str
    name: str | None = None
    ram: int | None = None
    disk: int | None = None
    bandwidth: int | None = None
    extra: dict[str, Any] = Field(default_factory=dict)


class LocationResponse(BaseModel):
    id: str
    name: str | None = None
    country: str | None = None
    extra: dict[str, Any] = Field(default_factory=dict)


class VolumeResponse(BaseModel):
    id: str
    name: str | None = None
    size: int | None = None
    state: str | None = None
    extra: dict[str, Any] = Field(default_factory=dict)


class KeyPairResponse(BaseModel):
    name: str
    fingerprint: str | None = None
    public_key: str | None = None
    private_key: str | None = None


class SnapshotResponse(BaseModel):
    id: str
    name: str | None = None
    volume_id: str | None = None
    state: str | None = None
    extra: dict[str, Any] = Field(default_factory=dict)
