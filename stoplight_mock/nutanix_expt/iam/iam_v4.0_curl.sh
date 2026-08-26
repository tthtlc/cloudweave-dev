#!/usr/bin/env bash
# =============================================================================
# Nutanix IAM v4.0 - every REST endpoint as a curl function.
# Generated from swagger-iam-v4.0-all.yaml (54 endpoints).
#
# Authentication: cookie derived from IAM authentication.
#   iam_login() authenticates once with Basic auth (PC_USERNAME/PC_PASSWORD
#   from .env) and stores the NTNX_IGW_SESSION cookie; every request below is
#   then sent with ONLY that cookie for access control.
#
# Usage:
#   ./iam_v4.0_curl.sh                          list all endpoints
#   ./iam_v4.0_curl.sh <operationId> [args...]  run one endpoint
#   ./iam_v4.0_curl.sh all-readonly             run every GET endpoint
#   ./iam_v4.0_curl.sh all                      run ALL endpoints incl. DELETE/POST
#                                       (requires FORCE_ALL=yes)
#
# Function arguments:
#   * path parameters (extId, userExtId) are positional, in path order
#   * "name=value" extra args become URL query parameters, e.g.
#       listUsers '$page=0' '$limit=50' '$filter=userType eq "LOCAL"'
#   * DELETE/PUT take the If-Match etag as second arg (default ${ETAG:-0};
#     "0" = do not check, matching Nutanix convention)
#   * JSON payloads: override via PAYLOAD='{...}' environment variable
#   * CURL_DRY_RUN=1 prints the exact curl command instead of running it
#
# WARNING: create*/update*/delete*/reset*/revoke*/share* functions mutate
# your Prism Central. Review the payload placeholders before running them.
# =============================================================================

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

IAM_BASE_PATH="/iam/v4.0/authn"   # probe endpoint used by iam_login()

# GET /iam/v4.0/authn/cert-auth-providers
#   Lists all configured certificate-based authentication providers
#   query params: $page $limit $filter $orderby $select
listCertAuthProviders() {
    _req GET "/iam/v4.0/authn/cert-auth-providers" "" "${@:1}"
}

# POST /iam/v4.0/authn/cert-auth-providers  # multipart/form-data (certificate upload)
#   Create certificate-based authentication provider
createCertAuthProvider() {
    _req_multipart POST "/iam/v4.0/authn/cert-auth-providers" "name=CAC" "clientCaChain=<string>" "isCertAuthEnabled=false" "isCacEnabled=true" "dirSvcExtID=e7742aa2-5139-45f3-bce7-ff51370d9a0f" "caCertFileName=@${CA_CERT_FILE:-test_cert.pem}"
#   set CA_CERT_FILE=/path/to/your/ca-chain.pem to upload your own file
}

# DELETE /iam/v4.0/authn/cert-auth-providers/{extId}
#   Delete certificate-based authentication provider
#   path args (positional): extId
#   headers: If-Match
deleteCertAuthProviderById() {
    local extId="${1:?usage: extId required}"
    local etag="${2:-${ETAG:-0}}"
    _req DELETE "/iam/v4.0/authn/cert-auth-providers/${extId}" "" "@If-Match: ${etag}" "${@:3}"
}

# GET /iam/v4.0/authn/cert-auth-providers/{extId}
#   Get certificate-based authentication provider
#   path args (positional): extId
getCertAuthProviderById() {
    local extId="${1:?usage: extId required}"
    _req GET "/iam/v4.0/authn/cert-auth-providers/${extId}" "" "${@:2}"
}

# PUT /iam/v4.0/authn/cert-auth-providers/{extId}  # multipart/form-data (certificate upload)
#   Update certificate-based authentication provider
#   path args (positional): extId
#   headers: If-Match
updateCertAuthProviderById() {
    local extId="${1:?usage: extId required}"
    local etag="${2:-${ETAG:-0}}"
    _req_multipart PUT "/iam/v4.0/authn/cert-auth-providers/${extId}" "@If-Match: ${etag}" "name=CAC" "clientCaChain=<string>" "isCertAuthEnabled=false" "isCacEnabled=true" "dirSvcExtID=e7742aa2-5139-45f3-bce7-ff51370d9a0f" "caCertFileName=@${CA_CERT_FILE:-test_cert.pem}"
#   set CA_CERT_FILE=/path/to/your/ca-chain.pem to upload your own file
}

# GET /iam/v4.0/authn/directory-services
#   List directory services
#   query params: $page $limit $filter $orderby $select
listDirectoryServices() {
    _req GET "/iam/v4.0/authn/directory-services" "" "${@:1}"
}

# POST /iam/v4.0/authn/directory-services
#   Create directory service
createDirectoryService() {
    local payload="${PAYLOAD:-'{"name": "AD1", "url": "ldap://{{host_name}}", "domainName": "domain1.com", "directoryType": "ACTIVE_DIRECTORY", "serviceAccount": {"username": "Administrator@domain1.com", "password": "Pa*******rd"}}'}"
    _req POST "/iam/v4.0/authn/directory-services" "$payload" "${@:1}"
}

# DELETE /iam/v4.0/authn/directory-services/{extId}
#   Delete directory service
#   path args (positional): extId
#   headers: If-Match
deleteDirectoryServiceById() {
    local extId="${1:?usage: extId required}"
    local etag="${2:-${ETAG:-0}}"
    _req DELETE "/iam/v4.0/authn/directory-services/${extId}" "" "@If-Match: ${etag}" "${@:3}"
}

# GET /iam/v4.0/authn/directory-services/{extId}
#   Get directory service
#   path args (positional): extId
getDirectoryServiceById() {
    local extId="${1:?usage: extId required}"
    _req GET "/iam/v4.0/authn/directory-services/${extId}" "" "${@:2}"
}

# PUT /iam/v4.0/authn/directory-services/{extId}
#   Update directory service
#   path args (positional): extId
#   headers: If-Match
updateDirectoryServiceById() {
    local extId="${1:?usage: extId required}"
    local payload="${PAYLOAD:-'{"name": "AD1", "url": "ldap://{{host_name}}", "domainName": "domain1.com", "directoryType": "ACTIVE_DIRECTORY", "serviceAccount": {"username": "Administrator@domain1.com", "password": "Pa*******rd"}}'}"
    local etag="${2:-${ETAG:-0}}"
    _req PUT "/iam/v4.0/authn/directory-services/${extId}" "$payload" "@If-Match: ${etag}" "${@:3}"
}

# POST /iam/v4.0/authn/directory-services/{extId}/$actions/search
#   Search user/group in directory service
#   path args (positional): extId
searchDirectoryService() {
    local extId="${1:?usage: extId required}"
    local payload="${PAYLOAD:-'{"query": "user"}'}"
    _req POST "/iam/v4.0/authn/directory-services/${extId}/\$actions/search" "$payload" "${@:2}"
}

# POST /iam/v4.0/authn/directory-services/{extId}/$actions/verify-connection-status
#   Check directory service connection
#   path args (positional): extId
connectionStatusDirectoryService() {
    local extId="${1:?usage: extId required}"
    local payload="${PAYLOAD:-'{"username": "<string>", "password": "<string>"}'}"
    _req POST "/iam/v4.0/authn/directory-services/${extId}/\$actions/verify-connection-status" "$payload" "${@:2}"
}

# GET /iam/v4.0/authn/saml-identity-providers
#   List SAML identity providers
#   query params: $page $limit $filter $orderby $select
listSamlIdentityProviders() {
    _req GET "/iam/v4.0/authn/saml-identity-providers" "" "${@:1}"
}

# POST /iam/v4.0/authn/saml-identity-providers
#   Create SAML identity provider
createSamlIdentityProvider() {
    local payload="${PAYLOAD:-'{"name": "saml1"}'}"
    _req POST "/iam/v4.0/authn/saml-identity-providers" "$payload" "${@:1}"
}

# DELETE /iam/v4.0/authn/saml-identity-providers/{extId}
#   Delete SAML identity provider
#   path args (positional): extId
#   headers: If-Match
deleteSamlIdentityProviderById() {
    local extId="${1:?usage: extId required}"
    local etag="${2:-${ETAG:-0}}"
    _req DELETE "/iam/v4.0/authn/saml-identity-providers/${extId}" "" "@If-Match: ${etag}" "${@:3}"
}

# GET /iam/v4.0/authn/saml-identity-providers/{extId}
#   Get SAML identity provider
#   path args (positional): extId
getSamlIdentityProviderById() {
    local extId="${1:?usage: extId required}"
    _req GET "/iam/v4.0/authn/saml-identity-providers/${extId}" "" "${@:2}"
}

# PUT /iam/v4.0/authn/saml-identity-providers/{extId}
#   Update SAML identity provider
#   path args (positional): extId
#   headers: If-Match
updateSamlIdentityProviderById() {
    local extId="${1:?usage: extId required}"
    local payload="${PAYLOAD:-'{"name": "saml1"}'}"
    local etag="${2:-${ETAG:-0}}"
    _req PUT "/iam/v4.0/authn/saml-identity-providers/${extId}" "$payload" "@If-Match: ${etag}" "${@:3}"
}

# GET /iam/v4.0/authn/saml-sp-metadata
#   Get SP-Metadata for SAML identity provider
getSamlSpMetadata() {
    _req GET "/iam/v4.0/authn/saml-sp-metadata" "" "${@:1}"
}

# GET /iam/v4.0/authn/user-groups
#   List user groups
#   query params: $page $limit $filter $orderby $select
listUserGroups() {
    _req GET "/iam/v4.0/authn/user-groups" "" "${@:1}"
}

# POST /iam/v4.0/authn/user-groups
#   Create user group
createUserGroup() {
    local payload="${PAYLOAD:-'{"groupType": "SAML", "idpId": "2f1fd196-b53b-4940-b873-139dac465c35"}'}"
    _req POST "/iam/v4.0/authn/user-groups" "$payload" "${@:1}"
}

# DELETE /iam/v4.0/authn/user-groups/{extId}
#   Delete user group
#   path args (positional): extId
#   headers: If-Match
deleteUserGroupById() {
    local extId="${1:?usage: extId required}"
    local etag="${2:-${ETAG:-0}}"
    _req DELETE "/iam/v4.0/authn/user-groups/${extId}" "" "@If-Match: ${etag}" "${@:3}"
}

# GET /iam/v4.0/authn/user-groups/{extId}
#   Get user group
#   path args (positional): extId
getUserGroupById() {
    local extId="${1:?usage: extId required}"
    _req GET "/iam/v4.0/authn/user-groups/${extId}" "" "${@:2}"
}

# GET /iam/v4.0/authn/users
#   List user(s)
#   query params: $page $limit $filter $orderby $select
listUsers() {
    _req GET "/iam/v4.0/authn/users" "" "${@:1}"
}

# POST /iam/v4.0/authn/users
#   Create user
createUser() {
    local payload="${PAYLOAD:-'{"username": "john_doe", "userType": "LOCAL"}'}"
    _req POST "/iam/v4.0/authn/users" "$payload" "${@:1}"
}

# POST /iam/v4.0/authn/users/$actions/change-password
#   Change password of user
changeUserPassword() {
    local payload="${PAYLOAD:-'{"username": "john_doe", "oldPassword": "<string>", "newPassword": "<string>"}'}"
    _req POST "/iam/v4.0/authn/users/\$actions/change-password" "$payload" "${@:1}"
}

# GET /iam/v4.0/authn/users/{extId}
#   Get user
#   path args (positional): extId
getUserById() {
    local extId="${1:?usage: extId required}"
    _req GET "/iam/v4.0/authn/users/${extId}" "" "${@:2}"
}

# PUT /iam/v4.0/authn/users/{extId}
#   Update user
#   path args (positional): extId
#   headers: If-Match
updateUserById() {
    local extId="${1:?usage: extId required}"
    local payload="${PAYLOAD:-'{"username": "john_doe", "userType": "LOCAL"}'}"
    local etag="${2:-${ETAG:-0}}"
    _req PUT "/iam/v4.0/authn/users/${extId}" "$payload" "@If-Match: ${etag}" "${@:3}"
}

# POST /iam/v4.0/authn/users/{extId}/$actions/change-state
#   Update active state of user
#   path args (positional): extId
updateUserState() {
    local extId="${1:?usage: extId required}"
    local payload="${PAYLOAD:-'{"status": "ACTIVE"}'}"
    _req POST "/iam/v4.0/authn/users/${extId}/\$actions/change-state" "$payload" "${@:2}"
}

# POST /iam/v4.0/authn/users/{extId}/$actions/reset-password
#   Reset user password
#   path args (positional): extId
resetUserPassword() {
    local extId="${1:?usage: extId required}"
    local payload="${PAYLOAD:-'{"newPassword": "<string>"}'}"
    _req POST "/iam/v4.0/authn/users/${extId}/\$actions/reset-password" "$payload" "${@:2}"
}

# GET /iam/v4.0/authn/users/{userExtId}/buckets-access-keys
#   List bucket access keys of user
#   path args (positional): userExtId
#   query params: $page $limit $filter $orderby
listUserBucketKeys() {
    local userExtId="${1:?usage: userExtId required}"
    _req GET "/iam/v4.0/authn/users/${userExtId}/buckets-access-keys" "" "${@:2}"
}

# POST /iam/v4.0/authn/users/{userExtId}/buckets-access-keys
#   Create bucket access key for user
#   path args (positional): userExtId
createBucketAccessKey() {
    local userExtId="${1:?usage: userExtId required}"
    local payload="${PAYLOAD:-'{"accessKeyName": "key1"}'}"
    _req POST "/iam/v4.0/authn/users/${userExtId}/buckets-access-keys" "$payload" "${@:2}"
}

# DELETE /iam/v4.0/authn/users/{userExtId}/buckets-access-keys/{extId}
#   Delete buckets access key of user
#   path args (positional): userExtId extId
#   headers: If-Match
deleteUserBucketKeyById() {
    local userExtId="${1:?usage: userExtId required}"
    local extId="${2:?usage: extId required}"
    local etag="${3:-${ETAG:-0}}"
    _req DELETE "/iam/v4.0/authn/users/${userExtId}/buckets-access-keys/${extId}" "" "@If-Match: ${etag}" "${@:4}"
}

# GET /iam/v4.0/authn/users/{userExtId}/buckets-access-keys/{extId}
#   Get bucket access key of user
#   path args (positional): userExtId extId
getUserBucketKeyById() {
    local userExtId="${1:?usage: userExtId required}"
    local extId="${2:?usage: extId required}"
    _req GET "/iam/v4.0/authn/users/${userExtId}/buckets-access-keys/${extId}" "" "${@:3}"
}

# POST /iam/v4.0/authn/users/{userExtId}/buckets-access-keys/{extId}/$actions/revoke
#   Revoke bucket access key of user
#   path args (positional): userExtId extId
revokeUserBucketAccessKey() {
    local userExtId="${1:?usage: userExtId required}"
    local extId="${2:?usage: extId required}"
    _req POST "/iam/v4.0/authn/users/${userExtId}/buckets-access-keys/${extId}/\$actions/revoke" "" "${@:3}"
}

# GET /iam/v4.0/authn/users/{userExtId}/keys
#   List keys for the user
#   path args (positional): userExtId
#   query params: $page $limit $filter $orderby $select
listUserKeys() {
    local userExtId="${1:?usage: userExtId required}"
    _req GET "/iam/v4.0/authn/users/${userExtId}/keys" "" "${@:2}"
}

# POST /iam/v4.0/authn/users/{userExtId}/keys
#   Create a key of the requested key type for a user
#   path args (positional): userExtId
createUserKey() {
    local userExtId="${1:?usage: userExtId required}"
    local payload="${PAYLOAD:-'{"name": "ApiKey1", "keyType": "API_KEY"}'}"
    _req POST "/iam/v4.0/authn/users/${userExtId}/keys" "$payload" "${@:2}"
}

# DELETE /iam/v4.0/authn/users/{userExtId}/keys/{extId}
#   Delete the requested key
#   path args (positional): userExtId extId
#   headers: If-Match
deleteUserKeyById() {
    local userExtId="${1:?usage: userExtId required}"
    local extId="${2:?usage: extId required}"
    local etag="${3:-${ETAG:-0}}"
    _req DELETE "/iam/v4.0/authn/users/${userExtId}/keys/${extId}" "" "@If-Match: ${etag}" "${@:4}"
}

# GET /iam/v4.0/authn/users/{userExtId}/keys/{extId}
#   Get the requested key
#   path args (positional): userExtId extId
getUserKeyById() {
    local userExtId="${1:?usage: userExtId required}"
    local extId="${2:?usage: extId required}"
    _req GET "/iam/v4.0/authn/users/${userExtId}/keys/${extId}" "" "${@:3}"
}

# POST /iam/v4.0/authn/users/{userExtId}/keys/{extId}/$actions/revoke
#   Revoke the requested key
#   path args (positional): userExtId extId
revokeUserKey() {
    local userExtId="${1:?usage: userExtId required}"
    local extId="${2:?usage: extId required}"
    _req POST "/iam/v4.0/authn/users/${userExtId}/keys/${extId}/\$actions/revoke" "" "${@:3}"
}

# GET /iam/v4.0/authz/authorization-policies
#   Lists all the authorization policies
#   query params: $page $limit $filter $orderby $expand $select
listAuthorizationPolicies() {
    _req GET "/iam/v4.0/authz/authorization-policies" "" "${@:1}"
}

# POST /iam/v4.0/authz/authorization-policies
#   Create authorization policy
createAuthorizationPolicy() {
    local payload="${PAYLOAD:-'{"displayName": "Policy1", "entities": [{}], "role": "b3a2c1ee-1b2a-42b0-aa39-634ff0b7daf9", "identities": [{}]}'}"
    _req POST "/iam/v4.0/authz/authorization-policies" "$payload" "${@:1}"
}

# DELETE /iam/v4.0/authz/authorization-policies/{extId}
#   Delete authorization policy
#   path args (positional): extId
#   headers: If-Match
deleteAuthorizationPolicyById() {
    local extId="${1:?usage: extId required}"
    local etag="${2:-${ETAG:-0}}"
    _req DELETE "/iam/v4.0/authz/authorization-policies/${extId}" "" "@If-Match: ${etag}" "${@:3}"
}

# GET /iam/v4.0/authz/authorization-policies/{extId}
#   Get authorization policy
#   path args (positional): extId
getAuthorizationPolicyById() {
    local extId="${1:?usage: extId required}"
    _req GET "/iam/v4.0/authz/authorization-policies/${extId}" "" "${@:2}"
}

# PUT /iam/v4.0/authz/authorization-policies/{extId}
#   Update authorization policy
#   path args (positional): extId
#   headers: If-Match
updateAuthorizationPolicyById() {
    local extId="${1:?usage: extId required}"
    local payload="${PAYLOAD:-'{"displayName": "Policy1", "entities": [{}], "role": "b3a2c1ee-1b2a-42b0-aa39-634ff0b7daf9", "identities": [{}]}'}"
    local etag="${2:-${ETAG:-0}}"
    _req PUT "/iam/v4.0/authz/authorization-policies/${extId}" "$payload" "@If-Match: ${etag}" "${@:3}"
}

# GET /iam/v4.0/authz/clients/{extId}
#   Get client
#   path args (positional): extId
getRegisteredClientById() {
    local extId="${1:?usage: extId required}"
    _req GET "/iam/v4.0/authz/clients/${extId}" "" "${@:2}"
}

# GET /iam/v4.0/authz/entities
#   List entities
#   query params: $page $limit $filter $orderby $select
listEntities() {
    _req GET "/iam/v4.0/authz/entities" "" "${@:1}"
}

# GET /iam/v4.0/authz/entities/{extId}
#   Get entity
#   path args (positional): extId
getEntityById() {
    local extId="${1:?usage: extId required}"
    _req GET "/iam/v4.0/authz/entities/${extId}" "" "${@:2}"
}

# GET /iam/v4.0/authz/operations
#   List operation(s)
#   query params: $page $limit $filter $orderby $select
listOperations() {
    _req GET "/iam/v4.0/authz/operations" "" "${@:1}"
}

# GET /iam/v4.0/authz/operations/{extId}
#   Get operation
#   path args (positional): extId
getOperationById() {
    local extId="${1:?usage: extId required}"
    _req GET "/iam/v4.0/authz/operations/${extId}" "" "${@:2}"
}

# GET /iam/v4.0/authz/roles
#   List role(s)
#   query params: $page $limit $filter $orderby $select
listRoles() {
    _req GET "/iam/v4.0/authz/roles" "" "${@:1}"
}

# POST /iam/v4.0/authz/roles
#   Create role
createRole() {
    local payload="${PAYLOAD:-'{"displayName": "custom_role1", "operations": ["2b3b78ac-d8ef-4c63-adae-0fcc965ad274"]}'}"
    _req POST "/iam/v4.0/authz/roles" "$payload" "${@:1}"
}

# DELETE /iam/v4.0/authz/roles/{extId}
#   Delete role
#   path args (positional): extId
#   headers: If-Match
deleteRoleById() {
    local extId="${1:?usage: extId required}"
    local etag="${2:-${ETAG:-0}}"
    _req DELETE "/iam/v4.0/authz/roles/${extId}" "" "@If-Match: ${etag}" "${@:3}"
}

# GET /iam/v4.0/authz/roles/{extId}
#   Get role
#   path args (positional): extId
getRoleById() {
    local extId="${1:?usage: extId required}"
    _req GET "/iam/v4.0/authz/roles/${extId}" "" "${@:2}"
}

# PUT /iam/v4.0/authz/roles/{extId}
#   Update role
#   path args (positional): extId
#   headers: If-Match
updateRoleById() {
    local extId="${1:?usage: extId required}"
    local payload="${PAYLOAD:-'{"displayName": "custom_role1", "operations": ["2b3b78ac-d8ef-4c63-adae-0fcc965ad274"]}'}"
    local etag="${2:-${ETAG:-0}}"
    _req PUT "/iam/v4.0/authz/roles/${extId}" "$payload" "@If-Match: ${etag}" "${@:3}"
}

usage() {
    cat <<'EOF'

iam_v4.0_curl.sh - Nutanix IAM curl endpoints (one function per endpoint)

Usage: ./iam_v4.0_curl.sh [operationId [args...] | all-readonly | all | help]

  AuthorizationPolicies
    listAuthorizationPolicies                     GET    /iam/v4.0/authz/authorization-policies
    createAuthorizationPolicy                     POST   /iam/v4.0/authz/authorization-policies
    deleteAuthorizationPolicyById                 DELETE /iam/v4.0/authz/authorization-policies/{extId}
    getAuthorizationPolicyById                    GET    /iam/v4.0/authz/authorization-policies/{extId}
    updateAuthorizationPolicyById                 PUT    /iam/v4.0/authz/authorization-policies/{extId}

  CertificateAuthenticationProviders
    listCertAuthProviders                         GET    /iam/v4.0/authn/cert-auth-providers
    createCertAuthProvider                        POST   /iam/v4.0/authn/cert-auth-providers
    deleteCertAuthProviderById                    DELETE /iam/v4.0/authn/cert-auth-providers/{extId}
    getCertAuthProviderById                       GET    /iam/v4.0/authn/cert-auth-providers/{extId}
    updateCertAuthProviderById                    PUT    /iam/v4.0/authn/cert-auth-providers/{extId}

  Clients
    getRegisteredClientById                       GET    /iam/v4.0/authz/clients/{extId}

  DirectoryServices
    listDirectoryServices                         GET    /iam/v4.0/authn/directory-services
    createDirectoryService                        POST   /iam/v4.0/authn/directory-services
    deleteDirectoryServiceById                    DELETE /iam/v4.0/authn/directory-services/{extId}
    getDirectoryServiceById                       GET    /iam/v4.0/authn/directory-services/{extId}
    updateDirectoryServiceById                    PUT    /iam/v4.0/authn/directory-services/{extId}
    searchDirectoryService                        POST   /iam/v4.0/authn/directory-services/{extId}/$actions/search
    connectionStatusDirectoryService              POST   /iam/v4.0/authn/directory-services/{extId}/$actions/verify-connection-status

  Entities
    listEntities                                  GET    /iam/v4.0/authz/entities
    getEntityById                                 GET    /iam/v4.0/authz/entities/{extId}

  Operations
    listOperations                                GET    /iam/v4.0/authz/operations
    getOperationById                              GET    /iam/v4.0/authz/operations/{extId}

  Roles
    listRoles                                     GET    /iam/v4.0/authz/roles
    createRole                                    POST   /iam/v4.0/authz/roles
    deleteRoleById                                DELETE /iam/v4.0/authz/roles/{extId}
    getRoleById                                   GET    /iam/v4.0/authz/roles/{extId}
    updateRoleById                                PUT    /iam/v4.0/authz/roles/{extId}

  SAMLIdentityProviders
    listSamlIdentityProviders                     GET    /iam/v4.0/authn/saml-identity-providers
    createSamlIdentityProvider                    POST   /iam/v4.0/authn/saml-identity-providers
    deleteSamlIdentityProviderById                DELETE /iam/v4.0/authn/saml-identity-providers/{extId}
    getSamlIdentityProviderById                   GET    /iam/v4.0/authn/saml-identity-providers/{extId}
    updateSamlIdentityProviderById                PUT    /iam/v4.0/authn/saml-identity-providers/{extId}
    getSamlSpMetadata                             GET    /iam/v4.0/authn/saml-sp-metadata

  UserGroups
    listUserGroups                                GET    /iam/v4.0/authn/user-groups
    createUserGroup                               POST   /iam/v4.0/authn/user-groups
    deleteUserGroupById                           DELETE /iam/v4.0/authn/user-groups/{extId}
    getUserGroupById                              GET    /iam/v4.0/authn/user-groups/{extId}

  Users
    listUsers                                     GET    /iam/v4.0/authn/users
    createUser                                    POST   /iam/v4.0/authn/users
    changeUserPassword                            POST   /iam/v4.0/authn/users/$actions/change-password
    getUserById                                   GET    /iam/v4.0/authn/users/{extId}
    updateUserById                                PUT    /iam/v4.0/authn/users/{extId}
    updateUserState                               POST   /iam/v4.0/authn/users/{extId}/$actions/change-state
    resetUserPassword                             POST   /iam/v4.0/authn/users/{extId}/$actions/reset-password
    listUserBucketKeys                            GET    /iam/v4.0/authn/users/{userExtId}/buckets-access-keys
    createBucketAccessKey                         POST   /iam/v4.0/authn/users/{userExtId}/buckets-access-keys
    deleteUserBucketKeyById                       DELETE /iam/v4.0/authn/users/{userExtId}/buckets-access-keys/{extId}
    getUserBucketKeyById                          GET    /iam/v4.0/authn/users/{userExtId}/buckets-access-keys/{extId}
    revokeUserBucketAccessKey                     POST   /iam/v4.0/authn/users/{userExtId}/buckets-access-keys/{extId}/$actions/revoke
    listUserKeys                                  GET    /iam/v4.0/authn/users/{userExtId}/keys
    createUserKey                                 POST   /iam/v4.0/authn/users/{userExtId}/keys
    deleteUserKeyById                             DELETE /iam/v4.0/authn/users/{userExtId}/keys/{extId}
    getUserKeyById                                GET    /iam/v4.0/authn/users/{userExtId}/keys/{extId}
    revokeUserKey                                 POST   /iam/v4.0/authn/users/{userExtId}/keys/{extId}/$actions/revoke

EOF
}

ALL_FUNCS=( listCertAuthProviders createCertAuthProvider deleteCertAuthProviderById getCertAuthProviderById updateCertAuthProviderById listDirectoryServices createDirectoryService deleteDirectoryServiceById getDirectoryServiceById updateDirectoryServiceById searchDirectoryService connectionStatusDirectoryService listSamlIdentityProviders createSamlIdentityProvider deleteSamlIdentityProviderById getSamlIdentityProviderById updateSamlIdentityProviderById getSamlSpMetadata listUserGroups createUserGroup deleteUserGroupById getUserGroupById listUsers createUser changeUserPassword getUserById updateUserById updateUserState resetUserPassword listUserBucketKeys createBucketAccessKey deleteUserBucketKeyById getUserBucketKeyById revokeUserBucketAccessKey listUserKeys createUserKey deleteUserKeyById getUserKeyById revokeUserKey listAuthorizationPolicies createAuthorizationPolicy deleteAuthorizationPolicyById getAuthorizationPolicyById updateAuthorizationPolicyById getRegisteredClientById listEntities getEntityById listOperations getOperationById listRoles createRole deleteRoleById getRoleById updateRoleById )
READONLY_FUNCS=( listCertAuthProviders getCertAuthProviderById listDirectoryServices getDirectoryServiceById listSamlIdentityProviders getSamlIdentityProviderById getSamlSpMetadata listUserGroups getUserGroupById listUsers getUserById listUserBucketKeys getUserBucketKeyById listUserKeys getUserKeyById listAuthorizationPolicies getAuthorizationPolicyById getRegisteredClientById listEntities getEntityById listOperations getOperationById listRoles getRoleById )

case "${1:-}" in
    ""|help|-h|--help)
        usage
        ;;
    all-readonly)
        iam_login
        for fn in "${READONLY_FUNCS[@]}"; do
            echo; echo "===== ${fn} ====="
            # subshell: a missing required arg aborts only this call
            ( "${fn}" ) || true
        done
        ;;
    all)
        if [[ "${FORCE_ALL:-}" != "yes" ]]; then
            echo "Refusing: 'all' includes DELETE/create/update actions." >&2
            echo "Run with FORCE_ALL=yes if you really mean it." >&2
            exit 1
        fi
        iam_login
        for fn in "${ALL_FUNCS[@]}"; do
            echo; echo "===== ${fn} ====="
            ( "${fn}" ) || true
        done
        ;;
    *)
        op="$1"; shift
        if declare -f "${op}" >/dev/null 2>&1; then
            iam_login
            "${op}" "$@"
        else
            echo "Unknown operationId: ${op}" >&2
            usage
            exit 1
        fi
        ;;
esac