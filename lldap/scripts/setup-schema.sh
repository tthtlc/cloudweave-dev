#!/usr/bin/env bash
# Idempotently creates the custom user attributes (department, role, jobtitle)
# via LLDAP's GraphQL API, then prints the resulting user schema.
#
# Runs inside the lldap-tools container or on the host. Reads connection info
# from environment variables (provided by docker-compose).
set -euo pipefail

: "${LLDAP_URL:=http://localhost:17170}"
: "${LLDAP_ADMIN_USER:=admin}"
: "${LLDAP_ADMIN_PASS:?LLDAP_ADMIN_PASS is required}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2; exit 1
fi

echo "Waiting for LLDAP web UI at ${LLDAP_URL} ..."
for i in $(seq 1 60); do
  if curl -fsS --max-time 3 "${LLDAP_URL}/" -o /dev/null 2>/dev/null; then break; fi
  sleep 1
  [ "$i" -eq 60 ] && { echo "LLDAP did not become ready in time" >&2; exit 1; }
done

echo "Authenticating as ${LLDAP_ADMIN_USER} ..."
LOGIN_RESP=$(curl -fsS --max-time 10 -X POST "${LLDAP_URL}/auth/simple/login" \
  -H 'Content-Type: application/json' \
  -d '{"username":"'"${LLDAP_ADMIN_USER}"'","password":"'"${LLDAP_ADMIN_PASS}"'"}')
TOKEN=$(printf '%s' "$LOGIN_RESP" | jq -r '.token')
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "Login failed: $LOGIN_RESP" >&2; exit 1; }

gql() {
  curl -fsS --max-time 10 -X POST "${LLDAP_URL}/api/graphql" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${TOKEN}" \
    -d "$1"
}

create_attr() {
  local name="$1"
  local is_list="${2:-false}"
  local body='{"query":"mutation { addUserAttribute(name: \"'"$name"'\", attributeType: STRING, isList: '"$is_list"', isVisible: true, isEditable: true) { ok } }"}'
  local resp ok err
  resp=$(gql "$body" || true)
  ok=$(printf '%s' "$resp" | jq -r '.data.addUserAttribute.ok // empty' 2>/dev/null || true)
  err=$(printf '%s' "$resp" | jq -r '.errors[0].message // empty' 2>/dev/null || true)
  if [ "$ok" = "true" ]; then
    echo "  + Created attribute: $name (isList: $is_list)"
  elif [ -n "$err" ]; then
    echo "  = $name already exists ($err)"
  else
    echo "  ? $name -> $resp"
  fi
}

echo "Creating custom user attributes ..."
create_attr department false
create_attr role true
create_attr jobtitle false

echo "Current user attribute schema:"
gql '{"query":"{ schema { userSchema { attributes { name attributeType isList isEditable isHardcoded } } } }"}' \
  | jq '.data.schema.userSchema.attributes'
