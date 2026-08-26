from fastapi import Query, Request

from app.auth.authorized_route import make_authorized_router
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
from app.connections.models import connection_target
from app.jobs.worker import job_worker

router = make_authorized_router(prefix="/v1/compute", tags=["compute"])


def _maybe_async(
    claims,
    connection,
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
def list_locations(request: Request):
    connection = request.state.connection
    data = [loc.model_dump() for loc in compute_service.list_locations(connection)]
    return success_response(data, request)


@router.get("/hosts")
def list_hosts(
    request: Request,
    cluster_ext_id: str | None = Query(None, alias="clusterExtId"),
):
    connection = request.state.connection
    data = compute_service.list_hosts(connection, cluster_ext_id=cluster_ext_id)
    return success_response(data, request)


@router.get("/hosts/{host_id}")
def get_host(
    host_id: str,
    request: Request,
    cluster_ext_id: str | None = Query(None, alias="clusterExtId"),
):
    connection = request.state.connection
    data = compute_service.get_host(connection, host_id, cluster_ext_id=cluster_ext_id)
    return success_response(data, request)


@router.get("/hosts/{host_id}/bmc-info")
def get_host_bmc_info(
    host_id: str,
    request: Request,
    cluster_ext_id: str | None = Query(None, alias="clusterExtId"),
):
    connection = request.state.connection
    data = compute_service.get_host_bmc_info(connection, host_id, cluster_ext_id=cluster_ext_id)
    return success_response(data, request)


@router.get("/images")
def list_images(
    request: Request,
    owner: str | None = None,
    name_filter: str | None = Query(
        None,
        alias="name",
        description="AWS only: DescribeImages name filter (supports * wildcards). "
        "Omit to use the server default (*ubuntu*24.04*amd64*). Pass name=* to list all images.",
    ),
    arch: str | None = Query(
        None,
        description="AWS only: architecture filter (x86_64 | arm64 | i386). "
        "Omit to use the server default (x86_64). Pass arch=* to skip the arch filter.",
    ),
):
    connection = request.state.connection
    filters: dict[str, str] | None = None
    if name_filter is None:
        filters = None
    elif name_filter == "*":
        filters = {}
    else:
        filters = {"name": name_filter}
    data = [
        img.model_dump()
        for img in compute_service.list_images(connection, owner=owner, filters=filters, arch=arch)
    ]
    return success_response(data, request)


@router.get("/sizes")
def list_sizes(request: Request):
    connection = request.state.connection
    data = [size.model_dump() for size in compute_service.list_sizes(connection)]
    return success_response(data, request)


@router.get("/nodes")
def list_nodes(request: Request):
    connection = request.state.connection
    data = [node.model_dump() for node in compute_service.list_nodes(connection)]
    return success_response(data, request)


@router.get("/nodes/{node_id}")
def get_node(node_id: str, request: Request):
    connection = request.state.connection
    node = compute_service.get_node(connection, node_id)
    return success_response(node.model_dump(), request)


@router.post("/nodes")
def create_node(body: NodeCreateRequest, request: Request):
    connection = request.state.connection
    claims = request.state.authorized_claims

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
def update_node(node_id: str, body: NodeUpdateRequest, request: Request):
    connection = request.state.connection
    result = compute_service.update_node(connection, node_id, body)
    return success_response(result, request)


@router.post("/nodes/{node_id}:start")
def start_node(node_id: str, request: Request):
    connection = request.state.connection
    result = compute_service.power_node(connection, node_id, "start")
    return success_response(result, request)


@router.post("/nodes/{node_id}:stop")
def stop_node(node_id: str, request: Request):
    connection = request.state.connection
    result = compute_service.power_node(connection, node_id, "stop")
    return success_response(result, request)


@router.post("/nodes/{node_id}:reboot")
def reboot_node(node_id: str, request: Request):
    connection = request.state.connection
    result = compute_service.power_node(connection, node_id, "reboot")
    return success_response(result, request)


@router.delete("/nodes/{node_id}")
def delete_node(
    node_id: str,
    request: Request,
    async_mode: bool = Query(False, alias="async"),
):
    connection = request.state.connection
    claims = request.state.authorized_claims

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
    volume_id: str | None = Query(None, alias="id"),
):
    connection = request.state.connection
    data = [v.model_dump() for v in compute_service.list_volumes(connection, volume_id=volume_id)]
    return success_response(data, request)


@router.post("/volumes")
def create_volume(body: VolumeCreateRequest, request: Request):
    connection = request.state.connection
    claims = request.state.authorized_claims

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
def update_volume(volume_id: str, body: VolumeUpdateRequest, request: Request):
    connection = request.state.connection
    result = compute_service.update_volume(connection, volume_id, body)
    return success_response(result, request)


@router.delete("/volumes/{volume_id}")
def delete_volume(volume_id: str, request: Request):
    connection = request.state.connection
    result = compute_service.destroy_volume(connection, volume_id)
    return success_response(result, request)


@router.post("/volumes/{volume_id}:attach")
def attach_volume(volume_id: str, body: VolumeAttachRequest, request: Request):
    connection = request.state.connection
    result = compute_service.attach_volume(connection, body, volume_id)
    return success_response(result, request)


@router.post("/volumes/{volume_id}:detach")
def detach_volume(volume_id: str, body: VolumeAttachRequest, request: Request):
    connection = request.state.connection
    result = compute_service.detach_volume(connection, body, volume_id)
    return success_response(result, request)


@router.get("/snapshots")
def list_snapshots(
    request: Request,
    volume_id: str | None = None,
    snapshot_id: str | None = Query(None, alias="id"),
    owner: str | None = Query(
        None,
        description="AWS only: snapshot owner filter (self|amazon|<account-id>). "
        "Omitting it returns ALL public snapshots (DescribeSnapshots default).",
    ),
):
    connection = request.state.connection
    data = [
        s.model_dump()
        for s in compute_service.list_snapshots(connection, volume_id=volume_id, snapshot_id=snapshot_id, owner=owner)
    ]
    return success_response(data, request)


@router.post("/snapshots")
def create_snapshot(body: SnapshotCreateRequest, request: Request):
    connection = request.state.connection
    claims = request.state.authorized_claims

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
    volume_id: str | None = None,
):
    connection = request.state.connection
    result = compute_service.destroy_snapshot(connection, snapshot_id, volume_id=volume_id)
    return success_response(result, request)


@router.post("/images")
def create_image(body: ImageCreateRequest, request: Request):
    connection = request.state.connection
    claims = request.state.authorized_claims

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
def delete_image(image_id: str, request: Request):
    connection = request.state.connection
    result = compute_service.destroy_image(connection, image_id)
    return success_response(result, request)


@router.get("/key-pairs")
def list_key_pairs(request: Request):
    connection = request.state.connection
    data = [k.model_dump() for k in compute_service.list_key_pairs(connection)]
    return success_response(data, request)


@router.post("/key-pairs")
def create_key_pair(body: KeyPairCreateRequest, request: Request):
    connection = request.state.connection
    result = compute_service.create_key_pair(connection, body)
    return success_response(result.model_dump(), request)


@router.delete("/key-pairs/{name}")
def delete_key_pair(name: str, request: Request):
    connection = request.state.connection
    result = compute_service.delete_key_pair(connection, name)
    return success_response(result, request)
