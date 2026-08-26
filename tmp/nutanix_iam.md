

Yes. Nutanix provides downloadable **OpenAPI specifications** for its v4 API namespaces, including **IAM**. You can import the IAM YAML specification into Stoplight and use it to create mocks, documentation, generated clients, and contract tests. Nutanix explicitly says v4 OpenAPI specs are downloadable from its API/SDK Developer Portal per namespace. [nutanix](https://www.nutanix.com/blog/announcing-the-v4-api-and-sdk-general-availability-in-pc-2024-3-aos-7-0)

## Where to get it

Open the Nutanix Developer Portal’s IAM API reference:

- [IAM v4.1 beta API reference](https://developers.nutanix.com/api-reference?namespace=iam&version=v4.1.b1)

That page presents a **Download OpenAPI specification** action. [developers.nutanix](https://developers.nutanix.com/api-reference?namespace=iam&version=v4.1.b1)

For your deployed Prism Central, choose the same IAM API version your environment supports—typically `v4.0` for GA usage rather than an alpha (`v4.0.a1`) or beta (`v4.1.b1`) contract.

The downloadable artifact is generally YAML, which Stoplight handles directly. You can also convert it to JSON if your workflow specifically requires `openapi.json`.

```bash
npx @redocly/cli bundle nutanix-iam.yaml \
  --output nutanix-iam.openapi.json \
  --ext json
```

## What it covers

The IAM namespace’s contract covers **IAM management APIs**, including users, user groups, directory services, identity providers, roles, and authorization policies. [developers.nutanix](https://developers.nutanix.com/api/v1/sdk/namespaces/main/iam/versions/v4.0/languages/python/)

It also has an authentication-related namespace (`authn`) for operations such as user and authentication-provider administration; older generated API documentation describes it as “user, token and identity management.” [developers.nutanix](https://developers.nutanix.com/api/v1/sdk/namespaces/main/iam/versions/v4.0.a1/languages/java/overview-summary.html)

The published v4 specs declare these API security mechanisms:

```yaml
components:
  securitySchemes:
    basicAuthScheme:
      type: http
      scheme: basic
    apiKeyAuthScheme:
      type: apiKey
      in: header
      name: X-ntnx-api-key
```

This matches Nutanix’s IAM SDK documentation, which identifies HTTP Basic authentication and API-key authentication using `X-ntnx-api-key`. [developers.nutanix](https://developers.nutanix.com/api/v1/sdk/namespaces/main/iam/versions/v4.1.b1/languages/python/configuration.html)

## Important limitation

The IAM OpenAPI spec is suitable for mocking **documented REST APIs**, but it is not necessarily a contract for Prism Central’s private browser sign-in mechanics—such as issuance of `NTNX_IAM_SESSION`, browser cookies, UI session renewal, or an OAuth-style refresh-token exchange.

In other words:

| Goal | Is IAM OpenAPI enough? |
|---|---|
| Mock IAM user/role/policy/directory-service APIs | Yes |
| Mock calls authenticated by Basic or `X-ntnx-api-key` | Yes |
| Generate an IAM v4 client | Yes |
| Mock Prism UI cookie login (`NTNX_IAM_SESSION`) | Usually no |
| Model refresh-token lifecycle for UI sessions | No documented stable API contract indicated |

For Stoplight, model authentication as an API-key security scheme and return deterministic 401/403 responses rather than fabricating UI session cookies. If your consumer needs token-refresh behavior, add that as a **separate, explicitly synthetic mock endpoint**—for example `/mock/auth/token`—and make clear it is a test-only contract rather than a Nutanix-supported endpoint.

## Stoplight setup

1. Download the IAM OpenAPI YAML for your version.
2. Import it into Stoplight Studio or push it to your Stoplight project repository.
3. Configure an environment variable such as `NTNX_API_KEY`.
4. Configure mocks for representative IAM resources, e.g.:

```yaml
components:
  securitySchemes:
    nutanixApiKey:
      type: apiKey
      in: header
      name: X-ntnx-api-key

security:
  - nutanixApiKey: []
```

5. Define examples for `200`, `401`, `403`, validation errors, pagination, and Nutanix `extId` resource identities.
6. Validate your client against Stoplight’s Prism mock, then run a limited integration suite against a non-production Prism Central instance.

If you can paste the downloaded IAM YAML—or state your Prism Central version—I can help you produce a Stoplight-ready overlay that adds realistic authentication failures and fixture responses without modifying Nutanix’s upstream spec.
