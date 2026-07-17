#!/usr/bin/env python3
"""Validate that app/auth/policies.json covers every AuthorizedAPIRoute.

Exits 0 when every authorized route has a table entry (and vice versa), 1
otherwise. Run from the libcloud.rest directory:

    python scripts/validate_policies.py

This mirrors the fail-closed check that AuthorizedAPIRoute.__init__ performs at
import time, but as a standalone CLI it's usable in CI without booting the app.
"""
from __future__ import annotations

import sys
from pathlib import Path

# Make the app package importable when run as a script.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from fastapi.routing import APIRoute  # noqa: E402

from app.auth.authorized_route import AuthorizedAPIRoute  # noqa: E402
from app.auth.policy_table import policy_table  # noqa: E402
import app.compute.routes  # noqa: E402
import app.network.routes  # noqa: E402
import app.storage.routes  # noqa: E402
import app.connections.routes  # noqa: E402
import app.jobs.routes  # noqa: E402
import app.admin.routes  # noqa: E402

_MODULES = [
    app.compute.routes,
    app.network.routes,
    app.storage.routes,
    app.connections.routes,
    app.jobs.routes,
    app.admin.routes,
]


def main() -> int:
    route_keys: set[str] = set()
    for mod in _MODULES:
        for r in mod.router.routes:
            if isinstance(r, AuthorizedAPIRoute):
                for m in sorted(r.methods or []):
                    route_keys.add(f"{m} {r.path}")
    table_keys = set(policy_table.entries().keys())

    missing = sorted(route_keys - table_keys)
    orphan = sorted(table_keys - route_keys)
    print(f"authorized routes: {len(route_keys)}")
    print(f"table entries:     {len(table_keys)}")
    if missing:
        print("ROUTES MISSING FROM TABLE:")
        for k in missing:
            print(f"  - {k}")
    if orphan:
        print("TABLE ENTRIES WITH NO ROUTE:")
        for k in orphan:
            print(f"  - {k}")
    if missing or orphan:
        return 1
    print("OK: full parity")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
