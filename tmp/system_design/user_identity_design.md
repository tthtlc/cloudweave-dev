
Given your background (CMP, OpenFGA, Vault, Apache Libcloud, multi-cloud provisioning), I would **separate Authentication, Identity Federation, and Authorization** into different layers.

Looking at your login page, you have:

* Username/password
* Sign in with Google
* Sign in with GitHub

If your CMP eventually supports:

* Google
* GitHub
* Facebook
* Microsoft Entra ID
* Okta
* AWS IAM Identity Center
* DigitalOcean
* Nutanix
* Kubernetes
* LDAP
* SAML

then **Dex + OpenFGA** complement each other very well because they solve completely different problems.

---

# High level architecture

```
                    +----------------------+
                    |     Web Browser      |
                    +----------+-----------+
                               |
                               |
                      OAuth / OIDC Login
                               |
                               v
                    +----------------------+
                    |         Dex          |
                    | Identity Federation |
                    +----------+-----------+
                               |
          +--------------------+-----------------------+
          |                    |                       |
          |                    |                       |
     Google OIDC          GitHub OAuth          Microsoft
          |                    |                    |
          |                    |                    |
      Facebook             AWS IAM IC           LDAP
          |                    |                    |
          +--------------------+--------------------+

                         Dex issues

                ID Token + Access Token + Refresh Token

                               |
                               v

                 +---------------------------+
                 |      CMP Backend API      |
                 +------------+--------------+
                              |
               Lookup authenticated identity
                              |
                              v
                  +-----------------------+
                  |      OpenFGA          |
                  | Authorization Engine  |
                  +-----------+-----------+
                              |
                  Can user create VM?
                  Can delete project?
                  Can manage AWS?
                  Can provision Nutanix?

                              |
                              v

                 +-------------------------+
                 | Apache Libcloud / SDKs |
                 +-------------------------+
```

---

# Responsibility of each component

## Dex

Dex answers only one question:

> "Who is this user?"

It does NOT answer:

* can this person create VM?
* can this person access AWS?
* can delete project?
* can manage billing?

Dex only authenticates.

---

## OpenFGA

OpenFGA answers

> "What is this authenticated user allowed to do?"

Examples

```
User:
    alice

Resource:
    AWS Account A

Relation:
    admin
```

```
user:alice
    can create EC2

user:alice
    cannot delete Azure subscription

user:bob
    can provision Nutanix VM

user:charlie
    read-only Kubernetes
```

---

# Why not use Dex alone?

Dex supports:

```
Google

GitHub

GitLab

OIDC

LDAP

SAML

Microsoft

OpenShift

Bitbucket

etc
```

But Dex has almost no authorization model.

You could put claims inside JWT

```
roles:
    admin

groups:
    cloud-admin
```

But eventually your authorization becomes

```
if(role=="admin")

if(group=="cloud")

if(role=="owner")

if(project=="abc")
```

This becomes impossible to manage.

---

# Why OpenFGA?

Suppose your CMP manages

```
500 users

1000 projects

15 AWS accounts

30 Azure subscriptions

20 Nutanix clusters

100 Kubernetes clusters
```

Now permissions become

```
Alice

AWS Account A
   admin

AWS Account B
   read-only

Azure
   operator

Nutanix Cluster 5
   owner

Kubernetes Cluster 3
   viewer
```

JWT cannot realistically contain all of this.

OpenFGA stores it separately.

---

# Login flow

Step 1

User clicks

```
Sign in with Google
```

Browser

↓

Dex

↓

Google

↓

Google authenticates

↓

Google returns

```
OIDC ID Token
```

↓

Dex verifies signature

↓

Dex creates

```
Internal User

ID = 84e5...
```

↓

Dex returns

```
ID Token

Access Token

Refresh Token
```

to CMP

---

Step 2

CMP extracts

```
sub

email

groups
```

Example

```
sub:

google:123456789
```

---

Step 3

CMP converts

```
google:123456789

↓

internal UUID

user-19
```

---

Step 4

Query OpenFGA

```
Can

user-19

create_vm

project-abc
```

OpenFGA

↓

YES

↓

Provision VM

---

# Mapping external identities

Suppose user logs in

Google

```
sub

11223344
```

GitHub

```
id

998877
```

Facebook

```
id

445566
```

You probably don't want

```
Google User

GitHub User

Facebook User
```

to become three different CMP users.

Instead create

```
Identity Table

Internal User UUID

External Provider

External Subject
```

Example

| Internal User | Provider | External Subject |
| ------------- | -------- | ---------------- |
| user-1        | Google   | 11223344         |
| user-1        | GitHub   | 998877           |
| user-1        | Facebook | 445566           |

Now one CMP account may authenticate from multiple providers.

---

# What about AWS?

AWS is interesting.

AWS is **not** primarily an Identity Provider.

Instead

```
User logs in

↓

Google

↓

CMP

↓

Provision AWS
```

Now CMP needs AWS credentials.

Don't ask user for AWS password.

Instead use

```
STS AssumeRole
```

```
CMP IAM Role

↓

Temporary Credentials

↓

EC2

↓

S3

↓

RDS
```

Store the long-term bootstrap credential (or better, use workload identity where possible) in Vault.

---

# DigitalOcean

DigitalOcean does not provide enterprise identity federation like Google.

Normally

```
User

↓

CMP

↓

Vault

↓

DO API Token

↓

DigitalOcean API
```

The API token belongs to a DigitalOcean team or service account rather than the end user.

---

# Nutanix

Usually

```
CMP

↓

Vault

↓

Prism Central Service Account

↓

Nutanix API
```

Enterprise deployments may integrate Prism Central with LDAP or SAML for human login, while automation commonly uses service accounts or API credentials.

---

# Vault's role

Vault should **not** authenticate users through Google or GitHub in this architecture.

Vault stores:

* AWS AssumeRole bootstrap credentials (if needed)
* DigitalOcean API tokens
* Nutanix credentials
* Azure service principals (or federated credentials)
* GCP service accounts where appropriate
* Kubernetes service account tokens (or better, workload identity)

Vault issues temporary credentials whenever possible.

---

# Recommended architecture for a Cloud Management Platform

```
                        Browser
                           |
                           |
                   Google Login
                  GitHub Login
                 Facebook Login
               Microsoft Entra
                       |
                       v
                    +------+
                    | Dex  |
                    +------+
                        |
                OIDC ID Token
                        |
                        v
             +-------------------+
             | Identity Service  |
             +-------------------+
                        |
          Link External Identity
             to Internal User
                        |
                        v
                 +-------------+
                 | OpenFGA     |
                 +-------------+
                        |
          Authorization Decision
                        |
                        v
             +-------------------+
             | Provisioning API  |
             +-------------------+
                        |
          +-------------+--------------+
          |             |              |
          v             v              v
        Vault      Apache Libcloud   Native SDKs
          |             |              |
          |             |              |
      AWS STS      AWS/GCP/Azure   Nutanix, VMware,
                                   Kubernetes, etc.
```

## One enhancement I'd recommend

As your CMP grows, introduce a dedicated **Identity Service** between Dex and the rest of your platform. That service becomes the canonical source of user identities and handles:

* Linking multiple external identities (Google, GitHub, Microsoft, etc.) to one internal user.
* Creating users on first login (Just-In-Time provisioning).
* Synchronizing profile information and groups from identity providers.
* Issuing your platform's internal user ID that OpenFGA and the rest of the CMP use.
* Translating external claims into your internal tenant/project model.

This keeps Dex focused on federation, OpenFGA focused on authorization, Vault focused on secrets, and your provisioning layer focused on interacting with cloud providers. Each component has a single responsibility, making the architecture easier to evolve and audit.

