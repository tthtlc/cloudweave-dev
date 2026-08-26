# Nutanix Prism Central — v4 IAM & List-VMs curl scripts

Bash + curl scripts covering **every** REST endpoint of the two IAM swagger
documents, plus a cookie-auth port of the C# "List VMs" sample.

## Files

| File | Purpose |
|---|---|
| `.env` | Prism Central URL + username + password (fill it in — never commit) |
| `common.sh` | Shared library: `.env` loading, `iam_login()` cookie auth, `_req`/`_req_multipart` curl helpers |
| `iam_v4.0_curl.sh` | **54 functions** — every endpoint of `swagger-iam-v4.0-all.yaml` |
| `iam_v4.1_curl.sh` | **66 functions** — every endpoint of `swagger-iam-v4.1.b3-all.yaml` |
| `list_vms_curl.sh` | Port of `code-samples/csharp/v4api_client/list_vms/Nutanix v4 API Demo - List VMs/Program.cs` |
| `extract_endpoints.py`, `extract_bodies.py`, `generate_scripts.py` | Generator pipeline (see Regenerating below) |
| `iam-v4.0-endpoints.json`, `iam-v4.0-bodies.json`, `iam-v4.1-*.json` | Extracted endpoint/body data |

## Setup

1. Edit `.env`:
   ```bash
   PC_URL="https://10.0.0.1:9440"   # your Prism Central
   PC_USERNAME="admin"
   PC_PASSWORD="<your-password>"
   PC_INSECURE="true"               # false if your PC has a trusted cert
   ```
2. Point the scripts at a different env file if needed: `ENV_FILE=/path/to/.env ./iam_v4.0_curl.sh ...`

## Authentication model

`iam_login()` authenticates **once** with HTTP Basic auth (credentials from
`.env`) against an IAM endpoint and stores the `NTNX_IGW_SESSION` session
cookie in a cookie jar. Every request after that sends **only the cookie** —
no `Authorization` header — mirroring how the Prism Central UI authorizes
its calls. The login step also verifies the cookie is accepted by itself and
falls back to `AUTH_MODE=basic` (or the legacy
`/PrismGateway/services/rest/v1/session` endpoint) if needed.

## Usage

```bash
./iam_v4.0_curl.sh                      # list all endpoints
./iam_v4.0_curl.sh listUsers            # run one endpoint (auto-login)
./iam_v4.0_curl.sh listUsers '$page=0' '$limit=50' '$filter=userType eq "LOCAL"'
./iam_v4.0_curl.sh getUserById <extId>                      # path args positional
./iam_v4.0_curl.sh deleteRoleById <extId> <etag-or-0>       # If-Match header
./iam_v4.0_curl.sh createRole                                # POST (payload inside)
PAYLOAD='{"displayName":"my_role","operations":["<op-id>"]}' ./iam_v4.0_curl.sh createRole
./iam_v4.0_curl.sh all-readonly         # run every GET
FORCE_ALL=yes ./iam_v4.0_curl.sh all    # run EVERYTHING incl. DELETE/POST (careful!)

./list_vms_curl.sh                      # list VMs via cookie auth, prints totalAvailableResults
```

Useful knobs (any script): `CURL_DRY_RUN=1` (print the curl command instead
of running it), `AUTH_MODE=basic`, `NTNX_PRETTY=0`, `ETAG=<value>`,
`CA_CERT_FILE=/path/to/ca.pem` (cert-auth-provider upload).

> **Warning**: the create/update/delete/reset/revoke/share functions mutate
> Prism Central. Payloads are filled with placeholder values taken from the
> swagger examples — review them (`PAYLOAD=...` overrides) before running
> against a real cluster.

## The C# → curl conversion

The C# demo (`Program.cs`) issues one GET to
`/api/vmm/v4.2/ahv/config/vms` with Basic auth and prints
`metadata.totalAvailableResults`. `list_vms_curl.sh` reproduces its headers
(`Accept`, `User-Agent`, `X-Correlation-Id`), its success/failure checks and
its output — with one deliberate change: access control uses the **session
cookie from the IAM login** instead of a Basic header.

## Regenerating after swagger updates

```bash
python3 extract_endpoints.py swagger-iam-v4.0-all.yaml    iam-v4.0-endpoints.json
python3 extract_bodies.py     swagger-iam-v4.0-all.yaml    iam-v4.0-bodies.json
python3 extract_endpoints.py swagger-iam-v4.1.b3-all.yaml  iam-v4.1-endpoints.json
python3 extract_bodies.py     swagger-iam-v4.1.b3-all.yaml iam-v4.1-bodies.json
python3 generate_scripts.py
bash -n iam_v4.0_curl.sh && bash -n iam_v4.1_curl.sh
```
