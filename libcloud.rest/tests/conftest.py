"""Test configuration: force local auth + OpenFGA disabled so authorization can
be exercised end-to-end without a cloud backend or an OIDC IdP.

Environment must be set BEFORE any app module is imported, because
``app.config.settings`` loads ``.env`` and ``app.auth.policy_table`` builds the
in-memory policy table at import time.
"""

import os

# 1) local JWT auth (no Dex/OIDC), 2) OpenFGA skipped, 3) no client credentials.
os.environ["AUTH_MODE"] = "local"
os.environ["FGA_ENABLED"] = "false"
os.environ["ALLOW_CLIENT_CREDENTIALS"] = "false"

import time
import uuid

import jwt
import pytest
from fastapi.testclient import TestClient

from app.auth.models import TokenClaims
from app.config.settings import get_settings
from app.main import app


@pytest.fixture
def mint_token():
    """Return a callable that mints a locally-valid JWT with the given scopes."""
    def _mint(scopes: list[str], *, allowed_providers: list[str] | None = None) -> str:
        settings = get_settings()
        now = int(time.time())
        claims = TokenClaims(
            sub="tester",
            iss=settings.api_issuer,
            aud=settings.api_audience,
            iat=now,
            nbf=now,
            exp=now + 3600,
            jti=f"jti_{uuid.uuid4().hex[:16]}",
            scope=" ".join(scopes),
            tenant_id="default",
            allowed_providers=allowed_providers or ["*"],
            session_id=f"sess_{uuid.uuid4().hex[:16]}",
        )
        return jwt.encode(claims.model_dump(), settings.jwt_signing_key, algorithm=settings.jwt_algorithm)
    return _mint


@pytest.fixture
def client():
    return TestClient(app)


@pytest.fixture
def connection_header():
    """A minimal valid X-Provider-Connection header value (no credentials)."""
    return '{"provider": "aws", "auth_binding": "aws", "config": {"region": "us-east-1"}}'


@pytest.fixture
def auth_headers():
    """Return a function building Authorization + extra headers for a token."""
    def _make(token: str, connection: str | None = None):
        headers = {"Authorization": f"Bearer {token}"}
        if connection is not None:
            headers["X-Provider-Connection"] = connection
        return headers
    return _make
