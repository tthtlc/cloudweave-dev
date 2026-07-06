# Libcloud REST API — Complete Reference

> **Generated:** 2026-06-25  
> **Project:** `libcloud.rest` — FastAPI REST wrapper for Apache Libcloud Nutanix & AWS drivers

---

## Table of Contents

1. [Project File Map](#project-file-map)
2. [Architecture Overview](#architecture-overview)
3. [HTTP Conventions](#http-conventions)
4. [Authentication & Authorization](#authentication--authorization)
   - [Authentik OIDC Integration](#authentik-oidc-integration)
   - [OpenFGA Fine-Grained Authorization](#openfga-fine-grained-authorization)
   - [Updates Required When Introducing New OpenFGA Objects](#updates-required-when-introducing-new-openfga-objects)
5. [API Endpoint Tables](#api-endpoint-tables)
   - [Auth APIs](#1-auth-apis)
   - [Provider API](#2-provider-api)
   - [Connection APIs](#3-connection-apis)
   - [Compute APIs](#4-compute-apis)
   - [Network APIs](#5-network-apis)
   - [Job API](#6-job-api)
   - [Health API](#7-health-api)
6. [Libcloud Driver Redirection Map](#libcloud-driver-redirection-map)
7. [Provider-Specific `provider_options` Allowlists](#provider-specific-provider_options-allowlists)
8. [Full Scope Reference](#full-scope-reference)
9. [Credential Verification Flow (End-to-End)](#credential-verification-flow-end-to-end)

---

## Project File Map

### Roles and Purpose of Each Python File

#### `app/` — Core Application Package

| File | Role |
|---|---|
| `app/main.py` | **Application entry point.** Creates the FastAPI app, registers `RequestIDMiddleware`, mounts all routers (auth, providers, connections, compute, network, jobs), and defines `/health`. |

#### `app/auth/` — Authentication & Authorization

| File | Role |
|---|---|
| `app/auth/models.py` | **Pydantic models** for auth domain: `LoginRequest`, `RefreshRequest`, `IntrospectRequest`, `TokenResponse`, `UserRecord`, `TokenClaims`. Defines the shape of JWT tokens and user records. |
| `app/auth/service.py` | **Local JWT AuthService.** Handles login, token refresh, logout, JWT signing/verification (HS256), user bootstrap from `data/users.json`, password hashing (argon2id), and JTI revocation set. Singleton: `auth_service`. |
| `app/auth/oidc_service.py` | **Authentik OIDC token verification.** `OidcAuthService` decodes tokens from Authentik: auto-detects RS/ES (JWKS) vs HS (shared secret) algorithms, maps OIDC `preferred_username` to libcloud scopes via `USERNAME_SCOPES` and `USERNAME_PROVIDERS` lookup tables. Singleton: `oidc_auth_service`. |
| `app/auth/fga_client.py` | **OpenFGA client.** `FgaClient` calls the OpenFGA `/check` API to evaluate relationship tuples (`user:name`, `relation`, `object:id`). Provides `check()` (boolean) and `require()` (raises on deny). Singleton via `get_fga_client()`. |
| `app/auth/policy.py` | **Policy engine.** `PolicyEngine` combines JWT scope validation, provider allowlists, and OpenFGA authorization. `authorize_connection()` is the single entry point called by every compute/network route handler. Also checks driver capabilities. Singleton: `policy_engine`. |
| `app/auth/dependencies.py` | **FastAPI dependency injection.** Provides `get_current_claims()` (extracts and validates Bearer token, dispatches to `auth_service` or `oidc_auth_service` based on `auth_mode`), `require_scopes()` (all scopes required), and `require_any_scopes()` (at least one scope required). Supports `local`, `oidc`, and `hybrid` auth modes. |
| `app/auth/routes.py` | **Auth REST endpoints.** Defines `POST /v1/auth/login`, `POST /v1/auth/refresh`, `POST /v1/auth/logout`, `GET /v1/auth/me`, `POST /v1/auth/token/introspect`. |

#### `app/common/` — Shared Infrastructure

| File | Role |
|---|---|
| `app/common/errors.py` | **Error handling.** `APIError` exception class (code, message, status_code, details), `error_response()` helper, and `api_error_handler` FastAPI exception handler that renders the standard error envelope. |
| `app/common/middleware.py` | **Request ID middleware.** `RequestIDMiddleware` reads `X-Request-ID` from the request header (generates `req_<12 hex>` if missing), stores it on `request.state.request_id`, and echoes it back in the response header. |
| `app/common/responses.py` | **Success response helper.** `success_response(data, request)` wraps any payload in `{\"data\": ..., \"meta\": {\"request_id\": ...}}`. |

#### `app/config/` — Configuration

| File | Role |
|---|---|
| `app/config/settings.py` | **Pydantic Settings.** Loads from `.env` file and environment variables. Defines all configuration: JWT secrets/TTLs, admin credentials, `auth_mode`, OIDC parameters (issuer URL, JWKS URL, client secret), OpenFGA parameters (API URL, store ID, model ID, FGA object names), and AWS image filter default. Singleton via `get_settings()`. |

#### `app/connections/` — Provider Connection Management

| File | Role |
|---|---|
| `app/connections/models.py` | **Connection domain models.** `ProviderConnection` (provider + config + credentials), `ConnectionConfig`, `ConnectionCredentials`, `ConnectionCapabilities`, `ALL_SCOPES` constant. Also `connection_target()` helper that normalizes a connection into a stable target string like `aws:us-east-1` or `nutanix:host:9440`. |
| `app/connections/dependencies.py` | **Connection query parser.** `parse_connection_query()` FastAPI dependency that URL-decodes and validates the `connection` query parameter into a `ProviderConnection` for GET/DELETE endpoints. |
| `app/connections/routes.py` | **Connection REST endpoint.** Defines `POST /v1/connections:test` which builds a driver from a client-supplied connection and returns capabilities. |

#### `app/compute/` — Compute Resource Services

| File | Role |
|---|---|
| `app/compute/models.py` | **Compute Pydantic models.** All request/response schemas: `NodeCreateRequest`, `NodeUpdateRequest`, `VolumeCreateRequest`, `VolumeUpdateRequest`, `VolumeAttachRequest`, `SnapshotCreateRequest`, `ImageCreateRequest`, `KeyPairCreateRequest`, `ExecutionOptions`, and response types (`NodeResponse`, `VolumeResponse`, `SnapshotResponse`, `ImageResponse`, `SizeResponse`, `LocationResponse`, `KeyPairResponse`). |
| `app/compute/routes.py` | **Compute REST endpoints.** Defines all `/v1/compute/*` routes: nodes (CRUD + start/stop/reboot), volumes (CRUD + attach/detach), snapshots (CRUD), images (create/delete), key pairs (CRUD), locations, sizes. Every handler calls `policy_engine.authorize_connection()` as the first authorization gate, then delegates to `compute_service`. |
| `app/compute/service.py` | **Compute business logic.** `ComputeService` class with methods for every compute operation. Builds libcloud drivers via `build_driver()`, translates REST request models into libcloud calls, serializes libcloud objects into response models. Contains `_filter_provider_options()` allowlists (AWS and Nutanix `ex_*` keys), `_build_auth()` (SSH key / password), and helper functions for resolving sizes, locations, subnets, and security groups. Singleton: `compute_service`. |

#### `app/network/` — Network Resource Services

| File | Role |
|---|---|
| `app/network/__init__.py` | Package marker (empty). |
| `app/network/models.py` | **Network Pydantic models.** Request schemas: `NetworkCreateRequest`, `NetworkUpdateRequest`, `SubnetCreateRequest`, `SubnetUpdateRequest`, `SecurityGroupCreateRequest`, `LoadBalancerCreateRequest`. |
| `app/network/routes.py` | **Network REST endpoints.** Defines all `/v1/compute/*` network routes: networks/VPCs (CRUD), subnets (CRUD), storage containers (list), security groups (CRUD), load balancers (CRUD). Every handler calls `policy_engine.authorize_connection()`. |
| `app/network/service.py` | **Network business logic.** `NetworkService` class with methods for every network operation. Handles provider-specific dispatch (Nutanix VPCs vs AWS VPCs), serialization helpers (`_serialize_network`, `_serialize_subnet`, `_serialize_sg`, `_serialize_lb`, `_serialize_storage`), and resource ID/name extraction from both dicts and objects. Singleton: `network_service`. |

#### `app/providers/` — Libcloud Driver Management

| File | Role |
|---|---|
| `app/providers/factory.py` | **Driver factory.** `build_driver(connection)` dispatches to the correct driver creator based on `connection.provider`. `probe_capabilities(driver)` inspects a driver instance for features (volumes, snapshots, key pairs, wait_until_running). `test_connection(connection)` validates a connection by calling `list_locations()`. |
| `app/providers/aws.py` | **AWS driver factory.** `create_aws_driver(key, secret, config)` instantiates the libcloud EC2 driver (`Provider.EC2`) with region and secure flag. |
| `app/providers/nutanix.py` | **Nutanix driver factory.** `create_nutanix_driver(key, secret, config)` instantiates `NutanixNodeDriver` with host, port, secure, api_version, and verify_ssl_cert. |
| `app/providers/routes.py` | **Provider discovery endpoint.** Defines `GET /v1/providers` returning a static list of supported providers (aws, nutanix) with their supported operations. |

#### `app/jobs/` — Async Job Execution

| File | Role |
|---|---|
| `app/jobs/routes.py` | **Job polling endpoint.** Defines `GET /v1/jobs/{job_id}` with ownership check (requesting user must match, or admin scope required). |
| `app/jobs/worker.py` | **Async job infrastructure.** `JobStore` (in-memory job registry), `JobWorker` (ThreadPoolExecutor with 4 workers), `JobRecord` model, and `redact_payload()` (strips secrets/passwords/keys from stored payloads). Singletons: `job_store`, `job_worker`. |

#### `clients/` — Example CLI Client Applications

| File | Role |
|---|---|
| `clients/common/api.py` | **Shared REST client library.** `LibcloudRestClient` class with login, auto-injection of connection objects, and HTTP methods (`get`, `post`, `patch`, `delete`). Handles token lifecycle. |
| `clients/common/connection.py` | **Client-side connection builders.** `aws_connection()` and `nutanix_connection()` build provider connection dicts from env vars (`LIBCLOUD_AWS_PROD_KEY`, `LIBCLOUD_NTNX_LAB_USER`, etc.). `encode_connection()` URL-encodes for GET/DELETE query params. |
| `clients/aws_client.py` | **AWS CLI client.** Mirrors EC2, VPC, subnet, and EBS storage operations via the REST API. Subcommands: `ec2 list/provision/edit/destroy`, `vpc list/provision/edit/destroy`, `subnet list/provision/edit/destroy`, `storage list/provision/edit/destroy`. |
| `clients/demo1_client.py` | **Nutanix CLI client (basic).** Mirrors Nutanix VM, VPC, subnet, and storage container operations. Subcommands: `vm list/provision/edit/destroy`, `vpc list/provision/edit/destroy`, `subnet list/provision/edit/destroy`, `storage list/provision/edit/destroy`. |
| `clients/demo2_client.py` | **Nutanix CLI client (extended).** Adds volumes, snapshots, images, security groups, and load balancers on top of demo1. Also includes cluster/size listing and advanced VM provisioning with disk/storage/user-data options. |
| `clients/list_us_east_nodes.py` | **Minimal AWS listing script.** Connects to us-east-1, logs in with `compute:read` scope, and lists all nodes. |

### Function Reference by File

#### `app/auth/service.py` — AuthService

| Function / Method | Signature | Description |
|---|---|---|
| `__init__` | `() -> None` | Initializes in-memory user store, refresh token dict, JTI revocation set, and audit log. Calls `_bootstrap_users()`. |
| `_bootstrap_users` | `() -> None` | Loads users from `data/users.json` on first start, or creates admin user from env vars. Ensures admin always has `ALL_SCOPES`. |
| `_persist_users` | `() -> None` | Writes current user records to `data/users.json`. |
| `verify_password` | `(plain: str, hashed: str) -> bool` | Verifies a plaintext password against an argon2id hash via passlib. |
| `login` | `(request: LoginRequest) -> TokenResponse` | Validates credentials, intersects requested scopes with user scopes, signs a JWT access token (HS256), generates an opaque refresh token, and stores it in memory. |
| `refresh` | `(refresh_token: str) -> TokenResponse` | Validates refresh token existence and expiry, issues a new access token. |
| `logout` | `(refresh_token: str \| None, jti: str \| None) -> None` | Revokes the access token JTI and optionally deletes the refresh token. |
| `decode_access_token` | `(token: str) -> TokenClaims` | Verifies JWT signature, expiry, audience, issuer, and checks JTI revocation set. Returns `TokenClaims` on success. |
| `introspect` | `(token: str) -> dict` | Decodes a token and returns its claims as a dict (RFC 7662-style). |

#### `app/auth/oidc_service.py` — OidcAuthService

| Function / Method | Signature | Description |
|---|---|---|
| `__init__` | `() -> None` | Initializes with no JWKS client (lazy). |
| `_client` | `() -> PyJWKClient` | Lazily creates a `PyJWKClient` pointed at `settings.oidc_jwks_url` (Authentik's JWKS endpoint). |
| `_looks_like_oidc_token` | `(token: str) -> bool` | Heuristic: checks if token uses asymmetric alg (RS/ES/PS) or if HS alg + issuer matches OIDC issuer. Used in hybrid mode to route decoding. |
| `_decode_with_jwks` | `(token: str, settings) -> dict` | Fetches the signing key from JWKS endpoint and decodes the token. Used for RS256/ES256 Authentik tokens. |
| `_decode_with_client_secret` | `(token: str, settings) -> dict` | Decodes HS256 tokens using the shared OIDC client secret. Used when Authentik is configured with symmetric signing. |
| `decode_access_token` | `(token: str) -> TokenClaims` | **Main entry point.** Auto-detects algorithm, decodes token, maps `preferred_username` to libcloud scopes and allowed providers via lookup tables. |

#### `app/auth/fga_client.py` — FgaClient

| Function / Method | Signature | Description |
|---|---|---|
| `__init__` | `() -> None` | Reads FGA configuration from settings (`fga_api_url`, `fga_store_id`, `fga_model_id`). |
| `enabled` (property) | `() -> bool` | Returns `True` only if `fga_enabled` is set AND store/model IDs are configured. |
| `check` | `(user: str, relation: str, obj: str) -> bool` | Calls `POST /stores/{store_id}/check` on the OpenFGA API. Returns `True` if the relationship tuple is allowed. Returns `True` always when FGA is disabled. |
| `require` | `(user: str, relation: str, obj: str) -> None` | Calls `check()` and raises `authz_fga_denied` if not allowed. |
| `get_fga_client` | `() -> FgaClient` | Module-level singleton factory. |

#### `app/auth/policy.py` — PolicyEngine

| Function / Method | Signature | Description |
|---|---|---|
| `_token_has_scope` | `(token_scopes: set[str], required_scope: str) -> bool` | Checks if token includes the required scope, also resolves `compute:read` aliases. |
| `_fga_user` | `(claims: TokenClaims) -> str` | Formats token claims into FGA user string: `user:<username>`. |
| `_backend_object` | `(connection: ProviderConnection) -> str` | Maps a connection to an FGA object: `nutanix_cluster:<cluster>` or `aws_region:<region>`. |
| `_enforce_openfga` | `(claims, connection, required_scope) -> None` | **OpenFGA enforcement pipeline.** Checks three FGA tuples in sequence: `can_connect` on the API object, `can_use` on the provider, and `can_provision`/`can_read` on the backend. Write/manage scopes require `can_provision`. |
| `authorize_connection` | `(claims, connection, required_scope) -> ProviderConnection` | **Main authorization gate.** Validates JWT scopes, provider allowlists, and runs OpenFGA enforcement. Returns the connection on success. Called by every resource route handler. |
| `check_driver_capability` | `(connection, operation) -> None` | Builds a driver, probes capabilities, and raises `provider_capability_unsupported` if the provider doesn't support the requested operation. |

#### `app/auth/dependencies.py` — FastAPI Dependencies

| Function | Signature | Description |
|---|---|---|
| `_decode_token` | `(token: str) -> TokenClaims` | Dispatches to `auth_service` (local), `oidc_auth_service` (oidc), or hybrid mode (tries OIDC first, falls back to local). |
| `get_current_claims` | `(credentials: HTTPAuthorizationCredentials \| None) -> TokenClaims` | FastAPI dependency. Extracts Bearer token from `Authorization` header, delegates to `_decode_token()`. |
| `require_scopes` | `(*required_scopes: str) -> Callable` | Factory returning a FastAPI dependency that requires ALL specified scopes. |
| `require_any_scopes` | `(*accepted_scopes: str) -> Callable` | Factory returning a FastAPI dependency that requires AT LEAST ONE of the specified scopes. |

#### `app/compute/service.py` — ComputeService

| Function / Method | Signature | Description |
|---|---|---|
| `_filter_provider_options` | `(provider: str, options: dict) -> dict` | Filters a `provider_options` dict against provider-specific allowlists (`AWS_ALLOWED_EX` / `NUTANIX_ALLOWED_EX`). |
| `_serialize_node` | `(node: Node, connection: ProviderConnection) -> NodeResponse` | Converts a libcloud `Node` to `NodeResponse`. Redacts the `password` key from extras. |
| `_find_size` | `(driver, size_id: str) -> NodeSize` | Looks up a size/instance-type by ID from the driver. Raises 404 if not found. |
| `_find_location` | `(driver, connection, location_id: str) -> NodeLocation` | Looks up a location (or Nutanix cluster) by ID. Falls back to `list_locations()` for AWS. |
| `_resolve_subnet` | `(driver, connection, subnet_id: str) -> Any` | Resolves a subnet ID to a subnet object for AWS, returns string for Nutanix. |
| `_resolve_aws_security_group_kwargs` | `(driver, subnet_id, security_group) -> dict` | Maps REST security group name to EC2 `SecurityGroupId` when a subnet (VPC) is present to avoid `InvalidParameterCombination`. |
| `_build_auth` | `(request: NodeCreateRequest) -> NodeAuthSSHKey \| NodeAuthPassword \| None` | Converts REST auth config into libcloud auth objects. |
| `list_nodes` | `(connection, node_id?) -> list[NodeResponse]` | Lists all nodes or filters by ID. Uses `ex_get_node` when available, falls back to filtering `list_nodes()`. |
| `get_node` | `(connection, node_id) -> NodeResponse` | Gets a single node by ID. Raises 404 if not found. |
| `create_node` | `(connection, request: NodeCreateRequest) -> NodeResponse` | **Creates a VM.** Resolves size/location/image, builds auth, network config, tags, provider options, then calls `driver.create_node(**kwargs)`. Optionally waits for running state. |
| `destroy_node` | `(connection, node_id) -> dict` | Destroys a node by ID. |
| `power_node` | `(connection, node_id, action) -> dict` | Starts, stops, or reboots a node. |
| `update_node` | `(connection, node_id, request) -> dict` | Updates a node: resize (AWS), tag (both), or update name/description/memory (Nutanix). |
| `_get_driver_node` | `(driver, connection, node_id) -> Node` | Internal helper: gets a libcloud `Node` object by ID using `ex_get_node` or filtering. |
| `list_images` | `(connection, owner?, filters?) -> list[ImageResponse]` | Lists images. Applies AWS `ex_filters` (default name filter `*Ubuntu*` from settings) and optional `ex_owner`. |
| `list_sizes` | `(connection) -> list[SizeResponse]` | Lists instance types/sizes. |
| `list_locations` | `(connection) -> list[LocationResponse]` | Lists locations (AWS regions/AZs) or Nutanix clusters via `ex_list_clusters()`. |
| `create_volume` | `(connection, request: VolumeCreateRequest) -> VolumeResponse` | Creates a storage volume with optional snapshot restore. |
| `list_volumes` | `(connection, volume_id?) -> list[VolumeResponse]` | Lists volumes, optionally filtered by ID. |
| `_serialize_volume` | `(volume) -> VolumeResponse` | Converts a libcloud volume to response model. |
| `destroy_volume` | `(connection, volume_id) -> dict` | Destroys a volume by ID. |
| `update_volume` | `(connection, volume_id, request) -> dict` | Modifies (AWS: `ex_modify_volume`) or tags a volume. |
| `attach_volume` | `(connection, request, volume_id) -> dict` | Attaches a volume to a node, optionally with a device path. |
| `detach_volume` | `(connection, request, volume_id) -> dict` | Detaches a volume. Nutanix requires `ex_vm_ext_id`; AWS uses `detach_volume(volume)`. |
| `create_snapshot` | `(connection, request: SnapshotCreateRequest) -> SnapshotResponse` | Creates a volume snapshot. |
| `list_snapshots` | `(connection, volume_id?, snapshot_id?) -> list[SnapshotResponse]` | Lists snapshots by volume, by ID, or all. |
| `destroy_snapshot` | `(connection, snapshot_id, volume_id?) -> dict` | Destroys a snapshot by ID. |
| `_serialize_snapshot` | `(snap, volume_id?) -> SnapshotResponse` | Converts a libcloud snapshot to response model. |
| `create_image` | `(connection, request: ImageCreateRequest) -> ImageResponse` | Creates an image from URL (`ex_create_image_from_url`, Nutanix) or from VM (`create_image`, Nutanix). |
| `destroy_image` | `(connection, image_id) -> dict` | Deletes an image by ID. |
| `list_key_pairs` | `(connection) -> list[KeyPairResponse]` | Lists SSH key pairs (AWS only). |
| `delete_key_pair` | `(connection, name) -> dict` | Deletes a key pair by name (AWS only). |
| `create_key_pair` | `(connection, request: KeyPairCreateRequest) -> KeyPairResponse` | Creates or imports a key pair (AWS only). |

#### `app/network/service.py` — NetworkService

| Function / Method | Signature | Description |
|---|---|---|
| `_resource_id` | `(obj: Any) -> str` | Extracts resource ID from a libcloud object or dict (tries `extId`, `ext_id`, `id`). |
| `_resource_name` | `(obj: Any) -> str \| None` | Extracts resource name from a libcloud object or dict. |
| `_extra` | `(obj: Any) -> dict` | Extracts extra metadata dict from a libcloud object or dict. |
| `_serialize_network` | `(obj, connection) -> dict` | Serializes a VPC/network object to a response dict. |
| `_serialize_subnet` | `(obj, connection) -> dict` | Serializes a subnet object to a response dict. |
| `list_networks` | `(connection, network_id?, is_default?) -> list[dict]` | Lists networks/VPCs. Uses `ex_get_vpc` (Nutanix) or `ex_list_networks` (AWS) for single lookup, `ex_list_vpcs` or `ex_list_networks` for listing. |
| `create_network` | `(connection, request: NetworkCreateRequest) -> dict` | Creates a VPC: `ex_create_vpc` (Nutanix) or `ex_create_network` (AWS). |
| `update_network` | `(connection, network_id, request: NetworkUpdateRequest) -> dict` | Updates name/description (Nutanix) or tags (both). |
| `destroy_network` | `(connection, network_id) -> dict` | Deletes a VPC: `ex_delete_vpc` (Nutanix) or `ex_delete_network` (AWS). |
| `list_subnets` | `(connection, subnet_id?, vpc_id?) -> list[dict]` | Lists subnets with optional filtering by ID or VPC. |
| `create_subnet` | `(connection, request: SubnetCreateRequest) -> dict` | Creates a subnet: Nutanix (`ex_create_subnet` with VLAN/OVERLAY, cluster, etc.) or AWS (`ex_create_subnet` with VPC, CIDR, AZ). |
| `update_subnet` | `(connection, subnet_id, request: SubnetUpdateRequest) -> dict` | Updates a subnet: tag, NAT toggle, name/description (Nutanix), or `mapPublicIpOnLaunch`/`assignIpv6AddressOnCreation` (AWS). |
| `destroy_subnet` | `(connection, subnet_id) -> dict` | Deletes a subnet by ID. |
| `list_storage_containers` | `(connection, container_id?) -> list[dict]` | Lists Nutanix storage containers with VMM API fallback to legacy API. |
| `_serialize_storage` | `(obj, connection) -> dict` | Serializes a storage container to response dict. |
| `list_security_groups` | `(connection, group_id?, vpc_id?) -> list[dict]` | Lists security groups. Supports AWS `ex_get_security_groups` and Nutanix `ex_list_security_groups`. |
| `create_security_group` | `(connection, request: SecurityGroupCreateRequest) -> dict` | Creates a security group (Nutanix: `ex_create_security_group`, AWS: same with different params). |
| `destroy_security_group` | `(connection, group_id) -> dict` | Deletes a security group by ID. |
| `_serialize_sg` | `(obj, connection) -> dict` | Serializes a security group to response dict. |
| `list_load_balancers` | `(connection, lb_id?) -> list[dict]` | Lists load balancers (Nutanix only). |
| `create_load_balancer` | `(connection, request: LoadBalancerCreateRequest) -> dict` | Creates a load balancer in a Nutanix VPC. |
| `destroy_load_balancer` | `(connection, lb_id) -> dict` | Deletes a load balancer by ID. |
| `_serialize_lb` | `(obj, connection) -> dict` | Serializes a load balancer to response dict. |

#### `app/providers/factory.py` — Driver Factory

| Function | Signature | Description |
|---|---|---|
| `build_driver` | `(connection: ProviderConnection) -> NodeDriver` | **Main driver factory.** Dispatches to `create_aws_driver()` or `create_nutanix_driver()` based on `connection.provider`. |
| `probe_capabilities` | `(driver: NodeDriver) -> ConnectionCapabilities` | Inspects a driver for available features (create_node auth types, volumes, snapshots, key pairs, wait_until_running). |
| `test_connection` | `(connection: ProviderConnection) -> dict` | Validates a connection by calling `list_locations()` and probing capabilities. Returns connection status and capabilities. |

#### `app/providers/aws.py`

| Function | Signature | Description |
|---|---|---|
| `create_aws_driver` | `(key: str, secret: str, config: ConnectionConfig) -> NodeDriver` | Instantiates the libcloud EC2 driver with the given credentials, region, and secure flag. |

#### `app/providers/nutanix.py`

| Function | Signature | Description |
|---|---|---|
| `create_nutanix_driver` | `(key: str, secret: str, config: ConnectionConfig) -> NutanixNodeDriver` | Instantiates `NutanixNodeDriver` with host, port, secure, api_version, and verify_ssl_cert. |

#### `app/jobs/worker.py` — Async Jobs

| Function / Method | Signature | Description |
|---|---|---|
| `redact_payload` | `(payload: dict) -> dict` | Deep-copies a payload and redacts sensitive keys (`password`, `secret`, `key`, `private_key`, `public_key`) and entire `credentials` sub-objects to `***REDACTED***`. |
| `JobStore.create` | `(**kwargs) -> JobRecord` | Creates a new job record with a unique `job_<16 hex>` ID and current timestamp. |
| `JobStore.get` | `(job_id: str) -> JobRecord` | Retrieves a job by ID. Raises 404 if not found. |
| `JobStore.update` | `(job_id: str, **kwargs) -> JobRecord` | Updates fields on an existing job record. |
| `JobWorker.submit` | `(operation, fn, *, requested_by, ...) -> JobRecord` | Creates a job record with redacted payload, submits `fn` to the thread pool for async execution. |
| `JobWorker._run` | `(job_id: str, fn: Callable) -> None` | Internal: sets job to `running`, executes `fn`, updates to `completed` or `failed` with error details. |

#### `clients/common/api.py` — Shared REST Client

| Function / Method | Signature | Description |
|---|---|---|
| `LibcloudRestClient.__init__` | `(base_url?, username?, password?, connection?) -> None` | Creates a client with config from args or env vars (`LIBCLOUD_REST_URL`, `LIBCLOUD_REST_USER`, `LIBCLOUD_REST_PASSWORD`, `LIBCLOUD_PROVIDER`). |
| `_connection_from_env` | `() -> dict \| None` | Builds connection dict from `LIBCLOUD_PROVIDER` env var (calls `aws_connection()` or `nutanix_connection()`). |
| `login` | `(scopes?) -> dict` | Logs in to the REST API, stores access and refresh tokens. |
| `_headers` | `(auth: bool) -> dict` | Builds HTTP headers with Bearer token (auto-login if no token cached). |
| `_require_connection` | `() -> dict` | Returns the stored connection or raises if missing. |
| `_inject_connection_params` | `(params: dict) -> dict` | Auto-injects URL-encoded `connection` into query params if not present. |
| `_inject_connection_body` | `(body: dict) -> dict` | Auto-injects `connection` object into request body if not present. |
| `_request` | `(method, path, *, params?, json_body?, auth?) -> Any` | **Core HTTP method.** Sends request with timeout, parses JSON response, returns `data` field. |
| `get` | `(path, **params) -> Any` | HTTP GET with auto-injected connection params. |
| `post` | `(path, body?, **params) -> Any` | HTTP POST with auto-injected connection body. |
| `patch` | `(path, body) -> Any` | HTTP PATCH with auto-injected connection body. |
| `delete` | `(path, **params) -> Any` | HTTP DELETE with auto-injected connection params. |
| `print_json` | `(data: Any) -> None` | Pretty-prints JSON to stdout. |

#### `clients/common/connection.py` — Client-Side Connection Helpers

| Function | Signature | Description |
|---|---|---|
| `aws_connection` | `(*, key?, secret?, region?) -> dict` | Builds an AWS provider connection dict from args or env vars (`LIBCLOUD_AWS_PROD_KEY`, `LIBCLOUD_AWS_PROD_SECRET`, `AWS_DEFAULT_REGION`). |
| `nutanix_connection` | `(*, key?, secret?, host?, port?, api_version?, verify_ssl_cert?) -> dict` | Builds a Nutanix provider connection dict from args or env vars (`LIBCLOUD_NTNX_LAB_USER`, `LIBCLOUD_NTNX_LAB_PASSWORD`, `NUTANIX_HOST`, etc.). |
| `encode_connection` | `(connection: dict) -> str` | JSON-serializes and URL-encodes a connection dict for use as a GET/DELETE query parameter. |

---

## Architecture Overview

```
┌──────────────┐  JWT + connection   ┌───────────────────────────────────────┐     libcloud      ┌─────────────────┐
│   Client     │ ──────────────────> │  libcloud.rest (FastAPI)              │ ────────────────> │  Nutanix Prism  │
│ (CLI / curl) │ <── JSON response   │                                       │                   │  Central / AWS  │
└──────────────┘                     │  ┌──────────┐  ┌──────────┐  ┌──────┐ │ <──────────────── │                 │
       │                             │  │ Auth     │  │ Policy   │  │ Prov │ │   libcloud        └─────────────────┘
       │  connection object          │  │ Service  │─>│ Engine   │─>│ Fact │ │   driver responses
       │  (provider, config,         │  │ (JWT +   │  │ (scopes  │  │ -ory │ │
       │   credentials)              │  │  OIDC)   │  │ + FGA)   │  └──────┘ │
       │                             │  └──────────┘  └──────────┘           │
       │                             │         │             │                │
       │                             │         v             v                │
       │                             │  ┌──────────────────────────┐         │
       │                             │  │ Authentik (OIDC)         │         │
       │                             │  │ OpenFGA (Fine-Grained)   │         │
       │                             │  └──────────────────────────┘         │
       │                             └───────────────────────────────────────┘
```

### Key Design Points

- **Provider credentials are supplied by the client** in a `connection` object on every compute/network call. The server does not store cloud accounts, regions, or provider keys in Docker or on disk.
- **Driver selection** happens in `app/providers/factory.py:build_driver()` — inspects `connection.provider` and calls either `create_aws_driver()` or `create_nutanix_driver()` using `connection.credentials`.
- **All resource operations** go through service classes (`ComputeService`, `NetworkService`) which call the libcloud driver methods.
- **All authorization** flows through `app/auth/policy.py:PolicyEngine.authorize_connection()` which validates JWT scopes, provider allowlists, AND OpenFGA tuples in a single gate.

### Driver Selection Logic (`build_driver`)

```python
# app/providers/factory.py
key, secret = connection.credentials.key, connection.credentials.secret
if connection.provider == "aws":
    return create_aws_driver(key, secret, connection.config)
    # → libcloud.compute.providers.get_driver(Provider.EC2)
elif connection.provider == "nutanix":
    return create_nutanix_driver(key, secret, connection.config)
    # → libcloud.compute.drivers.nutanix.NutanixNodeDriver
```

### Provider Connection Object (`ProviderConnection`)

| Field | Type | Required | Description |
|---|---|---|---|
| `provider` | `"aws"` \| `"nutanix"` | Yes | Cloud provider |
| `config.region` | string | AWS | AWS region (e.g. `us-east-1`) |
| `config.host` | string | Nutanix | Prism Central hostname |
| `config.port` | int | No | Prism Central port (default `9440`) |
| `config.secure` | bool | No | Use HTTPS (default `true`) |
| `config.api_version` | string | No | Nutanix API version (default `v4.0`) |
| `config.verify_ssl_cert` | bool | No | Verify TLS certificate (Nutanix) |
| `credentials.key` | string | Yes | AWS access key ID or Nutanix username |
| `credentials.secret` | string | Yes | AWS secret access key or Nutanix password |

**GET / DELETE:** pass as `connection` query parameter (URL-encoded JSON).  
**POST / PATCH:** include as `"connection": { ... }` in the request body.

---

## HTTP Conventions

### Special Headers

| Header | Direction | Required | Description |
|---|---|---|---|
| **`Authorization: Bearer <JWT>`** | Request | Yes (authenticated endpoints) | JWT access token obtained from `POST /v1/auth/login`. Token expires after 15 minutes. |
| **`Content-Type: application/json`** | Request | Yes (endpoints with body) | All request bodies are JSON. |
| **`X-Request-ID`** | Request | Optional | Client-supplied correlation ID. Echoed back in response `meta.request_id`. If omitted, server generates `req_<12 hex chars>`. |
| **`X-Request-ID`** | Response | Always | Same as request or auto-generated. Also available as `meta.request_id` in the JSON body. |

### Response Envelope (Success)

Every endpoint returns:

```json
{
  "data": { ... },
  "meta": {
    "request_id": "req_abc123"
  }
}
```

`data` contains the endpoint-specific payload. `meta.request_id` is the correlation ID.

### Response Envelope (Error)

```json
{
  "error": {
    "code": "auth_insufficient_scope",
    "message": "Required scope missing: compute:node:create",
    "details": {
      "required_scope": "compute:node:create"
    }
  },
  "meta": {
    "request_id": "req_abc123"
  }
}
```

### Error Codes

| Code | HTTP Status | Meaning |
|---|---|---|
| `auth_invalid_token` | 401 | Missing, malformed, or revoked bearer token |
| `auth_expired_token` | 401 | Token has expired |
| `auth_invalid_credentials` | 401 | Wrong username or password |
| `auth_insufficient_scope` | 403 | Token lacks required scope |
| `auth_provider_denied` | 403 | Token not authorized for the requested provider |
| `auth_misconfigured` | 500 | OIDC/JWKS/issuer configuration missing or wrong |
| `auth_user_unknown` | 403 | OIDC user not mapped to any libcloud role |
| `authz_fga_denied` | 403 | OpenFGA denied the requested action |
| `authz_fga_error` | 503 | OpenFGA check returned an error |
| `authz_fga_unavailable` | 503 | OpenFGA service unreachable |
| `invalid_connection` | 400 | Malformed or missing `connection` query parameter or body field |
| `resource_not_found` | 404 | Resource (node, volume, image, etc.) not found |
| `resource_conflict` | 409 | Resource already exists |
| `validation_error` | 400 | Missing/incorrect required fields |
| `provider_operation_failed` | 502 | Libcloud driver call failed (upstream error) |
| `provider_capability_unsupported` | 400 | Operation not supported by this provider/driver |

---

## Authentication & Authorization

### Auth Modes

The system supports three authentication modes, configured via `auth_mode` in `.env`:

| Mode | Description | Token Verification |
|---|---|---|
| `local` | Uses the built-in `AuthService` with users stored in `data/users.json`. Passwords hashed with argon2id. JWT signed with HS256. | `app/auth/service.py:AuthService.decode_access_token()` |
| `oidc` | Delegates to Authentik (or any OIDC provider). Tokens are issued by Authentik and verified against its JWKS endpoint or shared client secret. | `app/auth/oidc_service.py:OidcAuthService.decode_access_token()` |
| `hybrid` | Accepts both local and OIDC tokens. Uses heuristics (`_looks_like_oidc_token`) to detect token type: RS/ES/PS alg tokens → OIDC; HS alg tokens with matching issuer → OIDC; otherwise → local. | Dispatched in `app/auth/dependencies.py:_decode_token()` |

### Authentik OIDC Integration

**How Authentik tokens are verified (end-to-end):**

1. **Token Acquisition:** The client obtains a token from Authentik directly (e.g., via Authentik's OAuth2/OIDC flow). The REST API does not proxy Authentik login — it only **verifies** tokens that clients present.

2. **Token Submission:** The client includes the Authentik-issued token in the `Authorization: Bearer <token>` header of every API request.

3. **Token Detection** (`app/auth/dependencies.py:_decode_token`):
   - In `oidc` mode: always routes to `oidc_auth_service.decode_access_token()`.
   - In `hybrid` mode: calls `_looks_like_oidc_token()` which checks the JWT header's `alg`:
     - **RS256/ES256/PS256** → token is asymmetric → definitely OIDC (Authentik defaults to RS256).
     - **HS256** → checks if `iss` matches `settings.oidc_issuer_url` → if yes, OIDC with shared secret; if no, local.

4. **Token Verification** (`app/auth/oidc_service.py:decode_access_token`):
   - **Asymmetric (RS/ES/PS):** Fetches the signing key from Authentik's JWKS endpoint (`settings.oidc_jwks_url`, typically `https://<authentik-host>/application/o/<slug>/jwks/`). Uses `PyJWKClient` from the `PyJWT` library to fetch and cache keys.
   - **Symmetric (HS):** Decodes using `settings.oidc_client_secret` as the shared key.
   - Validates `exp` (expiry), `iss` (issuer), and `aud` (audience) claims.
   - Extracts the user identity from `preferred_username` (fallback: `sub`).

5. **User-to-Permission Mapping** (`app/auth/oidc_service.py` lookup tables):
   ```python
   USERNAME_SCOPES = {
       "admin": ALL_SCOPES,
       "provisioner": PROVISIONER_SCOPES,
       "reader": READER_SCOPES,
   }
   USERNAME_PROVIDERS = {
       "admin": ["*"],
       "provisioner": ["aws", "nutanix"],
       "reader": ["aws", "nutanix"],
   }
   ```
   The OIDC `preferred_username` is looked up in these dicts to determine the user's libcloud scopes and allowed providers. If the username is not found, the request is denied with `auth_user_unknown`.

6. **TokenClaims Construction:** A `TokenClaims` object is built from the OIDC payload — this makes OIDC tokens indistinguishable from local tokens for the rest of the authorization pipeline.

**Configuration for Authentik (`.env`):**

```bash
AUTH_MODE=hybrid                         # or oidc
OIDC_ENABLED=true
OIDC_ISSUER_URL=https://auth.example.com/application/o/libcloud-rest/
OIDC_JWKS_URL=https://auth.example.com/application/o/libcloud-rest/jwks/
OIDC_CLIENT_SECRET=your-client-secret    # for HS256 tokens
OIDC_AUDIENCE=libcloud-rest
OIDC_TENANT_ID=default
```

### OpenFGA Fine-Grained Authorization

**How OpenFGA is integrated (end-to-end):**

1. **Configuration** (`.env`):
   ```bash
   FGA_ENABLED=true
   FGA_API_URL=http://localhost:8080
   FGA_STORE_ID=01J...
   FGA_MODEL_ID=01J...
   FGA_API_OBJECT=libcloud_api:main
   FGA_NUTANIX_CLUSTER=lab
   FGA_AWS_REGION_OBJECT=ap-southeast-1
   ```

2. **Authorization Pipeline** (`app/auth/policy.py:PolicyEngine.authorize_connection`):
   Every compute/network route handler calls this method, which runs three sequential checks:
   
   **Stage 1 — JWT Scope Check:**
   - Verifies the token's `scope` claim includes the required scope.
   - Resolves `compute:read` alias (implies `compute:image:read`, `compute:size:read`, `compute:location:read`, `compute:network:read`).
   
   **Stage 2 — Provider Allowlist Check:**
   - Verifies the token's `allowed_providers` includes the requested provider (or `"*"`).
   
   **Stage 3 — OpenFGA Check** (`_enforce_openfga`):
   - If FGA is disabled (`fga_enabled=false` or missing store/model IDs): **skipped entirely** — all requests pass.
   - If FGA is enabled, checks three relationship tuples in sequence:
     
     | # | Tuple | Meaning |
     |---|---|---|
     | 1 | `user:<username> can_connect libcloud_api:main` | User is allowed to access the REST API at all |
     | 2 | `user:<username> can_use provider:<provider>` | User is allowed to use AWS or Nutanix |
     | 3a | `user:<username> can_provision <backend>` | Write/manage operations require provision access on the specific backend |
     | 3b | `user:<username> can_read <backend>` (fallback: `can_provision`) | Read operations check read access first, then fall back to provision access |
     
     Backend objects (per-tenant isolation):
     - AWS: `aws_region:<auth_binding>` (e.g., `aws_region:aws`, `aws_region:aws-dev`)
     - Nutanix: `nutanix_cluster:<auth_binding>` (e.g., `nutanix_cluster:nutanix`)
     - The backend object id is the connection's `auth_binding` (the tenant id),
       NOT the region/cluster. Each tenant maps to its own OpenFGA backend
       object and its own Vault secret (`secret/libcloud/<auth_binding>`).

3. **FGA Client** (`app/auth/fga_client.py`):
   - Calls OpenFGA's `/stores/{store_id}/check` REST endpoint.
   - `check()` returns boolean; `require()` raises `authz_fga_denied` (403) on denial.
   - On OpenFGA errors: raises `authz_fga_error` (503) or `authz_fga_unavailable` (503).

**Example OpenFGA Authorization Model:**

```
type user

type libcloud_api
  relations
    define can_connect: [user]

type provider
  relations
    define can_use: [user]

type aws_region
  relations
    define can_read: [user]
    define can_provision: [user]

type nutanix_cluster
  relations
    define can_read: [user]
    define can_provision: [user]
```

**Example Tuples:**

```
user:aws-admin can_connect libcloud_api:main
user:aws-admin can_use provider:aws
user:aws-admin can_provision aws_region:aws
user:aws-viewer can_read aws_region:aws
user:ntnx-admin can_provision nutanix_cluster:nutanix
```

### Updates Required When Introducing New OpenFGA Objects

When a new resource type, provider, or entity is added to the system, the following files must be updated to keep the OpenFGA authorization layer consistent:

#### 1. OpenFGA Authorization Model (External)

The OpenFGA authorization model (stored in the OpenFGA server, referenced by `FGA_STORE_ID` / `FGA_MODEL_ID`) must be extended with new type definitions and relations for the new object. For example, if adding a new provider "gcp":

```
type gcp_project
  relations
    define can_read: [user]
    define can_provision: [user]
```

#### 2. `.env` — New FGA Object IDs

Add a new configuration key for the FGA object identifier:
```bash
FGA_GCP_PROJECT_OBJECT=my-gcp-project
```

#### 3. `app/config/settings.py` — Settings Class

Add the new field to the `Settings` class:
```python
class Settings(BaseSettings):
    # ... existing fields ...
    fga_gcp_project_object: str = "default-gcp-project"
```

#### 4. `app/auth/policy.py` — `_backend_object()` Method

Add a new branch to map the provider connection to the FGA object string:
```python
def _backend_object(self, connection: ProviderConnection) -> str:
    settings = get_settings()
    if connection.provider == "nutanix":
        return f"nutanix_cluster:{settings.fga_nutanix_cluster}"
    if connection.provider == "gcp":
        return f"gcp_project:{settings.fga_gcp_project_object}"
    region = connection.config.region or settings.fga_aws_region_object
    return f"aws_region:{region}"
```

#### 5. `app/auth/oidc_service.py` — User Scopes/Providers Mapping

If the new object requires new scopes, update `USERNAME_SCOPES` and `USERNAME_PROVIDERS`:
```python
PROVISIONER_SCOPES = [
    # ... existing scopes ...
    "compute:gcp:manage",  # new scope
]

USERNAME_PROVIDERS = {
    "admin": ["*"],
    "provisioner": ["aws", "nutanix", "gcp"],  # add new provider
    "reader": ["aws", "nutanix", "gcp"],
}
```

#### 6. `app/connections/models.py` — `ALL_SCOPES` and `ProviderConnection`

If adding new scopes or a new provider type:
```python
ALL_SCOPES = [
    # ... existing scopes ...
    "compute:gcp:read",
    "compute:gcp:manage",
]

class ProviderConnection(BaseModel):
    provider: Literal["aws", "nutanix", "gcp"]  # add new provider literal
```

#### 7. `app/providers/factory.py` — `build_driver()`

Add a new dispatch branch:
```python
def build_driver(connection: ProviderConnection) -> NodeDriver:
    # ...
    if connection.provider == "gcp":
        return create_gcp_driver(key, secret, connection.config)
```

#### Summary Checklist for New Objects

| # | File | What to Update |
|---|---|---|
| 1 | External: OpenFGA model | Define new `type` with `can_read` / `can_provision` relations |
| 2 | `.env` | Add FGA object ID config var (e.g., `FGA_GCP_PROJECT_OBJECT=...`) |
| 3 | `app/config/settings.py` | Add Settings field for the new FGA object |
| 4 | `app/auth/policy.py::_backend_object()` | Map provider → FGA object string |
| 5 | `app/auth/policy.py::_enforce_openfga()` | No change needed (uses `_backend_object()` dynamically) |
| 6 | `app/auth/oidc_service.py` | Add new scopes to role mappings if needed |
| 7 | `app/connections/models.py` | Add new scopes to `ALL_SCOPES`, update `ProviderConnection.provider` Literal |
| 8 | `app/providers/factory.py` | Add new driver dispatch branch |
| 9 | `app/providers/routes.py` | Add new provider to the `PROVIDERS` list |
| 10 | OpenFGA tuples | Write the actual relationship tuples for existing users |

---

## API Endpoint Tables

### 1. Auth APIs

**Prefix:** `/v1/auth`

| # | Method | Path | Auth | Scope | Description |
|---|---|---|---|---|---|
| 1 | `POST` | `/v1/auth/login` | None | — | Login, get JWT tokens |
| 2 | `POST` | `/v1/auth/refresh` | None | — | Refresh expired access token |
| 3 | `POST` | `/v1/auth/logout` | Bearer | — | Revoke tokens |
| 4 | `GET` | `/v1/auth/me` | Bearer | — | Get current token info |
| 5 | `POST` | `/v1/auth/token/introspect` | Bearer | `admin:connections:read` | Decode/validate a token |

#### 1.1 `POST /v1/auth/login`

**Input:**
```json
{
  "username": "admin",
  "password": "********",
  "requested_scopes": ["compute:read", "compute:node:create"]
}
```
| Field | Type | Required | Description |
|---|---|---|---|
| `username` | string | Yes | User login name |
| `password` | string | Yes | User password |
| `requested_scopes` | string[] | No | Scopes to request. Server may grant fewer than requested. |

**Output:**
```json
{
  "data": {
    "access_token": "eyJhbGciOi...",
    "token_type": "bearer",
    "expires_in": 900,
    "refresh_token": "rft_a1b2c3d4e5f6...",
    "scope": "compute:read compute:node:create"
  },
  "meta": { "request_id": "req_abc123" }
}
```
| Field | Type | Description |
|---|---|---|
| `access_token` | string | JWT for API calls (15 min TTL) |
| `token_type` | string | Always `"bearer"` |
| `expires_in` | int | Seconds until access token expires |
| `refresh_token` | string | Opaque token for refresh (8 hour TTL) |
| `scope` | string | Space-separated granted scopes |

#### 1.2 `POST /v1/auth/refresh`

**Input:**
```json
{
  "refresh_token": "rft_a1b2c3d4e5f6..."
}
```
| Field | Type | Required | Description |
|---|---|---|---|
| `refresh_token` | string | Yes | Refresh token from login |

**Output:** Same shape as login (new `access_token` + `refresh_token`).

#### 1.3 `POST /v1/auth/logout`

**Special Header:** `Authorization: Bearer <access_token>`

**Input (optional body):**
```json
{
  "refresh_token": "rft_a1b2c3d4e5f6..."
}
```
| Field | Type | Required | Description |
|---|---|---|---|
| `refresh_token` | string | No | If provided, also revokes the refresh token |

**Output:**
```json
{
  "data": { "logged_out": true },
  "meta": { "request_id": "..." }
}
```

#### 1.4 `GET /v1/auth/me`

**Special Header:** `Authorization: Bearer <access_token>`

**Input:** None (query-only — uses bearer token)

**Output:**
```json
{
  "data": {
    "username": "admin",
    "tenant_id": "default",
    "scope": "compute:read compute:node:create",
    "allowed_providers": ["*"],
    "session_id": "sess_x1y2z3"
  },
  "meta": { "request_id": "..." }
}
```

#### 1.5 `POST /v1/auth/token/introspect`

**Special Header:** `Authorization: Bearer <access_token>` (needs `admin:connections:read` scope)

**Input:**
```json
{
  "token": "eyJhbGciOi..."
}
```
| Field | Type | Required | Description |
|---|---|---|---|
| `token` | string | Yes | JWT to introspect |

**Output:** Decoded token claims (validity, scopes, etc.) or error if invalid.

---

### 2. Provider API

**Prefix:** `/v1/providers`

| # | Method | Path | Auth | Scope | Description |
|---|---|---|---|---|---|
| 6 | `GET` | `/v1/providers` | None | — | List available provider types |

#### 2.1 `GET /v1/providers`

**Input:** None

**Output:** Static list of supported providers (`aws`, `nutanix`) with metadata.

---

### 3. Connection APIs

**Prefix:** `/v1/connections`

| # | Method | Path | Auth | Scope | Description |
|---|---|---|---|---|---|
| 7 | `POST` | `/v1/connections:test` | Bearer | `compute:read` | Test a client-supplied connection |

#### 3.1 `POST /v1/connections:test`

**Input:** A full `ProviderConnection` object in the request body:

```json
{
  "provider": "aws",
  "config": { "region": "us-east-1", "secure": true },
  "credentials": { "key": "AKIA...", "secret": "..." }
}
```

**Output:**
```json
{
  "data": {
    "target": "aws:us-east-1",
    "provider": "aws",
    "status": "ok",
    "capabilities": {
      "create_node_auth": ["ssh_key", "password"],
      "supports_volumes": true,
      "supports_snapshots": true,
      "supports_key_pairs": true,
      "supports_wait_until_running": true
    }
  },
  "meta": { "request_id": "..." }
}
```

The server does **not** persist connections. List/create/get connection endpoints have been removed.

---

### 4. Compute APIs

**Prefix:** `/v1/compute`

All compute endpoints require `Authorization: Bearer <token>` and a `connection` (URL-encoded JSON query param for GET/DELETE, or inline object in the body for POST/PATCH). The `connection.provider` field determines which libcloud driver is used.

---

#### 4.1 Locations

| # | Method | Path | Scope | Description |
|---|---|---|---|---|
| 11 | `GET` | `/v1/compute/locations` | `compute:location:read` or `compute:read` | List locations/clusters |

**Input (query params):**

| Param | Type | Required | Description |
|---|---|---|---|
| `connection` | string | Yes | URL-encoded JSON `ProviderConnection` |

**Driver Redirection:**

| Provider | libcloud Method Called |
|---|---|
| **AWS** | `driver.list_locations()` → returns AWS regions/availability zones |
| **Nutanix** | `driver.ex_list_clusters()` → returns Nutanix clusters |

**Output:**
```json
{
  "data": [
    {
      "id": "us-east-1",
      "name": "us-east-1",
      "country": "US",
      "extra": {}
    }
  ],
  "meta": { "request_id": "..." }
}
```
| Field | Type | Description |
|---|---|---|
| `id` | string | Location/cluster ID |
| `name` | string | Location/cluster name |
| `country` | string | Country code (AWS only) |
| `extra` | object | Provider-specific metadata |

---

#### 4.2 Images

| # | Method | Path | Scope | Description |
|---|---|---|---|---|
| 12 | `GET` | `/v1/compute/images` | `compute:image:read` or `compute:read` | List images |
| 13 | `POST` | `/v1/compute/images` | `compute:image:manage` | Create image |
| 14 | `DELETE` | `/v1/compute/images/{image_id}` | `compute:image:manage` | Delete image |

##### 4.2.1 `GET /v1/compute/images`

**Input (query params):**

| Param | Type | Required | Description |
|---|---|---|---|
| `connection` | string | Yes | URL-encoded JSON `ProviderConnection` |
| `owner` | string | No | Filter by image owner (AWS only) |
| `name` | string | No | Image name filter with `*` wildcards (AWS only). Omit to use server default (`*Ubuntu*`). Pass `name=*` to list all images. |

**Driver Redirection:**

| Provider | libcloud Method |
|---|---|
| **Both** | `driver.list_images()` |

**Output:**
```json
{
  "data": [
    {
      "id": "ami-0c55b159cbfafe1f0",
      "name": "amzn2-ami-hvm-2.0.20210601.0-x86_64-gp2",
      "extra": { "architecture": "x86_64", "owner_id": "amazon" }
    }
  ],
  "meta": { "request_id": "..." }
}
```

##### 4.2.2 `POST /v1/compute/images`

**Supports async execution.**

**Input:**
```json
{
  "connection": {
    "provider": "nutanix",
    "config": {
      "host": "prism.example.com",
      "port": 9440,
      "secure": true,
      "api_version": "v4.0",
      "verify_ssl_cert": false
    },
    "credentials": { "key": "admin", "secret": "..." }
  },
  "name": "my-image",
  "url": "http://fileserver/disk.qcow2",
  "vm_id": null,
  "description": "Custom image from URL",
  "execution": {
    "mode": "async",
    "wait_until_running": false,
    "timeout_seconds": 900
  }
}
```
| Field | Type | Required | Description |
|---|---|---|---|
| `connection` | object | Yes | Inline `ProviderConnection` in request body |
| `name` | string | Yes | Image name |
| `url` | string | No* | Image URL for import (Nutanix: `ex_create_image_from_url`) |
| `vm_id` | string | No* | Source VM ID for snapshot (Nutanix: `create_image`) |
| `description` | string | No | Image description |
| `execution.mode` | `"sync"` \| `"async"` | No | Default `"sync"`. Use `"async"` for long operations. |
| `execution.wait_until_running` | bool | No | Wait for image to be ready (sync mode only) |
| `execution.timeout_seconds` | int | No | Wait timeout, default 900 |

> *One of `url` or `vm_id` is required. `url` uses `driver.ex_create_image_from_url()` (Nutanix only). `vm_id` uses `driver.create_image()` (Nutanix only). AWS image creation is not supported via this API.

**Driver Redirection:**

| Provider | Condition | libcloud Method |
|---|---|---|
| **Nutanix** | `url` provided | `driver.ex_create_image_from_url(name, url, description)` |
| **Nutanix** | `vm_id` provided | `driver.create_image(node, name, description)` |
| **AWS** | — | Not supported (`validation_error`) |

**Output (sync):**
```json
{
  "data": {
    "id": "img_abc123",
    "name": "my-image",
    "extra": {}
  },
  "meta": { "request_id": "..." }
}
```

**Output (async):**
```json
{
  "data": {
    "job_id": "job_a1b2c3d4e5f6a7b8",
    "status": "pending"
  },
  "meta": { "request_id": "..." }
}
```

##### 4.2.3 `DELETE /v1/compute/images/{image_id}`

**Input (query params):**

| Param | Type | Required | Description |
|---|---|---|---|
| `connection` | string | Yes | URL-encoded JSON `ProviderConnection` |

**Driver Redirection:**

| Provider | libcloud Method |
|---|---|
| **Both** | `driver.delete_image(image)` |

**Output:**
```json
{
  "data": { "id": "ami-0c55b159cbfafe1f0", "destroyed": true },
  "meta": { "request_id": "..." }
}
```

---

#### 4.3 Sizes (Instance Types)

| # | Method | Path | Scope | Description |
|---|---|---|---|---|
| 15 | `GET` | `/v1/compute/sizes` | `compute:size:read` or `compute:read` | List instance sizes |

**Input (query params):**

| Param | Type | Required | Description |
|---|---|---|---|
| `connection` | string | Yes | URL-encoded JSON `ProviderConnection` |

**Driver Redirection:**

| Provider | libcloud Method |
|---|---|
| **Both** | `driver.list_sizes()` |

**Output:**
```json
{
  "data": [
    {
      "id": "t2.micro",
      "name": "t2.micro",
      "ram": 1024,
      "disk": 30,
      "bandwidth": null,
      "extra": { "vcpus": 1 }
    }
  ],
  "meta": { "request_id": "..." }
}
```
| Field | Type | Description |
|---|---|---|
| `id` | string | Size/instance-type ID |
| `name` | string | Display name |
| `ram` | int | RAM in MB |
| `disk` | int | Disk in GB |
| `bandwidth` | int | Bandwidth in Mbps |
| `extra` | object | Provider-specific metadata |

---

#### 4.4 Nodes (VMs)

| # | Method | Path | Scope | Description |
|---|---|---|---|---|
| 16 | `GET` | `/v1/compute/nodes` | `compute:read` | List nodes |
| 17 | `GET` | `/v1/compute/nodes/{node_id}` | `compute:read` | Get single node |
| 18 | `POST` | `/v1/compute/nodes` | `compute:node:create` | Create node |
| 19 | `PATCH` | `/v1/compute/nodes/{node_id}` | `compute:node:update` or `compute:node:power` | Update/resize/tag node |
| 20 | `POST` | `/v1/compute/nodes/{node_id}:start` | `compute:node:power` | Start node |
| 21 | `POST` | `/v1/compute/nodes/{node_id}:stop` | `compute:node:power` | Stop node |
| 22 | `POST` | `/v1/compute/nodes/{node_id}:reboot` | `compute:node:power` | Reboot node |
| 23 | `DELETE` | `/v1/compute/nodes/{node_id}` | `compute:node:delete` | Delete/destroy node |

##### 4.4.1 `GET /v1/compute/nodes`

**Input (query params):**

| Param | Type | Required | Description |
|---|---|---|---|
| `connection` | string | Yes | URL-encoded JSON `ProviderConnection` |

**Driver Redirection:**

| Provider | libcloud Method |
|---|---|
| **Both** | `driver.list_nodes()` |

##### 4.4.2 `GET /v1/compute/nodes/{node_id}`

**Input:**

| Param | Source | Type | Required | Description |
|---|---|---|---|---|
| `node_id` | Path | string | Yes | Node identifier |
| `connection` | Query | string | Yes | URL-encoded JSON `ProviderConnection` |

**Driver Redirection:**

| Provider | libcloud Method |
|---|---|
| **Both** | `driver.ex_get_node(node_id)` if available, else filter `list_nodes()` |

**Output (both list & get):**
```json
{
  "data": {
    "id": "i-0abcd1234efgh5678",
    "name": "my-vm",
    "state": "running",
    "public_ips": ["54.1.2.3"],
    "private_ips": ["10.0.0.5"],
    "size": "t2.micro",
    "image": "ami-0c55b159cbfafe1f0",
    "provider": "aws",
    "target": "aws:us-east-1",
    "extra": { "instance_type": "t2.micro" }
  },
  "meta": { "request_id": "..." }
}
```
| Field | Type | Description |
|---|---|---|
| `id` | string | Node/instance ID |
| `name` | string | Node name |
| `state` | string | `"running"`, `"stopped"`, `"terminated"`, `"pending"`, etc. |
| `public_ips` | string[] | Public IP addresses |
| `private_ips` | string[] | Private IP addresses |
| `size` | string | Size/instance-type ID |
| `image` | string | Image ID used to create the node |
| `target` | string | Connection target summary (e.g. `aws:us-east-1`, `nutanix:host:9440`) |
| `provider` | string | `"aws"` or `"nutanix"` |
| `extra` | object | All provider-specific metadata (passwords redacted) |

##### 4.4.3 `POST /v1/compute/nodes` (Create Node)

**The most argument-rich endpoint. Supports async execution.**

**Input:**
```json
{
  "connection": {
    "provider": "aws",
    "config": { "region": "us-east-1", "secure": true },
    "credentials": { "key": "AKIA...", "secret": "..." }
  },
  "name": "my-new-vm",
  "size": { "id": "t2.micro" },
  "image": { "id": "ami-0c55b159cbfafe1f0" },
  "location": { "id": "us-east-1a" },
  "auth": {
    "type": "ssh_key",
    "public_key": "ssh-rsa AAAAB3NzaC1yc2EAAA...",
    "key_name": "my-keypair",
    "password": null
  },
  "network": {
    "public_ip": true,
    "subnet_id": "subnet-0abc1234",
    "security_group": "sg-0def5678"
  },
  "tags": { "env": "prod", "app": "web" },
  "provider_options": {
    "ex_volume_type": "gp3",
    "ex_encrypted": true,
    "ex_iops": 3000
  },
  "execution": {
    "mode": "sync",
    "wait_until_running": true,
    "timeout_seconds": 600
  }
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `connection` | object | **Yes** | Inline `ProviderConnection` in request body |
| `name` | string | **Yes** | Node/hostname name |
| `size` | `{id: string}` | **Yes** | Instance type/size reference |
| `image` | `{id: string}` | **Yes** | Image reference |
| `location` | `{id: string}` | No | Location/cluster reference |
| `auth` | object | No | Authentication configuration |
| `auth.type` | `"ssh_key"` \| `"password"` \| `"key_pair"` | No | Default `"ssh_key"` |
| `auth.public_key` | string | If `type=ssh_key` | SSH public key material |
| `auth.key_name` | string | If `type=key_pair` | Existing key pair name (AWS: `ex_keyname`) |
| `auth.password` | string | If `type=password` | Root/admin password |
| `network` | object | No | Network configuration |
| `network.public_ip` | bool | No | Assign public IP (AWS: `ex_assign_public_ip`) |
| `network.subnet_id` | string | No | Subnet to attach (maps to `ex_subnet`) |
| `network.security_group` | string | No | Security group (AWS: `ex_securitygroup`) |
| `tags` | object | No | Key-value tags. AWS: mapped to `ex_metadata`. Nutanix: use `provider_options.ex_categories`. |
| `provider_options` | object | No | Provider-specific `ex_*` options (see [allowlists](#provider-specific-provider_options-allowlists)) |
| `execution.mode` | `"sync"` \| `"async"` | No | Default `"sync"` |
| `execution.wait_until_running` | bool | No | Wait for node to reach running state |
| `execution.timeout_seconds` | int | No | Wait timeout, default 900 |

**Driver Redirection:**

| Provider | libcloud Method | Key Extra Args |
|---|---|---|
| **AWS** | `driver.create_node(name, size, image, location, auth, ex_keyname, ex_securitygroup, ex_subnet, ex_assign_public_ip, ex_metadata, ...)` | `ex_keyname`, `ex_securitygroup`, `ex_subnet`, `ex_assign_public_ip`, `ex_metadata`, `ex_userdata`, `ex_blockdevicemappings`, `ex_spot`, `ex_placement_group`, `ex_iamprofile` |
| **Nutanix** | `driver.create_node(name, size, image, location, auth, ex_subnet, ex_description, ex_memory_mib, ex_vcpus, ex_cores_per_vcpu, ex_storage_container, ex_disk_size_mib, ex_cloud_init, ex_nics, ex_categories, ex_power_on, ex_wait)` | `ex_subnet`, `ex_description`, `ex_memory_mib`, `ex_vcpus`, `ex_cores_per_vcpu`, `ex_storage_container`, `ex_disk_size_mib`, `ex_user_data`, `ex_cloud_init`, `ex_nics`, `ex_categories`, `ex_power_on`, `ex_wait` |

**Libcloud method signature that gets called:**
```python
node = driver.create_node(**kwargs)
# plus optional wait:
# node = driver.wait_until_running(node, timeout=timeout_seconds)
```

**Output (sync):** `NodeResponse` — same shape as `GET /v1/compute/nodes/{node_id}`.

**Output (async):**
```json
{
  "data": {
    "job_id": "job_a1b2c3d4e5f6a7b8",
    "status": "pending"
  },
  "meta": { "request_id": "..." }
}
```

##### 4.4.4 `PATCH /v1/compute/nodes/{node_id}` (Update Node)

**Input:**
```json
{
  "connection": {
    "provider": "aws",
    "config": { "region": "us-east-1", "secure": true },
    "credentials": { "key": "AKIA...", "secret": "..." }
  },
  "action": "resize",
  "name": null,
  "description": null,
  "memory_mib": null,
  "new_size_id": "t2.small",
  "tag_key": null,
  "tag_value": null
}
```
| Field | Type | Required | Description |
|---|---|---|---|
| `connection` | object | **Yes** | Inline `ProviderConnection` in request body |
| `action` | `"update"` \| `"resize"` \| `"tag"` | Yes | Operation type |
| `name` | string | For `update` | New node name (Nutanix only) |
| `description` | string | For `update` | New description (Nutanix only) |
| `memory_mib` | int | For `update` | New memory in MiB (Nutanix only) |
| `new_size_id` | string | For `resize` | New instance type ID (AWS only) |
| `tag_key` | string | For `tag` | Tag key |
| `tag_value` | string | For `tag` | Tag value |

**Driver Redirection:**

| Action | AWS libcloud | Nutanix libcloud |
|---|---|---|
| `resize` | `driver.ex_change_node_size(node, size)` | Not supported |
| `tag` | `driver.ex_create_tags(node, {key: value})` | `driver.ex_create_tags(node, {key: value})` |
| `update` | Not supported | `driver.ex_update_node(node_id, name, description, ex_memory_mib)` |

##### 4.4.5 `POST /v1/compute/nodes/{node_id}:start`

**Input (query params):**

| Param | Type | Required | Description |
|---|---|---|---|
| `connection` | string | Yes | URL-encoded JSON `ProviderConnection` |

**Driver Redirection:**

| Provider | libcloud Method |
|---|---|
| **Both** | `driver.start_node(node)` |

**Output:**
```json
{
  "data": { "id": "i-0abcd1234efgh5678", "action": "start", "success": true },
  "meta": { "request_id": "..." }
}
```

##### 4.4.6 `POST /v1/compute/nodes/{node_id}:stop`

Same as start — calls `driver.stop_node(node)`.

##### 4.4.7 `POST /v1/compute/nodes/{node_id}:reboot`

Same as start — calls `driver.reboot_node(node)`.

##### 4.4.8 `DELETE /v1/compute/nodes/{node_id}`

**Input (query params):**

| Param | Type | Required | Description |
|---|---|---|---|
| `connection` | string | Yes | URL-encoded JSON `ProviderConnection` |
| `async` | bool | No | Default false. Set `true` for async execution. |

**Driver Redirection:**

| Provider | libcloud Method |
|---|---|
| **Both** | `driver.destroy_node(node)` |

**Output (sync):**
```json
{
  "data": { "id": "i-0abcd1234efgh5678", "destroyed": true },
  "meta": { "request_id": "..." }
}
```

**Output (async):**
```json
{
  "data": { "job_id": "job_b2c3d4e5f6a7b8c9", "status": "pending" },
  "meta": { "request_id": "..." }
}
```

---

#### 4.5 Volumes

| # | Method | Path | Scope | Description |
|---|---|---|---|---|
| 24 | `GET` | `/v1/compute/volumes` | `compute:volume:manage` or `compute:read` | List volumes |
| 25 | `POST` | `/v1/compute/volumes` | `compute:volume:manage` | Create volume |
| 26 | `PATCH` | `/v1/compute/volumes/{volume_id}` | `compute:volume:manage` | Modify/tag volume |
| 27 | `DELETE` | `/v1/compute/volumes/{volume_id}` | `compute:volume:manage` | Delete volume |
| 28 | `POST` | `/v1/compute/volumes/{volume_id}:attach` | `compute:volume:manage` | Attach volume to node |
| 29 | `POST` | `/v1/compute/volumes/{volume_id}:detach` | `compute:volume:manage` | Detach volume from node |

##### 4.5.1 `GET /v1/compute/volumes`

**Input (query params):**

| Param | Type | Required | Description |
|---|---|---|---|
| `connection` | string | Yes | URL-encoded JSON `ProviderConnection` |
| `id` | string | No | Filter by volume ID |

**Driver Redirection:**

| Provider | Condition | libcloud Method |
|---|---|---|
| **Both** | `id` given | `driver.ex_get_volume(volume_id)` |
| **Both** | No `id` | `driver.list_volumes()` |

**Output:**
```json
{
  "data": [
    {
      "id": "vol-0abcd1234efgh5678",
      "name": "my-volume",
      "size": 100,
      "state": "available",
      "extra": { "volume_type": "gp3", "iops": 3000 }
    }
  ],
  "meta": { "request_id": "..." }
}
```
| Field | Type | Description |
|---|---|---|
| `id` | string | Volume ID |
| `name` | string | Volume name |
| `size` | int | Size in GB |
| `state` | string | `"available"`, `"in-use"`, `"creating"`, etc. |
| `extra` | object | Provider-specific metadata |

##### 4.5.2 `POST /v1/compute/volumes`

**Supports async execution.**

**Input:**
```json
{
  "connection": {
    "provider": "aws",
    "config": { "region": "us-east-1", "secure": true },
    "credentials": { "key": "AKIA...", "secret": "..." }
  },
  "name": "data-volume",
  "size_gb": 100,
  "location": { "id": "us-east-1a" },
  "snapshot_id": null,
  "provider_options": {
    "ex_volume_type": "gp3",
    "ex_encrypted": true,
    "ex_iops": 3000
  },
  "execution": {
    "mode": "async"
  }
}
```
| Field | Type | Required | Description |
|---|---|---|---|
| `connection` | object | **Yes** | Inline `ProviderConnection` in request body |
| `name` | string | **Yes** | Volume name |
| `size_gb` | int | **Yes** | Size in GB |
| `location` | `{id: string}` | No | Location/availability zone |
| `snapshot_id` | string | No | Restore from snapshot |
| `provider_options` | object | No | `ex_volume_type`, `ex_encrypted`, `ex_iops` (AWS). `ex_storage_container`, `ex_description` (Nutanix). |
| `execution.mode` | `"sync"` \| `"async"` | No | Default `"sync"` |

**Driver Redirection:**

| Provider | libcloud Method |
|---|---|
| **Both** | `driver.create_volume(size_gb, name, location, snapshot, **provider_options)` |

##### 4.5.3 `PATCH /v1/compute/volumes/{volume_id}`

**Input:**
```json
{
  "connection": {
    "provider": "aws",
    "config": { "region": "us-east-1", "secure": true },
    "credentials": { "key": "AKIA...", "secret": "..." }
  },
  "action": "modify",
  "new_size_gb": 200,
  "volume_type": "gp3",
  "iops": 6000,
  "tag_key": null,
  "tag_value": null
}
```
| Field | Type | Required | Description |
|---|---|---|---|
| `connection` | object | **Yes** | Inline `ProviderConnection` in request body |
| `action` | `"modify"` \| `"tag"` | Yes | Operation type |
| `new_size_gb` | int | For `modify` | New size in GB |
| `volume_type` | string | For `modify` | New volume type |
| `iops` | int | For `modify` | New IOPS |
| `tag_key` | string | For `tag` | Tag key |
| `tag_value` | string | For `tag` | Tag value |

**Driver Redirection:**

| Action | AWS libcloud | Nutanix libcloud |
|---|---|---|
| `modify` | `driver.ex_modify_volume(volume, size, volume_type, iops)` | Not supported |
| `tag` | `driver.ex_create_tags(volume, {key: value})` | `driver.ex_create_tags(volume, {key: value})` |

##### 4.5.4 `DELETE /v1/compute/volumes/{volume_id}`

**Input (query params):**

| Param | Type | Required | Description |
|---|---|---|---|
| `connection` | string | Yes | URL-encoded JSON `ProviderConnection` |

**Driver Redirection:**

| Provider | libcloud Method |
|---|---|
| **Both** | `driver.destroy_volume(volume)` |

##### 4.5.5 `POST /v1/compute/volumes/{volume_id}:attach`

**Input:**
```json
{
  "connection": {
    "provider": "aws",
    "config": { "region": "us-east-1", "secure": true },
    "credentials": { "key": "AKIA...", "secret": "..." }
  },
  "node_id": "i-0abcd1234efgh5678",
  "device": "/dev/sdf"
}
```
| Field | Type | Required | Description |
|---|---|---|---|
| `connection` | object | **Yes** | Inline `ProviderConnection` in request body |
| `node_id` | string | **Yes** | Target node/VM ID |
| `device` | string | No | Device path, e.g. `/dev/sdf` |

**Driver Redirection:**

| Provider | libcloud Method |
|---|---|
| **Both** | `driver.attach_volume(node, volume, device=device)` |

**Output:**
```json
{
  "data": { "volume_id": "vol-xxx", "node_id": "i-xxx", "attached": true },
  "meta": { "request_id": "..." }
}
```

##### 4.5.6 `POST /v1/compute/volumes/{volume_id}:detach`

Same input shape as attach.

**Driver Redirection:**

| Provider | libcloud Method |
|---|---|
| **AWS** | `driver.detach_volume(volume)` |
| **Nutanix** | `driver.detach_volume(volume, ex_vm_ext_id=node_id)` |

---

#### 4.6 Snapshots

| # | Method | Path | Scope | Description |
|---|---|---|---|---|
| 30 | `GET` | `/v1/compute/snapshots` | `compute:snapshot:manage` or `compute:read` | List snapshots |
| 31 | `POST` | `/v1/compute/snapshots` | `compute:snapshot:manage` | Create snapshot |
| 32 | `DELETE` | `/v1/compute/snapshots/{snapshot_id}` | `compute:snapshot:manage` | Delete snapshot |

##### 4.6.1 `GET /v1/compute/snapshots`

**Input (query params):**

| Param | Type | Required | Description |
|---|---|---|---|
| `connection` | string | Yes | URL-encoded JSON `ProviderConnection` |
| `id` | string | No | Filter by snapshot ID |
| `volume_id` | string | No | Filter by source volume ID |

**Driver Redirection:**

| Condition | libcloud Method |
|---|---|
| `id` given | `driver.ex_get_volume_snapshot(snapshot_id)` |
| `volume_id` given | `driver.list_volume_snapshots(volume)` |
| Neither | `driver.list_snapshots()` |

**Output:**
```json
{
  "data": [
    {
      "id": "snap-0abcd1234efgh5678",
      "name": "my-snapshot",
      "volume_id": "vol-0abcd1234efgh5678",
      "state": "completed",
      "extra": {}
    }
  ],
  "meta": { "request_id": "..." }
}
```

##### 4.6.2 `POST /v1/compute/snapshots`

**Supports async execution.**

**Input:**
```json
{
  "connection": {
    "provider": "aws",
    "config": { "region": "us-east-1", "secure": true },
    "credentials": { "key": "AKIA...", "secret": "..." }
  },
  "volume_id": "vol-0abcd1234efgh5678",
  "name": "backup-2026-06-22",
  "execution": {
    "mode": "async"
  }
}
```
| Field | Type | Required | Description |
|---|---|---|---|
| `connection` | object | **Yes** | Inline `ProviderConnection` in request body |
| `volume_id` | string | **Yes** | Source volume ID |
| `name` | string | No | Snapshot name |
| `execution.mode` | `"sync"` \| `"async"` | No | Default `"sync"` |

**Driver Redirection:**

| Provider | libcloud Method |
|---|---|
| **Both** | `driver.create_volume_snapshot(volume, name=name)` |

##### 4.6.3 `DELETE /v1/compute/snapshots/{snapshot_id}`

**Input (query params):**

| Param | Type | Required | Description |
|---|---|---|---|
| `connection` | string | Yes | URL-encoded JSON `ProviderConnection` |
| `volume_id` | string | No | Source volume ID (helps locate snapshot) |

**Driver Redirection:**

| Provider | libcloud Method |
|---|---|
| **Both** | `driver.destroy_volume_snapshot(snapshot)` |

---

#### 4.7 Key Pairs

| # | Method | Path | Scope | Description |
|---|---|---|---|---|
| 33 | `GET` | `/v1/compute/key-pairs` | `compute:keypair:manage` or `compute:read` | List key pairs |
| 34 | `POST` | `/v1/compute/key-pairs` | `compute:keypair:manage` | Create/import key pair |
| 35 | `DELETE` | `/v1/compute/key-pairs/{name}` | `compute:keypair:manage` | Delete key pair |

##### 4.7.1 `GET /v1/compute/key-pairs`

**Input (query params):**

| Param | Type | Required | Description |
|---|---|---|---|
| `connection` | string | Yes | URL-encoded JSON `ProviderConnection` |

**Driver Redirection:**

| Provider | libcloud Method |
|---|---|
| **AWS** | `driver.list_key_pairs()` |
| **Nutanix** | Not supported |

**Output:**
```json
{
  "data": [
    {
      "name": "my-keypair",
      "fingerprint": "1a:2b:3c:4d:5e:6f:...",
      "public_key": "ssh-rsa AAAAB3NzaC1yc2EAAA...",
      "private_key": null
    }
  ],
  "meta": { "request_id": "..." }
}
```
> `private_key` is only populated on creation, never on list.

##### 4.7.2 `POST /v1/compute/key-pairs`

**Input:**
```json
{
  "connection": {
    "provider": "aws",
    "config": { "region": "us-east-1", "secure": true },
    "credentials": { "key": "AKIA...", "secret": "..." }
  },
  "name": "my-new-keypair",
  "public_key": null
}
```
| Field | Type | Required | Description |
|---|---|---|---|
| `connection` | object | **Yes** | Inline `ProviderConnection` in request body |
| `name` | string | **Yes** | Key pair name |
| `public_key` | string | No | If provided, import existing public key. If omitted, driver generates new key pair. |

**Driver Redirection:**

| Provider | Condition | libcloud Method |
|---|---|---|
| **AWS** | `public_key` given | `driver.create_key_pair(name, public_key=public_key)` |
| **AWS** | `public_key` omitted | `driver.create_key_pair(name=name)` |
| **Nutanix** | — | Not supported |

##### 4.7.3 `DELETE /v1/compute/key-pairs/{name}`

**Input (query params):**

| Param | Type | Required | Description |
|---|---|---|---|
| `connection` | string | Yes | URL-encoded JSON `ProviderConnection` |

**Driver Redirection:**

| Provider | libcloud Method |
|---|---|
| **AWS** | `driver.delete_key_pair(name)` |
| **Nutanix** | Not supported |

---

### 5. Network APIs

**Prefix:** `/v1/compute` (tag: `network`)

---

#### 5.1 Networks (VPCs)

| # | Method | Path | Scope | Description |
|---|---|---|---|---|
| 36 | `GET` | `/v1/compute/networks` | `compute:network:read` or `compute:read` | List networks/VPCs |
| 37 | `POST` | `/v1/compute/networks` | `compute:network:manage` | Create network/VPC |
| 38 | `PATCH` | `/v1/compute/networks/{network_id}` | `compute:network:manage` | Update/tag network |
| 39 | `DELETE` | `/v1/compute/networks/{network_id}` | `compute:network:manage` | Delete network/VPC |

##### 5.1.1 `GET /v1/compute/networks`

**Input (query params):**

| Param | Type | Required | Description |
|---|---|---|---|
| `connection` | string | Yes | URL-encoded JSON `ProviderConnection` |
| `id` | string | No | Filter by network/VPC ID |

**Driver Redirection:**

| Provider | Condition | libcloud Method |
|---|---|---|
| **Nutanix** | `id` given | `driver.ex_get_vpc(network_id)` |
| **AWS** | `id` given | `driver.ex_list_networks(network_ids=[network_id])` |
| **Nutanix** | No `id` | `driver.ex_list_vpcs()` |
| **AWS** | No `id` | `driver.ex_list_networks()` |

**Output:**
```json
{
  "data": [
    {
      "id": "vpc-0abcd1234efgh5678",
      "name": "my-vpc",
      "cidr_block": "10.0.0.0/16",
      "state": "available",
      "provider": "aws",
      "target": "aws:us-east-1",
      "extra": {}
    }
  ],
  "meta": { "request_id": "..." }
}
```

##### 5.1.2 `POST /v1/compute/networks`

**Input:**
```json
{
  "connection": {
    "provider": "aws",
    "config": { "region": "us-east-1", "secure": true },
    "credentials": { "key": "AKIA...", "secret": "..." }
  },
  "name": "my-vpc",
  "description": "Production VPC",
  "cidr_block": "10.0.0.0/16",
  "vpc_type": "REGULAR",
  "instance_tenancy": "default",
  "external_subnet_ids": [],
  "provider_options": {}
}
```
| Field | Type | Required | Description |
|---|---|---|---|
| `connection` | object | **Yes** | Inline `ProviderConnection` in request body |
| `name` | string | **Yes** | VPC/network name |
| `description` | string | No | Description (Nutanix) |
| `cidr_block` | string | **AWS: Yes** | CIDR block (AWS only) |
| `vpc_type` | `"REGULAR"` \| `"TRANSIT"` | No | VPC type (Nutanix only, default `REGULAR`) |
| `instance_tenancy` | string | No | Tenancy, default `"default"` (AWS only) |
| `external_subnet_ids` | string[] | No | External subnet IDs (Nutanix only) |
| `provider_options` | object | No | Additional provider args |

**Driver Redirection:**

| Provider | libcloud Method |
|---|---|
| **AWS** | `driver.ex_create_network(name, cidr_block, instance_tenancy)` |
| **Nutanix** | `driver.ex_create_vpc(name, description, vpc_type, external_subnet_ext_ids)` |

##### 5.1.3 `PATCH /v1/compute/networks/{network_id}`

**Input:**
```json
{
  "connection": {
    "provider": "nutanix",
    "config": {
      "host": "prism.example.com",
      "port": 9440,
      "secure": true,
      "api_version": "v4.0",
      "verify_ssl_cert": false
    },
    "credentials": { "key": "admin", "secret": "..." }
  },
  "name": "updated-name",
  "description": "Updated description",
  "tag_key": null,
  "tag_value": null
}
```
| Field | Type | Required | Description |
|---|---|---|---|
| `connection` | object | **Yes** | Inline `ProviderConnection` in request body |
| `name` | string | No | New name |
| `description` | string | No | New description |
| `tag_key` | string | No | Tag key (for `tag` action) |
| `tag_value` | string | No | Tag value (for `tag` action) |

**Driver Redirection:**

| Condition | Nutanix | AWS |
|---|---|---|
| `tag_key` + `tag_value` | `driver.ex_create_tags(vpc, {k: v})` | `driver.ex_create_tags(network, {k: v})` |
| `name` / `description` | `driver.ex_update_vpc(id, name, description)` | Not supported |

##### 5.1.4 `DELETE /v1/compute/networks/{network_id}`

**Input (query params):**

| Param | Type | Required | Description |
|---|---|---|---|
| `connection` | string | Yes | URL-encoded JSON `ProviderConnection` |

**Driver Redirection:**

| Provider | libcloud Method |
|---|---|
| **Nutanix** | `driver.ex_delete_vpc(network_id)` |
| **AWS** | `driver.ex_delete_network(network)` |

---

#### 5.2 Subnets

| # | Method | Path | Scope | Description |
|---|---|---|---|---|
| 40 | `GET` | `/v1/compute/subnets` | `compute:network:read` or `compute:read` | List subnets |
| 41 | `POST` | `/v1/compute/subnets` | `compute:network:manage` | Create subnet |
| 42 | `PATCH` | `/v1/compute/subnets/{subnet_id}` | `compute:network:manage` | Update subnet |
| 43 | `DELETE` | `/v1/compute/subnets/{subnet_id}` | `compute:network:manage` | Delete subnet |

##### 5.2.1 `GET /v1/compute/subnets`

**Input (query params):**

| Param | Type | Required | Description |
|---|---|---|---|
| `connection` | string | Yes | URL-encoded JSON `ProviderConnection` |
| `id` | string | No | Filter by subnet ID |
| `vpc_id` | string | No | Filter by VPC ID |

**Driver Redirection:**

| Condition | libcloud Method |
|---|---|
| `id` given | `driver.ex_get_subnet(subnet_id)` else `driver.ex_list_subnets(subnet_ids=[subnet_id])` |
| No `id` | `driver.ex_list_subnets()` |

##### 5.2.2 `POST /v1/compute/subnets`

**Input:**
```json
{
  "connection": {
    "provider": "aws",
    "config": { "region": "us-east-1", "secure": true },
    "credentials": { "key": "AKIA...", "secret": "..." }
  },
  "name": "my-subnet",
  "subnet_type": "VLAN",
  "vpc_id": "vpc-0abcd1234efgh5678",
  "cluster_id": null,
  "network_id": null,
  "cidr_block": "10.0.1.0/24",
  "availability_zone": "us-east-1a",
  "description": null,
  "is_external": false,
  "ip_address": null,
  "prefix_length": null,
  "gateway_ip": null,
  "provider_options": {}
}
```
| Field | Type | Required | Description |
|---|---|---|---|
| `connection` | object | **Yes** | Inline `ProviderConnection` in request body |
| `name` | string | **Yes** | Subnet name |
| `subnet_type` | `"VLAN"` \| `"OVERLAY"` | No | Default `"VLAN"` (Nutanix only) |
| `vpc_id` | string | **AWS: Yes** | VPC to create subnet in |
| `cluster_id` | string | No | Cluster ID (Nutanix only) |
| `network_id` | int | No | Network ID (Nutanix only) |
| `cidr_block` | string | **AWS: Yes** | CIDR block (AWS only) |
| `availability_zone` | string | **AWS: Yes** | AZ (AWS only) |
| `description` | string | No | Description (Nutanix only) |
| `is_external` | bool | No | External subnet (Nutanix only) |
| `ip_address` | string | No | IP address (Nutanix only) |
| `prefix_length` | int | No | Prefix length (Nutanix only) |
| `gateway_ip` | string | No | Gateway IP (Nutanix only) |
| `provider_options` | object | No | Additional provider args |

**Driver Redirection:**

| Provider | libcloud Method |
|---|---|
| **AWS** | `driver.ex_create_subnet(name, vpc_id, cidr_block, availability_zone)` |
| **Nutanix** | `driver.ex_create_subnet(name, subnet_type, cluster_ext_id, vpc_ext_id, network_id, description, is_external, ip_address, prefix_length, gateway_ip)` |

##### 5.2.3 `PATCH /v1/compute/subnets/{subnet_id}`

**Input:**
```json
{
  "connection": {
    "provider": "aws",
    "config": { "region": "us-east-1", "secure": true },
    "credentials": { "key": "AKIA...", "secret": "..." }
  },
  "action": "auto_public_ip",
  "name": null,
  "description": null,
  "nat_enabled": null,
  "value": true,
  "tag_key": null,
  "tag_value": null
}
```
| Field | Type | Required | Description |
|---|---|---|---|
| `connection` | object | **Yes** | Inline `ProviderConnection` in request body |
| `action` | `"update"` \| `"nat"` \| `"auto_public_ip"` \| `"auto_ipv6"` \| `"tag"` | Yes | Operation type |
| `name` | string | For `update` | New name (Nutanix only) |
| `description` | string | For `update` | New description (Nutanix only) |
| `nat_enabled` | bool | For `nat` | Enable/disable NAT (Nutanix only) |
| `value` | bool | For `auto_public_ip`/`auto_ipv6` | Enable/disable (AWS only) |
| `tag_key` | string | For `tag` | Tag key |
| `tag_value` | string | For `tag` | Tag value |

**Driver Redirection:**

| Action | AWS libcloud | Nutanix libcloud |
|---|---|---|
| `update` | Not supported | `driver.ex_update_subnet(id, name, description)` |
| `nat` | Not supported | `driver.ex_update_subnet(id, is_nat_enabled=bool)` |
| `auto_public_ip` | `driver.ex_modify_subnet_attribute(id, attribute="mapPublicIpOnLaunch", value=bool)` | Not supported |
| `auto_ipv6` | `driver.ex_modify_subnet_attribute(id, attribute="assignIpv6AddressOnCreation", value=bool)` | Not supported |
| `tag` | `driver.ex_create_tags(subnet, {k: v})` | `driver.ex_create_tags(subnet, {k: v})` |

##### 5.2.4 `DELETE /v1/compute/subnets/{subnet_id}`

**Input (query params):**

| Param | Type | Required | Description |
|---|---|---|---|
| `connection` | string | Yes | URL-encoded JSON `ProviderConnection` |

**Driver Redirection:**

| Provider | libcloud Method |
|---|---|
| **Both** | `driver.ex_delete_subnet(subnet_id)` |

---

#### 5.3 Storage Containers (Nutanix Only)

| # | Method | Path | Scope | Description |
|---|---|---|---|---|
| 44 | `GET` | `/v1/compute/storage-containers` | `compute:read` or `compute:network:read` | List storage containers |

**Input (query params):**

| Param | Type | Required | Description |
|---|---|---|---|
| `connection` | string | Yes | Connection (must be `nutanix`) |
| `id` | string | No | Filter by container ID |

**Driver Redirection (Nutanix only):**

| Condition | libcloud Method |
|---|---|
| `id` given | `driver.ex_get_storage_container_vmm(id)` → fallback `driver.ex_get_storage_container(id)` |
| No `id` | `driver.ex_list_storage_containers_vmm()` → fallback `driver.ex_list_storage_containers()` |

---

#### 5.4 Security Groups (Nutanix Only)

| # | Method | Path | Scope | Description |
|---|---|---|---|---|
| 45 | `GET` | `/v1/compute/security-groups` | `compute:network:read` or `compute:read` | List security groups |
| 46 | `POST` | `/v1/compute/security-groups` | `compute:network:manage` | Create security group |
| 47 | `DELETE` | `/v1/compute/security-groups/{group_id}` | `compute:network:manage` | Delete security group |

##### 5.4.1 `GET /v1/compute/security-groups`

**Input (query params):**

| Param | Type | Required | Description |
|---|---|---|---|
| `connection` | string | Yes | Connection (must be `nutanix`) |
| `id` | string | No | Filter by group ID |

**Driver Redirection (Nutanix only):**

| Condition | libcloud Method |
|---|---|
| `id` given | `driver.ex_get_security_group(group_id)` |
| No `id` | `driver.ex_list_security_groups()` |

##### 5.4.2 `POST /v1/compute/security-groups`

**Input:**
```json
{
  "connection": {
    "provider": "nutanix",
    "config": {
      "host": "prism.example.com",
      "port": 9440,
      "secure": true,
      "api_version": "v4.0",
      "verify_ssl_cert": false
    },
    "credentials": { "key": "admin", "secret": "..." }
  },
  "name": "web-sg",
  "description": "Security group for web servers",
  "vpc_id": "vpc_ext_12345"
}
```
| Field | Type | Required | Description |
|---|---|---|---|
| `connection` | object | **Yes** | Connection (must be `nutanix`) |
| `name` | string | **Yes** | Security group name |
| `description` | string | No | Description |
| `vpc_id` | string | No | VPC external ID |

**Driver Redirection (Nutanix only):**

| libcloud Method |
|---|
| `driver.ex_create_security_group(name, description, vpc_ext_id)` |

##### 5.4.3 `DELETE /v1/compute/security-groups/{group_id}`

**Driver Redirection (Nutanix only):**

| libcloud Method |
|---|
| `driver.ex_delete_security_group(group_id)` |

---

#### 5.5 Load Balancers (Nutanix Only)

| # | Method | Path | Scope | Description |
|---|---|---|---|---|
| 48 | `GET` | `/v1/compute/load-balancers` | `compute:network:read` or `compute:read` | List load balancers |
| 49 | `POST` | `/v1/compute/load-balancers` | `compute:network:manage` | Create load balancer |
| 50 | `DELETE` | `/v1/compute/load-balancers/{lb_id}` | `compute:network:manage` | Delete load balancer |

##### 5.5.1 `GET /v1/compute/load-balancers`

**Input (query params):**

| Param | Type | Required | Description |
|---|---|---|---|
| `connection` | string | Yes | Connection (must be `nutanix`) |
| `id` | string | No | Filter by LB ID |

**Driver Redirection (Nutanix only):**

| Condition | libcloud Method |
|---|---|
| `id` given | `driver.ex_get_load_balancer(lb_id)` |
| No `id` | `driver.ex_list_load_balancers()` |

##### 5.5.2 `POST /v1/compute/load-balancers`

**Input:**
```json
{
  "connection": {
    "provider": "nutanix",
    "config": {
      "host": "prism.example.com",
      "port": 9440,
      "secure": true,
      "api_version": "v4.0",
      "verify_ssl_cert": false
    },
    "credentials": { "key": "admin", "secret": "..." }
  },
  "name": "web-lb",
  "vpc_id": "vpc_ext_12345",
  "external_ip": null
}
```
| Field | Type | Required | Description |
|---|---|---|---|
| `connection` | object | **Yes** | Connection (must be `nutanix`) |
| `name` | string | **Yes** | Load balancer name |
| `vpc_id` | string | **Yes** | VPC external ID |
| `external_ip` | string | No | External IP address |

**Driver Redirection (Nutanix only):**

| libcloud Method |
|---|
| `driver.ex_create_load_balancer(name, vpc_ext_id, external_ip)` |

##### 5.5.3 `DELETE /v1/compute/load-balancers/{lb_id}`

**Driver Redirection (Nutanix only):**

| libcloud Method |
|---|
| `driver.ex_delete_load_balancer(lb_id)` |

---

### 6. Job API

**Prefix:** `/v1/jobs`

| # | Method | Path | Auth | Scope | Description |
|---|---|---|---|---|---|
| 51 | `GET` | `/v1/jobs/{job_id}` | Bearer | `jobs:read` | Poll job status |

#### 6.1 `GET /v1/jobs/{job_id}`

**Special Header:** `Authorization: Bearer <token>` (needs `jobs:read` scope)

**Input:** `job_id` in path

**Output:**
```json
{
  "data": {
    "id": "job_a1b2c3d4e5f6a7b8",
    "operation": "create_node",
    "status": "completed",
    "requested_by": "admin",
    "connection_target": "aws:us-east-1",
    "provider": "aws",
    "progress": 100,
    "result_resource_id": "i-0abcd1234efgh5678",
    "result": { "id": "i-0abcd1234efgh5678", "name": "my-vm", ... },
    "error_code": null,
    "error_message": null,
    "submitted_at": "2026-06-22T10:30:00.000Z",
    "started_at": "2026-06-22T10:30:01.000Z",
    "completed_at": "2026-06-22T10:32:15.000Z"
  },
  "meta": { "request_id": "..." }
}
```

**Job Status Lifecycle:**
```
pending → running → completed
                  → failed (with error_code + error_message)
```

**Authorization:** The requesting user's `sub` must match `job.requested_by`, unless the token has `admin:connections:read` scope. Sensitive keys (`password`, `secret`, `key`, `private_key`, `public_key`) and the entire `credentials` object are redacted in `request_payload_redacted`.

### 7. Health API

| # | Method | Path | Auth | Scope | Description |
|---|---|---|---|---|---|
| 52 | `GET` | `/health` | None | — | Health check |

**Output:**
```json
{
  "data": { "status": "ok" },
  "meta": { "request_id": "..." }
}
```

---

## Libcloud Driver Redirection Map

This table shows the exact libcloud method called for each API endpoint, per provider.

| API Endpoint | AWS Driver Method | Nutanix Driver Method |
|---|---|---|
| `GET /locations` | `driver.list_locations()` | `driver.ex_list_clusters()` |
| `GET /images` | `driver.list_images()` | `driver.list_images()` |
| `POST /images` | Not supported | `ex_create_image_from_url()` or `create_image()` |
| `DELETE /images/{id}` | `driver.delete_image(image)` | `driver.delete_image(image)` |
| `GET /sizes` | `driver.list_sizes()` | `driver.list_sizes()` |
| `GET /nodes` | `driver.list_nodes()` | `driver.list_nodes()` |
| `GET /nodes/{id}` | `driver.ex_get_node(id)` | `driver.ex_get_node(id)` |
| `POST /nodes` | `driver.create_node(name, size, image, location, auth, ex_keyname, ex_securitygroup, ex_subnet, ex_assign_public_ip, ex_metadata, ...)` | `driver.create_node(name, size, image, location, auth, ex_subnet, ex_description, ex_memory_mib, ex_vcpus, ex_cores_per_vcpu, ex_storage_container, ex_disk_size_mib, ex_cloud_init, ex_nics, ex_categories, ex_power_on, ex_wait)` |
| `PATCH /nodes/{id}` (resize) | `driver.ex_change_node_size(node, size)` | Not supported |
| `PATCH /nodes/{id}` (tag) | `driver.ex_create_tags(node, {...})` | `driver.ex_create_tags(node, {...})` |
| `PATCH /nodes/{id}` (update) | Not supported | `driver.ex_update_node(id, name, description, ex_memory_mib)` |
| `POST /nodes/{id}:start` | `driver.start_node(node)` | `driver.start_node(node)` |
| `POST /nodes/{id}:stop` | `driver.stop_node(node)` | `driver.stop_node(node)` |
| `POST /nodes/{id}:reboot` | `driver.reboot_node(node)` | `driver.reboot_node(node)` |
| `DELETE /nodes/{id}` | `driver.destroy_node(node)` | `driver.destroy_node(node)` |
| `GET /volumes` | `driver.list_volumes()` / `ex_get_volume(id)` | `driver.list_volumes()` / `ex_get_volume(id)` |
| `POST /volumes` | `driver.create_volume(size, name, location, snapshot, ex_volume_type, ex_encrypted, ex_iops)` | `driver.create_volume(size, name, location, snapshot, ex_storage_container, ex_description)` |
| `PATCH /volumes/{id}` (modify) | `driver.ex_modify_volume(vol, size, volume_type, iops)` | Not supported |
| `PATCH /volumes/{id}` (tag) | `driver.ex_create_tags(vol, {...})` | `driver.ex_create_tags(vol, {...})` |
| `DELETE /volumes/{id}` | `driver.destroy_volume(volume)` | `driver.destroy_volume(volume)` |
| `POST /volumes/{id}:attach` | `driver.attach_volume(node, volume, device)` | `driver.attach_volume(node, volume, device)` |
| `POST /volumes/{id}:detach` | `driver.detach_volume(volume)` | `driver.detach_volume(volume, ex_vm_ext_id=node_id)` |
| `GET /snapshots` | `driver.list_snapshots()` / `ex_get_volume_snapshot(id)` | `driver.list_volume_snapshots(vol)` / `ex_get_volume_snapshot(id)` |
| `POST /snapshots` | `driver.create_volume_snapshot(volume, name)` | `driver.create_volume_snapshot(volume, name)` |
| `DELETE /snapshots/{id}` | `driver.destroy_volume_snapshot(snapshot)` | `driver.destroy_volume_snapshot(snapshot)` |
| `GET /key-pairs` | `driver.list_key_pairs()` | Not supported |
| `POST /key-pairs` | `driver.create_key_pair(name, public_key)` | Not supported |
| `DELETE /key-pairs/{name}` | `driver.delete_key_pair(name)` | Not supported |
| `GET /networks` | `driver.ex_list_networks()` | `driver.ex_list_vpcs()` / `ex_get_vpc(id)` |
| `POST /networks` | `driver.ex_create_network(name, cidr_block, instance_tenancy)` | `driver.ex_create_vpc(name, description, vpc_type, external_subnet_ext_ids)` |
| `PATCH /networks/{id}` (tag) | `driver.ex_create_tags(obj, {...})` | `driver.ex_create_tags(obj, {...})` |
| `PATCH /networks/{id}` (update) | Not supported | `driver.ex_update_vpc(id, name, description)` |
| `DELETE /networks/{id}` | `driver.ex_delete_network(network)` | `driver.ex_delete_vpc(id)` |
| `GET /subnets` | `driver.ex_list_subnets()` | `driver.ex_list_subnets()` / `ex_get_subnet(id)` |
| `POST /subnets` | `driver.ex_create_subnet(name, vpc_id, cidr_block, availability_zone)` | `driver.ex_create_subnet(name, subnet_type, cluster_ext_id, vpc_ext_id, network_id, description, is_external, ip_address, prefix_length, gateway_ip)` |
| `PATCH /subnets/{id}` (update) | Not supported | `driver.ex_update_subnet(id, name, description)` |
| `PATCH /subnets/{id}` (nat) | Not supported | `driver.ex_update_subnet(id, is_nat_enabled)` |
| `PATCH /subnets/{id}` (auto_public_ip) | `driver.ex_modify_subnet_attribute(id, "mapPublicIpOnLaunch", value)` | Not supported |
| `PATCH /subnets/{id}` (auto_ipv6) | `driver.ex_modify_subnet_attribute(id, "assignIpv6AddressOnCreation", value)` | Not supported |
| `PATCH /subnets/{id}` (tag) | `driver.ex_create_tags(subnet, {...})` | `driver.ex_create_tags(subnet, {...})` |
| `DELETE /subnets/{id}` | `driver.ex_delete_subnet(id)` | `driver.ex_delete_subnet(id)` |
| `GET /storage-containers` | Not supported | `ex_list_storage_containers_vmm()` / `ex_list_storage_containers()` / `ex_get_storage_container*()` |
| `GET /security-groups` | Not supported | `driver.ex_list_security_groups()` / `ex_get_security_group(id)` |
| `POST /security-groups` | Not supported | `driver.ex_create_security_group(name, description, vpc_ext_id)` |
| `DELETE /security-groups/{id}` | Not supported | `driver.ex_delete_security_group(id)` |
| `GET /load-balancers` | Not supported | `driver.ex_list_load_balancers()` / `ex_get_load_balancer(id)` |
| `POST /load-balancers` | Not supported | `driver.ex_create_load_balancer(name, vpc_ext_id, external_ip)` |
| `DELETE /load-balancers/{id}` | Not supported | `driver.ex_delete_load_balancer(id)` |

---

## Provider-Specific `provider_options` Allowlists

These are the exact `ex_*` keys that pass through the filter in `app/compute/service.py:_filter_provider_options()`.

### AWS `provider_options`

| Key | Description |
|---|---|
| `ex_securitygroup` | Security group name |
| `ex_securitygroups` | List of security group names |
| `ex_security_group_ids` | List of security group IDs |
| `ex_keyname` | Key pair name |
| `ex_subnet` | Subnet object or ID |
| `ex_assign_public_ip` | Assign public IP (bool) |
| `ex_userdata` | User data / cloud-init script |
| `ex_metadata` | Metadata key-value pairs |
| `ex_blockdevicemappings` | Block device mappings |
| `ex_spot` | Spot instance configuration |
| `ex_placement_group` | Placement group name |
| `ex_iamprofile` | IAM instance profile |
| `ex_volume_type` | Volume type (gp3, io2, etc.) |
| `ex_encrypted` | Encrypt volume (bool) |
| `ex_iops` | Provisioned IOPS |

### Nutanix `provider_options`

| Key | Description |
|---|---|
| `ex_subnet` | Subnet object or ID |
| `ex_description` | VM description |
| `ex_cluster` | Cluster ID/name |
| `ex_memory_mib` | Memory in MiB |
| `ex_vcpus` | Number of vCPUs |
| `ex_cores_per_vcpu` | Cores per vCPU |
| `ex_storage_container` | Storage container reference |
| `ex_disk_size_mib` | Disk size in MiB |
| `ex_user_data` | User data / cloud-init |
| `ex_cloud_init` | Cloud-init configuration |
| `ex_nics` | Network interface configuration |
| `ex_categories` | Nutanix categories |
| `ex_power_on` | Power on after create (bool) |
| `ex_wait` | Wait for completion (bool) |

---

## Full Scope Reference

16 scopes total. Each API endpoint requires one or more of these scopes in the JWT token.

| Scope | Description | Required By |
|---|---|---|
| `compute:read` | Read-only access to all compute resources | List nodes, images, sizes, locations, volumes, snapshots, key-pairs |
| `compute:image:read` | List images | `GET /images` |
| `compute:image:manage` | Create/delete images | `POST /images`, `DELETE /images/{id}` |
| `compute:size:read` | List instance sizes | `GET /sizes` |
| `compute:location:read` | List locations/clusters | `GET /locations` |
| `compute:node:create` | Create VMs | `POST /nodes` |
| `compute:node:delete` | Delete VMs | `DELETE /nodes/{id}` |
| `compute:node:power` | Start/stop/reboot VMs | `POST /nodes/{id}:start`, `:stop`, `:reboot` |
| `compute:node:update` | Update/resize/tag VMs | `PATCH /nodes/{id}` |
| `compute:volume:manage` | Full volume management | All `/volumes` endpoints |
| `compute:snapshot:manage` | Full snapshot management | All `/snapshots` endpoints |
| `compute:network:read` | List network resources | `GET /networks`, `/subnets`, `/security-groups`, `/load-balancers`, `/storage-containers` |
| `compute:network:manage` | Create/update/delete network resources | `POST/PATCH/DELETE` on network resources |
| `compute:keypair:manage` | Manage key pairs | All `/key-pairs` endpoints |
| `jobs:read` | Poll job status | `GET /jobs/{job_id}` |
| `admin:connections:read` | Token introspection, admin job access | `POST /auth/token/introspect` |

**Scope Aliases:** `compute:read` implies `compute:image:read`, `compute:size:read`, `compute:location:read`, and `compute:network:read`.

---

## Credential Verification Flow (End-to-End)

This section describes how credentials are verified at every layer, from the moment a request arrives to the moment a libcloud driver call is made.

### 1. Authentication Layer: Token Verification

```
                    ┌─────────────────────────────────────────────────────────────┐
                    │            app/auth/dependencies.py:_decode_token()          │
                    │                                                             │
  Bearer token ───>│  auth_mode? ──┬── local ──> auth_service.decode_access_token │
                    │              │           (HS256 JWT verify + JTI check)     │
                    │              ├── oidc ───> oidc_auth_service.decode_token   │
                    │              │           (JWKS or client-secret verify)     │
                    │              └── hybrid ─> _looks_like_oidc_token?          │
                    │                          ├── yes ──> try OIDC first         │
                    │                          └── no ───> fall back to local     │
                    └─────────────────────────────────────────────────────────────┘
```

**Three auth modes control which verification path is used:**

#### Mode A: `local` (HS256, self-issued JWTs)

File: `app/auth/service.py`

1. `decode_access_token(token)` calls `jwt.decode()` with `settings.jwt_signing_key` (HS256).
2. PyJWT validates: signature, `exp` (expiry), `iss` (issuer), `aud` (audience).
3. Checks the `jti` (JWT ID) against the in-memory `_revoked_jtis` set — if the token was explicitly logged out, it's rejected.
4. Returns `TokenClaims` with user identity, scopes, allowed providers, session ID.

#### Mode B: `oidc` (Authentik-issued tokens)

File: `app/auth/oidc_service.py`

1. `decode_access_token(token)` reads the unverified JWT header to detect the algorithm:
   - **RS256/ES256/PS256:** Fetches the signing key from Authentik's JWKS endpoint (`settings.oidc_jwks_url`) via `PyJWKClient`. The JWKS URL is typically `https://<authentik>/application/o/<slug>/jwks/`. Keys are cached by `PyJWKClient`.
   - **HS256:** Decodes using `settings.oidc_client_secret` as the shared symmetric key.
2. PyJWT validates: signature via JWKS or shared secret, `exp`, `iss`, `aud`.
3. Extracts `preferred_username` (falls back to `sub`) as the user identity.
4. Maps the username to libcloud scopes via `USERNAME_SCOPES` dict:
   - `"admin"` → all 16 scopes
   - `"provisioner"` → 14 scopes (no admin, no image manage)
   - `"reader"` → 7 read-only scopes
5. Maps the username to allowed providers via `USERNAME_PROVIDERS` dict.
6. Returns `TokenClaims` — indistinguishable from local tokens downstream.

#### Mode C: `hybrid` (accepts both)

File: `app/auth/dependencies.py:_decode_token()`

1. Calls `oidc_auth_service._looks_like_oidc_token(token)`:
   - Returns `True` if: algorithm is RS/ES/PS (asymmetric = definitely OIDC), OR algorithm is HS AND `iss` claim matches `settings.oidc_issuer_url`.
   - Returns `False` otherwise (treat as local).
2. If OIDC-detected: tries `oidc_auth_service.decode_access_token()`. If it fails with anything other than `auth_invalid_token`/`auth_expired_token`, re-raises immediately. Otherwise falls through to local.
3. If not OIDC-detected (or OIDC failed gracefully): tries `auth_service.decode_access_token()`.

### 2. Authorization Layer: Policy Engine

```
                    ┌──────────────────────────────────────────────────────────────┐
                    │       app/auth/policy.py:PolicyEngine.authorize_connection()  │
                    │                                                              │
  TokenClaims ─────>│  Stage 1: JWT scope check                                    │
  ProviderConnection│     _token_has_scope(token_scopes, required_scope)           │
                    │     Also resolves compute:read → aliases                     │
                    │                                                              │
                    │  Stage 2: Provider allowlist check                           │
                    │     "*" in allowed_providers OR provider in allowed_providers│
                    │                                                              │
                    │  Stage 3: OpenFGA fine-grained check (_enforce_openfga)     │
                    │     IF fga_enabled:                                          │
                    │       check(user, "can_connect", "libcloud_api:main")        │
                    │       check(user, "can_use", "provider:aws")                 │
                    │       check(user, "can_provision"|"can_read", backend)       │
                    │     ELSE: skip (allow all)                                   │
                    │                                                              │
                    │  Returns: connection (on success)                            │
                    │  Raises: 401/403 on any failure                              │
                    └──────────────────────────────────────────────────────────────┘
```

**The `authorize_connection()` method is called by every compute/network route handler** as the first step after extracting the token claims. This is the single authorization gate; there is no way to reach a libcloud driver without passing through it.

### 3. Provider Credential Flow: Connection → Driver

```
                    ┌─────────────────────────────────────────────────────┐
                    │        app/providers/factory.py:build_driver()      │
                    │                                                     │
  ProviderConnection │  connection.provider == "aws"?                     │
  (from request) ───>│    → create_aws_driver(key, secret, config)        │
                    │      → Provider.EC2 driver                          │
                    │                                                     │
                    │  connection.provider == "nutanix"?                  │
                    │    → create_nutanix_driver(key, secret, config)     │
                    │      → NutanixNodeDriver(host, port, secure, ...)   │
                    └─────────────────────────────────────────────────────┘
```

**Key point:** The provider credentials (`connection.credentials.key` and `connection.credentials.secret`) are extracted directly from the request body/query and passed to the libcloud driver constructor. They are:

- **Never stored** on the server's filesystem (users.json only stores JWT user records, not provider keys).
- **Never logged** (sensitive keys are redacted in async job payloads via `redact_payload()`).
- **Transient** — they exist only for the duration of the API call.

### 4. Complete Request Lifecycle

```
Client sends request:
  POST /v1/compute/nodes
  Authorization: Bearer <token>          ← Step 1: Auth header
  Body: {
    "connection": {                       ← Step 2: Provider credentials
      "provider": "aws",
      "config": {"region": "us-east-1"},
      "credentials": {"key": "AKIA...", "secret": "..."}
    },
    "name": "my-vm",
    "size": {"id": "t2.micro"},
    "image": {"id": "ami-xxx"}
  }

Server processing:

  RequestIDMiddleware                     ← Attach X-Request-ID
       │
       ▼
  get_current_claims()                    ← Step 3: Extract & verify Bearer token
       │                                    (local HS256, OIDC JWKS, or hybrid)
       ▼
  require_scopes("compute:node:create")   ← Step 4: Verify JWT scope
       │
       ▼
  policy_engine.authorize_connection()    ← Step 5: Provider allowlist + OpenFGA
       │                                    - JWT scope check (already done)
       │                                    - allowed_providers check
       │                                    - FGA: can_connect → can_use → can_provision
       ▼
  compute_service.create_node()           ← Step 6: Build driver from credentials
       │                                    build_driver(connection)
       │                                    → create_aws_driver(key, secret, config)
       ▼
  driver.create_node(**kwargs)            ← Step 7: Libcloud API call
       │
       ▼
  Serialize Node → NodeResponse           ← Step 8: Response model (passwords redacted)
       │
       ▼
  success_response(data, request)         ← Step 9: Wrap in standard envelope
```

### 5. Security Properties

| Property | How It's Achieved |
|---|---|
| **Token authenticity** | JWT signature verified against HS256 key (local) or Authentik JWKS/client-secret (OIDC) |
| **Token freshness** | `exp` claim validated; 15-minute access token TTL |
| **Token revocation** | JTI blacklist (`_revoked_jtis`) checked on every request; logout adds JTI to blacklist |
| **Scope enforcement** | `require_scopes()` / `require_any_scopes()` FastAPI dependencies check every endpoint |
| **Provider restriction** | `allowed_providers` claim checked by `PolicyEngine` |
| **Fine-grained access** | OpenFGA tuple checks: `can_connect` → `can_use` → `can_provision`/`can_read` |
| **Credential confidentiality** | Provider credentials never stored; redacted in async job payloads; excluded from logs |
| **Transport security** | All credentials transit in HTTPS request body; use TLS in production |

---

## Async Execution Summary

These operations support `"execution": {"mode": "async"}` in the request body:

| Endpoint | Job `operation` | Async Param |
|---|---|---|
| `POST /v1/compute/nodes` | `create_node` | `body.execution.mode = "async"` |
| `POST /v1/compute/volumes` | `create_volume` | `body.execution.mode = "async"` |
| `POST /v1/compute/snapshots` | `create_snapshot` | `body.execution.mode = "async"` |
| `POST /v1/compute/images` | `create_image` | `body.execution.mode = "async"` |
| `DELETE /v1/compute/nodes/{id}` | `destroy_node` | Query `async=true` |

Async jobs run on a `ThreadPoolExecutor` (4 workers). Poll with `GET /v1/jobs/{job_id}` (requires `jobs:read` scope).

---

## Credential Flow (Security Model)

```
1. Client holds provider credentials (AWS keys, Nutanix password, etc.)

2. Client logs in to the REST API:
   POST /v1/auth/login → receives JWT with scopes and allowed_providers
   OR
   Client obtains token from Authentik → presents OIDC token

3. Client calls compute/network API with connection in the request:
   GET /v1/compute/nodes?connection=<url-encoded-json>
   or
   POST /v1/compute/nodes { "connection": {...}, "name": "...", ... }

4. Server validates JWT/OIDC token (signature, expiry, issuer, audience, JTI)
   → Checks JWT scopes and allowed_providers
   → Checks OpenFGA tuples (if enabled)
   → Builds libcloud driver from connection.credentials
   → Calls driver.list_nodes() (or other operation)
   → Returns results to client

5. Async jobs redact credentials.key and credentials.secret in stored payloads
```

**Note:** Provider credentials transit the API in the `connection` object. Use HTTPS in production and treat the REST API as a trusted proxy boundary.

---

**End of Document**
