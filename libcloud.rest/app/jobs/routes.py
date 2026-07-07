from fastapi import Request

from app.auth.authorized_route import make_authorized_router
from app.common.errors import APIError
from app.common.responses import success_response
from app.jobs.worker import job_store

router = make_authorized_router(prefix="/v1/jobs", tags=["jobs"])


@router.get("/{job_id}")
def get_job(job_id: str, request: Request):
    # Scope gate (jobs:read) is enforced by AuthorizedAPIRoute via the policy
    # table entry "GET /v1/jobs/{job_id}" (connection_required=false). The check
    # below is a resource-level ownership check (job belongs to caller or admin),
    # which is business logic, not policy-engine authorization.
    claims = request.state.authorized_claims
    job = job_store.get(job_id)
    if job.requested_by != claims.sub and "admin:connections:read" not in claims.scope.split():
        raise APIError(
            code="auth_connection_denied",
            message="Not authorized to view this job",
            status_code=403,
            details={"job_id": job_id},
        )
    return success_response(job.model_dump(), request)
