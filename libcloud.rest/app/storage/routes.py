from fastapi import APIRouter, Depends, Query, Request

from app.auth.dependencies import require_any_scopes, require_scopes
from app.auth.models import TokenClaims
from app.auth.policy import policy_engine
from app.common.responses import success_response
from app.connections.dependencies import parse_connection_query
from app.connections.models import ProviderConnection
from app.storage.models import BucketCreateRequest, ObjectDownloadRequest, ObjectUploadRequest
from app.storage.service import storage_service

router = APIRouter(prefix="/v1/storage", tags=["storage"])


@router.get("/buckets")
def list_buckets(
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    claims: TokenClaims = Depends(require_any_scopes("compute:read", "compute:network:read")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:read")
    data = storage_service.list_buckets(connection)
    return success_response(data, request)


@router.post("/buckets")
def create_bucket(
    body: BucketCreateRequest,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("compute:network:manage")),
):
    connection = policy_engine.authorize_connection(claims, body.connection, "compute:network:manage")
    data = storage_service.create_bucket(connection, body)
    return success_response(data, request)


@router.delete("/buckets/{bucket_name}")
def delete_bucket(
    bucket_name: str,
    request: Request,
    force: bool = False,
    connection: ProviderConnection = Depends(parse_connection_query),
    claims: TokenClaims = Depends(require_scopes("compute:network:manage")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:network:manage")
    data = storage_service.delete_bucket(connection, bucket_name)
    return success_response(data, request)


@router.get("/buckets/{bucket_name}/objects")
def list_objects(
    bucket_name: str,
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    prefix: str | None = Query(None),
    claims: TokenClaims = Depends(require_any_scopes("compute:read", "compute:network:read")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:read")
    data = storage_service.list_objects(connection, bucket_name, prefix=prefix)
    return success_response(data, request)


@router.post("/buckets/{bucket_name}/objects")
def upload_object(
    bucket_name: str,
    body: ObjectUploadRequest,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("compute:network:manage")),
):
    if body.bucket != bucket_name:
        body.bucket = bucket_name
    connection = policy_engine.authorize_connection(claims, body.connection, "compute:network:manage")
    data = storage_service.upload_object(connection, body)
    return success_response(data, request)


@router.post("/buckets/{bucket_name}/objects/{object_name:path}:download")
def download_object(
    bucket_name: str,
    object_name: str,
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    claims: TokenClaims = Depends(require_any_scopes("compute:read", "compute:network:read")),
):
    req = ObjectDownloadRequest(connection=connection, bucket=bucket_name, object_name=object_name)
    connection = policy_engine.authorize_connection(claims, connection, "compute:read")
    data = storage_service.download_object(connection, req)
    return success_response(data, request)


@router.delete("/buckets/{bucket_name}/objects/{object_name:path}")
def delete_object(
    bucket_name: str,
    object_name: str,
    request: Request,
    connection: ProviderConnection = Depends(parse_connection_query),
    claims: TokenClaims = Depends(require_scopes("compute:network:manage")),
):
    connection = policy_engine.authorize_connection(claims, connection, "compute:network:manage")
    data = storage_service.delete_object(connection, bucket_name, object_name)
    return success_response(data, request)
