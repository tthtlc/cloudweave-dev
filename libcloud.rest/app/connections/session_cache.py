"""In-memory Prism Central session-cookie cache.

The Nutanix driver authenticates with HTTP Basic auth once (against its
``login_path``) and receives a session cookie in return. We cache that cookie,
keyed by the connection target (``nutanix:<host>:<port>``), so subsequent
requests can replay the cookie instead of re-fetching the backend credential
from Vault and re-authenticating on every call.

This is a per-process cache: with multiple API workers each worker performs its
own first login and caches its own session, which is fine since a session
cookie is a bearer credential scoped to whatever issued it, not to a specific
client. Stale cookies are dropped after ``ttl`` seconds (and a 401 from the
backend on a later request simply surfaces to the caller; the next request will
re-authenticate).
"""
from __future__ import annotations

import threading
import time

# Default lifetime of a cached session cookie. Prism Central sessions are
# long-lived; this TTL is deliberately conservative so a revoked/expired cookie
# cannot be replayed indefinitely.
DEFAULT_TTL_SECONDS = 3600.0

# target -> (cookie, expires_at_epoch)
_cache: dict[str, tuple[str, float]] = {}
_lock = threading.Lock()


def get_session_cookie(target: str) -> str | None:
    """Return a cached (and unexpired) session cookie for ``target``, if any."""
    with _lock:
        entry = _cache.get(target)
        if entry is None:
            return None
        cookie, expires_at = entry
        if time.time() >= expires_at:
            _cache.pop(target, None)
            return None
        return cookie


def put_session_cookie(target: str, cookie: str, ttl: float = DEFAULT_TTL_SECONDS) -> None:
    """Cache a session cookie for ``target``."""
    with _lock:
        _cache[target] = (cookie, time.time() + ttl)


def clear_session_cookie(target: str) -> None:
    """Drop a cached session cookie (e.g. after an auth failure)."""
    with _lock:
        _cache.pop(target, None)


def clear_all() -> None:
    """Drop every cached session cookie."""
    with _lock:
        _cache.clear()
