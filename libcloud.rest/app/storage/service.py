from __future__ import annotations

import base64
from typing import Any

from app.common.errors import APIError
from app.connections.models import ProviderConnection, connection_target
from app.providers.storage_factory import build_storage_driver
from app.storage.models import (
    BucketCreateRequest,
    BucketResponse,
    ObjectDownloadRequest,
    ObjectResponse,
    ObjectUploadRequest,
)


def _bucket_resp(bucket: Any, connection: ProviderConnection) -> dict[str, Any]:
    extra = {}
    try:
        extra = dict(bucket.extra or {})
    except Exception:
        extra = {}
    return {
        "id": getattr(bucket, "name", "") or "",
        "name": getattr(bucket, "name", "") or "",
        "provider": connection.provider,
        "target": connection_target(connection),
        "extra": extra,
    }


def _object_resp(obj: Any, connection: ProviderConnection, bucket: str) -> dict[str, Any]:
    extra = {}
    try:
        extra = dict(obj.meta_data or {})
    except Exception:
        extra = {}
    return {
        "name": getattr(obj, "name", "") or "",
        "bucket": bucket,
        "size": getattr(obj, "size", None),
        "provider": connection.provider,
        "target": connection_target(connection),
        "extra": extra,
    }


class StorageService:
    def list_buckets(self, connection: ProviderConnection) -> list[dict[str, Any]]:
        driver = build_storage_driver(connection)
        try:
            buckets = driver.list_containers()
        except Exception as exc:
            raise APIError("provider_operation_failed", "Failed to list buckets",
                           502, {"reason": str(exc)}) from exc
        return [_bucket_resp(b, connection) for b in buckets]

    def create_bucket(
        self, connection: ProviderConnection, request: BucketCreateRequest
    ) -> dict[str, Any]:
        driver = build_storage_driver(connection)
        location = request.location or connection.config.region
        try:
            bucket = driver.create_container(request.name)
        except Exception as exc:
            msg = str(exc).lower()
            if "already" in msg or "exists" in msg or "bucketowned" in msg:
                # Idempotent: fetch the existing bucket.
                try:
                    bucket = driver.get_container(request.name)
                except Exception as e2:
                    raise APIError("provider_operation_failed", "Bucket exists but could not be fetched",
                                   502, {"reason": str(e2)}) from e2
            else:
                raise APIError("provider_operation_failed", "Failed to create bucket",
                               502, {"reason": str(exc)}) from exc
        # Best-effort tagging (AWS supports ex_set_bucket_tags / tag dict via
        # extra on create; ignore if unsupported).
        if request.tags:
            try:
                if hasattr(driver, "ex_set_bucket_tags"):
                    driver.ex_set_bucket_tags(bucket.name, request.tags)
            except Exception:
                pass
        return _bucket_resp(bucket, connection)

    def delete_bucket(self, connection: ProviderConnection, bucket_name: str) -> dict[str, Any]:
        driver = build_storage_driver(connection)
        try:
            bucket = driver.get_container(bucket_name)
        except Exception as exc:
            raise APIError("resource_not_found", "Bucket not found", 404,
                           {"reason": str(exc)}) from exc
        # Refuse to delete a non-empty bucket (safer; matches the CLI contract).
        try:
            objs = driver.list_container_objects(bucket)
        except Exception:
            objs = []
        if objs:
            raise APIError("bucket_not_empty",
                           "Bucket is not empty; remove objects first or use --force",
                           409, {"object_count": len(objs)})
        try:
            bucket.delete()
        except Exception as exc:
            raise APIError("provider_operation_failed", "Failed to delete bucket",
                           502, {"reason": str(exc)}) from exc
        return {"id": bucket_name, "destroyed": True}

    def list_objects(
        self, connection: ProviderConnection, bucket_name: str, prefix: str | None = None
    ) -> list[dict[str, Any]]:
        driver = build_storage_driver(connection)
        try:
            bucket = driver.get_container(bucket_name)
        except Exception as exc:
            raise APIError("resource_not_found", "Bucket not found", 404,
                           {"reason": str(exc)}) from exc
        try:
            objs = driver.list_container_objects(bucket, prefix=prefix) if prefix \
                else driver.list_container_objects(bucket)
        except Exception as exc:
            raise APIError("provider_operation_failed", "Failed to list objects",
                           502, {"reason": str(exc)}) from exc
        return [_object_resp(o, connection, bucket_name) for o in objs]

    def upload_object(
        self, connection: ProviderConnection, request: ObjectUploadRequest
    ) -> dict[str, Any]:
        driver = build_storage_driver(connection)
        try:
            bucket = driver.get_container(request.bucket)
        except Exception as exc:
            raise APIError("resource_not_found", "Bucket not found", 404,
                           {"reason": str(exc)}) from exc
        try:
            payload = base64.b64decode(request.data_b64)
        except Exception as exc:
            raise APIError("validation_error", "data_b64 is not valid base64", 400,
                           {"reason": str(exc)}) from exc
        import tempfile, os
        fd, tmp = tempfile.mkstemp(prefix="libcloud-rest-upload-")
        try:
            with os.fdopen(fd, "wb") as fh:
                fh.write(payload)
            extra = {"meta_data": request.metadata or {}}
            if request.content_type:
                extra["content_type"] = request.content_type
            obj = driver.upload_object(tmp, bucket, request.object_name, extra=extra)
        except Exception as exc:
            raise APIError("provider_operation_failed", "Failed to upload object",
                           502, {"reason": str(exc)}) from exc
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        return _object_resp(obj, connection, request.bucket)

    def download_object(
        self, connection: ProviderConnection, request: ObjectDownloadRequest
    ) -> dict[str, Any]:
        driver = build_storage_driver(connection)
        try:
            bucket = driver.get_container(request.bucket)
        except Exception as exc:
            raise APIError("resource_not_found", "Bucket not found", 404,
                           {"reason": str(exc)}) from exc
        try:
            obj = bucket.get_object(request.object_name)
        except Exception as exc:
            raise APIError("resource_not_found", "Object not found", 404,
                           {"reason": str(exc)}) from exc
        import tempfile, os, base64 as _b64
        fd, tmp = tempfile.mkstemp(prefix="libcloud-rest-dl-")
        os.close(fd)
        try:
            obj.download(tmp, overwrite_existing=True)
            with open(tmp, "rb") as fh:
                data = fh.read()
        except Exception as exc:
            raise APIError("provider_operation_failed", "Failed to download object",
                           502, {"reason": str(exc)}) from exc
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        return {
            "name": request.object_name,
            "bucket": request.bucket,
            "size": len(data),
            "data_b64": _b64.b64encode(data).decode("ascii"),
            "provider": connection.provider,
            "target": connection_target(connection),
        }

    def delete_object(
        self, connection: ProviderConnection, bucket_name: str, object_name: str
    ) -> dict[str, Any]:
        driver = build_storage_driver(connection)
        try:
            bucket = driver.get_container(bucket_name)
        except Exception as exc:
            raise APIError("resource_not_found", "Bucket not found", 404,
                           {"reason": str(exc)}) from exc
        try:
            obj = bucket.get_object(object_name)
            obj.delete()
        except Exception as exc:
            raise APIError("provider_operation_failed", "Failed to delete object",
                           502, {"reason": str(exc)}) from exc
        return {"bucket": bucket_name, "object": object_name, "destroyed": True}


storage_service = StorageService()
