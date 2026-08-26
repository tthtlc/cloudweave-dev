
The closest Nutanix v4 equivalents are mostly in the `iam`, `networking`, `vmm`, `volumes`, and `objects` namespaces, with Prism Central acting as the control plane where those APIs are published. Nutanix v4 GA explicitly exposes namespaces for Identity and Access Management, Networking, Virtual Machine Management, Volumes, and Objects Storage Management, which makes it a good fit for an AWS-style inventory model focused on identity, network, compute, and storage. [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html)

## Resource mapping

Below is a practical AWS-to-Nutanix mapping for your trimmed list:

| AWS resource | Closest Nutanix v4 resource | Notes |
|---|---|---|
| IAM users | IAM users / identities in `iam`  [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html) | Direct identity-plane equivalent. |
| IAM roles | IAM roles in `iam`  [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html) | Role-based access equivalent. |
| IAM policies | IAM policies / permissions model in `iam`  [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html) | Use for authorization inventory. |
| VPCs | VPCs in `networking`  [nutanix](https://www.nutanix.dev/2023/02/28/nutanix-v4-api-update-february-2023/) | Strong conceptual match. |
| Subnets | Subnets in `networking`  [nutanix](https://www.nutanix.dev/2023/02/28/nutanix-v4-api-update-february-2023/) | Direct network segment equivalent. |
| Route tables | Routing constructs in `networking`  [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html) | Depends on exact exposed v4 resource model, but same control-plane area. |
| Internet gateways | External connectivity / gateway constructs in `networking`  [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html) | Similar purpose, though Nutanix implementation details differ from AWS IGW. |
| NAT gateways | NAT/external connectivity constructs in `networking`  [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html) | Conceptual match, not necessarily 1:1 object parity. |
| Security groups | Nutanix Flow / microseg security policy objects plus NIC/subnet security context  [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html) | Closer to policy-based microseg than AWS SG semantics. |
| Network interfaces | VM NICs in `vmm` plus subnet attachment in `networking`  [nutanix](https://www.nutanix.dev/2023/02/28/nutanix-v4-api-update-february-2023/) | Usually represented as part of VM resources. |
| EC2 instances | VMs in `vmm`  [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html) | Direct compute equivalent. |
| AMIs | Images in `vmm`  [nutanix](https://www.nutanix.dev/2023/02/28/nutanix-v4-api-update-february-2023/) | Direct template/image equivalent for VM provisioning. |
| EBS volumes | Volumes / disks in `volumes` and VM-attached disk resources in `vmm`  [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html) | Use both attached-disk and standalone volume views. |
| EBS snapshots | Snapshot/DP-style equivalents via `dataprotection` and volume/image lineage  [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html) | May not be a simple single-resource 1:1 match. |
| S3 buckets | Object store buckets in `objects`  [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html) | Strong conceptual match to S3 buckets. |

The biggest modeling differences are security groups, gateways, and snapshots. AWS has very explicit first-class resources for SGs, IGWs, NAT gateways, and EBS snapshots, while Nutanix often expresses equivalent behavior through a mix of `networking`, `microseg`, `vmm`, and `dataprotection` resources rather than a perfect object-for-object clone. [nutanix](https://www.nutanix.dev/2023/02/28/nutanix-v4-api-update-february-2023/)

## Libcloud fit

Apache Libcloud does not currently list a Nutanix provider in its supported provider matrix, so a Nutanix implementation would be a **new provider**, not an extension of an existing one. Libcloud’s architecture is still a good fit, because Nutanix has a clear VM plane, object-storage plane, and identity/networking planes exposed through Prism Central’s v4 namespaces and SDKs. That means a Nutanix integration can follow the same broad pattern Libcloud already uses for AWS: compute-style driver for VMs/images/volumes, object-storage driver for buckets, and provider-specific extensions for network and identity details. [github](https://github.com/zer1t0/awsenum)

## Driver design

The cleanest implementation is a new `NutanixNodeDriver` backed by Prism Central v4 APIs, plus optional `NutanixObjectsStorageDriver` for buckets. Nutanix v4 emphasizes SDK support, OData filtering, sorting, selection, and pagination, so the driver should be built around those primitives from day one rather than bolting them on later. [securitycafe](https://securitycafe.ro/2022/11/01/aws-enumeration-part-1/)

A practical design would be:

- `libcloud.compute.drivers.nutanix.NutanixNodeDriver`
- `list_nodes()` -> `vmm` VMs [nutanix](https://www.nutanix.dev/2023/02/28/nutanix-v4-api-update-february-2023/)
- `list_images()` -> `vmm` images [nutanix](https://www.nutanix.dev/2023/02/28/nutanix-v4-api-update-february-2023/)
- `list_volumes()` -> `volumes` plus attached-disk normalization from `vmm` [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html)
- `list_sizes()` -> normalized VM sizing/profile abstraction derived from VM hardware config and cluster capabilities
- `create_node()` -> compose calls across `clustermgmt`, `networking`, `vmm`, and possibly `volumes`, matching Nutanix’s own example flow for VM creation [securitycafe](https://securitycafe.ro/2022/11/01/aws-enumeration-part-1/)
- `ex_list_vpcs()`, `ex_list_subnets()`, `ex_list_routes()`, `ex_list_gateways()`, `ex_list_nics()` -> provider-specific networking extensions from `networking` and `vmm` [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html)
- `ex_list_users()`, `ex_list_roles()`, `ex_list_policies()` -> optional IAM extensions from `iam` [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html)
- `ex_list_security_policies()` -> Flow / microseg integration via `microseg` [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html)

For object storage, a separate `NutanixObjectsStorageDriver` should expose:

- `list_containers()` -> object buckets in `objects` [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html)
- `list_objects(container)` -> bucket contents, if API scope and Libcloud semantics align
- `create_container()` / `delete_container()` -> bucket lifecycle, where supported by the Nutanix objects API [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html)

## Enumeration enhancements

If the goal is **resource enumeration**, not just provisioning, the driver should add inventory-first extension methods rather than relying only on Libcloud base methods. Nutanix v4 already highlights OData filtering, sorting, limiting, and pagination, so those should be first-class in every `list_*` and `ex_list_*` method to support large Prism Central estates efficiently. [securitycafe](https://securitycafe.ro/2022/11/01/aws-enumeration-part-1/)

The most useful Nutanix-specific enumeration methods would be:

- `ex_list_vpcs()`
- `ex_list_subnets(vpc_id=None)`
- `ex_list_routes(vpc_id=None, subnet_id=None)`
- `ex_list_gateways(vpc_id=None)`
- `ex_list_security_policies(scope=None)`
- `ex_list_vm_nics(node=None)`
- `ex_list_images(owned_only=False)`
- `ex_list_attached_disks(node=None)`
- `ex_list_volume_groups()` if the `volumes` model exposes them
- `ex_list_buckets()`
- `ex_list_users()`, `ex_list_roles()`, `ex_list_policies()`

Each returned resource should be normalized into Libcloud objects where possible, with extra Nutanix metadata stored in `extra`. For example, a VM node’s `extra` should include cluster UUID, subnet UUIDs, NIC list, attached disk UUIDs, power state, categories/tags, and Prism task references, because those are operationally critical for future provisioning and dependency analysis. [securitycafe](https://securitycafe.ro/2022/11/01/aws-enumeration-part-1/)

## Inventory model

For your AWS-style inventory use case, I would not stop at raw listing calls. I would add a higher-level `NutanixInventoryFacade` that walks the Nutanix v4 namespaces and emits a unified record format such as:

- `resource_type`
- `id`
- `name`
- `namespace`
- `cluster_id`
- `project_id`
- `location`
- `tags/categories`
- `relationships`
- `raw`

That facade can then build graph edges such as:

- `vm -> nic`
- `nic -> subnet`
- `subnet -> vpc`
- `vm -> image`
- `vm -> volume`
- `bucket -> object service`
- `user -> role`
- `role -> policy` [securitycafe](https://securitycafe.ro/2022/11/01/aws-enumeration-part-1/)

This is especially important because Nutanix provisioning commonly spans several namespaces in one workflow: cluster selection, storage container selection, subnet selection, VM creation, and task monitoring are explicitly described as a multi-namespace process in Nutanix’s own v4 example. A good Libcloud Nutanix driver should therefore expose both simple per-resource listings and a stitched topology view. [securitycafe](https://securitycafe.ro/2022/11/01/aws-enumeration-part-1/)

## Implementation notes

A robust Nutanix Libcloud driver should include:

- Prism Central endpoint configuration and version negotiation, because Nutanix v4 availability depends on Prism Central and AOS versions. [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html)
- Token/session handling and consistent request signing/authentication for all namespaces.
- OData-aware pagination helpers, because Nutanix v4 explicitly promotes filtering, sorting, limiting, and pagination. [securitycafe](https://securitycafe.ro/2022/11/01/aws-enumeration-part-1/)
- Async task polling helpers, because Nutanix operations often return tasks that must be monitored through Prism APIs. [securitycafe](https://securitycafe.ro/2022/11/01/aws-enumeration-part-1/)
- Strong `extra` metadata preservation, since Nutanix resources carry useful cluster, category, and topology details that do not map neatly to Libcloud base fields.
- Clear fallback behavior where Libcloud abstractions are too shallow, especially for IAM and microseg policy enumeration.

## Suggested scope

A sensible phased roadmap would be:

1. **Phase 1, compute inventory**: VMs, images, disks/volumes, NICs, clusters used by VMs. [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html)
2. **Phase 2, networking inventory**: VPCs, subnets, routes, gateways, connectivity relationships. [nutanix](https://www.nutanix.dev/2023/02/28/nutanix-v4-api-update-february-2023/)
3. **Phase 3, object storage inventory**: buckets and bucket metadata from `objects`. [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html)
4. **Phase 4, identity and security inventory**: users, roles, policies, Flow/microseg policies. [docs.aws.amazon](https://docs.aws.amazon.com/serverlessrepo/latest/devguide/list-supported-resources.html)
5. **Phase 5, topology/enrichment**: graph relationships and provisioning-readiness summaries.

For your particular AWS-derived list, the best Nutanix equivalent enumerator would focus first on: IAM users/roles/policies, VPCs, subnets, routes/gateways, security policy objects, VM NICs, VMs, images, attached and standalone volumes, and object buckets. That gives a general user or developer the Nutanix-side answers to the same core questions: who can provision, where can a VM land, what network can it join, what image can it boot from, what storage can it consume, and what object storage already exists. [securitycafe](https://securitycafe.ro/2022/11/01/aws-enumeration-part-1/)
