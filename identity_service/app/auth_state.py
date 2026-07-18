from __future__ import annotations

import hashlib
import base64
import secrets
import time
import uuid
from typing import Any

import jwt
from urllib.parse import urlencode

from app.config import get_settings
from app.errors import APIError

# Server-issued OAuth state + PKCE verifier store, and short-lived pending
# identity tokens for the collapse step.
#
# Why server-issued state: the browser used to generate `state` itself and only
# sanity-check it client-side (serverless/README §auth). That does not stop
# CSRF — the backend never verified it. Now /api/auth/begin mints `state` +
# PKCE `code_verifier`, stores them here, and /api/auth/exchange consumes them
# (single-use, TTL-bounded). The browser only carries the `state` echo.
#
# Why pending tokens: /api/auth/collapse used to trust a client-supplied
# `pendingIdentity.subject`. An attacker could link an arbitrary identity into
# a victim's account. Now /api/auth/exchange issues a signed, single-use
# pending token bound to the Dex-verified identity, and /api/auth/collapse
# accepts ONLY that token — the client's `pendingIdentity` is ignored.

_STATE_TTL = 600      # 10 min between begin and callback
_PENDING_TTL = 300    # 5 min between exchange(collapse) and collapse

_state_store: dict[str, dict[str, Any]] = {}
_used_jti: set[str] = set()


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _now() -> int:
    return int(time.time())


class AuthService:
    """Mints/consumes server-issued OAuth state + PKCE pairs and pending
    identity tokens. In-memory; move to Redis for multi-replica."""

    def __init__(self) -> None:
        self._settings = get_settings

    # --- state / PKCE -------------------------------------------------------
    def begin(self, *, provider: str, redirect_uri: str) -> dict[str, str]:
        s = self._settings()
        state = secrets.token_urlsafe(32)
        code_verifier = secrets.token_urlsafe(48)
        code_challenge = _b64url(hashlib.sha256(code_verifier.encode("ascii")).digest())
        _state_store[state] = {
            "code_verifier": code_verifier,
            "provider": provider,
            "redirect_uri": redirect_uri,
            "exp": _now() + _STATE_TTL,
        }
        params = {
            "client_id": s.dex_portal_client_id,
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "scope": "openid profile email",
            "state": state,
            "code_challenge": code_challenge,
            "code_challenge_method": "S256",
        }
        if provider:
            params["connector_id"] = provider
        authorize_url = f"{s.dex_base_url.rstrip('/')}/auth?{urlencode(params)}"
        return {"authorizeUrl": authorize_url, "state": state, "provider": provider}

    def consume_state(self, state: str) -> dict[str, Any]:
        if not state:
            raise APIError("auth_bad_state", "missing state", 400)
        entry = _state_store.pop(state, None)
        if entry is None:
            raise APIError("auth_bad_state", "unknown or reused state", 400)
        if _now() > entry["exp"]:
            raise APIError("auth_bad_state", "state expired", 400)
        return entry  # {code_verifier, provider, redirect_uri}

    # --- pending identity token --------------------------------------------
    def issue_pending(self, pending_identity: dict[str, str]) -> str:
        s = self._settings()
        now = _now()
        payload = {
            "provider": pending_identity["provider"],
            "subject": pending_identity["subject"],
            "email": pending_identity.get("email", ""),
            "iat": now,
            "exp": now + _PENDING_TTL,
            "jti": uuid.uuid4().hex,
            "type": "pending_identity",
        }
        return jwt.encode(payload, s.session_secret, algorithm="HS256")

    def consume_pending(self, token: str) -> dict[str, str]:
        s = self._settings()
        try:
            claims = jwt.decode(token, s.session_secret, algorithms=["HS256"])
        except jwt.PyJWTError as exc:
            raise APIError("auth_bad_pending_token", "pending token invalid or expired", 401, {"detail": str(exc)}) from exc
        if claims.get("type") != "pending_identity":
            raise APIError("auth_bad_pending_token", "wrong token type", 401)
        jti = claims.get("jti", "")
        if jti in _used_jti:
            raise APIError("auth_bad_pending_token", "pending token already used", 401)
        _used_jti.add(jti)
        return {"provider": claims["provider"], "subject": claims["subject"], "email": claims.get("email", "")}
