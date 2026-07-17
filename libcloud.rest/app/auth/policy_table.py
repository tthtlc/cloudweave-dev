"""External, hot-reloadable authorization policy table.

The table maps a route key ``"METHOD path_template"`` (e.g.
``"GET /v1/compute/locations"``) to a policy entry::

    {
      "scopes_any_of": ["compute:location:read", "compute:read"],
      "capability": null,                  # optional driver capability
      "connection_required": true          # default true; false for connection-less routes
    }

The table is loaded into memory at startup and reloaded automatically when the
underlying file changes (cheap mtime check on every lookup) or on demand via
``POST /v1/admin/policies:reload``. Editing ``policies.json`` therefore changes
authorization enforcement with NO source-code changes and NO restart.

Route handlers never read this table directly; ``AuthorizedAPIRoute`` in
``app/auth/authorized_route.py`` is the only consumer.
"""

from __future__ import annotations

import json
import os
import threading
from typing import Any

from app.common.errors import APIError
from app.config.settings import get_settings

REQUIRED_FIELDS = ("scopes_any_of",)


class PolicyTable:
    def __init__(self, path: str) -> None:
        self._path = path
        self._lock = threading.RLock()
        self._entries: dict[str, dict[str, Any]] = {}
        self._mtime: float = 0.0
        self.load()

    def load(self) -> dict[str, dict[str, Any]]:
        """Read the JSON file from disk and swap the in-memory dict."""
        try:
            st = os.stat(self._path)
        except OSError as exc:
            raise APIError(
                code="policy_table_unreadable",
                message=f"Policy table file not readable: {self._path}",
                status_code=500,
                details={"path": self._path, "error": str(exc)},
            ) from exc

        with open(self._path, "r", encoding="utf-8") as fh:
            raw = json.load(fh)

        if not isinstance(raw, dict):
            raise APIError(
                code="policy_table_invalid",
                message="Policy table root must be a JSON object keyed by 'METHOD path'",
                status_code=500,
            )

        normalized: dict[str, dict[str, Any]] = {}
        for key, entry in raw.items():
            # Allow documentation/metadata keys (e.g. "_comment") that are not
            # route entries. Any key starting with "_" is ignored.
            if key.startswith("_"):
                continue
            if not isinstance(entry, dict):
                raise APIError(
                    code="policy_table_invalid",
                    message=f"Policy entry for {key!r} must be an object",
                    status_code=500,
                    details={"key": key},
                )
            for field in REQUIRED_FIELDS:
                if field not in entry:
                    raise APIError(
                        code="policy_table_invalid",
                        message=f"Policy entry for {key!r} missing required field: {field}",
                        status_code=500,
                        details={"key": key, "field": field},
                    )
            if not isinstance(entry["scopes_any_of"], list) or not entry["scopes_any_of"]:
                raise APIError(
                    code="policy_table_invalid",
                    message=f"Policy entry for {key!r} must have a non-empty scopes_any_of list",
                    status_code=500,
                    details={"key": key},
                )
            entry.setdefault("capability", None)
            entry.setdefault("connection_required", True)
            normalized[key] = entry

        with self._lock:
            self._entries = normalized
            self._mtime = st.st_mtime
        return normalized

    def _maybe_reload(self) -> None:
        """Re-read the file if its mtime changed. Cheap stat; no-op if unchanged."""
        try:
            st = os.stat(self._path)
        except OSError:
            return
        if st.st_mtime != self._mtime:
            self.load()

    def get(self, key: str) -> dict[str, Any]:
        """Look up a policy entry by 'METHOD path_template'.

        Raises ``policy_unknown_operation`` (500, fail-closed) if the route is not
        declared in the table so a missing entry can never silently allow access.
        """
        self._maybe_reload()
        with self._lock:
            entry = self._entries.get(key)
        if entry is None:
            raise APIError(
                code="policy_unknown_operation",
                message=f"No policy entry for route; refusing to authorize: {key}",
                status_code=500,
                details={"key": key},
            )
        return entry

    def reload(self) -> dict[str, dict[str, Any]]:
        """Force a re-read (used by the admin reload endpoint)."""
        return self.load()

    def entries(self) -> dict[str, dict[str, Any]]:
        """Return a snapshot of all entries (for startup validation / admin listing)."""
        self._maybe_reload()
        with self._lock:
            return dict(self._entries)


policy_table = PolicyTable(get_settings().policy_table_file)
