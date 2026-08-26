#!/usr/bin/env python3
"""Merge per-namespace Nutanix v4 OpenAPI YAML specs into one mock spec.

This is the Python equivalent of `merge-specs.js` (which runs inside a
`node:20-alpine` container). It produces the same shape of document as the
v4.0 spec in `stoplight_mock/spec/openapi.json`:

  * `openapi: 3.0.1`
  * every path is prefixed with `/api` (the YAML specs define paths like
    `/vmm/v4.1/...` while their `servers[0].url` ends in `/api`; Prism matches
    the full request path, so we prepend `/api`).
  * `components.schemas` are merged (schema names are already namespaced as
    `{namespace}.v{version}.content.{Name}`, so there are no collisions).
  * `tags` are merged, deduplicated by name.
  * security / securitySchemes / responses / parameters / requestBodies /
    headers are deliberately skipped so Prism does not enforce auth on the
    mock.

Usage:
    python3 merge_specs.py [v4.1|v4.2|v4.3 ...]
    (no argument merges all three versions)
"""

import json
import sys
from pathlib import Path

import yaml


class _NoTimestampLoader(yaml.SafeLoader):
    """SafeLoader that leaves ISO-8601 dates as strings.

    PyYAML would otherwise parse `example: 2023-01-01T12:00:00Z` into a
    `datetime` object, which is not JSON-serializable. The reference merge
    (`js-yaml`) treats such scalars as plain strings, so we match that here.
    """


_NoTimestampLoader.yaml_implicit_resolvers = {
    key: [
        (tag, regexp)
        for tag, regexp in resolvers
        if tag != "tag:yaml.org,2002:timestamp"
    ]
    for key, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()
}


def load_yaml(path: Path):
    with open(path) as fh:
        return yaml.load(fh, Loader=_NoTimestampLoader)


REPO_ROOT = Path(__file__).resolve().parents[2]
SPEC_DIR = REPO_ROOT / "nutanix_swagger"
OUT_DIR = REPO_ROOT / "stoplight_mock" / "spec"

# Namespaces merged per target version. Each entry must have a stable
# (non-alpha/beta) `v{version}` spec available on the Nutanix OpenAPI portal:
#   https://developers.nutanix.com/api/v1/namespaces/{ns}/versions/v{ver}/yaml
# Namespaces with no stable release for a given version (e.g. iam has only
# v4.1.b* betas, storage has only v4.0.a3, files/aiops/opsmgmt/tenancy have no
# v4.1+ stable spec) are omitted, mirroring how the v4.0 merge only included
# namespaces that actually shipped a spec at that version.
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


def merge_version(version: str) -> dict:
    namespaces = NAMESPACES[version]
    merged = {
        "openapi": "3.0.1",
        "info": {
            "title": f"Nutanix {version} API - Merged Mock Spec",
            "description": (
                f"Merged OpenAPI specification combining all Nutanix {version} "
                f"namespace specs ({', '.join(namespaces)}). Used by Stoplight "
                "Prism for API mocking."
            ),
            "version": version.lstrip("v"),
        },
        "servers": [
            {"url": "http://localhost:4010", "description": "Prism mock server"}
        ],
        "paths": {},
        "components": {"schemas": {}},
        "tags": [],
    }

    known_tags = set()
    for ns in namespaces:
        fname = SPEC_DIR / f"swagger-{ns}-{version}-all.yaml"
        if not fname.exists():
            raise FileNotFoundError(
                f"{fname} is missing — download it from "
                f"https://developers.nutanix.com/api/v1/namespaces/{ns}"
                f"/versions/{version}/yaml"
            )

        content = load_yaml(fname)

        # Merge paths, prefixed with /api.
        for spec_path, item in (content.get("paths") or {}).items():
            merged["paths"]["/api" + spec_path] = item

        # Merge schemas only.
        schemas = ((content.get("components") or {}).get("schemas")) or {}
        merged["components"]["schemas"].update(schemas)

        # Merge tags, deduplicated by name.
        for tag in content.get("tags") or []:
            name = tag.get("name")
            if name and name not in known_tags:
                merged["tags"].append(tag)
                known_tags.add(name)

    return merged


def main() -> int:
    versions = sys.argv[1:] or list(NAMESPACES)
    for version in versions:
        if version not in NAMESPACES:
            print(f"ERROR: unknown version {version!r}", file=sys.stderr)
            return 1

        merged = merge_version(version)
        out_path = OUT_DIR / f"openapi-{version}.json"
        out_path.write_text(json.dumps(merged, indent=2) + "\n")

        size_kb = out_path.stat().st_size / 1024
        print(
            f"{version}: {len(merged['paths'])} paths, "
            f"{len(merged['components']['schemas'])} schemas, "
            f"{len(merged['tags'])} tags -> {out_path.name} ({size_kb:.1f} KB)"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
