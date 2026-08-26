
                                                                                                                                                                                                                                                                                                                     
  generate the openapi specification of the current REST API.                                                                                                                                                                                                                                                        
                                                                                                                                                                                                                                                                                                                     

  $ cd /home/ubuntu/libcloud_nutanix/libcloud.rest && ls -la && echo "=== app ===" && ls -la app/ && echo "=== app/api or routes ===" && find app -maxdepth 3 -type d 2>/dev/null 1.1s
    … 77 output lines hidden · ctrl+o to expand
    app/config
    app/config/__pycache__

    Read libcloud.rest/app/main.py

  It's a FastAPI app, so the most accurate OpenAPI spec comes from app.openapi() directly. Let me check the environment and settings dependencies.

  $ cd /home/ubuntu/libcloud_nutanix/libcloud.rest && echo "=== requirements ===" && cat requirements.txt && echo "" && echo "=== venv fastapi? ===" && .venv/bin/python -c "import fastapi, pydantic; print('fastapi', fastapi.__version__); print('pydantic', pydantic.__version__)" 2>&1 | head && echo "" &&
    echo "=== settings.py (top) ===" && sed -n '1,40p' app/config/settings.py 1.3s
    … 52 output lines hidden · ctrl+o to expand
        # cloud backend using its OWN identity (IAM role / service account) and the
        # client must never receive or pass backend credentials. The values below are

  The venv has FastAPI. Let me generate the spec by importing the app and dumping app.openapi().

  $ cd /home/ubuntu/libcloud_nutanix/libcloud.rest && .venv/bin/python -c "
    import json 1.7s
    … 15 input + 48 output lines hidden · ctrl+o to expand
    /v1/admin/policies:reload ['post']
    /health ['get']

  45 paths generated. Let me also produce a YAML version and summarize the schemas/security

  $ cd /home/ubuntu/libcloud_nutanix/libcloud.rest && .venv/bin/python -c "
    import json, sys 539ms
    … 16 input + 14 output lines hidden · ctrl+o to expand
    -rw-rw-r-- 1 ubuntu ubuntu 109657 Jul 15 16:34 generated/openapi.json
    -rw-rw-r-- 1 ubuntu ubuntu  70846 Jul 15 16:34 generated/openapi.yaml

  Both JSON and YAML are generated. Let me add a small reusable generator script so the spec can be regenerated as the API evolves.

  $ cd /home/ubuntu/libcloud_nutanix/libcloud.rest && ls scripts/ 2>&1 258ms
    … 1 output lines hidden · ctrl+o to expand
    validate_policies.py
    validate_vault_chain.py

    Read libcloud.rest/scripts/validate_policies.py

    Edited generate_openapi.py +68

    ▎+ #!/usr/bin/env python3
    ▎+ """Dump the OpenAPI specification of the libcloud REST API (FastAPI app).
    ▎ 
    ▎+ Imports `app.main:app` and writes the generated OpenAPI document to
    ▎+ `generated/openapi.json` and `generated/openapi.yaml` (YAML only if PyYAML is
    ▎+ installed). The spec is derived from the live FastAPI app, so it always
    ▎+ matches the current routes, schemas, and security scheme.
    ▎+ 
    ▎+ Run from the libcloud.rest directory:
    ▎+ 
    ▎+     python scripts/generate_openapi.py
    ▎+ 
    ▎ … truncated (57 more lines) · ctrl+r to review

  $ cd /home/ubuntu/libcloud_nutanix/libcloud.rest && chmod +x scripts/generate_openapi.py && .venv/bin/python scripts/generate_openapi.py 2>&1 | tail -10 && echo "" && echo "=== validate JSON parses ===" && .venv/bin/python -c "import json; json.load(open('generated/openapi.json')); print('openapi.json
    valid')" && echo "=== openapi version ===" && .venv/bin/python -c "import json; print(json.load(open('generated/openapi.json'))['openapi'])" 1.8s
    … 6 output lines hidden · ctrl+o to expand
    === openapi version ===
    3.1.0

  Done. The OpenAPI specification of the current REST API has been generated from the live FastAPI app.

  Output

  • libcloud.rest/generated/openapi.json (109 KB) — OpenAPI 3.1.0, pretty-printed
  • libcloud.rest/generated/openapi.yaml (70 KB) — same spec in YAML
  • libcloud.rest/scripts/generate_openapi.py — reusable generator (re-run as python scripts/generate_openapi.py from libcloud.rest/; supports --no-json / --no-yaml / -o DIR)

  Spec summary

  • Title / version: Libcloud REST API v1.0.0
  • 45 paths, 28 schemas
  • Security scheme: HTTPBearer (bearer token). Note: no global security array — auth is enforced per-route via the AuthorizedAPIRoute dependency, so the bearer requirement is reflected at the operation level, not globally.
  • Routers covered: auth, providers, connections, compute (nodes/volumes/snapshots/images/key-pairs/networks/subnets/storage-containers/security-groups/load-balancers/floating-ips), storage (buckets/objects), jobs, admin, plus /health.

  The spec is derived by importing app.main:app and calling app.openapi(), so it always reflects the current routes/schemas rather than a hand-maintained copy. Both files validate as parseable JSON/YAML. Nothing was committed — the files are ready for review.



