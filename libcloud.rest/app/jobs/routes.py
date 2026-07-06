from fastapi import APIRouter, Depends, Request

from app.auth.dependencies import require_scopes
from app.auth.models import TokenClaims
from app.common.responses import success_response
from app.jobs.worker import job_store

router = APIRouter(prefix="/v1/jobs", tags=["jobs"])


@router.get("/{job_id}")
def get_job(
    job_id: str,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("jobs:read")),
):
    job = job_store.get(job_id)
    if job.requested_by != claims.sub and "admin:connections:read" not in claims.scope.split():
        from app.common.errors import APIError

        raise APIError(
            code="auth_connection_denied",
            message="Not authorized to view this job",
            status_code=403,
            details={"job_id": job_id},
        )
    return success_response(job.model_dump(), request)
