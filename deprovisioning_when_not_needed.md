
**No** — an AWS resource without an EC2 VM attached cannot always be safely deleted. Many resources have dependencies on non-EC2 services (Lambda, RDS, Load Balancers, NAT Gateways, VPC endpoints) that prevent deletion or cause cascading failures. Enhancing libcloud with a manual cleanup feature is feasible, but it must handle AWS's complex dependency graph.

## Why "No EC2 Attached" ≠ Safe to Delete

AWS resources form a deep dependency chain. Even with zero EC2 instances, resources can be locked by other services: [repost](https://repost.aws/questions/QUkGt8dt8BSDSwr7yz9kh5JQ/issues-deleting-vpc)

| Resource | Charged When Idle | Non-EC2 Dependencies That Block Deletion |
|---|---|---|
| Elastic IP (EIP) | Yes (~$3.60/mo if unattached) | None — but must check if referenced by NAT Gateway |
| EBS Volume | Yes | May be managed by AWS Backup  [access.redhat](https://access.redhat.com/solutions/7005014) |
| Network Interface (ENI) | No (but blocks VPC deletion) | Lambda, RDS Proxy, NAT Gateway, ALB/NLB, VPC endpoints, EFS  [repost](https://repost.aws/questions/QUkGt8dt8BSDSwr7yz9kh5JQ/issues-deleting-vpc) |
| Security Group | No | Referenced by ALB, Lambda, RDS, ENIs  [medium](https://medium.com/@vanshajbajaj1002/why-is-it-important-to-define-resource-dependencies-in-aws-cloudformation-25c98cbf3b54) |
| NAT Gateway | Yes (~$32/mo + data) | Referenced by route tables |
| Load Balancer (ALB/NLB) | Yes | Deletion protection flag; associated with target groups  [docs.aws.amazon](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-delete.html) |
| VPC | No | All subnets, route tables, SGs, ENIs must be gone first  [oneuptime](https://oneuptime.com/blog/post/2026-02-23-how-to-fix-error-deleting-vpc-dependencyviolation/view) |

A classic example: deleting a VPC fails because a Lambda function or RDS instance still holds an ENI in a subnet — even though no EC2 instance exists. [reddit](https://www.reddit.com/r/aws/comments/1fc1fc8/attempting_to_delete_all_resources_so_i_can/)

### Correct Deletion Order

AWS resources have a strict dependency ordering. The `grafiti` project (CoreOS) documents the universal deletion sequence: [github](https://github.com/coreos/grafiti/blob/master/Documentation/deletion-order.md)

```
S3 Objects → S3 Buckets
Route53 Records → Hosted Zones
EC2 Instances → AutoScaling Groups
Elastic IPs (release)
ENI (delete after detaching from consumers)
EBS Volumes
NAT Gateways
Subnets → Route Tables → Security Groups
Internet Gateway (detach then delete)
VPC (last)
```

Key gotchas include: [stackoverflow](https://stackoverflow.com/questions/71822160/cannot-delete-ec2)
- **Elastic Beanstalk** environments auto-scale new instances when you delete individual EC2s — you must delete the EB environment itself.
- **AWS Backup-managed snapshots** cannot be deleted via EC2 APIs — they require the Backup console/API.
- **Load Balancer deletion protection** must be explicitly disabled before deletion.

## Enhancing libcloud for Resource Cleanup

Apache libcloud's EC2 compute driver currently provides `destroy_node`, `destroy_volume`, `ex_destroy_image`, and similar granular methods, but lacks any orchestration for cascading dependency-aware cleanup. Adding a manual cleanup feature is architecturally sound — here's how it could work: [libcloud.readthedocs](https://libcloud.readthedocs.io/en/stable/compute/drivers/ec2.html)

### Proposed Feature: `cleanup_orphaned_resources()`

```python
class EC2NodeDriver(NodeDriver):
    def cleanup_orphaned_resources(self, region, vpc_id=None,
                                    dry_run=True, resource_types=None,
                                    exclude_tags=None):
        """
        Identify and optionally delete AWS resources with no EC2 instances
        attached, following the correct dependency order.
        """
        plan = self._discover_orphaned_resources(region, vpc_id, exclude_tags)
        
        if dry_run:
            return plan  # Returns deletion plan with cost savings estimate
        
        return self._execute_cleanup(plan, resource_types)
```

### Implementation Architecture

The feature would need three phases:

**Phase 1 — Discovery**: Enumerate all resources in a region/VPC and build a dependency graph. For each ENI, check its `Description` field to identify the owning service (Lambda, RDS, ALB, etc.). This is the critical step — the ENI description field reveals what non-EC2 service holds the resource. [repost](https://repost.aws/questions/QUkGt8dt8BSDSwr7yz9kh5JQ/issues-deleting-vpc)

**Phase 2 — Classification**: Categorize resources into:
- **Safe to delete**: Unattached EIPs, orphaned EBS volumes (not managed by AWS Backup), unused security groups with no references, empty target groups.
- **Conditionally deletable**: ENIs whose owning service can be identified and confirmed as deleted, NAT Gateways (check route table references), idle Load Balancers (check deletion protection).
- **Blocked**: Resources with active non-EC2 dependencies (Lambda VPC config, RDS instances, VPC endpoints).

**Phase 3 — Ordered Execution**: Delete in the correct dependency order as documented by grafiti, with rollback on failure. [github](https://github.com/coreos/grafiti/blob/master/Documentation/deletion-order.md)

### Key Design Considerations

- **Dry-run mode**: Always default to returning a plan with cost estimates before executing.
- **Cost estimation**: Query AWS Pricing API or use static rate cards to show monthly savings per resource.
- **Tag-based exclusions**: Respect `prevent-delete` tags or environment tags to protect resources.
- **Cross-service checks**: Must query not just EC2 but also Lambda (`GetFunctionConfiguration` for VPC settings), RDS (`DescribeDBInstances` for subnet groups), ELB (`DescribeLoadBalancers`), and VPC endpoints — libcloud would need boto3-style cross-service calls beyond its current EC2 driver scope.
- **libcloud's abstraction limitation**: libcloud's `BaseDriver` design is per-service (compute, storage, loadbalancer, dns). A full cleanup feature spans multiple AWS services, so it would either need to be a standalone utility module or require instantiating multiple libcloud drivers. [infoworld](https://www.infoworld.com/article/2246027/apache-libcloud-provides-single-python-api-for-all-clouds.html)

### Contribution Path

libcloud accepts contributions via GitHub following their development guide: [libcloud.readthedocs](https://libcloud.readthedocs.io/en/latest/development.html)

1. Fork `apache/libcloud` and create a feature branch.
2. Add the method to `libcloud/compute/drivers/ec2.py` (the `EC2NodeDriver` class). [libcloud.readthedocs](https://libcloud.readthedocs.io/en/stable/_modules/libcloud/compute/drivers/ec2.html)
3. For cross-service discovery, either use boto3 directly within the method (pragmatic approach) or extend libcloud's loadbalancer/dns drivers.
4. Add tests in `libcloud/test/compute/test_ec2.py` using mock fixtures.
5. Submit a PR referencing the cost-optimization use case.
