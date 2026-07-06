import copy
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from typing import Any, Callable, Literal

from pydantic import BaseModel, Field

from app.common.errors import APIError

JobStatus = Literal["pending", "running", "completed", "failed"]


class JobRecord(BaseModel):
    id: str
    operation: str
    status: JobStatus = "pending"
    requested_by: str
    token_jti: str
    connection_target: str
    provider: str
    scope_snapshot: str
    request_payload_redacted: dict[str, Any] = Field(default_factory=dict)
    progress: int = 0
    result_resource_id: str | None = None
    result: Any | None = None
    error_code: str | None = None
    error_message: str | None = None
    submitted_at: str
    started_at: str | None = None
    completed_at: str | None = None


SENSITIVE_KEYS = {"password", "secret", "private_key", "public_key", "key"}


def redact_payload(payload: dict[str, Any]) -> dict[str, Any]:
    redacted = copy.deepcopy(payload)

    def _walk(obj: Any) -> Any:
        if isinstance(obj, dict):
            walked = {}
            for k, v in obj.items():
                if k in SENSITIVE_KEYS:
                    walked[k] = "***REDACTED***"
                elif k == "credentials" and isinstance(v, dict):
                    walked[k] = {ck: "***REDACTED***" for ck in v}
                else:
                    walked[k] = _walk(v)
            return walked
        if isinstance(obj, list):
            return [_walk(item) for item in obj]
        return obj

    return _walk(redacted)


class JobStore:
    def __init__(self) -> None:
        self._jobs: dict[str, JobRecord] = {}

    def create(self, **kwargs) -> JobRecord:
        now = datetime.now(timezone.utc).isoformat()
        job = JobRecord(
            id=f"job_{uuid.uuid4().hex[:16]}",
            submitted_at=now,
            **kwargs,
        )
        self._jobs[job.id] = job
        return job

    def get(self, job_id: str) -> JobRecord:
        job = self._jobs.get(job_id)
        if not job:
            raise APIError(
                code="resource_not_found",
                message="Job not found",
                status_code=404,
                details={"job_id": job_id},
            )
        return job

    def update(self, job_id: str, **kwargs) -> JobRecord:
        job = self.get(job_id)
        data = job.model_dump()
        data.update(kwargs)
        updated = JobRecord.model_validate(data)
        self._jobs[job_id] = updated
        return updated


class JobWorker:
    def __init__(self, store: JobStore) -> None:
        self.store = store
        self._executor = ThreadPoolExecutor(max_workers=4, thread_name_prefix="libcloud-job")

    def submit(
        self,
        operation: str,
        fn: Callable[[], Any],
        *,
        requested_by: str,
        token_jti: str,
        connection_target: str,
        provider: str,
        scope_snapshot: str,
        request_payload: dict[str, Any],
    ) -> JobRecord:
        job = self.store.create(
            operation=operation,
            requested_by=requested_by,
            token_jti=token_jti,
            connection_target=connection_target,
            provider=provider,
            scope_snapshot=scope_snapshot,
            request_payload_redacted=redact_payload(request_payload),
        )
        self._executor.submit(self._run, job.id, fn)
        return job

    def _run(self, job_id: str, fn: Callable[[], Any]) -> None:
        now = datetime.now(timezone.utc).isoformat()
        self.store.update(job_id, status="running", started_at=now, progress=10)
        try:
            result = fn()
            completed = datetime.now(timezone.utc).isoformat()
            resource_id = None
            if isinstance(result, dict):
                resource_id = result.get("id")
            self.store.update(
                job_id,
                status="completed",
                progress=100,
                result=result,
                result_resource_id=resource_id,
                completed_at=completed,
            )
        except APIError as exc:
            completed = datetime.now(timezone.utc).isoformat()
            self.store.update(
                job_id,
                status="failed",
                progress=100,
                error_code=exc.code,
                error_message=exc.message,
                completed_at=completed,
            )
        except Exception as exc:
            completed = datetime.now(timezone.utc).isoformat()
            self.store.update(
                job_id,
                status="failed",
                progress=100,
                error_code="provider_operation_failed",
                error_message=str(exc),
                completed_at=completed,
            )


job_store = JobStore()
job_worker = JobWorker(job_store)
