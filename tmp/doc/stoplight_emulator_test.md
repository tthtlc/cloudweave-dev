
 Use Kimi K3 with High thinking effort - for the best balance between token spend and capability
   Run /model to switch to K3 and set thinking effort to High
 
 
 ✨ write down some test in a script which I can used to test that the docker  stoplight_mock-emulator-1 is running correctly using curl mainly.                                                             
 … 2 messages
 
 ● The user wants a test script to verify that the docker container `stoplight_mock-emulator-1` is running correctly, using curl mainly. Let me look at the stoplight_mock directory to understand what this 
   service is, what endpoints exist, ports, etc.                                                                                                                                                             
                                                                                                                                                                                                             
   Let me explore the stoplight_mock directory first.                                                                                                                                                        
 
 ● Ran a command                                                                                                                                                                                             
   $ ls stoplight_mock stoplight_mock/mock stoplight_mock/spec stoplight_mock/scripts 2>/dev/null                                                                                                            
   stoplight_mock:                                                                                                                                                                                           
   ARCHITECTURE.md                                                                                                                                                                                           
   docker-compose.yml                                                                                                                                                                                        
   mock                                                                                                                                                                                                      
   myrun.sh                                                                                                                                                                                                  
   node_modules                                                                                                                                                                                              
   prism.png                                                                                                                                                                                                 
   scripts                                                                                                                                                                                                   
   spec                                                                                                                                                                                                      
   tmp                                                                                                                                                                                                       
                                                                                                                                                                                                             
   stoplight_mock/mock:                                                                                                                                                                                      
   Dockerfile                                                                                                                                                                                                
   entrypoint.sh                                                                                                                                                                                             
   package.json                                                                                                                                                                                              
   server.js                                                                                                                                                                                                 
                                                                                                                                                                                                             
   stoplight_mock/scripts:                                                                                                                                                                                   
   merge-specs.js                                                                                                                                                                                            
   prism-test.sh                                                                                                                                                                                             
   smoke-test.sh                                                                                                                                                                                             
                                                                                                                                                                                                             
   stoplight_mock/spec:                                                                                                                                                                                      
   openapi.json                                                                                                                                                                                              
 
 ● Used Read (stoplight_mock/docker-compose.yml) · 21 lines                                                                                                                                                  
     1   services:                                                                                                                                                                                           
     2     # Stoplight Prism: OpenAPI schema-valid mock server                                                                                                                                               
     3     prism:                                                                                                                                                                                            
     4       image: stoplight/prism:5                                                                                                                                                                        
     5       command: "mock -h 0.0.0.0 -p 4010 -m false /spec/openapi.json"                                                                                                                                  
     6       volumes:                                                                                                                                                                                        
     7         - ./spec:/spec:ro                                                                                                                                                                             
     8       ports:                                                                                                                                                                                          
     9         - "4010:4010"                                                                                                                                                                                 
     10       restart: unless-stopped                                                                                                                                                                        
     11                                                                                                                                                                                                      
     12     # Stateful Node.js shim: VM CRUD + task polling                                                                                                                                                  
     13     emulator:                                                                                                                                                                                        
     14       build: ./mock                                                                                                                                                                                  
     15       ports:                                                                                                                                                                                         
     16         - "9440:9440"                                                                                                                                                                                
     17       environment:                                                                                                                                                                                   
     18         - PRISM_URL=http://prism:4010                                                                                                                                                                
     19       depends_on:                                                                                                                                                                                    
     20         - prism                                                                                                                                                                                      
     21       restart: unless-stopped                                                                                                                                                                        
 
   Approved: Running: ls stoplight_mock stoplight_mock/mock stoplight_mo…                                                                                                                                    
 
 ● The emulator is on port 9440, and Prism is on 4010. Let me read the mock server.js and the existing smoke-test.sh to understand the endpoints.                                                            
 
   Auto mode: ON                                                                                                                                                                                             
   All actions auto-approved; the agent will not ask you questions.                                                                                                                                          
 
 ● Read 2 files · 1210 lines                                                                                                                                                                                 
   ├─ stoplight_mock/mock/server.js · 1000 lines                                                                                                                                                             
   └─ stoplight_mock/scripts/smoke-test.sh · 210 lines                                                                                                                                                       
 
 ● There's already a smoke-test.sh but it's HTTPS-based (https://localhost:9440). Wait — looking at the compose file, the emulator exposes 9440 as plain HTTP probably. The existing smoke-test.sh uses      
   `https://localhost:9440` with `-k`. Let me check the entrypoint.sh to see if TLS is involved, and check whether the container is actually running.                                                        
                                                                                                                                                                                                             
   The user asked: "write down some test in a script which I can use to test that the docker stoplight_mock-emulator-1 is running correctly using curl mainly."                                              
                                                                                                                                                                                                             
   So they want a new test script. Let me check the rest of server.js (lines 1000-1130) and the entrypoint to understand TLS. Also check whether the container is running so I can verify the script works.  
 
 ● Read 2 files · 160 lines                                                                                                                                                                                  
   ├─ stoplight_mock/mock/server.js · 131 lines                                                                                                                                                              
   └─ stoplight_mock/mock/entrypoint.sh · 29 lines                                                                                                                                                           
 
 ● Ran a command                                                                                                                                                                                             
   $ docker ps --filter name=stoplight_mock --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' 2>&1                                                                                                              
   stoplight_mock-emulator-1   Up 3 weeks (healthy)   0.0.0.0:9440->9440/tcp, [::]:9440->9440/tcp                                                                                                            
   stoplight_mock-prism-1   Up 3 weeks   0.0.0.0:4010->4010/tcp, [::]:4010->4010/tcp                                                                                                                         
 
 ● The container is running. The emulator runs HTTPS (self-signed cert) on 9440. The existing smoke-test.sh covers health, seed data, VM lifecycle. The user wants a new script testing that                 
   `stoplight_mock-emulator-1` is running correctly, using curl mainly.                                                                                                                                      
                                                                                                                                                                                                             
   I'll write a comprehensive test script covering:                                                                                                                                                          
   1. Container status check (docker inspect) — optional but useful since they mention the docker container specifically                                                                                     
   2. Health endpoint                                                                                                                                                                                        
   3. Seed reference data (clusters, subnets, images, storage containers)                                                                                                                                    
   4. VM CRUD lifecycle (create → task poll → get → update → power action → list → delete)                                                                                                                   
   5. Subnet/VPC/FIP create                                                                                                                                                                                  
   6. Volume groups                                                                                                                                                                                          
   7. Prism proxy pass-through (catch-all to Prism on 4010 — e.g., an endpoint not handled by emulator)                                                                                                      
   8. 404 handling                                                                                                                                                                                           
                                                                                                                                                                                                             
   The existing smoke-test.sh already does 1-4 partly. The user asked for "some test in a script" — I'll write a new, self-contained script, e.g. `stoplight_mock/scripts/test-emulator.sh` that goes broader
   than smoke-test.sh, and make sure it passes against the live container. Note the existing smoke test has a bug: `PASS` is never incremented (green doesn't do ((PASS++))), so the summary always says 0   
   passed. I should fix that in my new script — count passes properly.                                                                                                                                       
                                                                                                                                                                                                             
   Also the default URL https://localhost:9440 with -k since TLS is enabled.                                                                                                                                 
                                                                                                                                                                                                             
   Let me write the script, run it, and verify it passes. Where to put it? The user said "write down some test in a script" — I'll place it in `stoplight_mock/scripts/test-emulator.sh` (or curl-test.sh).  
   I'll make it executable and run it to verify.                                                                                                                                                             
                                                                                                                                                                                                             
   Note about the proxy test: requests to paths not handled by emulator get proxied to Prism on 4010 which validates against the OpenAPI spec. E.g. `/api/iam/v4.0/authz/roles` is used by entrypoint as     
   readiness check. Prism will return 200 with a mock response. That's a good test of the proxy chain.                                                                                                       
                                                                                                                                                                                                             
   Let me also verify task polling timing: TASK_TRANSITION_MS = 200, so tasks succeed after 400ms. Poll with sleeps.                                                                                         
                                                                                                                                                                                                             
   Let me design the script structure:                                                                                                                                                                       
                                                                                                                                                                                                             
   ```bash                                                                                                                                                                                                   
   #!/usr/bin/env bash                                                                                                                                                                                       
   # test-emulator.sh — curl-based tests for stoplight_mock-emulator-1                                                                                                                                       
   set -uo pipefail  (not -e since we handle failures ourselves)                                                                                                                                             
                                                                                                                                                                                                             
   BASE="${1:-https://localhost:9440}"                                                                                                                                                                       
   PASS=0; FAIL=0                                                                                                                                                                                            
                                                                                                                                                                                                             
   pass/fail/check functions:                                                                                                                                                                                
   - check_status desc method url expected [body]                                                                                                                                                            
   - extract helper using python3 or jq fallback                                                                                                                                                             
                                                                                                                                                                                                             
   Tests:                                                                                                                                                                                                    
   0. Container check (docker ps) — optional, warn only                                                                                                                                                      
   1. GET /health → 200, status ok                                                                                                                                                                           
   2. Seed data: clusters list, subnets list, images list, storage containers list                                                                                                                           
   3. VM lifecycle: POST create → 202 + taskId; poll task → SUCCEEDED; GET VM by id (get vm id from task entitiesAffected); PUT update; power action POST .../power-state/power-off → check powerState OFF;  
   list with $filter; DELETE → 404 verify                                                                                                                                                                    
   4. Networking: create subnet → task; create VPC; create FIP; list them                                                                                                                                    
   5. Volume groups: create, list, delete                                                                                                                                                                    
   6. Prism proxy passthrough: GET /api/iam/v4.0/authz/roles → proxied to prism (200)                                                                                                                        
   7. 404 for unknown VM                                                                                                                                                                                     
                                                                                                                                                                                                             
   Then summary + exit code.                                                                                                                                                                                 
   ```                                                                                                                                                                                                       
                                                                                                                                                                                                             
   Keep it reasonably simple but complete. Use python3 for JSON parsing (available on the host? probably, it's used in the existing smoke test). Check jq availability as fallback. I'll write a small `jget`
   helper that tries jq then python3.                                                                                                                                                                        
                                                                                                                                                                                                             
   Actually to keep it simple and consistent with the repo's existing script, use python3 for JSON extraction.                                                                                               
                                                                                                                                                                                                             
   Let me write the script now. I'll verify each endpoint against the live container as I go — actually, best to just write it and run it, then fix whatever fails.                                          
                                                                                                                                                                                                             
   One thing to note: the VM create returns taskRefEnvelope: `{data: {$objectType, $reserved, extId}}`. Task response: prismTaskEnvelope with camelCase: data.extId, data.status,                            
   data.entitiesAffected[0].extId.                                                                                                                                                                           
                                                                                                                                                                                                             
   Power action: POST `/api/vmm/v4.0/ahv/config/vms/:extId/$actions/:action` or `/power-state/:action`. Note for curl, `$actions` needs to be escaped/quoted to avoid shell variable expansion — use single  
   quotes or `\$actions`.                                                                                                                                                                                    
                                                                                                                                                                                                             
   Update: PUT returns 202 with task.                                                                                                                                                                        
                                                                                                                                                                                                             
   Also test networking subnet create returns networkingTaskRefEnvelope with data.extId.                                                                                                                     
                                                                                                                                                                                                             
   Volume group: POST /api/volumes/v4.0/config/volume-groups → 202; GET list; DELETE.                                                                                                                        
                                                                                                                                                                                                             
   Recovery points: POST /api/dataprotection/v4.0/config/recovery-points.                                                                                                                                    
                                                                                                                                                                                                             
   FIP: POST /api/networking/v4.0/config/floating-ips.                                                                                                                                                       
                                                                                                                                                                                                             
   For a Prism proxy test: entrypoint checks `/api/iam/v4.0/authz/roles` on Prism. Via emulator: GET https://localhost:9440/api/iam/v4.0/authz/roles → proxied → prism returns mock 200. Let me verify what  
   prism returns. I'll test it when running.                                                                                                                                                                 
                                                                                                                                                                                                             
   Let me write the script.                                                                                                                                                                                  
 
 ● Used Write (stoplight_mock/scripts/test-emulator.sh) · 222 lines                                                                                                                                          
      1  #!/usr/bin/env bash                                                                                                                                                                                 
      2  # ─── Emulator container test: stoplight_mock-emulator-1 ──────────────────────                                                                                                                     
      3  # Verifies the Nutanix emulator shim (and its Prism upstream) is working:                                                                                                                           
      4  #   health endpoint, seed data, VM lifecycle, networking resources,                                                                                                                                 
      5  #   volume groups, recovery points, and the catch-all proxy to Prism.                                                                                                                               
      6  #                                                                                                                                                                                                   
      7  # Usage:                                                                                                                                                                                            
      8  #   chmod +x scripts/test-emulator.sh                                                                                                                                                               
      9  #   ./scripts/test-emulator.sh [base_url]                                                                                                                                                           
     10  #                                                                                                                                                                                                   
     11  # Default base URL: https://localhost:9440 (self-signed cert, curl uses -k)                                                                                                                         
     12  # Exit code: number of failed checks (0 = all good)                                                                                                                                                 
     13                                                                                                                                                                                                      
     14  set -uo pipefail                                                                                                                                                                                    
     15                                                                                                                                                                                                      
     16  BASE="${1:-https://localhost:9440}"                                                                                                                                                                 
     17  PASS=0                                                                                                                                                                                              
     18  FAIL=0                                                                                                                                                                                              
     19  TMP="$(mktemp -d)"                                                                                                                                                                                  
     20  trap 'rm -rf "$TMP"' EXIT                                                                                                                                                                           
     21                                                                                                                                                                                                      
     22  green() { printf '\033[32m✓ %s\033[0m\n' "$*"; PASS=$((PASS+1)); }                                                                                                                                  
     23  red()   { printf '\033[31m✗ %s\033[0m\n' "$*"; FAIL=$((FAIL+1)); }                                                                                                                                  
     24  hdr()   { printf '\n\033[1;36m── %s ──\033[0m\n' "$*"; }                                                                                                                                            
     25                                                                                                                                                                                                      
     26  # Extract a dotted path from JSON on stdin; empty string on failure.                                                                                                                                
     27  jget() { python3 -c "                                                                                                                                                                               
     28  import sys, json                                                                                                                                                                                    
     29  try:                                                                                                                                                                                                
     30      d = json.load(sys.stdin)                                                                                                                                                                        
     31      for k in sys.argv[1].split('.'):                                                                                                                                                                
     32          d = d[int(k)] if isinstance(d, list) else d[k]                                                                                                                                              
     33      print(d if d is not None else '')                                                                                                                                                               
     34  except Exception:                                                                                                                                                                                   
     35      print('')                                                                                                                                                                                       
     36  " "$1" 2>/dev/null; }                                                                                                                                                                               
     37                                                                                                                                                                                                      
     38  # check <desc> <method> <path> <expected_status> [json_body]                                                                                                                                        
     39  check() {                                                                                                                                                                                           
     40    local desc="$1" method="$2" path="$3" expected="$4" body="${5:-}"                                                                                                                                 
     41    local args=(-sk -o "$TMP/resp.json" -w '%{http_code}' -X "$method" "$BASE$path")                                                                                                                  
     42    [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")                                                                                                                        
     43    local code                                                                                                                                                                                        
     44    code=$(curl "${args[@]}" 2>&1) || code="curl-error"                                                                                                                                               
     45    if [[ "$code" == "$expected" ]]; then                                                                                                                                                             
     46      green "$desc (HTTP $code)"                                                                                                                                                                      
     47    else                                                                                                                                                                                              
     48      red "$desc — expected $expected, got $code"                                                                                                                                                     
     49      head -c 300 "$TMP/resp.json" 2>/dev/null; echo                                                                                                                                                  
     50    fi                                                                                                                                                                                                
     51  }                                                                                                                                                                                                   
     52                                                                                                                                                                                                      
     53  # poll_task <task_id> -> echoes final status; returns 0 if SUCCEEDED                                                                                                                                
     54  poll_task() {                                                                                                                                                                                       
     55    local tid="$1" status=""                                                                                                                                                                          
     56    for _ in $(seq 1 15); do                                                                                                                                                                          
     57      status=$(curl -sk "$BASE/api/prism/v4.0/config/tasks/$tid" | jget data.status)                                                                                                                  
     58      [[ "$status" == "SUCCEEDED" ]] && return 0                                                                                                                                                      
     59      sleep 0.5                                                                                                                                                                                       
     60    done                                                                                                                                                                                              
     61    echo "$status"                                                                                                                                                                                    
     62    return 1                                                                                                                                                                                          
     63  }                                                                                                                                                                                                   
     64                                                                                                                                                                                                      
     65  echo "╔══════════════════════════════════════════════════════╗"                                                                                                                                     
     66  echo "║   Emulator test: stoplight_mock-emulator-1          ║"                                                                                                                                      
     67  echo "║   Target: $BASE"                                                                                                                                                                            
     68  echo "╚══════════════════════════════════════════════════════╝"                                                                                                                                     
     69                                                                                                                                                                                                      
     70  # ── 0. Container sanity (informational) ──────────────────────────────────────                                                                                                                     
     71  hdr "0. Docker container"                                                                                                                                                                           
     72  if docker ps --filter name=stoplight_mock-emulator-1 --format '{{.Names}}' 2>/dev/null | grep -q stoplight_mock-emulator-1; then                                                                    
     73    green "container stoplight_mock-emulator-1 is up"                                                                                                                                                 
     74  else                                                                                                                                                                                                
     75    red "container stoplight_mock-emulator-1 not found in docker ps"                                                                                                                                  
     76  fi                                                                                                                                                                                                  
     77                                                                                                                                                                                                      
     78  # ── 1. Health ────────────────────────────────────────────────────────────────                                                                                                                     
     79  hdr "1. Health"                                                                                                                                                                                     
     80  check "GET /health" GET /health 200                                                                                                                                                                 
     81  H=$(curl -sk "$BASE/health" | jget status)                                                                                                                                                          
     82  [[ "$H" == "ok" ]] && green "health status is 'ok'" || red "health status: '$H'"                                                                                                                    
     83                                                                                                                                                                                                      
     84  # ── 2. Seed reference data ───────────────────────────────────────────────────                                                                                                                     
     85  hdr "2. Seed data"                                                                                                                                                                                  
     86  check "List clusters"           GET /api/cluster-mgmt/v4.0/config/clusters 200                                                                                                                      
     87  check "List subnets"            GET /api/networking/v4.0/config/subnets 200                                                                                                                         
     88  check "List images (config)"    GET /api/vmm/v4.0/config/images 200                                                                                                                                 
     89  check "List images (content)"   GET /api/vmm/v4.0/content/images 200                                                                                                                                
     90  check "List storage containers" GET /api/vmm/v4.0/config/storage-containers 200                                                                                                                     
     91  check "v4.0.a1 path variant"    GET /api/vmm/v4.0.a1/config/vms 200                                                                                                                                 
     92  check "ahv path variant"        GET /api/vmm/v4.0/ahv/config/vms 200                                                                                                                                
     93                                                                                                                                                                                                      
     94  N=$(curl -sk "$BASE/api/networking/v4.0/config/subnets" | jget metadata.totalAvailableResults)                                                                                                      
     95  [[ "$N" -ge 1 ]] && green "seed subnet present ($N)" || red "seed subnet missing"                                                                                                                   
     96  N=$(curl -sk "$BASE/api/vmm/v4.0/config/images" | jget metadata.totalAvailableResults)                                                                                                              
     97  [[ "$N" -ge 2 ]] && green "seed images present ($N)" || red "seed images missing ($N)"                                                                                                              
     98                                                                                                                                                                                                      
     99  # ── 3. VM lifecycle ──────────────────────────────────────────────────────────                                                                                                                     
    100  hdr "3. VM lifecycle (create → task → get → update → power → delete)"                                                                                                                               
    101  VM_BODY='{                                                                                                                                                                                          
    102    "name": "curl-test-vm",                                                                                                                                                                           
    103    "description": "created by test-emulator.sh",                                                                                                                                                     
    104    "num_sockets": 2,                                                                                                                                                                                 
    105    "num_cores_per_socket": 2,                                                                                                                                                                        
    106    "memory_size_bytes": 4294967296,                                                                                                                                                                  
    107    "nics": [{ "subnet": { "ext_id": "00000000-0000-0000-0000-000000000002" } }]                                                                                                                      
    108  }'                                                                                                                                                                                                  
    109                                                                                                                                                                                                      
    110  RESP=$(curl -sk -X POST "$BASE/api/vmm/v4.0/ahv/config/vms" -H 'Content-Type: application/json' -d "$VM_BODY")                                                                                      
    111  TASK_ID=$(echo "$RESP" | jget data.extId)                                                                                                                                                           
    112  [[ -n "$TASK_ID" ]] && green "POST create VM accepted (task $TASK_ID)" || red "POST create VM: no task id — $RESP"                                                                                  
    113                                                                                                                                                                                                      
    114  VM_ID=""                                                                                                                                                                                            
    115  if [[ -n "$TASK_ID" ]]; then                                                                                                                                                                        
    116    if poll_task "$TASK_ID" >/dev/null; then                                                                                                                                                          
    117      green "create task SUCCEEDED"                                                                                                                                                                   
    118      VM_ID=$(curl -sk "$BASE/api/prism/v4.0/config/tasks/$TASK_ID" | jget data.entitiesAffected.0.extId)                                                                                             
    119    else                                                                                                                                                                                              
    120      red "create task did not reach SUCCEEDED"                                                                                                                                                       
    121    fi                                                                                                                                                                                                
    122  fi                                                                                                                                                                                                  
    123                                                                                                                                                                                                      
    124  if [[ -n "$VM_ID" ]]; then                                                                                                                                                                          
    125    NAME=$(curl -sk "$BASE/api/vmm/v4.0/ahv/config/vms/$VM_ID" | jget data.name)                                                                                                                      
    126    [[ "$NAME" == "curl-test-vm" ]] && green "GET VM name ok" || red "GET VM name: '$NAME'"                                                                                                           
    127                                                                                                                                                                                                      
    128    # Update                                                                                                                                                                                          
    129    RESP=$(curl -sk -X PUT "$BASE/api/vmm/v4.0/ahv/config/vms/$VM_ID" \                                                                                                                               
    130      -H 'Content-Type: application/json' -d '{"name":"curl-test-vm-v2","numSockets":4}')                                                                                                             
    131    UTASK=$(echo "$RESP" | jget data.extId)                                                                                                                                                           
    132    [[ -n "$UTASK" ]] && poll_task "$UTASK" >/dev/null && green "PUT update task SUCCEEDED" || red "PUT update failed"                                                                                
    133    NAME=$(curl -sk "$BASE/api/vmm/v4.0/ahv/config/vms/$VM_ID" | jget data.name)                                                                                                                      
    134    [[ "$NAME" == "curl-test-vm-v2" ]] && green "updated name persisted" || red "updated name: '$NAME'"                                                                                               
    135                                                                                                                                                                                                      
    136    # Power action (v4 $actions URL — single quotes protect the $)                                                                                                                                    
    137    RESP=$(curl -sk -X POST "$BASE/api/vmm/v4.0/ahv/config/vms/$VM_ID/\$actions/power-off" -H 'Content-Type: application/json' -d '{}')                                                               
    138    PTASK=$(echo "$RESP" | jget data.extId)                                                                                                                                                           
    139    [[ -n "$PTASK" ]] && green "power-off accepted (task $PTASK)" || red "power-off: no task — $RESP"                                                                                                 
    140    sleep 1                                                                                                                                                                                           
    141    PS=$(curl -sk "$BASE/api/vmm/v4.0/ahv/config/vms/$VM_ID" | jget data.powerState)                                                                                                                  
    142    [[ "$PS" == "OFF" ]] && green "power state is OFF" || red "power state: '$PS' (expected OFF)"                                                                                                     
    143                                                                                                                                                                                                      
    144    # Legacy power-state URL                                                                                                                                                                          
    145    check "legacy /power-state/power-on" POST "/api/vmm/v4.0/ahv/config/vms/$VM_ID/power-state/power-on" 202 '{}'                                                                                     
    146                                                                                                                                                                                                      
    147    # List + $filter                                                                                                                                                                                  
    148    check "List VMs" GET /api/vmm/v4.0/ahv/config/vms 200                                                                                                                                             
    149    F=$(curl -sk --get --data-urlencode "\$filter=name eq 'curl-test-vm-v2'" "$BASE/api/vmm/v4.0/ahv/config/vms" | jget metadata.totalAvailableResults)                                               
    150    [[ "$F" == "1" ]] && green "\$filter by name works" || red "\$filter returned $F results (expected 1)"                                                                                            
    151                                                                                                                                                                                                      
    152    # Delete                                                                                                                                                                                          
    153    RESP=$(curl -sk -X DELETE "$BASE/api/vmm/v4.0/ahv/config/vms/$VM_ID")                                                                                                                             
    154    DTASK=$(echo "$RESP" | jget data.extId)                                                                                                                                                           
    155    [[ -n "$DTASK" ]] && poll_task "$DTASK" >/dev/null && green "DELETE task SUCCEEDED" || red "DELETE failed"                                                                                        
    156    check "GET deleted VM → 404" GET "/api/vmm/v4.0/ahv/config/vms/$VM_ID" 404                                                                                                                        
    157  fi                                                                                                                                                                                                  
    158                                                                                                                                                                                                      
    159  check "GET unknown VM → 404" GET /api/vmm/v4.0/ahv/config/vms/00000000-dead-beef-0000-000000000000 404                                                                                              
    160  check "GET unknown task → 404" GET /api/prism/v4.0/config/tasks/00000000-dead-beef-0000-000000000000 404                                                                                            
    161                                                                                                                                                                                                      
    162  # ── 4. Networking resources ──────────────────────────────────────────────────                                                                                                                     
    163  hdr "4. Networking (subnet / VPC / floating IP / NSP)"                                                                                                                                              
    164                                                                                                                                                                                                      
    165  RESP=$(curl -sk -X POST "$BASE/api/networking/v4.0/config/subnets" -H 'Content-Type: application/json' \                                                                                            
    166    -d '{"name":"curl-test-subnet","subnetType":"VLAN"}')                                                                                                                                             
    167  STASK=$(echo "$RESP" | jget data.extId)                                                                                                                                                             
    168  [[ -n "$STASK" ]] && green "create subnet accepted" || red "create subnet: $RESP"                                                                                                                   
    169  SUBNET_ID=$(curl -sk "$BASE/api/prism/v4.0/config/tasks/$STASK" | jget data.entitiesAffected.0.extId)                                                                                               
    170  [[ -n "$SUBNET_ID" ]] && green "subnet extId from task" || red "subnet extId missing"                                                                                                               
    171  check "List subnets after create" GET /api/networking/v4.0/config/subnets 200                                                                                                                       
    172                                                                                                                                                                                                      
    173  RESP=$(curl -sk -X POST "$BASE/api/networking/v4.0/config/vpcs" -H 'Content-Type: application/json' \                                                                                               
    174    -d '{"name":"curl-test-vpc"}')                                                                                                                                                                    
    175  VTASK=$(echo "$RESP" | jget data.extId)                                                                                                                                                             
    176  VPC_ID=$(curl -sk "$BASE/api/prism/v4.0/config/tasks/$VTASK" | jget data.entitiesAffected.0.extId)                                                                                                  
    177  [[ -n "$VPC_ID" ]] && green "create VPC accepted ($VPC_ID)" || red "create VPC failed"                                                                                                              
    178  check "List VPCs" GET /api/networking/v4.0/config/vpcs 200                                                                                                                                          
    179  check "Delete VPC" DELETE "/api/networking/v4.0/config/vpcs/$VPC_ID" 202                                                                                                                            
    180                                                                                                                                                                                                      
    181  RESP=$(curl -sk -X POST "$BASE/api/networking/v4.0/config/floating-ips" -H 'Content-Type: application/json' \                                                                                       
    182    -d '{"name":"curl-test-fip"}')                                                                                                                                                                    
    183  FTASK=$(echo "$RESP" | jget data.extId)                                                                                                                                                             
    184  FIP_ID=$(curl -sk "$BASE/api/prism/v4.0/config/tasks/$FTASK" | jget data.entitiesAffected.0.extId)                                                                                                  
    185  [[ -n "$FIP_ID" ]] && green "create floating IP accepted ($FIP_ID)" || red "create floating IP failed"                                                                                              
    186  check "List floating IPs" GET /api/networking/v4.0/config/floating-ips 200                                                                                                                          
    187  check "Delete floating IP" DELETE "/api/networking/v4.0/config/floating-ips/$FIP_ID" 202                                                                                                            
    188                                                                                                                                                                                                      
    189  check "Create NSP" POST /api/networking/v4.0/config/network-security-policies 202 '{"name":"curl-test-nsp"}'                                                                                        
    190  check "List NSPs" GET /api/networking/v4.0/config/network-security-policies 200                                                                                                                     
    191                                                                                                                                                                                                      
    192  # ── 5. Volume groups + recovery points ───────────────────────────────────────                                                                                                                     
    193  hdr "5. Volume groups / recovery points"                                                                                                                                                            
    194                                                                                                                                                                                                      
    195  RESP=$(curl -sk -X POST "$BASE/api/volumes/v4.0/config/volume-groups" -H 'Content-Type: application/json' \                                                                                         
    196    -d '{"name":"curl-test-vg","disks":[{"diskSizeBytes":10737418240}]}')                                                                                                                             
    197  GTASK=$(echo "$RESP" | jget data.extId)                                                                                                                                                             
    198  VG_ID=$(curl -sk "$BASE/api/prism/v4.0/config/tasks/$GTASK" | jget data.entitiesAffected.0.extId)                                                                                                   
    199  [[ -n "$VG_ID" ]] && green "create volume group accepted ($VG_ID)" || red "create VG failed"                                                                                                        
    200  check "List volume groups" GET /api/volumes/v4.0/config/volume-groups 200                                                                                                                           
    201  check "List VG disks" GET "/api/volumes/v4.0/config/volume-groups/$VG_ID/disks" 200                                                                                                                 
    202                                                                                                                                                                                                      
    203  RESP=$(curl -sk -X POST "$BASE/api/dataprotection/v4.0/config/recovery-points" -H 'Content-Type: application/json' \                                                                                
    204    -d "{\"name\":\"curl-test-rp\",\"volumeGroupRecoveryPoints\":[{\"volumeGroupExtId\":\"$VG_ID\"}]}")                                                                                               
    205  RTASK=$(echo "$RESP" | jget data.extId)                                                                                                                                                             
    206  RP_ID=$(curl -sk "$BASE/api/prism/v4.0/config/tasks/$RTASK" | jget data.entitiesAffected.0.extId)                                                                                                   
    207  [[ -n "$RP_ID" ]] && green "create recovery point accepted ($RP_ID)" || red "create RP failed"                                                                                                      
    208  RF=$(curl -sk --get --data-urlencode "\$filter=volumeGroupExtId eq '$VG_ID'" "$BASE/api/dataprotection/v4.0/config/recovery-points" | jget metadata.totalAvailableResults)                          
    209  [[ "$RF" -ge 1 ]] && green "RP \$filter by volumeGroupExtId works" || red "RP \$filter returned $RF"                                                                                                
    210  check "Delete recovery point" DELETE "/api/dataprotection/v4.0/config/recovery-points/$RP_ID" 202                                                                                                   
    211  check "Delete volume group" DELETE "/api/volumes/v4.0/config/volume-groups/$VG_ID" 202                                                                                                              
    212                                                                                                                                                                                                      
    213  # ── 6. Prism proxy passthrough ───────────────────────────────────────────────                                                                                                                     
    214  hdr "6. Proxy to Prism (spec-covered, not emulated)"                                                                                                                                                
    215  check "GET /api/iam/v4.0/authz/roles via proxy" GET /api/iam/v4.0/authz/roles 200                                                                                                                   
    216                                                                                                                                                                                                      
    217  # ── Summary ──────────────────────────────────────────────────────────────────                                                                                                                     
    218  echo ""                                                                                                                                                                                             
    219  echo "════════════════════════════════════════════════════════"                                                                                                                                     
    220  printf "  Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"                                                                                                            
    221  echo "════════════════════════════════════════════════════════"                                                                                                                                     
    222  exit "$FAIL"                                                                                                                                                                                        
    223                                                                                                                                                                                                      
     Wrote 12474 bytes to stoplight_mock/scripts/test-emulator.sh                                                                                                                                            
 
 ● Now run it against the live container.                                                                                                                                                                    
 
 ● Now let me run it against the live container to verify.                                                                                                                                                   
 
 ● Ran a command                                                                                                                                                                                             
   $ chmod +x stoplight_mock/scripts/test-emulator.sh && ./stoplight_mock/scripts/test-emulator.sh 2>&1                                                                                                      
   ╔══════════════════════════════════════════════════════╗                                                                                                                                                  
   ║   Emulator test: stoplight_mock-emulator-1          ║                                                                                                                                                   
   ║   Target: https://localhost:9440                                                                                                                                                                        
   ╚══════════════════════════════════════════════════════╝                                                                                                                                                  
                                                                                                                                                                                                             
   ── 0. Docker container ──                                                                                                                                                                                 
   ✓ container stoplight_mock-emulator-1 is up                                                                                                                                                               
                                                                                                                                                                                                             
   ── 1. Health ──                                                                                                                                                                                           
   ✓ GET /health (HTTP 200)                                                                                                                                                                                  
   ✓ health status is 'ok'                                                                                                                                                                                   
                                                                                                                                                                                                             
   ── 2. Seed data ──                                                                                                                                                                                        
   ✓ List clusters (HTTP 200)                                                                                                                                                                                
   ✓ List subnets (HTTP 200)                                                                                                                                                                                 
   ✓ List images (config) (HTTP 200)                                                                                                                                                                         
   ✓ List images (content) (HTTP 200)                                                                                                                                                                        
   ✓ List storage containers (HTTP 200)                                                                                                                                                                      
   ✓ v4.0.a1 path variant (HTTP 200)                                                                                                                                                                         
   ✓ ahv path variant (HTTP 200)                                                                                                                                                                             
   ✓ seed subnet present (2)                                                                                                                                                                                 
   ✓ seed images present (2)                                                                                                                                                                                 
                                                                                                                                                                                                             
   ── 3. VM lifecycle (create → task → get → update → power → delete) ──                                                                                                                                     
   ✓ POST create VM accepted (task e2a63b2a-c2f7-4887-9528-7b0f8d7a21bf)                                                                                                                                     
   ✓ create task SUCCEEDED                                                                                                                                                                                   
   ✓ GET VM name ok                                                                                                                                                                                          
   ✓ PUT update task SUCCEEDED                                                                                                                                                                               
   ✓ updated name persisted                                                                                                                                                                                  
   ✓ power-off accepted (task 238770ad-13ef-4543-a3b5-8a3aa939d002)                                                                                                                                          
   ✓ power state is OFF                                                                                                                                                                                      
   ✓ legacy /power-state/power-on (HTTP 202)                                                                                                                                                                 
   ✓ List VMs (HTTP 200)                                                                                                                                                                                     
   ✓ $filter by name works                                                                                                                                                                                   
   ✓ DELETE task SUCCEEDED                                                                                                                                                                                   
   ✓ GET deleted VM → 404 (HTTP 404)                                                                                                                                                                         
   ✓ GET unknown VM → 404 (HTTP 404)                                                                                                                                                                         
   ✓ GET unknown task → 404 (HTTP 404)                                                                                                                                                                       
                                                                                                                                                                                                             
   ── 4. Networking (subnet / VPC / floating IP / NSP) ──                                                                                                                                                    
   ✓ create subnet accepted                                                                                                                                                                                  
   ✓ subnet extId from task                                                                                                                                                                                  
   ✓ List subnets after create (HTTP 200)                                                                                                                                                                    
   ✓ create VPC accepted (467b61e5-a44b-451d-92ec-f4ed3986e6ce)                                                                                                                                              
   ✓ List VPCs (HTTP 200)                                                                                                                                                                                    
   ✓ Delete VPC (HTTP 202)                                                                                                                                                                                   
   ✓ create floating IP accepted (0e414678-6bd8-4ccf-817e-6b8d1f1fbc35)                                                                                                                                      
   ✓ List floating IPs (HTTP 200)                                                                                                                                                                            
   ✓ Delete floating IP (HTTP 202)                                                                                                                                                                           
   ✓ Create NSP (HTTP 202)                                                                                                                                                                                   
   ✓ List NSPs (HTTP 200)                                                                                                                                                                                    
                                                                                                                                                                                                             
   ── 5. Volume groups / recovery points ──                                                                                                                                                                  
   ✓ create volume group accepted (d686f8e0-67d5-4e19-91b3-71d79e520ecf)                                                                                                                                     
   ✓ List volume groups (HTTP 200)                                                                                                                                                                           
   ✓ List VG disks (HTTP 200)                                                                                                                                                                                
   ✓ create recovery point accepted (a553952e-2e22-46fa-88e4-5cefe98ab950)                                                                                                                                   
   ✓ RP $filter by volumeGroupExtId works                                                                                                                                                                    
   ✓ Delete recovery point (HTTP 202)                                                                                                                                                                        
   ✓ Delete volume group (HTTP 202)                                                                                                                                                                          
                                                                                                                                                                                                             
   ── 6. Proxy to Prism (spec-covered, not emulated) ──                                                                                                                                                      
   ✓ GET /api/iam/v4.0/authz/roles via proxy (HTTP 200)                                                                                                                                                      
                                                                                                                                                                                                             
   ════════════════════════════════════════════════════════                                                                                                                                                  
     Results: 45 passed, 0 failed                                                                                                                                                                            
   ════════════════════════════════════════════════════════                                                                                                                                                  
 
 ● All 45 checks pass. One side effect: the test left behind a "curl-test-subnet" and a "curl-test-nsp" (I don't delete those in the script — subnet and NSP created but not cleaned up). Since the store is 
   in-memory, they disappear on container restart, but it would be cleaner to delete them in the script. Let me add cleanup for the subnet and NSP so repeated runs don't accumulate state (note: "seed      
   subnet present (2)" already showed 2 — my test subnet from this run is still there). Let me add delete checks for subnet and NSP to the script, and clean up the leftover ones from the current run.      
                                                                                                                                                                                                             
   For the subnet: I have SUBNET_ID. Add `check "Delete subnet" DELETE .../subnets/$SUBNET_ID 202`. For NSP: capture the extId from the task and delete. Let me update the script, then delete the leftover  
   entities from this first run (I can find them by listing with filter). Actually simpler: after updating the script, run it again — it will create new ones and clean them up. But the leftover from run 1 
   remains. Let me clean that manually via curl.                                                                                                                                                             
                                                                                                                                                                                                             
   Let me find the leftover subnet and NSP ids.                                                                                                                                                              
 
 ● Used Edit (stoplight_mock/scripts/test-emulator.sh) · +9 -1                                                                                                                                               
   +9 -1 stoplight_mock/scripts/test-emulator.sh                                                                                                                                                             
      1 - check "Create NSP" POST /api/networking/v4.0/config/network-security-policies 202 '{"name":"curl-test-nsp"}'                                                                                       
      1 + RESP=$(curl -sk -X POST "$BASE/api/networking/v4.0/config/network-security-policies" -H 'Content-Type: application/json' \                                                                         
      2 +   -d '{"name":"curl-test-nsp"}')                                                                                                                                                                   
      3 + NTASK=$(echo "$RESP" | jget data.extId)                                                                                                                                                            
      4 + NSP_ID=$(curl -sk "$BASE/api/prism/v4.0/config/tasks/$NTASK" | jget data.entitiesAffected.0.extId)                                                                                                 
      5 + [[ -n "$NSP_ID" ]] && green "create NSP accepted ($NSP_ID)" || red "create NSP failed"                                                                                                             
      6   check "List NSPs" GET /api/networking/v4.0/config/network-security-policies 200                                                                                                                    
      7 + check "Delete NSP" DELETE "/api/networking/v4.0/config/network-security-policies/$NSP_ID" 202                                                                                                      
      8 +                                                                                                                                                                                                    
      9 + # Clean up the subnet created above                                                                                                                                                                
     10 + check "Delete subnet" DELETE "/api/networking/v4.0/config/subnets/$SUBNET_ID" 202                                                                                                                  
     Replaced 1 occurrence in stoplight_mock/scripts/test-emulator.sh                                                                                                                                        
 
 ● Ran a command                                                                                                                                                                                             
   $ for id in $(curl -sk "https://localhost:9440/api/networking/v4.0/config/subnets" | python3 -c "import sys,json; [print(s['extId']) for s in json.load(sys.stdin)['data'] if                             
   s.get('name')=='curl-test-subnet']"); do curl -sk -X DELETE "https://localhost:9440/api/networking/v4.0/config/subnets/$id" >/dev/null && echo "deleted subnet $id"; done                                 
     for id in $(curl -sk "https://localhost:9440/api/networking/v4.0/config/network-security-policies" | python3 -c "import sys,json; [print(n['extId']) for n in json.load(sys.stdin)['data'] if           
   n.get('name')=='curl-test-nsp']"); do curl -sk -X DELETE "https://localhost:9440/api/networking/v4.0/config/network-security-policies/$id" >/dev/null && echo "deleted nsp $id"; done                     
   deleted subnet 08848ca4-e741-428f-9262-75177bf688f0                                                                                                                                                       
   deleted nsp 0503151c-a412-48fd-b273-7c6c22a38b65                                                                                                                                                          
 
 ● Ran a command                                                                                                                                                                                             
   $ ./stoplight_mock/scripts/test-emulator.sh 2>&1 | tail -30; echo "exit=$?"                                                                                                                               
   ── 4. Networking (subnet / VPC / floating IP / NSP) ──                                                                                                                                                    
   ✓ create subnet accepted                                                                                                                                                                                  
   ✓ subnet extId from task                                                                                                                                                                                  
   ✓ List subnets after create (HTTP 200)                                                                                                                                                                    
   ✓ create VPC accepted (8d0e5462-a6de-4a4e-b333-196604e1c04d)                                                                                                                                              
   ✓ List VPCs (HTTP 200)                                                                                                                                                                                    
   ✓ Delete VPC (HTTP 202)                                                                                                                                                                                   
   ✓ create floating IP accepted (058193d7-1915-4741-9bc4-6b425c5060d9)                                                                                                                                      
   ✓ List floating IPs (HTTP 200)                                                                                                                                                                            
   ✓ Delete floating IP (HTTP 202)                                                                                                                                                                           
   ✓ create NSP accepted (3665a707-2903-427d-bf31-f0e137594976)                                                                                                                                              
   ✓ List NSPs (HTTP 200)                                                                                                                                                                                    
   ✓ Delete NSP (HTTP 202)                                                                                                                                                                                   
   ✓ Delete subnet (HTTP 202)                                                                                                                                                                                
                                                                                                                                                                                                             
   ── 5. Volume groups / recovery points ──                                                                                                                                                                  
   ✓ create volume group accepted (a5a38603-8d96-475e-96af-4e21025f0f53)                                                                                                                                     
   ✓ List volume groups (HTTP 200)                                                                                                                                                                           
   ✓ List VG disks (HTTP 200)                                                                                                                                                                                
   ✓ create recovery point accepted (96887844-55c2-4329-bb64-758d7de95310)                                                                                                                                   
   ✓ RP $filter by volumeGroupExtId works                                                                                                                                                                    
   ✓ Delete recovery point (HTTP 202)                                                                                                                                                                        
   ✓ Delete volume group (HTTP 202)                                                                                                                                                                          
                                                                                                                                                                                                             
   ── 6. Proxy to Prism (spec-covered, not emulated) ──                                                                                                                                                      
   ✓ GET /api/iam/v4.0/authz/roles via proxy (HTTP 200)                                                                                                                                                      
                                                                                                                                                                                                             
   ════════════════════════════════════════════════════════                                                                                                                                                  
     Results: 47 passed, 0 failed                                                                                                                                                                            
   ════════════════════════════════════════════════════════                                                                                                                                                  
   exit=0                                                                                                                                                                                                    
 
 ● All 47 checks pass, exit code 0. The script is done. Let me summarize for the user.                                                                                                                       
 
 ● Done. The script is at stoplight_mock/scripts/test-emulator.sh — 47 checks, all passing, exit code 0 against the live stoplight_mock-emulator-1.                                                          
                                                                                                                                                                                                             
   What it tests (all via curl -k against https://localhost:9440, plus one docker ps sanity check):                                                                                                          
                                                                                                                                                                                                             
   • Container + health — container is up, GET /health returns 200 with status: ok                                                                                                                           
   • Seed data — clusters, subnets, images (config + content paths), storage containers, and both v4.0.a1 / v4.0/ahv path variants                                                                           
   • Full VM lifecycle — create → poll task to SUCCEEDED → get by extId → update → power-off via /$actions/power-off (verifies powerState flips to OFF) → legacy /power-state/power-on → $filter by name →   
     delete → confirm 404                                                                                                                                                                                    
   • 404 handling — unknown VM and unknown task                                                                                                                                                              
   • Networking — subnet, VPC, floating IP, NSP: create (202 + task), list, delete                                                                                                                           
   • Volumes / data protection — volume group create/list/disks, recovery point create + $filter=volumeGroupExtId eq ..., deletes                                                                            
   • Prism proxy passthrough — GET /api/iam/v4.0/authz/roles goes through the emulator's catch-all proxy to Prism and returns 200                                                                            
                                                                                                                                                                                                             
   Usage:                                                                                                                                                                                                    
                                                                                                                                                                                                             
   ```bash                                                                                                                                                                                                   
     ./stoplight_mock/scripts/test-emulator.sh            # defaults to https://localhost:9440                                                                                                               
     ./stoplight_mock/scripts/test-emulator.sh https://other-host:9440                                                                                                                                       
   ```                                                                                                                                                                                                       
                                                                                                                                                                                                             
   Notes:                                                                                                                                                                                                    
   • Everything it creates is cleaned up at the end, so it's safe to run repeatedly (state is in-memory anyway — a container restart resets it).                                                             
   • Exit code equals the number of failed checks, so it works in CI: 0 = healthy.                                                                                                                           
   • There's also the older scripts/smoke-test.sh covering just the VM flow, but its pass/fail counter was broken (never increments PASS), so I'd use this new one.                                          
 

