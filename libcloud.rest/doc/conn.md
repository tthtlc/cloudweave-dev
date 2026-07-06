
what is the structure of conn_aws_prod_sg and what are its values or contents?                                                                                

  Thought for 7s, searched for 1 pattern, read 2 files (ctrl+o to expand)

● Here's the structure and contents of conn_aws_prod_sg, defined in data/connections.json:2-32:

  Structure

  Each connection object has these top-level fields:

  ┌────────────────┬──────────┬───────────────────────────────────────────────┐
  │     Field      │   Type   │                  Description                  │
  ├────────────────┼──────────┼───────────────────────────────────────────────┤
  │ id             │ string   │ Unique identifier                             │
  ├────────────────┼──────────┼───────────────────────────────────────────────┤
  │ provider       │ string   │ Cloud provider name                           │
  ├────────────────┼──────────┼───────────────────────────────────────────────┤
  │ name           │ string   │ Human-readable display name                   │
  ├────────────────┼──────────┼───────────────────────────────────────────────┤
  │ auth_binding   │ object   │ Credential source (environment variable keys) │
  ├────────────────┼──────────┼───────────────────────────────────────────────┤
  │ config         │ object   │ Provider-specific connection parameters       │
  ├────────────────┼──────────┼───────────────────────────────────────────────┤
  │ allowed_scopes │ string[] │ Permission scopes granted to this connection  │
  ├────────────────┼──────────┼───────────────────────────────────────────────┤
  │ labels         │ object   │ Arbitrary key/value tags                      │
  ├────────────────┼──────────┼───────────────────────────────────────────────┤
  │ status         │ string   │ "active" or presumably "inactive"             │
  └────────────────┴──────────┴───────────────────────────────────────────────┘

  conn_aws_prod_sg values

  {
    "id": "conn_aws_prod_sg",
    "provider": "aws",
    "name": "aws-prod-singapore",
    "auth_binding": {
      "key_env": "LIBCLOUD_AWS_PROD_KEY",
      "secret_env": "LIBCLOUD_AWS_PROD_SECRET"
    },
    "config": {
      "region": "ap-southeast-1",
      "secure": true
    },
    "allowed_scopes": [
      "compute:read",
      "compute:image:read",
      "compute:image:manage",
      "compute:size:read",
      "compute:location:read",
      "compute:node:create",
      "compute:node:delete",
      "compute:node:power",
      "compute:node:update",
      "compute:volume:manage",
      "compute:snapshot:manage",
      "compute:network:read",
      "compute:network:manage",
      "compute:keypair:manage"
    ],
    "labels": {"env": "prod"},
    "status": "active"
  }

  Key takeaways:
  - It targets AWS in the ap-southeast-1 (Singapore) region with TLS enabled (secure: true).
  - Credentials come from the environment variables LIBCLOUD_AWS_PROD_KEY and LIBCLOUD_AWS_PROD_SECRET.
  - It has broad compute scopes covering read, node lifecycle, volumes, snapshots, networking, and keypairs — but notably no compute:image:create (only read and
  manage). 
  - It is labeled env: prod and is active.

  In clients/aws_client.py:284, this connection ID is used as the default when no --connection-id argument is passed:

  connection_id=args.connection_id or "conn_aws_prod_sg",

✻ Worked for 15s

※ recap: We looked up `conn_aws_prod_sg` — it's an active AWS connection targeting Singapore (`ap-southeast-1`) with credentials from 
  `LIBCLOUD_AWS_PROD_KEY`/`LIBCLOUD_AWS_PROD_SECRET` env vars and broad compute scopes. No pending task — this was a one-off lookup. (disable recaps in /config)


