
 NONCE='a939c046-9d11-e342-10be-5b742d9e8918'
 OTP='uWb6ZlXjCrGQYRXWiFetIuzB3bY4'
 UNSEAL_KEY='a7c77174caae380deb997cde03f1e2f132929dd46a24c73ea347c2d96be5b344'

  # Step 2: provide the unseal key
 curl -s -X PUT http://localhost:8200/v1/sys/generate-root/update \
    -H 'Content-Type: application/json' \
    -d "{\"key\": \"${UNSEAL_KEY}\", \"nonce\": \"${NONCE}\"}"

