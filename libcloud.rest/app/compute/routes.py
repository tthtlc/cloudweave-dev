from fastapi import APIRouter, Depends, Query, Request

from app.auth.dependencies import require_any_scopes, require_scopes
from app.auth.models import TokenClaims
from app.auth.policy import policy_engine
from app.common.responses import success_response
from app.compute.models import (
    ImageCreateRequest,
    KeyPairCreateRequest,
    NodeCreateRequest,
    NodeUpdateRequest,
    SnapshotCreateRequest,
    VolumeAttachRequest,
    VolumeCreateRequest,
    VolumeUpdateRequest,
)
from app.compute.service import compute_service
from app.connections.dependencies import parse_connection_query
from app.connections.models import ProviderConnection, connection_target
from app.jobs.worker import job_worker

router = APIRouter(prefix="/v1/compute", tags=["compute"])


def _maybe_async(
    claims: TokenClaims,
    connection: ProviderConnection,
    operation: str,
    request_payload: dict,
    sync_fn,
    async_default: bool = False,
):
    mode = request_payload.get("execution", {}).get("mode")
    if mode == "async" or (mode is None and async_default):
        job = job_worker.submit(
            operation=operation,
            fn=sync_fn,
            requested_by=claims.sub,
            token_jti=claims.jti,
            connection_target=connection_target(connection),
            provider=connection.provider,
            scope_snapshot=claims.scope,
            request_payload=request_payload,
        )
        return {"job_id": job.id, "status": job.status}
    return sync_fn()


@router.get("/locations")
def list_locations(
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    claims: TokenClaims = Depends(require_any_scopes("compute:location:read", "compute:read")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:location:read")
    data = [loc.model_dump() for loc in compute_service.list_locations(connection)]
    return success_response(data, request)


@router.get("/images")
def list_images(
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    owner: str | None = None,
    name_filter: str | None = Query(
        None,
        alias="name",
        description="AWS only: DescribeImages name filter (supports * wildcards). "
        "Omit to use the server default (*Ubuntu*). Pass name=* to list all images.",
    ),
    claims: TokenClaims = Depends(require_any_scopes("compute:image:read", "compute:read")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:image:read")
    filters: dict[str, str] | None = None
    if name_filter is None:
        filters = None
    elif name_filter == "*":
        filters = {}
    else:
        filters = {"name": name_filter}
    data = [
        img.model_dump()
        for img in compute_service.list_images(connection, owner=owner, filters=filters)
    ]
    return success_response(data, request)


@router.get("/sizes")
def list_sizes(
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    claims: TokenClaims = Depends(require_any_scopes("compute:size:read", "compute:read")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:size:read")
    data = [size.model_dump() for size in compute_service.list_sizes(connection)]
    return success_response(data, request)


@router.get("/nodes")
def list_nodes(
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    claims: TokenClaims = Depends(require_scopes("compute:read")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:read")
    data = [node.model_dump() for node in compute_service.list_nodes(connection)]
    return success_response(data, request)


@router.get("/nodes/{node_id}")
def get_node(
    node_id: str,
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    claims: TokenClaims = Depends(require_scopes("compute:read")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:read")
    node = compute_service.get_node(connection, node_id)
    return success_response(node.model_dump(), request)


@router.post("/nodes")
def create_node(
    body: NodeCreateRequest,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("compute:node:create")),
):
    connection = policy_engine.authorize_connection(claims, body.connection, "compute:node:create")
    policy_engine.check_driver_capability(connection, "create_node")

    def _create():
        return compute_service.create_node(connection, body).model_dump()

    result = _maybe_async(
        claims,
        connection,
        "create_node",
        body.model_dump(),
        _create,
        async_default=body.execution.mode == "async",
    )
    return success_response(result, request)


@router.patch("/nodes/{node_id}")
def update_node(
    node_id: str,
    body: NodeUpdateRequest,
    request: Request,
    claims: TokenClaims = Depends(require_any_scopes("compute:node:power", "compute:node:update")),
):
    connection = policy_engine.authorize_connection(
        claims, body.connection, "compute:node:update" if body.action == "update" else "compute:node:power"
    )
    result = compute_service.update_node(connection, node_id, body)
    return success_response(result, request)


@router.post("/nodes/{node_id}:start")
def start_node(
    node_id: str,
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    claims: TokenClaims = Depends(require_scopes("compute:node:power")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:node:power")
    result = compute_service.power_node(connection, node_id, "start")
    return success_response(result, request)


@router.post("/nodes/{node_id}:stop")
def stop_node(
    node_id: str,
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    claims: TokenClaims = Depends(require_scopes("compute:node:power")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:node:power")
    result = compute_service.power_node(connection, node_id, "stop")
    return success_response(result, request)


@router.post("/nodes/{node_id}:reboot")
def reboot_node(
    node_id: str,
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    claims: TokenClaims = Depends(require_scopes("compute:node:power")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:node:power")
    result = compute_service.power_node(connection, node_id, "reboot")
    return success_response(result, request)


@router.delete("/nodes/{node_id}")
def delete_node(
    node_id: str,
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    async_mode: bool = Query(False, alias="async"),
    claims: TokenClaims = Depends(require_scopes("compute:node:delete")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:node:delete")
    policy_engine.check_driver_capability(connection, "destroy_node")

    payload = {"connection": connection.model_dump(), "node_id": node_id}

    def _destroy():
        return compute_service.destroy_node(connection, node_id)

    if async_mode:
        job = job_worker.submit(
            operation="destroy_node",
            fn=_destroy,
            requested_by=claims.sub,
            token_jti=claims.jti,
            connection_target=connection_target(connection),
            provider=connection.provider,
            scope_snapshot=claims.scope,
            request_payload=payload,
        )
        return success_response({"job_id": job.id, "status": job.status}, request)

    result = _destroy()
    return success_response(result, request)


@router.get("/volumes")
def list_volumes(
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    volume_id: str | None = Query(None, alias="id"),
    claims: TokenClaims = Depends(require_any_scopes("compute:volume:manage", "compute:read")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:read")
    data = [v.model_dump() for v in compute_service.list_volumes(connection, volume_id=volume_id)]
    return success_response(data, request)


@router.post("/volumes")
def create_volume(
    body: VolumeCreateRequest,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("compute:volume:manage")),
):
    connection = policy_engine.authorize_connection(claims, body.connection, "compute:volume:manage")
    policy_engine.check_driver_capability(connection, "volumes")

    def _create():
        return compute_service.create_volume(connection, body).model_dump()

    result = _maybe_async(
        claims,
        connection,
        "create_volume",
        body.model_dump(),
        _create,
        async_default=body.execution.mode == "async",
    )
    return success_response(result, request)


@router.patch("/volumes/{volume_id}")
def update_volume(
    volume_id: str,
    body: VolumeUpdateRequest,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("compute:volume:manage")),
):
    connection = policy_engine.authorize_connection(claims, body.connection, "compute:volume:manage")
    result = compute_service.update_volume(connection, volume_id, body)
    return success_response(result, request)


@router.delete("/volumes/{volume_id}")
def delete_volume(
    volume_id: str,
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    claims: TokenClaims = Depends(require_scopes("compute:volume:manage")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:volume:manage")
    result = compute_service.destroy_volume(connection, volume_id)
    return success_response(result, request)


@router.post("/volumes/{volume_id}:attach")
def attach_volume(
    volume_id: str,
    body: VolumeAttachRequest,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("compute:volume:manage")),
):
    connection = policy_engine.authorize_connection(claims, body.connection, "compute:volume:manage")
    result = compute_service.attach_volume(connection, body, volume_id)
    return success_response(result, request)


@router.post("/volumes/{volume_id}:detach")
def detach_volume(
    volume_id: str,
    body: VolumeAttachRequest,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("compute:volume:manage")),
):
    connection = policy_engine.authorize_connection(claims, body.connection, "compute:volume:manage")
    result = compute_service.detach_volume(connection, body, volume_id)
    return success_response(result, request)


@router.get("/snapshots")
def list_snapshots(
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    volume_id: str | None = None,
    snapshot_id: str | None = Query(None, alias="id"),
    claims: TokenClaims = Depends(require_any_scopes("compute:snapshot:manage", "compute:read")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:read")
    data = [
        s.model_dump()
        for s in compute_service.list_snapshots(connection, volume_id=volume_id, snapshot_id=snapshot_id)
    ]
    return success_response(data, request)


@router.post("/snapshots")
def create_snapshot(
    body: SnapshotCreateRequest,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("compute:snapshot:manage")),
):
    connection = policy_engine.authorize_connection(claims, body.connection, "compute:snapshot:manage")
    policy_engine.check_driver_capability(connection, "snapshots")

    def _create():
        return compute_service.create_snapshot(connection, body).model_dump()

    result = _maybe_async(
        claims,
        connection,
        "create_snapshot",
        body.model_dump(),
        _create,
        async_default=body.execution.mode == "async",
    )
    return success_response(result, request)


@router.delete("/snapshots/{snapshot_id}")
def delete_snapshot(
    snapshot_id: str,
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    volume_id: str | None = None,
    claims: TokenClaims = Depends(require_scopes("compute:snapshot:manage")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:snapshot:manage")
    result = compute_service.destroy_snapshot(connection, snapshot_id, volume_id=volume_id)
    return success_response(result, request)


@router.post("/images")
def create_image(
    body: ImageCreateRequest,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("compute:image:manage")),
):
    connection = policy_engine.authorize_connection(claims, body.connection, "compute:image:manage")

    def _create():
        return compute_service.create_image(connection, body).model_dump()

    result = _maybe_async(
        claims,
        connection,
        "create_image",
        body.model_dump(),
        _create,
        async_default=body.execution.mode == "async",
    )
    return success_response(result, request)


@router.delete("/images/{image_id}")
def delete_image(
    image_id: str,
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    claims: TokenClaims = Depends(require_scopes("compute:image:manage")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:image:manage")
    result = compute_service.destroy_image(connection, image_id)
    return success_response(result, request)


@router.get("/key-pairs")
def list_key_pairs(
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    claims: TokenClaims = Depends(require_any_scopes("compute:keypair:manage", "compute:read")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:read")
    data = [k.model_dump() for k in compute_service.list_key_pairs(connection)]
    return success_response(data, request)


@router.post("/key-pairs")
def create_key_pair(
    body: KeyPairCreateRequest,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("compute:keypair:manage")),
):
    connection = policy_engine.authorize_connection(claims, body.connection, "compute:keypair:manage")
    policy_engine.check_driver_capability(connection, "key_pairs")
    result = compute_service.create_key_pair(connection, body)
    return success_response(result.model_dump(), request)


@router.delete("/key-pairs/{name}")
def delete_key_pair(
    name: str,
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    claims: TokenClaims = Depends(require_scopes("compute:keypair:manage")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:keypair:manage")
    policy_engine.check_driver_capability(connection, "key_pairs")
    result = compute_service.delete_key_pair(connection, name)
    return success_response(result, request)
