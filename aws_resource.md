Yes — Apache Libcloud can be enhanced into a useful AWS enumerator, but the cleanest approach is to treat enumeration as a **cross-driver inventory layer**, not as a feature of only the EC2 compute driver. Libcloud already exposes EC2 compute APIs plus separate S3 and Route 53 drivers, and the EC2 driver already includes many useful AWS extension methods for networks, subnets, route tables, security groups, internet gateways, network interfaces, images, volumes, and key pairs. [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html)

## Current coverage

Libcloud already gives you a strong base for the resources in your trimmed list. The EC2 compute driver supports `list_nodes`, `list_images`, `list_volumes`, `list_snapshots`, and extension methods such as `ex_list_networks`, `ex_list_subnets`, `ex_list_route_tables`, `ex_list_internet_gateways`, `ex_list_network_interfaces`, `ex_get_security_groups`, and key-pair listing methods, while S3 and Route 53 are covered by separate Libcloud storage and DNS drivers rather than the EC2 driver itself. Temporary AWS session credentials are also supported by Amazon drivers through the `token` constructor argument, which is important for real-world enumeration with STS-issued credentials. [github](https://github.com/zer1t0/awsenum)

## Recommended design

For your target resource set, I would add an `AWSInventoryFacade` on top of Libcloud instead of bloating `EC2NodeDriver` with mixed-service logic. That facade would instantiate Libcloud’s EC2, S3, and Route 53 drivers per region, normalize the returned objects into a common schema like `{service, resource_type, id, name, region, arn?, tags, relationships, raw}`, and expose a single `enumerate(profile="general")` entry point. This matches Libcloud’s provider split, where compute, object storage, and DNS are distinct APIs and drivers, so the enhancement remains aligned with Libcloud’s architecture rather than fighting it. [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html)

A good `general` profile for your list would map like this:

| Resource | Libcloud support | Suggested enhancement |
|---|---|---|
| IAM users / roles / policies | Not covered by Libcloud EC2/S3/Route53 drivers  [github](https://github.com/zer1t0/awsenum) | Add optional boto3-backed plugin or document as unsupported in core. |
| VPCs | `ex_list_networks`  [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html) | Normalize VPC CIDRs, default VPC flag, tenancy, tags. |
| Subnets | `ex_list_subnets`  [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html) | Add AZ, map-public-ip flag, available IP count if possible. |
| Route tables | `ex_list_route_tables`  [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html) | Parse routes and subnet associations into relationship edges. |
| Internet gateways | `ex_list_internet_gateways`  [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html) | Record attached VPC IDs and internet reachability hints. |
| NAT gateways | No direct EC2 Libcloud method shown  [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html) | Add AWS extension method or plugin using AWS API directly. |
| Security groups | `ex_get_security_groups` / `ex_list_security_groups`  [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html) | Normalize ingress/egress rules and referenced SGs/CIDRs. |
| Network interfaces | `ex_list_network_interfaces`  [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html) | Link ENIs to instance, subnet, SG, and public IP state. |
| EC2 instances | `list_nodes`  [github](https://github.com/zer1t0/awsenum) | Enrich with subnet, VPC, SG IDs, IAM profile, EBS mappings. |
| AMIs | `list_images`  [github](https://github.com/zer1t0/awsenum) | Filter owned/shared/public and expose root device and IMDS flags where available. |
| EBS volumes | `list_volumes`  [github](https://github.com/zer1t0/awsenum) | Add encrypted/type/iops/throughput and attachment metadata. |
| EBS snapshots | `list_snapshots`  [github](https://github.com/zer1t0/awsenum) | Add owner, volume lineage, encryption, and sharing state. |
| S3 buckets | S3 storage driver `list_containers`  [github](https://github.com/zer1t0/awsenum) | Add bucket region lookup, versioning, encryption, public-access hints. |
| Route 53 zones | Route53 DNS driver `list_zones`  [github](https://github.com/zer1t0/awsenum) | Add zone type and record-count metadata. |
| Route 53 records | Route53 DNS driver `list_records`  [github](https://github.com/zer1t0/awsenum) | Normalize alias/TTL/target data for dependency graphs. |

