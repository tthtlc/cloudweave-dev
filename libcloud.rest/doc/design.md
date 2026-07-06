Target is to implement a REST API wrapper that be used to talk to libcloud API with different enabled drivers.

Other relevant information:

libcloud with Nutanix and AWS driver is here: ../libcloud

Two samples using libcloud API talking to Nutanix REST API (V4) are available:
../libcloud_demo
../libcloud_demo2

Two samples using libcloud API talking to AWS:
../libcloud_aws
../libcloud_aws2

## Security model

The API should adopt a **control-plane** model: clients authenticate to your FastAPI service, receive a temporary access token, and then invoke provider-neutral Libcloud-backed operations without ever sending Nutanix passwords, AWS secrets, or similar cloud credentials in routine API requests. Libcloud’s `NodeDriver` constructor requires provider credentials and connection parameters on the server side, which makes it natural to keep those values in `.env`-loaded configuration or another server-side secret source and never expose them through public REST contracts. [pypi](https://pypi.org/project/python-dotenv/)

JWTs are appropriate here only as session and authorization artifacts, not as secret containers. FastAPI’s security documentation states that JWTs are not encrypted and can be decoded by anyone holding them, so your JWT payload should contain claims like subject, tenant, role, scopes, connection references, and expiry, but must not include provider passwords, private keys, or API secrets. [github](https://github.com/fastapi/fastapi/discussions/11210)

## Revised architecture

The revised API should have six layers:
- FastAPI transport and OpenAPI.
- Identity and token service.
- Authorization and policy engine.
- Secret-backed provider connection registry.
- Libcloud adapter and orchestration layer.
- Async job worker for long-running tasks. [libcloud.apache](https://libcloud.apache.org/blog/)

The crucial change is that `connections` no longer store raw secrets as editable API payload fields in the normal data plane. Instead, a connection stores metadata plus a `secret_ref` or environment-variable mapping, and the runtime service resolves actual provider credentials from server-side configuration before constructing the Libcloud driver. Libcloud’s connection model directly supports this because driver creation happens in-process from parameters like `key`, `secret`, `host`, and `region`; clients only need authorization to use a named connection, not possession of the underlying credential material. [libcloud.apache](https://libcloud.apache.org/blog/)

A good internal structure is:
- `auth/`: login, token minting, token validation, scope handling.
- `config/`: `.env` loading and settings models.
- `secrets/`: secret resolution from env variables or secret manager.
- `connections/`: metadata registry for named provider accounts.
- `providers/`: AWS and Nutanix Libcloud driver factories.
- `compute/`: node, image, size, volume, snapshot, and key-pair services.
- `jobs/`: durable async orchestration. [pypi](https://pypi.org/project/python-dotenv/)

## Secret handling

Because different providers need different secret material, the API should use a **server-side secret indirection model**. A connection record should reference secret names or env-variable keys, while the real values live only in `.env` or a stronger backend such as Vault or KMS; `.env` is acceptable for server-side configuration loading, but it should stay out of version control and be loaded only by the server process. [jeeva](https://www.jeeva.us/docs/Python/dotenv/)

A connection record should look like this:

```json
{
  "id": "conn_aws_prod_sg",
  "provider": "aws",
  "name": "aws-prod-singapore",
  "auth_binding": {
    "key_env": "LIBCLOUD_AWS_PROD_KEY",
    "secret_env": "LIBCLOUD_AWS_PROD_SECRET"
  },
  "config": {
    "region": "ap-southeast-1",
    "secure": true
  },
  "allowed_scopes": [
    "compute:read",
    "compute:node:create",
    "compute:node:power",
    "compute:volume:manage"
  ],
  "status": "active"
}
```

For Nutanix:

```json
{
  "id": "conn_nutanix_lab_01",
  "provider": "nutanix",
  "name": "nutanix-lab-01",
  "auth_binding": {
    "key_env": "LIBCLOUD_NTNX_LAB_USER",
    "secret_env": "LIBCLOUD_NTNX_LAB_PASSWORD"
  },
  "config": {
    "host": "prism.example.internal",
    "port": 9440,
    "secure": true,
    "api_version": "v3"
  },
  "allowed_scopes": [
    "compute:read",
    "compute:node:create",
    "compute:node:delete"
  ],
  "status": "active"
}
```

The API should never return resolved secret values, never echo env variable contents, and never expose whether a specific variable is missing beyond a generic configuration error. This is especially important because Libcloud accepts sensitive constructor arguments directly, and those should be assembled only inside the trusted runtime boundary. [libcloud.apache](https://libcloud.apache.org/blog/)

### Recommended `.env` categories

Use environment variables for:
- API signing material: `JWT_SIGNING_KEY`, `JWT_ALGORITHM`, `ACCESS_TOKEN_TTL_SECONDS`, `REFRESH_TOKEN_TTL_SECONDS`. [github](https://github.com/fastapi/fastapi/discussions/11210)
- Provider account material: `LIBCLOUD_AWS_*`, `LIBCLOUD_NTNX_*`. [pypi](https://pypi.org/project/python-dotenv/)
- Database and job backend settings.
- Optional per-environment allowlists and feature flags. [pypi](https://pypi.org/project/python-dotenv/)

Do not use `.env` as a user-editable API surface. It is a deployment artifact for the server, not a client resource. [pypi](https://pypi.org/project/python-dotenv/)

## Authentication and token flows

The API should require client authentication before any provider operation. FastAPI’s documented OAuth2/JWT flow supports access tokens with expiry and bearer authorization headers, and it is a good base for this design. [github](https://github.com/fastapi/fastapi/discussions/11210)

Use two token types:
- **Access token**: short-lived JWT, for example 5 to 15 minutes.
- **Refresh token**: longer-lived opaque token or JWT, for example 8 to 24 hours, stored and revocable server-side. [github](https://github.com/fastapi/fastapi/discussions/11210)

Recommended auth endpoints:
- `POST /v1/auth/login`
- `POST /v1/auth/refresh`
- `POST /v1/auth/logout`
- `GET /v1/auth/me`
- `POST /v1/auth/token/introspect` for internal or admin use

A login request should be JSON:

```json
{
  "username": "platform-ops",
  "password": "********",
  "requested_scopes": [
    "compute:read",
    "compute:node:create"
  ]
}
```

Response:

```json
{
  "data": {
    "access_token": "eyJ...",
    "token_type": "bearer",
    "expires_in": 900,
    "refresh_token": "rft_01J...",
    "scope": "compute:read compute:node:create"
  }
}
```

FastAPI’s docs also recommend secure password hashing and explicitly show use of expiry claims in JWTs, so the authentication service should hash local passwords with Argon2 and enforce expiration on every access token. [github](https://github.com/fastapi/fastapi/discussions/11210)

### JWT claims

JWT claims should include only authorization and identity context, for example:
- `sub`: caller identity.
- `iss`: issuing service.
- `aud`: API audience.
- `iat`, `nbf`, `exp`.
- `jti`: token ID for revocation tracking.
- `scope`: granted scopes.
- `tenant_id` or `project_id`.
- `allowed_connections`: list of connection IDs or policy references.
- `session_id`. [github](https://github.com/fastapi/fastapi/discussions/11210)

Do not include:
- provider usernames,
- provider passwords,
- AWS secrets,
- SSH private keys,
- raw `.env` names unless you want them visible to token holders. [github](https://github.com/fastapi/fastapi/discussions/11210)

Because JWTs are only signed, not encrypted, every claim should be treated as readable by the client and intermediaries that can inspect headers. [github](https://github.com/fastapi/fastapi/discussions/11210)

## Authorization model

Authorization should be **scope-based plus connection-bound**. FastAPI’s security guidance notes that OAuth2 scopes can be used to encode permission sets in tokens, which fits this design well. [github](https://github.com/fastapi/fastapi/discussions/11210)

Recommended scopes:
- `compute:read`
- `compute:image:read`
- `compute:size:read`
- `compute:location:read`
- `compute:node:create`
- `compute:node:delete`
- `compute:node:power`
- `compute:volume:manage`
- `compute:keypair:manage`
- `jobs:read`
- `admin:connections:read`
- `admin:connections:write` [github](https://github.com/fastapi/fastapi/discussions/11210)

Then bind scopes to specific connections or connection groups. A token may allow `compute:node:create` on `conn_nutanix_lab_01` but only `compute:read` on `conn_aws_prod_sg`. That avoids giving broad access just because the same API user can authenticate.

A policy evaluation should check:
1. Is the JWT valid and unexpired? [github](https://github.com/fastapi/fastapi/discussions/11210)
2. Does the token include the required scope? [github](https://github.com/fastapi/fastapi/discussions/11210)
3. Is the target `connection_id` in the caller’s allowed connection set?
4. Is the requested provider operation enabled for that connection?
5. Is the requested action supported by the underlying Libcloud driver capability set? Libcloud exposes capability flags such as `driver.features['create_node']`, especially around create-node auth behaviors. [libcloud.apache](https://libcloud.apache.org/blog/)

## Revised resource model

Keep the provider-neutral resources, but revise `connections` to avoid raw secret ingestion in normal flows.

### Public resources
- `/v1/providers`
- `/v1/connections`
- `/v1/compute/nodes`
- `/v1/compute/images`
- `/v1/compute/sizes`
- `/v1/compute/locations`
- `/v1/compute/volumes`
- `/v1/compute/snapshots`
- `/v1/compute/key-pairs`
- `/v1/jobs`
- `/v1/auth/*` [libcloud.apache](https://libcloud.apache.org/blog/)

### Connection resource
A connection should expose:
- `id`
- `provider`
- `name`
- `config`
- `auth_mode`
- `secret_binding_status`
- `allowed_scopes`
- `capabilities`
- `labels`
- `status` [libcloud.apache](https://libcloud.apache.org/blog/)

Example response:

```json
{
  "data": {
    "id": "conn_nutanix_lab_01",
    "provider": "nutanix",
    "name": "nutanix-lab-01",
    "auth_mode": "server_env",
    "secret_binding_status": "configured",
    "config": {
      "host": "prism.example.internal",
      "port": 9440,
      "secure": true,
      "api_version": "v3"
    },
    "capabilities": {
      "create_node_auth": [],
      "supports_volumes": true,
      "supports_snapshots": true,
      "supports_key_pairs": false,
      "supports_wait_until_running": true
    },
    "status": "active"
  }
}
```

That capability metadata is justified because Libcloud explicitly documents feature differences and operation availability across drivers. [libcloud.apache](https://libcloud.apache.org/blog/)

## Revised connection onboarding

Since you want secrets server-side in `.env`, there are two valid onboarding patterns.

### Pattern A: Admin-preprovisioned
An operator edits `.env` or a stronger secret backend and deploys the service with:
- `LIBCLOUD_AWS_PROD_KEY`
- `LIBCLOUD_AWS_PROD_SECRET`
- `LIBCLOUD_NTNX_LAB_USER`
- `LIBCLOUD_NTNX_LAB_PASSWORD` [pypi](https://pypi.org/project/python-dotenv/)

Then an admin calls:

`POST /v1/connections`

```json
{
  "id": "conn_aws_prod_sg",
  "provider": "aws",
  "name": "aws-prod-singapore",
  "auth_binding": {
    "key_env": "LIBCLOUD_AWS_PROD_KEY",
    "secret_env": "LIBCLOUD_AWS_PROD_SECRET"
  },
  "config": {
    "region": "ap-southeast-1",
    "secure": true
  }
}
```

The API validates only that the env variable names exist and are readable by the service. The actual secret values remain invisible. [pypi](https://pypi.org/project/python-dotenv/)

### Pattern B: Bootstrap import
Allow a one-time admin-only bootstrap endpoint that accepts cleartext secret material only over TLS and immediately writes it into the secret backend, never storing it in application tables. This is more flexible, but it contradicts your stated preference for `.env`-only server-side storage, so Pattern A is the cleaner fit.

## Compute API redesign

The compute endpoints remain mostly the same, but every mutating request must reference a `connection_id` rather than embedding provider credentials. Libcloud’s compute methods already operate from a driver object initialized with server-side credentials, so the request contract only needs resource selections and operation parameters. [libcloud.apache](https://libcloud.apache.org/blog/)

Example node create request:

```json
{
  "connection_id": "conn_aws_prod_sg",
  "name": "web-01",
  "size": {
    "id": "t3.medium"
  },
  "image": {
    "id": "ami-1234"
  },
  "location": {
    "id": "ap-southeast-1a"
  },
  "auth": {
    "type": "ssh_key",
    "public_key": "ssh-rsa AAAAB3Nza..."
  },
  "network": {
    "public_ip": true,
    "subnet_id": "subnet-123"
  },
  "tags": {
    "env": "dev",
    "owner": "platform"
  },
  "provider_options": {
    "ex_securitygroup": "sg-123"
  },
  "execution": {
    "mode": "async",
    "wait_until_running": true,
    "timeout_seconds": 900
  }
}
```

This request is safe because it contains no provider API secret. The only secret-like field that may still appear is an optional initial node password when using Libcloud `NodeAuthPassword`, but even that should be discouraged or tightly controlled because Libcloud documents password-based create-node auth and generated-password behavior, including passwords surfacing in `extra['password']`. [libcloud.apache](https://libcloud.apache.org/blog/)

### Recommended policy on node auth
Prefer:
1. `ssh_key`
2. provider-managed key pair references
3. password only when provider constraints require it [libcloud.apache](https://libcloud.apache.org/blog/)

If password auth is allowed:
- accept it only over TLS,
- never log it,
- never echo it back,
- redact it from job payload history,
- optionally support a secret reference instead of inline password.

## Async and sync behavior

The sync and async model should stay, but now every job also records the authenticated principal, token ID, and connection authorization context. Long-running Libcloud operations such as `create_node`, `deploy_node`, and `wait_until_running` should execute outside the event loop, because Libcloud methods are synchronous and FastAPI’s async model does not make blocking provider calls non-blocking by itself. [libcloud.apache](https://libcloud.apache.org/blog/)

Recommended modes:
- Reads: sync.
- Small writes: sync or async.
- Infrastructure creates, deploys, deletes, snapshots, and wait loops: async by default. [libcloud.apache](https://libcloud.apache.org/blog/)

Job record fields should include:
- `id`
- `operation`
- `status`
- `requested_by`
- `token_jti`
- `connection_id`
- `provider`
- `scope_snapshot`
- `request_payload_redacted`
- `progress`
- `result_resource_id`
- `error_code`
- `submitted_at`
- `started_at`
- `completed_at` [libcloud.apache](https://libcloud.apache.org/blog/)

Redaction matters because request payloads may include SSH public keys, deployment scripts, or optional node passwords.

## Error and response contract

Keep all responses JSON and all errors structured. Add security-specific error codes:
- `auth_invalid_token`
- `auth_expired_token`
- `auth_insufficient_scope`
- `auth_connection_denied`
- `secret_binding_missing`
- `secret_binding_invalid`
- `provider_operation_failed`
- `provider_capability_unsupported` [github](https://github.com/fastapi/fastapi/discussions/11210)

Example:

```json
{
  "error": {
    "code": "auth_connection_denied",
    "message": "Token is not authorized to use the requested connection",
    "details": {
      "connection_id": "conn_aws_prod_sg",
      "required_scope": "compute:node:create"
    }
  },
  "meta": {
    "request_id": "req_01J..."
  }
}
```

## Operational hardening

You should add several hardening rules:
- Use HTTPS only.
- Use short access token TTL and enforce refresh. [github](https://github.com/fastapi/fastapi/discussions/11210)
- Rotate JWT signing keys regularly; FastAPI’s JWT example shows a secret signing key and explicit expiry handling, which should be externalized to environment-based configuration in production. [pypi](https://pypi.org/project/python-dotenv/)
- Support token revocation by `jti`.
- Record full audit trails for login, token refresh, node create, delete, power actions, and connection use.
- Mask secrets in logs, traces, and exception messages.
- Validate provider-specific `ex_*` arguments against an allowlist per provider.
- Prefer RS256 or ES256 if you want key rotation and verifier separation instead of a shared symmetric key; FastAPI’s docs note PyJWT support for asymmetric algorithms through `pyjwt[crypto]`. [github](https://github.com/fastapi/fastapi/discussions/11210)

## Recommended endpoint set

A strong v1 set is:

- `POST /v1/auth/login`
- `POST /v1/auth/refresh`
- `POST /v1/auth/logout`
- `GET /v1/auth/me`
- `GET /v1/providers`
- `GET /v1/connections`
- `GET /v1/connections/{id}`
- `POST /v1/connections`
- `POST /v1/connections/{id}:test`
- `GET /v1/compute/locations`
- `GET /v1/compute/images`
- `GET /v1/compute/sizes`
- `GET /v1/compute/nodes`
- `POST /v1/compute/nodes`
- `GET /v1/compute/nodes/{id}`
- `POST /v1/compute/nodes/{id}:start`
- `POST /v1/compute/nodes/{id}:stop`
- `POST /v1/compute/nodes/{id}:reboot`
- `DELETE /v1/compute/nodes/{id}`
- `POST /v1/compute/volumes`
- `POST /v1/compute/volumes/{id}:attach`
- `POST /v1/compute/volumes/{id}:detach`
- `POST /v1/compute/key-pairs`
- `GET /v1/jobs/{id}` [libcloud.apache](https://libcloud.apache.org/blog/)

## Design decisions

The revised specification should therefore adopt these rules:
- Provider secrets live only on the server, ideally in `.env` or a stronger secret backend, never in routine client payloads. [pypi](https://pypi.org/project/python-dotenv/)
- JWT or session tokens are short-lived authorization artifacts, not encrypted secret carriers. [github](https://github.com/fastapi/fastapi/discussions/11210)
- Every request references a named `connection_id`, and the server resolves credentials internally before creating the Libcloud driver. [libcloud.apache](https://libcloud.apache.org/blog/)
- Access is enforced by scopes plus per-connection authorization. [github](https://github.com/fastapi/fastapi/discussions/11210)
- Async jobs are first-class for long-running Libcloud operations such as create, deploy, and wait-until-running. [libcloud.apache](https://libcloud.apache.org/blog/)
