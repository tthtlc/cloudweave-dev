
AWS FinOps Agent is an AWS-managed, preview FinOps service with its own service API surface, and it is not something Apache Libcloud natively supports today.  In practice, you enable the underlying AWS cost services the agent uses, create the agent in the console or via AWS APIs, and then access it with the AWS SDK/HTTP APIs rather than through Libcloud’s standard abstractions. [docs.aws.amazon](https://docs.aws.amazon.com/online-register/latest/data-formats/awsfinopsagent.html)

## What it is

AWS describes FinOps Agent as a Bedrock-powered agent that can answer cost questions, investigate anomalies, surface optimization opportunities, generate recurring reports, and use uploaded context plus memory across sessions.  It integrates with AWS Cost Explorer, AWS Cost Anomaly Detection, AWS Cost Optimization Hub, AWS Compute Optimizer, and CloudTrail, but only for the resources and integrations you permit during setup. [docs.aws.amazon](https://docs.aws.amazon.com/finops-agent/latest/userguide/getting-started.html)

The getting started guide says the console workflow currently runs in us-east-1 and the creation wizard can create the needed IAM roles and attach required policies automatically.  During preview, the agent itself is offered at no charge, but its calls to underlying AWS APIs still incur normal API pricing where applicable. [docs.aws.amazon](https://docs.aws.amazon.com/finops-agent/latest/userguide/chatting-with-finops-agent.html)

## APIs to enable

There are really two layers to “enable.” First, you need the AWS data sources the agent reads from: Cost Explorer, Cost Anomaly Detection, Cost Optimization Hub, Compute Optimizer, and CloudTrail.  Second, you need permissions for the FinOps Agent service itself, whose documented read/list API actions include `GetAgentSpace`, `GetTask`, `GetTurn`, `ListAgentSpaces`, `ListConversations`, `ListTasks`, `ListTurns`, `ListArtifacts`, `GetArtifactContent`, `ListDocuments`, and related actions for automations, integrations, and connections. [github](https://github.com/aws-samples/sample-finops-agent)

A concise view is below.

| Layer | What to enable | Why |
|---|---|---|
| Underlying cost data | AWS Cost Explorer  [docs.aws.amazon](https://docs.aws.amazon.com/online-register/latest/data-formats/awsfinopsagent.html) | Cost and usage, forecasting, SP/RI analysis.  [docs.aws.amazon](https://docs.aws.amazon.com/online-register/latest/data-formats/awsfinopsagent.html) |
| Anomaly pipeline | AWS Cost Anomaly Detection  [docs.aws.amazon](https://docs.aws.amazon.com/online-register/latest/data-formats/awsfinopsagent.html) | Trigger and investigate spend anomalies.  [docs.aws.amazon](https://docs.aws.amazon.com/online-register/latest/data-formats/awsfinopsagent.html) |
| Optimization data | AWS Cost Optimization Hub  [docs.aws.amazon](https://docs.aws.amazon.com/online-register/latest/data-formats/awsfinopsagent.html) | Savings recommendations.  [docs.aws.amazon](https://docs.aws.amazon.com/online-register/latest/data-formats/awsfinopsagent.html) |
| Rightsizing data | AWS Compute Optimizer  [docs.aws.amazon](https://docs.aws.amazon.com/online-register/latest/data-formats/awsfinopsagent.html) | Detailed resource recommendations.  [docs.aws.amazon](https://docs.aws.amazon.com/online-register/latest/data-formats/awsfinopsagent.html) |
| Change correlation | AWS CloudTrail  [docs.aws.amazon](https://docs.aws.amazon.com/online-register/latest/data-formats/awsfinopsagent.html) | Trace infrastructure changes during anomaly investigations.  [docs.aws.amazon](https://docs.aws.amazon.com/online-register/latest/data-formats/awsfinopsagent.html) |
| Agent control/data plane | `awsfinopsagent:*` specific actions, such as `ListAgentSpaces`, `ListTasks`, `GetTask`, `ListTurns`, `GetTurn`, `GetArtifactMetadata`, `GetArtifactContent`  [github](https://github.com/aws-samples/sample-finops-agent) | Read agent workspaces, conversations, tasks, turns, reports, and artifacts.  [github](https://github.com/aws-samples/sample-finops-agent) |

The IAM setup guide is the authoritative place for the exact policies, roles, and trust relationships, and AWS states the service uses four IAM policies and two IAM roles.  If you are doing this manually rather than via the wizard, start there before writing any custom integration code. [docs.aws.amazon](https://docs.aws.amazon.com/finops-agent/latest/userguide/setting-up.html)

## Libcloud fit

Apache Libcloud is mainly a multi-cloud abstraction library for compute, storage, load balancers, DNS, containers, and similar infrastructure primitives; its AWS support is exposed through common AWS connection classes, but it does not publish a built-in FinOps Agent driver or high-level FinOps abstraction.  So the direct answer is: you generally cannot “use Libcloud to call AWS FinOps Agent” in the same way you use Libcloud for EC2, S3, or Route53-style resources. [libcloud.readthedocs](https://libcloud.readthedocs.io/en/latest/apidocs/libcloud.common.aws.html)

What Libcloud *can* do is provide reusable AWS-style connection/signing primitives if you insist on building a custom integration layer yourself.  Even then, you would still be implementing AWS FinOps Agent-specific endpoints, request signing, pagination, and response parsing outside Libcloud’s supported resource model. [github](https://github.com/aws-samples/sample-finops-agent)

## Practical integration

The cleanest approach is to use the AWS SDK for Python, because FinOps Agent is an AWS-native service with AWS IAM authorization and AWS-defined actions.  If boto3 has released service support in your environment, use that; otherwise call the service endpoint with SigV4-signed HTTPS requests via `botocore` or another AWS signer. [alexocallaghan](https://alexocallaghan.com/configure-boto3-endpoint-url)

A pragmatic architecture would look like this:
- Use AWS SDK credentials from your usual profile, role, or STS session. [docs.aws.amazon](https://docs.aws.amazon.com/finops-agent/latest/userguide/setting-up.html)
- Call FinOps Agent service APIs for workspace, conversation, task, turn, and artifact retrieval. [github](https://github.com/aws-samples/sample-finops-agent)
- Use Libcloud separately only for other multi-cloud inventory/enrichment tasks, such as mapping EC2-like instances or object storage resources across providers. [libcloud.readthedocs](https://libcloud.readthedocs.io/en/latest/apidocs/libcloud.common.aws.html)
- Join the two at your application layer: FinOps Agent for AWS cost intelligence, Libcloud for normalized infra metadata. [docs.aws.amazon](https://docs.aws.amazon.com/online-register/latest/data-formats/awsfinopsagent.html)

Example pattern in Python, using AWS SDK concepts rather than Libcloud:
```python
import boto3

session = boto3.Session(profile_name="default", region_name="us-east-1")

# Pseudocode: exact client/service name depends on SDK release support
client = session.client("awsfinopsagent")

spaces = client.list_agent_spaces()
for space in spaces.get("agentSpaces", []):
    tasks = client.list_tasks(agentSpaceId=space["agentSpaceId"])
    print(space["agentSpaceId"], tasks)
```

If boto3 does not yet expose the service model, the next-best option is a raw SigV4 client.  In that case, Libcloud is still not your best tool, because you would be using only its low-level AWS connection helpers while reimplementing the rest yourself. [alexocallaghan](https://alexocallaghan.com/configure-boto3-endpoint-url)

## If you want Libcloud anyway

If your goal is “single Python dependency for all clouds,” the realistic pattern is a hybrid adapter.  Use Libcloud for cross-cloud resources, and add a custom AWS-only adapter class for FinOps Agent APIs. [libcloud.readthedocs](https://libcloud.readthedocs.io/en/latest/apidocs/libcloud.common.aws.html)

Conceptually:
1. Libcloud discovers or normalizes cloud resources across AWS, Azure, GCP, or others. [libcloud.readthedocs](https://libcloud.readthedocs.io/en/latest/apidocs/libcloud.common.aws.html)
2. Your AWS-specific adapter calls FinOps Agent APIs like `ListAgentSpaces`, `ListTasks`, `GetTask`, `ListTurns`, and artifact/document retrieval. [github](https://github.com/aws-samples/sample-finops-agent)
3. Your service correlates agent output with Libcloud resource identities or tags. [github](https://github.com/aws-samples/sample-finops-agent)

That gives you a workable design without forcing Libcloud into a role it does not natively cover. Would you like a concrete Python example using `botocore` SigV4 signing for AWS FinOps Agent, or a sample adapter that combines boto3 and Libcloud in one class?
