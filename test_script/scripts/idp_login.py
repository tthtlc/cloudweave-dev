#!/usr/bin/env python3
"""Obtain an OIDC access token for libcloud REST provisioning scripts (Dex)."""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.cookiejar import CookieJar
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread

# Dex (default Phase 1 issuer)
DEX_URL = os.environ.get("DEX_URL", "http://localhost:5556").rstrip("/")
DEX_ISSUER = os.environ.get("DEX_ISSUER_URL", f"{DEX_URL}/dex/").rstrip("/")

CLIENT_ID = os.environ.get("LIBCLOUD_OIDC_CLIENT_ID", "libcloud-rest")
CLIENT_SECRET = os.environ.get("LIBCLOUD_OIDC_CLIENT_SECRET", "")
REDIRECT_URI = os.environ.get("LIBCLOUD_OIDC_REDIRECT_URI", "http://127.0.0.1:8766/oauth/callback")
TOKEN_CACHE_DIR = os.environ.get("IDP_TOKEN_CACHE_DIR", "generated/tokens")
VERBOSE = os.environ.get("IDP_LOGIN_VERBOSE", os.environ.get("VERBOSE", "")).lower() in {
    "1",
    "true",
    "yes",
}

# Map script usernames → LLDAP uid (Dex LDAP connector matches `username: uid`).
# Users live in LLDAP (../lldap); Dex authenticates against it over LDAP.
USER_UID = {
    "cloud-admin": "cloud-admin",
    "cloud-readonly": "cloud-readonly",
    "cloud-denied": "cloud-denied",
    # Legacy Phase-1 aliases → stable LLDAP uids.
    "admin": "cloud-admin",
    "provisioner": "cloud-admin",
    "reader": "cloud-readonly",
    "outsider": "cloud-denied",
}


def _verbose(msg: str) -> None:
    if VERBOSE:
        print(msg, file=sys.stderr)


def _redact(text: str) -> str:
    text = re.sub(r"(Authorization: Bearer )\S+", r"\1***REDACTED***", text)
    text = re.sub(r'("password"\s*:\s*")[^"]*', r'\1***REDACTED***', text)
    text = re.sub(r'("access_token"\s*:\s*")[^"]*', r'\1***REDACTED***', text)
    text = re.sub(r"(client_secret=)[^&\s]+", r"\1***REDACTED***", text)
    return text


class _CallbackHandler(BaseHTTPRequestHandler):
    auth_code = ""
    error = ""

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        if "code" in params:
            _CallbackHandler.auth_code = params["code"][0]
            body = b"Authentication complete. You can close this window."
            status = 200
        else:
            _CallbackHandler.error = params.get("error", ["unknown"])[0]
            body = f"Authentication failed: {_CallbackHandler.error}".encode()
            status = 400
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args) -> None:
        return


def _cookie_opener(jar: CookieJar) -> urllib.request.OpenerDirector:
    return urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))


def _login_identity(username: str) -> str:
    return USER_UID.get(username, username)


def _exchange_code(token_url: str, code: str) -> dict:
    payload = urllib.parse.urlencode(
        {
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": REDIRECT_URI,
            "client_id": CLIENT_ID,
            "client_secret": CLIENT_SECRET,
        }
    ).encode()
    req = urllib.request.Request(
        token_url,
        data=payload,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        if exc.code == 401 and "invalid_client" in detail:
            raise RuntimeError(
                "Dex token exchange failed (invalid_client): LIBCLOUD_OIDC_CLIENT_SECRET "
                "does not match dex/config.yaml. Re-run ./setup.sh or restart Dex after "
                "config changes: docker compose restart dex"
            ) from exc
        raise RuntimeError(f"Dex token exchange failed (HTTP {exc.code}): {detail}") from exc


def _refresh(token_url: str, refresh_token: str) -> dict:
    payload = urllib.parse.urlencode(
        {
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_id": CLIENT_ID,
            "client_secret": CLIENT_SECRET,
        }
    ).encode()
    req = urllib.request.Request(
        token_url,
        data=payload,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode() or "{}")


def _cache_path(username: str) -> str:
    os.makedirs(TOKEN_CACHE_DIR, exist_ok=True)
    return os.path.join(TOKEN_CACHE_DIR, f"{username}.json")


def _load_cached(username: str) -> dict | None:
    path = _cache_path(username)
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def _save_cache(username: str, token: dict) -> None:
    with open(_cache_path(username), "w", encoding="utf-8") as fh:
        json.dump(token, fh, indent=2)


def _dex_login_page(opener, authorize_url: str) -> tuple[str, str]:
    _verbose(f">>> GET {authorize_url}")
    # Dex redirects /dex/auth -> /dex/auth/<connector_id> -> /dex/auth/<id>/login
    # (urllib follows the 302s); the final page is the password form whose
    # action posts back to /dex/auth/<id>/login?state=...
    resp = opener.open(urllib.request.Request(authorize_url), timeout=30)
    html = resp.read().decode("utf-8", errors="replace")
    match = re.search(r'action="(/dex/auth/[^"]+)"', html)
    if not match:
        raise RuntimeError(
            "Dex login form not found — is an LDAP/password connector configured?"
        )
    action = match.group(1).replace("&amp;", "&")
    post_url = urllib.parse.urljoin(f"{DEX_URL}/", action.lstrip("/"))
    return post_url, html


def dex_login(username: str, password: str) -> dict:
    login_id = _login_identity(username)
    state = "libcloud-dex"
    _CallbackHandler.auth_code = ""
    _CallbackHandler.error = ""

    server = HTTPServer(("127.0.0.1", urllib.parse.urlparse(REDIRECT_URI).port or 8766), _CallbackHandler)
    thread = Thread(target=server.handle_request, daemon=True)
    thread.start()

    params = urllib.parse.urlencode(
        {
            "client_id": CLIENT_ID,
            "redirect_uri": REDIRECT_URI,
            "response_type": "code",
            "scope": "openid email profile",
            "state": state,
        }
    )
    authorize_url = f"{DEX_URL}/dex/auth?{params}"
    jar = CookieJar()
    opener = _cookie_opener(jar)

    post_url, _html = _dex_login_page(opener, authorize_url)
    form = urllib.parse.urlencode({"login": login_id, "password": password}).encode()
    _verbose(f">>> POST {post_url} (login={login_id})")
    opener.open(
        urllib.request.Request(
            post_url,
            data=form,
            method="POST",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        ),
        timeout=30,
    ).read()

    thread.join(timeout=10)
    server.server_close()

    if _CallbackHandler.error:
        raise RuntimeError(f"OAuth authorize failed: {_CallbackHandler.error}")
    if not _CallbackHandler.auth_code:
        raise RuntimeError("OAuth authorization code was not captured from Dex login")

    token_url = f"{DEX_URL.rstrip('/')}/dex/token"
    return _exchange_code(token_url, _CallbackHandler.auth_code)


def login(username: str, password: str) -> dict:
    cached = _load_cached(username)
    token_url = f"{DEX_URL.rstrip('/')}/dex/token"
    if cached and cached.get("refresh_token"):
        try:
            refreshed = _refresh(token_url, cached["refresh_token"])
            refreshed.setdefault("refresh_token", cached["refresh_token"])
            _save_cache(username, refreshed)
            return refreshed
        except urllib.error.HTTPError as exc:
            if exc.code in {401, 400}:
                _verbose(f"Stale token cache for {username}; performing full login")
                try:
                    os.remove(_cache_path(username))
                except OSError:
                    pass
            else:
                pass

    token = dex_login(username, password)
    _save_cache(username, token)
    return token


def main() -> int:
    username = os.environ.get("LIBCLOUD_USER", "cloud-admin")
    password = os.environ.get("LIBCLOUD_PASSWORD", "")
    if not CLIENT_SECRET:
        print("LIBCLOUD_OIDC_CLIENT_SECRET is required", file=sys.stderr)
        return 1
    if not password:
        print("LIBCLOUD_PASSWORD is required", file=sys.stderr)
        return 1
    try:
        token = login(username, password)
    except Exception as exc:  # noqa: BLE001
        print(f"IdP login failed (dex): {exc}", file=sys.stderr)
        return 1
    print(token["access_token"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
