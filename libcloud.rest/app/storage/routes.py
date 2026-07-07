from fastapi import Query, Request

from app.auth.authorized_route import make_authorized_router
from app.common.responses import success_response
from app.storage.models import (
    BucketCreateRequest,
    ObjectDownloadRequest,
    ObjectUploadRequest,
)
from app.storage.service import storage_service

router = make_authorized_router(prefix="/v1/storage", tags=["storage"])


@router.get("/buckets")
def list_buckets(request: Request):
    connection = request.state.connection
    data = storage_service.list_buckets(connection)
    return success_response(data, request)


@router.post("/buckets")
def create_bucket(body: BucketCreateRequest, request: Request):
    connection = request.state.connection
    data = storage_service.create_bucket(connection, body)
    return success_response(data, request)


@router.delete("/buckets/{bucket_name}")
def delete_bucket(bucket_name: str, request: Request, force: bool = False):
    connection = request.state.connection
    data = storage_service.delete_bucket(connection, bucket_name)
    return success_response(data, request)


@router.get("/buckets/{bucket_name}/objects")
def list_objects(
    bucket_name: str,
    request: Request,
    prefix: str | None = Query(None),
):
    connection = request.state.connection
    data = storage_service.list_objects(connection, bucket_name, prefix=prefix)
    return success_response(data, request)


@router.post("/buckets/{bucket_name}/objects")
def upload_object(bucket_name: str, body: ObjectUploadRequest, request: Request):
    if body.bucket != bucket_name:
        body.bucket = bucket_name
    connection = request.state.connection
    data = storage_service.upload_object(connection, body)
    return success_response(data, request)


@router.post("/buckets/{bucket_name}/objects/{object_name:path}:download")
def download_object(bucket_name: str, object_name: str, request: Request):
    connection = request.state.connection
    req = ObjectDownloadRequest(bucket=bucket_name, object_name=object_name)
    data = storage_service.download_object(connection, req)
    return success_response(data, request)


@router.delete("/buckets/{bucket_name}/objects/{object_name:path}")
def delete_object(bucket_name: str, object_name: str, request: Request):
    connection = request.state.connection
    data = storage_service.delete_object(connection, bucket_name, object_name)
    return success_response(data, request)
