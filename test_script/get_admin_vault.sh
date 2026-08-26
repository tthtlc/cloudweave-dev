#VAULT_ADDR=$(grep VAULT_ADDR vault/generated/vault.env | cut -d= -f2) \
#VAULT_TOKEN=$(grep VAULT_ROOT_TOKEN vault/generated/vault.env | cut -d= -f2) \
#vault kv get secret/libcloud/nutanix

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

source $REPO_ROOT/vault/generated/vault.env
curl -s -H "X-Vault-Token: $VAULT_ROOT_TOKEN" \
    "$VAULT_ADDR/v1/secret/data/libcloud/nutanix" | jq .data.data

curl -s -H "X-Vault-Token: $VAULT_ROOT_TOKEN" \
    "$VAULT_ADDR/v1/secret/data/libcloud/aws" | jq .data.data


