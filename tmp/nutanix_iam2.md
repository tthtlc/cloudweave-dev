

You generally should **not** try to obtain or persist `NTNX_IAM_SESSION` or browser refresh-token cookies for automation. Those are Prism Central web-session artifacts, intended for the UI and subject to rotation/expiry; use a supported API authentication method instead.

## Recommended: IAM API key

For Prism Central v4 APIs, create a **service account**, generate an IAM API key for it, and attach a least-privilege Authorization Policy. This is Nutanix’s supported automation pattern and avoids managing browser sessions or refresh tokens. It requires Prism Central `pc.2024.3+` and AOS `7.0+`; API keys are only supported for service accounts, not normal users. [nutanix](https://www.nutanix.dev/2025/02/05/nutanix-v4-apis-using-api-key-authentication/)

1. Authenticate initially to Prism Central with an administrative identity.
2. In IAM v4:
   - Create a user with `userType = SERVICE_ACCOUNT`.
   - Create a key with `keyType = API_KEY` for that account.
   - Store the returned key immediately in a secret manager—Nutanix only displays it once.
   - Bind that service account to an Authorization Policy with the minimum necessary role and entity scope.
3. Send it on API calls:

```bash
curl --fail --silent --show-error \
  --cacert /etc/ssl/certs/your-pc-ca.pem \
  -H "X-Ntnx-Api-Key: ${NTNX_API_KEY}" \
  "https://pc.example.net:9440/api/vmm/v4.0/ahv/config/vms"
```

Nutanix’s v4 SDK/API approach is specifically to send the key in `X-Ntnx-Api-Key`; their example demonstrates using that header to list VMs after creating a service account, key, and authorization policy. [nutanix](https://www.nutanix.dev/2025/02/05/nutanix-v4-apis-using-api-key-authentication/)

## Do not automate the UI cookie

`NTNX_IAM_SESSION` is a **web-session cookie**, not a stable public automation credential. Trying to reproduce UI login flows, scrape cookies, or extract refresh tokens from browser storage creates several operational and security problems:

- Cookie and refresh-token format, scopes, rotation, and endpoints are implementation details that may change with Prism Central releases.
- A session cookie effectively behaves like a logged-in user session, so leakage can enable account takeover until expiry/revocation.
- It is difficult to grant least privilege cleanly if you rely on an interactive admin identity.
- It is likely to break in headless jobs, CI, Terraform providers, or long-running controllers.

If you are debugging your own web login, you may observe `Set-Cookie: NTNX_IAM_SESSION=...` in your browser’s Network panel, but do not export it, put it in source control, or use it as an application credential.

## If you need OAuth-style refresh

Use a Nutanix API/service that explicitly documents a token endpoint and supports a `REFRESH_TOKEN` grant for that product. For example, Nutanix Move documents token issuance using `PASSWORD`, `AUTHORIZATION_CODE`, or `REFRESH_TOKEN` grants, including a refresh-token input. That contract is specific to **Move** and should not be assumed to apply to Prism Central IAM/browser sessions. [nutanix](https://www.nutanix.dev/api_reference/apis/move.html)

For Prism Central infrastructure automation, prefer:

| Need | Use |
|---|---|
| v4 REST/SDK automation | IAM service account + API key |
| One-off administrative API work | Basic auth only where that endpoint/version explicitly supports it |
| Browser/UI access | Normal interactive IAM login and session cookie managed by the browser |
| Nutanix Move integration | Its documented token endpoint and refresh flow |

## Operational hardening

- Put the API key in Vault, Kubernetes External Secrets, CI secret storage, or an equivalent secret manager.
- Create a narrowly scoped custom role; do not assign Super Admin except for a short validation step. Nutanix’s published demo uses Super Admin only as an example and notes production roles should be more restrictive. [nutanix](https://www.nutanix.dev/2025/02/05/nutanix-v4-apis-using-api-key-authentication/)
- Use the Prism Central CA certificate rather than disabling TLS verification.
- Name keys by workload and environment, e.g. `terraform-prod-vmm-readwrite`.
- Rotate and revoke keys on a schedule and immediately after suspected exposure.
- Separate service accounts per automation boundary rather than sharing one key across Terraform, CI, backup, and operators.

If you tell me your target—Terraform, a custom Python/Go client, or a particular Nutanix API namespace—I can provide a least-privilege IAM v4 setup and an implementation example for it.
