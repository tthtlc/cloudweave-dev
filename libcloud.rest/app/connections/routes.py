from fastapi import Request

from app.auth.authorized_route import make_authorized_router
from app.common.responses import success_response
from app.providers.factory import test_connection

router = make_authorized_router(prefix="/v1/connections", tags=["connections"])


@router.post(":test")
def test_connection_endpoint(request: Request):
    # The provider connection is resolved + authorized by AuthorizedAPIRoute
    # (entry "POST /v1/connections:test" in app/auth/policies.json) and exposed
    # on request.state.connection — same path as every other endpoint.
    connection = request.state.connection
    result = test_connection(connection)
    return success_response(result, request)
