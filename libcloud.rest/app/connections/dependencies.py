import json
from urllib.parse import unquote

from fastapi import Header, Query

from app.common.errors import APIError
from app.connections.models import ProviderConnection


def parse_connection_raw(raw: str, *, url_encoded: bool) -> ProviderConnection:
    try:
        payload = unquote(raw) if url_encoded else raw
        data = json.loads(payload)
        return ProviderConnection.model_validate(data)
    except Exception as exc:
        raise APIError(
            code="invalid_connection",
            message="Invalid provider connection; expected JSON object",
            status_code=400,
        ) from exc


# Back-compat alias used internally by the legacy Depends path.
_parse_connection_raw = parse_connection_raw


def parse_connection_query(
    connection: str | None = Query(
        None,
        description="URL-encoded JSON provider connection object (legacy; prefer X-Provider-Connection header)",
    ),
    x_provider_connection: str | None = Header(
        None,
        alias="X-Provider-Connection",
        description="JSON provider connection object (preferred over connection query param)",
    ),
) -> ProviderConnection:
    if x_provider_connection:
        return _parse_connection_raw(x_provider_connection, url_encoded=False)
    if connection:
        return _parse_connection_raw(connection, url_encoded=True)
    raise APIError(
        code="invalid_connection",
        message="Missing provider connection; send X-Provider-Connection header or connection query parameter",
        status_code=400,
    )
