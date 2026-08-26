https://www.perplexity.ai/search/165e674d-c7b6-4ade-a33a-85ed9e63962e

No. In Nutanix Prism Central v4, **HTTP Basic Authentication remains sufficient** for read requests such as listing or retrieving resource information, provided the account has the required IAM permissions. Nutanix’s own v4 examples issue each request with Basic credentials directly; a separate session cookie is not required. [nutanix](https://www.nutanix.dev/api-versions/)

## What may be causing confusion

Nutanix v4 supports multiple authentication modes:

| Method | Is it valid for v4 resource reads? | Cookie required? |
|---|---:|---:|
| HTTP Basic (`Authorization: Basic …`) | Yes | No |
| Session-cookie authentication | Yes | Yes, by design |
| `X-Ntnx-Api-Key` for IAM service accounts | Yes | No |

If you choose session authentication, the first authenticated call establishes a session and returns cookies; you then reuse those cookies in later calls, usually omitting Basic credentials. That is an optimization / alternate auth flow—not an additional mandatory credential alongside Basic auth. [nutanix](https://www.nutanix.dev/api-versions/)

## Direct Basic-auth example

A regular v4 request can be made directly like this:

```bash
curl --silent --show-error --fail \
  --user "${PC_USER}:${PC_PASSWORD}" \
  -H 'Accept: application/json' \
  'https://<prism-central>:9440/api/vmm/v4.0/ahv/config/vms?$limit=50'
```

Nutanix’s v4 documentation likewise demonstrates GET requests with `requests.get(..., auth=HTTPBasicAuth(...))`, including resource-list and resource-detail calls. [nutanix](https://www.nutanix.dev/nutanix-api-user-guide/)

## Recommended implementation

For a custom API client:

- Use Basic auth per request for a simple integration or troubleshooting.
- Prefer a persistent HTTP client / session that retains cookies if you make many requests, to reduce repeated authentication work.
- For unattended production automation, prefer an IAM **service account + API key** (`X-Ntnx-Api-Key`) rather than embedding a human user’s password. [nutanix](https://www.nutanix.dev/nutanix-api-user-guide/)

If basic-only requests are returning 401/403 in your environment, investigate account type, authorization policy / role bindings, Prism Central endpoint versus Prism Element endpoint, API namespace/version, and any proxy or load-balancer cookie-affinity behavior. The cookie itself should not normally be a v4 requirement when a valid Basic `Authorization` header is sent.
