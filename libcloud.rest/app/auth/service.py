import json
import secrets
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import jwt
from passlib.context import CryptContext

from app.auth.models import LoginRequest, TokenClaims, TokenResponse, UserRecord
from app.common.errors import APIError
from app.config.settings import get_settings

_pwd_context = CryptContext(schemes=["argon2"], deprecated="auto")


class AuthService:
    def __init__(self) -> None:
        self._users: dict[str, UserRecord] = {}
        self._refresh_tokens: dict[str, dict] = {}
        self._revoked_jtis: set[str] = set()
        self._audit_log: list[dict] = []
        self._bootstrap_users()

    def _users_path(self) -> Path:
        return Path(get_settings().users_file)

    def _bootstrap_users(self) -> None:
        # No static/admin user is ever auto-created. User identities come from
        # the OIDC IdP (Dex → LLDAP). This optional file is only consulted in
        # local/hybrid auth_mode for deployments that manage their own users.
        path = self._users_path()
        if not path.exists():
            return
        with path.open() as fh:
            for item in json.load(fh):
                user = UserRecord.model_validate(item)
                if not user.allowed_providers:
                    user = user.model_copy(update={"allowed_providers": ["*"]})
                self._users[user.username] = user

    def _persist_users(self) -> None:
        path = self._users_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w") as fh:
            json.dump([u.model_dump() for u in self._users.values()], fh, indent=2)

    def verify_password(self, plain: str, hashed: str) -> bool:
        return _pwd_context.verify(plain, hashed)

    def _audit(self, event: str, **kwargs) -> None:
        self._audit_log.append(
            {
                "event": event,
                "timestamp": datetime.now(timezone.utc).isoformat(),
                **kwargs,
            }
        )

    def login(self, request: LoginRequest) -> TokenResponse:
        user = self._users.get(request.username)
        if not user or not self.verify_password(request.password, user.password_hash):
            self._audit("login_failed", username=request.username)
            raise APIError(
                code="auth_invalid_credentials",
                message="Invalid username or password",
                status_code=401,
            )

        requested = request.requested_scopes or user.scopes
        granted_scopes = sorted(set(requested) & set(user.scopes))
        if not granted_scopes:
            raise APIError(
                code="auth_insufficient_scope",
                message="No requested scopes are permitted for this user",
                status_code=403,
            )

        allowed_providers = user.allowed_providers or ["*"]

        settings = get_settings()
        now = int(time.time())
        session_id = f"sess_{uuid.uuid4().hex[:16]}"
        jti = f"jti_{uuid.uuid4().hex[:16]}"
        claims = TokenClaims(
            sub=user.username,
            iss=settings.api_issuer,
            aud=settings.api_audience,
            iat=now,
            nbf=now,
            exp=now + settings.access_token_ttl_seconds,
            jti=jti,
            scope=" ".join(granted_scopes),
            tenant_id=user.tenant_id,
            allowed_providers=allowed_providers,
            session_id=session_id,
        )
        access_token = jwt.encode(
            claims.model_dump(),
            settings.jwt_signing_key,
            algorithm=settings.jwt_algorithm,
        )

        refresh_token = f"rft_{secrets.token_urlsafe(32)}"
        self._refresh_tokens[refresh_token] = {
            "username": user.username,
            "session_id": session_id,
            "scopes": granted_scopes,
            "allowed_providers": allowed_providers,
            "expires_at": now + settings.refresh_token_ttl_seconds,
        }
        self._audit("login_success", username=user.username, session_id=session_id, jti=jti)

        return TokenResponse(
            access_token=access_token,
            expires_in=settings.access_token_ttl_seconds,
            refresh_token=refresh_token,
            scope=claims.scope,
        )

    def refresh(self, refresh_token: str) -> TokenResponse:
        record = self._refresh_tokens.get(refresh_token)
        if not record:
            raise APIError(code="auth_invalid_token", message="Invalid refresh token", status_code=401)
        now = int(time.time())
        if record["expires_at"] < now:
            del self._refresh_tokens[refresh_token]
            raise APIError(code="auth_expired_token", message="Refresh token expired", status_code=401)

        settings = get_settings()
        jti = f"jti_{uuid.uuid4().hex[:16]}"
        claims = TokenClaims(
            sub=record["username"],
            iss=settings.api_issuer,
            aud=settings.api_audience,
            iat=now,
            nbf=now,
            exp=now + settings.access_token_ttl_seconds,
            jti=jti,
            scope=" ".join(record["scopes"]),
            tenant_id=self._users[record["username"]].tenant_id,
            allowed_providers=record["allowed_providers"],
            session_id=record["session_id"],
        )
        access_token = jwt.encode(
            claims.model_dump(),
            settings.jwt_signing_key,
            algorithm=settings.jwt_algorithm,
        )
        self._audit("token_refresh", username=record["username"], jti=jti)
        return TokenResponse(
            access_token=access_token,
            expires_in=settings.access_token_ttl_seconds,
            refresh_token=refresh_token,
            scope=claims.scope,
        )

    def logout(self, refresh_token: str | None, jti: str | None) -> None:
        if refresh_token and refresh_token in self._refresh_tokens:
            del self._refresh_tokens[refresh_token]
        if jti:
            self._revoked_jtis.add(jti)
            self._audit("logout", jti=jti)

    def decode_access_token(self, token: str) -> TokenClaims:
        settings = get_settings()
        try:
            payload = jwt.decode(
                token,
                settings.jwt_signing_key,
                algorithms=[settings.jwt_algorithm],
                audience=settings.api_audience,
                issuer=settings.api_issuer,
            )
        except jwt.ExpiredSignatureError as exc:
            raise APIError(code="auth_expired_token", message="Access token expired", status_code=401) from exc
        except jwt.InvalidTokenError as exc:
            raise APIError(code="auth_invalid_token", message="Invalid access token", status_code=401) from exc

        claims = TokenClaims.model_validate(payload)
        if claims.jti in self._revoked_jtis:
            raise APIError(code="auth_invalid_token", message="Token has been revoked", status_code=401)
        claims.access_token = token
        return claims

    def introspect(self, token: str) -> dict:
        claims = self.decode_access_token(token)
        return {
            "active": True,
            "sub": claims.sub,
            "scope": claims.scope,
            "tenant_id": claims.tenant_id,
            "allowed_providers": claims.allowed_providers,
            "exp": claims.exp,
            "jti": claims.jti,
        }


auth_service = AuthService()
