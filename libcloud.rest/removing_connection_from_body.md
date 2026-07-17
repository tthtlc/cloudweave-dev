
This is about **where your API gets tenant/provider context from**, and how that choice affects authorization design and API consistency.

Right now you have an inconsistency:

- POST/PATCH → read `connection` from JSON body (`body.connection`)
- GET/DELETE → read `connection` from:
  - `X-Provider-Connection` header, or
  - `?connection=` query param

So the same logical concept (provider/tenant selection) is coming from **different places depending on HTTP method**.

***

### What the proposal is suggesting

Unify everything so that:

- ALL endpoints (GET, POST, PATCH, DELETE)
- read `connection` from:
  - header (`X-Provider-Connection`), or
  - query param

and **remove it from request bodies entirely**

***

### Why this matters (architecturally)

This is really about **separating concerns cleanly**.

Right now:
- Route handlers must:
  - parse request body
  - extract `connection`
  - do authorization logic

If you standardize on header/query:

- You can move auth into a **shared dependency/middleware layer**
- Handlers no longer care about *where* connection comes from

Example (conceptual):

Current pattern (coupled):
- handler parses body
- handler extracts `connection`
- handler does auth

Proposed pattern (decoupled):
- middleware extracts `connection` from header
- middleware validates + authorizes
- handler receives already-authorized context

***

### Why header/query is preferred

This aligns with common API design principles:

- Headers/query = **request context / routing / tenancy**
- Body = **resource payload**

`connection` is not really part of the resource itself — it's **which provider/tenant you're operating against**

So putting it in the body is semantically off.

***

### Benefits of the change

- Consistency across all endpoints
- Cleaner handler code (no repeated extraction logic)
- Centralized authz (easier to audit and harden)
- Easier to plug into middleware frameworks (FastAPI dependencies, Express middleware, etc.)
- Less risk of bugs where:
  - GET uses one connection source
  - POST uses another

***

### The downside (important)

This is a **breaking API change**:

- Existing clients sending:
  - `{ "connection": "foo", ... }`
- Will stop working

They must switch to:
- Header: `X-Provider-Connection: foo`
  or
- Query: `?connection=foo`

***

### Practical migration strategies

Instead of a hard break, you could:

- Temporarily support both:
  - Prefer header/query
  - Fallback to body (with deprecation warning)
- Emit warnings/logs when body is used
- Remove body support in next major version

***

### Concrete example

Current POST:
- POST /instances  
- Body:
  - `{ "connection": "aws-prod", "name": "vm1" }`

Proposed:
- POST /instances  
- Header:
  - `X-Provider-Connection: aws-prod`
- Body:
  - `{ "name": "vm1" }`

***

### What the question is really asking

“Which path do you want?” means:

Option A (status quo):
- Keep mixed sources (body vs header)
- No breaking change
- Messier auth logic

Option B (proposed):
- Standardize on header/query
- Break clients
- Cleaner architecture + centralized auth

***

### My take (given your background)

For a system that cares about:
- security boundaries
- clean abstractions
- multi-provider isolation

Option B is the correct long-term move.

But I would not do it as a hard cut unless:
- API versioning already exists

Otherwise:
- introduce a **v2 API contract**
- or do a staged deprecation with telemetry

***

If you want, I can sketch a concrete FastAPI / Go middleware pattern for this that cleanly injects provider context into handlers.
