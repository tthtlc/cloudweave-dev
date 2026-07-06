
Each of those `aws ec2` commands is a Query API action over HTTPS `POST` to the regional EC2 endpoint (e.g. `https://ec2.ap-southeast-1.amazonaws.com`), with `Action=...` and `Version=...` in the body plus your parameters. [flexera](https://www.flexera.com/blog/finops/aws-ec2-pricing-how-the-ec2-api-works-and-a-quick-tutorial-to-get-started/)

Below I stick to what your script actually sends (filters, owners, etc.), and show the effective HTTP method, high‑level payload structure, and EC2 action name.

## EC2 describe-images

Script:

```bash
aws ec2 describe-images \
  --region "$REGION" \
  --owners amazon \
  --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
  --query "Images | sort_by(@, &CreationDate) | [-1].ImageId" \
  --output text
```

- HTTP method:  
  - `POST` (EC2 Query API). [documentation](https://documentation.help/ec2-dg-2009-03-01/ApiReference-Query-DescribeImages.html)
- Request target:  
  - URL: `https://ec2.${REGION}.amazonaws.com/`. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/ec2/)
- Action name:  
  - `DescribeImages`. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-images.html)
- Request payload (form-encoded query body): conceptually like:

  \[
  Action=DescribeImages,\ Owners.1=amazon,\ Filter.1.Name=name,\ Filter.1.Value.1=amzn2\text{-}ami\text{-}hvm\text{-}*\text{-}x86\_64\text{-}gp2,\ Version=2016\text{-}11\text{-}15
  \]

  In actual wire format, EC2 uses `Filter.n.Name` and `Filter.n.Value.m` parameters, along with `Owners.n` and the standard `Action` and `Version` fields. [documentation](https://documentation.help/ec2-dg-2009-03-01/ApiReference-Query-DescribeImages.html)

CLI-only pieces:
- `--query "Images | sort_by(@, &CreationDate) | [-1].ImageId"` and `--output text` are client-side JMESPath and formatting, not part of the HTTP request; they just process the JSON/XML response. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-images.html)

## EC2 describe-key-pairs

Script:

```bash
aws ec2 describe-key-pairs \
  --region "$REGION" \
  --query "KeyPairs[0].KeyName" \
  --output text
```

- HTTP method: `POST`. [flexera](https://www.flexera.com/blog/finops/aws-ec2-pricing-how-the-ec2-api-works-and-a-quick-tutorial-to-get-started/)
- Target URL: `https://ec2.${REGION}.amazonaws.com/`. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/ec2/)
- Action name: `DescribeKeyPairs`. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/ec2/)
- Request payload:

  \[
  Action=DescribeKeyPairs,\ Version=2016\text{-}11\text{-}15
  \]

  No additional parameters, since you’re not filtering by key name; the CLI’s `--query` and `--output` again act only client-side. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/ec2/)

## EC2 create-key-pair

Script:

```bash
aws ec2 create-key-pair \
  --region "$REGION" \
  --key-name "$keyname" \
  --query "KeyMaterial" \
  --output text
```

- HTTP method: `POST`. [flexera](https://www.flexera.com/blog/finops/aws-ec2-pricing-how-the-ec2-api-works-and-a-quick-tutorial-to-get-started/)
- Target URL: `https://ec2.${REGION}.amazonaws.com/`. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/ec2/)
- Action name: `CreateKeyPair`. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/ec2/)
- Request payload:

  \[
  Action=CreateKeyPair,\ KeyName={keyname},\ Version=2016\text{-}11\text{-}15
  \]

  Response body contains the key pair metadata plus the private key material (PEM) as a string; the CLI extracts `KeyMaterial` and writes it to `${keyname}.pem` for you. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/ec2/)

## EC2 describe-vpcs (with filter and fallback)

Scripts:

```bash
aws ec2 describe-vpcs \
  --region "$REGION" \
  --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" \
  --output text

aws ec2 describe-vpcs \
  --region "$REGION" \
  --query "Vpcs[0].VpcId" \
  --output text
```

- HTTP method: `POST`. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/ec2/)
- Target URL: `https://ec2.${REGION}.amazonaws.com/`. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/ec2/)
- Action name: `DescribeVpcs`. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/ec2/)
- Request payload (first call, default-only):

  \[
  Action=DescribeVpcs,\ Filter.1.Name=isDefault,\ Filter.1.Value.1=true,\ Version=2016\text{-}11\text{-}15
  \]

- Request payload (second call, no filters):

  \[
  Action=DescribeVpcs,\ Version=2016\text{-}11\text{-}15
  \]

Again, `--query` and `--output` are client-side response processing only. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/ec2/)

## EC2 describe-subnets

Script:

```bash
aws ec2 describe-subnets \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$vpcid" \
  --query "Subnets[0].SubnetId" \
  --output text
```

- HTTP method: `POST`. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/ec2/)
- Target URL: `https://ec2.${REGION}.amazonaws.com/`. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/ec2/)
- Action name: `DescribeSubnets`. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/ec2/)
- Request payload:

  \[
  Action=DescribeSubnets,\ Filter.1.Name=vpc\text{-}id,\ Filter.1.Value.1={vpcid},\ Version=2016\text{-}11\text{-}15
  \]

The filter selects subnets belonging to the specific VPC ID. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/ec2/)

## EC2 describe-security-groups

Script:

```bash
aws ec2 describe-security-groups \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$vpcid" \
  --query "SecurityGroups[0].GroupId" \
  --output text
```

- HTTP method: `POST`. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/ec2/)
- Target URL: `https://ec2.${REGION}.amazonaws.com/`. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/ec2/)
- Action name: `DescribeSecurityGroups`. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/ec2/)
- Request payload:

  \[
  Action=DescribeSecurityGroups,\ Filter.1.Name=vpc\text{-}id,\ Filter.1.Value.1={vpcid},\ Version=2016\text{-}11\text{-}15
  \]

This filters SGs by VPC, then the CLI `--query` pulls the first `GroupId`. [docs.aws.amazon](https://docs.aws.amazon.com/cli/latest/reference/ec2/)

## EC2 run-instances

Script:

```bash
aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$ami" \
  --count 1 \
  --instance-type t2.micro \
  --key-name "$keyname" \
  --security-group-ids "$secgroupid" \
  --subnet-id "$subnetid"
```

- HTTP method: `POST`. [docs.aws.amazon](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_RunInstances.html)
- Target URL: `https://ec2.${REGION}.amazonaws.com/`. [flexera](https://www.flexera.com/blog/finops/aws-ec2-pricing-how-the-ec2-api-works-and-a-quick-tutorial-to-get-started/)
- Action name: `RunInstances`. [docs.aws.amazon](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_RunInstances.html)
- Request payload (conceptual EC2 Query form):

  \[
  \begin{aligned}
  &Action=RunInstances, \\
  &ImageId={ami}, \\
  &MinCount=1,\ MaxCount=1, \\
  &InstanceType=t2.micro, \\
  &KeyName={keyname}, \\
  &SecurityGroupId.1={secgroupid}, \\
  &SubnetId={subnetid}, \\
  &Version=2016\text{-}11\text{-}15
  \end{aligned}
  \]

The CLI turns `--count 1` into `MinCount=1` and `MaxCount=1` under the hood; `--security-group-ids` becomes `SecurityGroupId.n`; and `--subnet-id` maps directly to `SubnetId`. [docs.aws.amazon](https://docs.aws.amazon.com/botocore/latest/reference/services/ec2/client/run_instances.html)

***

If you’d like this in a single markdown table suitable for docs (with explicit example bodies or JSON-equivalent structures), do you prefer the native EC2 Query encoding (form-style `key=value` pairs) or a JSON model representation that mirrors SDK/CLI request shapes?

## libcloud REST API mapping (libcloud.rest)

Shell scripts under `aws_scripts/`, `nutanix_scripts/`, and `nutanix_vm_create/` now call `libcloud.rest` via curl. Shared helpers: `libcloud.rest/clients/common/rest_curl_lib.sh`.

| AWS CLI / EC2 action | libcloud REST |
|---|---|
| (auth) | `POST /v1/auth/login` |
| DescribeImages | `GET /v1/compute/images?owner=amazon&name=...` |
| DescribeKeyPairs | `GET /v1/compute/key-pairs` |
| CreateKeyPair | `POST /v1/compute/key-pairs` |
| DescribeVpcs | `GET /v1/compute/networks?is_default=true` |
| DescribeSubnets | `GET /v1/compute/subnets?vpc_id=...` |
| DescribeSecurityGroups | `GET /v1/compute/security-groups?vpc_id=...` |
| RunInstances | `POST /v1/compute/nodes` |
| DescribeInstances | `GET /v1/compute/nodes` |
| TerminateInstances | `DELETE /v1/compute/nodes/{id}` |
