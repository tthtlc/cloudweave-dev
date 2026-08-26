
OpenFGA exposes a core set of HTTP APIs for clients like the SDKs, plus a few additional/experimental surfaces. The main client-facing APIs are Stores, Authorization Models, Relationship Tuples, Relationship Queries, Assertions, and the experimental AuthZEN service. [openfga](https://openfga.dev/api/service)

## Main query and data APIs

These are the APIs you’ll use most often from the FGA client or directly over HTTP:

- **Check**: answer whether a user has a specific relation on an object, via `POST /stores/{store_id}/check`. [openfga](https://openfga.dev/docs/interacting/relationship-queries)
- **Batch Check**: run many check operations in one request, via `POST /stores/{store_id}/batch-check`. [github](https://github.com/openfga/python-sdk/blob/main/docs/OpenFgaApi.md)
- **Read**: read stored relationship tuples matching a filter, via `POST /stores/{store_id}/read`. [openfga](https://openfga.dev/docs/interacting/relationship-queries)
- **Expand**: expand the userset tree for a given object/relation, via `POST /stores/{store_id}/expand`. [github](https://github.com/openfga/python-sdk/blob/main/docs/OpenFgaApi.md)
- **List Objects**: list all objects of a given type that a user has a relation with, via `POST /stores/{store_id}/list-objects`. [github](https://github.com/openfga/java-sdk)
- **List Users**: list users matching a filter for a type/relation, via `POST /stores/{store_id}/list-users`. [github](https://github.com/openfga/python-sdk/blob/main/docs/OpenFgaApi.md)

## Management APIs

These are the APIs for setting up and administering OpenFGA:

- **Create Store**: `POST /stores`. [github](https://github.com/openfga/python-sdk/blob/main/docs/OpenFgaApi.md)
- **List Stores**: `GET /stores`. [github](https://github.com/openfga/java-sdk)
- **Get Store**: `GET /stores/{store_id}`. [github](https://github.com/openfga/java-sdk)
- **Delete Store**: `DELETE /stores/{store_id}`. [github](https://github.com/openfga/python-sdk/blob/main/docs/OpenFgaApi.md)
- **Write Authorization Model**: create a new model version for a store. [openfga](https://openfga.dev/api/service)
- **Read Authorization Models**: list/read model versions for a store. [github](https://github.com/openfga/java-sdk)
- **Read Authorization Model**: get a specific authorization model by ID. [openfga](https://openfga.dev/api/service)
- **Write Assertions**: upsert assertions for an authorization model. [github](https://github.com/openfga/python-sdk/blob/main/docs/OpenFgaApi.md)
- **Read Assertions**: read assertions for an authorization model. [github](https://github.com/openfga/python-sdk/blob/main/docs/OpenFgaApi.md)

## Protocols and client access

Clients connect through the OpenFGA API using the SDKs or raw HTTP, and OpenFGA documents SDKs for Go, Java, .NET, Python, and JavaScript, plus CLI and curl examples. The service API explorer also shows an `AuthZenService`, which is an experimental interoperability surface. [openfga](https://openfga.dev/docs/fga)

## Practical grouping

If you want the shortest useful breakdown, think of OpenFGA as:

1. **Store/model admin**: create/list/get/delete stores, write/read models, write/read assertions. [openfga](https://openfga.dev/api/service)
2. **Tuple data access**: write tuples and read tuples. [openfga](https://openfga.dev/api/service)
3. **Permission queries**: check, batch-check, expand, list-objects, list-users. [openfga](https://openfga.dev/docs/interacting/relationship-queries)
4. **Interop/experimental**: AuthZEN. [openfga](https://openfga.dev/docs/interacting/authzen)
