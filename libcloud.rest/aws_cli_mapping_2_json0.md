
Each `aws ec2 ...` command maps 1:1 to a specific EC2 API action with an underlying HTTPS request (JSON protocol), even though the exact wire-level “REST path” is abstracted behind the EC2 endpoint. Below is the mapping for every CLI call in your script.

## Command → API action table

| Script snippet / CLI command                            | AWS service | CLI operation              | Underlying AWS API action       | Notes |
|---------------------------------------------------------|------------|----------------------------|---------------------------------|-------|
| `aws ec2 describe-images ...`                           | EC2        | `describe-images`          | `DescribeImages`                | Used to find the latest AL2 AMI. |
| `aws ec2 describe-key-pairs ...`                        | EC2        | `describe-key-pairs`       | `DescribeKeyPairs`              | Lists existing key pairs. |
| `aws ec2 create-key-pair ...`                           | EC2        | `create-key-pair`          | `CreateKeyPair`                 | Creates a new key pair and returns the private key material. |
| `aws ec2 describe-vpcs --filters Name=isDefault,...`    | EC2        | `describe-vpcs`            | `DescribeVpcs`                  | First call filters for the default VPC. |
| `aws ec2 describe-vpcs` (no filters, fallback)          | EC2        | `describe-vpcs`            | `DescribeVpcs`                  | Second call just grabs the first VPC. |
| `aws ec2 describe-subnets --filters Name=vpc-id,...`    | EC2        | `describe-subnets`         | `DescribeSubnets`               | Gets a subnet within the chosen VPC. |
| `aws ec2 describe-security-groups --filters Name=vpc-id`| EC2        | `describe-security-groups` | `DescribeSecurityGroups`        | Retrieves a security group in that VPC. |
| `aws ec2 run-instances ...`                             | EC2        | `run-instances`            | `RunInstances`                  | Launches the EC2 instance with the selected parameters. |

## About “REST API” in this context

For EC2, the public documentation calls these “Actions” (e.g., `DescribeImages`, `RunInstances`), and the CLI simply signs and sends those actions to the EC2 endpoint (e.g., `https://ec2.ap-southeast-1.amazonaws.com`) using the EC2 query/JSON protocol rather than a resource-style REST path. In other words, mapping from CLI to AWS API is via the action name (camelCase / PascalCase) rather than a human-readable URI; what you’d typically document is the action name and service endpoint, as in the table above.

If you want, I can expand this into a more formal spec-style table that includes HTTP method, target endpoint, and example request payload structure for each of these actions.
