#!/usr/bin/env python3
"""openfga-tuple-audit.py — dump all OpenFGA tuples + cross-ref LLDAP memberships.

Produces a CSV (one row per tuple) classifying each as:
  infra        structural tuple (parent/provider/tenant relations, provider->provider,
               tenant->backend) — not membership-derived; left alone by the reconciler.
  managed-ok   user->role tuple on tenant:/platform: whose user is in the
               corresponding LLDAP group (per the reconciler mapping).
  orphan       user->role tuple on tenant:/platform: whose user is NOT in the
               corresponding LLDAP group (exists in OpenFGA but not backed by LLDAP).
  unknown      user->role tuple whose object is not tenant:/platform: (unexpected).
Plus one row per "missing" tuple (LLDAP group membership with no OpenFGA tuple).

Also prints a summary to stderr and emits a JSONL audit record.

Usage:
  python3 scripts/openfga-tuple-audit.py [--out PATH] [--stdout] [--map-file PATH]
                                         [--actor <user>]
  --out PATH   write CSV to PATH (default generated/audit/openfga_tuples_<date>.csv)
  --stdout     also print the CSV to stdout
"""
from __future__ import annotations

import argparse
import csv
import datetime
import json
import os
import sys
from pathlib import Path
from typing import Dict, Tuple

import openfga_pylib as lib


def classify(t: dict, expected: Dict[Tuple[str, str, str], str]):
    u, r, o = t.get("user"), t.get("relation"), t.get("object")
    # Structural / infra tuples (not user->role on tenant:/platform:).
    if not (u and u.startswith("user:")):
        return "infra", ""
    if r in ("parent", "provider", "tenant", "allowed"):
        return "infra", ""
    if r in lib.MANAGED_RELATIONS and o and (o.startswith("tenant:") or o.startswith("platform:")):
        key = (u, r, o)
        if key in expected:
            return "managed-ok", expected[key]
        return "orphan", ""
    return "unknown", ""


def main() -> int:
    ap = argparse.ArgumentParser(description="Audit OpenFGA tuples vs LLDAP memberships")
    ap.add_argument("--out", help="CSV output path")
    ap.add_argument("--stdout", action="store_true")
    ap.add_argument("--map-file")
    ap.add_argument("--actor", default=os.environ.get("LIBCLOUD_USER", "superadmin"))
    args = ap.parse_args()

    lib.bootstrap_env()
    explicit = lib.load_map_file(args.map_file)

    fga = lib.FgaClient()
    tuples = fga.read_all_tuples()

    lldap = lib.LldapClient()
    groups = lldap.list_groups_with_members()
    expected: Dict[Tuple[str, str, str], str] = {}
    for g in groups:
        m = lib.group_to_tuple(g["name"], explicit)
        if m is None:
            continue
        rel, obj = m
        for member in g["members"]:
            expected[(f"user:{member}", rel, obj)] = g["name"]

    date_tag = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    out_path = Path(args.out) if args.out else (
        lib.REPO_ROOT / "generated" / "audit" / f"openfga_tuples_{date_tag}.csv")
    out_path.parent.mkdir(parents=True, exist_ok=True)

    rows = []
    counts = {"infra": 0, "managed-ok": 0, "orphan": 0, "unknown": 0, "missing": 0}
    seen = set()
    ts = lib.now_iso()
    for t in tuples:
        cls, group = classify(t, expected)
        counts[cls] = counts.get(cls, 0) + 1
        rows.append([ts, t.get("user"), t.get("relation"), t.get("object"), cls, group, ""])
        seen.add((t.get("user"), t.get("relation"), t.get("object")))
    # missing: expected but not present in OpenFGA.
    for (u, r, o), group in sorted(expected.items()):
        if (u, r, o) not in seen:
            counts["missing"] += 1
            rows.append([ts, u, r, o, "missing", group, "LLDAP membership not in OpenFGA"])

    with out_path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["timestamp", "user", "relation", "object", "classification",
                    "lldap_group", "notes"])
        w.writerows(rows)

    if args.stdout:
        with out_path.open(encoding="utf-8") as fh:
            sys.stdout.write(fh.read())

    summary = {"total": len(tuples), **counts, "out": str(out_path)}
    print(json.dumps(summary), file=sys.stderr)
    lib.audit({"ts": ts, "actor": args.actor, "action": "tuple-audit",
               "result": "written", **summary})
    print(f"audit CSV written: {out_path} ({len(rows)} rows)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
