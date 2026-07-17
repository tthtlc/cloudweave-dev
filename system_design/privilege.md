
Yes — for multiple tenants in OpenFGA, you typically model each tenant as its own object such as `organization`, `tenant`, or `account`, and then attach users, groups, roles, and resources to that tenant boundary so authorization is isolated per tenant. [openfga](https://openfga.dev/docs/modeling/organization-context-authorization)

And yes, in a CMP-like system, a higher-level platform role such as `superadmin` is usually the clean way to bootstrap or manage tenant ownership across tenants, because ordinary tenant owners should generally be powerful only inside their own tenant, not globally across all tenants. [perplexity](https://www.perplexity.ai/search/c2b3b452-e632-41b4-8029-0a4a006e7fdd)

## Tenant structure

A typical pattern is:
- `user`
- `tenant` or `organization`
- tenant-scoped resources like `project`, `vm`, `network`, `secret`
- tenant-scoped relations like `owner`, `admin`, `operator`, `viewer`. [github](https://github.com/openfga/sample-stores/tree/main/stores/multitenant-rbac)

That means `user:bob` may be `owner` of `tenant:acme` but just `viewer` in `tenant:beta`, and OpenFGA will evaluate those separately because the relation is attached to different tenant objects. [community.auth0](https://community.auth0.com/t/streamline-your-authorization-workflow-with-auth0-fga/112289)

## Superadmin

Yes, a `superadmin` or `platform_admin` role usually makes sense, but it should live at a higher scope than any tenant, such as a `platform:controlplane` object. That role is useful for: [perplexity](https://www.perplexity.ai/search/7be5a413-7556-4f00-a1b3-252537af0d8d)
- creating a new tenant,
- assigning the first tenant owner,
- replacing an owner in emergency cases,
- handling break-glass administration and support. [perplexity](https://www.perplexity.ai/search/7be5a413-7556-4f00-a1b3-252537af0d8d)

A simple model shape is:

```fga
type user

type platform
  relations
    define superadmin: [user]
    define can_create_tenant: superadmin
    define can_assign_tenant_owner: superadmin

type tenant
  relations
    define owner: [user]
    define admin: [user]
    define operator: [user]
    define viewer: [user]

    define can_assign_owner: owner
    define can_assign_admin: owner
    define can_assign_operator: owner or admin
    define can_assign_viewer: owner or admin
```

In practice, your application would check `can_assign_tenant_owner` on `platform:main` before writing `user:alice owner tenant:acme` for the first time. [openfga](https://openfga.dev/docs/modeling)

## One owner or many

It is **not** generally recommended to have exactly one owner per tenant as a hard rule; it is usually better to have at least two trusted owners for resilience, or one owner plus a break-glass platform admin path, so you do not create an operational lockout if one owner leaves, is disabled, or loses access. [perplexity](https://www.perplexity.ai/search/c2b3b452-e632-41b4-8029-0a4a006e7fdd)

A better guideline is:
- minimum one owner required,
- preferred two owners for business continuity,
- very small tenants may start with one owner,
- platform `superadmin` remains outside the tenant as recovery authority. [github](https://github.com/openfga/sample-stores/tree/main/stores/multitenant-rbac)

So the answer is:
- **Required**: at least one owner per tenant.
- **Recommended**: one or two owners depending on governance needs, with strong audit on ownership changes.
- **Avoid**: zero owners, because tenant administration becomes stranded. [perplexity](https://www.perplexity.ai/search/336b557e-f977-4307-a531-0f7562fdb41f)

## Recommended model

For your CMP, I would recommend this hierarchy:
- `platform:main`
  - `superadmin`
- `tenant:acme`
  - `owner`
  - `admin`
  - `operator`
  - `auditor`
  - `viewer`
- child resources under each tenant inherit or reference tenant membership as needed. [perplexity](https://www.perplexity.ai/search/32c7e10e-3094-4e2d-9d3f-2b0a58bd0642)

Example:
- `user:rootops` is `superadmin` on `platform:main`.
- `user:alice` and `user:bob` are `owner` on `tenant:acme`.
- `user:carol` is `owner` on `tenant:beta`.
- Alice cannot assign owners in `tenant:beta` unless she also has rights there.
- `rootops` can bootstrap or recover both tenants. [openfga](https://openfga.dev/docs/modeling/organization-context-authorization)

## Practical advice

For safety and clarity:
- Keep `superadmin` very small in number and highly audited. [perplexity](https://www.perplexity.ai/search/7be5a413-7556-4f00-a1b3-252537af0d8d)
- Keep tenant ownership tenant-local; owners should not automatically have rights in other tenants. [perplexity](https://www.perplexity.ai/search/336b557e-f977-4307-a531-0f7562fdb41f)
- Store tenant membership and role changes as auditable events in your app DB in addition to OpenFGA tuple writes. [perplexity](https://www.perplexity.ai/search/c2b3b452-e632-41b4-8029-0a4a006e7fdd)
- Do not use OpenFGA as identity or secret storage; keep identity in IdP and secrets in Vault or equivalent. [perplexity](https://www.perplexity.ai/search/b9091615-8da9-4a2a-946b-b5b3db0c4623)

So yes: different tenants are straightforward in OpenFGA, a global `superadmin` role is a good idea for bootstrap/recovery, and the strongest practical recommendation is **at least one owner per tenant, preferably two for resilience rather than exactly one**. [openfga](https://openfga.dev/docs/modeling/organization-context-authorization)
