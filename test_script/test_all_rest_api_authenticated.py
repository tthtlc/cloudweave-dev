#!/usr/bin/env python3
"""Verify that every REST API endpoint in libcloud.rest requires authentication.

What this script checks
-----------------------
For each route registered on the FastAPI app it sends an *unauthenticated*
request (no ``Authorization`` header) and asserts that the response is
``401 Unauthorized``. A second pass sends an *invalid* bearer token and again
expects ``401``. Both together prove the endpoint is gated by the auth layer
and not returning 401 for some unrelated reason (routing, body validation, ...).

A small, explicit allowlist documents the only endpoints that are intentionally
open without authentication (the login / refresh token-grant endpoints, the
public provider catalogue, and the liveness probe). Each allowlisted endpoint is
asserted to *not* return 401, so the allowlist doubles as a tripwire: if one of
them ever accidentally starts requiring auth, or if a brand-new endpoint is
added without auth and is not added to the allowlist, the script fails.

Run it two ways:

    # standalone
    python test_script/test_all_rest_api_authenticated.py

    # via pytest (optional)
    pytest test_script/test_all_rest_api_authenticated.py -q

The script forces ``AUTH_MODE=local`` + OpenFGA disabled so it can exercise the
auth layer end-to-end with no cloud backend, no Dex/OIDC IdP, and no client
credentials -- mirroring ``libcloud.rest/tests/conftest.py``.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path
from typing import Iterable

# --- environment must be pinned BEFORE any app module is imported ------------ #
# (app.config.settings loads .env at import time; app.auth.policy_table builds
# the in-memory policy table at import time.)
os.environ.setdefault("AUTH_MODE", "local")
os.environ.setdefault("FGA_ENABLED", "false")
os.environ.setdefault("ALLOW_CLIENT_CREDENTIALS", "false")

# Make ``app`` importable no matter where the script is invoked from. The app
# also reads several files by relative path (app/auth/policies.json,
# data/users.json, ...), so chdir into libcloud.rest/ -- exactly how the
# existing pytest suite runs -- to keep those resolves working from any cwd.
_LIBCLOUD_REST = Path(__file__).resolve().parent.parent / "libcloud.rest"
if str(_LIBCLOUD_REST) not in sys.path:
    sys.path.insert(0, str(_LIBCLOUD_REST))
os.chdir(_LIBCLOUD_REST)

from fastapi.routing import APIRoute  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app.main import app  # noqa: E402
from app.auth.authorized_route import AuthorizedAPIRoute  # noqa: E402


# --- the only endpoints that are intentionally unauthenticated --------------- #
# (method, path_template) -- path templates match app route templates verbatim.
PUBLIC_ALLOWLIST: set[tuple[str, str]] = {
    ("GET", "/health"),
    ("GET", "/v1/providers"),          # public provider catalogue
    ("POST", "/v1/auth/login"),        # token-grant: password -> access token
    ("POST", "/v1/auth/refresh"),      # token-grant: refresh token -> access token
}

# Garbage bearer token used for the "invalid token is still rejected" pass.
_BAD_TOKEN = "not.a.real.jwt"

# Placeholder substituted for every path parameter when materializing a URL.
_PATH_PARAM_RE = re.compile(r"\{[^}]+\}")


def _enumerate_routes() -> list[tuple[str, str, str]]:
    """Return ``[(method, path_template, route_class_name), ...]`` for every
    business API route on the app (skipping FastAPI's auto-generated doc/openapi
    routes). Handles FastAPI >=0.115 where included routers are wrapped in
    ``_IncludedRouter`` objects whose real routes live on ``original_router``."""
    from fastapi.routing import _IncludedRouter

    out: list[tuple[str, str, str]] = []
    seen: set[tuple[str, str]] = set()

    def _emit(methods: Iterable[str], path: str, cls: str) -> None:
        for method in sorted(methods):
            key = (method, path)
            if key in seen:
                return
            seen.add(key)
            out.append((method, path, cls))

    for route in app.routes:
        # Direct APIRoute on the app (e.g. /health).
        if isinstance(route, APIRoute) and not isinstance(route, _IncludedRouter):
            _emit(route.methods or set(), route.path, type(route).__name__)
            continue
        # Routers included via app.include_router(...).
        if isinstance(route, _IncludedRouter):
            inner = route.original_router
            for sub in inner.routes:
                if isinstance(sub, APIRoute):
                    _emit(sub.methods or set(), sub.path, type(sub).__name__)

    return out


def _materialize(path_template: str) -> str:
    """Replace ``{node_id}`` / ``{name:path}`` style params with a placeholder
    so the URL resolves to the route without a 404."""
    return _PATH_PARAM_RE.sub("test_value", path_template)


def _is_public(method: str, path_template: str) -> bool:
    return (method, path_template) in PUBLIC_ALLOWLIST


def _check_unauthenticated(client: TestClient, method: str, url: str) -> int:
    """No Authorization header at all -> expect 401 on protected routes."""
    return client.request(method, url).status_code


def _check_invalid_token(client: TestClient, method: str, url: str) -> int:
    """A malformed bearer token -> still expect 401 on protected routes."""
    return client.request(
        method, url, headers={"Authorization": f"Bearer {_BAD_TOKEN}"}
    ).status_code


def run() -> tuple[list[str], list[str]]:
    """Run the audit. Returns ``(failures, passes)`` as human-readable lines."""
    client = TestClient(app)
    routes = _enumerate_routes()

    failures: list[str] = []
    passes: list[str] = []

    for method, path_template, cls in routes:
        url = _materialize(path_template)
        public = _is_public(method, path_template)

        no_auth = _check_unauthenticated(client, method, url)
        bad_tok = _check_invalid_token(client, method, url)

        if public:
            # Allowlisted endpoints must NOT be auth-gated. A 401 here would mean
            # we accidentally protected a public endpoint (or the allowlist is
            # stale). 422 (missing body) / 200 are both acceptable.
            if no_auth == 401:
                failures.append(
                    f"PUBLIC  {method:6} {path_template:55} [{cls}] "
                    f"returned 401 without token (expected open)"
                )
            else:
                passes.append(
                    f"PUBLIC  {method:6} {path_template:55} [{cls}] "
                    f"open (no-auth={no_auth})"
                )
            continue

        # Protected endpoint: both probes must yield 401.
        ok = no_auth == 401 and bad_tok == 401
        if ok:
            passes.append(
                f"PROTECT {method:6} {path_template:55} [{cls}] "
                f"401 (no-auth={no_auth}, bad-token={bad_tok})"
            )
        else:
            failures.append(
                f"PROTECT {method:6} {path_template:55} [{cls}] "
                f"FAIL (no-auth={no_auth}, bad-token={bad_tok}) -- expected 401"
            )

    return failures, passes


def _print_report(failures: list[str], passes: list[str]) -> int:
    total = len(failures) + len(passes)
    print(f"\nAuthenticated-endpoint audit: {len(passes)}/{total} passed, "
          f"{len(failures)} failed\n")
    for line in passes:
        print("  PASS  " + line)
    for line in failures:
        print("  FAIL  " + line)
    print()
    if failures:
        print(f"RESULT: FAIL -- {len(failures)} endpoint(s) not correctly auth-gated:")
        for f in failures:
            print("   - " + f)
        return 1
    print(f"RESULT: PASS -- every non-allowlisted endpoint returned 401 without a token.")
    return 0


def main() -> int:
    failures, passes = run()
    return _print_report(failures, passes)


# --- pytest entry point (optional) ------------------------------------------- #
def test_all_endpoints_require_auth() -> None:
    failures, _ = run()
    assert not failures, "Some endpoints are not correctly auth-gated:\n" + "\n".join(failures)


if __name__ == "__main__":
    raise SystemExit(main())
