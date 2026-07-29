<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# what are the different ways cloud usage are charged?  is it possible to just put router at the main choke point (like a bastion host architecture) and then charge by the total traffic passed

Cloud usage is usually charged in a few buckets: compute time, storage capacity, network transfer, managed-service requests/operations, and sometimes commitments like reserved capacity or savings plans. Many providers also add separate charges for things like load balancers, NAT gateways, inter-region traffic, and support plans.[^1][^2][^3]

## Common billing dimensions

- Compute: billed per second/minute/hour for VMs, containers, or serverless execution time.[^2][^1]
- Storage: billed by GB-month, plus often per-read/write request counts for object storage.[^4][^2]
- Network: billed for outbound traffic, inter-AZ/inter-region traffic, VPN/peering, and sometimes public IP-related data paths.[^3][^5][^6]
- Service usage: billed per request, API call, operation, message, or transaction for managed services.[^2]
- Commitments: reserved instances, savings plans, or similar discounts exchange flexibility for lower effective rates.[^7][^1]


## About “charge by total traffic through a router”

Yes, you can technically meter and charge on total traffic passing through a choke point, but that is only a billing policy you build yourself, not how cloud providers usually bill native cloud resources. Providers generally bill by specific meter types such as egress bytes, instance hours, requests, or allocated capacity, and network pricing is often directional and topology-aware rather than just “all bytes through one router”.[^5][^6][^3]

That design also has practical limits: it may miss east-west traffic that bypasses the router, it can be expensive to force all traffic through a single bottleneck, and it does not reflect compute, storage, or control-plane costs. A router-based model is closer to a private-network or chargeback scheme, where you measure aggregate throughput and allocate costs internally, not a full cloud billing model.[^8][^3]

## When it works well

A choke-point model works best when you want simple internal chargeback for a single tenant boundary, a shared egress gateway, or a centralized bastion/proxy architecture. It is especially useful if most cost comes from outbound internet traffic, because egress fees are a major cloud cost driver and are often explicitly billed per GB.[^6][^3]

## Main caveat

If your goal is accurate end-user billing, “total traffic passed” is usually too coarse on its own. In practice you would combine bytes, direction, destination, and possibly protocol or tenant tags, then add separate meters for compute and storage so the bill matches actual cloud cost drivers.[^3][^2]
<span style="display:none">[^10][^11][^12][^13][^14][^15][^16][^17][^18][^19][^20][^21][^22][^23][^24][^25][^26][^27][^28][^29][^30][^9]</span>

<div align="center">⁂</div>

[^1]: https://www.infracost.io/resources/glossary/cloud-pricing-models

[^2]: https://dev.to/ibbus/day-4-understanding-cloud-billing-and-pricing-models-55n0

[^3]: https://www.cloudflare.com/learning/cloud/what-is-aws-data-transfer-pricing/

[^4]: https://aws.amazon.com/s3/pricing/

[^5]: https://azure.microsoft.com/en-us/pricing/details/bandwidth/

[^6]: https://cloud.google.com/network-tiers/pricing

[^7]: https://www.exoscale.com/blog/cloud-pricing-models/

[^8]: https://hokstadconsulting.com/blog/5-chargeback-models-for-multi-cloud

[^9]: https://www.usage.ai/blogs/finops/cost-optimization/usage-based-pricing-bill-spikes/

[^10]: https://learn.microsoft.com/sk-sk/training/modules/cmu-build-apps-cloud/7-economics

[^11]: https://www.flexera.com/blog/finops/cloud-cost-models-management-strategies/

[^12]: https://www.deloitte.com/us/en/what-we-do/capabilities/cloud-transformation/articles/cloud-consumption-model.html

[^13]: https://www.linkedin.com/pulse/cloud-pricing-models-understanding-your-options-making-them-xbssc

[^14]: https://dev.to/574n13y/cloud-service-pricing-models-2f7

[^15]: https://www.tierpoint.com/blog/cloud/cloud-cost-models/

[^16]: https://www.digitalocean.com/blog/understand-your-cloud-bill

[^17]: https://cloud.google.com/blog/topics/cost-management/demystifying-cloud-pricing-a-comprehensive-guide-for-businesses

[^18]: https://en.wikipedia.org/wiki/Pay-as-you-use

[^19]: https://www.scribd.com/document/866592466/UNIT-IV

[^20]: https://smallestbusiness.com/compare/gcp-egress-cost/

[^21]: https://azure.microsoft.com/ko-kr/pricing/details/bandwidth/

[^22]: https://egresscost.com/aws/

[^23]: https://azure.microsoft.com/de-de/pricing/details/bandwidth/

[^24]: https://egresscost.com/gcp/

[^25]: https://cloud.google.com/vpc/pricing-announce

[^26]: https://lp.zeroservices.eu/articles/google-cloud-egress-pricing-2026/

[^27]: https://repost.aws/questions/QUnXZUu85QSRuFh-x_2c9mPg/aws-data-transfer

[^28]: https://atonementlicensing.com/blog/gcp-egress-negotiation/

[^29]: https://storage.googleapis.com/cloud-training/gcpnet/v2.0/student/07 Network Billing and Pricing 2.0.pdf

[^30]: https://www.cloudbolt.io/guide-to-aws-cost-optimization/aws-data-transfer-pricing/

