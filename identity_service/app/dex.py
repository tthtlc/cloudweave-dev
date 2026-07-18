from __future__ import annotations

import logging
from typing import Any

import httpx
import jwt
from jwt import PyJWKClient

from app.config import get_settings
from app.errors import APIError

log = logging.getLogger(__name__)


class DexService:
    """Exchange the portal's authorization code for OIDC tokens and verify the
    ID token. The portal client secret (DEX_PORTAL_CLIENT_SECRET) lives
    server-side only; the browser never sees it."""

    def __init__(self) -> None:
        self._jwks: PyJWKClient | None = None

    def _settings(self):
        return get_settings()

    def _jwks_client(self) -> PyJWKClient:
        if self._jwks is None:
            self._jwks = PyJWKClient(self._settings().dex_jwks_url)
        return self._jwks

    def exchange_code(self, *, code: str, redirect_uri: str, provider: str | None, code_verifier: str | None = None) -> dict[str, Any]:
        """POST /dex/token with the authorization_code grant.

        Mirrors test_script/scripts/idp_login.py: the portal is a confidential
        OAuth2 client, so the secret is required here. When the begin step used
        PKCE (S256), the server-held `code_verifier` is sent here so Dex can
        recompute the challenge — protecting the code from interception.
        """
        s = self._settings()
        data = {
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect_uri,
            "client_id": s.dex_portal_client_id,
            "client_secret": s.dex_portal_client_secret,
        }
        if code_verifier:
            data["code_verifier"] = code_verifier
        # Dex selects the upstream connector by `connector_id` at the authorize
        # step, not at token; we keep provider for logging only.
        log.info("Exchanging authorization code with Dex (provider=%s)", provider)
        try:
            resp = httpx.post(s.dex_token_url, data=data, timeout=15)
        except httpx.HTTPError as exc:
            raise APIError("auth_dex_unreachable", "Dex token endpoint unreachable", 503) from exc
        if resp.status_code != 200:
            raise APIError(
                "auth_dex_exchange_failed",
                "Dex rejected the authorization code",
                400,
                {"status": resp.status_code, "body": resp.text},
            )
        return resp.json()

    def verify_id_token(self, id_token: str) -> dict[str, Any]:
        """Verify signature (JWKS), iss, aud, exp. Returns the decoded claims."""
        s = self._settings()
        try:
            signing_key = self._jwks_client().get_signing_key_from_jwt(id_token)
            header = jwt.get_unverified_header(id_token)
            alg = header.get("alg") or getattr(signing_key, "algorithm_name", "RS256")
            claims = jwt.decode(
                id_token,
                signing_key.key,
                algorithms=[alg],
                audience=s.dex_portal_client_id,
                issuer=s.dex_issuer.rstrip("/"),
                options={"require": ["exp", "sub", "iss", "aud"]},
            )
        except jwt.PyJWTError as exc:
            raise APIError("auth_invalid_id_token", "ID token verification failed", 401, {"detail": str(exc)}) from exc
        return claims

    @staticmethod
    def external_identity(claims: dict[str, Any], connector_id: str | None) -> dict[str, str]:
        """Build the canonical external-identity record.

        `subject` is "<provider>:<sub>" — the same shape used in
        server/src/services/mockData.js linkedIdentities. `connector_id` is
        the connector the user picked (google/github); we fall back to a claim
        if Dex did not echo it.
        """
        provider = connector_id or claims.get("federated_claims", {}).get("connector_id", "") or "unknown"
        sub = str(claims.get("sub", ""))
        email = str(claims.get("email", "") or "")
        return {"provider": provider, "subject": f"{provider}:{sub}", "email": email}
