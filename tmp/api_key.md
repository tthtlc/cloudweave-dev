https://www.perplexity.ai/search/165e674d-c7b6-4ade-a33a-85ed9e63962e

Both Nutanix v3 and v4 can use HTTP Basic authentication and session-cookie authentication. The main authentication change in v4 is that it adds a first-class IAM API-key path—especially suited to service accounts—and aligns authorization more closely with current Prism Central IAM controls. [nutanix](https://www.nutanix.dev/api-versions/)

## Authentication matrix

| Aspect | v3 API | v4 API |
|---|---|---|
| Primary platform | Prism Central only | Primarily Prism Central, with API namespaces also available according to the relevant PC/AOS support matrix |
| HTTP Basic auth | Supported: send username/password in the `Authorization` header | Supported: Basic header can authenticate an individual request |
| Session-cookie auth | Supported: obtain and reuse the authenticated session cookie | Supported: reuse the session cookie after session establishment |
| IAM API key | Not the standard v3 authentication model | Supported for service accounts, typically sent as `X-Ntnx-Api-Key` in v4.0 |
| SDK API-key setup | N/A | v4.1 SDKs can configure an API key with SDK configuration methods instead of manually adding the header |
| Recommended automation identity | Often a dedicated local/directory user and credential storage | IAM service account plus API key, with narrowly scoped authorization |
| Lifecycle status | Legacy; planned deprecation/no support beginning with the planned Q4 2026 AOS/PC upgrade release | Current recommended API generation; GA since PC 2024.3/AOS 7.0 |

Nutanix explicitly describes v3 as Prism Central–only and documents its use of HTTP Basic authentication.  Nutanix recommends v4 for production and migration because v0.8–v3 are on the legacy/deprecation path. [nutanix](https://www.nutanix.dev/api_reference/apis/self-service.html)

## Basic vs cookie behavior

The key distinction is **not** “v3 uses Basic while v4 requires a cookie.” Both support these two patterns:

### Stateless Basic authentication

Each request carries credentials:

```http
Authorization: Basic <base64(username:password)>
```

This is valid for v3 and v4. It is straightforward, but repeatedly presenting user credentials is typically less desirable for high-volume automation.

### Stateful session authentication

A successful authenticated request can establish a server-side session and return a cookie. Your HTTP client stores and sends that cookie on subsequent requests:

```http
Cookie: <returned-session-cookie>
```

The cookie replaces repeated Basic credentials for the lifetime of the session; it is not normally an additional mandatory header to send *with* Basic authentication. Nutanix’s legacy API guidance describes Basic auth as credentials supplied with each request and session authentication as credentials stored in a cookie. [nutanix](https://www.nutanix.dev/api_reference/apis/self-service.html)

## The material v4 addition: API keys

For Prism Central 2024.3 / AOS 7.0-era v4 environments, Nutanix introduced API-key authentication. An IAM **service account** is associated with an API key, and clients can use:

```http
X-Ntnx-Api-Key: <api-key>
```

The v4.0 REST/SDK flow uses that explicit header. In v4.1 SDKs, the SDK can be configured with the API key directly—for example, `config.set_api_key(...)`—and handles the header itself. [nutanix](https://www.nutanix.dev/2025/08/05/update-api-key-authentication-in-nutanix-rest-api-and-sdk-v4-1/)

This has practical advantages over Basic auth for non-interactive automation:

- No human-user password must be embedded in Terraform, CI, or a long-running controller.
- The identity is purpose-built for automation.
- Authorization can be assigned to the service account according to least privilege.
- API keys can be rotated independently of a human account password.

## Migration implications

When moving a v3 client to v4, do not assume the authentication mechanism must change immediately:

1. Start with Basic auth if you need the smallest migration delta.
2. Ensure the v4 request targets the correct namespace and versioned endpoint; v3’s “intentful” Prism Central endpoints do not map one-to-one to all v4 resource APIs.
3. Use an HTTP session/cookie jar if request volume is substantial and your client supports session auth.
4. Move unattended production integrations to a service account plus API key where your Prism Central/AOS version and selected v4 namespace support it.
5. Treat API-key authorization failures as IAM policy/role-binding issues, not as cookie requirements.

So, if your v4 read call succeeds only after replaying a cookie, that likely reflects how that particular client, endpoint path, proxy, or authentication flow is configured—not a general rule that v4 requires Basic auth *and* its returned cookie together.
