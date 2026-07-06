
The mapping is: each `aws <service> <operation>` CLI command corresponds directly to a specific AWS API operation of the same name in the service’s HTTPS/REST (or JSON-RPC) API, e.g., `aws ec2 describe-instances` → EC2 `DescribeInstances`, `aws s3api list-buckets` → S3 `ListBuckets`. [aws.amazon](https://aws.amazon.com/blogs/aws/new-aws-command-line-interface-cli/)

## How AWS CLI maps to REST APIs

The AWS CLI is a thin wrapper over the AWS service APIs; every CLI “operation” name is the same as the underlying API operation name, with hyphens instead of camel case. For example, `aws SERVICE OPERATION` calls the API operation `Operation` in the `SERVICE` API, using signed HTTPS requests (SigV4). [hoop](https://hoop.dev/blog/mastering-aws-cli-through-rest-apis-for-reliable-automation/)

For most services, those operations are exposed via JSON over HTTP endpoints that are documented as “Actions” in the AWS SDK/API Reference, even if AWS doesn’t market them explicitly as “REST”. S3 is an exception that uses a more traditional REST-style resource model with operations like `ListBuckets` and `PutObject` that map to HTTP verbs on canonical paths. [aws.amazon](https://aws.amazon.com/blogs/aws/new-aws-command-line-interface-cli/)

## Identifying the REST API for a given CLI command

To find the exact API call for a particular CLI command:

1. Look up the CLI command in the AWS CLI reference; the page will name the corresponding API operation and link to the service API reference. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/apigatewayv2/get-api-mapping.html)
2. In the service’s API reference, each operation lists its HTTP method, request URI, and input/output model; this is the REST/HTTP mapping you are looking for. [awscli.amazonaws](https://awscli.amazonaws.com/v2/documentation/api/2.0.33/reference/apigateway/get-rest-apis.html)

As a concrete illustration, a command such as `aws s3api list-buckets` calls the Amazon S3 `ListBuckets` operation, which is an HTTP `GET` on the S3 service root, while something like `aws lambda invoke` hits Lambda’s `Invoke` endpoint for the specific function ARN you provide. [hoop](https://hoop.dev/blog/mastering-aws-cli-through-rest-apis-for-reliable-automation/)

If you paste the specific series of `aws` CLI invocations you care about, I can give you the exact REST/HTTP method and path for each one.
