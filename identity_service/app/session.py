from __future__ import annotations

import time
import uuid
from typing import Any

import jwt
from fastapi import Request, Response

from app.config import get_settings
from app.errors import APIError

# Server-side session store: maps session id -> Dex refresh token + metadata.
# NOTE: in-memory only. For a multi-replica deployment move this to Redis (or
# store the refresh token in Vault and keep only a session id here). A single
# replica is fine for the current single-container deployment.
_refresh_store: dict[str, dict[str, Any]] = {}


class SessionService:
    """Mints and verifies the httpOnly session cookie.

    The cookie carries a signed JWT with internalUserId + role + email +
    linkedIdentities (the same minimal metadata the browser stashes in
    sessionStorage — see server/src/context/AuthContext.js). The Dex refresh
    token is kept SERVER-SIDE only, keyed by session id, never exposed to the
    browser.
    """

    def __init__(self) -> None:
        self._settings = get_settings

    def _encode(self, claims: dict[str, Any]) -> str:
        s = self._settings()
        now = int(time.time())
        payload = {
            **claims,
            "iat": now,
            "exp": now + s.session_ttl_seconds,
            "jti": uuid.uuid4().hex,
        }
        return jwt.encode(payload, s.session_secret, algorithm="HS256")

    def _decode(self, token: str) -> dict[str, Any]:
        s = self._settings()
        try:
            return jwt.decode(token, s.session_secret, algorithms=["HS256"])
        except jwt.PyJWTError as exc:
            raise APIError("auth_invalid_session", "Session cookie invalid or expired", 401, {"detail": str(exc)}) from exc

    def create(self, resp: Response, *, internal_user: dict[str, Any], refresh_token: str | None) -> dict[str, Any]:
        s = self._settings()
        sid = uuid.uuid4().hex
        meta = {
            "internalUserId": internal_user["internalUserId"],
            "role": internal_user["role"],
            "email": internal_user["email"],
            "linkedIdentities": internal_user["linkedIdentities"],
            "sid": sid,
        }
        if refresh_token:
            _refresh_store[sid] = {"refresh_token": refresh_token, "internalUserId": internal_user["internalUserId"]}
        cookie_value = self._encode(meta)
        resp.set_cookie(
            key=s.session_cookie_name,
            value=cookie_value,
            max_age=s.session_ttl_seconds,
            httponly=True,
            secure=s.session_secure,
            samesite=s.session_samesite,
            path="/",
        )
        return {k: v for k, v in meta.items() if k != "sid"}

    def read(self, req: Request) -> dict[str, Any]:
        s = self._settings()
        token = req.cookies.get(s.session_cookie_name)
        if not token:
            raise APIError("auth_no_session", "No session", 401)
        return self._decode(token)

    def revoke(self, req: Request, resp: Response) -> None:
        s = self._settings()
        token = req.cookies.get(s.session_cookie_name)
        if token:
            try:
                claims = self._decode(token)
                _refresh_store.pop(claims.get("sid", ""), None)
            except APIError:
                pass
        resp.delete_cookie(s.session_cookie_name, path="/")

    def refresh_token_for(self, sid: str) -> str | None:
        entry = _refresh_store.get(sid)
        return entry["refresh_token"] if entry else None
