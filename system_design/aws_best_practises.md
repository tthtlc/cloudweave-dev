

# Security best practices for Amazon S3
<a name="security-best-practices"></a>

**Important**  
Amazon Simple Storage Service now applies a new default bucket security setting that automatically disables server-side encryption with customer-provided keys (SSE-C) for all new general purpose buckets. In April 2026, Amazon S3 deployed an update so all new general purpose buckets have SSE-C encryption disabled for all new write requests. For existing buckets in AWS accounts with no SSE-C encrypted objects, Amazon S3 also disabled SSE-C for all new write requests. With this change, applications that need SSE-C encryption must deliberately enable SSE-C by using the [https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutBucketEncryption.html](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutBucketEncryption.html) API operation after creating a new bucket. For more information about this change, see [Default SSE-C setting for new buckets FAQ](default-s3-c-encryption-setting-faq.md).

Amazon S3 provides a number of security features to consider as you develop and implement your own security policies. The following best practices are general guidelines and don't represent a complete security solution. Because these best practices might not be appropriate or sufficient for your environment, treat them as helpful recommendations rather than prescriptions. 

**Topics**
+ [Amazon S3 security best practices](#security-best-practices-prevent)
+ [Amazon S3 monitoring and auditing best practices](#security-best-practices-detect)
+ [Monitoring data security with managed AWS security services](#monitoring-data-security)

## Amazon S3 security best practices
<a name="security-best-practices-prevent"></a>

The following best practices for Amazon S3 can help prevent security incidents.

**Disable access control lists (ACLs)**  
S3 Object Ownership is an Amazon S3 bucket-level setting that you can use to control ownership of objects uploaded to your bucket and to disable or enable ACLs. By default, Object Ownership is set to the bucket owner enforced setting and all ACLs are disabled. When ACLs are disabled, the bucket owner owns all the objects in the bucket and manages access to data exclusively using access management policies.   
A majority of modern use cases in Amazon S3 no longer require the use of [access control lists (ACLs)](acl-overview.md). We recommend that you disable ACLs, except in circumstances where you must control access for each object individually. To disable ACLs and take ownership of every object in your bucket, apply the bucket owner enforced setting for S3 Object Ownership. When you disable ACLs, you can easily maintain a bucket with objects uploaded by different AWS accounts.   
When ACLs are disabled access control for your data is based on policies, such as the following:   
+ AWS Identity and Access Management (IAM) user policies
+ S3 bucket policies
+ Virtual private cloud (VPC) endpoint policies
+ AWS Organizations service control policies (SCPs)
+ AWS Organizations resource control policies (RCPs)
  
Disabling ACLs simplifies permissions management and auditing. ACLs are disabled for new buckets by default. You can also disable ACLs for existing buckets. If you have an existing bucket that already has objects in it, after you disable ACLs, the object and bucket ACLs are no longer part of the access-evaluation process. Instead, access is granted or denied on the basis of policies.   
Before you disable ACLs, make sure that you do the following:   
+ Review your bucket policy to ensure that it covers all the ways that you intend to grant access to your bucket outside of your account.
+ Reset your bucket ACL to the default (full control to the bucket owner).
  
After you disable ACLs, the following behaviors occur:   
+ Your bucket accepts only `PUT` requests that do not specify an ACL or `PUT` requests with bucket owner full control ACLs. These ACLs include the `bucket-owner-full-control` canned ACL or equivalent forms of this ACL that are expressed in XML.
+ Existing applications that support bucket owner full control ACLs see no impact. 
+ `PUT` requests that contain other ACLs (for example, custom grants to certain AWS accounts) fail and return an HTTP status code `400 (Bad Request)` with the error code `AccessControlListNotSupported`.
   
For more information, see [Controlling ownership of objects and disabling ACLs for your bucket](about-object-ownership.md).

**Ensure that your Amazon S3 buckets use the correct policies and are not publicly accessible**  
Unless you explicitly require anyone on the internet to be able to read or write to your S3 bucket, make sure that your S3 bucket is not public. The following are some of the steps that you can take to block public access:  
+ Use S3 Block Public Access. With S3 Block Public Access, you can easily set up centralized controls to limit public access to your Amazon S3 resources. These centralized controls are enforced regardless of how the resources are created. For organizations managing multiple AWS accounts, you can now use organization-level enforcement through AWS Organizations to centrally manage S3 Block Public Access settings across your entire organization with a single policy configuration.

  For more information, see [Blocking public access to your Amazon S3 storage](access-control-block-public-access.md).
+ Identify Amazon S3 bucket policies that allow a wildcard identity such as `"Principal": "*"` (which effectively means "anyone"). Also look for policies that allow a wildcard action `"*"` (which effectively allows the user to perform any action in the Amazon S3 bucket).
+ Similarly, look for Amazon S3 bucket access control lists (ACLs) that provide read, write, or full-access to "Everyone" or "Any authenticated AWS user." 
+ Use the `ListBuckets` API operation to scan all of your Amazon S3 buckets. Then use `GetBucketAcl`, `GetBucketWebsite`, and `GetBucketPolicy` to determine whether each bucket has compliant access controls and a compliant configuration.
+ Use [AWS Trusted Advisor](https://docs.aws.amazon.com/awssupport/latest/user/getting-started.html#trusted-advisor) to inspect your Amazon S3 implementation.
+ Consider implementing ongoing detective controls by using the [https://docs.aws.amazon.com/config/latest/developerguide/s3-bucket-public-read-prohibited.html](https://docs.aws.amazon.com/config/latest/developerguide/s3-bucket-public-read-prohibited.html) and [https://docs.aws.amazon.com/config/latest/developerguide/s3-bucket-public-write-prohibited.html](https://docs.aws.amazon.com/config/latest/developerguide/s3-bucket-public-write-prohibited.html) managed AWS Config Rules.
**For organizations with multiple AWS accounts, consider using organization-level Block Public Access management:**  
+ Centralized policy management: Use AWS Organizations to create a single S3 Block Public Access policy that automatically applies to all member accounts or selected organizational units (OUs).
+ Automatic inheritance: When you attach the policy at the root or OU level, new member accounts automatically inherit the Block Public Access settings without individual account setup.
+ Simplified compliance: Organization-level policies eliminate the need to maintain complex Service Control Policies (SCPs) for Block Public Access enforcement and reduce operational overhead of managing individual account configurations.
+ Audit capabilities: Use AWS CloudTrail to monitor policy attachment and enforcement across member accounts for compliance tracking.
For more information, see [Identity and Access Management for Amazon S3](security-iam.md). 

**Keep server-side encryption with customer-provided keys (SSE-C) disabled unless your workload requires it**  
Starting April 2026, Amazon S3 automatically disables SSE-C for all new general purpose buckets and existing buckets in accounts with no SSE-C encrypted objects. We recommend keeping SSE-C disabled unless your workload has a specific requirement for this encryption offering.  
SSE-C requires you to provide the encryption key with every request to read or write encrypted objects. This makes it impractical to share access with other users, roles, or AWS services that operate on your data. Objects encrypted with SSE-C cannot be natively decrypted by AWS managed services. For most workloads, server-side encryption with Amazon S3 managed keys (SSE-S3) or AWS KMS keys (SSE-KMS) provides equivalent protection with greater flexibility.  
If you have existing buckets where SSE-C is still enabled, review whether it's still needed and block it if not. When SSE-C is blocked, any `PutObject`, `CopyObject`, `PostObject`, Multipart Upload, or replication request that specifies SSE-C encryption is rejected with an HTTP 403 `AccessDenied` error.  
To learn more about blocking SSE-C, see [Blocking or unblocking SSE-C for a general purpose bucket](blocking-unblocking-s3-c-encryption-gpb.md).

**Create buckets in your account regional namespace**  
By default, you create global general purpose buckets in the shared global namespace. After creating a general purpose bucket in the shared global namespace, that bucket name is unavailable for anyone else to create within partition. When you delete a global general purpose bucket, the bucket name becomes available again in the global namespace for anyone to re-create.  
Although Amazon S3 general purpose buckets exist in a shared global namespace, you can optionally create buckets in your account regional namespace. The account regional namespace is a reserved subdivision of the global bucket namespace where only your account can create general purpose buckets. We recommend you create buckets in your account regional namespace since these buckets are unique to your account and can never be re-created by another account. For more information, see [Namespaces for general purpose buckets](gpbucketnamespaces.md).  
We recommend that you don't delete your global general purpose buckets in the shared global namespace. All AWS Accounts now have a default bucket quota of 10,000 buckets, reducing the need to delete empty buckets from your account. If you delete a bucket in the shared global namespace, be aware that another AWS account in the same partition can use the same bucket name for a new bucket and can therefore potentially receive requests that are intended for the deleted bucket. If you want to prevent this, or if you want to continue to use the same bucket name, don't delete the bucket. We recommend that you empty the bucket and keep it. Instead of deleting the bucket, block any bucket requests as needed. For buckets no longer in active use, we recommend emptying the bucket of all objects to minimize costs while retaining the bucket itself. For more information, see [Deleting a general purpose bucket](delete-bucket.md).

**Implement least privilege access**  
When granting permissions, you decide who is getting what permissions to which Amazon S3 resources. You enable specific actions that you want to allow on those resources. Therefore, we recommend that you grant only the permissions that are required to perform a task. Implementing least privilege access is fundamental in reducing security risk and the impact that could result from errors or malicious intent.   
The following tools are available to implement least privilege access:  
+ [Policy actions for Amazon S3](security_iam_service-with-iam.md#security_iam_service-with-iam-id-based-policies-actions) and [Permissions Boundaries for IAM Entities](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html)
+ [How Amazon S3 works with IAM](security_iam_service-with-iam.md)
+ [Access control list (ACL) overview](acl-overview.md)
For guidance on what to consider when choosing one or more of the preceding mechanisms, see [Identity and Access Management for Amazon S3](security-iam.md).

**Use IAM roles for applications and AWS services that require Amazon S3 access**  
In order for applications running on Amazon EC2 or other AWS services to access Amazon S3 resources, they must include valid AWS credentials in their AWS API requests. We recommend not storing AWS credentials directly in the application or Amazon EC2 instance. These are long-term credentials that are not automatically rotated and could have a significant business impact if they are compromised.  
Instead, use an IAM role to manage temporary credentials for applications or services that need to access Amazon S3. When you use a role, you don't have to distribute long-term credentials (such as a username and password or access keys) to an Amazon EC2 instance or AWS service, such as AWS Lambda. The role supplies temporary permissions that applications can use when they make calls to other AWS resources.  
For more information, see the following topics in the *IAM User Guide*:  
+ [IAM Roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html)
+ [Common Scenarios for Roles: Users, Applications, and Services](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_common-scenarios.html)

  

**Consider encryption of data at rest**  
You have the following options for protecting data at rest in Amazon S3:  
+ **Server-side encryption** – All Amazon S3 buckets have encryption configured by default, and all new objects that are uploaded to an S3 bucket are automatically encrypted at rest. Server-side encryption with Amazon S3 managed keys (SSE-S3) is the default encryption configuration for every bucket in Amazon S3. To use a different type of encryption, you can either specify the type of server-side encryption to use in your S3 `PUT` requests, or you can set the default encryption configuration in the destination bucket. 

  Amazon S3 also provides these server-side encryption options:
  + Server-side encryption with AWS Key Management Service (AWS KMS) keys (SSE-KMS) 
  + Dual-layer server-side encryption with AWS Key Management Service (AWS KMS) keys (DSSE-KMS)
  + Server-side encryption with customer-provided keys (SSE-C)

  For more information, see [Protecting data with server-side encryption](serv-side-encryption.md).
+ **Client-side encryption** – Encrypt data client-side and upload the encrypted data to Amazon S3. In this case, you manage the encryption process, the encryption keys, and related tools. As with server-side encryption, client-side encryption can help reduce risk by encrypting the data with a key that is stored in a different mechanism than the mechanism that stores the data itself. 

  Amazon S3 provides multiple client-side encryption options. For more information, see [Protecting data by using client-side encryption](UsingClientSideEncryption.md).

**Enforce encryption of data in transit**  
You can use HTTPS (TLS) to help prevent potential attackers from eavesdropping on or manipulating network traffic by using person-in-the-middle or similar attacks. We recommend allowing only encrypted connections over HTTPS (TLS) by using the [https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_condition_operators.html#Conditions_Boolean](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_condition_operators.html#Conditions_Boolean) condition in your Amazon S3 bucket policies. For more information, see the example S3 bucket policy [Managing access based on HTTP or HTTPS requests](https://docs.aws.amazon.com/AmazonS3/latest/userguide/example-bucket-policies.html#example-bucket-policies-HTTP-HTTPS). In addition to denying HTTP requests, we recommend that you set Amazon CloudWatch alarms on `tlsDetails.tlsVersion NOT EXISTS` that alert you if HTTP access attempts are made on your content. For more information on how to configure Amazon CloudWatch alarms, see [Creating CloudWatch alarms for CloudTrail events: examples](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudwatch-alarms-for-cloudtrail.html) and [CloudTrail record contents](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-event-reference-record-contents.html) in the *AWS CloudTrail User Guide*.  
We recommend that your application not pin Amazon S3 TLS certificates as AWS doesn’t support pinning of publicly-trusted certificates. S3 automatically renews certificates and renewal can happen any time before certificate expiry. Renewing a certificate generates a new public-private key pair. If you’ve pinned an S3 certificate which has been recently renewed with a new public key, you won’t be able to connect to S3 until your application uses the new certificate. 
Also consider implementing ongoing detective controls by using the [https://docs.aws.amazon.com/config/latest/developerguide/s3-bucket-ssl-requests-only.html](https://docs.aws.amazon.com/config/latest/developerguide/s3-bucket-ssl-requests-only.html) managed AWS Config rule. 

**Consider using S3 Object Lock**  
With S3 Object Lock, you can store objects by using a "Write Once Read Many" (WORM) model. S3 Object Lock can help prevent accidental or inappropriate deletion of data. For example, you can use S3 Object Lock to help protect your AWS CloudTrail logs.  
For more information, see [Locking objects with Object Lock](object-lock.md).

**Enable S3 Versioning**  
S3 Versioning is a means of keeping multiple variants of an object in the same bucket. You can use versioning to preserve, retrieve, and restore every version of every object stored in your bucket. With versioning, you can easily recover from both unintended user actions and application failures.   
Also consider implementing ongoing detective controls by using the [https://docs.aws.amazon.com/config/latest/developerguide/s3-bucket-versioning-enabled.html](https://docs.aws.amazon.com/config/latest/developerguide/s3-bucket-versioning-enabled.html) managed AWS Config rule.  
For more information, see [Retaining multiple versions of objects with S3 Versioning](Versioning.md). 

**Consider using S3 Cross-Region Replication**  
Although Amazon S3 stores your data across multiple geographically diverse Availability Zones by default, compliance requirements might dictate that you store data at even greater distances. With S3 Cross-Region Replication (CRR), you can replicate data between distant AWS Regions to help satisfy these requirements. CRR enables automatic, asynchronous copying of objects across buckets in different AWS Regions. For more information, see [Replicating objects within and across Regions](replication.md).  
CRR requires both the source and destination S3 buckets to have versioning enabled.
Also consider implementing ongoing detective controls by using the [https://docs.aws.amazon.com/config/latest/developerguide/s3-bucket-replication-enabled.html](https://docs.aws.amazon.com/config/latest/developerguide/s3-bucket-replication-enabled.html) managed AWS Config rule.

**Consider using VPC endpoints for Amazon S3 access**  
A virtual private cloud (VPC) endpoint for Amazon S3 is a logical entity within a VPC that allows connectivity only to Amazon S3. VPC endpoints can help prevent traffic from traversing the open internet.  
VPC endpoints for Amazon S3 provide multiple ways to control access to your Amazon S3 data:  
+ You can control the requests, users, or groups that are allowed through a specific VPC endpoint by using S3 bucket policies.
+ You can control which VPCs or VPC endpoints have access to your S3 buckets by using S3 bucket policies.
+ You can help prevent data exfiltration by using a VPC that does not have an internet gateway.
For more information, see [Controlling access from VPC endpoints with bucket policies](example-bucket-policies-vpc-endpoint.md). 

** Use managed AWS security services to monitor data security**  
Several managed AWS security services can help you identify, assess, and monitor security and compliance risks for your Amazon S3 data. These services can also help you protect your data from those risks. These services include automated detection, monitoring, and protection capabilities that are designed to scale from Amazon S3 resources for a single AWS account to resources for organizations spanning thousands of accounts.  
For more information, see [Monitoring data security with managed AWS security services](#monitoring-data-security).

## Amazon S3 monitoring and auditing best practices
<a name="security-best-practices-detect"></a>

The following best practices for Amazon S3 can help detect potential security weaknesses and incidents.

**Identify and audit all of your Amazon S3 buckets**  
Identification of your IT assets is a crucial aspect of governance and security. You need to have visibility of all your Amazon S3 resources to assess their security posture and take action on potential areas of weakness. To audit your resources, we recommend doing the following:  
+ Use Tag Editor to identify and tag security-sensitive or audit-sensitive resources, then use those tags when you need to search for these resources. For more information, see [Searching for Resources to Tag](https://docs.aws.amazon.com/ARG/latest/userguide/tag-editor.html) in the *Tagging AWS Resources User Guide*. 
+ Use S3 Inventory to audit and report on the replication and encryption status of your objects for business, compliance, and regulatory needs. For more information, see [Cataloging and analyzing your data with S3 Inventory](storage-inventory.md).
+ Create resource groups for your Amazon S3 resources. For more information, see [What are resource groups?](https://docs.aws.amazon.com/ARG/latest/userguide/welcome.html) in the *AWS Resource Groups User Guide*.

**Implement monitoring by using AWS monitoring tools**  
Monitoring is an important part of maintaining the reliability, security, availability, and performance of Amazon S3 and your AWS solutions. AWS provides several tools and services to help you monitor Amazon S3 and your other AWS services. For example, you can monitor Amazon CloudWatch metrics for Amazon S3, particularly the `PutRequests`, `GetRequests`, `4xxErrors`, and `DeleteRequests` metrics. For more information, see [Monitoring metrics with Amazon CloudWatch](cloudwatch-monitoring.md) and [Logging and monitoring in Amazon S3](monitoring-overview.md).  
For a second example, see [Example: Amazon S3 Bucket Activity](http://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudwatch-alarms-for-cloudtrail.html#cloudwatch-alarms-for-cloudtrail-s3-bucket-activity). This example describes how to create a CloudWatch alarm that is triggered when an Amazon S3 API call is made to `PUT` or `DELETE` a bucket policy, a bucket lifecycle, or a bucket replication configuration, or to `PUT` a bucket ACL.

**Enable Amazon S3 server access logging**  
Server access logging provides detailed records of the requests that are made to a bucket. Server access logs can assist you in security and access audits, help you learn about your customer base, and understand your Amazon S3 bill. For instructions on enabling server access logging, see [Logging requests with server access logging](ServerLogs.md).  
Also consider implementing ongoing detective controls by using the [https://docs.aws.amazon.com/config/latest/developerguide/s3-bucket-logging-enabled.html](https://docs.aws.amazon.com/config/latest/developerguide/s3-bucket-logging-enabled.html) AWS Config managed rule. 

**Use AWS CloudTrail**  
AWS CloudTrail provides a record of actions taken by a user, a role, or an AWS service in Amazon S3. You can use information collected by CloudTrail to determine the following:   
+ The request that was made to Amazon S3
+ The IP address from which the request was made
+ Who made the request
+ When the request was made
+ Additional details about the request
  
For example, you can identify CloudTrail entries for `PUT` actions that affect data access, in particular `PutBucketAcl`, `PutObjectAcl`, `PutBucketPolicy`, and `PutBucketWebsite`.   
When you set up your AWS account, CloudTrail is enabled by default. You can view recent events in the CloudTrail console. To create an ongoing record of activity and events for your Amazon S3 buckets, you can create a trail in the CloudTrail console. For more information, see [Logging data events](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/logging-data-events-with-cloudtrail.html) in the *AWS CloudTrail User Guide*.  
When you create a trail, you can configure CloudTrail to log data events. Data events are records of resource operations performed on or within a resource. In Amazon S3, data events record object-level API activity for individual buckets. CloudTrail supports a subset of Amazon S3 object-level API operations, such as `GetObject`, `DeleteObject`, and `PutObject`. For more information about how CloudTrail works with Amazon S3, see [Logging Amazon S3 API calls using AWS CloudTrail](cloudtrail-logging.md). In the Amazon S3 console, you can also configure your S3 buckets to [Enabling CloudTrail event logging for S3 buckets and objects](enable-cloudtrail-logging-for-s3.md).  
AWS Config provides a managed rule (`cloudtrail-s3-dataevents-enabled`) that you can use to confirm that at least one CloudTrail trail is logging data events for your S3 buckets. For more information, see [https://docs.aws.amazon.com//config/latest/developerguide/cloudtrail-s3-dataevents-enabled.html](https://docs.aws.amazon.com//config/latest/developerguide/cloudtrail-s3-dataevents-enabled.html) in the *AWS Config Developer Guide*.

**Enable AWS Config**  
Several of the best practices listed in this topic suggest creating AWS Config rules. AWS Config helps you to assess, audit, and evaluate the configurations of your AWS resources. AWS Config monitors resource configurations so that you can evaluate the recorded configurations against the desired secure configurations. With AWS Config, you can do the following:   
+ Review changes in configurations and relationships between AWS resources
+ Investigate detailed resource-configuration histories
+ Determine your overall compliance against the configurations specified in your internal guidelines
  
Using AWS Config can help you simplify compliance auditing, security analysis, change management, and operational troubleshooting. For more information, see [Setting Up AWS Config with the Console](https://docs.aws.amazon.com/config/latest/developerguide/gs-console.html) in the *AWS Config Developer Guide*. When specifying the resource types to record, ensure that you include Amazon S3 resources.  
AWS Config managed rules only supports general purpose buckets when evaluating Amazon S3 resources. AWS Config doesn’t record configuration changes for directory buckets. For more information, see [AWS Config Managed Rules](https://docs.aws.amazon.com//config/latest/developerguide/evaluate-config_use-managed-rules.html) and [List of AWS Config Managed Rules](https://docs.aws.amazon.com//config/latest/developerguide/managed-rules-by-aws-config.html) in the *AWS Config Developer Guide*.
For an example of how to use AWS Config, see [How to Use AWS Config to Monitor for and Respond to Amazon S3 Buckets Allowing Public Access](https://aws.amazon.com/blogs/security/how-to-use-aws-config-to-monitor-for-and-respond-to-amazon-s3-buckets-allowing-public-access/) on the *AWS Security Blog*. 

**Use S3 Storage Lens**  
S3 Storage Lens is a cloud-storage analytics feature that you can use to gain organization-wide visibility into object-storage usage and activity. S3 Storage Lens also analyzes metrics to deliver contextual recommendations that you can use to optimize storage costs and apply best practices for protecting your data.   
With S3 Storage Lens, you can use metrics to generate summary insights, such as finding out how much storage you have across your entire organization or which are the fastest-growing buckets and prefixes. You can also use S3 Storage Lens metrics to identify cost-optimization opportunities, implement data-protection and access-management best practices, and improve the performance of application workloads.   
For example, you can identify buckets that don't have S3 Lifecycle rules to abort incomplete multipart uploads that are more than 7 days old. You can also identify buckets that aren't following data-protection best practices, such as using S3 Replication or S3 Versioning. For more information, see [Understanding Amazon S3 Storage Lens](https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage_lens_basics_metrics_recommendations.html).

**Monitor AWS security advisories**  
We recommend that you regularly check the security advisories posted in Trusted Advisor for your AWS account. In particular, look for warnings about Amazon S3 buckets with "open access permissions." You can do this programmatically by using [https://docs.aws.amazon.com/cli/latest/reference/support/describe-trusted-advisor-checks.html](https://docs.aws.amazon.com/cli/latest/reference/support/describe-trusted-advisor-checks.html).  
Further, actively monitor the primary email address that's registered to each of your AWS accounts. AWS uses this email address to contact you about emerging security issues that might affect you.  
AWS operational issues with broad impact are posted on the [AWS Health Dashboard - Service health](https://status.aws.amazon.com/). Operational issues are also posted to individual accounts through the AWS Health Dashboard. For more information, see the [AWS Health documentation](https://docs.aws.amazon.com/health/).

## Monitoring data security with managed AWS security services
<a name="monitoring-data-security"></a>

Several managed AWS security services can help you identify, assess, and monitor security and compliance risks for your Amazon S3 data. They can also help you protect your data from those risks. These services include automated detection, monitoring, and protection capabilities that are designed to scale from Amazon S3 resources for a single AWS account to resources for organizations spanning thousands of AWS accounts.

AWS detection and response services can help you identify potential security misconfigurations, threats, or unexpected behaviors, so that you can quickly respond to potentially unauthorized or malicious activity in your environment. AWS data protection services can help you monitor and protect your data, accounts, and workloads from unauthorized access. They can also help you discover sensitive data, such as personally identifiable information (PII), in your Amazon S3 data estate.

To help you identify and evaluate data security and compliance risks, managed AWS security services generate findings to notify you of potential security events or issues with your Amazon S3 data. The findings provide relevant details that you can use to investigate, assess, and act upon these risks according to your incident-response workflows and policies. You can access findings data directly by using each service. You can also send the data to other applications, services, and systems, such as your security incident and event management system (SIEM).

To monitor the security of your Amazon S3 data, consider using these managed AWS security services.

**Amazon GuardDuty**  
Amazon GuardDuty is a threat-detection service that continuously monitors your AWS accounts and workloads for malicious activity and delivers detailed security findings for visibility and remediation.  
With the S3 protection feature in GuardDuty, you can configure GuardDuty to analyze AWS CloudTrail management and data events for your Amazon S3 resources. GuardDuty then monitors those events for malicious and suspicious activity. To inform the analysis and identify potential security risks, GuardDuty uses threat-intelligence feeds and machine learning.  
GuardDuty can monitor different kinds of activity for your Amazon S3 resources. For example, CloudTrail management events for Amazon S3 include bucket-level operations, such as `ListBuckets`, `DeleteBucket`, and `PutBucketReplication`. CloudTrail data events for Amazon S3 include object-level operations, such as `GetObject`, `ListObjects`, and `PutObject`. If GuardDuty detects anomalous or potentially malicious activity, it generates a finding to notify you.  
For more information, see [Amazon S3 Protection in Amazon GuardDuty](https://docs.aws.amazon.com/guardduty/latest/ug/s3-protection.html) in the *Amazon GuardDuty User Guide*.

**Amazon Detective**  
Amazon Detective simplifies the investigative process and helps you conduct faster, more effective security investigations. Detective provides prebuilt data aggregations, summaries, and context that can help you analyze and assess the nature and extent of possible security issues.  
Detective automatically extracts time-based events, such as API calls from AWS CloudTrail and Amazon VPC Flow Logs for your AWS resources. It also ingests findings generated by Amazon GuardDuty. Detective then uses machine learning, statistical analysis, and graph theory to generate visualizations that help you conduct effective security investigations more quickly.  
These visualizations provide a unified, interactive view of resource behaviors and the interactions between them over time. You can explore this behavior graph to examine potentially malicious actions, such as failed login attempts or suspicious API calls. You can also see how these actions affect resources, such as S3 buckets and objects.  
For more information, see the [Amazon Detective Administration Guide](https://docs.aws.amazon.com/detective/latest/adminguide/what-is-detective.html).

**IAM Access Analyzer**  
AWS Identity and Access Management Access Analyzer (IAM Access Analyzer) can help you identify resources that are shared with an external entity. You can also use IAM Access Analyzer to validate IAM policies against policy grammar and best practices, and generate IAM policies based on access activity in your AWS CloudTrail logs.  
IAM Access Analyzer uses logic-based reasoning to analyze resource policies in your AWS environment, such as bucket policies. With IAM Access Analyzer for S3, you're alerted when an S3 bucket is configured to allow access to anyone on the internet or other AWS accounts, including accounts outside your organization. For example, IAM Access Analyzer for S3 can report that a bucket has read or write access provided through a bucket access control list (ACL), a bucket policy, a Multi-Region Access Point policy, or an access point policy. For each public or shared bucket, you receive findings that indicate the source and level of public or shared access. With these findings, you can take immediate and precise corrective action to restore bucket access to what you intended.  
For more information, see [Reviewing bucket access using IAM Access Analyzer for S3](access-analyzer.md).

**Amazon Macie**  
Amazon Macie is a security service that discovers sensitive data by using machine learning and pattern matching. Macie provides visibility into data security risks, and enables automated protection against those risks. With Macie, you can automate the discovery and reporting of sensitive data in your Amazon S3 data estate to gain a better understanding of the data that your organization stores in S3.  
To detect sensitive data with Macie, you can use built-in criteria and techniques that are designed to detect a large and growing list of sensitive data types for many countries and regions. These sensitive data types include multiple types of personally identifiable information (PII), financial data, and credentials data. You can also use custom criteria that you define—regular expressions that define text patterns to match and, optionally, character sequences and proximity rules that refine the results.  
If Macie detects sensitive data in an S3 object, Macie generates a security finding to notify you. This finding provides information about the affected object, the types and number of occurrences of the sensitive data that Macie found, and additional details to help you investigate the affected S3 bucket and object. For more information, see the [Amazon Macie User Guide](https://docs.aws.amazon.com/macie/latest/user/what-is-macie.html).

**AWS Security Hub CSPM**  
AWS Security Hub CSPM is a security-posture management service that performs security best-practice checks, aggregates alerts and findings from multiple sources into a single format, and enables automated remediation.  
Security Hub CSPM collects and provides security findings data from integrated AWS Partner Network security solutions and AWS services, including Amazon Detective, Amazon GuardDuty, IAM Access Analyzer, and Amazon Macie. It also generates its own findings by running continuous, automated security checks based on AWS best practices and supported industry standards.  
Security Hub CSPM then correlates and consolidates findings across providers to help you prioritize and process the most significant findings. It also provides support for custom actions, which you can use to invoke responses or remediation actions for specific classes of findings.  
With Security Hub CSPM, you can assess the security and compliance status of your Amazon S3 resources, and you can do so as part of a broader analysis of your organization's security posture in individual AWS Regions and across multiple Regions. This includes analyzing security trends and identifying the highest-priority security issues. You can also aggregate findings from multiple AWS Regions, and monitor and process aggregated findings data from a single Region.  
For more information, see [Amazon Simple Storage Service controls](https://docs.aws.amazon.com/securityhub/latest/userguide/s3-controls.html) in the *AWS Security Hub CSPM User Guide*.