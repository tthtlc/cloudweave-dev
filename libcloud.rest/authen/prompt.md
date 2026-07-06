
For **client compromise and REST API compromise**, the easiest strong pattern is: **OIDC/OAuth2 for the client to authenticate to your API, and IAM roles for the API to access AWS**. Do not mint `GetSessionToken` per client request. That adds credential-vending risk without solving either compromise scenario well. [docs.aws.amazon](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/security-iam-roles.html)

## Recommended pattern

Use this split: [docs.aws.amazon](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-integrate-with-cognito.html)

- Client authenticates with **OIDC/OAuth2** and gets a short-lived JWT access token.
- Client sends `Authorization: Bearer <JWT>` to the REST API.
- REST API validates the token, then uses its **own AWS identity** through an IAM role attached to the compute platform, such as ECS task role, EKS IRSA, or EC2 instance profile. AWS rotates these credentials automatically. [docs.aws.amazon](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- REST API never receives long-term AWS keys from the client, and the client never receives AWS credentials. [docs.aws.amazon](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/security-iam-roles.html)

This is easier to implement because each side has one job: user/session auth at the app layer, AWS auth at the infrastructure layer. OIDC is also a better fit than SAML for application protocols because it uses HTTP/JSON flows. [aws.amazon](https://aws.amazon.com/blogs/security/approaches-for-authenticating-external-applications-in-a-machine-to-machine-scenario/)

## Why this is better

For **client compromise**, a stolen app token can be limited with short TTL, scopes, audience checks, revocation strategy, and API-side rate limits. A stolen AWS credential set is usually worse because it directly authorizes backend cloud actions. [docs.aws.amazon](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-integrate-with-cognito.html)

For **REST API compromise**, the blast radius is controlled by the IAM role attached to that service. ECS task roles and EKS IRSA issue temporary credentials automatically and rotate them, so you avoid storing root or IAM user access keys in an “authenticator” service.  With `GetSessionToken`, the temp credentials inherit the caller’s permissions, which often makes accidental over-privilege more likely than a tightly scoped role-based design. [docs.aws.amazon](https://docs.aws.amazon.com/STS/latest/APIReference/API_GetSessionToken.html)

## Practical standards

### Client to API

Use one of these, ordered by ease:

| Option | What it does | Fit |
|---|---|---|
| **Cognito User Pool + API Gateway authorizer** | Managed login and JWT validation at the API edge.  [docs.aws.amazon](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-integrate-with-cognito.html) | Easiest if you are already on AWS. |
| Any OIDC provider + JWT validation in app | Your API verifies issuer, audience, expiry, and signature via JWKS.  [aws.amazon](https://aws.amazon.com/blogs/security/approaches-for-authenticating-external-applications-in-a-machine-to-machine-scenario/) | Good when you already use Auth0, Okta, Entra ID, Keycloak. |
| OAuth2 client credentials | For machine-to-machine clients, not end users.  [aws.amazon](https://aws.amazon.com/blogs/security/approaches-for-authenticating-external-applications-in-a-machine-to-machine-scenario/) | Good for service callers. |

If your “client” is a browser or mobile app, Cognito User Pools or another OIDC IdP is usually the cleanest path. API Gateway can enforce Cognito user-pool tokens before traffic even reaches your backend. [docs.aws.amazon](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-integrate-with-cognito.html)

### API to AWS

Use compute-native AWS identity:

- **ECS task role** for containers on ECS; credentials are temporary and automatically rotated, and exposed to the SDK through the container credential endpoint. [docs.aws.amazon](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/security-iam-roles.html)
- **EKS IRSA** for Kubernetes; the pod uses a service-account token and STS `AssumeRoleWithWebIdentity` to get temporary credentials for the bound IAM role. [docs.aws.amazon](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- **EC2 instance profile** if the API runs on EC2. This follows the same role-based pattern. [docs.aws.amazon](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/security-iam-roles.html)

This is the AWS standard alternative to passing AWS credentials around between services. [docs.aws.amazon](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)

## Simple protocol flow

A minimal secure flow looks like this: [docs.aws.amazon](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-integrate-with-cognito.html)

1. User signs in to OIDC provider and receives JWT access token.
2. Client calls REST API with bearer token.
3. API validates JWT claims: signature, issuer, audience, expiry, scopes.
4. API performs business authorization in app logic.
5. API calls AWS using its local role-backed SDK credentials.
6. AWS authorizes only what that service role allows.

That gives you **separation of concerns**: user identity is not mixed with cloud credentials. [aws.amazon](https://aws.amazon.com/blogs/security/approaches-for-authenticating-external-applications-in-a-machine-to-machine-scenario/)

## Easy implementation choices

If you want the least engineering effort on AWS:

- **Frontend/mobile app:** Cognito User Pool.
- **API entry:** API Gateway with Cognito authorizer. [docs.aws.amazon](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-integrate-with-cognito.html)
- **Backend compute:** Lambda, ECS, or EKS with attached IAM role. [docs.aws.amazon](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- **AWS SDK:** use default credential chain; no explicit access key handling in code. [docs.aws.amazon](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/security-iam-roles.html)

If you are not using API Gateway, validating JWTs in a Node, Go, or Python REST API is still straightforward because OIDC exposes standard JWKS-based signature verification. OIDC is specifically positioned as application-friendly compared with SAML. [aws.amazon](https://aws.amazon.com/blogs/security/approaches-for-authenticating-external-applications-in-a-machine-to-machine-scenario/)

## Threat-model notes

This design does **not** eliminate damage from a compromised REST API server; nothing can, if the server is the actor calling AWS. It does, however, constrain damage to the service role’s permissions and avoids turning your auth service into a credential mint for attackers. [docs.aws.amazon](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)

For compromised clients, use:

- Short JWT TTLs.
- Refresh token rotation if applicable.
- Scope-based access tokens.
- Device/session revocation.
- Rate limiting and anomaly detection at the API. [aws.amazon](https://aws.amazon.com/blogs/security/approaches-for-authenticating-external-applications-in-a-machine-to-machine-scenario/)

If your client is not a human user but another service outside AWS, the nearest “easy standard” is **OAuth2 client credentials** for client-to-API auth, while the API still uses an IAM role to reach AWS. [aws.amazon](https://aws.amazon.com/blogs/security/approaches-for-authenticating-external-applications-in-a-machine-to-machine-scenario/)
