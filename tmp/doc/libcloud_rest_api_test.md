# Libcloud REST API Test

**Script:** `libcloud.rest/scripts/rest-api-test.sh`
**Target:** `libcloud-rest-api` container on `http://localhost:8765`

## Usage

```bash
# Basic (public + auth-rejection tests only):
./libcloud.rest/scripts/rest-api-test.sh

# Custom host/port:
./libcloud.rest/scripts/rest-api-test.sh http://192.168.1.50:8765

# With authenticated endpoint tests:
BEARER_TOKEN="eyJ..." ./libcloud.rest/scripts/rest-api-test.sh

# When OIDC-only (login is 404 by design):
SKIP_LOGIN_TEST=1 ./libcloud.rest/scripts/rest-api-test.sh
```

## Test sections

| # | Section | What it tests |
|---|---------|---------------|
| 0 | **Container** | `docker ps` confirms `libcloud-rest-api` is running |
| 1 | **Public endpoints** | `/health` returns 200 with `"status"`/`"ok"`; `/v1/providers` returns 200 with `"data"`, `"ec2"`, and `"nutanix"` |
| 2 | **Auth enforcement** | All 13 authorized routes (`/v1/compute/*`, `/v1/storage/*`, `/v1/connections:test`) reject unauthenticated requests with 401 |
| 3 | **Token validation** | `/v1/auth/me` returns 401 for no token and bogus Bearer token |
| 4 | **Login** | `/v1/auth/login` rejects empty body (422 in local mode, 404 in OIDC mode); respects `SKIP_LOGIN_TEST=1` |
| 5 | **Authenticated** | When `BEARER_TOKEN` is set: tests `/v1/auth/me`, logout, and list endpoints (nodes/images/sizes/locations), plus connection test with `X-Provider-Connection` header |
| 6 | **Response format** | `Content-Type: application/json` and valid JSON on health + providers |
| 7 | **Error handling** | Unknown paths → 404 with `"detail"`; `POST /health` → 405 |
| 8 | **Request validation** | POST to authorized route without Content-Type → 422/401 |
| 9 | **Summary** | Pass/fail counts; exits with failure count (exit 0 = all pass) |

## API surface covered

### Public (no auth)

| Method | Path | Expected |
|--------|------|----------|
| GET | `/health` | 200 `{"status":"ok"}` |
| GET | `/v1/providers` | 200, `"data"` array with AWS + Nutanix entries |

### Auth endpoints

| Method | Path | Auth | Notes |
|--------|------|------|-------|
| POST | `/v1/auth/login` | No | 422 (local mode) / 404 (OIDC mode) |
| POST | `/v1/auth/refresh` | No | 422 without body |
| POST | `/v1/auth/logout` | Bearer | 200 with valid token |
| GET | `/v1/auth/me` | Bearer | 200 with user claims, 401 without |
| POST | `/v1/auth/token/introspect` | Bearer + admin scope | Not tested (requires admin) |

### Authorized (Bearer + X-Provider-Connection)

**Compute** (`/v1/compute`):

| Method | Path | Notes |
|--------|------|-------|
| GET | `/nodes`, `/nodes/{id}` | List / get nodes |
| POST | `/nodes` | Create node (can be async) |
| PATCH | `/nodes/{id}` | Update / resize / tag |
| DELETE | `/nodes/{id}` | Destroy node |
| POST | `/nodes/{id}:start`, `:stop`, `:reboot` | Power actions |
| GET | `/images` | List images (AWS filter support) |
| POST | `/images` | Create image from URL or VM |
| DELETE | `/images/{id}` | Delete image |
| GET | `/sizes` | List instance sizes |
| GET | `/locations` | List regions / clusters |
| GET | `/volumes` | List volumes |
| POST | `/volumes` | Create volume |
| PATCH | `/volumes/{id}` | Modify / tag volume |
| DELETE | `/volumes/{id}` | Delete volume |
| POST | `/volumes/{id}:attach`, `:detach` | Attach/detach |
| GET | `/snapshots` | List snapshots |
| POST | `/snapshots` | Create snapshot |
| DELETE | `/snapshots/{id}` | Delete snapshot |
| GET | `/key-pairs` | List key pairs |
| POST | `/key-pairs` | Create key pair |
| DELETE | `/key-pairs/{name}` | Delete key pair |

**Network** (`/v1/compute`):

| Method | Path | Notes |
|--------|------|-------|
| GET/POST/PATCH/DELETE | `/networks[/{id}]` | VPCs |
| GET/POST/PATCH/DELETE | `/subnets[/{id}]` | Subnets |
| GET | `/storage-containers` | Nutanix only |
| GET/POST/DELETE | `/security-groups[/{id}]` | Security groups |
| GET/POST/DELETE | `/load-balancers[/{id}]` | Load balancers |
| GET/POST/DELETE | `/floating-ips[/{address}]` | Elastic IPs |
| POST | `/floating-ips/{addr}:associate`, `:disassociate` | IP actions |

**Storage** (`/v1/storage`):

| Method | Path | Notes |
|--------|------|-------|
| GET/POST/DELETE | `/buckets[/{name}]` | S3/Nutanix buckets |
| GET | `/buckets/{name}/objects` | List objects |
| POST | `/buckets/{name}/objects` | Upload (base64 body) |
| POST | `/buckets/{name}/objects/{path}:download` | Download |
| DELETE | `/buckets/{name}/objects/{path}` | Delete object |

**Other:**

| Method | Path | Notes |
|--------|------|-------|
| POST | `/v1/connections:test` | Test provider connectivity |
| GET | `/v1/jobs/{id}` | Job status (async ops) |
| POST | `/v1/admin/policies:reload` | Hot-reload policies (admin) |

## Exit codes

- **0** — all checks passed
- **N** — N checks failed (max 255)
