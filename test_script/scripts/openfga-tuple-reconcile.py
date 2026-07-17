#!/usr/bin/env python3
"""openfga-tuple-reconcile.py — sync LLDAP group memberships into OpenFGA tuples.

Reads LLDAP group memberships (GraphQL) and OpenFGA tuples (REST), then writes
the missing and (in --full mode) deletes the stale "managed" tuples so that
OpenFGA user->role state mirrors LLDAP group membership.

Mapping (LLDAP group -> OpenFGA tuple), overridable via --map-file JSON:
  platform-superadmin                 -> user:<u> superadmin platform:main
  tenant-<cloud>-<owner|admin|viewer> -> user:<u> <role>     tenant:<cloud>

"Managed" tuples (the only ones this tool will create or delete) are user->role
tuples whose relation is in {owner,admin,viewer,superadmin} and whose object is
tenant:* or platform:*. Structural/infra tuples (parent/provider/tenant
relations on backends, provider->provider, tenant->backend) are NEVER touched.

Modes:
  --additive (default)   only write missing tuples; never delete.
  --full                 also delete stale tuples (managed tuples whose user is
                          not in the corresponding LLDAP group). Requires --yes.
  --dry-run              compute and print the plan; make no changes.

Usage:
  python3 scripts/openfga-tuple-reconcile.py [--additive|--full] [--dry-run] [--yes]
          [--map-file PATH] [--actor <user>]

Env (loaded from .env / generated/*.env / ../lldap/.env):
  LLDAP_URL, LLDAP_ADMIN_USER, LLDAP_LDAP_USER_PASS / LLDAP_ADMIN_PASSWORD
  FGA_API_URL, FGA_STORE_ID, FGA_MODEL_ID, FGA_API_TOKEN / SUPERADMIN_JWT
"""
from __future__ import annotations

import argparse
import sys
from collections import defaultdict
from typing import Dict, Set, Tuple

from openfga_pylib import FgaClient, LldapClient  # noqa: F401

import openfga_pylib as lib


def main() -> int:
    ap = argparse.ArgumentParser(description="Reconcile LLDAP groups -> OpenFGA tuples")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--additive", action="store_true", help="only write missing (default)")
    mode.add_argument("--full", action="store_true", help="also delete stale tuples")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--yes", action="store_true", help="confirm destructive --full deletes")
    ap.add_argument("--map-file", help="JSON {group: {relation, object}}")
    ap.add_argument("--actor", default=os.environ.get("LIBCLOUD_USER", "superadmin"))
    args = ap.parse_args()

    lib.bootstrap_env()
    actor = args.actor

    explicit = lib.load_map_file(args.map_file)

    # 1. LLDAP groups -> expected managed tuples.
    lldap = lib.LldapClient()
    groups = lldap.list_groups_with_members()
    expected: Dict[Tuple[str, str, str], str] = {}  # (user,relation,object) -> group
    ignored_groups = []
    for g in groups:
        mapping = lib.group_to_tuple(g["name"], explicit)
        if mapping is None:
            ignored_groups.append(g["name"])
            continue
        rel, obj = mapping
        for member in g["members"]:
            key = (f"user:{member}", rel, obj)
            expected[key] = g["name"]
    print(f"LLDAP: {len(groups)} groups, {len(expected)} expected managed tuples "
          f"({len(ignored_groups)} groups ignored by mapping convention).",
          file=sys.stderr)

    # 2. OpenFGA current managed tuples.
    fga = lib.FgaClient()
    current = fga.read_all_tuples()
    current_managed: Set[Tuple[str, str, str]] = {
        (t["user"], t["relation"], t["object"]) for t in current if lib.is_managed_tuple(t)
    }
    print(f"OpenFGA: {len(current)} total tuples, {len(current_managed)} managed.",
          file=sys.stderr)

    # 3. Diff.
    expected_keys = set(expected.keys())
    missing = sorted(expected_keys - current_managed)
    stale = sorted(current_managed - expected_keys)

    print(f"Plan: {len(missing)} missing (will write), {len(stale)} stale "
          f"(will{' ' if args.full and not args.additive else ' NOT '}delete).",
          file=sys.stderr)
    for k in missing:
        print(f"  + write  {k[0]} {k[1]} {k[2]}   [via group {expected[k]}]", file=sys.stderr)
    if args.full and not args.additive:
        for k in stale:
            print(f"  - delete {k[0]} {k[1]} {k[2]}", file=sys.stderr)

    if args.dry_run:
        lib.audit({"ts": lib.now_iso(), "actor": actor, "action": "reconcile",
                   "result": "dry-run", "missing": len(missing), "stale": len(stale),
                   "mode": "full" if args.full else "additive"})
        return 0

    do_delete = bool(args.full and not args.additive)
    if do_delete and stale and not args.yes:
        print(f"REFUSING to delete {len(stale)} stale tuples without --yes (use --full --yes).",
              file=sys.stderr)
        return 3

    # 4. Apply writes.
    wrote, deleted, errors = 0, 0, 0
    if missing:
        triples = [{"user": u, "relation": r, "object": o} for (u, r, o) in missing]
        try:
            fga.write(triples)
            wrote = len(triples)
            for (u, r, o) in missing:
                lib.audit({"ts": lib.now_iso(), "actor": actor, "action": "reconcile-write",
                           "tuple": {"user": u, "relation": r, "object": o},
                           "source_group": expected[(u, r, o)], "result": "ok"})
        except lib.FgaHttpError as e:
            errors += 1
            print(f"write failed: HTTP {e.status} {e.body}", file=sys.stderr)

    # 5. Apply deletes.
    if do_delete and stale:
        triples = [{"user": u, "relation": r, "object": o} for (u, r, o) in stale]
        try:
            fga.delete(triples)
            deleted = len(triples)
            for (u, r, o) in stale:
                lib.audit({"ts": lib.now_iso(), "actor": actor, "action": "reconcile-delete",
                           "tuple": {"user": u, "relation": r, "object": o}, "result": "ok"})
        except lib.FgaHttpError as e:
            errors += 1
            print(f"delete failed: HTTP {e.status} {e.body}", file=sys.stderr)

    summary = {"wrote": wrote, "deleted": deleted, "missing": len(missing),
               "stale": len(stale), "errors": errors,
               "mode": "full" if do_delete else "additive"}
    lib.audit({"ts": lib.now_iso(), "actor": actor, "action": "reconcile",
               "result": "ok" if errors == 0 else "partial", **summary})
    print(json.dumps(summary), file=sys.stderr)
    return 0 if errors == 0 else 4


if __name__ == "__main__":
    import json  # noqa: E402
    import os    # noqa: E402
    sys.exit(main())
