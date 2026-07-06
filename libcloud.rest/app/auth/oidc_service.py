from __future__ import annotations

import base64
import json
from typing import Any

import jwt
from jwt import PyJWKClient

from app.auth.identity import (
    audit_auth_event,
    principal_providers,
    principal_scopes,
    resolve_principal,
)
from app.auth.models import TokenClaims
from app.common.errors import APIError
from app.config.settings import get_settings


class OidcAuthService:
    def __init__(self) -> None:
        self._jwks_client: PyJWKClient | None = None

    def _client(self) -> PyJWKClient:
        settings = get_settings()
        if not settings.oidc_jwks_url:
            raise APIError(
                code="auth_misconfigured",
                message="OIDC JWKS URL is not configured",
                status_code=500,
            )
        if self._jwks_client is None:
            self._jwks_client = PyJWKClient(settings.oidc_jwks_url)
        return self._jwks_client

    @staticmethod
    def _looks_like_oidc_token(token: str) -> bool:
        settings = get_settings()
        if not settings.oidc_enabled:
            return False
        try:
            header = jwt.get_unverified_header(token)
            payload = jwt.decode(token, options={"verify_signature": False})
        except jwt.InvalidTokenError:
            return False
        alg = header.get("alg", "")
        if alg.startswith("RS") or alg.startswith("ES") or alg.startswith("PS"):
            return True
        if alg.startswith("HS") and settings.oidc_client_secret:
            issuer = str(payload.get("iss", ""))
            return not settings.oidc_issuer_url or issuer == settings.oidc_issuer_url
        return False

    def _decode_with_jwks(self, token: str, settings) -> dict[str, Any]:
        signing_key = self._client().get_signing_key_from_jwt(token)
        header = jwt.get_unverified_header(token)
        alg = header.get("alg") or getattr(signing_key, "algorithm_name", "RS256")
        issuer = (settings.oidc_issuer_url or "").rstrip("/")
        return jwt.decode(
            token,
            signing_key.key,
            algorithms=[alg],
            audience=settings.oidc_audience,
            issuer=issuer,
            options={"require": ["exp", "sub"]},
        )

    def _decode_with_client_secret(self, token: str, settings) -> dict[str, Any]:
        if not settings.oidc_client_secret:
            raise APIError(
                code="auth_misconfigured",
                message="OIDC client secret is required for HS256 tokens",
                status_code=500,
            )
        header = jwt.get_unverified_header(token)
        alg = header.get("alg", "HS256")
        return jwt.decode(
            token,
            settings.oidc_client_secret,
            algorithms=[alg],
            audience=settings.oidc_audience,
            issuer=(settings.oidc_issuer_url or "").rstrip("/"),
            options={"require": ["exp", "sub"]},
        )

    def decode_access_token(self, token: str) -> TokenClaims:
        settings = get_settings()
        if not settings.oidc_issuer_url:
            raise APIError(
                code="auth_misconfigured",
                message="OIDC issuer URL is not configured",
                status_code=500,
            )
        try:
            header = jwt.get_unverified_header(token)
            alg = header.get("alg", "")
            if alg.startswith("HS"):
                payload = self._decode_with_client_secret(token, settings)
            else:
                payload = self._decode_with_jwks(token, settings)
        except jwt.ExpiredSignatureError as exc:
            raise APIError(
                code="auth_expired_token",
                message="Access token expired",
                status_code=401,
            ) from exc
        except jwt.InvalidTokenError as exc:
            raise APIError(
                code="auth_invalid_token",
                message="Invalid OIDC access token",
                status_code=401,
            ) from exc

        principal = resolve_principal(payload)
        scopes = principal_scopes(principal)
        if not scopes:
            raise APIError(
                code="auth_user_unknown",
                message="OIDC principal is not mapped to libcloud permissions",
                status_code=403,
                details={"principal": principal, "sub": payload.get("sub")},
            )

        providers = principal_providers(principal)
        issuer = str(payload.get("iss", settings.oidc_issuer_url))
        audit_auth_event(
            event="oidc_token_decoded",
            principal=principal,
            issuer=issuer,
            subject=str(payload.get("sub") or ""),
            email=str(payload.get("email") or ""),
        )

        return TokenClaims(
            sub=principal,
            iss=issuer,
            aud=str(payload.get("aud", settings.oidc_audience)),
            iat=int(payload.get("iat", 0)),
            nbf=int(payload.get("nbf", payload.get("iat", 0))),
            exp=int(payload["exp"]),
            jti=str(payload.get("jti") or payload.get("sid") or principal),
            scope=" ".join(scopes),
            tenant_id=settings.oidc_tenant_id,
            allowed_providers=providers,
            session_id=str(payload.get("sid") or payload.get("jti") or principal),
            access_token=token,
        )


oidc_auth_service = OidcAuthService()
