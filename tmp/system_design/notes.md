
inside the script "./scripts/provision_aws.sh" are the two statement 'openfga_authorization_flow "aws" "${AWS_BACKEND_OBJECT}"' and                          
  'build_aws_connection_param "${AWS_REGION}"' necessary in order to successfully execute the next statement after that.                                       

  Analyzing the two statements against what the subsequent code actually consumes:

  openfga_authorization_flow "aws" "${AWS_BACKEND_OBJECT}" — NOT necessary

  This function (scripts/common.sh:250-264) only runs OpenFGA fga_check calls against the FGA API. It reads ACCESS_TOKEN (already set by idp_login on line
  50) and LIBCLOUD_USER, but it does not export or modify any state that later statements depend on. It is a policy gate — its only side effect is exiting
  (via the [[ "$allowed" == ... ]] assertion under set -e) if authorization fails.

  That's why it is already commented out on line 51 and the script still proceeds. Removing it does not break libcloud_me, libcloud_connection_test, or any
  libcloud_api call — those depend on ACCESS_TOKEN (from idp_login) and CONNECTION_PARAM, not on anything this function produces.

   scripts/provision_aws.sh lines 50-55

  idp_login
  #openfga_authorization_flow "aws" "${AWS_BACKEND_OBJECT}"
  build_aws_connection_param "${AWS_REGION}"
  libcloud_me
  libcloud_connection_test "$(connection_json)"

  build_aws_connection_param "${AWS_REGION}" — NECESSARY

  This function (scripts/common.sh:301-316) sets and exports CONNECTION_PARAM, which is consumed by the very next steps:

  • connection_json (line 55) does json.loads(os.environ['CONNECTION_PARAM']) — an empty CONNECTION_PARAM (initialized to "" at common.sh:102) would raise
    JSONDecodeError and abort the script.

   scripts/common.sh lines 344-346

  connection_json() {
    CONNECTION_PARAM="${CONNECTION_PARAM}" python3 -c "import json,os; print(json.dumps(json.loads(os.environ['CONNECTION_PARAM']), indent=2))"
  }

  • libcloud_api (used at lines 58-63 and beyond) only adds the X-Provider-Connection header when CONNECTION_PARAM is non-empty; without it the REST API
    would not know which backend auth_binding/region to target.

   scripts/common.sh lines 283-295

  libcloud_api() {
    local method="$1" path="$2" body="${3:-}"
    local -a extra=()
    # Send the provider connection via the X-Provider-Connection header (never via
    # the `?connection=` query parameter, which leaks into logs/proxies/history).
    if [[ -n "${CONNECTION_PARAM}" ]]; then
      extra+=("-H" "X-Provider-Connection: ${CONNECTION_PARAM}")
    fi
    curl_http "${method}" "${LIBCLOUD_REST_URL}${path}" "${body}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Accept: application/json" \
      "${extra[@]}"
  }

  • with_connection (line 100) and the catalog/provisioning libcloud_api calls all rely on the same CONNECTION_PARAM.

  Summary

  ┌───────────────────────────────────────────┬──────────────────────────────┬─────────────────────────────────────────────────────────────────────────────┐
  │ Statement                                 │ Needed for the next          │ Why                                                                         │
  │                                           │ statements to run?           │                                                                             │
  ├───────────────────────────────────────────┼──────────────────────────────┼─────────────────────────────────────────────────────────────────────────────┤
  │ openfga_authorization_flow "aws"          │ No                           │ Pure authorization gate; produces no state consumed downstream. Already     │
  │ "${AWS_BACKEND_OBJECT}"                   │                              │ commented out.                                                              │
  ├───────────────────────────────────────────┼──────────────────────────────┼─────────────────────────────────────────────────────────────────────────────┤
  │ build_aws_connection_param                │ Yes                          │ Sets CONNECTION_PARAM, required by connection_json (next-but-one call) and  │
  │ "${AWS_REGION}"                           │                              │ every libcloud_api call.                                                    │
  └───────────────────────────────────────────┴──────────────────────────────┴─────────────────────────────────────────────────────────────────────────────┘

  Caveat: while openfga_authorization_flow is not execitionally required, it is the client-side mirror of the REST API's OpenFGA enforcement — skipping it
  means the script no longer fails fast on a user who lacks can_connect/can_use/can_provision before hitting the API; the REST API itself should still
  reject unauthorized calls.


