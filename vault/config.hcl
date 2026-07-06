# Vault server configuration (single-host, persistent file storage).
# Secrets and seal state are stored on the `vault-data` volume (mounted at
# /vault/file), so they survive reboot / restart / `docker compose down`.
#
# We use /vault/file (not a custom path) because the hashicorp/vault image's
# docker-entrypoint.sh automatically chowns /vault/file to the vault user when
# running as root (it su-exec's the server down to uid 100). A custom path like
# /vault/data would NOT be chowned, so the vault process couldn't write to it
# and `vault operator init` would fail with "permission denied".
#
# This is a local development / single-host configuration: the TCP listener
# disables TLS. For production, enable TLS on the listener and use Raft or an
# external KMS for auto-unseal.

storage "file" {
  path = "/vault/file"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

ui            = true
api_addr      = "http://0.0.0.0:8200"
disable_mlock = true
