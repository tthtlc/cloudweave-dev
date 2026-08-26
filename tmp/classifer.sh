set -x

# Dynamically read VAULT_TOKEN from vault/generated/vault.env
VAULT_TOKEN=$(grep '^VAULT_TOKEN=' vault/generated/vault.env | head -1 | cut -d= -f2-)

# 1. Is the new Vault token valid?
curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
    http://localhost:8200/v1/auth/token/lookup-self | python3 -m json.tool

# 2. Does the Nutanix secret exist?
curl -s -w "\nHTTP %{http_code}\n" -H "X-Vault-Token: $VAULT_TOKEN" \
    http://localhost:8200/v1/secret/data/libcloud/nutanix

  # 3. List secrets under libcloud/
curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
    http://localhost:8200/v1/secret/metadata/libcloud?list=true | python3 -m json.tool

