# Vault credential rotation + secret purge — runbook

Companion to `vault/ARCHITECTURE.md` §8.5. This is the ordered, copy-pasteable
command sequence for rotating the Vault root token / unseal key / orchestrator
token that were committed to git, un-tracking them, and purging them from git
history. Secrets are read into shell variables (`$ROOT`, `$UNSEAL`, …) so no
literal values appear.

`./vault/rotate_root_and_unseal.sh --yes` automates Phase 3 (the rotation); the
raw commands below are exactly what that script does.

---

## Phase 1 — Untrack the committed secrets

```bash
cd /home/ubuntu/libcloud_nutanix
git rm --cached vault/generated/vault.env dex/generated/dex.env
```

## Phase 2 — Commit the gate + scripts + gitignore

```bash
# Files created: vault/rotate_root_and_unseal.sh, scripts/git-secrets-check.sh,
# scripts/pre-commit, .github/workflows/secret-scan.yml; .gitignore edited.
git add .gitignore scripts/ .github/ vault/rotate_root_and_unseal.sh
git commit -m "chore(security): untrack committed Vault/Dex bootstrap secrets" \
  -m "Stop tracking the generated env files holding root token / unseal key /
orchestrator token; add rotation script + secret-scan gate." \
  -m "Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

## Phase 3 — Rotate Vault credentials

```bash
ADDR=http://127.0.0.1:8200
UNSEAL=$(sed -nE 's/^VAULT_UNSEAL_KEY=//p' vault/generated/vault.env | head -1)
ROOT=$(sed -nE 's/^VAULT_ROOT_TOKEN=//p' vault/generated/vault.env | head -1)
VAULT_ADDR_VAL=$(sed -nE 's/^VAULT_ADDR=//p' vault/generated/vault.env | head -1)

# 1) rekey the unseal key
NONCE=$(curl -sS -X PUT -H "X-Vault-Token: $ROOT" \
  -d '{"secret_shares":1,"secret_threshold":1}' "$ADDR/v1/sys/rekey/init" | jq -r .nonce)
NEW_UNSEAL=$(curl -sS -X PUT \
  -d "$(jq -cn --arg k "$UNSEAL" --arg n "$NONCE" '{key:$k,nonce:$n}')" \
  "$ADDR/v1/sys/rekey/update" | jq -r '.keys[0]')

# 2) generate a fresh root token (server-generated OTP, decoded by the CLI)
INIT=$(docker exec -e VAULT_ADDR=http://127.0.0.1:8200 vault vault operator generate-root -init -format=json)
GNONCE=$(echo "$INIT" | jq -r .nonce); OTP=$(echo "$INIT" | jq -r .otp)
UPD=$(docker exec -e VAULT_ADDR=http://127.0.0.1:8200 vault vault operator generate-root -format=json -nonce="$GNONCE" "$NEW_UNSEAL")
ENC=$(echo "$UPD" | jq -r '.encoded_root_token')
NEW_ROOT=$(docker exec -e VAULT_ADDR=http://127.0.0.1:8200 vault vault operator generate-root -format=json -decode="$ENC" -otp="$OTP" | jq -r .token)

# 3) mint a fresh orchestrator token
NEW_ORCH=$(curl -sS -X POST -H "X-Vault-Token: $NEW_ROOT" \
  -d '{"policies":["libcloud-vault-auth-read"],"ttl":"768h","renewable":true}' \
  "$ADDR/v1/auth/token/create" | jq -r '.auth.client_token')

# 4) persist the new credentials (0600)
umask 077
printf 'VAULT_ADDR=%s\nVAULT_TOKEN=%s\nVAULT_ROOT_TOKEN=%s\nVAULT_UNSEAL_KEY=%s\n' \
  "$VAULT_ADDR_VAL" "$NEW_ORCH" "$NEW_ROOT" "$NEW_UNSEAL" > vault/generated/vault.env
chmod 600 vault/generated/vault.env

# 5) revoke the old credentials (old root; old orchestrator dies via cascade)
curl -sS -X POST -H "X-Vault-Token: $NEW_ROOT" \
  -d "{\"token\":\"$ROOT\"}" "$ADDR/v1/auth/token/revoke"
```

## Phase 4 — Re-sync the API + recreate its container

Required or the running REST API keeps the dead token and returns 503
`server_credentials_unavailable` ("permission denied") on every backend call.

```bash
sed -i "s|^VAULT_TOKEN=.*|VAULT_TOKEN=$NEW_ORCH|" libcloud.rest/.env
docker compose -p libcloudrest -f libcloud.rest/docker-compose.yml up -d --force-recreate api
```

## Phase 5 — Commit the rotation-script fix

```bash
git add vault/rotate_root_and_unseal.sh
git commit -m "fix(vault): rotate root token via generate-root, not token/create" \
  -m "token/create with policies=[root] + ttl=0 expired immediately; use generate-root." \
  -m "Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

## Phase 6 — Purge the secrets from git history + force-push

```bash
curl -sSL https://raw.githubusercontent.com/newren/git-filter-repo/main/git-filter-repo \
  -o /tmp/git-filter-repo && chmod +x /tmp/git-filter-repo

git stash push -u -m "wip-before-history-purge"   # protect uncommitted work
/tmp/git-filter-repo --path vault/generated/vault.env \
  --path dex/generated/dex.env --invert-paths --force
git remote add origin https://github.com/tthtlc/cloudweave-dev.git   # filter-repo stripped it
git push --force origin main
git stash pop                                        # restore uncommitted work
```

## Verify

```bash
git ls-files | grep -E 'generated/(vault|dex)\.env' || echo "untracked"
git log --all --oneline -- vault/generated/vault.env dex/generated/dex.env || echo "purged from history"
bash scripts/git-secrets-check.sh                                     # exit 0
curl -s -o /dev/null -w '%{http_code}\n' -H "X-Vault-Token: $NEW_ORCH" \
  "$ADDR/v1/secret/data/libcloud-vault-auth/libcloud-nutanix"        # 200
```

---

## Notes

- **Phase 4 must follow Phase 3.** Rotation invalidates the old orchestrator
  token; the running `libcloud-rest-api` container holds it in its process
  environment and must be recreated to pick up the fresh value. Phases 4 and 6
  are otherwise independent.
- **Rotation is the real fix; purge is hygiene.** The values were already on
  GitHub; the purge stops future clones seeing them but GitHub may retain old
  objects (forks/PRs/GC) server-side.
- **Commit messages still name the files** (e.g. "modified: dex/generated/dex.env")
  — filenames only, no values. Scrub with `git filter-repo --message-callback` if
  required.
- The `.bak` produced by the script (`vault/generated/vault.env.bak.*`) holds the
  now-dead values; delete once verified.
