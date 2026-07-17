#!/usr/bin/env python3
"""Dump the OpenAPI specification of the libcloud REST API (FastAPI app).

Imports `app.main:app` and writes the generated OpenAPI document to
`generated/openapi.json` and `generated/openapi.yaml` (YAML only if PyYAML is
installed). The spec is derived from the live FastAPI app, so it always
matches the current routes, schemas, and security scheme.

Run from the libcloud.rest directory:

    python scripts/generate_openapi.py

Options:
    --json / --no-json   write / skip generated/openapi.json   (default: write)
    --yaml / --no-yaml   write / skip generated/openapi.yaml   (default: write
                         if PyYAML is importable)
    -o, --out-dir DIR    output directory (default: generated)
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.main import app  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", dest="write_json", action="store_true", default=True)
    parser.add_argument("--no-json", dest="write_json", action="store_false")
    parser.add_argument("--yaml", dest="write_yaml", action="store_true", default=True)
    parser.add_argument("--no-yaml", dest="write_yaml", action="store_false")
    parser.add_argument("-o", "--out-dir", default="generated")
    args = parser.parse_args()

    out_dir = (ROOT / args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    spec = app.openapi()

    if args.write_json:
        path = out_dir / "openapi.json"
        path.write_text(json.dumps(spec, indent=2) + "\n")
        print(f"wrote {path.relative_to(ROOT)}")

    if args.write_yaml:
        try:
            import yaml
        except ImportError:
            print("PyYAML not installed; skipping YAML output", file=sys.stderr)
        else:
            path = out_dir / "openapi.yaml"
            path.write_text(yaml.safe_dump(spec, sort_keys=False, allow_unicode=True))
            print(f"wrote {path.relative_to(ROOT)}")

    info = spec.get("info", {})
    print(f"{info.get('title', '?')} v{info.get('version', '?')}: "
          f"{len(spec.get('paths', {}))} paths, "
          f"{len(spec.get('components', {}).get('schemas', {}))} schemas")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
