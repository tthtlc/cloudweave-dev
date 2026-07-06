from fastapi import APIRouter, Depends, Request

from app.auth.dependencies import require_scopes
from app.auth.models import TokenClaims
from app.auth.policy import policy_engine
from app.common.responses import success_response
from app.connections.models import ProviderConnection
from app.providers.factory import test_connection

router = APIRouter(prefix="/v1/connections", tags=["connections"])


@router.post(":test")
def test_connection_endpoint(
    body: ProviderConnection,
    request: Request,
    claims: TokenClaims = Depends(require_scopes("compute:read")),
):
    # Enforce the same per-request OpenFGA authorization as every other
    # sensitive endpoint so callers cannot bypass authz by hitting the
    # connection-test path directly.
    body = policy_engine.authorize_connection(claims, body, "compute:read")
    _ = claims
    result = test_connection(body)
    return success_response(result, request)
