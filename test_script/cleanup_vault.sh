
VAULT_ADDR=$(grep '^VAULT_ADDR=' ../vault/generated/vault.env | cut -d= -f2-)
  T=$(grep '^VAULT_ROOT_TOKEN=' ../vault/generated/vault.env | cut -d= -f2-)
  curl -sS -X DELETE -H "X-Vault-Token: $T" "$VAULT_ADDR/v1/secret/metadata/libcloud/aws-prod"
  curl -sS -X DELETE -H "X-Vault-Token: $T" "$VAULT_ADDR/v1/secret/metadata/libcloud/ntnx-lab"
