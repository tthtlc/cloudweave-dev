Yes — OpenFGA can model this kind of hierarchical privilege system, including “a higher user can grant or revoke a lower user’s privileges,” as long as you model both the **roles** and the **permission to manage roles** explicitly. [openfga](https://openfga.dev/docs/best-practices/modeling-roles)

The key idea is that OpenFGA is not just flat RBAC; it supports object-scoped roles, parent-child inheritance, and delegated administration patterns, which makes it suitable for a team or tenant hierarchy with different users managing different privilege sets. [perplexity](https://www.perplexity.ai/search/32c7e10e-3094-4e2d-9d3f-2b0a58bd0642)

## How to think about it

For your case, define an object such as `tenant:acme`, then define relations like `owner`, `admin`, `operator`, `auditor`, and `viewer`, plus management relations such as `can_assign_admin`, `can_assign_operator`, and `can_assign_viewer`. OpenFGA modeling guidance shows that permissions are typically derived from relations, and parent-child relationships can propagate those permissions down to resources. [openfga](https://openfga.dev/docs/modeling)

A common pattern is:
- `owner` can assign or revoke all lower roles.
- `admin` can assign `operator`, `auditor`, and `viewer`, but not `owner`.
- `operator` can perform actions on resources but cannot change role assignments.
- `auditor` can read logs/history only.
- `viewer` can only read basic data. [openfga](https://openfga.dev/docs/modeling/roles-and-permissions)

## Example with 10 people

Assume one organization `tenant:cloudweave` and 10 users:

| Person | OpenFGA user | Role on `tenant:cloudweave` | Can manage |
|---|---|---|---|
| Alice | `user:alice` | owner | All lower roles. [openfga](https://openfga.dev/docs/best-practices/modeling-roles) |
| Bob | `user:bob` | admin | operator, auditor, viewer. [openfga](https://openfga.dev/docs/best-practices/modeling-roles) |
| Carol | `user:carol` | admin | operator, auditor, viewer. [openfga](https://openfga.dev/docs/best-practices/modeling-roles) |
| Dave | `user:dave` | operator | No role management. [openfga](https://openfga.dev/docs/modeling/roles-and-permissions) |
| Eve | `user:eve` | operator | No role management. [openfga](https://openfga.dev/docs/modeling/roles-and-permissions) |
| Frank | `user:frank` | auditor | No role management; logs/read only. [perplexity](https://www.perplexity.ai/search/32c7e10e-3094-4e2d-9d3f-2b0a58bd0642) |
| Grace | `user:grace` | viewer | No role management. [openfga](https://openfga.dev/docs/modeling/roles-and-permissions) |
| Heidi | `user:heidi` | viewer | No role management. [openfga](https://openfga.dev/docs/modeling/roles-and-permissions) |
| Ivan | `user:ivan` | viewer | No role management. [openfga](https://openfga.dev/docs/modeling/roles-and-permissions) |
| Judy | `user:judy` | viewer | No role management. [openfga](https://openfga.dev/docs/modeling/roles-and-permissions) |

Example business rules:
- Alice can promote Grace from viewer to operator. [openfga](https://openfga.dev/docs/best-practices/modeling-roles)
- Bob can grant Judy viewer or operator, but cannot make Judy an owner. [openfga](https://openfga.dev/docs/modeling/roles-and-permissions)
- Dave can provision VMs if operators are allowed to do so, but Dave cannot modify Bob’s or Carol’s role. [perplexity](https://www.perplexity.ai/search/32c7e10e-3094-4e2d-9d3f-2b0a58bd0642)

## Example model

A simplified OpenFGA-style model could look like this:

```fga
model
  schema 1.1

type user

type tenant
  relations
    define owner: [user]
    define admin: [user]
    define operator: [user]
    define auditor: [user]
    define viewer: [user]

    define can_assign_owner: owner
    define can_assign_admin: owner
    define can_assign_operator: owner or admin
    define can_assign_auditor: owner or admin
    define can_assign_viewer: owner or admin

    define can_view: viewer or auditor or operator or admin or owner
    define can_audit: auditor or admin or owner
    define can_operate: operator or admin or owner
    define can_administer: admin or owner
```

This follows OpenFGA’s roles-and-permissions style, where relations represent assignments and other relations derive effective permissions from them. [openfga](https://openfga.dev/docs/best-practices/modeling-roles)

## Example tuples

Example tuples for the 10 users:

```text
user:alice   owner    tenant:cloudweave
user:bob     admin    tenant:cloudweave
user:carol   admin    tenant:cloudweave
user:dave    operator tenant:cloudweave
user:eve     operator tenant:cloudweave
user:frank   auditor  tenant:cloudweave
user:grace   viewer   tenant:cloudweave
user:heidi   viewer   tenant:cloudweave
user:ivan    viewer   tenant:cloudweave
user:judy    viewer   tenant:cloudweave
```

Then your application enforces changes like this:
- Before Bob assigns `operator` to Heidi, check whether `user:bob` has `can_assign_operator` on `tenant:cloudweave`. [openfga](https://openfga.dev/docs/modeling/roles-and-permissions)
- Before Carol revokes Judy’s viewer role, check whether `user:carol` has `can_assign_viewer` on `tenant:cloudweave`. [openfga](https://openfga.dev/docs/best-practices/modeling-roles)
- Before Bob tries to assign `admin` to Dave, deny it because only `owner` has `can_assign_admin` in this model. [openfga](https://openfga.dev/docs/modeling/roles-and-permissions)

## Example checks

Some example authorization decisions:

- `Check(user:alice, can_assign_admin, tenant:cloudweave)` → true, because Alice is `owner`. [openfga](https://openfga.dev/docs/modeling/roles-and-permissions)
- `Check(user:bob, can_assign_operator, tenant:cloudweave)` → true, because Bob is `admin`. [openfga](https://openfga.dev/docs/modeling/roles-and-permissions)
- `Check(user:bob, can_assign_admin, tenant:cloudweave)` → false, because only `owner` can do that in this design. [openfga](https://openfga.dev/docs/best-practices/modeling-roles)
- `Check(user:dave, can_operate, tenant:cloudweave)` → true, because Dave is `operator`. [openfga](https://openfga.dev/docs/modeling/roles-and-permissions)
- `Check(user:frank, can_operate, tenant:cloudweave)` → false, because Frank is only `auditor`. [openfga](https://openfga.dev/docs/modeling/roles-and-permissions)

## Resource inheritance

If you later want this to apply to resources like `project`, `vm`, `network`, or `cluster`, OpenFGA supports parent-child modeling so that tenant-level or project-level permissions can flow down to child resources. That is especially useful in a CMP, where an admin of a project might automatically get admin rights on its VMs and networks without storing separate tuples for every object. [perplexity](https://www.perplexity.ai/search/7be5a413-7556-4f00-a1b3-252537af0d8d)

For example:
- `tenant:cloudweave`
  - `project:prod`
    - `vm:web-01`
    - `network:vpc-01`

Then `operator` on `project:prod` can be inherited to `vm:web-01` for `start`, `stop`, or `rebuild` actions if your model defines that chain. [openfga](https://openfga.dev/docs/modeling/parent-child)

## Important limitation

OpenFGA answers **who is allowed** to do something, but your application still performs the actual mutation of tuples. In other words, OpenFGA can say “Bob is allowed to assign operator,” but your backend must: [perplexity](https://www.perplexity.ai/search/f4bf6b64-0606-423b-824f-c28b661ff7f4)
1. check `can_assign_operator`,
2. validate business rules,
3. write or delete the role tuple. [openfga](https://openfga.dev/docs/modeling)

So yes, this is absolutely implementable with OpenFGA, and it is a strong fit for hierarchical delegated privileges in a 5-user or 10-user organization model. [perplexity](https://www.perplexity.ai/search/32c7e10e-3094-4e2d-9d3f-2b0a58bd0642)
