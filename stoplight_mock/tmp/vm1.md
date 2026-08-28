<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# yes

Done — I produced a second package tuned specifically toward `nutanix_virtual_machine_v2`, based on inspection of the current Nutanix Terraform provider source and examples.  The provider repo confirms that v2.x uses Prism Central as the endpoint, and that v4-backed resources are exposed with the `*_v2` suffix, including `nutanix_virtual_machine_v2`.[^1][^2]

## What changed

This version narrows the emulator to the VM v2 workflow and adds a stateful shim for VM CRUD plus task polling, while still forwarding unmatched routes to Prism.  I also made the shim accept both `/api/vmm/v4.0/...` and `/api/vmm/v4.0.a1/...` path variants because Nutanix v4 references are versioned by namespace/version and provider integrations often drift between doc versions and generated client paths.[^2][^3]

## Provider alignment

The provider source exposes a VMM `VmApi` client and a Prism `TasksApi`, which is exactly why the emulator now focuses on VM endpoints plus task endpoints rather than only raw OpenAPI mocking.  The provider repository also ships many `virtual_machine_v2` examples, which is a strong sign that the right strategy is to emulate just enough of the VM lifecycle and task semantics to satisfy plan/apply/refresh loops.[^2]

## What is in the package

The archive contains:

- `docker-compose.yml` for Prism plus the stateful Node service.[^2]
- `mock/server.js` with VM CRUD, lookup helpers for cluster/subnet/image, and task polling endpoints.[^2]
- `terraform/` with a focused `nutanix_virtual_machine_v2` example.[^2]
- `notes/findings.txt` containing grep-based inspection notes from the current provider source so you can keep tightening the shim against real provider behavior.[^2]


## What to expect next

This should get you closer than the generic emulator, but you will still likely need one or two iterations after reading `TF_LOG=DEBUG` output, especially for exact task envelopes, list/filter reads, and any update semantics the provider expects from the generated Nutanix SDK client.  The Nutanix provider also documents specific supported Prism Central and AOS versions for v2.x, which reinforces that real behavior is tightly coupled to the platform version, not just the OpenAPI contract.[^1][^2]

## Run order

Place your Nutanix VMM v4 OpenAPI JSON in `spec/openapi.json`, start the stack with Docker Compose, then run Terraform from the included `terraform/` folder against `127.0.0.1:9440`.  If the first apply fails, inspect `terraform-debug.log` and update `mock/server.js` to match the exact endpoint or response the provider requested.[^2]

Would you like me to go one step further and generate a third package that includes a request recorder plus automatic log-based route stubs so each failed Terraform run teaches the emulator new endpoints?
<span style="display:none">[^10][^11][^12][^13][^14][^15][^16][^17][^4][^5][^6][^7][^8][^9]</span>

<div align="center">⁂</div>

[^1]: https://github.com/nutanix/terraform-provider-nutanix

[^2]: https://www.nutanix.dev/api-versions/

[^3]: https://www.nutanix.dev/api-reference-v4/

[^4]: https://github.com/nutanix/terraform-provider-nutanix/releases

[^5]: https://github.com/nutanix/terraform-provider-nutanix/issues/1108

[^6]: https://github.com/nutanix/terraform-provider-nutanix/issues/69

[^7]: https://github.com/Aristocrat-B2B/terraform-nutanix-virtualmachine

[^8]: https://www.reddit.com/r/nutanix/comments/v97w5d/terraform_nutanix/

[^9]: https://www.nutanix.com/partners/technology-alliances/hashicorp

[^10]: https://github.com/nutanixdev/terraform_blog

[^11]: https://github.com/nutanix/terraform-provider-nutanix/issues/857

[^12]: https://registry.terraform.io/providers/nutanix/nutanix/latest/docs/resources/virtual_machine_v2

[^13]: https://github.com/nutanix/terraform-provider-nutanix/issues/1060

[^14]: https://github.com/nutanix/terraform-provider-nutanix/issues/750

[^15]: https://search.opentofu.org/provider/nutanix/nutanix/v2.4.0

[^16]: https://github.com/nutanix/terraform-provider-nutanix/blob/master/CHANGELOG.md

[^17]: https://github.com/nutanix/terraform-provider-nutanix/issues

