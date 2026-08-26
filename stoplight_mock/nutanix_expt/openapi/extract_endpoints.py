#!/usr/bin/env python3
"""Extract all endpoints (path, method, operationId, summary, security, tags, params)
from the Nutanix IAM swagger YAMLs into JSON for script generation."""
import json
import sys
import yaml

METHODS = {"get", "post", "put", "patch", "delete", "head", "options"}


def param_spec(p):
    return {
        "name": p.get("name"),
        "in": p.get("in"),
        "required": bool(p.get("required", False)),
        "type": (p.get("schema") or {}).get("type"),
    }


def main(yaml_path, json_path):
    with open(yaml_path) as f:
        spec = yaml.safe_load(f)

    out = {
        "title": spec["info"]["title"],
        "version": spec["info"]["version"],
        "servers": spec.get("servers", []),
        "security": spec.get("security", []),
        "endpoints": [],
    }
    for path, item in (spec.get("paths") or {}).items():
        for method in METHODS:
            op = item.get(method)
            if op is None:
                continue
            out["endpoints"].append(
                {
                    "path": path,
                    "method": method.upper(),
                    "operationId": op.get("operationId"),
                    "summary": (op.get("summary") or "").replace("\n", " ").strip(),
                    "tags": op.get("tags", []),
                    "security": op.get("security"),
                    "parameters": [param_spec(p) for p in op.get("parameters", [])],
                    "requestBody": bool(op.get("requestBody")),
                }
            )
    out["endpoints"].sort(key=lambda e: (e["path"], e["method"]))
    with open(json_path, "w") as f:
        json.dump(out, f, indent=2)
    print(f"{yaml_path}: {len(out['endpoints'])} endpoints -> {json_path}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
