from typing import Any

from fastapi import Request


def success_response(data: Any, request: Request, meta: dict[str, Any] | None = None) -> dict:
    payload: dict[str, Any] = {"data": data}
    combined_meta = {"request_id": getattr(request.state, "request_id", "unknown")}
    if meta:
        combined_meta.update(meta)
    payload["meta"] = combined_meta
    return payload
