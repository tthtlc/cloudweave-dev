from fastapi import Request

from app.auth.authorized_route import make_authorized_router
from app.auth.policy_table import policy_table
from app.common.responses import success_response

router = make_authorized_router(prefix="/v1/admin", tags=["admin"])


@router.post("/policies:reload")
def reload_policies(request: Request):
    # Scope gate (admin:connections:read) is enforced by AuthorizedAPIRoute via
    # the policy table entry "POST /v1/admin/policies:reload"
    # (connection_required=false). Force a re-read of app/auth/policies.json so
    # policy edits take effect without a restart or source-code change.
    entries = policy_table.reload()
    return success_response(
        {"reloaded": True, "entries": len(entries)},
        request,
    )
