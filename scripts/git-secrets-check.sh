#!/usr/bin/env bash
#
# git-secrets-check.sh — fail if Vault/Dex bootstrap secret material is tracked.
#
# Two checks, dependency-free (git + grep only):
#   1. Path check:  no tracked file may live under a generated/ env path
#                   (vault/generated/*.env, dex/generated/*.env).
#   2. Value check: no tracked file may contain an assigned Vault token or
#                   unseal key (VAULT_TOKEN= / VAULT_ROOT_TOKEN= /
#                   VAULT_UNSEAL_KEY= with a value), nor a standalone Vault
#                   token value (hvs./hvr. prefixes — gitleaks-compatible).
#
# The value check deliberately does NOT scan for bare "s.<...>" strings: that
# prefix collides with Python attribute access (e.g. `s.client_id`) and would
# false-positive across the codebase. Legacy "s." tokens are still caught when
# they appear in a VAULT_*TOKEN= assignment.
#
# Both checks run against the git index (--cached), so this also works as a
# pre-commit hook that inspects exactly what would be committed.
#
# Usage:
#   scripts/git-secrets-check.sh        # exit 0 = clean, 1 = leak found
#
# Install as a pre-commit hook:
#   ln -s ../../scripts/pre-commit .git/hooks/pre-commit
set -uo pipefail

fail=0

# --- 1. path check ----------------------------------------------------------
while IFS= read -r f; do
  echo "SECRET FILE TRACKED: $f" >&2
  echo "  fix: git rm --cached '$f' && commit" >&2
  fail=1
done < <(git ls-files 2>/dev/null | grep -E 'generated/.*\.env$' || true)

# --- 2. value check (single pass over the index) -----------------------------
# Assigned Vault token (any prefix) or unseal key, plus standalone hvs./hvr. tokens.
assigned_re='VAULT_(ROOT_)?TOKEN[[:space:]]*=[[:space:]]*(hvs|hvr|s)\.[A-Za-z0-9_-]{20,}'
unseal_re='VAULT_UNSEAL_KEY[[:space:]]*=[[:space:]]*[A-Za-z0-9+/=]{24,}'
bare_re='(hvs|hvr)\.[A-Za-z0-9_-]{20,}'

hits="$(git grep --cached -n -I -E -e "$assigned_re" -e "$unseal_re" -e "$bare_re" 2>/dev/null || true)"
if [[ -n "$hits" ]]; then
  echo "SECRET VALUE DETECTED:" >&2
  printf '%s\n' "$hits" >&2
  fail=1
fi

exit "$fail"
