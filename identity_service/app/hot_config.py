"""Live-reload config from the bind-mounted ``$REPO_ROOT/my.env``.

Unlike :class:`app.config.Settings` (cached at startup via ``@lru_cache``), the
values here are re-read from disk whenever the file changes, so editing
``my.env`` takes effect on the next request with **no container restart**.

The cache is keyed on the file's ``(st_mtime_ns, st_size)`` signature: a cheap
``os.stat`` per read, re-parsing only when the file actually changed.
"""
from __future__ import annotations

import os
import threading

_PATH = os.environ.get("HOT_CONFIG_PATH", "/run/config/my.env")

_lock = threading.Lock()
_state: dict = {"sig": None, "data": {}}


def _parse(path: str) -> dict[str, str]:
    data: dict[str, str] = {}
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            data[key.strip()] = value.strip()
    return data


def read() -> dict[str, str]:
    """Return the current KEY->value mapping, re-parsing only on change."""
    try:
        st = os.stat(_PATH)
        sig = (st.st_mtime_ns, st.st_size)
    except OSError:
        return {}
    if _state["sig"] == sig:
        return _state["data"]
    with _lock:
        if _state["sig"] == sig:
            return _state["data"]
        try:
            _state["data"] = _parse(_PATH)
            _state["sig"] = sig
        except OSError:
            # Keep the last-good value if the file vanished mid-read.
            pass
        return _state["data"]


def get(key: str, default: str | None = None) -> str | None:
    """Return a single value, or ``default`` when unset/absent."""
    return read().get(key, default)
