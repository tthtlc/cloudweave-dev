

I checked the flow against the security design in your `rest_api_security.md`, and the short answer is: **partially yes for the auth pattern, but not fully proven for REST API server and OpenFGA security requirements**. 

`provision_aws.sh` follows the right high-level pattern of OIDC login first, OpenFGA authorization checks second, and backend AWS access through the server path instead of giving AWS credentials to the client script directly as cloud API credentials.  However, the script and shared helpers also expose several gaps: AWS credentials are still constructed from environment variables and passed in the request payload as a `connection` object, local HTTP endpoints are used by default, and the OpenFGA checks shown here are pre-flight client-side checks rather than proof of enforced server-side authorization on every sensitive API call. 

## What matches

The script does authenticate through an IdP first by calling `idp_login`, which obtains an OIDC access token and then uses that bearer token for calls to the libcloud REST API.  That matches the document’s requirement that the client authenticate with OIDC/OAuth2 and call the REST API with `Authorization: Bearer <JWT>`. 

It also performs authorization checks through OpenFGA before doing AWS-related actions, including `can_connect`, `can_use`, and either `can_read` or `can_provision` depending on the user role.  Conceptually, that aligns with the design’s split where authentication proves identity and authorization decides what the caller may do. 

The script also supports a read-only path for `reader` and `cloud-readonly` users and skips mutating provisioning calls in that branch.  That is good from a least-privilege workflow perspective, though it is only a partial control because it depends on both role naming and actual backend enforcement. [owasp](https://owasp.org/API-Security/editions/2023/en/0x11-t10/)

## Main gaps

The biggest mismatch with your security design is that AWS credentials are still taken from `LIBCLOUD_AWS_PROD_KEY` and `LIBCLOUD_AWS_PROD_SECRET`, placed into a connection object, URL-encoded, and sent to the REST API.  Your design explicitly says the REST API should use its own AWS identity through an IAM role and that the client should never receive or pass AWS credentials. 

In other words, this script is not implementing the preferred model “client token to API, API role to AWS”; it is implementing “client token to API plus client-supplied AWS credentials to API.”  That is a significant security difference because it keeps credential-vending or credential-passing behavior alive, which your design specifically recommends avoiding. 

A second gap is transport security: defaults are local plain HTTP for Dex, Authentik, OpenFGA, and the libcloud REST API (`http://localhost:5556`, `http://localhost:9000`, `http://localhost:8080`, `http://localhost:8765`).  Localhost development is understandable, but as written this does not meet production-grade REST API security expectations for encrypted transport and trusted server identity. [csrc.nist](https://csrc.nist.gov/pubs/sp/800/204/a/ipd)

A third gap is that the OpenFGA checks visible here are done in shell before the libcloud API calls.  That is useful for demo flow and early denial, but it does **not** by itself prove the REST API server enforces the same authorization on `/v1/connections:test`, `/v1/compute/nodes`, `/v1/compute/images`, `/v1/compute/sizes`, `/v1/compute/subnets`, and related endpoints.  For real security, the server must enforce authz per request, because a caller can bypass this script and call the API directly. 

## OpenFGA-specific assessment

The OpenFGA model usage shown here is directionally sound: user identity is represented as `user:<name>`, and checks are made against objects like `libcloud_api:main`, `provider:aws`, and `aws_region:<region>`.  That gives you a clean graph-based authorization shape for “may connect,” “may use provider,” and “may provision/read region.” 

What is **not** shown is whether the REST API maps each endpoint and action to the same tuples and relations server-side.  For example, the provisioning POST to `/v1/compute/nodes` should be denied by the REST API unless the token subject is authorized for the exact action and backend object, regardless of whether `openfga_authorization_flow` was run beforehand. [owasp](https://owasp.org/API-Security/editions/2023/en/0x11-t10/)

Also not shown are object-level or resource-level checks after node creation, such as “can read node X,” “can delete node X,” or “can attach subnet/security-group Y.”  If OpenFGA is only being used at the provider or region level, that is better than nothing, but it is weaker than full object-level authorization. 

## REST API server requirements check

Against your `rest_api_security.md`, here is the practical verdict:

| Requirement | Status | Notes |
|---|---|---|
| OIDC/OAuth2 client auth to API | Mostly meets   |
| JWT-based API access | Mostly meets   |
| API uses its own AWS identity/role | Does **not** meet   |
| Client never receives/passes AWS credentials | Does **not** meet   |
| OpenFGA authorization before sensitive actions | Partially meets   |
| Read-only versus provision roles | Partially meets   |
| Secure transport | Not production-ready   |
| Least privilege / blast radius control | Weak-to-partial   |

## Specific issues to fix

1. Remove client-supplied AWS credentials from the request path. 
The libcloud REST service should hold the AWS access path itself, ideally via ECS task role, EKS IRSA, EC2 instance profile, or another server-side secret broker only the service can use. [csrc.nist](https://csrc.nist.gov/pubs/sp/800/204/a/ipd)

2. Make OpenFGA enforcement happen inside the REST API on every endpoint. [owasp](https://owasp.org/API-Security/editions/2023/en/0x11-t10/)
Keep the shell pre-check if you want better UX, but treat it as advisory only. 

3. Validate JWT claims server-side, not only “token exists.” 
The API should explicitly enforce signature, issuer, audience, expiry, and relevant claims/scopes before any libcloud or AWS action. 

4. Use HTTPS everywhere outside local dev. [csrc.nist](https://csrc.nist.gov/pubs/sp/800/204/a/ipd)
At minimum: IdP, OpenFGA, and REST API should all run over TLS; ideally internal service-to-service traffic also gets mTLS or equivalent mesh-based protection. [csrc.nist](https://csrc.nist.rip/pubs/sp/800/204/final)

5. Avoid default passwords in shared scripts. 
Even if this is a demo, embedded fallback passwords like `CloudAdmin123!` and related defaults should be removed or gated behind an explicit dev-only flag. 

6. Stop putting sensitive connection data in query parameters where possible. 
This script uses `connection=${CONNECTION_PARAM}` in GET requests, which is operationally risky because URLs can leak into logs, traces, proxies, browser history, and monitoring systems.  Even with redaction in your helper, downstream infrastructure may still log it. 

7. Add resource-level OpenFGA objects. [owasp](https://owasp.org/API-Security/editions/2023/en/0x11-t10/)
For stronger authorization, model not only `provider:aws` and `aws_region:ap-southeast-1`, but also concrete resources such as node ids, subnet ids, or environment/project boundaries. [owasp](https://owasp.org/API-Security/editions/2023/en/0x11-t10/)

## Verdict

So, if the question is “does `provision_aws.sh` fully meet the REST API server and OpenFGA security requirements?”, the answer is **no, not fully**.  It demonstrates the right broad control flow—OIDC login, OpenFGA checks, REST API mediation—but it still violates one of your core security requirements by passing AWS credentials from the client side instead of relying on server-side IAM identity, and it does not prove server-enforced OpenFGA authorization on every API call. 

If the question is “is it a reasonable demo of the intended direction?”, then yes, it is close in structure but still needs several security upgrades before I would call it aligned with the design in `rest_api_security.md`. 

## Useful references

- OWASP API Security Top 10 2023: broken auth, broken authorization, and security misconfiguration are the exact categories relevant here. [owasp](https://owasp.org/API-Security/editions/2023/en/0x11-t10/)
  [OWASP API Security Top 10](https://owasp.org/API-Security/editions/2023/en/0x11-t10/) [owasp](https://owasp.org/API-Security/editions/2023/en/0x11-t10/)

- NIST SP 800-204A: guidance for secure microservice interactions, secure token services, and service-to-service protections. [csrc.nist](https://csrc.nist.gov/pubs/sp/800/204/a/ipd)
  [NIST SP 800-204A](https://csrc.nist.gov/pubs/sp/800/204/a/ipd) [csrc.nist](https://csrc.nist.gov/pubs/sp/800/204/a/ipd)

Would you like me to turn this into a line-by-line remediation review of `provision_aws.sh` and `common.sh`, with exact code changes recommended for each issue?
