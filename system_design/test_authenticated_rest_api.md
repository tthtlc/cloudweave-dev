
 write a script to test all the REST API in the system to ensure that it must be authenticated. (locate it inside test_script).                                 
                                                                                                                                                                 

  $ ls /home/ubuntu/libcloud_nutanix/ 1.6s
    … 27 output lines hidden · ctrl+o to expand
    todo.md
    vault

  $ ls /home/ubuntu/libcloud_nutanix/test_script/ /home/ubuntu/libcloud_nutanix/libcloud.rest/ 222ms
    … 52 output lines hidden · ctrl+o to expand
    test_scripts_runner.sh
    testing_task.wtd

  $ cat /home/ubuntu/libcloud_nutanix/libcloud.rest/all_rest_api_url.dat | head -50; echo "---TOTAL---"; wc -l
    /home/ubuntu/libcloud_nutanix/libcloud.rest/all_rest_api_url.dat 271ms
    … 42 output lines hidden · ctrl+o to expand
    ---TOTAL---
    42 /home/ubuntu/libcloud_nutanix/libcloud.rest/all_rest_api_url.dat

  $ ls /home/ubuntu/libcloud_nutanix/libcloud.rest/app/ /home/ubuntu/libcloud_nutanix/libcloud.rest/tests/ 266ms
    … 19 output lines hidden · ctrl+o to expand
    test_authorization.py
    test_policy_table.py

    Read libcloud.rest/app/main.py

  $ cd /home/ubuntu/libcloud_nutanix/libcloud.rest && for d in app/auth app/admin app/compute app/connections app/network app/providers app/storage app/jobs; do
    echo "=== $d/routes.py ==="; ls $d/; done 246ms
    … 50 output lines hidden · ctrl+o to expand
    routes.py
    worker.py

    Read 4 files
    Read libcloud.rest/app/auth/dependencies.py
    Read libcloud.rest/app/auth/authorized_route.py
    Read libcloud.rest/tests/conftest.py
    Read libcloud.rest/tests/test_authorization.py

  $ cd /home/ubuntu/libcloud_nutanix/libcloud.rest && grep -rn "make_authorized_router\|APIRouter(\|@router\." app/auth/routes.py app/admin/routes.py
    app/providers/routes.py app/connections/routes.py app/compute/routes.py app/network/routes.py app/storage/routes.py app/jobs/routes.py | head -100 250ms
    … 73 output lines hidden · ctrl+o to expand
    app/jobs/routes.py:8:router = make_authorized_router(prefix="/v1/jobs", tags=["jobs"])
    app/jobs/routes.py:11:@router.get("/{job_id}")

    Read 3 files
    Read libcloud.rest/app/auth/routes.py
    Read libcloud.rest/app/providers/routes.py
    Read libcloud.rest/app/config/settings.py

  $ cd /home/ubuntu/libcloud_nutanix/libcloud.rest && cat requirements.txt 2>/dev/null | head -40; echo "---"; ls -a | grep -i env 301ms
    … 9 output lines hidden · ctrl+o to expand
    .env.example
    .venv

  $ cd /home/ubuntu/libcloud_nutanix/libcloud.rest && ls .venv/bin/ | grep -E "python|pytest|httpx"; echo "---"; .venv/bin/python -c "import fastapi, httpx,
    jwt, pytest; print('ok')" 2>&1 | tail -5 1.5s
    … 5 output lines hidden · ctrl+o to expand
    ---
    ok

    Read libcloud.rest/app/auth/policies.json

  $ cd /home/ubuntu/libcloud_nutanix/libcloud.rest && .venv/bin/python -m pytest tests/test_authorization.py -q 2>&1 | tail -15 2.5s
    … 13 output lines hidden · ctrl+o to expand
    -- Docs: https://docs.pytest.org/en/stable/how-to/capture-warnings.html
    14 passed, 24 warnings in 0.19s

  $ cd /home/ubuntu/libcloud_nutanix/libcloud.rest && AUTH_MODE=local FGA_ENABLED=false ALLOW_CLIENT_CREDENTIALS=false .venv/bin/python -c "
    from fastapi.testclient import TestClient 1.7s
    … 18 input + 9 output lines hidden · ctrl+o to expand
    GET /v1/storage/buckets -> 401 auth_invalid_token
    GET /v1/compute/networks -> 401 auth_invalid_token

  $ cd /home/ubuntu/libcloud_nutanix/libcloud.rest && AUTH_MODE=local FGA_ENABLED=false ALLOW_CLIENT_CREDENTIALS=false .venv/bin/python -c "
    from fastapi.testclient import TestClient 1.8s
    … 8 input + 5 output lines hidden · ctrl+o to expand
    POST /v1/auth/refresh -> 422
    total routes: 5

  $ cd /home/ubuntu/libcloud_nutanix/libcloud.rest && AUTH_MODE=local FGA_ENABLED=false ALLOW_CLIENT_CREDENTIALS=false .venv/bin/python -c "
    from app.main import app 1.4s
    … 6 input lines hidden · ctrl+o to expand
    APIRoute count: 1
    ['GET'] /health

  $ cd /home/ubuntu/libcloud_nutanix/libcloud.rest && AUTH_MODE=local FGA_ENABLED=false ALLOW_CLIENT_CREDENTIALS=false .venv/bin/python -c "
    from app.main import app 1.5s
    … 3 input + 11 output lines hidden · ctrl+o to expand
    _IncludedRouter ? None
    APIRoute /health {'GET'}

  $ cd /home/ubuntu/libcloud_nutanix/libcloud.rest && AUTH_MODE=local FGA_ENABLED=false ALLOW_CLIENT_CREDENTIALS=false .venv/bin/python -c "
    from app.main import app 1.9s
    … 10 input + 3 output lines hidden · ctrl+o to expand
    fastapi ver: 0.137.2
    attrs: ['effective_candidates', 'effective_route_contexts', 'handle', 'include_context', 'matches', 'original_router', 'url_path_for']

  $ cd /home/ubuntu/libcloud_nutanix/libcloud.rest && AUTH_MODE=local FGA_ENABLED=false ALLOW_CLIENT_CREDENTIALS=false .venv/bin/python -c "
    from app.main import app 1.5s
    … 12 input + 61 output lines hidden · ctrl+o to expand
       AuthorizedAPIRoute /v1/jobs/{job_id} ['GET']
       AuthorizedAPIRoute /v1/admin/policies:reload ['POST']

  Now I have a complete picture. Let me create the test script inside test_script/.

    Edited test_all_rest_api_authenticated.py +206

    ▎+ #!/usr/bin/env python3
    ▎+ """Verify that every REST API endpoint in libcloud.rest requires authentication.
    ▎ 
    ▎+ What this script checks
    ▎+ -----------------------
    ▎+ For each route registered on the FastAPI app it sends an *unauthenticated*
    ▎+ request (no ``Authorization`` header) and asserts that the response is
    ▎+ ``401 Unauthorized``. A second pass sends an *invalid* bearer token and again
    ▎+ expects ``401``. Both together prove the endpoint is gated by the auth layer
    ▎+ and not returning 401 for some unrelated reason (routing, body validation, ...).
    ▎+ 
    ▎+ A small, explicit allowlist documents the only endpoints that are intentionally
    ▎ … truncated (195 more lines) · ctrl+r to review

  $ .venv/bin/python ../test_script/test_all_rest_api_authenticated.py 2>&1 | tail -80 1.8s
    … 67 output lines hidden · ctrl+o to expand
    RESULT: PASS -- every non-allowlisted endpoint returned 401 without a token.

  All 62 endpoints pass. Let me verify the pytest entry point works and that the script runs from any cwd (it auto-locates libcloud.rest/).

  $ cd /home/ubuntu/libcloud_nutanix && libcloud.rest/.venv/bin/python test_script/test_all_rest_api_authenticated.py 2>&1 | tail -3; echo "=== pytest ==="; cd
    /home/ubuntu/libcloud_nutanix/libcloud.rest && .venv/bin/python -m pytest /home/ubuntu/libcloud_nutanix/test_script/test_all_rest_api_authenticated.py -q
    2>&1 | tail -5 5.1s
    … 7 output lines hidden · ctrl+o to expand
    -- Docs: https://docs.pytest.org/en/stable/how-to/capture-warnings.html
    1 passed, 2 warnings in 1.96s

  Running from a different cwd fails because the app loads app/auth/policies.json with a relative path. The existing tests avoid this by running from
  libcloud.rest/. I'll make the script chdir into libcloud.rest/ so it works from anywhere.

    Edited test_all_rest_api_authenticated.py +5 -1

    ▎  os.environ.setdefault("FGA_ENABLED", "false")
    ▎  os.environ.setdefault("ALLOW_CLIENT_CREDENTIALS", "false")
    ▎ 
    ▎- # Make ``app`` importable no matter where the script is invoked from.
    ▎+ # Make ``app`` importable no matter where the script is invoked from. The app
    ▎+ # also reads several files by relative path (app/auth/policies.json,
    ▎+ # data/users.json, ...), so chdir into libcloud.rest/ -- exactly how the
    ▎+ # existing pytest suite runs -- to keep those resolves working from any cwd.
    ▎  _LIBCLOUD_REST = Path(__file__).resolve().parent.parent / "libcloud.rest"
    ▎  if str(_LIBCLOUD_REST) not in sys.path:
    ▎      sys.path.insert(0, str(_LIBCLOUD_REST))
    ▎+ os.chdir(_LIBCLOUD_REST)
    ▎ … truncated (3 more lines) · ctrl+r to review

  $ cd /home/ubuntu/libcloud_nutanix && libcloud.rest/.venv/bin/python test_script/test_all_rest_api_authenticated.py 2>&1 | tail -3; echo "exit=$?" 2.1s
    … 2 output lines hidden · ctrl+o to expand
    RESULT: PASS -- every non-allowlisted endpoint returned 401 without a token.
    exit=0

  The script works from any directory. Let me do a final review of the complete file.

    Read test_script/test_all_rest_api_authenticated.py lines 1-40

  I created the audit script at test_script/test_all_rest_api_authenticated.py.

  What it does

  It enumerates every REST route registered on the libcloud.rest FastAPI app (62 endpoints in total — all 8 included routers plus /health), then for each one:

  1. Sends a request with no Authorization header → expects 401.
  2. Sends a request with an invalid bearer token → expects 401 again.

  Both probes must return 401 for a protected endpoint, which proves the 401 is genuinely coming from the auth layer (in AuthorizedAPIRoute / the
  get_current_claims dependency) and not from a routing or body-validation artifact.

  A small explicit PUBLIC_ALLOWLIST documents the only intentionally-open endpoints — GET /health, GET /v1/providers, POST /v1/auth/login, POST 
  /v1/auth/refresh — and asserts each of them does not return 401. This makes the allowlist a tripwire in both directions: a new endpoint added without auth
  fails the audit, and an allowlisted endpoint that accidentally starts requiring auth also fails.

  Key design choices

  • Pins AUTH_MODE=local, FGA_ENABLED=false, ALLOW_CLIENT_CREDENTIALS=false before importing app (mirrors libcloud.rest/tests/conftest.py), so it runs
    end-to-end with no cloud backend / no Dex / no OpenFGA.
  • Auto-discovers routes via FastAPI 0.137's _IncludedRouter.original_router traversal instead of a hardcoded URL list — adding a new endpoint
    automatically includes it in the audit.
  • Substitutes path params ({node_id}, {object_name:path}, …) with a placeholder so templated routes still resolve.
  • chdirs into libcloud.rest/ so the app's relative-path config files (app/auth/policies.json, data/…) load correctly regardless of where it's invoked
    from.
  • Runnable both standalone (python test_script/test_all_rest_api_authenticated.py, exits non-zero on failure) and via pytest
    (test_all_endpoints_require_auth).

  Result

  Authenticated-endpoint audit: 62/62 passed, 0 failed
  RESULT: PASS -- every non-allowlisted endpoint returned 401 without a token.

  Run it with:

  libcloud.rest/.venv/bin/python test_script/test_all_rest_api_authenticated.py

