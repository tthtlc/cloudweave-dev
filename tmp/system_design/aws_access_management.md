

# Access control in Amazon S3
<a name="access-management"></a>

In AWS, a resource is an entity that you can work with. In Amazon Simple Storage Service (S3), *buckets* and *objects* are the original Amazon S3 resources. Every S3 customer likely has buckets with objects in them. As new features were added to S3, additional resources were also added, but not every customer uses these feature-specific resources. For more information about Amazon S3 resources, see [S3 resources](#access-management-resources).

By default, all Amazon S3 resources are private. Also by default, the root user of the AWS account that created the resource (resource owner) and IAM users within that account with the necessary permissions can access a resource that they created. The resource owner decides who else can access the resource and the actions that others are allowed to perform on the resource. S3 has various access management tools that you can use to grant others access to your S3 resources.

The following sections provide you with an overview of S3 resources, the S3 access management tools available, and the best use cases for each access management tool. The lists in these sections aim to be comprehensive and include all S3 resources, access management tools, and common access management use cases. At the same time, these sections are designed to be directories that lead you to the technical details you want. If you have a good understanding of some of the following topics, you can skip to the section that applies to you. 

For more information about the permissions to S3 API operations by S3 resource types, see [Required permissions for Amazon S3 API operations](using-with-s3-policy-actions.md).

**Topics**
+ [S3 resources](#access-management-resources)
+ [Identities](#access-management-owners)
+ [Access management tools](#access-management-tools)
+ [Actions](#access-management-actions)
+ [Access management use cases](#access-management-usecases)
+ [Access management troubleshooting](#access-management-troubleshooting)

## S3 resources
<a name="access-management-resources"></a>

The original Amazon S3 resources are buckets and the objects that they contain. As new features are added to S3, new resources are also added. The following is a complete list of S3 resources and their respective features. 


<table>
<thead>
  <tr><th> Resource type</th><th> Amazon S3 feature </th><th> Description </th></tr>
</thead>
<tbody>
  <tr><td>`bucket`</td><td rowspan="2">Core features</td><td>A bucket is a container for objects. To store an object in S3, create a bucket and then upload one or more objects to the bucket. For more information, see [Creating, configuring, and working with Amazon S3 general purpose buckets](creating-buckets-s3.md).</td></tr>
  <tr><td>`object`</td><td>An object can be a file and any metadata that describes that file. When an object is in the bucket, you can open it, download it, and move it. For more information, see [Working with objects in Amazon S3](uploading-downloading-objects.md). </td></tr>
  <tr><td>`accesspoint`</td><td>Access Points</td><td>Access Points are named network endpoints that are attached to buckets that you can use to perform Amazon S3 **object** operations, such as `GetObject` and `PutObject`. Each access point has distinct permissions, network controls, and a customized *access point policy* that works in conjunction with the bucket policy that is attached to the underlying bucket. You can configure any access point to accept requests only from a virtual private cloud (VPC) or configure custom block public access settings for each access point. For more information, see [Managing access to shared datasets with access points](access-points.md).</td></tr>
  <tr><td>`objectlambdaaccesspoint`</td><td>``</td><td>An Object Lambda Access Point is an access point for a bucket that is also associated with a Lambda function. With Object Lambda Access Point, you can add your own code to Amazon S3 `GET`, `LIST`, and `HEAD` requests to modify and process data as it's returned to an application. For more information, see [Creating Object Lambda Access Points](olap-create.md). </td></tr>
  <tr><td>`multiregionaccesspoint`</td><td>``</td><td>Multi-Region Access Points provide a global endpoint that applications can use to fulfill requests from Amazon S3 buckets that are located in multiple AWS Regions. You can use Multi-Region Access Points to build multi-Region applications with the same architecture that's used in a single Region, and then run those applications anywhere in the world. Instead of sending requests over the congested public internet, application requests made to a Multi-Region Access Point global endpoint automatically route through the AWS global network to the closest proximity Amazon S3 bucket. For more information, see [Managing multi-Region traffic with Multi-Region Access Points](MultiRegionAccessPoints.md).</td></tr>
  <tr><td>`job`</td><td>S3 Batch Operations</td><td>A job is a resource of the S3 Batch Operations feature. You can use S3 Batch Operations to perform large-scale batch operations on lists of Amazon S3 objects that you specify. Amazon S3 tracks the progress of the batch operation job, sends notifications, and stores a detailed completion report of all actions, providing you with a fully managed, auditable, and serverless experience. For more information, see [Performing object operations in bulk with Batch Operations](batch-ops.md). </td></tr>
  <tr><td>`storagelensconfiguration`</td><td rowspan="2">S3 Storage Lens</td><td>An S3 Storage Lens configuration collects organization-wide storage metrics and user data across accounts. S3 Storage Lens provides admins with a single view of object storage usage and activity across hundreds, or even thousands, of accounts in an organization, with details to generate insights at multiple aggregation levels. For more information, see [Monitoring your storage activity and usage with Amazon S3 Storage Lens](storage_lens.md).</td></tr>
  <tr><td>`storagelensgroup`</td><td>An S3 Storage Lens group aggregates metrics by using custom filters based on object metadata. S3 Storage Lens groups help you investigate characteristics of your data, such as distribution of objects by age, your most common file types, and more. For more information, see [Working with S3 Storage Lens groups to filter and aggregate metrics](storage-lens-groups-overview.md).</td></tr>
  <tr><td>`accessgrantsinstance`</td><td rowspan="3">S3 Access Grants</td><td>An S3 Access Grants instance is a container for the S3 grants that you create. With S3 Access Grants, you can create grants to your Amazon S3 data for IAM identities within your account, IAM identities in other accounts (cross-account), and directory identities added to AWS IAM Identity Center from your corporate directory. For more information about S3 Access Grants, see [Managing access with S3 Access Grants](access-grants.md).</td></tr>
  <tr><td>`accessgrantslocation`</td><td>An Access Grants Location is a bucket, prefix within a bucket, or an object that you register in your S3 Access Grants instance. You must register locations within the S3 Access Grants instance before you can create a grant to that location. Then, with S3 Access Grants, you can grant access to the bucket, prefix, or object for IAM identities within your account, IAM identities in other accounts (cross-account), and directory identities added to AWS IAM Identity Center from your corporate directory. For more information about S3 Access Grants, see [Managing access with S3 Access Grants](access-grants.md)</td></tr>
  <tr><td>`accessgrant`</td><td>An Access Grant is an individual grant to your Amazon S3 data. With S3 Access Grants, you can create grants to your Amazon S3 data for IAM identities within your account, IAM identities in other accounts (cross-account), and directory identities added to AWS IAM Identity Center from your corporate directory. For more information about S3 Access Grants, see [Managing access with S3 Access Grants](access-grants.md)</td></tr>
</tbody>
</table>


**Buckets**  
There are two types of Amazon S3 buckets: *general purpose buckets* and *directory buckets*. 
+ **General purpose buckets** are the original S3 bucket type and are recommended for most use cases and access patterns. General purpose buckets also allow objects that are stored across all storage classes, except S3 Express One Zone. For more information about S3 storage classes, see [Understanding and managing Amazon S3 storage classes](storage-class-intro.md).
+ **Directory buckets** use the S3 Express One Zone storage class, which is recommended if your application is performance-sensitive and benefits from single-digit millisecond `PUT` and `GET` latencies. For more information, see [Working with directory buckets](directory-buckets-overview.md), [S3 Express One Zone](directory-bucket-high-performance.md#s3-express-one-zone), and [Authorizing Regional endpoint API operations with IAM](s3-express-security-iam.md).

**Categorizing S3 resources**  
Amazon S3 provides features to categorize and organize your S3 resources. Categorizing your resources is not only useful for organizing them, but you can also set access management rules based on the resource categories. In particular, prefixes and tagging are two storage organization features that you can use when setting access management permissions. 

**Note**  
The following information applies to general purpose buckets. Directory buckets do not support tagging, and they have prefix limitations. For more information, see [Authorizing Regional endpoint API operations with IAM](s3-express-security-iam.md).
+ **Prefixes** — A prefix in Amazon S3 is a string of characters at the beginning of an object key name that's used to organize the objects that are stored in your S3 buckets. You can use a delimiter character, such as a forward slash (`/`), to indicate the end of the prefix within the object key name. For example, you might have object key names that start with the `engineering/` prefix or object key names that start with the `marketing/campaigns/` prefix. Using a delimeter at the end of your prefix, such as as a forward slash character `/` emulates folder and file naming conventions. However, in S3, the prefix is part of the object key name. In general purpose S3 buckets, there is no actual folder hierarchy. 

  Amazon S3 supports organizing and grouping objects by using their prefixes. You can also manage access to objects by their prefixes. For example, you can limit access to only the objects with names that start with a specific prefix. 

  For more information, see [Organizing objects using prefixes](using-prefixes.md). S3 Console uses the concept of *folders*, which, in general purpose buckets, are essentially prefixes that are pre-pended to the object key name. For more information, see [Organizing objects in the Amazon S3 console by using folders](using-folders.md).
+ **Tags** — Each tag is a key-value pair that you assign to resources. For example, you can tag some resources with the tag `topicCategory=engineering`. You can use tagging to help with cost allocation, categorizing and organizing, and access control. Bucket tagging is only used for cost allocation. You can tag objects, S3 Storage Lens, jobs, and S3 Access Grants for the purposes of organizing or for access control. In S3 Access Grants, you can also use tagging for cost-allocation. As an example of controlling access to resources by using their tags, you can share only the objects that have a specific tag or a combination of tags. 

  For more information, see [Controlling access to AWS resources by using resource tags](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_tags.html) in the *IAM User Guide*.

## Identities
<a name="access-management-owners"></a>

In Amazon S3, the resource owner is the identity that created the resource, such as a bucket or an object. By default, only the root user of the account that created the resource and IAM identities within the account that have the required permission can access the S3 resource. Resource owners can give other identities access to their S3 resources. 

Identities that don't own a resource can request access to that resource. Requests to a resource are either authenticated or unauthenticated. Authenticated requests must include a signature value that authenticates the request sender, but unauthenticated requests do not require a signature. We recommend that you grant access only to authenticated users. For more information about request authentication, see [Making requests ](https://docs.aws.amazon.com/AmazonS3/latest/API/MakingRequests.html) in the *Amazon S3 API Reference*. 

**Important**  
We recommend that you don't use the AWS account root user credentials to make authenticated requests. Instead, create an IAM role and grant that role full access. We refer to users with this role as *administrator users*. You can use credentials assigned to the administrator role, instead of AWS account root user credentials, to interact with AWS and perform tasks, such as create a bucket, create users, and grant permissions. For more information, see [AWS account root user credentials and IAM user credentials](https://docs.aws.amazon.com/general/latest/gr/root-vs-iam.html) in the *AWS General Reference*, and see [Security best practices in IAM](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html) in the *IAM User Guide*.

Identities accessing your data in Amazon S3 can be one of the following:

**AWS account owner**  
The AWS account that created the resource. For example, the account that created the bucket. This account owns the resource. For more information, see [AWS account root user](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user.html).

**IAM identities in the same account of the AWS account owner**  
When setting up accounts for new team members who require S3 access, the AWS account owner can use AWS Identity and Access Management (IAM) to create [users](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_users.html), [groups](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_groups.html), and [roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html). The AWS account owner can then share resources with these IAM identities. The account owner can also specify the permissions to give the IAM identities, which allow or deny the actions that can be performed on the shared resources. 

IAM identities provide increased capabilities, including the ability to require users to enter login credentials before accessing shared resources. By using IAM identities, you can implement a form of IAM multi-factor authentication (MFA) to support a strong identity foundation. An IAM best practice is to create roles for access management instead of granting permissions to each individual user. You assign individual users to the appropriate role. For more information, see [Security best practices in IAM](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html). 

**Other AWS account owners and their IAM identities (cross-account access)**  
The AWS account owner can also give other AWS account owners, or IAM identities that belong to another AWS account, access to resources. 

**Note**  
**Permission delegation** — If an AWS account owns a resource, it can grant those permissions to another AWS account. That account can then delegate those permissions, or a subset of them, to users in the same account. This is referred to as permission delegation. But an account that receives permissions from another account cannot delegate those permissions "cross-account" to another AWS account. 

**Anonymous users (public access)**  
The AWS account owner can make resources public. Making a resource public technically shares the resource with *the anonymous user*. Buckets created since April 2023 block all public access by default, unless you change this setting. We recommend that you set your buckets to block public access, and that you only grant access to authenticated users. For more information about blocking public access, see [Blocking public access to your Amazon S3 storage](access-control-block-public-access.md). 

**AWS services**  
The resource owner can grant another AWS service access to an Amazon S3 resource. For example, you can grant the AWS CloudTrail service `s3:PutObject` permission to write log files to your bucket. For more information, see [Providing access to an AWS service](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_common-scenarios_services.html).

**Corporate directory identities**  
The resource owner can grant users or roles from your corporate directory access to an S3 resource by using [S3 Access Grants](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-grants-get-started.html). For more information about adding your corporate directory to AWS IAM Identity Center, see [What is IAM Identity Center?](https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html). 

### Bucket or resource owners
<a name="access-management-owners-rules"></a>

The AWS account that you use to create buckets and upload objects owns those resources. A bucket owner can grant cross-account permissions to another AWS account (or users in another account) to upload objects.

When a bucket owner permits another account to upload objects to a bucket, the bucket owner, by default, owns all objects uploaded to their bucket. However, if both the *Bucket owner enforced* and *Bucket owner preferred* bucket settings are turned off, the AWS account that uploads the objects owns those objects, and the bucket owner does not have permissions on the objects owned by another account, with the following exceptions:
+ The bucket owner pays the bills. The bucket owner can deny access to any objects, or delete any objects in the bucket, regardless of who owns them. 
+ The bucket owner can archive any objects or restore archived objects, regardless of who owns them. Archival refers to the storage class used to store the objects. For more information, see [Managing the lifecycle of objects](object-lifecycle-mgmt.md).

## Access management tools
<a name="access-management-tools"></a>

Amazon S3 provides a variety of security features and tools. The following is a comprehensive list of these features and tools. You do not need all of these access management tools, but you must use one or more to grant access to your Amazon S3 resources. Proper application of these tools can help make sure that your resources are accessible only to the intended users. 

The most commonly used access management tool is an *access policy*. An access policy can be a *resource-based policy* that is attached to an AWS resource, such as a bucket policy for a bucket. An access policy can also be an *identity-based policy* that is attached to an AWS Identity and Access Management (IAM) identity, such as an IAM user, group, or role. Write an access policy to grant AWS accounts and IAM users, groups, and roles permission to perform operations on a resource. For example, you can grant `PUT Object` permission to another AWS account so that the other account can upload objects to your bucket.

An access policy describes who has access to what things. When Amazon S3 receives a request, it must evaluate all of the access policies to determine whether to authorize or deny the request. For more information about how Amazon S3 evaluates these policies, see [How Amazon S3 authorizes a request](how-s3-evaluates-access-control.md).

The following are the access management tools available in Amazon S3.

### Bucket policy
<a name="access-mgmt-bucket-policy"></a>

An Amazon S3 bucket policy is a JSON-formatted [AWS Identity and Access Management (IAM) resource-based policy](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies.html) that is attached to a particular bucket. Use bucket policies to grant other AWS accounts or IAM identities permissions for the bucket and the objects in it. Many S3 access management use cases can be met by using a bucket policy. With bucket policies, you can personalize bucket access to help make sure that only the identities that you have approved can access resources and perform actions within them. For more information, see [Bucket policies for Amazon S3](bucket-policies.md). 

The following is an example bucket policy. You express the bucket policy by using a JSON file. This example policy grants an IAM role read permission to all objects in the bucket. It contains one statement named `BucketLevelReadPermissions`, which allows the `s3:GetObject` action (read permission) on objects in a bucket named `amzn-s3-demo-bucket1`. By specifying an IAM role as the `Principal`, this policy grants access to any IAM user with this role. To use this example policy, replace the `{{user input placeholders}}` with your own information. 

------
#### [ JSON ]

****  

```
{
  "Version":"2012-10-17",		 	 	 
  "Statement": [
    {
      "Sid":"{{BucketLevelReadPermissions}}",
      "Effect":"Allow",
      "Principal": {
	    "AWS": "arn:aws:iam::{{123456789101}}:role/{{s3-role}}"
      },
      "Action":["s3:GetObject"],
      "Resource":["arn:aws:s3:::{{amzn-s3-demo-bucket/*}}"]
    }]
  }
```

------

**Note**  
When creating policies, avoid the use of wildcard characters (`*`) in the `Principal` element because using a wildcard character allows anyone to access your Amazon S3 resources. Instead, explicitly list users or groups that are allowed to access the bucket, or list conditions that must be met by using a condition clause in the policy. Also, rather than including a wildcard character for the actions of your users or groups, grant them specific permissions when applicable. 

### Identity-based policy
<a name="access-mgmt-id-policy"></a>

An identity-based or IAM user policy is a type of [AWS Identity and Access Management (IAM) policy](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies.html). An identity-based policy is a JSON-formatted policy that is attached to IAM users, groups, or roles in your AWS account. You can use identity-based policies to grant an IAM identity access to your buckets or objects. You can create IAM users, groups, and roles in your account and attach access policies to them. You can then grant access to AWS resources, including Amazon S3 resources. For more information, see [Identity-based policies for Amazon S3](security_iam_id-based-policy-examples.md). 

The following is an example of an identity-based policy. The example policy allows the associated IAM role to perform six different Amazon S3 actions (permissions) on a bucket and the objects in it. If you attach this policy to an IAM role in your account and assign the role to some of your IAM users, the users with this role will be able to perform these actions on the resources (buckets) specified in your policy. To use this example policy, replace the `{{user input placeholders}}` with your own information.

------
#### [ JSON ]

****  

```
{
  "Version":"2012-10-17",		 	 	 
  "Statement": [
  {
    "Sid": "{{AssignARoleActions}}",
    "Effect": "Allow",
    "Action": [
	  "s3:PutObject",
	  "s3:GetObject",
	  "s3:ListBucket",
	  "s3:DeleteObject",
	  "s3:GetBucketLocation"
    ],
    "Resource": [
	  "arn:aws:s3:::{{amzn-s3-demo-bucket/*}}",
	  "arn:aws:s3:::{{amzn-s3-demo-bucket}}"
    ]
    },
  {
    "Sid": "{{AssignARoleActions2}}",
    "Effect": "Allow",
    "Action": "s3:ListAllMyBuckets",
    "Resource": "*"
  }
  ]
}
```

------

### S3 Access Grants
<a name="access-mgmt-s3ag"></a>

Use S3 Access Grants to create access grants to your Amazon S3 data for both identities in corporate identity directories, such as Active Directory, and to AWS Identity and Access Management (IAM) identities. S3 Access Grants helps you manage data permissions at scale. Additionally, S3 Access Grants logs end-user identity and the application used to access the S3 data in AWS CloudTrail. This provides a detailed audit history down to the end-user identity for all access to the data in your S3 buckets. For more information, see [Managing access with S3 Access Grants](access-grants.md).

### Access Points
<a name="access-mgmt-ap"></a>

Amazon S3 Access Points simplifies managing data access at scale for applications that use shared datasets on S3. Access Points are named network endpoints that are attached to a bucket. You can use access points to perform S3 object operations at scale, such as uploading and retrieving objects. A bucket can have up to 10,000 access points attached, and for each access point, you can enforce distinct permissions and network controls to give you detailed control over access to your S3 objects. S3 Access Points can be associated with buckets in the same account or in another trusted account. Access Points policies are resource-based policies that are evaluated in conjunction with the underlying bucket policy. For more information, see [Managing access to shared datasets with access points](access-points.md).

### Access control list (ACL)
<a name="access-mgmt-acl"></a>

An ACL is a list of grants identifying the grantee and the permission granted. ACLs grant basic read or write permissions to other AWS accounts. ACLs use an Amazon S3–specific XML schema. An ACL is a type of [AWS Identity and Access Management (IAM) policy](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies.html). An object ACL is used to manage access to an object, and a bucket ACL is used to manage access to a bucket. With bucket policies, there is a single policy for the entire bucket, but object ACLs are specified for each object. We recommend that you keep ACLs turned off, except in circumstances where you must individually control access for each object. For more information about using ACLs, see [Controlling ownership of objects and disabling ACLs for your bucket](about-object-ownership.md).

**Warning**  
The majority of modern use cases in Amazon S3 do not require the use of ACLs. 

The following is an example bucket ACL. The grant in the ACL shows a bucket owner that has full control permission. 

```
<?xml version="1.0" encoding="UTF-8"?>
	<AccessControlPolicy xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
		<Owner>
			<ID>{{Owner-Canonical-User-ID}}</ID>
		</Owner>
	<AccessControlList>
		<Grant>
			<Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Canonical User">
				<ID>{{Owner-Canonical-User-ID}}</ID>
			</Grantee>
			<Permission>FULL_CONTROL</Permission>
		</Grant>
	</AccessControlList>
</AccessControlPolicy>
```

### Object Ownership
<a name="access-mgmt-obj-ownership"></a>

To manage access to your objects, you must be the owner of the object. You can use the Object Ownership bucket-level setting to control ownership of objects uploaded to your bucket. Also, use Object Ownership to turn on ACLs. By default, Object Ownership is set to the *Bucket owner enforced setting* and all ACLs are turned off. When ACLs are turned off, the bucket owner owns all of the objects in the bucket and exclusively manages access to data. To manage access, the bucket owner uses policies or another access management tool, excluding ACLs. For more information, see [Controlling ownership of objects and disabling ACLs for your bucket](about-object-ownership.md).

Object Ownership has three settings that you can use both to control ownership of objects that are uploaded to your bucket and to turn on ACLs:

**ACLs turned off**
+ **Bucket owner enforced (default)** – ACLs are turned off, and the bucket owner automatically owns and has full control over every object in the bucket. ACLs do not affect permissions to data in the S3 bucket. The bucket uses policies exclusively to define access control.

**ACLs turned on**
+ **Bucket owner preferred** – The bucket owner owns and has full control over new objects that other accounts write to the bucket with the `bucket-owner-full-control` canned ACL. 
+ **Object writer** – The AWS account that uploads an object owns the object, has full control over it, and can grant other users access to it through ACLs.

**Additional best practices**  
Consider using the following bucket settings and tools to help protect data in transit and at rest, both of which are crucial in maintaining the integrity and accessibility of your data:
+ **Block Public Access** — Do not turn off the default bucket-level setting *Block Public Access*. This setting blocks public access to your data by default. For more information about blocking public access, see [Blocking public access to your Amazon S3 storage](access-control-block-public-access.md).
+ **S3 Versioning** — For data integrity, you can implement the S3 Versioning bucket setting, which versions your objects as you make updates, instead of overwriting them. You can use S3 Versioning to preserve, retrieve, and restore a previous version, if needed. For information about S3 Versioning, see [Retaining multiple versions of objects with S3 Versioning](Versioning.md). 
+ **S3 Object Lock** — S3 Object Lock is another setting that you can implement for achieving data integrity. This feature can implement a write-once-read-many (WORM) model to store objects immutably. For information about Object Lock, see [Locking objects with Object Lock](object-lock.md).
+ **Object encryption** — Amazon S3 offers several object encryption options that protect data in transit and at rest. *Server-side encryption* encrypts your object before saving it on disks in its data centers and then decrypts it when you download the objects. If you authenticate your request and you have access permissions, there is no difference in the way you access encrypted or unencrypted objects. For more information, see [Protecting data with server-side encryption](serv-side-encryption.md). S3 encrypts newly uploaded objects by default. For more information, see [Setting default server-side encryption behavior for Amazon S3 buckets](bucket-encryption.md). *Client-side encryption* is the act of encrypting data before sending it to Amazon S3. For more information, see [Protecting data by using client-side encryption](UsingClientSideEncryption.md). 
+ **Signing methods** — Signature Version 4 is the process of adding authentication information to AWS requests sent by HTTP. For security, most requests to AWS must be signed with an access key, which consists of an access key ID and secret access key. These two keys are commonly referred to as your security credentials. For more information, see [Authenticating Requests (AWS Signature Version 4)](https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-authenticating-requests.html) and [Signature Version 4 signing process](https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html). 

## Actions
<a name="access-management-actions"></a>

For a complete list of S3 permissions and condition keys, see [Actions, resources, and condition keys for Amazon S3](https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazons3.html) in the *Service Authorization Reference*.

For more information about the permissions to S3 API operations by S3 resource types, see [Required permissions for Amazon S3 API operations](using-with-s3-policy-actions.md).

**Actions**  
The AWS Identity and Access Management (IAM) actions for Amazon S3 are the possible actions that can be performed on an S3 bucket or object. You grant these actions to identities so they can act on your S3 resources. Examples of S3 actions are `s3:GetObject` to read objects in a bucket, and `s3:PutObject` to write objects to a bucket. 

**Condition keys**  
In addition to actions, IAM condition keys are limited to granting access to only when a condition is met. Condition keys are optional. 



**Note**  
In a resource-based access policy, such as a bucket policy, or in an identity-based policy, you can specify the following:  
An action or an array of actions in the `Action` element of the policy statement. 
In the `Effect` element of the policy statement, you can specify `Allow` to grant the actions listed, or you can specify `Deny` to block the listed actions. To further maintain the practice of least privileges, `Deny` statements in the `Effect` element of the access policy should be as broad as possible, and `Allow` statements should be as narrow as possible. `Deny` effects paired with the `s3:*` action are another good way to implement opt-in best practices for the identities that are included in policy condition statements.
A condition key in the `Condition` element of a policy statement.

## Access management use cases
<a name="access-management-usecases"></a>

Amazon S3 provides resource owners with a variety of tools for granting access. The S3 access management tool that you use depends on the S3 resources that you want to share, the identities that you are granting access to, and the actions that you want to allow or deny. You might want to use one or a combination of S3 access management tools to manage access to your S3 resources.

In most cases, you can use an access policy to manage permissions. An access policy can be a resource-based policy, which is attached to a resource, such as a bucket, or another Amazon S3 resource ([S3 resources](#access-management-resources)). An access policy can also be an identity-based policy, which is attached to an AWS Identity and Access Management (IAM) user, group, or role in your account. You might find that a bucket policy works better for your use case. For more information, see [Bucket policies for Amazon S3](bucket-policies.md). Alternatively, with AWS Identity and Access Management (IAM), you can create IAM users, groups, and roles within your AWS account and manage their access to buckets and objects through identity-based policies. For more information, see [Identity-based policies for Amazon S3](security_iam_id-based-policy-examples.md).

To help you navigate these access management options, the following are common Amazon S3 customer use cases and recommendations for each of the S3 access management tools. 

### The AWS account owner wants to share buckets only with users within the same account
<a name="access-mgmt-use-case-1"></a>

All access management tools can fulfill this basic use case. We recommend the following access management tools for this use case:
+ **Bucket policy** – If you want to grant access to one bucket or a small number of buckets, or if your bucket access permissions are similar from bucket to bucket, use a bucket policy. With bucket policies, you manage one policy for each bucket. For more information, see [Bucket policies for Amazon S3](bucket-policies.md).
+ **Identity-based policy** – If you have a very large number of buckets with different access permissions for each bucket, and only a few user roles to manage, you can use an IAM policy for users, groups, or roles. IAM policies are also a good option if you are managing user access to other AWS resources, as well as Amazon S3 resources. For more information, see [Example 1: Bucket owner granting its users bucket permissions](example-walkthroughs-managing-access-example1.md).
+ **S3 Access Grants** – You can use S3 Access Grants to grant access to your S3 buckets, prefixes, or objects. S3 Access Grants allows you to specify varying object-level permissions at scale; whereas, bucket policies are limited to 20 KB in size. For more information, see [Getting started with S3 Access Grants](access-grants-get-started.md).
+ **Access Points** – You can use Access Points, which are named network endpoints that are attached to a bucket. A bucket can have up to 10,000 access points attached, and for each access point you can enforce distinct permissions and network controls to give you detailed control over access to your S3 objects. For more information, see [Managing access to shared datasets with access points](access-points.md). 

### The AWS account owner wants to share buckets or objects with users from another AWS account (cross-account)
<a name="access-mgmt-use-case-2"></a>

To grant permission to another AWS account, you must use a bucket policy or one of the following recommended access management tools. You cannot use an identity-based access policy for this use case. For more information about granting cross-account access, see [How do I provide cross-account access to objects that are in Amazon S3 buckets?](https://repost.aws/knowledge-center/cross-account-access-s3)

We recommend the following access management tools for this use case:
+ **Bucket policy** – With bucket policies, you manage one policy for each bucket. For more information, see [Bucket policies for Amazon S3](bucket-policies.md).
+ **S3 Access Grants** – You can use S3 Access Grants to grant cross-account permissions to your S3 buckets, prefixes, or objects. You can use S3 Access Grants to specify varying object-level permissions at scale; whereas, bucket policies are limited to 20 KB in size. For more information, see [Getting started with S3 Access Grants](access-grants-get-started.md).
+ **Access Points** – You can use Access Points, which are named network endpoints that are attached to a bucket. A bucket can have up to 10,000 access points attached, and for each access point you can enforce distinct permissions and network controls to give you detailed control over access to your S3 objects. For more information, see [Managing access to shared datasets with access points](access-points.md). 

### The AWS account owner or bucket owner must grant permissions at the object-level or prefix-level, and these permissions vary from object to object or prefix to prefix
<a name="access-mgmt-use-case-3"></a>

In a bucket policy, for example, you can grant access to the objects within a bucket that share a specific [key name prefix](https://docs.aws.amazon.com/general/latest/gr/glos-chap.html#keyprefix) or have a specific tag. You can grant read permission on objects starting with the key name prefix `logs/`. However, if your access permissions vary by object, granting permissions to individual objects by using a bucket policy might not be practical, especially since bucket policies are limited to 20 KB in size.

We recommend the following access management tools for this use case:
+ **S3 Access Grants** – You can use S3 Access Grants to manage object-level or prefix-level permissions. Unlike bucket policies, you can use S3 Access Grants to specify varying object-level permissions at scale. Bucket policies are limited to 20 KB in size. For more information, see [Getting started with S3 Access Grants](access-grants-get-started.md).
+ **Access Points** – You can use access points to manage object-level or prefix-level permissions. Access Points are named network endpoints that are attached to a bucket. A bucket can have up to 10,000 access points attached, and for each access point you can enforce distinct permissions and network controls to give you detailed control over access to your S3 objects. For more information, see [Managing access to shared datasets with access points](access-points.md).
+ **ACLs** – We do not recommend using Access Control Lists (ACLs), especially because ACLs are limited to 100 grants per object. However, if you choose to turn on ACLs, in your Bucket Settings, set *Object Ownership* to *Bucket owner preferred* and *ACLs enabled*. With this setting, new objects that are written with the `bucket-owner-full-control` canned ACL are automatically owned by the bucket owner rather than the object writer. You can then use object ACLs, which is an XML-formatted access policy, to grant other users access to the object. For more information, see [Access control list (ACL) overview](acl-overview.md).

### The AWS account owner or bucket owner wants to limit bucket access only to specific account IDs
<a name="access-mgmt-use-case-4"></a>

We recommend the following access management tools for this use case:
+ **Bucket policy** – With bucket policies, you manage one policy for each bucket. For more information, see [Bucket policies for Amazon S3](bucket-policies.md).
+ **Access Points** – Access Points are named network endpoints that are attached to a bucket. A bucket can have up to 10,000 access points attached, and for each access point you can enforce distinct permissions and network controls to give you detailed control over access to your S3 objects. For more information, see [Managing access to shared datasets with access points](access-points.md).

### The AWS account owner or bucket owner wants distinct endpoints for every user or application that accesses their data
<a name="access-mgmt-use-case-5"></a>

We recommend the following access management tool for this use case:
+ **Access Points** – Access Points are named network endpoints that are attached to a bucket. A bucket can have up to 10,000 access points attached, and for each access point you can enforce distinct permissions and network controls to give you detailed control over access to your S3 objects. Each access point enforces a customized access point policy that works in conjunction with the bucket policy that is attached to the underlying bucket. For more information, see [Managing access to shared datasets with access points](access-points.md).

### The AWS account owner or bucket owner must manage access from Virtual Private Cloud (VPC) endpoints for S3
<a name="access-mgmt-use-case-6"></a>

Virtual Private Cloud (VPC) endpoints for Amazon S3 are logical entities within a VPC that allow connectivity only to S3. We recommend the following access management tools for this use case:
+ **Buckets in a VPC setting** – You can use a bucket policy to control who is allowed to access your buckets and which VPC endpoints they can access. For more information, see [Controlling access from VPC endpoints with bucket policies](example-bucket-policies-vpc-endpoint.md).
+ **Access Points** – If you choose to set up access points, you can use an access point policy. You can configure any access point to accept requests only from a virtual private cloud (VPC) to restrict Amazon S3 data access to a private network. You can also configure custom block public access settings for each access point. For more information, see [Managing access to shared datasets with access points](access-points.md).

### The AWS account owner or bucket owner must make a static website publicly available
<a name="access-mgmt-use-case-7"></a>

With S3, you can host a static website and allow anyone to view the content of the website, which is hosted from an S3 bucket. 

We recommend the following access management tools for this use case:
+ **Amazon CloudFront** – This solution allows you to host an Amazon S3 static website to the public while also continuing to block all public access to a bucket's content. If you want to keep all four S3 Block Public Access settings enabled and host an S3 static website, you can use Amazon CloudFront origin access control (OAC). Amazon CloudFront provides the capabilities required to set up a secure static website. Also, Amazon S3 static websites that do not use this solution can only support HTTP endpoints. CloudFront uses the durable storage of Amazon S3 while providing additional security headers, such as HTTPS. HTTPS adds security by encrypting a normal HTTP request and protecting against common cyberattacks.

  For more information, see [Getting started with a secure static website](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/getting-started-secure-static-website-cloudformation-template.html) in the *Amazon CloudFront Developer Guide*.
+ **Making your Amazon S3 bucket publicly accessible** – You can configure a bucket to be used as a publicly accessed static website. 
**Warning**  
We do not recommend this method. Instead, we recommend you use Amazon S3 static websites as a part of Amazon CloudFront. For more information, see the previous option, or see [Getting started with a secure static website](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/getting-started-secure-static-website-cloudformation-template.html).

  To create an Amazon S3 static website, without Amazon CloudFront, first, you must turn off all Block Public Access settings. When writing the bucket policy for your static website, make sure that you allow only `s3:GetObject` actions, not `ListObject` or `PutObject` permissions. This helps make sure that users cannot view all the objects in your bucket or add their own content. For more information, see [Setting permissions for website access](WebsiteAccessPermissionsReqd.md).

### The AWS account owner or bucket owner wants to make the content of a bucket publicly available
<a name="access-mgmt-use-case-8"></a>

When creating a new Amazon S3 bucket, the *Block Public Access* setting is enabled by default. For more information about blocking public access, see [Blocking public access to your Amazon S3 storage](access-control-block-public-access.md). 

We do not recommend allowing public access to your bucket. However, if you must do so for a particular use case, we recommend the following access management tool for this use case:
+ **Disable Block Public Access setting** – A bucket owner can allow unauthenticated requests to the bucket. For example, unauthenticated [PUT Object](https://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectPUT.html) requests are allowed when a bucket has a public bucket policy, or when a bucket ACL grants public access. All unauthenticated requests are made by other arbitrary AWS users, or even unauthenticated, anonymous users. This user is represented in ACLs by the specific canonical user ID `65a011a29cdf8ec533ec3d1ccaae921c`. If an object is uploaded to a `WRITE` or `FULL_CONTROL`, then this specifically grants access to the All Users group or the anonymous user. For more information about public bucket policies and public access control lists (ACLs), see [The meaning of "public"](access-control-block-public-access.md#access-control-block-public-access-policy-status).

### The AWS account owner or bucket owner has exceeded access policy size limits
<a name="access-mgmt-use-case-9"></a>

Both bucket policies and identity-based policies have a 20 KB size limit. If your access permission requirements are complex, you might exceed this size limit. 

We recommended the following access management tools for this use case:
+ **Access Points** – Use access points if this works with your use case. With access points, each bucket has multiple named network endpoints, each with its own access point policy that works with the underlying bucket policy. However, access points can only act on objects, not buckets, and does not support cross-Region replication. For more information, see [Managing access to shared datasets with access points](access-points.md).
+ **S3 Access Grants** – Use S3 Access Grants, which supports a very large number of grants that give access to buckets, prefixes, or objects. For more information, see [Getting started with S3 Access Grants](access-grants-get-started.md).

### The AWS account owner or admin role wants to grant bucket, prefix, or object access directly to users or groups in a corporate directory
<a name="access-mgmt-use-case-10"></a>

Instead of managing users, groups, and roles through AWS Identity and Access Management (IAM), you can add your corporate directory to AWS IAM Identity Center. For more information, see [What is IAM Identity Center?](https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html). 

After you add your corporate directory to AWS IAM Identity Center, we recommend that you use the following access management tool to grant corporate directory identities access to your S3 resources:
+ **S3 Access Grants** – Use S3 Access Grants, which supports granting access to users or roles in your corporate directory. For more information, see [Getting started with S3 Access Grants](access-grants-get-started.md).

### The AWS account owner or bucket owner wants to give the AWS CloudFront service access to write CloudFront logs to an S3 bucket
<a name="access-mgmt-use-case-11"></a>

We recommended the following access management tool for this use case:
+ **Bucket ACL** – The only recommended use case for bucket ACLs is to grant permissions to certain AWS services, such as the Amazon CloudFront `awslogsdelivery` account. When you create or update a distribution and turn on CloudFront logging, CloudFront updates the bucket ACL to give the `awslogsdelivery` account `FULL_CONTROL` permissions to write logs to your bucket. For more information, see [Permissions required to configure standard logging and to access your log files](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/AccessLogs.html#AccessLogsBucketAndFileOwnership) in the *Amazon CloudFront Developer Guide*. If the bucket that stores the logs uses the *Bucket owner enforced* setting for S3 Object Ownership to turn off ACLs, CloudFront cannot write logs to the bucket. For more information, see [Controlling ownership of objects and disabling ACLs for your bucket](about-object-ownership.md).

### You, as the bucket owner, want to maintain full control of objects that are added to the bucket by other users
<a name="access-mgmt-use-case-12"></a>

You can grant other accounts access to upload objects to your bucket by using a bucket policy, access point, or S3 Access Grants. If you have granted cross-account access to your bucket, you can make sure that any objects uploaded to your bucket remain under your full control. 

We recommended the following access management tool for this use case:
+ **Object Ownership** – Keep the bucket-level setting *Object Ownership* at the default *Bucket owner enforced* setting.

## Access management troubleshooting
<a name="access-management-troubleshooting"></a>

The following resources can help you troubleshoot any issues with S3 access management: 

**Troubleshooting Access Denied (403 Forbidden) errors**  
If you encounter access denial issues, check the account-level and bucket-level settings. Also, check the access management feature that you are using to grant access to make sure that the policy, setting, or configuration is correct. For more information about common causes of Access Denied (403 Forbidden) errors in Amazon S3, see [Troubleshoot access denied (403 Forbidden) errors in Amazon S3](troubleshoot-403-errors.md).

**IAM Access Analyzer for S3**  
If you do not want to make any of your resources publicly available, or if you want to limit public access to your resources, you can use IAM Access Analyzer for S3. On the Amazon S3 console, use IAM Access Analyzer for S3 to review all buckets that have bucket access control lists (ACLs), bucket policies, or access point policies that grant public or shared access. IAM Access Analyzer for S3 alerts you to buckets that are configured to allow access to anyone on the internet or other AWS accounts, including AWS accounts outside of your organization. For each public or shared bucket, you receive findings that report the source and level of public or shared access. 

In IAM Access Analyzer for S3, you can block all public access to a bucket with a single action. We recommend that you block all public access to your buckets, unless you require public access to support a specific use case. Before you block all public access, make sure that your applications will continue to work correctly without public access. For more information, see [Blocking public access to your Amazon S3 storage](access-control-block-public-access.md).

You can also review your bucket-level permission settings to configure detailed levels of access. For specific and verified use cases that require public or shared access, you can acknowledge and record your intent for the bucket to remain public or shared by archiving the findings for the bucket. You can revisit and modify these bucket configurations at any time. You can also download your findings as a CSV report for auditing purposes.

IAM Access Analyzer for S3 is available at no extra cost on the Amazon S3 console. IAM Access Analyzer for S3 is powered by AWS Identity and Access Management (IAM) IAM Access Analyzer. To use IAM Access Analyzer for S3 on the Amazon S3 console, you must visit the [IAM Console](https://console.aws.amazon.com/iam/) and create an account-level analyzer in IAM Access Analyzer for each individual Region. 

For more information about IAM Access Analyzer for S3, see [Reviewing bucket access using IAM Access Analyzer for S3](access-analyzer.md).

**Logging and monitoring**  
Monitoring is an important part of maintaining the reliability, availability, and performance of your Amazon S3 solutions so that you can more easily debug an access failure. Logging can provide insight into any errors users are receiving, and when and what requests are made. AWS provides several tools for monitoring your Amazon S3 resources, such as the following: 
+ AWS CloudTrail
+ Amazon S3 Access Logs
+ AWS Trusted Advisor
+ Amazon CloudWatch

For more information, see [Logging and monitoring in Amazon S3](monitoring-overview.md).