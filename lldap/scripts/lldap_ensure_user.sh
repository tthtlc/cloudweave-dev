#!/usr/bin/env bash
# lldap_ensure_user.sh
# ====================
# Idempotently ensure an LLDAP user exists with the given password.
# Used by setup.sh to create superadmin + per-cloud owners/admins/viewers.
#
# If the user does not exist, create it (via /scripts/create-user.sh). If it
# already exists, reset its password so it matches generated/dex.env.
#
# Runs inside the lldap-tools container:
#   docker compose -f ../lldap/docker-compose.yml run --rm lldap-tools \
#     /scripts/lldap_ensure_user.sh <uid> <email> <name> <dept> <role> <jobtitle> <password>
set -euo pipefail

if [[ "$#" -lt 7 ]]; then
  echo "Usage: $0 <uid> <email> <name> <dept> <role> <jobtitle> <password>" >&2
  exit 1
fi

UID_="$1"; EMAIL="$2"; NAME="$3"; DEPT="$4"; ROLE="$5"; JOBTITLE="$6"; PASSWORD="$7"

: "${LLDAP_URL:=http://lldap:17170}"
: "${LLDAP_ADMIN_USER:=admin}"
: "${LLDAP_ADMIN_PASS:?LLDAP_ADMIN_PASS is required}"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

TOKEN=$(curl -fsS --max-time 10 -X POST "${LLDAP_URL}/auth/simple/login" \
  -H 'Content-Type: application/json' \
  -d '{"username":"'"${LLDAP_ADMIN_USER}"'","password":"'"${LLDAP_ADMIN_PASS}"'"}' \
  | jq -r '.token')

# Does the user already exist?
QUERY='query($id: String!) { user(userId: $id) { id } }'
EXISTS=$(curl -fsS --max-time 10 -X POST "${LLDAP_URL}/api/graphql" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${TOKEN}" \
  -d "$(jq -nc --arg q "$QUERY" --arg id "$UID_" '{query:$q, variables:{id:$id}}')" \
  | jq -r '.data.user.id // empty')

if [[ -z "${EXISTS}" ]]; then
  echo "Creating LLDAP user ${UID_} ..." >&2
  /scripts/create-user.sh "$UID_" "$EMAIL" "$NAME" "$DEPT" "$ROLE" "$JOBTITLE" "$PASSWORD" >&2
else
  echo "LLDAP user ${UID_} already exists — syncing password ..." >&2
  python3 /scripts/set-password.py "$UID_" "$PASSWORD" >&2
fi
echo "OK ${UID_}"
