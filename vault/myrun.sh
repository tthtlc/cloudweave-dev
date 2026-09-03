#  list_credentials.py
#
#  Recursively lists every secret under secret/libcloud/*, showing version metadata and key names (values hidden by default; --show-values to reveal).
#
#  python3 list_credentials.py
python3 list_credentials.py --show-values
#
#  add_credential.py
#
#  Writes a new secret (or new version of an existing one) at secret/libcloud/<name>. Three input modes:
#
#  python3 add_credential.py aws-staging --kv key=AKIA... --kv secret=...
#  python3 add_credential.py aws-staging --from-env LIBCLOUD_AWS_KEY LIBCLOUD_AWS_SECRET
#  python3 add_credential.py gcp-prod          # interactive: prompts for key/value pairs
#
#  delete_credential.py
#
#  Removes a secret. --yes skips the typed confirmation. Default deletes metadata + all versions; --destroy-versions only destroys current version data while
#  keeping metadata for audit.
#
#  python3 delete_credential.py aws-staging
#  python3 delete_credential.py aws-staging --yes
#  python3 delete_credential.py aws-staging --destroy-versions
#
