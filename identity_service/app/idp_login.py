from __future__ import annotations

import logging
import re
import time
from typing import Any
from urllib.parse import parse_qs, urlparse

import httpx
import jwt

from app.config import get_settings
from app.errors import APIError

log = logging.getLogger(__name__)

# Per-cloud token cache: cloud -> {access_token, refresh_token, exp}
_token_cache: dict[str, dict[str, Any]] = {}


def _extract_code(location: str) -> str:
    if not location:
        return ""
    return parse_qs(urlparse(location).query).get("code", [""])[0]


def _parse_token(tok: dict[str, Any]) -> dict[str, Any]:
    access = tok.get("access_token", "")
    exp = int(time.time()) + 3600
    try:
        payload = jwt.decode(access, options={"verify_signature": False})
        exp = int(payload.get("exp", exp))
    except Exception:
        pass
    return {"access_token": access, "refresh_token": tok.get("refresh_token", ""), "exp": exp}


class ProvisionerAuth:
    """Obtain a libcloud-rest-audience OIDC token by performing the Dex LDAP
    login flow (same as test_script/scripts/idp_login.py) — but WITHOUT an
    ephemeral callback server. We POST the login form with redirects disabled
    and extract the authorization code from the 302 Location header. The
    redirect_uri is the already-registered http://127.0.0.1:8766/oauth/callback
    (Dex only validates it against the registered list; it never connects).
    """

    def __init__(self) -> None:
        self._settings = get_settings

    def _provisioner(self, cloud: str) -> tuple[str, str]:
        s = self._settings()
        if cloud == "aws":
            return s.provisioner_aws_user, s.provisioner_aws_password
        return s.provisioner_ntnx_user, s.provisioner_ntnx_password

    def get_token(self, cloud: str) -> str:
        cached = _token_cache.get(cloud)
        now = time.time()
        if cached and cached.get("exp", 0) > now + 30:
            return cached["access_token"]
        if cached and cached.get("refresh_token"):
            try:
                tok = self._refresh(cloud, cached["refresh_token"])
                _token_cache[cloud] = tok
                return tok["access_token"]
            except Exception:
                log.warning("provisioner token refresh failed for %s; full login", cloud)
        tok = self._full_login(cloud)
        _token_cache[cloud] = tok
        return tok["access_token"]

    def get_token_full(self, cloud: str) -> dict[str, Any]:
        """Same as get_token() but returns the full token dict
        ({access_token, refresh_token, exp}) so callers that hand the token to
        external processes (e.g. deprovision_aws.sh's token cache) get the
        refresh_token too."""
        # Ensure the cache is populated/refreshed.
        access = self.get_token(cloud)
        cached = _token_cache.get(cloud, {})
        if not cached.get("access_token"):
            cached = {"access_token": access, "refresh_token": "", "exp": 0}
        return cached

    def _full_login(self, cloud: str) -> dict[str, Any]:
        s = self._settings()
        user, password = self._provisioner(cloud)
        if not user or not password:
            raise APIError("provisioner_unconfigured", f"no provisioner credentials for {cloud}", 500)
        dex = s.dex_url.rstrip("/")
        redirect_uri = s.libcloud_oidc_redirect_uri
        params = {
            "client_id": s.libcloud_oidc_client_id,
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "scope": "openid email profile",
            "state": "libcloud-dex",
            # Select the LDAP connector directly so Dex routes to the password
            # form instead of the connector chooser (the libcloud-rest client
            # also has google/github connectors for the portal).
            "connector_id": s.provisioner_connector_id,
        }
        try:
            with httpx.Client(timeout=30, follow_redirects=True) as client:
                # 1. GET authorize -> follow redirects to the LDAP login form.
                r = client.get(f"{dex}/dex/auth", params=params)
                if r.status_code != 200:
                    raise APIError("idp_login_form", "Dex login form not reached", 502, {"status": r.status_code})
                m = re.search(r'action="(/dex/auth/[^"]+)"', r.text)
                if not m:
                    raise APIError("idp_login_form", "Dex login form action not found", 502)
                post_url = dex + m.group(1).replace("&amp;", "&")
                # 2. POST credentials; do NOT follow the 302 so we can read the code.
                r = client.post(post_url, data={"login": user, "password": password}, follow_redirects=False)
                if r.status_code not in (302, 303):
                    raise APIError("idp_login_failed", "Dex rejected provisioner credentials", 401, {"status": r.status_code})
                code = _extract_code(r.headers.get("location", ""))
                if not code:
                    raise APIError("idp_login_failed", "no authorization code in callback", 401, {"location": r.headers.get("location", "")})
                # 3. Exchange code for tokens (client libcloud-rest + secret).
                tr = client.post(f"{dex}/dex/token", data={
                    "grant_type": "authorization_code",
                    "code": code,
                    "redirect_uri": redirect_uri,
                    "client_id": s.libcloud_oidc_client_id,
                    "client_secret": s.libcloud_oidc_client_secret,
                })
                if tr.status_code != 200:
                    raise APIError("idp_token_exchange", "Dex token exchange failed", 502, {"status": tr.status_code, "body": tr.text})
                return _parse_token(tr.json())
        except httpx.HTTPError as exc:
            raise APIError("idp_unreachable", "Dex unreachable for provisioner login", 503) from exc

    def _refresh(self, cloud: str, refresh_token: str) -> dict[str, Any]:
        s = self._settings()
        dex = s.dex_url.rstrip("/")
        with httpx.Client(timeout=30) as client:
            r = client.post(f"{dex}/dex/token", data={
                "grant_type": "refresh_token",
                "refresh_token": refresh_token,
                "client_id": s.libcloud_oidc_client_id,
                "client_secret": s.libcloud_oidc_client_secret,
            })
            if r.status_code != 200:
                raise APIError("idp_refresh_failed", "token refresh failed", 401, {"status": r.status_code})
            tok = _parse_token(r.json())
            tok.setdefault("refresh_token", refresh_token)
            return tok
