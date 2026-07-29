what are the difference between the fga and openfga binaries.                                                                                                                                              
 
 ● Let me quickly check what's in this repo and the CLI repo to ground the answer.                                                                                                                             
 
 ● Used Read (cmd/openfga/main.go) · 31 lines                                                                                                                                                                  
 
 ● Used FetchURL (https://github.com/openfga/cli) · 32.3 KB                                                                                                                                                    
 
 ● Now I have solid grounding. The `openfga` binary is built from this repo (openfga/openfga), cmd/openfga/main.go shows commands: run, migrate, validate-models, version. The `fga` binary is from the        
   separate openfga/cli repo — a client CLI to interact with a running OpenFGA server.                                                                                                                         
   ... (2 more lines, ctrl+o to expand)
 
 ● They're two different tools from two different repos — one is the server, the other is a client:                                                                                                            
                                                                                                                                                                                                               
   openfga — the server binary (built from this repo, cmd/openfga/main.go)                                                                                                                                     
                                                                                                                                                                                                               
   This is the actual authorization engine. It's a long-running service that exposes the OpenFGA HTTP/gRPC APIs. Its subcommands are operational:                                                              
                                                                                                                                                                                                               
   • run — start the server (with a datastore, authn, etc.)                                                                                                                                                    
   • migrate — run datastore schema migrations                                                                                                                                                                 
   • validate-models — validate authorization model files                                                                                                                                                      
   • version                                                                                                                                                                                                   
                                                                                                                                                                                                               
   fga — the CLI client (from the separate openfga/cli (https://github.com/openfga/cli) repo)                                                                                                                  
                                                                                                                                                                                                               
   This is a command-line client that talks to a running OpenFGA server over its API. It's for day-to-day interaction:                                                                                         
                                                                                                                                                                                                               
   • fga store ... — create/list/import/export stores                                                                                                                                                          
   • fga model write/validate/test/transform — manage and test authorization models                                                                                                                            
   • fga tuple write/read/delete/changes — manage relationship tuples                                                                                                                                          
   • fga query check/list-objects/list-users/expand — run authorization queries                                                                                                                                
                                                                                                                                                                                                               
   It configures the target server via --api-url / FGA_API_URL, auth tokens, store id, etc.                                                                                                                    
                                                                                                                                                                                                               
   In short: openfga run starts the authorization service; fga is the CLI you use against that service (or against hosted Auth0 FGA). One exception to the server/client split: fga model test can run entirely
   locally using a built-in in-memory OpenFGA instance, so you don't need a server for that.                                                                                                                   
                                                                                                                                                                                                               
   Typical workflow: openfga run in one terminal (or Docker), then fga store create, fga model write, fga query check ... against it.                                                                          
 
 ✨ elaborate on all the available features and services implemented in the openfga and fga - presenting in a table will be ideal                                                                              
 
 ● The user wants an elaboration of all available features and services in the `openfga` server binary and the `fga` CLI, ideally in a table. Let me gather accurate information.                              
                                                                                                                                                                                                               
   ... (38 more lines, ctrl+o to expand)
 
 ● I'll ground the server-side feature list in this repo's actual config and run command before writing it up.                                                                                                 
 
 ● Ran a command                                                                                                                                                                                               
   $ grep -o 'flags\.[A-Za-z]*("[a-z-]*"' cmd/run/run.go | sort -u | head -100                                                                                                                                 
   flags.Bool("access-control-enabled"                                                                                                                                                                         
   flags.Bool("cache-controller-enabled"                                                                                                                                                                       
   flags.Bool("check-dispatch-throttling-enabled"                                                                                                                                                              
   ... (79 more lines, ctrl+o to expand)
 
 ● Ran a command                                                                                                                                                                                               
   $ grep -n '"[a-z-]*":' .config-schema.json | grep -i -A0 'properties' | head -5; python3 -c "                                                                                                               
     import json                                                                                                                                                                                               
     with open('.config-schema.json') as f:                                                                                                                                                                    
         schema = json.load(f)                                                                                                                                                                                 
     props = schema.get('properties', {})                                                                                                                                                                      
     for k in sorted(props):                                                                                                                                                                                   
         desc = props[k].get('description','')                                                                                                                                                                 
         print(f'{k}: {desc[:120]}')" 2>/dev/null | head -80                                                                                                                                                   
   4:    "properties": {                                                                                                                                                                                       
   --                                                                                                                                                                                                          
   158:            "properties": {                                                                                                                                                                             
   ... (51 more lines, ctrl+o to expand)
 
   Approved for session: Running: grep -o 'flags\.[A-Za-z]*("[a-z-]*"' cmd/run/run.g…                                                                                                                          
 
   Approved for session: Running: grep -n '"[a-z-]*":' .config-schema.json | grep -i…                                                                                                                          
 
 ● I have a good picture of the server's config. Let me also quickly confirm the API services (gRPC methods) — I know them from the API: Check, Expand, ListObjects, ListUsers, StreamedListObjects, Read,     
   Write, ReadChanges, ReadAuthorizationModels, ReadAuthorizationModel, WriteAuthorizationModel, WriteAssertions, ReadAssertions, CreateStore, DeleteStore, GetStore, ListStores, BatchCheck, plus AuthZEN     
   ... (1 more lines, ctrl+o to expand)
 
 ● Ran a command                                                                                                                                                                                               
   $ ls pkg/server/*.go | grep -v test | head -40; echo ---; ls docs/authzen docs/http 2>/dev/null                                                                                                             
   pkg/server/assertions.go                                                                                                                                                                                    
   pkg/server/authorization_models.go                                                                                                                                                                          
   pkg/server/authzen.go                                                                                                                                                                                       
   ... (20 more lines, ctrl+o to expand)
 
   Approved for session: Running: ls pkg/server/*.go | grep -v test | head -40; echo…                                                                                                                          
 
 ● I now have a solid, grounded picture. Let me compose the answer with tables covering:                                                                                                                       
                                                                                                                                                                                                               
   ... (58 more lines, ctrl+o to expand)
 
 ● Here's the full breakdown, grounded in this repo (cmd/run, .config-schema.json, pkg/server) and the openfga/cli (https://github.com/openfga/cli) repo.                                                      
                                                                                                                                                                                                               
   openfga — the server binary                                                                                                                                                                                 
                                                                                                                                                                                                               
   Top-level commands (cmd/openfga/main.go)                                                                                                                                                                    
                                                                                                                                                                                                               
   ┌─────────────────┬──────────────────────────────────────────────────────────────────────────────────────────┐                                                                                              
   │ Command         │ Purpose                                                                                  │                                                                                              
   ├─────────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤                                                                                              
   │ run             │ Start the OpenFGA server (gRPC + HTTP), with all configuration via flags/env/config file │                                                                                              
   ├─────────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤                                                                                              
   │ migrate         │ Run datastore schema migrations (Postgres/MySQL/SQLite)                                  │                                                                                              
   ├─────────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤                                                                                              
   │ validate-models │ Validate authorization model files offline (no server needed)                            │                                                                                              
   ├─────────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤                                                                                              
   │ version         │ Print version/commit info                                                                │                                                                                              
   └─────────────────┴──────────────────────────────────────────────────────────────────────────────────────────┘                                                                                              
                                                                                                                                                                                                               
   API services (pkg/server/)                                                                                                                                                                                  
                                                                                                                                                                                                               
   All exposed over gRPC, plus an HTTP/JSON gateway (--http-enabled, CORS and TLS configurable):                                                                                                               
                                                                                                                                                                                                               
   ┌──────────────────────┬───────────────────────────────────────────────────────────────────────────────────────────────────┐                                                                                
   │ Service group        │ Endpoints                                                                                         │                                                                                
   ├──────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────┤                                                                                
   │ Relationship queries │ Check, BatchCheck, Expand, ListObjects, StreamedListObjects, ListUsers                            │                                                                                
   ├──────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────┤                                                                                
   │ Tuples               │ Read, Write (writes + deletes in one transaction), ReadChanges (changelog/watch)                  │                                                                                
   ├──────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────┤                                                                                
   │ Authorization models │ WriteAuthorizationModel, ReadAuthorizationModel, ReadAuthorizationModels                          │                                                                                
   ├──────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────┤                                                                                
   │ Assertions           │ WriteAssertions, ReadAssertions                                                                   │                                                                                
   ├──────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────┤                                                                                
   │ Stores               │ CreateStore, GetStore, ListStores, DeleteStore                                                    │                                                                                
   ├──────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────┤                                                                                
   │ AuthZEN              │ Experimental AuthZEN (https://openid.net/wg/authzen/)-compliant authorization API (docs/authzen/) │                                                                                
   └──────────────────────┴───────────────────────────────────────────────────────────────────────────────────────────────────┘                                                                                
                                                                                                                                                                                                               
   Query engine features (internal/graph/, pkg/typesystem/)                                                                                                                                                    
                                                                                                                                                                                                               
   ┌─────────────────────────────┬───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐                                 
   │ Feature                     │ What it does                                                                                                                              │                                 
   ├─────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤                                 
   │ ReBAC graph resolution      │ Union, intersection, exclusion; direct relations, tuple-to-userset, computed usersets, recursive/wildcard (user:*) relations              │                                 
   ├─────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤                                 
   │ ABAC conditions             │ CEL-based conditions on tuples with request context; cost-capped evaluation (maxConditionEvaluationCost)                                  │                                 
   ├─────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤                                 
   │ Weighted graph optimization │ Picks cheapest query paths (pkg/typesystem/weighted_graph.go)                                                                             │                                 
   ├─────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤                                 
   │ Strategy planner            │ Thompson Sampling planner selects resolver strategies from observed latency (internal/planner/)                                           │                                 
   ├─────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤                                 
   │ Resolver chain              │ Composable: CachedCheckResolver → DispatchThrottlingCheckResolver → ShadowResolver/LocalChecker (circular, see internal/graph/builder.go) │                                 
   ├─────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤                                 
   │ Shadow mode                 │ Runs main + shadow checker side by side for A/B comparison of results/latency                                                             │                                 
   ├─────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤                                 
   │ ListObjects pipeline        │ Optimization algorithm for ListObjects latency (listObjectsPipelineEnabled)                                                               │                                 
   ├─────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤                                 
   │ Shared iterators            │ Dedupes concurrent identical datastore reads within a request                                                                             │                                 
   ├─────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤                                 
   │ Contextual tuples & context │ Per-request tuples and condition context                                                                                                  │                                 
   ├─────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤                                 
   │ Consistency preferences     │ Per-request MINIMIZE_LATENCY vs HIGHER_CONSISTENCY                                                                                        │                                 
   ├─────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤                                 
   │ Safety limits               │ Resolution depth/breadth limits, per-query concurrent-read caps, deadlines for ListObjects/ListUsers, max results                         │                                 
   └─────────────────────────────┴───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘                                 
                                                                                                                                                                                                               
   Caching & throttling                                                                                                                                                                                        
                                                                                                                                                                                                               
   ┌────────────────────────────┬───────────────────────────────────────────────────────────────────────────────┐                                                                                              
   │ Feature                    │ Config                                                                        │                                                                                              
   ├────────────────────────────┼───────────────────────────────────────────────────────────────────────────────┤                                                                                              
   │ Check query cache          │ check-query-cache-enabled, TTL                                                │                                                                                              
   ├────────────────────────────┼───────────────────────────────────────────────────────────────────────────────┤                                                                                              
   │ Check iterator cache       │ check-iterator-cache-enabled, TTL                                             │                                                                                              
   ├────────────────────────────┼───────────────────────────────────────────────────────────────────────────────┤                                                                                              
   │ ListObjects iterator cache │ list-objects-iterator-cache-enabled, TTL                                      │                                                                                              
   ├────────────────────────────┼───────────────────────────────────────────────────────────────────────────────┤                                                                                              
   │ Cache controller           │ Invalidates cached entries when tuples change (cache-controller-enabled, TTL) │                                                                                              
   ├────────────────────────────┼───────────────────────────────────────────────────────────────────────────────┤                                                                                              
   │ TTL jitter                 │ Randomizes expiry to prevent stampedes                                        │                                                                                              
   ├────────────────────────────┼───────────────────────────────────────────────────────────────────────────────┤                                                                                              
   │ Dispatch throttling        │ Limits dispatches for Check / ListObjects / ListUsers independently           │                                                                                              
   ├────────────────────────────┼───────────────────────────────────────────────────────────────────────────────┤                                                                                              
   │ Datastore throttling       │ Threshold + duration based throttling per API                                 │                                                                                              
   └────────────────────────────┴───────────────────────────────────────────────────────────────────────────────┘                                                                                              
                                                                                                                                                                                                               
   Datastore layer (pkg/storage/)                                                                                                                                                                              
                                                                                                                                                                                                               
   ┌──────────────────────────┬────────────────────────────────────────────────────────────────┐                                                                                                               
   │ Capability               │ Detail                                                         │                                                                                                               
   ├──────────────────────────┼────────────────────────────────────────────────────────────────┤                                                                                                               
   │ Backends                 │ memory, postgres, mysql, sqlite (--datastore-engine)           │                                                                                                               
   ├──────────────────────────┼────────────────────────────────────────────────────────────────┤                                                                                                               
   │ Connection pooling       │ Max/min open conns, max/min idle conns, conn max idle/lifetime │                                                                                                               
   ├──────────────────────────┼────────────────────────────────────────────────────────────────┤                                                                                                               
   │ Secondary (read replica) │ Separate URI/credentials for read scaling                      │                                                                                                               
   ├──────────────────────────┼────────────────────────────────────────────────────────────────┤                                                                                                               
   │ Type system cache        │ In-memory cache sized via datastore-max-typesystem-cache-size  │                                                                                                               
   ├──────────────────────────┼────────────────────────────────────────────────────────────────┤                                                                                                               
   │ Datastore metrics        │ Optional per-query metrics                                     │                                                                                                               
   ├──────────────────────────┼────────────────────────────────────────────────────────────────┤                                                                                                               
   │ Changelog horizon        │ changelog-horizon-offset for ReadChanges freshness             │                                                                                                               
   └──────────────────────────┴────────────────────────────────────────────────────────────────┘                                                                                                               
                                                                                                                                                                                                               
   AuthN / AuthZ                                                                                                                                                                                               
                                                                                                                                                                                                               
   ┌────────────────────────┬─────────────────────────────────────────────────────────────────────────────────────────────┐                                                                                    
   │ Feature                │ Detail                                                                                      │                                                                                    
   ├────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────┤                                                                                    
   │ none                   │ No authentication                                                                           │                                                                                    
   ├────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────┤                                                                                    
   │ preshared              │ Static API keys (--authn-preshared-keys)                                                    │                                                                                    
   ├────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────┤                                                                                    
   │ oidc                   │ OIDC JWT validation — issuer, audience, subject allowlist, issuer aliases, client-ID claims │                                                                                    
   ├────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────┤                                                                                    
   │ Access control (authz) │ Uses an FGA model itself to authorize API calls (--access-control-enabled + model/store ID) │                                                                                    
   └────────────────────────┴─────────────────────────────────────────────────────────────────────────────────────────────┘                                                                                    
                                                                                                                                                                                                               
   Observability & ops                                                                                                                                                                                         
                                                                                                                                                                                                               
   ┌───────────────┬──────────────────────────────────────────────────────────────────────────────────────────┐                                                                                                
   │ Feature       │ Detail                                                                                   │                                                                                                
   ├───────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤                                                                                                
   │ Metrics       │ Prometheus endpoint, RPC histograms, datastore query/dispatch count histogram buckets    │                                                                                                
   ├───────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤                                                                                                
   │ Tracing       │ OTLP export (TLS, sampler, service name, resource attributes)                            │                                                                                                
   ├───────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤                                                                                                
   │ Logging       │ Level, format (json/text), timestamp format                                              │                                                                                                
   ├───────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤                                                                                                
   │ Profiler      │ pprof endpoint (--profiler-enabled)                                                      │                                                                                                
   ├───────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤                                                                                                
   │ Health        │ gRPC/HTTP health checks                                                                  │                                                                                                
   ├───────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤                                                                                                
   │ Playground    │ Embedded web UI (--playground-enabled, separate port)                                    │                                                                                                
   ├───────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤                                                                                                
   │ Reliability   │ Request timeout, graceful shutdown timeout, gRPC max message size, TLS on both listeners │                                                                                                
   ├───────────────┼──────────────────────────────────────────────────────────────────────────────────────────┤                                                                                                
   │ Experimentals │ --experimentals feature-flag list for preview features                                   │                                                                                                
   └───────────────┴──────────────────────────────────────────────────────────────────────────────────────────┘                                                                                                
                                                                                                                                                                                                               
   ────────────────────────────────────────────────────────────────────────────────                                                                                                                            
                                                                                                                                                                                                               
   fga — the CLI client                                                                                                                                                                                        
                                                                                                                                                                                                               
   Configured via flags, FGA_* env vars, or ~/.fga.yaml (api-url, api-token or OAuth client credentials, store-id, model-id, custom headers).                                                                  
                                                                                                                                                                                                               
   ┌───────────────┬─────────────────────────────────────────────────────────┬────────────────────────────────────────────────────────────────────────────────────────────────────────┐                        
   │ Command group │ Subcommands                                             │ Notes                                                                                                  │                        
   ├───────────────┼─────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤                        
   │ fga store     │ create, list, get, delete, import, export               │ Import/export whole stores (model + tuples + tests) as YAML files                                      │                        
   ├───────────────┼─────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤                        
   │ fga model     │ write, list, get, validate, test, transform             │ Accepts DSL (.fga), JSON, or modular (fga.mod) formats                                                 │                        
   ├───────────────┼─────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤                        
   │ fga tuple     │ write, delete, read, changes                            │ Bulk import from CSV/JSON/JSONL/YAML, RPS ramping, parallel requests, on-duplicate/on-missing policies │                        
   ├───────────────┼─────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤                        
   │ fga query     │ check, list-objects, list-relations, expand, list-users │ Supports contextual tuples, condition context, consistency preference                                  │                        
   └───────────────┴─────────────────────────────────────────────────────────┴────────────────────────────────────────────────────────────────────────────────────────────────────────┘                        
                                                                                                                                                                                                               
   Notable CLI-only capabilities:                                                                                                                                                                              
                                                                                                                                                                                                               
   ┌────────────────────────────────┬──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐                       
   │ Capability                     │ Detail                                                                                                                                           │                       
   ├────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤                       
   │ fga model test                 │ Runs check/list-objects assertions against a model — either on a built-in in-memory OpenFGA (no server needed) or remotely via contextual tuples │                       
   ├────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤                       
   │ fga model transform            │ Converts models between DSL ↔ JSON ↔ modular formats                                                                                             │                       
   ├────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤                       
   │ fga store import/export        │ Round-trips a store as a single .fga.yaml file for versioning/sharing                                                                            │                       
   ├────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤                       
   │ Rate-controlled tuple import   │ --max-rps with automatic ramp-up for large tuple backfills                                                                                       │                       
   ├────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤                       
   │ fga tuple read --output-format │ csv/yaml/json/simple-json, pipeable back into tuple write/delete                                                                                 │                       
   └────────────────────────────────┴──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘                       
                                                                                                                                                                                                               
   How they fit together                                                                                                                                                                                       
                                                                                                                                                                                                               
   • openfga is the deployment artifact: the stateful service holding stores, models, and tuples, answering authorization queries at low latency.                                                              
   • fga is the operator/developer tool: it never evaluates anything against your server's data itself — every command (except local model test) is an API call to a running openfga server (self-hosted or    
     Auth0 FGA).                                                                                                                                                                                               
   • Overlap is minimal and intentional: both can validate a model offline (openfga validate-models vs fga model validate/test), but only openfga serves traffic and only fga provides the ergonomic client    
     workflows.                                                                                                                                                                                                
