##docker compose up -d 
#
./test_iam.py --host rocky96 --user admin --password admin -v --version v4.0 --verbose

exit
usage: test_iam.py [-h] [--version {v4.0,v4.1.b2,v4.1.b3,all}] [--host HOST]
                   [--port PORT] [--user USER] [--password PASSWORD]
                   [--api-key API_KEY] [--list] [-v]

Test the Nutanix IAM Prism mocks.

options:
  -h, --help            show this help message and exit
  --version {v4.0,v4.1.b2,v4.1.b3,all}
                        which spec to test (default: all)
  --host HOST           mock host (default: localhost)
  --port PORT           override the port (single --version only)
  --user USER           Basic-auth user (default: admin)
  --password PASSWORD   Basic-auth password (default: admin)
  --api-key API_KEY     use X-ntnx-api-key instead of Basic auth
  --list                list endpoints without sending requests
  -v, --verbose         verbose output
