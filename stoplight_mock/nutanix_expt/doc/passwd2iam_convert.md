
In the modern Nutanix v4 API architecture, authorization moves away from temporary session tokens (or session cookies) in favor of API Keys mapped to Service Accounts. [1] 
To authenticate programmatic tools without hardcoding human credentials, you use your primary administrator username and password one time to request a permanent, secure API Key from the Nutanix IAM service. [2, 3] 
Follow these steps to convert your administrator credentials into a functional programmatic key using curl.
------------------------------
## Step 1: Find the User ID (extId) of Your Target Account
Before you can issue an API Key, you need the unique platform identifier (extId) of the account. Run this command to list users and find your ID:

curl --insecure --location --request GET \
  --url "https://<PRISM_CENTRAL_IP>:9440/api/iam/v4.0/authn/users" \
  --user "<USERNAME>:<PASSWORD>" \
  --header "Accept: application/json"

What to look for in the response:
Locate your user object in the JSON output and extract the "extId" value (a unique UUID string). [4] 
------------------------------
## Step 2: Generate the API Key via the IAM Service
Now, pass that extId into the URL payload to generate your long-term programmatic token. This uses your admin password to securely register the new credential: [2, 4] 

curl --insecure --location --request POST \
  --url "https://<PRISM_CENTRAL_IP>:9440/api/iam/v4.0/authn/users/<USER_EXT_ID>/keys" \
  --user "<USERNAME>:<PASSWORD>" \
  --header "Content-Type: application/json" \
  --header "Accept: application/json" \
  --data '{
    "name": "automation_api_key",
    "keyType": "API_KEY"
  }'

(Note: Replace <USER_EXT_ID> with the string gathered from Step 1). [4] 
Crucial Security Warning:
The JSON response will contain a long alphanumeric string under fields like apiKey or secretKey. Nutanix will only display this key once. Copy it immediately and save it securely in a password manager or secrets vault. [2, 4] 
------------------------------
## Step 3: Test and Use Your New Token
Once you have the key, you can safely strip your username and password out of your automation platforms. To make requests using your new token, pass it via the standard Authorization Header: [1, 5] 

curl --insecure --location --request GET \
  --url "https://<PRISM_CENTRAL_IP>:9440/api/vmm/v4.0/ahv/config/vms" \
  --header "Authorization: Basic <YOUR_NEW_API_KEY>" \
  --header "Accept: application/json"

Would you like help constructing an IAM Authorization Policy payload next to restrict this key so it can only manage a specific subnet or cluster?

[1] [https://www.nutanix.dev](https://www.nutanix.dev/2025/02/05/nutanix-v4-apis-using-api-key-authentication/)
[2] [https://www.nutanix.dev](https://www.nutanix.dev/2025/02/21/nutanix-v4-apis-using-api-key-authentication-part-2/)
[3] [https://www.nutanix.dev](https://www.nutanix.dev/2025/07/11/ncm-self-service-and-v4-iam-api-key-authentication/)
[4] [https://www.securefever.com](https://www.securefever.com/blog)
[5] [https://www.digitalocean.com](https://www.digitalocean.com/community/tutorials/workflow-downloading-files-curl)

