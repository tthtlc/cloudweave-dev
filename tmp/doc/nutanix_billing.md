
Yes — Nutanix does have API access for billing-related data, but the exact capability depends on which Nutanix product/service you mean. For **Nutanix Cloud Hosted / Xi Cloud Services**, the billing-management docs describe usage details such as rate, quantity, and amount charged per entity, and a separate “Displaying Billing and Usage Details” page covers invoices and payment details for Self-Service SaaS. [portal.nutanix](https://portal.nutanix.com/page/documents/details?targetId=Xi-Cloud-Services-Administration-Guide:adm-billing-management-xi-c.html)

## What’s available

- Nutanix’s main API platform is documented in the Nutanix API reference, including Prism Element v2, Prism Central v3, and the newer v4 APIs. [nutanix](https://www.nutanix.dev/api-reference/)
- The Nutanix developer portal says v4 APIs are the recommended production APIs for administrative and reporting use cases. [developers.nutanix](https://developers.nutanix.com/)
- For cost-related functionality specifically, Nutanix documents a **Cost Governance API** for programmatic retrieval of data from the Cost Governance platform. [portal.nutanix](https://portal.nutanix.com/page/documents/details?targetId=Nutanix-Beam-User-Guide:bea-beam-api-nx-r.html)

## Practical interpretation

- If you want **cloud-hosted billing/usage** data, Nutanix appears to expose billing and usage information through the Xi Cloud Services / Cloud Hosted documentation, and possibly through Cost Governance APIs depending on the product tier. [portal.nutanix](https://portal.nutanix.com/page/documents/details?targetId=Xi-Cloud-Services-Administration-Guide:adm-display-billing-usage-details-calm.html)
- If you want **on-prem Prism billing**, that is not described as a generic billing API in the main Prism API reference; the standard APIs are focused on infrastructure and management operations rather than invoicing. [nutanixbible](https://www.nutanixbible.com/19a-rest-apis.html)
- For **usage/cost reporting**, Cost Governance is the strongest match in the docs you linked. [next.nutanix](https://next.nutanix.com/cost-governance-173/consumption-billing-and-reports-44339)

## Best next step

If your goal is to pull:
- invoices,
- payment details,
- or resource usage charges,

the most relevant place to look is the Xi Cloud Services billing docs and Cost Governance API docs rather than the general Prism APIs. [portal.nutanix](https://portal.nutanix.com/page/documents/details?targetId=Xi-Cloud-Services-Administration-Guide:adm-billing-management-xi-c.html)

Would you like me to extract the specific billing endpoints or summarize what fields the billing API returns?
