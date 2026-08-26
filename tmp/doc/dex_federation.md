
Dex is an OpenID Connect (OIDC) identity service that federates authentication to upstream identity providers through "connectors". Among your four target providers, Dex has native connectors for **Google** and **Microsoft Azure**, while **AWS** (via Cognito/IAM Identity Center) and **DigitalOcean** must use the generic **OIDC connector** since neither has a dedicated Dex connector type. [aws.amazon](https://aws.amazon.com/blogs/containers/authenticate-to-amazon-eks-using-google-workspace/)

## Prerequisites

Before configuring connectors, you need a running Dex instance with a base `config.yaml`. The global `issuer` URL and `redirectURI` pattern (`<issuer>/callback`) are used by all connectors. Each provider also requires you to register an OAuth2/OIDC application on that provider's developer console and obtain a `clientID` and `clientSecret`. [aws.amazon](https://aws.amazon.com/blogs/containers/authenticate-to-amazon-eks-using-google-workspace/)

## Google Connector

Dex ships with a native `google` connector that uses Google's OpenID Connect flow and adds Google-specific features like hosted-domain whitelisting and group fetching via a service account. [dexidp](https://dexidp.io/docs/connectors/google/)

**Prerequisites on Google Cloud:**
- Create an OAuth 2.0 Client ID in the Google Cloud Console (Credentials → Create Credentials → OAuth client ID)
- Set the authorized redirect URI to `https://<dex-issuer>/callback`
- For group membership, create a service account with Domain-Wide Delegation and grant the `https://www.googleapis.com/auth/admin.directory.group.readonly` scope [dexidp](https://dexidp.io/docs/connectors/google/)

**Dex configuration:**

```yaml
connectors:
- type: google
  id: google
  name: Google
  config:
    clientID: $GOOGLE_CLIENT_ID
    clientSecret: $GOOGLE_CLIENT_SECRET
    redirectURI: https://dex.example.com/callback
    # Optional: restrict to specific Google Workspace domains
    # hostedDomains:
    #   - example.com
    # Optional: restrict to specific groups (requires service account)
    # groups:
    #   - admins@example.com
    # serviceAccountFilePath: /path/to/googleAuth.json
    # domainToAdminEmail:
    #   "*": super-user@example.com
```

The `promptType` field defaults to `consent` (forcing the consent screen every login); set it to an empty string `""` to skip it. [dexidp](https://dexidp.io/docs/connectors/google/)

## Microsoft Azure Connector

Dex has a native `microsoft` connector that uses Microsoft's OAuth2 flow and supports Azure AD (now Entra ID) with tenant-specific configuration and group claims. [dexidp](https://dexidp.io/docs/connectors/google/)

**Prerequisites on Azure:**
- Register an application in the Azure Portal (App Registrations → New registration)
- Set the redirect URI to `https://<dex-issuer>/callback`
- Create a client secret under Certificates & secrets
- For group claims, add `Directory.Read.All` as a Delegated permission and have an admin grant consent at `https://login.microsoftonline.com/<tenant>/adminconsent?client_id=<client_id>` [dexidp](https://dexidp.io/docs/connectors/google/)

**Dex configuration:**

```yaml
connectors:
- type: microsoft
  id: microsoft
  name: Microsoft
  config:
    clientID: $MICROSOFT_APPLICATION_ID
    clientSecret: $MICROSOFT_CLIENT_SECRET
    redirectURI: https://dex.example.com/callback
    tenant: organizations           # or your tenant UUID/name
    # Optional: streamline login for a single domain
    # domainHint: example.com
    # Optional: restrict access to specific groups
    # groups:
    #   - developers
    #   - devops
    # Optional: normalize email case for Kubernetes RBAC
    # emailToLowercase: true
```

The `tenant` parameter controls which account types can authenticate: `common` (all accounts, default), `organizations` (work/school only), `consumers` (personal only), or a specific tenant UUID/name. Group claims (`groups`) require `tenant` to be set to a specific tenant UUID or name, and admin consent is needed for `Directory.Read.All`. [dexidp](https://dexidp.io/docs/connectors/google/)

## AWS (via OIDC Connector)

Dex does not have a dedicated AWS connector. You should use the generic `oidc` connector pointed at an AWS OIDC-compatible identity provider — either **AWS Cognito User Pools** or **AWS IAM Identity Center** (formerly AWS SSO). The OIDC connector table in Dex documentation explicitly lists Azure as a compatible provider for this connector type . [aws.amazon](https://aws.amazon.com/blogs/containers/authenticate-to-amazon-eks-using-google-workspace/)

**Option A — AWS Cognito User Pool:**

Cognito User Pools are OIDC-compliant. The issuer URL follows the format:

```
https://cognito-idp.<region>.amazonaws.com/<user-pool-id>
```

**Prerequisites on AWS:**
- Create a Cognito User Pool and note the Pool ID and region
- Create an App Client in the User Pool (generate a client secret)
- Set the callback URL to `https://<dex-issuer>/callback`
- Enable the `profile`, `email`, and `openid` scopes in the App Client settings

**Option B — AWS IAM Identity Center:**

IAM Identity Center also exposes an OIDC endpoint. You would configure it as a SAML or OIDC application in the Identity Center console and use the discovered issuer URL.

**Dex configuration (Cognito example):**

```yaml
connectors:
- type: oidc
  id: aws-cognito
  name: AWS Cognito
  config:
    issuer: https://cognito-idp.us-east-1.amazonaws.com/us-east-1_XXXXXXXXX
    clientID: $AWS_COGNITO_CLIENT_ID
    clientSecret: $AWS_COGNITO_CLIENT_SECRET
    redirectURI: https://dex.example.com/callback
    # Cognito returns groups under a non-standard claim
    claimMapping:
      groups: "cognito:groups"
    # Cognito may not return email_verified claim
    insecureSkipEmailVerified: true
    # Enable groups (note: groups may be stale until id token refresh)
    insecureEnableGroups: true
    # Optional: restrict to specific groups
    # allowedGroups:
    #   - admins
    #   - developers
```

The `insecureSkipEmailVerified` option is needed because Cognito (especially when federating through an upstream SAML IdP) may not include the `email_verified` claim. The `insecureEnableGroups` option is required because the OIDC connector does not refresh group claims during token refresh by default. [aws.amazon](https://aws.amazon.com/blogs/containers/authenticate-to-amazon-eks-using-google-workspace/)

## DigitalOcean (via OIDC Connector)

**DigitalOcean does not provide a native public OIDC identity provider service.** Unlike AWS Cognito, Azure AD, or Google Identity, DigitalOcean does not expose an OAuth2/OIDC endpoint that Dex could federate to for "DigitalOcean authentication." Therefore, there is no standard way to add DigitalOcean as a login option in Dex using a connector.

There are two alternative approaches:

**Alternative 1 — Use a third-party OIDC provider that federates DigitalOcean:** If you use a tool like Authentik, Keycloak, or Zitadel as an intermediary, you could configure that provider to authenticate against DigitalOcean (if it supports DigitalOcean as a social login) and then point Dex's generic `oidc` connector at it.

**Alternative 2 — Deploy Dex on DigitalOcean infrastructure:** If your intent is to host Dex itself on DigitalOcean Droplets or Kubernetes (DOKS), that is straightforward — Dex runs as a container and can be deployed via Helm or Docker. The authentication connectors would still point to the other identity providers (Google, Microsoft, AWS).

If you do have a custom or third-party OIDC endpoint you want to use for DigitalOcean users, the configuration would follow the same `oidc` connector pattern:

```yaml
connectors:
- type: oidc
  id: digitalocean
  name: DigitalOcean
  config:
    issuer: https://your-oidc-provider.example.com
    clientID: $DO_OIDC_CLIENT_ID
    clientSecret: $DO_OIDC_CLIENT_SECRET
    redirectURI: https://dex.example.com/callback
    scopes:
      - openid
      - profile
      - email
```

## Combined Configuration

Here is a full `config.yaml` example combining Google, Microsoft, and AWS Cognito connectors:

```yaml
issuer: https://dex.example.com

storage:
  type: sqlite3
  config:
    file: /var/dex/dex.db

web:
  http: 0.0.0.0:5556

# Enable if you want local password users as a fallback
# enablePasswordDB: true

staticClients:
- id: my-app
  secret: my-app-secret
  name: 'My App'
  redirectURIs:
  - https://my-app.example.com/callback

connectors:
# --- Google ---
- type: google
  id: google
  name: Google
  config:
    clientID: $GOOGLE_CLIENT_ID
    clientSecret: $GOOGLE_CLIENT_SECRET
    redirectURI: https://dex.example.com/callback
    promptType: ""

# --- Microsoft Azure ---
- type: microsoft
  id: microsoft
  name: Microsoft
  config:
    clientID: $MICROSOFT_APPLICATION_ID
    clientSecret: $MICROSOFT_CLIENT_SECRET
    redirectURI: https://dex.example.com/callback
    tenant: organizations
    emailToLowercase: true

# --- AWS (Cognito) ---
- type: oidc
  id: aws-cognito
  name: AWS Cognito
  config:
    issuer: https://cognito-idp.us-east-1.amazonaws.com/us-east-1_XXXXXXXXX
    clientID: $AWS_COGNITO_CLIENT_ID
    clientSecret: $AWS_COGNITO_CLIENT_SECRET
    redirectURI: https://dex.example.com/callback
    insecureSkipEmailVerified: true
    insecureEnableGroups: true
    claimMapping:
      groups: "cognito:groups"

oauth2:
  skipApprovalScreen: true
  alwaysShowLoginScreen: true

expiry:
  signingKeys: "6h"
  idTokens: "24h"
```

## Key Considerations

- **Redirect URI registration**: Every provider's application console must have the redirect URI set to `<dex-issuer>/callback`. [github](https://github.com/dexidp/dex/issues/1611)
- **Environment variable substitution**: Dex reads config values prefixed with `$` from environment variables, so you can inject secrets without hardcoding them. [aws.amazon](https://aws.amazon.com/blogs/containers/authenticate-to-amazon-eks-using-google-workspace/)
- **Group claims**: Google requires a service account with Domain-Wide Delegation; Microsoft requires `tenant` set to a specific tenant and admin consent for `Directory.Read.All`; the generic OIDC connector requires `insecureEnableGroups: true` and group claims may be stale between refreshes. [aws.amazon](https://aws.amazon.com/blogs/containers/authenticate-to-amazon-eks-using-google-workspace/)
- **Connector maturity**: Per Dex's connector table, Google is `alpha`, Microsoft and the generic OIDC connector are `beta` — meaning they are tested but may change in backward-incompatible ways .
- **DigitalOcean gap**: Since DigitalOcean lacks a native OIDC IdP, you would need an intermediary identity provider (e.g., Keycloak, Authentik, Zitadel) to bridge DigitalOcean authentication into Dex's OIDC connector.
