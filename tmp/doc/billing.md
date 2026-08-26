
AWS exposes several cost/billing–related APIs you can hit via standard HTTPS (JSON) to programmatically query, generate, and retrieve billing and price data. [docs.aws.amazon](https://docs.aws.amazon.com/general/latest/gr/billing.html)

## Main AWS billing-related APIs

Here are the primary “REST-style” AWS services you’d use for billing/cost data:

| Area | Service / API | Typical use cases |
| --- | --- | --- |
| Cost & usage | AWS Cost Explorer API | Query historical & forecasted cost/usage by time, service, tags, dimensions. [docs.aws.amazon](https://docs.aws.amazon.com/general/latest/gr/billing.html) |
| Raw billing | AWS Cost and Usage Reports (CUR) + S3/Athena | Retrieve detailed line-item billing records, then query via Athena/your own API. [docs.aws.amazon](https://docs.aws.amazon.com/general/latest/gr/billing.html) |
| Budgets | AWS Budgets API | Create/update budgets, read actuals vs budget, notifications. [docs.aws.amazon](https://docs.aws.amazon.com/general/latest/gr/billing.html) |
| Pricing | AWS Price List (Pricing) API | Get SKU-level service pricing, build calculators, scenario planning. [docs.aws.amazon](https://docs.aws.amazon.com/general/latest/gr/billing.html) |
| Free tier | AWS Free Tier API | Programmatically track free-tier usage vs limits. [docs.aws.amazon](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/using-free-tier-api.html) |
| New Billing API | AWS Billing API | Query “billing views” and detailed billing/credits/preferences via a dedicated endpoint. [docs.aws.amazon](https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/Welcome.html) |

All of these are exposed through AWS’s standard service endpoints and use AWS Signature v4 auth; you can treat them as normal REST-ish JSON APIs from your tooling. [docs.aws.amazon](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/price-changes.html)

## AWS Billing API (new service)

AWS has a dedicated **Billing** service (endpoint `https://billing.us-east-1.api.aws`) exposing a set of actions focused on billing views and account-level billing metadata. [docs.aws.amazon](https://docs.aws.amazon.com/botocore/latest/reference/services/billing.html)

Key actions include (all JSON over HTTPS, authenticated with SigV4):

- `GetBillingData` – Perform queries on billing information for a given time period. [docs.aws.amazon](https://docs.aws.amazon.com/online-register/latest/data-formats/awsbilling.html)
- `GetBillingDetails` – Retrieve detailed line-item billing information. [docs.aws.amazon](https://docs.aws.amazon.com/online-register/latest/data-formats/awsbilling.html)
- `GetBillingView` / `GetBillingViewData` – Access metadata and cost/usage data for a specific “billing view”. [docs.aws.amazon](https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/Welcome.html)
- `ListBillingViews` – Enumerate available billing views. [docs.aws.amazon](https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/Welcome.html)
- `GetCredits` – View credits that have been redeemed on the account. [docs.aws.amazon](https://docs.aws.amazon.com/online-register/latest/data-formats/awsbilling.html)
- `GetBillingPreferences`, `GetIAMAccessPreference`, `GetSellerOfRecord`, etc. – Read account‑level billing configuration and contract info. [docs.aws.amazon](https://docs.aws.amazon.com/online-register/latest/data-formats/awsbilling.html)

These are consumed via SDKs (e.g., `session.create_client('billing')` in boto3) or direct HTTP requests to the service endpoint. [docs.aws.amazon](https://docs.aws.amazon.com/botocore/latest/reference/services/billing.html)

## Cost Explorer API

For “generate billing reports / queries by time, group-by, filters” the **Cost Explorer API** is the workhorse. [docs.aws.amazon](https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_GetCostAndUsage.html)

Representative operations:

- `GetCostAndUsage` – Query cost/usage metrics (e.g., `BlendedCost`, `UnblendedCost`, `UsageQuantity`) over a time range, with filters and group-by on dimensions like `SERVICE`, `LINKED_ACCOUNT`, `TAG`, etc. [docs.aws.amazon](https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_GetCostAndUsage.html)
- `GetCostForecast` – Forecast cost over a future time period. [docs.aws.amazon](https://docs.aws.amazon.com/general/latest/gr/billing.html)
- `GetUsageForecast` – Forecast usage metrics. [docs.aws.amazon](https://docs.aws.amazon.com/general/latest/gr/billing.html)

You typically hit the regional Cost Explorer endpoint via AWS SDK or signed HTTPS requests, posting JSON bodies that define `TimePeriod`, `Metrics`, `Granularity`, `Filter`, and `GroupBy`. [docs.aws.amazon](https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_GetCostAndUsage.html)

## Cost and Usage Reports (CUR)

If you want **complete raw billing detail**, AWS recommends CUR rather than a single “billing REST API”:

- You configure a Cost and Usage Report to export detailed line items to an S3 bucket. [docs.aws.amazon](https://docs.aws.amazon.com/general/latest/gr/billing.html)
- Then you query them with Athena/Glue and optionally front them with your own REST API via API Gateway + Lambda (many sample projects do this). [github](https://github.com/aws-samples/cost-report-query-api)

This pattern is what most “billing report APIs” on GitHub implement: Athena queries over CUR wrapped by a custom HTTP API. [github](https://github.com/mpcloud/aws-billing-api)

## AWS Budgets API

For budget and alert–oriented billing features:

- `CreateBudget`, `UpdateBudget`, `DescribeBudgets`, etc., to manage budgets programmatically. [docs.aws.amazon](https://docs.aws.amazon.com/general/latest/gr/billing.html)
- You can read actual spend and forecast linked to each budget, and manage notifications (SNS/Email) using this API. [docs.aws.amazon](https://docs.aws.amazon.com/general/latest/gr/billing.html)

This is useful when you need automation around “equire billing” in the sense of automatically watching for threshold breaches.

## AWS Price List (Pricing) API

If your “generate billing” workflow needs **pricing data**, use the Pricing APIs:

- **Price List Query API**: Query SKU‑level prices for specific services, attributes, and regions via `https://api.pricing.{region}.amazonaws.com`. [docs.aws.amazon](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/price-changes.html)
- **Price List Bulk API**: Download full price lists for services in JSON/CSV for offline analysis/tools. [docs.aws.amazon](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/price-changes.html)

This is good for pre‑billing estimations, cost calculators, and scenario modeling. [docs.aws.amazon](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/price-changes.html)

## Free Tier API

For free-tier‑specific billing/usage:

- `GetFreeTierUsage` – Retrieve monthly free tier usage by service (e.g., AWS Glue). [docs.aws.amazon](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/using-free-tier-api.html)
- Accessible via AWS CLI/SDKs and exposed as a normal AWS JSON API under the Billing & Cost Management umbrella. [docs.aws.amazon](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/using-free-tier-api.html)

***

If you’re building a system to “generate billing” and query costs, are you more interested in (a) historical actual charges from CUR/Billing API, or (b) *price estimation* from the Pricing API for planned usage?  
