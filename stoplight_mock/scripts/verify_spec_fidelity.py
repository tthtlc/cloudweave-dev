#!/usr/bin/env python3
"""Detect discrepancies between the committed mock specs and their source YAML.

The `stoplight_mock/spec/openapi-v4.{1,2,3}.json` files are *derived* from the
per-namespace Nutanix OpenAPI YAML files in `nutanix_swagger/` via
`merge_specs.py`. This script re-runs that merge in-memory (without writing) and
diffs the result against the committed JSON, so drift in the mock surface is
caught at the source level rather than discovered at runtime.

Checks performed, per version:
  1. path keys           — symmetric diff (missing from / extra in committed spec)
  2. component schemas   — symmetric diff of schema names
  3. per-path operations — which HTTP methods differ, and a deep diff of each
                           shared operation object
  4. per-schema body     — deep diff of each shared schema object

Deliberately NOT compared: components.{security,securitySchemes,responses,
parameters,requestBodies,headers} — merge_specs.py intentionally drops them so
Prism does not enforce auth on the mock. Only `paths`, `components.schemas`,
and `tags` are meant to be carried over.

Usage:
    python3 verify_spec_fidelity.py [v4.1|v4.2|v4.3 ...] [--max N]
    (no argument checks all three versions)
"""

import argparse
import json
import sys
from pathlib import Path

import yaml


class _NoTimestampLoader(yaml.SafeLoader):
    """Leave ISO-8601 dates as strings (matches merge_specs.py)."""


_NoTimestampLoader.yaml_implicit_resolvers = {
    key: [
        (tag, regexp)
        for tag, regexp in resolvers
        if tag != "tag:yaml.org,2002:timestamp"
    ]
    for key, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()
}


REPO_ROOT = Path(__file__).resolve().parents[2]
SPEC_DIR = REPO_ROOT / "nutanix_swagger"
OUT_DIR = REPO_ROOT / "stoplight_mock" / "spec"

NAMESPACES = {
    "v4.1": [
        "clustermgmt", "datapolicies", "dataprotection", "licensing",
        "lifecycle", "microseg", "monitoring", "networking", "objects",
        "prism", "security", "vmm", "volumes",
    ],
    "v4.2": [
        "clustermgmt", "datapolicies", "dataprotection", "licensing",
        "lifecycle", "microseg", "monitoring", "multidomain", "networking",
        "prism", "vmm", "volumes",
    ],
    "v4.3": [
        "clustermgmt", "datapolicies", "dataprotection", "licensing",
        "lifecycle", "microseg", "monitoring", "multidomain", "networking",
        "prism", "vmm", "volumes",
    ],
}


def load_yaml(path: Path):
    with open(path) as fh:
        return yaml.load(fh, Loader=_NoTimestampLoader)


def rebuild_merged(version: str) -> dict:
    """Re-run the merge_specs.py logic in memory and return the merged doc."""
    merged = {"paths": {}, "components": {"schemas": {}}, "tags": []}
    known_tags = set()
    for ns in NAMESPACES[version]:
        fname = SPEC_DIR / f"swagger-{ns}-{version}-all.yaml"
        if not fname.exists():
            raise FileNotFoundError(fname)
        content = load_yaml(fname)
        for spec_path, item in (content.get("paths") or {}).items():
            merged["paths"]["/api" + spec_path] = item
        schemas = ((content.get("components") or {}).get("schemas")) or {}
        merged["components"]["schemas"].update(schemas)
        for tag in content.get("tags") or []:
            name = tag.get("name")
            if name and name not in known_tags:
                merged["tags"].append(tag)
                known_tags.add(name)
    return merged


def diff_paths(expect: dict, actual: dict, max_n: int):
    exp_paths, act_paths = set(expect["paths"]), set(actual.get("paths") or {})
    missing = sorted(exp_paths - act_paths)          # in source, missing from committed
    extra = sorted(act_paths - exp_paths)            # in committed, not in source
    changed = []                                     # same path, different operations
    for p in sorted(exp_paths & act_paths):
        e, a = expect["paths"][p], actual["paths"][p]
        if e != a:
            changed.append((p, sorted(set(e) - set(a)), sorted(set(a) - set(e))))
    print(f"  paths: expect={len(exp_paths)} committed={len(act_paths)} "
          f"missing={len(missing)} extra={len(extra)} changed={len(changed)}")
    for p in missing[:max_n]:
        print(f"    MISSING path: {p}")
    for p in extra[:max_n]:
        print(f"    EXTRA   path: {p}")
    for p, removed_methods, added_methods in changed[:max_n]:
        print(f"    CHANGED path: {p} (methods removed={removed_methods} added={added_methods})")
    return len(missing) or len(extra) or len(changed)


def diff_schemas(expect: dict, actual: dict, max_n: int):
    exp_s = set(expect["components"]["schemas"])
    act_s = set((actual.get("components") or {}).get("schemas") or {})
    missing = sorted(exp_s - act_s)
    extra = sorted(act_s - exp_s)
    changed = []
    for name in sorted(exp_s & act_s):
        e = expect["components"]["schemas"][name]
        a = actual["components"]["schemas"][name]
        if e != a:
            changed.append(name)
    print(f"  schemas: expect={len(exp_s)} committed={len(act_s)} "
          f"missing={len(missing)} extra={len(extra)} changed={len(changed)}")
    for name in missing[:max_n]:
        print(f"    MISSING schema: {name}")
    for name in extra[:max_n]:
        print(f"    EXTRA   schema: {name}")
    for name in changed[:max_n]:
        print(f"    CHANGED schema: {name}")
    return len(missing) or len(extra) or len(changed)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("versions", nargs="*", default=list(NAMESPACES))
    ap.add_argument("--max", type=int, default=20, help="max diffs printed per class")
    args = ap.parse_args()

    rc = 0
    for version in args.versions:
        if version not in NAMESPACES:
            print(f"ERROR: unknown version {version!r}", file=sys.stderr)
            return 1

        out_path = OUT_DIR / f"openapi-{version}.json"
        if not out_path.exists():
            print(f"{version}: committed spec {out_path.name} NOT FOUND", file=sys.stderr)
            rc = 1
            continue

        print(f"\n=== {version} -> {out_path.name} ===")
        expect = rebuild_merged(version)
        actual = json.loads(out_path.read_text())

        rc |= diff_paths(expect, actual, args.max)
        rc |= diff_schemas(expect, actual, args.max)

    print("\n" + ("DRIFT DETECTED" if rc else "OK: committed specs match source YAML"))
    return 1 if rc else 0


if __name__ == "__main__":
    sys.exit(main())
