#!/usr/bin/env bash
# Create a user in LLDAP with the supported fields:
#   username (uid), email, name (displayName), department, role, jobtitle
#
# `role` is a multi-valued attribute. Pass one or more roles as a
# comma-separated list, e.g. "engineer,oncall" -> roles ["engineer","oncall"].
#
# Usage:
#   create-user.sh <username> <email> <name> <department> <role[,role...]> <jobtitle> [password]
#
# If password is omitted, a random one is generated and printed.
# Runs inside the lldap-tools container or on the host.
set -euo pipefail

if [ "$#" -lt 6 ]; then
  echo "Usage: $0 <username> <email> <name> <department> <role[,role...]> <jobtitle> [password]" >&2
  exit 1
fi

USERNAME="$1"; EMAIL="$2"; NAME="$3"; DEPT="$4"; ROLE="$5"; JOBTITLE="$6"
PASSWORD="${7:-$(openssl rand -base64 18 | tr -d '/=+' | cut -c1-16)}"

: "${LLDAP_URL:=http://localhost:17170}"
: "${LLDAP_ADMIN_USER:=admin}"
: "${LLDAP_ADMIN_PASS:?LLDAP_ADMIN_PASS is required}"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

TOKEN=$(curl -fsS --max-time 10 -X POST "${LLDAP_URL}/auth/simple/login" \
  -H 'Content-Type: application/json' \
  -d '{"username":"'"${LLDAP_ADMIN_USER}"'","password":"'"${LLDAP_ADMIN_PASS}"'"}' \
  | jq -r '.token')

CREATE_QUERY='mutation CreateUser($user: CreateUserInput!) {
  createUser(user: $user) {
    id displayName email
    attributes { name value }
  }
}'

# Split the comma-separated role list into a JSON array of trimmed strings.
ROLE_ARRAY=$(printf '%s' "$ROLE" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')
[ "$(printf '%s' "$ROLE_ARRAY" | jq 'length')" -gt 0 ] || { echo "No valid roles provided in: $ROLE" >&2; exit 1; }

ATTRS=$(jq -nc \
  --arg dept "$DEPT" --argjson roles "$ROLE_ARRAY" --arg title "$JOBTITLE" \
  '[
    {"name":"department","value":[$dept]},
    {"name":"role","value":$roles},
    {"name":"jobtitle","value":[$title]}
  ]')

VARIABLES=$(jq -nc \
  --arg id "$USERNAME" --arg email "$EMAIL" --arg dn "$NAME" --argjson attrs "$ATTRS" \
  '{user:{id:$id, email:$email, displayName:$dn, attributes:$attrs}}')

RESP=$(curl -fsS --max-time 10 -X POST "${LLDAP_URL}/api/graphql" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${TOKEN}" \
  -d "$(jq -nc --arg q "$CREATE_QUERY" --argjson v "$VARIABLES" '{query:$q, variables:$v}')")

echo "$RESP" | jq '.data.createUser'

# Set the password over LDAP (PasswordModify extended op), admin bind.
python3 /scripts/set-password.py "$USERNAME" "$PASSWORD"

echo >&2
echo "Username : $USERNAME" >&2
echo "Password : $PASSWORD" >&2
