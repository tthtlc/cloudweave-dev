 ▐▛███▜▌   Claude Code v2.1.234
▝▜█████▛▘  deepseek-v4-pro · API Usage Billing
  ▘▘ ▝▝    ~/libcloud_nutanix


❯ inside stoplight_mock, create multiple docker that can mock or emulate the    
  other version of Nutanix v4 API, whose openapi spec is given in               
  stoplight_mock/spec.                                                          

  Thought for 4s (ctrl+o to expand)

● I'll explore the stoplight_mock directory and its spec to understand the
  current setup before planning the changes.

  Thought for 3m 41s, searched for 1 pattern, read 14 files, ran 9 shell commands (ctrl+o to expand)

● Now I'll make the changes. First, parameterize the API version in
  mock/server.js:

● Update(stoplight_mock/mock/server.js)
  ⎿  Added 8 lines, removed 1 line
       9  // ─── Constants ──────────────────────────────────────────────
          ─────────────────
      10  const PORT = 9440;
      11  const PRISM_URL = process.env.PRISM_URL || 'http://prism:4010';
      12 -const API_VERSIONS = ['v4.0.a1', 'v4.0', 'v4.0/ahv'];          
      12 +// API version this emulator front-ends. Defaults to v4.0, whic
         +h preserves the                                                
      13 +// legacy path variants below. For v4.1/v4.2/v4.3 the Nutanix p
         +aths collapse to                                               
      14 +// a single /api/{ns}/v4.x/... form, and AHV VMs live under    
      15 +// /api/vmm/v4.x/ahv/config/vms (see vmListPaths below).       
      16 +const API_VERSION = process.env.API_VERSION || 'v4.0';         
      17 +const API_VERSIONS = API_VERSION === 'v4.0'                    
      18 +  ? ['v4.0.a1', 'v4.0', 'v4.0/ahv']                            
      19 +  : [API_VERSION];                                             
      20  const TASK_TRANSITION_MS = 200;
      21  
      22  // ─── Helpers: camelCase ↔ snake_case ────────────────────────
          ────────────────

● Update(stoplight_mock/mock/server.js)
  ⎿  Added 5 lines, removed 1 line
      331  }
      332  
      333  // ─── VM CRUD ───────────────────────────────────────────────
           ──────────────────
      334 -const vmListPaths = pathVariants('vmm', 'config', 'vms');     
      334 +// v4.0 serves VMs on several legacy path variants (a1 / bare 
          +/ ahv); v4.1+ uses                                            
      335 +// the canonical AHV path /api/vmm/v4.x/ahv/config/vms.       
      336 +const vmListPaths = API_VERSION === 'v4.0'                    
      337 +  ? pathVariants('vmm', 'config', 'vms')                      
      338 +  : [`/api/vmm/${API_VERSION}/ahv/config/vms`];               
      339  const vmDetailPaths = vmListPaths.map((p) => p + '/:extId');
      340  
      341  // CREATE

● Update(stoplight_mock/mock/server.js)
  ⎿  Added 1 line, removed 1 line
      728  
      729  // ─── Images (legacy config path + v4 content path) ─────────
           ──────────────────
      730  const imagePaths = pathVariants('vmm', 'config', 'images')
      731 -  .concat(['/api/vmm/v4.0/content/images']);                  
      731 +  .concat([`/api/vmm/${API_VERSION}/content/images`]);        
      732  const imageDetailPaths = imagePaths.map((p) => p + '/:extId');
      733  
      734  function imageSummary(img) {

● Update(stoplight_mock/mock/server.js)
  ⎿  Added 1 line, removed 1 line
      778    res.json(dataEnvelope(imageSummary(img)));
      779  });
      780  
      781 -app.post(['/api/vmm/v4.0/content/images'], (req, res) => {    
      781 +app.post([`/api/vmm/${API_VERSION}/content/images`], (req, res
          +) => {                                                        
      782    const body = deepConvert(req.body, toSnakeCase);
      783    const source = body.source || {};
      784  

● Update(stoplight_mock/mock/server.js)
  ⎿  Added 1 line, removed 1 line
      816    res.status(202).json(taskRefEnvelope(task.ext_id));
      817  });
      818  
      819 -app.delete(['/api/vmm/v4.0/content/images/:extId'], (req, res)
          - => {                                                         
      819 +app.delete([`/api/vmm/${API_VERSION}/content/images/:extId`], 
          +(req, res) => {                                               
      820    if (!images.has(req.params.extId)) {
      821      return res.status(404).json({ message: `Image ${req.params
           .extId} not found` });
      822    }

● Update(stoplight_mock/mock/server.js)
  ⎿  Added 1 line, removed 1 line
      844  });
      845  
      846  // ─── Volume groups (volumes v4) ────────────────────────────
           ──────────────────
      847 -const vgListPaths = ['/api/volumes/v4.0/config/volume-groups']
          -;                                                             
      847 +const vgListPaths = [`/api/volumes/${API_VERSION}/config/volum
          +e-groups`];                                                   
      848  const vgDetailPaths = vgListPaths.map((p) => p + '/:extId');
      849  const vgDiskPaths = vgListPaths.map((p) => p + '/:volumeGroupE
           xtId/disks');
      850  const vgAttachmentPaths = vgListPaths.map((p) => p + '/:volume
           GroupExtId/vm-attachments');

● Update(stoplight_mock/mock/server.js)
  ⎿  Added 1 line, removed 1 line
       997  });
       998  
       999  // ─── Recovery points (dataprotection v4) ──────────────────
            ───────────────────
      1000 -const rpListPaths = ['/api/dataprotection/v4.0/config/recover
           -y-points'];                                                  
      1000 +const rpListPaths = [`/api/dataprotection/${API_VERSION}/conf
           +ig/recovery-points`];                                        
      1001  const rpDetailPaths = rpListPaths.map((p) => p + '/:extId');
      1002  
      1003  function recoveryPointSummary(rp) {

  Thought for 1s (ctrl+o to expand)

● Now update the entrypoint readiness probe to be version-aware:

● Update(stoplight_mock/mock/entrypoint.sh)
  ⎿  Added 8 lines, removed 4 lines
       1  #!/bin/sh
       2  set -e
       3  
       4 +# A well-known GET path in the served spec, used only as a read
         +iness probe.                                                   
       5 +# v4.0 and v4.1+ all expose the AHV VM list at /api/vmm/v{ver}/
         +ahv/config/vms.                                                
       6 +READY_PATH="${PRISM_READY_PATH:-/api/vmm/${API_VERSION:-v4.0}/a
         +hv/config/vms}"                                                
       7 +                                                               
       8  echo "Waiting for Prism on ${PRISM_URL:-http://prism:4010} ..."
       9  for i in $(seq 1 30); do
       6 -  # Prism mock returns 404 on / and non-existent paths, so chec
         -k the spec root                                                
       7 -  # or any well-known API path that exists in the served OpenAP
         -I document                                                     
       8 -  if curl -s -o /dev/null "${PRISM_URL:-http://prism:4010}/api/
         -iam/v4.0/authz/roles" 2>/dev/null; then                        
       9 -    echo "Prism is ready (API path ok)!"                       
      10 +  # -f fails the request on 4xx/5xx, so this only passes once P
         +rism is actually                                               
      11 +  # serving the right spec (not merely listening on the TCP por
         +t).                                                            
      12 +  if curl -sf -o /dev/null "${PRISM_URL:-http://prism:4010}${RE
         +ADY_PATH}" 2>/dev/null; then                                   
      13 +    echo "Prism is ready (${READY_PATH} -> 200)!"              
      14      break
      15    fi
      16    echo "  attempt ${i}/30 - waiting..."

● Now rewrite docker-compose.yml with per-version Prism + emulator services:

● Write(stoplight_mock/docker-compose.yml)
  ⎿  Added 82 lines, removed 2 lines
       1 +# ─────────────────────────────────────────────────────────────
         +────────────────                                               
       2 +# Nutanix v4 API mock stack — one Prism mock + one stateful emu
         +lator per API                                                  
       3 +# version (v4.0, v4.1, v4.2, v4.3).                            
       4 +#                                                              
       5 +#   Service                Host port      Spec file (mounted fr
         +om ./spec)                                                     
       6 +#   ────────────────────   ─────────      ─────────────────────
         +───────────                                                    
       7 +#   prism        (v4.0)    127.0.0.1:4010  openapi.json        
       8 +#   prism-41     (v4.1)    127.0.0.1:4011  openapi-v4.1.json   
       9 +#   prism-42     (v4.2)    127.0.0.1:4012  openapi-v4.2.json   
      10 +#   prism-43     (v4.3)    127.0.0.1:4013  openapi-v4.3.json   
      11 +#                                                              
      12 +#   emulator     (v4.0)    0.0.0.0:9440   → prism        (API_V
         +ERSION=v4.0)                                                   
      13 +#   emulator-41  (v4.1)    0.0.0.0:9441   → prism-41     (API_V
         +ERSION=v4.1)                                                   
      14 +#   emulator-42  (v4.2)    0.0.0.0:9442   → prism-42     (API_V
         +ERSION=v4.2)                                                   
      15 +#   emulator-43  (v4.3)    0.0.0.0:9443   → prism-43     (API_V
         +ERSION=v4.3)                                                   
      16 +# ─────────────────────────────────────────────────────────────
         +────────────────                                               
      17 +                                                               
      18  services:
       2 -  # Stoplight Prism: OpenAPI schema-valid mock server          
      19 +  # ── v4.0 ───────────────────────────────────────────────────
         +───────────────                                                
      20    prism:
      21      image: stoplight/prism:5
      22      command: "mock -h 0.0.0.0 -p 4010 -m false /spec/openapi.js
          on"
     ...
       26        - "127.0.0.1:4010:4010"
       27      restart: unless-stopped
       28  
       12 -  # Stateful Node.js shim: VM CRUD + task polling             
       29    emulator:
       30      build: ./mock
       31      ports:
       32        - "0.0.0.0:9440:9440"
       33      environment:
       34        - PRISM_URL=http://prism:4010
       35 +      - API_VERSION=v4.0                                      
       36      depends_on:
       37        - prism
       38      restart: unless-stopped
       39 +                                                              
       40 +  # ── v4.1 ──────────────────────────────────────────────────
          +────────────────                                              
       41 +  prism-41:                                                   
       42 +    image: stoplight/prism:5                                  
       43 +    command: "mock -h 0.0.0.0 -p 4010 -m false /spec/openapi-v
          +4.1.json"                                                     
       44 +    volumes:                                                  
       45 +      - ./spec:/spec:ro                                       
       46 +    ports:                                                    
       47 +      - "127.0.0.1:4011:4010"                                 
       48 +    restart: unless-stopped                                   
       49 +                                                              
       50 +  emulator-41:                                                
       51 +    build: ./mock                                             
       52 +    ports:                                                    
       53 +      - "0.0.0.0:9441:9440"                                   
       54 +    environment:                                              
       55 +      - PRISM_URL=http://prism-41:4010                        
       56 +      - API_VERSION=v4.1                                      
       57 +    depends_on:                                               
       58 +      - prism-41                                              
       59 +    restart: unless-stopped                                   
       60 +                                                              
       61 +  # ── v4.2 ──────────────────────────────────────────────────
          +────────────────                                              
       62 +  prism-42:                                                   
       63 +    image: stoplight/prism:5                                  
       64 +    command: "mock -h 0.0.0.0 -p 4010 -m false /spec/openapi-v
          +4.2.json"                                                     
       65 +    volumes:                                                  
       66 +      - ./spec:/spec:ro                                       
       67 +    ports:                                                    
       68 +      - "127.0.0.1:4012:4010"                                 
       69 +    restart: unless-stopped                                   
       70 +                                                              
       71 +  emulator-42:                                                
       72 +    build: ./mock                                             
       73 +    ports:                                                    
       74 +      - "0.0.0.0:9442:9440"                                   
       75 +    environment:                                              
       76 +      - PRISM_URL=http://prism-42:4010                        
       77 +      - API_VERSION=v4.2                                      
       78 +    depends_on:                                               
       79 +      - prism-42                                              
       80 +    restart: unless-stopped                                   
       81 +                                                              
       82 +  # ── v4.3 ──────────────────────────────────────────────────
          +────────────────                                              
       83 +  prism-43:                                                   
       84 +    image: stoplight/prism:5                                  
       85 +    command: "mock -h 0.0.0.0 -p 4010 -m false /spec/openapi-v
          +4.3.json"                                                     
       86 +    volumes:                                                  
       87 +      - ./spec:/spec:ro                                       
       88 +    ports:                                                    
       89 +      - "127.0.0.1:4013:4010"                                 
       90 +    restart: unless-stopped                                   
       91 +                                                              
       92 +  emulator-43:                                                
       93 +    build: ./mock                                             
       94 +    ports:                                                    
       95 +      - "0.0.0.0:9443:9440"                                   
       96 +    environment:                                              
       97 +      - PRISM_URL=http://prism-43:4010                        
       98 +      - API_VERSION=v4.3                                      
       99 +    depends_on:                                               
      100 +      - prism-43                                              
      101 +    restart: unless-stopped                                   

  Thought for 3s (ctrl+o to expand)

● Now validate the changes:

  Thought for 41s, ran 2 shell commands (ctrl+o to expand)

● All syntax checks pass. Now let me do an end-to-end verification by building
  and starting just the v4.3 pair (free ports 4013/9443, no conflict with the
  running v4.0 stack or the manual focused_jang prism on 4011):

  Ran 1 shell command (ctrl+o to expand)

❯ explain the different types of test scripts inside stoplight_mock/scripts,    
  and can we consolidate all the test script into one, so that while testing -  
  two modes are available - VERBOSE vs non VERBOSE.   for VERBOSE mode please   
  print all the HTTP requests in details together with the PATH or URL.         
  provide option to test the different minor version of the v4 as well.         

  Thought for 1m 21s, ran 1 shell command (ctrl+o to expand)

● The v4.3 pair works end-to-end. Let me tear down those two verification
  containers to leave a clean state, and check a couple of spec details needed
  for the consolidated test script:
  Thought for 2m 7s, searched for 1 pattern, ran 5 shell commands (ctrl+o to expand)

● All specs enforce the NTNX-Request-Id header (uppercase) and If-Match. I now
  have everything I need. Let me write the consolidated test script.

  First, let me explain what I found, then build it.

  Thought for 2s, ran 1 shell command (ctrl+o to expand)

● Write(stoplight_mock/scripts/test.sh)
  ⎿  Wrote 362 lines to stoplight_mock/scripts/test.sh
       1 #!/usr/bin/env bash
         ───────────────
       3 # Consolidated Nutanix v4 mock-stack test runner.
       4 #
       6 #   * prism-test.sh      — Prism schema-mock + request-validatio
         n checks
         ecks
       8 #   * test-emulator.sh   — full emulator lifecycle (VM, networki
         ng, VG, RP, proxy)
      10 #
     … +429 lines (ctrl+o to expand)

  Thought for 26s, ran 1 shell command (ctrl+o to expand)

● The --help range is brittle and leaks code lines. Let me fix usage() to print
  only the header comment block:

● Update(stoplight_mock/scripts/test.sh)
  ⎿  Added 3 lines, removed 1 line
      37  VERSION="v4.0"
      38  
      39  usage() {
      40 -  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'                   
      40 +  # Print the contiguous header comment block (lines starting w
         +ith '#'), minus                                                
      41 +  # the leading '#', stopping at the first blank line / code li
         +ne.                                                            
      42 +  awk 'NR==1 {next} { if (substr($0,1,1)=="#") { sub(/^# ?/, ""
         +); print } else exit }' "$0"                                   
      43  }
      44  
      45  while [[ $# -gt 0 ]]; do

  Thought for 1s, ran 1 shell command (ctrl+o to expand)

● Now run the full suite against the running v4.0 stack (quiet mode):

  Thought for 2m 51s, read 1 file, ran 7 shell commands (ctrl+o to expand)

● Background command "Run consolidated test in quiet mode against v4.0" failed
with exit code 144

● Found it — a classic bash shift bug: shift 6 when only 5 args are present is a
  silent no-op, so $@ leaked old positional args into curl. I'll make the
  optional-body handling robust:

● Update(stoplight_mock/scripts/test.sh)
  ⎿  Added 5 lines, removed 1 line
      112  #   Runs the request, sets RESP_CODE / RESP_BODY, and (in verb
           ose mode) prints
      113  #   the full request + response detail.
      114  req() {
      115 -  local method="$1" url="$2" body="${3:-}"; shift 3           
      115 +  local method="$1" url="$2" body=""                          
      116 +  shift 2                                                     
      117 +  # Optional 3rd positional is the request body; anything afte
          +r that (or any                                                
      118 +  # leading '-flag') is passed straight through to curl.      
      119 +  if [[ $# -gt 0 && "${1:-}" != -* ]]; then body="$1"; shift; 
          +fi                                                            
      120    local args=(-sk -o "$TMP/body" -w '%{http_code}' -X "$method
           ")
      121    [[ -n "$body" ]] && args+=(-H 'Content-Type: application/jso
           n' -d "$body")
      122    args+=("$@")

● Update(stoplight_mock/scripts/test.sh)
  ⎿  Added 3 lines, removed 1 line
      140  
      141  # check DESC METHOD URL EXPECTED_CODE [BODY] [EXTRA...]
      142  check() {
      143 -  local desc="$1" method="$2" url="$3" expected="$4" body="${5
          -:-}"; shift 5                                                 
      143 +  local desc="$1" method="$2" url="$3" expected="$4" body=""  
      144 +  shift 4                                                     
      145 +  if [[ $# -gt 0 && "${1:-}" != -* ]]; then body="$1"; shift; 
          +fi                                                            
      146    req "$method" "$url" "$body" "$@"
      147    if [[ "$RESP_CODE" == "$expected" ]]; then
      148      green "$desc (HTTP $RESP_CODE)"

● Update(stoplight_mock/scripts/test.sh)
  ⎿  Added 3 lines, removed 1 line
      154  
      155  # check_body DESC METHOD URL EXPECTED_CODE PATTERN [BODY] [EXT
           RA...]
      156  check_body() {
      157 -  local desc="$1" method="$2" url="$3" expected="$4" pattern="
          -$5" body="${6:-}"; shift 6                                    
      157 +  local desc="$1" method="$2" url="$3" expected="$4" pattern="
          +$5" body=""                                                   
      158 +  shift 5                                                     
      159 +  if [[ $# -gt 0 && "${1:-}" != -* ]]; then body="$1"; shift; 
          +fi                                                            
      160    req "$method" "$url" "$body" "$@"
      161    if [[ "$RESP_CODE" == "$expected" ]] && grep -q "$pattern" <
           <<"$RESP_BODY"; then
      162      green "$desc (HTTP $RESP_CODE, body matches '$pattern')"

  Thought for 7s, ran 1 shell command (ctrl+o to expand)

● All 52 checks pass. Now verify verbose mode output (showing the detailed HTTP
  request blocks) and version selection against v4.3:

  Thought for 4s, ran 1 shell command (ctrl+o to expand)

● Verbose mode works. Now verify version selection against v4.3 (bring up the
  pair, test, tear down):

  Thought for 16s, ran 1 shell command (ctrl+o to expand)

● The v4.3 run failed only because I didn't wait for the freshly-started
  containers to become ready (Prism needs to parse the 17MB spec, then the
  emulator's entrypoint waits + generates its TLS cert). Let me re-run with a
  proper readiness poll:

  Thought for 16s, ran 1 shell command (ctrl+o to expand)

● Both versions pass (v4.0: 52/52, v4.3: 50/50). Now let me mark the old scripts
  as superseded and update the architecture doc to reflect the new
  multi-version stack:

● Update(stoplight_mock/scripts/prism-test.sh)
  ⎿  Added 1 line
      1  #!/usr/bin/env bash
      2 +# DEPRECATED: superseded by scripts/test.sh (run `./scripts/test
        +.sh` instead).                                                  
      3  # ─── Prism Mock Server Test (stoplight_mock-prism-1) ──────────
         ────────────────
      4  # Verifies the Stoplight Prism container is up and serving schem
         a-valid mock
      5  # responses on http://localhost:4010.

● Update(stoplight_mock/scripts/smoke-test.sh)
  ⎿  Added 1 line
      1  #!/usr/bin/env bash
      2 +# DEPRECATED: superseded by scripts/test.sh (run `./scripts/test
        +.sh` instead).                                                  
      3  # ─── Nutanix Emulator Smoke Test ──────────────────────────────
         ────────────────
      4  # Verifies the emulator shim is running and correctly handling V
         M CRUD + tasks.
      5  #

● Update(stoplight_mock/scripts/test-emulator.sh)
  ⎿  Added 1 line
      1  #!/usr/bin/env bash
      2 +# DEPRECATED: superseded by scripts/test.sh (run `./scripts/test
        +.sh` instead).                                                  
      3  # ─── Emulator container test: stoplight_mock-emulator-1 ───────
         ───────────────
      4  # Verifies the Nutanix emulator shim (and its Prism upstream) is
          working:
      5  #   health endpoint, seed data, VM lifecycle, networking resourc
         es,

● Update(stoplight_mock/ARCHITECTURE.md)
  ⎿  Added 23 lines, removed 6 lines
      51  
      52  File: `docker-compose.yml`
      53  
      54 -| Service   | Image / build       | Port   | Role |            
      55 -|-----------|---------------------|--------|------|            
      56 -| `prism`   | `stoplight/prism:5` | `4010` | OpenAPI mock serve
         -r. Command: `mock -h 0.0.0.0 -p 4010 -m false /spec/openapi.jso
         -n`. Mounts `./spec:/spec:ro`. `-m false` disables dynamic reque
         -st mocking so it serves static examples. |                     
      57 -| `emulator`| build `./mock`      | `9440` | Stateful Node.js s
         -him. `PRISM_URL=http://prism:4010` env var points at Prism. `de
         -pends_on: prism`. Restart policy `unless-stopped`. |           
      54 +The stack now mocks **four** Nutanix v4 minor versions side-by-
         +side — one                                                     
      55 +Prism (schema-only) mock plus one stateful emulator per version
         +, each on its                                                  
      56 +own host port:                                                 
      57  
      58 +| Version | Prism service | Prism host port | Emulator service 
         +| Emulator host port |                                         
      59 +|---------|---------------|-----------------|------------------
         +|--------------------|                                         
      60 +| v4.0    | `prism`       | `127.0.0.1:4010`| `emulator`       
         +| `0.0.0.0:9440`     |                                         
      61 +| v4.1    | `prism-41`    | `127.0.0.1:4011`| `emulator-41`    
         +| `0.0.0.0:9441`     |                                         
      62 +| v4.2    | `prism-42`    | `127.0.0.1:4012`| `emulator-42`    
         +| `0.0.0.0:9442`     |                                         
      63 +| v4.3    | `prism-43`    | `127.0.0.1:4013`| `emulator-43`    
         +| `0.0.0.0:9443`     |                                         
      64 +                                                               
      65 +Each `prism*` service runs `stoplight/prism:5` with            
      66 +`mock -h 0.0.0.0 -p 4010 -m false /spec/openapi{,-v4.1,-v4.2,-v
         +4.3}.json`                                                     
      67 +(mounts `./spec:/spec:ro`; `-m false` serves static examples, n
         +ot dynamic                                                     
      68 +request mocking). Each `emulator*` service builds `./mock`, exp
         +oses internal                                                  
      69 +port `9440`, and sets two env vars:                            
      70 +                                                               
      71 +* `PRISM_URL` — points at its matching Prism (e.g. `http://pris
         +m-41:4010`).                                                   
      72 +* `API_VERSION` — the minor version (`v4.0` … `v4.3`) used to b
         +uild the                                                       
      73 +  `/api/{ns}/{version}/...` paths and to select the AHV VM path
         + shape                                                         
      74 +  (`/api/vmm/v4.x/ahv/config/vms` for v4.1+).                  
      75 +                                                               
      76  Note: the older `tmp/README.md` also describes a `terraform` se
          rvice, but the
      60 -current `docker-compose.yml` only defines `prism` and `emulator
         -`. Terraform is                                                
      61 -now invoked from the host or via the helper scripts in `tmp/`. 
      77 +current `docker-compose.yml` only defines the Prism + emulator 
         +pairs. Terraform                                               
      78 +is now invoked from the host or via the helper scripts in `tmp/
         +`.                                                             
      79  
      80  ---
      81  

  Thought for 2s (ctrl+o to expand)
● Update(stoplight_mock/ARCHITECTURE.md)
  ⎿  Added 7 lines, removed 5 lines
      212  
      213  | Path | Purpose |
      214  |------|---------|
      215 -| `docker-compose.yml`        | Defines `prism` + `emulator` s
          -ervices |                                                     
      216 -| `spec/openapi.json`         | Merged OpenAPI 3.0.1 spec cons
          -umed by Prism (487 paths, 2206 schemas) |                     
      215 +| `docker-compose.yml`        | Defines 4 Prism + 4 emulator s
          +ervices (§2), one pair per v4 minor version |                 
      216 +| `spec/openapi.json`         | Merged v4.0 spec consumed by `
          +prism` (487 paths, 2206 schemas) |                            
      217 +| `spec/openapi-v4.{1,2,3}.json` | Merged v4.1/v4.2/v4.3 specs
          + consumed by `prism-41/42/43` |                               
      218  | `scripts/merge-specs.js`    | Builds `spec/openapi.json` fro
           m the per-namespace YAML in `mock/v40/` |
      219 +| `scripts/merge_specs.py`    | Builds `spec/openapi-v4.{1,2,3
          +}.json` from `nutanix_swagger/` |                             
      220  | `myrun.sh`                  | Helper that runs `merge-specs.
           js` in a `node:20-alpine` container and restarts Prism |
      221  | `mock/Dockerfile`           | `node:20-alpine` + curl + open
           ssl; copies `server.js`, exposes 9440, healthcheck |
      220 -| `mock/entrypoint.sh`        | Waits for Prism readiness, gen
          -erates self-signed TLS cert, execs `node server.js` |         
      221 -| `mock/server.js`            | The stateful shim (all routes 
          -in §4) + Prism catch-all proxy |                              
      222 +| `mock/entrypoint.sh`        | Waits for Prism readiness (ver
          +sion-aware probe), generates self-signed TLS cert, execs `node
          + server.js` |                                                 
      223 +| `mock/server.js`            | The stateful shim (all routes 
          +in §4) + Prism catch-all proxy; `API_VERSION` env selects the 
          +version |                                                     
      224  | `mock/package.json`         | Dependencies: `express`, `uuid
           `, `http-proxy-middleware` |
      223 -| `scripts/smoke-test.sh`     | Curl-based integration test: h
          -ealth, seed data, VM CRUD lifecycle, path variants |          
      225 +| `scripts/test.sh`           | Consolidated test runner (§7) 
          +— replaces `prism-test.sh`, `smoke-test.sh`, `test-emulator.sh
          +` |                                                           
      226  
      227  ---
      228  

  Thought for 5s, read 1 file (ctrl+o to expand)

● Update(stoplight_mock/ARCHITECTURE.md)
  ⎿  Added 28 lines
      244  - **`./terraform`** configuration referenced by `tmp/README.md
           ` lives under
      245    `tmp/terraform/` and `tmp/terraform-network/`, not in the to
           p-level
      246    `docker-compose.yml`.
      247 +                                                              
      248 +---                                                           
      249 +                                                              
      250 +## 7. Consolidated test runner                                
      251 +                                                              
      252 +File: `scripts/test.sh` — replaces `prism-test.sh`, `smoke-tes
          +t.sh` and                                                     
      253 +`test-emulator.sh` with a single script that covers the Prism 
          +mock, the                                                     
      254 +emulator lifecycle (VM CRUD + tasks, networking, volume groups
          +, recovery                                                    
      255 +points) and the Prism catch-all proxy.                        
      256 +                                                              
      257 +Two output modes:                                             
      258 +                                                              
      259 +* **quiet** (default) — one `✓`/`✗` line per check plus a summ
          +ary.                                                          
      260 +* **`--verbose` / `-v`** — additionally prints every HTTP requ
          +est in detail:                                                
      261 +  method, full URL, headers, body, response status and respons
          +e body.                                                       
      262 +                                                              
      263 +Version selection via `--version` (default `v4.0`; also accept
          +s `4.1`,                                                      
      264 +`v4.1.0`, …), which maps to the matching Prism/emulator host p
          +orts in §2:                                                   
      265 +                                                              
      266 +```                                                           
      267 +./scripts/test.sh                       # v4.0, quiet         
      268 +./scripts/test.sh --version v4.3 --verbose                    
      269 +./scripts/test.sh -V 4.1                                      
      270 +```                                                           
      271 +                                                              
      272 +Exit code = number of failed checks. The v4.0 run also exercis
          +es the legacy                                                 
      273 +`v4.0.a1` / bare `/v4.0/` path variants; v4.1+ use the canonic
          +al                                                            
      274 +`/api/vmm/v4.x/ahv/config/vms` AHV path.                      

  Thought for 5s (ctrl+o to expand)

● Let me do a final verification of the environment state and a quick review of
  all changes:

  Thought for 13s, ran 1 shell command (ctrl+o to expand)

● Done. Both requests are complete and verified. Here's the summary.

  1. Multi-version mock (your original ask)

  The emulator was hardcoded to v4.0 paths. I made the version a runtime setting
  and added one Prism + one emulator per minor version.

  mock/server.js — now reads API_VERSION (default v4.0), and builds every path
  from it. Key detail: v4.1+ AHV VMs live under /api/vmm/v4.x/ahv/config/vms
  (not the v4.0 …/v4.0/config/vms variants), so I special-cased that. v4.0 keeps
  its legacy v4.0.a1 / bare / v4.0/ahv variants unchanged.

  mock/entrypoint.sh — readiness probe is now version-aware (was hardcoded to
  the v4.0-only iam path).

  docker-compose.yml — now 8 services:

  ┌─────────┬────────────────┬───────────────────┬───────────────────┐
  │ Version │  Prism (host)  │  Emulator (host)  │       Spec        │
  ├─────────┼────────────────┼───────────────────┼───────────────────┤
  │ v4.0    │ prism :4010    │ emulator :9440    │ openapi.json      │
  ├─────────┼────────────────┼───────────────────┼───────────────────┤
  │ v4.1    │ prism-41 :4011 │ emulator-41 :9441 │ openapi-v4.1.json │
  ├─────────┼────────────────┼───────────────────┼───────────────────┤
  │ v4.2    │ prism-42 :4012 │ emulator-42 :9442 │ openapi-v4.2.json │
  ├─────────┼────────────────┼───────────────────┼───────────────────┤
  │ v4.3    │ prism-43 :4013 │ emulator-43 :9443 │ openapi-v4.3.json │
  └─────────┴────────────────┴───────────────────┴───────────────────┘

  Each emulator gets API_VERSION + the matching PRISM_URL. I verified the v4.3
  pair end-to-end (50/50 checks pass).

  ⚠️ One conflict: focused_jang is a manually-docker run prism already holding
  host port 4011. Stop it before docker compose up -d --build, or prism-41 won't
  bind.

  2. The test scripts

  What's there today (stoplight_mock/scripts/):

  ┌─────────────────────┬───────────────────────────────────────────────────┐
  │       Script        │                   What it tests                   │
  ├─────────────────────┼───────────────────────────────────────────────────┤
  │                     │ Prism only — schema-valid mock responses, request │
  │ prism-test.sh       │  validation (required NTNX-Request-Id header,     │
  │                     │ invalid-UUID → 422)                               │
  ├─────────────────────┼───────────────────────────────────────────────────┤
  │ smoke-test.sh       │ Emulator basics — health, seed data, VM           │
  │                     │ create/poll/get/update/delete                     │
  ├─────────────────────┼───────────────────────────────────────────────────┤
  │                     │ Emulator full lifecycle — VMs + tasks, networking │
  │ test-emulator.sh    │  (subnet/VPC/FIP/NSP), volume groups, recovery    │
  │                     │ points, Prism proxy                               │
  ├─────────────────────┼───────────────────────────────────────────────────┤
  │ merge-specs.js /    │ not tests — build tools that generate the merged  │
  │ merge_specs.py      │ spec JSON                                         │
  └─────────────────────┴───────────────────────────────────────────────────┘

  New: scripts/test.sh consolidates all three test scripts into one, with:

  - --verbose / -v — prints every HTTP request in detail (method, full URL,
  headers, body, status, response body). Default is one ✓/✗ line per check + a
  summary.
  - --version v4.0|v4.1|v4.2|v4.3 — also accepts 4.1, v4.1.0, etc.; auto-derives
  the right Prism/emulator ports. Covers Prism validation, VM lifecycle,
  networking, volume groups, recovery points, and the proxy.

  ./scripts/test.sh                          # v4.0, quiet
  ./scripts/test.sh --version v4.3 --verbose
  ./scripts/test.sh -V 4.1

  The old three scripts are now marked DEPRECATED (not deleted).

  Verification: 52/52 pass on v4.0, 50/50 on v4.3 (v4.0 has 2 extra legacy-path
  checks). Exit code = number of failed checks.

  One operational note: the emulator takes ~25s to become ready on first start
  (Prism parses the large spec, then the entrypoint generates its self-signed
  TLS cert). My verification polls https://localhost:944x/health until 200
  first.

  I also updated ARCHITECTURE.md to document the new multi-version compose
  layout (§2), the version-aware emulator (§5), and the test runner (§7).

✻ Baked for 22m 29s

❯ running "./scripts/test.sh --version v4.0 --verbose" result in errors as      
  captured in /tmp/error.log                                                    

  Thought for 27s, read 1 file (ctrl+o to expand)

● Found it — a real bug in verbose mode. The req function prints its verbose
  HTTP detail to stdout, but section 2 calls it inside $(req …; echo … | jget 
  …), so the whole HTTP block gets captured into $N and breaks the [[ "$N" -ge 1
  ]] arithmetic test. (That's why quiet mode passed 52/52 but verbose errored.)

  The fix: diagnostic output belongs on stderr, not stdout:

● Update(stoplight_mock/scripts/test.sh)
  ⎿  Added 14 lines, removed 10 lines
      124    RESP_CODE="$(curl "${args[@]}" "$url" 2>&1)" || RESP_CODE="c
           url-error"
      125    RESP_BODY="$(cat "$TMP/body" 2>/dev/null)"
      126  
      127 +  # Verbose detail goes to STDERR (not stdout) so that `req` c
          +an be used inside                                             
      128 +  # `$(...)` without the HTTP trace being captured into a vari
          +able.                                                         
      129    if [[ "$VERBOSE" == "1" ]]; then
      128 -    printf '──────────────────────────────────────────────────
          -──────────\n'                                                 
      129 -    printf '  REQUEST\n'                                      
      130 -    printf '    method:  %s\n' "$method"                      
      131 -    printf '    url:     %s\n' "$url"                         
      132 -    [[ -n "$body" ]] && printf '    body:    %s\n' "$body"    
      133 -    [[ $# -gt 0 ]] && printf '    headers: %s\n' "$*"         
      134 -    printf '  RESPONSE\n'                                     
      135 -    printf '    status:  %s\n' "$RESP_CODE"                   
      136 -    printf '    body:    %s\n' "${RESP_BODY:-<empty>}"        
      137 -    printf '──────────────────────────────────────────────────
          -──────────\n'                                                 
      130 +    {                                                         
      131 +      printf '────────────────────────────────────────────────
          +────────────\n'                                               
      132 +      printf '  REQUEST\n'                                    
      133 +      printf '    method:  %s\n' "$method"                    
      134 +      printf '    url:     %s\n' "$url"                       
      135 +      [[ -n "$body" ]] && printf '    body:    %s\n' "$body"  
      136 +      [[ $# -gt 0 ]] && printf '    headers: %s\n' "$*"       
      137 +      printf '  RESPONSE\n'                                   
      138 +      printf '    status:  %s\n' "$RESP_CODE"                 
      139 +      printf '    body:    %s\n' "${RESP_BODY:-<empty>}"      
      140 +      printf '────────────────────────────────────────────────
          +────────────\n'                                               
      141 +    } >&2                                                     
      142    fi
      143  }
      144  

  Thought for 9s (ctrl+o to expand)

● Now verify the fix by re-running verbose mode against the still-running v4.0
  stack:

  Thought for 15s, searched for 1 pattern, ran 2 shell commands (ctrl+o to expand)

● Fixed. The bug and the fix:

  Root cause — the req function printed its verbose HTTP trace to stdout.
  Section 2's seed-count checks call it inside command substitution:

  N="$(req GET "$EMU$SUBNETS"; echo "$RESP_BODY" | jget 
  metadata.totalAvailableResults)"
  [[ "$N" -ge 1 ]] && ...

  In verbose mode the whole multi-line HTTP block got captured into $N along
  with the number, so [[ "$N" -ge 1 ]] failed with syntax error: operand 
  expected. Quiet mode never hit it because req printed nothing.

  Fix — the verbose HTTP detail now writes to stderr ({ … } >&2) instead of
  stdout, so req can be used inside $(...) without the trace being captured.
  This is the correct convention anyway (diagnostic output on stderr, data on
  stdout).

  Verified:

  Results: 52 passed, 0 failed    (exit 0)
  ✓ seed subnet present (3)
  ✓ seed images present (2)

  No more bash syntax errors in verbose mode. The fix is only in
  scripts/test.sh; the server.js, docker-compose.yml, and multi-version changes
  from before are untouched and still valid.

✻ Sautéed for 1m 28s

※ recap: Goal: mock all Nutanix v4 minor versions (v4.0–v4.3) and consolidate tests into one script. Done and verified: 8 docker-compose services plus scripts/test.sh with verbose/version modes, all tests passing. Next: stop focused_jang and run docker compose up -d --build. (disable recaps in /config)

❯ how to start the docker to mock all version of v4                             

  Thought for 20s, ran 1 shell command (ctrl+o to expand)

● Start the multi-version mock stack

  cd /home/ubuntu/libcloud_nutanix/stoplight_mock

  # 1. Remove the leftover manual v4.3 Prism — it's holding port 4011 that
  #    prism-41 needs (started as a one-off `docker run`, not by compose).
  docker rm -f focused_jang

  # 2. Build + start all 8 services (4 Prism + 4 emulator)
  docker compose up -d --build

  # 3. Wait ~30s, then confirm
  docker compose ps

  What gets started

  ┌─────────┬──────────────────────────┬────────────────────────┐
  │ Version │ Prism (schema-only mock) │  Emulator (stateful)   │
  ├─────────┼──────────────────────────┼────────────────────────┤
  │ v4.0    │ http://localhost:4010    │ https://localhost:9440 │
  ├─────────┼──────────────────────────┼────────────────────────┤
  │ v4.1    │ http://localhost:4011    │ https://localhost:9441 │
  ├─────────┼──────────────────────────┼────────────────────────┤
  │ v4.2    │ http://localhost:4012    │ https://localhost:9442 │
  ├─────────┼──────────────────────────┼────────────────────────┤
  │ v4.3    │ http://localhost:4013    │ https://localhost:9443 │
  └─────────┴──────────────────────────┴────────────────────────┘

  - Point clients at the emulator (944x) for full stateful behavior
  (VM/subnet/VPC CRUD, task polling). It proxies unmatched paths to its Prism.
  - Point at Prism (401x) for the pure schema-valid example mock.

  Verify

  ./scripts/test.sh --version v4.0
  ./scripts/test.sh --version v4.1
  ./scripts/test.sh --version v4.2
  ./scripts/test.sh --version v4.3
  # or all four with verbose HTTP tracing:
  ./scripts/test.sh -v -V v4.3

  Stop it

  docker compose down          # stop + remove all 8 containers
  docker compose stop          # stop but keep containers

  Two notes:

  1. focused_jang must go first — it's a manually docker run Prism serving
  openapi-v4.3.json on 127.0.0.1:4011, which collides with prism-41. docker 
  compose up will fail to bind 4011 until it's removed.
  2. ~25s first-start delay — the emulators wait for their Prism to parse the
  (large) spec, then generate a self-signed TLS cert before listening. The
  test.sh emulator checks will hit curl-error until then; the Prism checks are
  ready sooner.

  Want me to run these commands now (including removing focused_jang)?

✻ Churned for 28s

❯ docker compose up -d                                                          

  Thought for 44s, ran 2 shell commands (ctrl+o to expand)

● docker compose up -d mostly succeeded, but prism-41 (v4.1) failed to start —
  exactly the port conflict I flagged:

  Error response from daemon: ... Bind for 127.0.0.1:4011 failed: port is
  already allocated

  focused_jang (your manual docker run Prism serving v4.3) still holds
  127.0.0.1:4011.

  Current state:

  ┌─────────┬────────────┬──────────────────────────┐
  │ Version │   Prism    │         Emulator         │
  ├─────────┼────────────┼──────────────────────────┤
  │ v4.0    │ ✅ :4010   │ ✅ :9440                 │
  ├─────────┼────────────┼──────────────────────────┤
  │ v4.1    │ ❌ blocked │ ❌ (depends on prism-41) │
  ├─────────┼────────────┼──────────────────────────┤
  │ v4.2    │ ✅ :4012   │ ✅ :9442                 │
  ├─────────┼────────────┼──────────────────────────┤
  │ v4.3    │ ✅ :4013   │ ✅ :9443                 │
  └─────────┴────────────┴──────────────────────────┘

  To finish, remove focused_jang (it's now redundant — compose's prism-43
  already serves v4.3 on :4013) and bring up the v4.1 pair:

  docker rm -f focused_jang
  docker compose up -d

  Want me to run that now?

✻ Churned for 1m 14s

❯ yes                                                                           

  Thought for 6s, ran 1 shell command (ctrl+o to expand)

● The auto-mode classifier blocked me from deleting focused_jang — it's a
  container I didn't create this session, and removing it is a destructive
  action, so it needs your explicit go-ahead naming that container.

  Two ways to proceed:

  Option A — run it yourself (type this into the prompt; the ! prefix runs it
  in-session):

  ! docker rm -f focused_jang && docker compose up -d

  Option B — authorize me by replying with something like "remove focused_jang 
  and start the v4.1 pair" (naming the container), and I'll run it.

  After focused_jang is removed, docker compose up -d will start the missing
  prism-41 and emulator-41, giving you all four versions. Everything else is
  already up.

✻ Worked for 29s

※ recap: Goal: run Docker mocks for all four Nutanix v4 API versions. v4.0, v4.2, and v4.3 are up; v4.1 is blocked by the manual `focused_jang` container holding port 4011. Next: remove it and run `docker compose up -d`. (disable recaps in /config)

! docker rm -f focused_jang && docker compose up -d                             
  ⎿  focused_jang
      Container stoplight_mock-emulator-43-1 Running
      Container stoplight_mock-prism-1 Running
      Container stoplight_mock-prism-42-1 Running
      Container stoplight_mock-emulator-1 Running
      Container stoplight_mock-prism-43-1 Running
      Container stoplight_mock-emulator-42-1 Running
      Container stoplight_mock-prism-41-1 Starting
      Container stoplight_mock-prism-41-1 Started
      Container stoplight_mock-emulator-41-1 Starting
      Container stoplight_mock-emulator-41-1 Started

  Thought for 12s, ran 1 shell command (ctrl+o to expand)

● All 8 services are up. Let me wait for the freshly-started v4.1 pair to finish
  its startup (~25s for Prism spec parse + TLS cert) and do a quick smoke check
  across all four versions:

  Thought for 22s, ran 2 shell commands (ctrl+o to expand)

● prism-41 is actually running and serving (its log shows "Prism is listening on
  http://0.0.0.0:4010"), but the host port mapping 127.0.0.1:4011→4010 never
  got re-applied — it was created during the failed first up (when 4011 was
  still held) and just "Started" without re-binding after you freed the port.
  Let me confirm and recreate it:
  Thought for 8s, ran 2 shell commands (ctrl+o to expand)

● All four versions are now up and mockable:

  ┌─────────┬──────────────────────────┬───────────────────────────┐
  │ Version │   Prism (schema mock)    │    Emulator (stateful)    │
  ├─────────┼──────────────────────────┼───────────────────────────┤
  │ v4.0    │ ✅ http://localhost:4010 │ ✅ https://localhost:9440 │
  ├─────────┼──────────────────────────┼───────────────────────────┤
  │ v4.1    │ ✅ http://localhost:4011 │ ✅ https://localhost:9441 │
  ├─────────┼──────────────────────────┼───────────────────────────┤
  │ v4.2    │ ✅ http://localhost:4012 │ ✅ https://localhost:9442 │
  ├─────────┼──────────────────────────┼───────────────────────────┤
  │ v4.3    │ ✅ http://localhost:4013 │ ✅ https://localhost:9443 │
  └─────────┴──────────────────────────┴───────────────────────────┘

  All four emulators are reporting healthy, and each Prism is serving its spec
  (v4.1's vmm list now returns 200 on :4011).

  The one snag along the way: prism-41's container was created during the first
  up (while focused_jang still held :4011), so after the port freed up it
  "Started" without re-applying its host-port binding. A --force-recreate fixed
  it — worth knowing if you ever hit a 000/connection-refused on a Prism port
  again.

  To verify everything end-to-end:

  cd /home/ubuntu/libcloud_nutanix/stoplight_mock
  for v in v4.0 v4.1 v4.2 v4.3; do ./scripts/test.sh --version "$v"; done

  Want me to run that full suite across all four versions now?

✻ Churned for 2m 3s

❯ yes                                                                           

  Thought for 8s, ran 1 shell command (ctrl+o to expand)

● All four versions pass end-to-end:

  ┌─────────┬────────────────────────┐
  │ Version │         Result         │
  ├─────────┼────────────────────────┤
  │ v4.0    │ ✅ 52 passed, 0 failed │
  ├─────────┼────────────────────────┤
  │ v4.1    │ ✅ 50 passed, 0 failed │
  ├─────────┼────────────────────────┤
  │ v4.2    │ ✅ 50 passed, 0 failed │
  ├─────────┼────────────────────────┤
  │ v4.3    │ ✅ 50 passed, 0 failed │
  └─────────┴────────────────────────┘

  (52 vs 50 is expected — v4.0 includes 2 extra checks for its legacy v4.0.a1 /
  bare path variants.)

  The full multi-version mock stack is up and verified: 4 Prism schema-mocks + 4
  stateful emulators, each covering VM CRUD/tasks, networking
  (subnets/VPCs/floating IPs/NSPs), volume groups, recovery points, and Prism
  proxy passthrough — all green.

✻ Sautéed for 41s

※ recap: Goal: mock all four Nutanix v4 API versions in stoplight_mock. Done and verified: all 8 containers running, tests pass (v4.0–v4.3, 0 failures). Next action: commit the changes when you're ready. (disable recaps in /config)

❯ split the test.sh into test_read.sh and test_write.sh where  test_read.sh     
  will cover all the READ-only enumeration or GET operations, whereas the       
  test_write.sh will cover the create/delete/update operation which can make    
  changes to the backend system.                                                

  Thought for 2m 2s, read 1 file (ctrl+o to expand)

● Now I'll split test.sh into a shared library plus read-only and write scripts.
  Starting with the shared harness:

● Write(stoplight_mock/scripts/lib.sh)
  ⎿  Wrote 180 lines to stoplight_mock/scripts/lib.sh
       1 #!/usr/bin/env bash
         ───────────────
       3 # Shared harness for test_read.sh / test_write.sh — SOURCE this 
       4 # execute it directly.
       5 #
         n URL + path
       7 # derivation, output helpers, the HTTP primitive (req), assertio
       8 # check_body), task polling, and the banner/summary helpers.
       9 #
         le.
     … +199 lines (ctrl+o to expand)

  Thought for 3s (ctrl+o to expand)

● Write(stoplight_mock/scripts/test_read.sh)
  ⎿  Wrote 73 lines to stoplight_mock/scripts/test_read.sh
       1 #!/usr/bin/env bash
         ───────────────
       3 # READ-ONLY test suite — enumeration + GET operations only.
       4 #
         on) and the
       6 # emulator's seed/reference data, without ever mutating backend 
       7 # No POST/PUT/DELETE is issued here.
       8 #
       9 # Usage:
         t
     … +87 lines (ctrl+o to expand)

  Thought for 4s (ctrl+o to expand)

● Write(stoplight_mock/scripts/test_write.sh)
  ⎿  Wrote 164 lines to stoplight_mock/scripts/test_write.sh
       1 #!/usr/bin/env bash
         ───────────────
       3 # WRITE test suite — create / update / delete (mutating operatio
       4 #
         VPC, floating
       6 # IP, NSP, volume group, recovery point) plus Prism's mutating-r
       7 # validation, then verifies the resulting state (including task 
         polling and
         n test_read.sh.
      10 # Usage:
     … +190 lines (ctrl+o to expand)

  Thought for 2s (ctrl+o to expand)

● Now turn test.sh into a thin wrapper that runs both:

● Write(stoplight_mock/scripts/test.sh)
  ⎿  Added 14 lines, removed 343 lines
       2  # ─────────────────────────────────────────────────────────────
          ────────────────
       3  # Consolidated Nutanix v4 mock-stack test runner.
       4  #
       5 +# Thin wrapper that runs the READ-ONLY suite (test_read.sh) the
         +n the WRITE                                                    
       6 +# suite (test_write.sh) back-to-back. For isolated runs, invoke
         + either script                                                 
       7 +# directly:                                                    
       8 +#   ./scripts/test_read.sh   — enumeration + GET operations onl
         +y (no mutations)                                               
       9 +#   ./scripts/test_write.sh  — create/update/delete (mutating) 
         +operations                                                     
      10 +#                                                              
      11  # Supersedes the three older, overlapping scripts:
      12  #   * prism-test.sh      — Prism schema-mock + request-validati
          on checks
      13  #   * smoke-test.sh      — basic emulator health/seed/VM-CRUD c
          hecks
     ...
       33  #   ./scripts/test.sh --version v4.3 --verbose
       34  #   ./scripts/test.sh -V 4.1
       35  #
       30 -# Exit code: number of failed checks (0 = all passed).        
       36 +# Exit code: total number of failed checks (0 = all passed).  
       37  # ────────────────────────────────────────────────────────────
           ─────────────────
       38  
       33 -set -uo pipefail                                              
       39 +set -u                                                        
       40 +DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"           
       41  
       35 -# ─── Defaults / arg parsing ─────────────────────────────────
          -──────────────────                                            
       36 -VERBOSE=0                                                     
       37 -VERSION="v4.0"                                                
       42 +"$DIR/test_read.sh"  "$@"                                     
       43 +R=$?                                                          
       44 +"$DIR/test_write.sh" "$@"                                     
       45 +W=$?                                                          
       46  
       39 -usage() {                                                     
       40 -  # Print the contiguous header comment block (lines starting 
          -with '#'), minus                                              
       41 -  # the leading '#', stopping at the first blank line / code l
          -ine.                                                          
       42 -  awk 'NR==1 {next} { if (substr($0,1,1)=="#") { sub(/^# ?/, "
          -"); print } else exit }' "$0"                                 
       43 -}                                                             
       44 -                                                              
       45 -while [[ $# -gt 0 ]]; do                                      
       46 -  case "$1" in                                                
       47 -    -v|--verbose) VERBOSE=1 ;;                                
       48 -    -V|--version) VERSION="${2:-}"; shift ;;                  
       49 -    -h|--help)    usage; exit 0 ;;                            
       50 -    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;  
       51 -  esac                                                        
       52 -  shift                                                       
       53 -done                                                          
       54 -                                                              
       55 -# Normalise the version token and derive the per-version ports
          -.                                                             
       56 -case "${VERSION#v}" in                                        
       57 -  4.0) MINOR=0; VERSION="v4.0" ;;                             
       58 -  4.1) MINOR=1; VERSION="v4.1" ;;                             
       59 -  4.2) MINOR=2; VERSION="v4.2" ;;                             
       60 -  4.3) MINOR=3; VERSION="v4.3" ;;                             
       61 -  *) echo "Unsupported version: '$VERSION' (supported: v4.0, v
          -4.1, v4.2, v4.3)" >&2; exit 2 ;;                              
       62 -esac                                                          
       63 -                                                              
       64 -PRISM="http://localhost:$((4010 + MINOR))"   # Prism   (schema
          --only mock)                                                   
       65 -EMU="https://localhost:$((9440 + MINOR))"    # Emulator (state
          -ful shim, self-signed)                                        
       66 -                                                              
       67 -# ─── Per-version resource paths ─────────────────────────────
          -─────────────────                                             
       68 -VM_LIST="/api/vmm/${VERSION}/ahv/config/vms"                  
       69 -TASKS="/api/prism/${VERSION}/config/tasks"                    
       70 -SUBNETS="/api/networking/${VERSION}/config/subnets"           
       71 -VPCS="/api/networking/${VERSION}/config/vpcs"                 
       72 -FIPS="/api/networking/${VERSION}/config/floating-ips"         
       73 -NSPS="/api/networking/${VERSION}/config/network-security-polic
          -ies"                                                          
       74 -CLUSTERS="/api/clustermgmt/${VERSION}/config/clusters"        
       75 -IMAGES="/api/vmm/${VERSION}/content/images"                   
       76 -SCS="/api/clustermgmt/${VERSION}/config/storage-containers"   
       77 -VGS="/api/volumes/${VERSION}/config/volume-groups"            
       78 -RPS="/api/dataprotection/${VERSION}/config/recovery-points"   
       79 -                                                              
       80 -# Seed extIds (same across all versions in the emulator).     
       81 -SEED_CLUSTER="00000000-0000-0000-0000-000000000001"           
       82 -SEED_SUBNET="00000000-0000-0000-0000-000000000002"            
       83 -                                                              
       84 -REQ_ID="11111111-2222-3333-4444-555555555555"                 
       85 -VALID_UUID="${SEED_CLUSTER}"                                  
       86 -                                                              
       87 -PASS=0                                                        
       88 -FAIL=0                                                        
       89 -TMP="$(mktemp -d)"                                            
       90 -trap 'rm -rf "$TMP"' EXIT                                     
       91 -                                                              
       92 -# ─── Output helpers ─────────────────────────────────────────
          -─────────────────                                             
       93 -green() { printf '\033[32m✓ %s\033[0m\n' "$*"; PASS=$((PASS+1)
          -); }                                                          
       94 -red()   { printf '\033[31m✗ %s\033[0m\n' "$*"; FAIL=$((FAIL+1)
          -); }                                                          
       95 -hdr()   { printf '\n\033[1;36m── %s ──\033[0m\n' "$*"; }      
       96 -dim()   { printf '\033[2m%s\033[0m\n' "$*"; }                 
       97 -                                                              
       98 -# jget DOTTED.PATH — extract a field from JSON on stdin ('' on
          - failure).                                                    
       99 -jget() {                                                      
      100 -  python3 -c 'import sys, json                                
      101 -d = json.load(sys.stdin)                                      
      102 -try:                                                          
      103 -    for k in sys.argv[1].split("."):                          
      104 -        d = d[int(k)] if isinstance(d, list) else d[k]        
      105 -    print(d if d is not None else "")                         
      106 -except Exception:                                             
      107 -    pass' "$1" 2>/dev/null                                    
      108 -}                                                             
      109 -                                                              
      110 -# ─── HTTP primitive ─────────────────────────────────────────
          -─────────────────                                             
      111 -# req METHOD URL [BODY] [EXTRA_CURL_ARGS...]                  
      112 -#   Runs the request, sets RESP_CODE / RESP_BODY, and (in verb
          -ose mode) prints                                              
      113 -#   the full request + response detail.                       
      114 -req() {                                                       
      115 -  local method="$1" url="$2" body=""                          
      116 -  shift 2                                                     
      117 -  # Optional 3rd positional is the request body; anything afte
          -r that (or any                                                
      118 -  # leading '-flag') is passed straight through to curl.      
      119 -  if [[ $# -gt 0 && "${1:-}" != -* ]]; then body="$1"; shift; 
          -fi                                                            
      120 -  local args=(-sk -o "$TMP/body" -w '%{http_code}' -X "$method
          -")                                                            
      121 -  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/jso
          -n' -d "$body")                                                
      122 -  args+=("$@")                                                
      123 -                                                              
      124 -  RESP_CODE="$(curl "${args[@]}" "$url" 2>&1)" || RESP_CODE="c
          -url-error"                                                    
      125 -  RESP_BODY="$(cat "$TMP/body" 2>/dev/null)"                  
      126 -                                                              
      127 -  # Verbose detail goes to STDERR (not stdout) so that `req` c
          -an be used inside                                             
      128 -  # `$(...)` without the HTTP trace being captured into a vari
          -able.                                                         
      129 -  if [[ "$VERBOSE" == "1" ]]; then                            
      130 -    {                                                         
      131 -      printf '────────────────────────────────────────────────
          -────────────\n'                                               
      132 -      printf '  REQUEST\n'                                    
      133 -      printf '    method:  %s\n' "$method"                    
      134 -      printf '    url:     %s\n' "$url"                       
      135 -      [[ -n "$body" ]] && printf '    body:    %s\n' "$body"  
      136 -      [[ $# -gt 0 ]] && printf '    headers: %s\n' "$*"       
      137 -      printf '  RESPONSE\n'                                   
      138 -      printf '    status:  %s\n' "$RESP_CODE"                 
      139 -      printf '    body:    %s\n' "${RESP_BODY:-<empty>}"      
      140 -      printf '────────────────────────────────────────────────
          -────────────\n'                                               
      141 -    } >&2                                                     
      142 -  fi                                                          
      143 -}                                                             
      144 -                                                              
      145 -# check DESC METHOD URL EXPECTED_CODE [BODY] [EXTRA...]       
      146 -check() {                                                     
      147 -  local desc="$1" method="$2" url="$3" expected="$4" body=""  
      148 -  shift 4                                                     
      149 -  if [[ $# -gt 0 && "${1:-}" != -* ]]; then body="$1"; shift; 
          -fi                                                            
      150 -  req "$method" "$url" "$body" "$@"                           
      151 -  if [[ "$RESP_CODE" == "$expected" ]]; then                  
      152 -    green "$desc (HTTP $RESP_CODE)"                           
      153 -  else                                                        
      154 -    red "$desc — expected $expected, got $RESP_CODE"          
      155 -    [[ "$VERBOSE" != "1" ]] && [[ -n "$RESP_BODY" ]] && dim " 
          -   body: ${RESP_BODY:0:300}"                                  
      156 -  fi                                                          
      157 -}                                                             
      158 -                                                              
      159 -# check_body DESC METHOD URL EXPECTED_CODE PATTERN [BODY] [EXT
          -RA...]                                                        
      160 -check_body() {                                                
      161 -  local desc="$1" method="$2" url="$3" expected="$4" pattern="
          -$5" body=""                                                   
      162 -  shift 5                                                     
      163 -  if [[ $# -gt 0 && "${1:-}" != -* ]]; then body="$1"; shift; 
          -fi                                                            
      164 -  req "$method" "$url" "$body" "$@"                           
      165 -  if [[ "$RESP_CODE" == "$expected" ]] && grep -q "$pattern" <
          -<<"$RESP_BODY"; then                                          
      166 -    green "$desc (HTTP $RESP_CODE, body matches '$pattern')"  
      167 -  elif [[ "$RESP_CODE" != "$expected" ]]; then                
      168 -    red "$desc — expected $expected, got $RESP_CODE"          
      169 -    [[ "$VERBOSE" != "1" ]] && [[ -n "$RESP_BODY" ]] && dim " 
          -   body: ${RESP_BODY:0:300}"                                  
      170 -  else                                                        
      171 -    red "$desc — HTTP $RESP_CODE but body missing '$pattern'" 
      172 -  fi                                                          
      173 -}                                                             
      174 -                                                              
      175 -# poll_task TASK_ID → returns 0 when SUCCEEDED; sets TASK_STAT
          -US                                                            
      176 -poll_task() {                                                 
      177 -  local tid="$1" i                                            
      178 -  TASK_STATUS=""                                              
      179 -  for i in $(seq 1 15); do                                    
      180 -    req GET "$EMU$TASKS/$tid"                                 
      181 -    TASK_STATUS="$(echo "$RESP_BODY" | jget data.status)"     
      182 -    [[ "$TASK_STATUS" == "SUCCEEDED" ]] && return 0           
      183 -    sleep 0.4                                                 
      184 -  done                                                        
      185 -  return 1                                                    
      186 -}                                                             
      187 -                                                              
      188 -# ─── Banner ─────────────────────────────────────────────────
          -─────────────────                                             
      189 -echo "╔══════════════════════════════════════════════════════╗
          -"                                                             
      190 -echo "║   Nutanix v4 Mock-Stack Test                         ║
          -"                                                             
      191 -printf  "║   Version:  %-41s ║\n" "$VERSION"                  
      192 -printf  "║   Prism:    %-41s ║\n" "$PRISM"                    
      193 -printf  "║   Emulator: %-41s ║\n" "$EMU"                      
      194 -printf  "║   Mode:     %-41s ║\n" "$([[ $VERBOSE == 1 ]] && ec
          -ho verbose || echo quiet)"                                    
      195 -echo "╚══════════════════════════════════════════════════════╝
          -"                                                             
      196 -                                                              
      197 -# ─── 1. Prism (schema-only mock) ────────────────────────────
          -─────────────────                                             
      198 -hdr "1. Prism — schema mock & request validation"             
      199 -check_body "List VMs"        GET "$PRISM$VM_LIST"   200 '"data
          -"'                                                            
      200 -check_body "List subnets"    GET "$PRISM$SUBNETS"   200 '"data
          -"'                                                            
      201 -check_body "List clusters"   GET "$PRISM$CLUSTERS"  200 '"data
          -"'                                                            
      202 -check_body "List images"     GET "$PRISM$IMAGES"    200 '"data
          -"'                                                            
      203 -check_body "Get VM (valid UUID)"  GET "$PRISM$VM_LIST/$VALID_U
          -UID" 200 '"extId"'                                            
      204 -check      "Get VM (invalid UUID → 422)" GET "$PRISM$VM_LIST/n
          -ot-a-uuid" 422                                                
      205 -check_body "Unknown path → 404"  GET "$PRISM/api/does/not/exis
          -t" 404 'NO_PATH_MATCHED'                                      
      206 -check      "Create VM missing NTNX-Request-Id → 422" \        
      207 -           POST "$PRISM$VM_LIST" 422 '{"name":"probe-vm"}'    
      208 -check      "Create VM with NTNX-Request-Id → 202" \           
      209 -           POST "$PRISM$VM_LIST" 202 '{"name":"probe-vm"}' -H 
          -"NTNX-Request-Id: $REQ_ID"                                    
      210 -                                                              
      211 -# v4.0-only legacy path variants (the emulator answers a1 / ba
          -re / ahv).                                                    
      212 -if [[ "$VERSION" == "v4.0" ]]; then                           
      213 -  hdr "1b. v4.0 legacy path variants"                         
      214 -  check "List VMs via v4.0.a1" GET "$EMU/api/vmm/v4.0.a1/confi
          -g/vms" 200                                                    
      215 -  check "List VMs via v4.0 (bare)" GET "$EMU/api/vmm/v4.0/conf
          -ig/vms" 200                                                   
      216 -fi                                                            
      217 -                                                              
      218 -# ─── 2. Emulator — health & seed data ───────────────────────
          -─────────────────                                             
      219 -hdr "2. Emulator — health & seed reference data"              
      220 -check "GET /health" GET "$EMU/health" 200                     
      221 -check "List clusters" GET "$EMU$CLUSTERS" 200                 
      222 -check "List subnets"  GET "$EMU$SUBNETS" 200                  
      223 -check "List images"   GET "$EMU$IMAGES"  200                  
      224 -check "List storage containers" GET "$EMU$SCS" 200            
      225 -                                                              
      226 -N="$(req GET "$EMU$SUBNETS"; echo "$RESP_BODY" | jget metadata
          -.totalAvailableResults)"                                      
      227 -[[ "$N" -ge 1 ]] && green "seed subnet present ($N)" || red "s
          -eed subnet missing ($N)"                                      
      228 -N="$(req GET "$EMU$IMAGES"; echo "$RESP_BODY" | jget metadata.
          -totalAvailableResults)"                                       
      229 -[[ "$N" -ge 2 ]] && green "seed images present ($N)" || red "s
          -eed images missing ($N)"                                      
      230 -                                                              
      231 -# ─── 3. Emulator — VM lifecycle ─────────────────────────────
          -─────────────────                                             
      232 -hdr "3. VM lifecycle (create → task → get → update → power → f
          -ilter → delete)"                                              
      233 -VM_BODY='{                                                    
      234 -  "name": "test-vm",                                          
      235 -  "description": "created by test.sh",                        
      236 -  "num_sockets": 2,                                           
      237 -  "num_cores_per_socket": 2,                                  
      238 -  "memory_size_bytes": 4294967296,                            
      239 -  "nics": [{ "subnet": { "ext_id": "'$SEED_SUBNET'" } }]      
      240 -}'                                                            
      241 -                                                              
      242 -req POST "$EMU$VM_LIST" "$VM_BODY"                            
      243 -TASK_ID="$(echo "$RESP_BODY" | jget data.extId)"              
      244 -[[ -n "$TASK_ID" ]] && green "POST create VM accepted (task $T
          -ASK_ID)" || red "POST create VM: no task id"                  
      245 -                                                              
      246 -VM_ID=""                                                      
      247 -if [[ -n "$TASK_ID" ]]; then                                  
      248 -  if poll_task "$TASK_ID"; then                               
      249 -    green "create task SUCCEEDED"                             
      250 -    VM_ID="$(echo "$RESP_BODY" | jget data.entitiesAffected.0.
          -extId)"                                                       
      251 -  else                                                        
      252 -    red "create task did not reach SUCCEEDED (last: $TASK_STAT
          -US)"                                                          
      253 -  fi                                                          
      254 -fi                                                            
      255 -                                                              
      256 -if [[ -n "$VM_ID" ]]; then                                    
      257 -  req GET "$EMU$VM_LIST/$VM_ID"                               
      258 -  NAME="$(echo "$RESP_BODY" | jget data.name)"                
      259 -  [[ "$NAME" == "test-vm" ]] && green "GET VM name ok" || red 
          -"GET VM name: '$NAME'"                                        
      260 -                                                              
      261 -  # Update                                                    
      262 -  req PUT "$EMU$VM_LIST/$VM_ID" '{"name":"test-vm-v2","numSock
          -ets":4}'                                                      
      263 -  UTASK="$(echo "$RESP_BODY" | jget data.extId)"              
      264 -  if [[ -n "$UTASK" ]] && poll_task "$UTASK"; then            
      265 -    green "PUT update task SUCCEEDED"                         
      266 -  else                                                        
      267 -    red "PUT update failed"                                   
      268 -  fi                                                          
      269 -  req GET "$EMU$VM_LIST/$VM_ID"                               
      270 -  NAME="$(echo "$RESP_BODY" | jget data.name)"                
      271 -  [[ "$NAME" == "test-vm-v2" ]] && green "updated name persist
          -ed" || red "updated name: '$NAME'"                            
      272 -                                                              
      273 -  # Power action ($actions URL)                               
      274 -  req POST "$EMU$VM_LIST/$VM_ID/\$actions/power-off" '{}'     
      275 -  PTASK="$(echo "$RESP_BODY" | jget data.extId)"              
      276 -  [[ -n "$PTASK" ]] && green "power-off accepted (task $PTASK)
          -" || red "power-off: no task"                                 
      277 -  sleep 1                                                     
      278 -  req GET "$EMU$VM_LIST/$VM_ID"                               
      279 -  PS="$(echo "$RESP_BODY" | jget data.powerState)"            
      280 -  [[ "$PS" == "OFF" ]] && green "power state is OFF" || red "p
          -ower state: '$PS' (expected OFF)"                             
      281 -                                                              
      282 -  # List + $filter                                            
      283 -  check "List VMs" GET "$EMU$VM_LIST" 200                     
      284 -  req GET "$EMU$VM_LIST" "" --get --data-urlencode "\$filter=n
          -ame eq 'test-vm-v2'"                                          
      285 -  F="$(echo "$RESP_BODY" | jget metadata.totalAvailableResults
          -)"                                                            
      286 -  [[ "$F" == "1" ]] && green "\$filter by name works" || red "
          -\$filter returned $F (expected 1)"                            
      287 -                                                              
      288 -  # Delete                                                    
      289 -  req DELETE "$EMU$VM_LIST/$VM_ID"                            
      290 -  DTASK="$(echo "$RESP_BODY" | jget data.extId)"              
      291 -  if [[ -n "$DTASK" ]] && poll_task "$DTASK"; then            
      292 -    green "DELETE task SUCCEEDED"                             
      293 -  else                                                        
      294 -    red "DELETE failed"                                       
      295 -  fi                                                          
      296 -  check "GET deleted VM → 404" GET "$EMU$VM_LIST/$VM_ID" 404  
      297 -fi                                                            
      298 -                                                              
      299 -check "GET unknown VM → 404" GET "$EMU$VM_LIST/00000000-dead-b
          -eef-0000-000000000000" 404                                    
      300 -check "GET unknown task → 404" GET "$EMU$TASKS/00000000-dead-b
          -eef-0000-000000000000" 404                                    
      301 -                                                              
      302 -# ─── 4. Emulator — networking resources ─────────────────────
          -─────────────────                                             
      303 -hdr "4. Networking (subnet / VPC / floating IP / NSP)"        
      304 -                                                              
      305 -req POST "$EMU$SUBNETS" '{"name":"test-subnet","subnetType":"V
          -LAN"}'                                                        
      306 -STASK="$(echo "$RESP_BODY" | jget data.extId)"                
      307 -[[ -n "$STASK" ]] && green "create subnet accepted" || red "cr
          -eate subnet failed"                                           
      308 -req GET "$EMU$TASKS/$STASK"                                   
      309 -SUBNET_ID="$(echo "$RESP_BODY" | jget data.entitiesAffected.0.
          -extId)"                                                       
      310 -[[ -n "$SUBNET_ID" ]] && green "subnet extId from task" || red
          - "subnet extId missing"                                       
      311 -check "List subnets after create" GET "$EMU$SUBNETS" 200      
      312 -                                                              
      313 -req POST "$EMU$VPCS" '{"name":"test-vpc"}'                    
      314 -VTASK="$(echo "$RESP_BODY" | jget data.extId)"                
      315 -req GET "$EMU$TASKS/$VTASK"                                   
      316 -VPC_ID="$(echo "$RESP_BODY" | jget data.entitiesAffected.0.ext
          -Id)"                                                          
      317 -[[ -n "$VPC_ID" ]] && green "create VPC accepted ($VPC_ID)" ||
          - red "create VPC failed"                                      
      318 -check "List VPCs" GET "$EMU$VPCS" 200                         
      319 -check "Delete VPC" DELETE "$EMU$VPCS/$VPC_ID" 202             
      320 -                                                              
      321 -req POST "$EMU$FIPS" '{"name":"test-fip"}'                    
      322 -FTASK="$(echo "$RESP_BODY" | jget data.extId)"                
      323 -req GET "$EMU$TASKS/$FTASK"                                   
      324 -FIP_ID="$(echo "$RESP_BODY" | jget data.entitiesAffected.0.ext
          -Id)"                                                          
      325 -[[ -n "$FIP_ID" ]] && green "create floating IP accepted ($FIP
          -_ID)" || red "create floating IP failed"                      
      326 -check "List floating IPs" GET "$EMU$FIPS" 200                 
      327 -check "Delete floating IP" DELETE "$EMU$FIPS/$FIP_ID" 202     
      328 -                                                              
      329 -req POST "$EMU$NSPS" '{"name":"test-nsp"}'                    
      330 -NTASK="$(echo "$RESP_BODY" | jget data.extId)"                
      331 -req GET "$EMU$TASKS/$NTASK"                                   
      332 -NSP_ID="$(echo "$RESP_BODY" | jget data.entitiesAffected.0.ext
          -Id)"                                                          
      333 -[[ -n "$NSP_ID" ]] && green "create NSP accepted ($NSP_ID)" ||
          - red "create NSP failed"                                      
      334 -check "List NSPs" GET "$EMU$NSPS" 200                         
      335 -check "Delete NSP" DELETE "$EMU$NSPS/$NSP_ID" 202             
      336 -                                                              
      337 -check "Delete subnet" DELETE "$EMU$SUBNETS/$SUBNET_ID" 202    
      338 -                                                              
      339 -# ─── 5. Emulator — volume groups & recovery points ──────────
          -─────────────────                                             
      340 -hdr "5. Volume groups / recovery points"                      
      341 -                                                              
      342 -req POST "$EMU$VGS" '{"name":"test-vg","disks":[{"diskSizeByte
          -s":10737418240}]}'                                            
      343 -GTASK="$(echo "$RESP_BODY" | jget data.extId)"                
      344 -req GET "$EMU$TASKS/$GTASK"                                   
      345 -VG_ID="$(echo "$RESP_BODY" | jget data.entitiesAffected.0.extI
          -d)"                                                           
      346 -[[ -n "$VG_ID" ]] && green "create volume group accepted ($VG_
          -ID)" || red "create VG failed"                                
      347 -check "List volume groups" GET "$EMU$VGS" 200                 
      348 -check "List VG disks" GET "$EMU$VGS/$VG_ID/disks" 200         
      349 -                                                              
      350 -req POST "$EMU$RPS" "{\"name\":\"test-rp\",\"volumeGroupRecove
          -ryPoints\":[{\"volumeGroupExtId\":\"$VG_ID\"}]}"              
      351 -RTASK="$(echo "$RESP_BODY" | jget data.extId)"                
      352 -req GET "$EMU$TASKS/$RTASK"                                   
      353 -RP_ID="$(echo "$RESP_BODY" | jget data.entitiesAffected.0.extI
          -d)"                                                           
      354 -[[ -n "$RP_ID" ]] && green "create recovery point accepted ($R
          -P_ID)" || red "create RP failed"                              
      355 -req GET "$EMU$RPS" "" --get --data-urlencode "\$filter=volumeG
          -roupExtId eq '$VG_ID'"                                        
      356 -RF="$(echo "$RESP_BODY" | jget metadata.totalAvailableResults)
          -"                                                             
      357 -[[ "$RF" -ge 1 ]] && green "RP \$filter by volumeGroupExtId wo
          -rks" || red "RP \$filter returned $RF"                        
      358 -check "Delete recovery point" DELETE "$EMU$RPS/$RP_ID" 202    
      359 -check "Delete volume group" DELETE "$EMU$VGS/$VG_ID" 202      
      360 -                                                              
      361 -# ─── 6. Emulator — catch-all proxy to Prism ─────────────────
          -─────────────────                                             
      362 -hdr "6. Proxy to Prism (spec-covered, not emulated)"          
      363 -# iam only ships a v4.0 spec; for v4.1+ pick a namespace that 
          -exists per version.                                           
      364 -if [[ "$VERSION" == "v4.0" ]]; then                           
      365 -  check "GET /api/iam/v4.0/authz/roles via proxy" GET "$EMU/ap
          -i/iam/v4.0/authz/roles" 200                                   
      366 -else                                                          
      367 -  check "GET prism tasks list via proxy" GET "$EMU$TASKS" 200 
      368 -fi                                                            
      369 -                                                              
      370 -# ─── Summary ────────────────────────────────────────────────
          -─────────────────                                             
      371 -echo ""                                                       
      372 -echo "════════════════════════════════════════════════════════
          -"                                                             
      373 -printf "  Results: \033[32m%d passed\033[0m, \033[31m%d failed
          -\033[0m\n" "$PASS" "$FAIL"                                    
      374 -echo "════════════════════════════════════════════════════════
          -"                                                             
      375 -                                                              
      376 -exit "$FAIL"                                                  
       47 +exit $(( R + W ))                                             

  Thought for 11s, ran 1 shell command (ctrl+o to expand)

● Now verify the split against the running v4.0 stack:

  Thought for 8s, ran 1 shell command (ctrl+o to expand)

● Split verified (read 19 + write 33 = 52 for v4.0). Let me confirm verbose mode
  still works correctly in the split scripts (the earlier stdout/stderr bug
  fix):

  Thought for 10s, ran 2 shell commands (ctrl+o to expand)

● Both versions pass (v4.3: read 17 + write 33 = 50). Let me update the
  architecture doc to reflect the new read/write split:

● Update(stoplight_mock/ARCHITECTURE.md)
  ⎿  Added 15 lines, removed 9 lines
      247  
      248  ---
      249  
      250 -## 7. Consolidated test runner                                
      250 +## 7. Test suite (read/write split)                           
      251  
      252 -File: `scripts/test.sh` — replaces `prism-test.sh`, `smoke-tes
          -t.sh` and                                                     
      253 -`test-emulator.sh` with a single script that covers the Prism 
          -mock, the                                                     
      254 -emulator lifecycle (VM CRUD + tasks, networking, volume groups
          -, recovery                                                    
      255 -points) and the Prism catch-all proxy.                        
      252 +The test suite is split by whether it mutates backend state:  
      253  
      257 -Two output modes:                                             
      254 +| Script | Scope |                                            
      255 +|--------|-------|                                            
      256 +| `scripts/test_read.sh`  | **Read-only** — enumeration + GET 
          +operations only (Prism list/get + path validation, emulator he
          +alth & seed data, unknown-resource 404s, Prism proxy). Issues 
          +no POST/PUT/DELETE. |                                         
      257 +| `scripts/test_write.sh` | **Write** — create / update / dele
          +te (Prism mutation validation, VM lifecycle, networking, volum
          +e groups, recovery points) plus the GETs that verify the mutat
          +ions. |                                                       
      258 +| `scripts/lib.sh`        | Shared harness (sourced by both): 
          +arg parsing, per-version URLs/paths, `req`/`check`/`check_body
          +`/`poll_task`, banner/summary. |                              
      259 +| `scripts/test.sh`       | Thin wrapper that runs `test_read.
          +sh` then `test_write.sh`. |                                   
      260  
      261 +These replace `prism-test.sh`, `smoke-test.sh` and `test-emula
          +tor.sh`.                                                      
      262 +                                                              
      263 +Two output modes (both scripts):                              
      264 +                                                              
      265  * **quiet** (default) — one `✓`/`✗` line per check plus a summ
           ary.
      266  * **`--verbose` / `-v`** — additionally prints every HTTP requ
           est in detail:
      267    method, full URL, headers, body, response status and respons
           e body.
     ...
      270  `v4.1.0`, …), which maps to the matching Prism/emulator host p
           orts in §2:
      271  
      272  ```
      267 -./scripts/test.sh                       # v4.0, quiet         
      268 -./scripts/test.sh --version v4.3 --verbose                    
      269 -./scripts/test.sh -V 4.1                                      
      273 +./scripts/test_read.sh                        # v4.0 read-only
          +, quiet                                                       
      274 +./scripts/test_write.sh --version v4.3 --verbose              
      275 +./scripts/test.sh -V 4.1                      # both read + wr
          +ite                                                           
      276  ```
      277  
      278  Exit code = number of failed checks. The v4.0 run also exercis
           es the legacy

  Thought for 7s, ran 1 shell command (ctrl+o to expand)

● Done. I split the suite by whether it mutates backend state, with the shared
  plumbing extracted so the HTTP/assertion logic isn't duplicated (important —
  that's the code I had to bug-fix earlier).

  What changed

  ┌───────────────────────┬──────────────────────────────────────────────────┐
  │         File          │                       Role                       │
  ├───────────────────────┼──────────────────────────────────────────────────┤
  │                       │ Shared harness (sourced): arg parsing,           │
  │ scripts/lib.sh        │ per-version URLs/paths,                          │
  │                       │ req/check/check_body/poll_task, banner/summary   │
  ├───────────────────────┼──────────────────────────────────────────────────┤
  │ scripts/test_read.sh  │ Read-only — GET/enumeration only                 │
  ├───────────────────────┼──────────────────────────────────────────────────┤
  │ scripts/test_write.sh │ Write — create/update/delete + the GETs that     │
  │                       │ verify them                                      │
  ├───────────────────────┼──────────────────────────────────────────────────┤
  │ scripts/test.sh       │ Now a thin wrapper that runs read → write        │
  └───────────────────────┴──────────────────────────────────────────────────┘

  The split rule

  - test_read.sh — no POST/PUT/DELETE at all:
    - Prism list/get (VMs, subnets, clusters, images), valid UUID → 200, invalid
  UUID → 422, unknown path → 404
    - v4.0 legacy path variants (GET)
    - Emulator /health + seed data (clusters/subnets/images/storage-containers)
    - Unknown VM/task → 404, and the Prism proxy passthrough
  - test_write.sh — every mutation:
    - Prism mutation-request validation (create VM missing/with NTNX-Request-Id)
    - VM lifecycle (create → poll task → get → update → power-off → filter →
  delete)
    - Networking (subnet/VPC/floating-IP/NSP create+delete)
    - Volume groups + recovery points (create+delete)

  Verified

  ┌─────────┬──────┬───────┬───────┐
  │ Version │ read │ write │ total │
  ├─────────┼──────┼───────┼───────┤
  │ v4.0    │ 19 ✓ │ 33 ✓  │ 52 ✓  │
  ├─────────┼──────┼───────┼───────┤
  │ v4.3    │ 17 ✓ │ 33 ✓  │ 50 ✓  │
  └─────────┴──────┴───────┴───────┘

  Verbose mode (-v) still works in both (the HTTP trace goes to stderr, so it
  can't corrupt the $(…)-captured values). Usage:

  ./scripts/test_read.sh                       # read-only, v4.0
  ./scripts/test_write.sh --version v4.3 -v    # mutations, v4.3, verbose
  ./scripts/test.sh -V 4.1                     # both, in order

  All exit with the number of failed checks (0 = clean). ARCHITECTURE.md §7 was
  updated to document the split.

✻ Baked for 4m 48s

❯ now how can i change the my.env or .env for the NUTANIX_HOST and port         
  information to point at different version of minor v4 just setup?             

  Thought for 1m 37s, searched for 2 patterns, read 7 files, ran 1 shell command (ctrl+o to expand)

● Here's the full picture. The Nutanix endpoint is controlled by four NUTANIX_*
  variables, and the important insight is that NUTANIX_PORT and 
  NUTANIX_API_VERSION must change together — each emulator only serves its own
  minor version's paths.

  Where the values live

  There are two files, with different reload behavior:

  ┌───────────┬─────────────────────────────────────────────────────────────┐
  │   File    │                          Behavior                           │
  ├───────────┼─────────────────────────────────────────────────────────────┤
  │ my.env    │ Live-reload. Bind-mounted to /run/config/my.env, re-read    │
  │ (repo     │ per request by hot_config.py (mtime cache). Edit → takes    │
  │ root)     │ effect on the next request, no restart.                     │
  ├───────────┼─────────────────────────────────────────────────────────────┤
  │ .env      │ Startup config. Loaded once via load_dotenv and cached      │
  │ (repo     │ (@lru_cache). Used as the fallback when my.env is absent.   │
  │ root)     │ Edit → needs a container restart.                           │
  └───────────┴─────────────────────────────────────────────────────────────┘

  Both currently carry the same values (.env:187-191, my.env:14-18).

  What to change

  The connection is NUTANIX_HOST:NUTANIX_PORT with an api_version in the URL
  path. To point at a different minor version, set NUTANIX_PORT + 
  NUTANIX_API_VERSION to the same version:

  ┌─────────┬──────────────┬─────────────────────┐
  │ Version │ NUTANIX_PORT │ NUTANIX_API_VERSION │
  ├─────────┼──────────────┼─────────────────────┤
  │ v4.0    │ 9440         │ v4.0                │
  ├─────────┼──────────────┼─────────────────────┤
  │ v4.1    │ 9441         │ v4.1                │
  ├─────────┼──────────────┼─────────────────────┤
  │ v4.2    │ 9442         │ v4.2                │
  ├─────────┼──────────────┼─────────────────────┤
  │ v4.3    │ 9443         │ v4.3                │
  └─────────┴──────────────┴─────────────────────┘

  NUTANIX_HOST stays pointing at the Docker host (currently rocky96, or use
  host.docker.internal); NUTANIX_VERIFY_SSL=false stays as-is (the emulator uses
  a self-signed cert).

  Example — switch to v4.2 (live, no restart)

  Edit my.env:

  env
  NUTANIX_HOST=rocky96
  NUTANIX_PORT=9442
  NUTANIX_API_VERSION=v4.2
  NUTANIX_VERIFY_SSL=false

  Done — the next request uses v4.2. For v4.3, change both to 9443 / v4.3.

  Why they must match (the caveat)

  The flow is: my.env → identity service builds X-Provider-Connection ({host, 
  port, api_version}) → libcloud REST API → NutanixNodeDriver(host, port, 
  api_version=…). The api_version becomes the path segment (/api/vmm/v4.2/…),
  and the port selects which emulator to hit.

  - emulator-41 (port 9441) only registers /api/…/v4.1/… routes and proxies
  everything else to prism-41 (v4.1 spec).
  - So NUTANIX_PORT=9441 + NUTANIX_API_VERSION=v4.0 → the driver asks the v4.1
  emulator for v4.0 paths → 404 NO_PATH_MATCHED.

  The Prism ports (4010–4013) are not what clients point at — they're
  localhost-only and only back the emulator's internal proxy (or direct
  schema-mock access). Clients talk to the emulator on 944x.

  One caveat on NUTANIX_HOST: the emulators are published on 0.0.0.0:944x, so
  from inside the containers use the host address (rocky96 /
  host.docker.internal); if you're driving from the host itself, localhost also
  works.

✻ Crunched for 1m 54s