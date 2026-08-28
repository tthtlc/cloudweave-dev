<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# using openapi.json specification from Nutanix, is it possible to use any emulator like StopLight to emulate the Nutanix resources using the openapi.json files, for example ECS virtual machine v2 resources, and then changes the attributes of these VM using terror?

Yes, you can use the Nutanix OpenAPI JSON with a mock/emulator like Stoplight Prism to stand up a fake Nutanix API for ECS VM v2 (or v3/v4) resources, and then point Terraform at that mock endpoint—but there are some important caveats around behavior, auth, and state.[^1][^2][^3]

## What tools can do

- Nutanix v3/v4 APIs are described with OpenAPI and are used for VM lifecycle management and other resources.[^4][^5][^3]
- Stoplight Studio/Prism can take any OpenAPI 2/3 document and run it as a mock HTTP server with request/response validation.[^2][^1]
- Prism specifically is designed to “turn any OpenAPI2/3 file into an API server with mocking, transformations and validations.”[^2]

So if you have Nutanix’ official OpenAPI JSON for the VM/ECS resources, you can:

1. Run `prism mock nutanix-openapi.json` to spin up a local HTTP server.[^2]
2. Call the Nutanix paths (e.g. `/api/nutanix/v3/vms` or whatever ECS VM v2 exposes) against Prism instead of a real Prism Central / ECS endpoint.[^6][^2]

This will give you “shape-correct” responses (types, fields, etc.), which is often enough to iterate on Terraform provider logic, API client code, or integration flows.

## What this buys you vs a real cluster

### Pros

- **Contract testing and schema validation**: Terraform plans and applies will exercise your code against the exact request/response schema, catching breaking changes or incorrect field usage early.[^7][^2]
- **Offline / no cluster**: You can iterate without touching real Nutanix or ECS infrastructure, useful for CI or local experimentation.[^2]
- **Deterministic test data**: You can fix the mock responses for specific calls (e.g. GET VM returns a known JSON) and write stable tests around that.[^2]


### Limitations

- **No real Nutanix semantics**: Prism/Prism Central behavior like async tasks, cluster validations, UUID relationships between VMs, images, subnets, etc., will not be enforced unless you explicitly model them in the mock layer.[^6][^2]
- **Authentication / authorization**: Prism uses auth (Basic, tokens, etc.) that the mock might skip or trivially accept unless you add custom logic.[^6][^2]
- **Statefulness**: Out-of-the-box mocks usually respond with generated or static examples; they do not maintain “create VM then later GET the same VM with modified attributes” unless you wire state in.[^2]

So: it is “possible” to emulate, but unless you invest in making the mock stateful and somewhat behaviorally accurate, it will only validate contracts, not true Nutanix workflows.

## Terraform against a mocked Nutanix API

From Terraform’s perspective, it only cares that:

- The provider talks HTTP/HTTPS with JSON bodies.
- Endpoints respond with the schemas the provider expects (for read/create/update/delete).

If you have a Terraform provider (or your own custom provider) for Nutanix/ECS that uses those OpenAPI-described endpoints, you can:

1. Configure the provider’s base URL to point at Prism’s mock server (e.g. `http://127.0.0.1:4010`) instead of the real Prism/ECS URL.[^2]
2. Run `terraform plan` and `terraform apply`.
3. Observe how the provider behaves given the mock responses (including how diffs are calculated when attributes change).

This is a standard pattern used with OpenAPI-driven APIs: use Prism or similar to do contract testing for clients and IaC tooling.[^2]

To make attribute changes behave as expected (e.g. change VM RAM, see updated value on next refresh):

- Either pre-script Prism responses for specific request payloads and URLs.[^2]
- Or wrap Prism behind a small stateful shim that stores VM specs in memory or a file and returns them on GET.[^2]

Without that, Terraform may see every refresh as “drift” or might always think resources need recreation.

## Specific to “ECS virtual machine v2 resources”

You mentioned “ECS virtual machine v2”. Nutanix has multiple API versions (v2, v3, v4) and the newer v4 APIs are explicitly OpenAPI-based.  If your OpenAPI JSON is:[^3][^8][^4]

- **Generated from v3/v4 Nutanix dev portal**: This is the intended use case; Prism/Stoplight will work fine as a mock.[^8][^4][^3]
- **A community swagger for v2 ECS VM** (like some of the older swagger JSONs in public repos): you may need to fix minor spec issues (invalid attributes, typos) before Prism will validate and mock correctly.[^9][^7]

The Pulumi Nutanix provider’s `getVirtualMachineV2` and related docs show the rough shapes of v2 VM resources, so you can cross-check schemas when debugging mismatches between the spec and tools like Terraform.[^10]

## Practical workflow sketch

One possible workflow:

1. Obtain Nutanix/ECS OpenAPI JSON for the VM endpoints you care about (e.g. `/vms` create/read/update).[^4][^3]
2. Clean/patch the spec if needed so it passes OpenAPI validation (similar to what Nutanix’s prism-go-client does when consuming the spec).[^7]
3. Run `prism mock nutanix-ecs-vm-openapi.json`.[^2]
4. Configure your Terraform Nutanix/ECS provider with:
    - Endpoint = Prism mock base URL.
    - Dummy credentials accepted by the mock.
5. Create a Terraform config defining an ECS VM resource with attributes matching the spec.
6. Run `terraform apply` to create the mock VM, then modify attributes (e.g. CPU, RAM) and apply again to see how diffs are handled.

If you need more realistic behavior, add stateful logic (in Node/Go/Python) that sits between Terraform and Prism, or write custom Prism rules/hooks to persist resource representations.

Would you like an example Terraform provider configuration and the minimal Prism setup commands for a Nutanix VM spec so you can wire this up quickly on your side?
<span style="display:none">[^11][^12][^13][^14][^15]</span>

<div align="center">⁂</div>

[^1]: https://github.com/stoplightio/studio

[^2]: https://github.com/stoplightio/prism

[^3]: https://www.nutanix.com/tech-center/blog/nutanix-v4-apis-and-sdks-expanded-for-nutanix-cloud-platform

[^4]: https://www.nutanix.dev/api-versions/

[^5]: https://www.nutanixbible.com/19a-rest-apis.html

[^6]: https://www.reddit.com/r/nutanix/comments/8rg21v/nutanix_api/

[^7]: https://github.com/nutanix-cloud-native/prism-go-client/pull/183/files

[^8]: https://www.nutanix.dev/2025/06/29/deploying-vms-from-templates-using-nutanix-v4-python-sdk-and-rest-apis/

[^9]: https://github.com/nutanix/Automation/blob/master/experimental/swagger-redoc-sandbox/v.8-1.2-jsons/swagger-v0.8-vms.json

[^10]: https://www.pulumi.com/registry/packages/nutanix/api-docs/getvirtualmachinev2/

[^11]: https://next.nutanix.com/ahv-virtualization-27/need-api-response-to-work-on-my-script-changes-using-v3-apis-to-v4-apis-45058

[^12]: https://github.com/nutanixdev/code-samples/blob/master/postman/Nutanix REST API Testing.postman_collection.json

[^13]: https://blog.ntnx.jp/entry/2018/11/11/191703

[^14]: https://docs.microfocus.com/doc/205/saas/nutanixdscvry

[^15]: https://aiegoo.github.io/apidoc/pubapis_stoplight_demo.html

