#!/usr/bin/env python3
"""Extract requestBody required fields + example (if any) per endpoint."""
import json
import sys
import yaml

METHODS = {"get", "post", "put", "patch", "delete"}


def resolve(spec, ref):
    """Resolve a $ref to its schema object."""
    assert ref.startswith("#/")
    node = spec
    for part in ref[2:].split("/"):
        node = node[part]
    return node


def merge(spec, schemas, depth):
    """Merge a list of schemas (allOf) into one effective schema."""
    merged = {"type": "object", "properties": {}, "required": []}
    for s in schemas:
        if "$ref" in s:
            s = resolve(spec, s["$ref"])
        if "allOf" in s:
            s = merge(spec, s["allOf"], depth + 1)
        merged.setdefault("type", s.get("type"))
        for k, v in s.get("properties", {}).items():
            if not v.get("readOnly"):
                merged["properties"][k] = v
        merged["required"] += [r for r in s.get("required", []) if r not in merged["required"]]
    return merged


def skeleton(spec, schema, depth=0):
    """Build a minimal JSON skeleton for a schema."""
    if depth > 6:
        return {}
    if "$ref" in schema:
        return skeleton(spec, resolve(spec, schema["$ref"]), depth + 1)
    if "allOf" in schema:
        m = merge(spec, schema["allOf"], depth)
        for r in schema.get("required", []):
            if r not in m["required"]:
                m["required"].append(r)
        return skeleton(spec, m, depth + 1)
    if "example" in schema:
        return schema["example"]
    if "default" in schema:
        return schema["default"]
    if "enum" in schema and schema["enum"]:
        return schema["enum"][0]
    t = schema.get("type")
    if t == "object":
        props = schema.get("properties", {})
        req = set(schema.get("required", []))
        out = {}
        for name, ps in props.items():
            if name in req and not ps.get("readOnly"):
                out[name] = skeleton(spec, ps, depth + 1)
        return out
    if t == "array":
        return [skeleton(spec, schema.get("items", {}), depth + 1)]
    if t == "string":
        if schema.get("format") == "date-time":
            return "2026-01-01T00:00:00Z"
        if schema.get("format") == "uuid":
            return "00000000-0000-0000-0000-000000000000"
        return "<string>"
    if t == "integer":
        return 0
    if t == "number":
        return 0
    if t == "boolean":
        return True
    if "oneOf" in schema or "anyOf" in schema:
        subs = schema.get("oneOf") or schema.get("anyOf")
        if subs:
            return skeleton(spec, subs[0], depth + 1)
    return None


def main(yaml_path, out_path):
    with open(yaml_path) as f:
        spec = yaml.safe_load(f)
    bodies = {}
    for path, item in (spec.get("paths") or {}).items():
        for method in METHODS:
            op = item.get(method)
            if not op or "requestBody" not in op:
                continue
            key = f"{method.upper()} {path}"
            rb = op["requestBody"]
            content = rb.get("content", {})
            ctype = next(iter(content), "application/json")
            schema = content.get(ctype, {}).get("schema", {})
            bodies[key] = {
                "contentType": ctype,
                "required": bool(rb.get("required", False)),
                "example": skeleton(spec, schema),
            }
    with open(out_path, "w") as f:
        json.dump(bodies, f, indent=2)
    print(f"{yaml_path}: {len(bodies)} request bodies -> {out_path}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
