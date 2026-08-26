
Nutanix Identity and Access Management (IAM) v4 is an enterprise authorization and authentication framework built into the Nutanix v4 API architecture. It introduces native API key support, granular role-based access control, and programmatic management for automated tools, scripts, and service accounts. [1, 2] 
## Core Capabilities

* API Key Authentication: Enables token-style authentication specifically for service accounts, replacing mandatory HTTP basic password usage in automated workflows. [1] 
* Granular Authorization Policies: Restricts access precisely to designated operational boundaries, such as permitting management of specific virtual machines while blocking network infrastructure modifications. [2] 
* Multi-Language SDK Support: Fully accessible via modern Python, Java, Go, and JavaScript SDK packages hosted on the [Nutanix Developer Portal](https://developers.nutanix.com/). [3] 

## Important Operational Constraints

* Programmatic Only: Service accounts and API keys cannot be created, modified, or mapped to policies via the Prism Central user interface; they require v4 APIs or SDKs. [3] 
* Service Account Restriction: API keys attach exclusively to service accounts rather than standard human user accounts. [3] 
* Legacy Migration: Nutanix legacy APIs (v3 and older) are scheduled for deprecation starting in Q4 2026, making v4 the mandatory standard for production environments. [4] 

If you need specific guidance, let me know:

* Are you trying to generate an API key using a specific language (like Python or Go)?
* Do you need an example of an IAM authorization policy payload?


[1] [https://www.nutanix.dev](https://www.nutanix.dev/2025/02/05/nutanix-v4-apis-using-api-key-authentication/)
[2] [https://www.nutanixbible.com](https://www.nutanixbible.com/19a-rest-apis.html)
[3] [https://www.nutanix.dev](https://www.nutanix.dev/2025/02/21/nutanix-v4-apis-using-api-key-authentication-part-2/)
[4] https://developers.nutanix.com

