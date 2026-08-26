 ▐▛███▜▌   Claude Code v2.1.234
▝▜█████▛▘  deepseek-v4-pro · API Usage Billing
  ▘▘ ▝▝    ~/libcloud_nutanix/stoplight_mock


❯ are there any authentication done using test_script/tenant_vault_secret.env's 
  Nutanix user and password(LIBCLOUD_NTNX_USER=admin                            
  LIBCLOUD_NTNX_PASSWORD=admin and the host is at NUTANIX_HOSTNAME defined in   
  my.env, or .env) inside the script stoplight_mock/scripts/test*.sh?           

  Thought for 6s (ctrl+o to expand)

● I'll investigate this. Let me look at the relevant files in parallel.

  Thought for 2s, read 1 file, listed 1 directory (ctrl+o to expand)

● Now let me examine the stoplight_mock test scripts and grep for credential
  references.

  Thought for 4s, searched for 2 patterns, read 3 files (ctrl+o to expand)

● Let me look at lib.sh to understand the endpoints and whether any
  authentication is performed.

  Thought for 7s, read 1 file (ctrl+o to expand)

● No. There is no authentication of any kind using those Nutanix credentials
  inside stoplight_mock/scripts/test*.sh.

  What the stoplight scripts actually do

  The three test scripts (test.sh, test_read.sh, test_write.sh) are thin runners
  that source stoplight_mock/scripts/lib.sh. They only ever hit local mock 
  endpoints derived from the selected API version — never a real Nutanix Prism
  host:

  - stoplight_mock/scripts/lib.sh:38-39
    - PRISM="http://localhost:$((4010 + MINOR))" — Stoplight Prism schema mock
    - EMU="https://localhost:$((9440 + MINOR))" — the stateful Nutanix emulator

  The HTTP primitive that makes every request (req, lib.sh:88-117) builds curl
  with:

  args=(-sk -o "$TMP/body" -w '%{http_code}' -X "$method")

  -sk = silent + insecure (skip TLS verify for the self-signed emulator). It
  never adds an Authorization header, never passes -u/--user, and never reads
  any env file. The only header ever sent in the whole suite is NTNX-Request-Id
  (test_write.sh:35) and Content-Type: application/json.

  About the credentials you mentioned

  - test_script/tenant_vault_secret.env (LIBCLOUD_NTNX_USER=admin,
  LIBCLOUD_NTNX_PASSWORD=admin) is backend cloud-credential seeding material,
  not something the stoplight tests consume. Per .env's comments, those values
  are written into Vault at secret/data/libcloud/nutanix via
  set_tenant_credentials.py — a completely separate flow from the mock-stack
  tests.
  - The host variable NUTANIX_HOSTNAME does not exist anywhere in the repo (grep
  across *.sh, *.py, *.env, *.yml, *.yaml, *.js returned nothing). The actual
  variable is NUTANIX_HOST (not NUTANIX_HOSTNAME), defined in my.env and .env as
  NUTANIX_HOST=rocky96. The stoplight scripts don't read that either — their
  target is always localhost.

  So the stoplight mock tests exercise Prism + the local emulator entirely
  without credentials; the real Nutanix admin credentials live in a separate,
  unconnected path (Vault seeding via the tenant-credentials script).

✻ Brewed for 35s

❯ can we modify the test*.sh so that it will read the NUTANIX_HOST from my.env, 
  and the nutanix admin username + password from  LIBCLOUD_NTNX_USER=admin      
  LIBCLOUD_NTNX_PASSWORD=admin -inside test_script/tenant_vault_secret.env and  
  then query the NUTANIX_HOST the relevant endpoint...be it v4.1 or v4.2 (as    
  specified in my.env).                                                         

  Thought for 20s (ctrl+o to expand)

● Good question — this is a meaningful change. Let me first understand how the
  repo currently reads those env files and queries the real Nutanix host, so the
  modification matches existing patterns.

  Thought for 16s, searched for 1 pattern, read 2 files, ran 3 shell commands (ctrl+o to expand)

● There's already a query_nutanix_v4.sh (currently deleted in the working tree)
  that does exactly this. Let me recover its full content and check the two
  tenant_vault_secret.env locations.

  Thought for 54s, ran 2 shell commands (ctrl+o to expand)

● I've found everything I need. Key discovery: the repo already has a
  query_nutanix_v4.sh (now deleted in the working tree) that does almost exactly
  this — HTTP Basic auth against the real Nutanix host, reading
  NUTANIX_HOST/NUTANIX_PORT/NUTANIX_API_VERSION/NUTANIX_VERIFY_SSL from .env and
  LIBCLOUD_NTNX_USER/LIBCLOUD_NTNX_PASSWORD from tenant_vault_secret.env. I'll
  reuse its auth pattern for the stoplight scripts.

  A couple of things I need to pin down before writing code, because they change
  the implementation and one has safety implications.

● User answered Claude's questions:
  ⎿  · When pointed at the real Nutanix host, how much of the suite should run? 
     → Read-only only
     · How should real-host mode be selected versus the existing local mock? → 
     Auto from env

  Thought for 3m 56s (ctrl+o to expand)

● The user wants: auto-detect from env, read-only only. I have everything I
  need. Let me quickly confirm nothing else sources lib.sh before I modify it,
  then implement.

  Thought for 5s, searched for 1 pattern (ctrl+o to expand)

● Now I'll implement. Starting with the core lib.sh changes (target resolution,
  env loading, Basic auth, conditional TLS).

● Update(scripts/lib.sh)
  ⎿  Added 75 lines, removed 3 lines
      12  
      13  set -uo pipefail
      14  
      15 +REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
      16 +                                                               
      17  # ─── Defaults / arg parsing ──────────────────────────────────
          ─────────────────
      18  VERBOSE=0
      19  VERSION="v4.0"
      20 +VERSION_EXPLICIT=0                                             
      21 +TARGET_FLAG="auto"     # auto | real | mock                    
      22  
      23  while [[ $# -gt 0 ]]; do
      24    case "$1" in
      25      -v|--verbose) VERBOSE=1 ;;
      22 -    -V|--version) VERSION="${2:-}"; shift ;;                   
      26 +    -V|--version) VERSION="${2:-}"; VERSION_EXPLICIT=1; shift ;
         +;                                                              
      27 +    --target)     TARGET_FLAG="${2:-auto}"; shift ;;           
      28      -h|--help)    usage; exit 0 ;;
      29      *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
      30    esac
      31    shift
      32  done
      33  
      34 +# ─── Env-file loading & target selection ─────────────────────
         +─────────────────                                              
      35 +# When NUTANIX_HOST is present in $REPO_ROOT/my.env (fallback .
         +env), the scripts                                              
      36 +# auto-target the REAL Nutanix Prism Central host instead of th
         +e local mock                                                   
      37 +# stack. Connection settings (host/port/API version/TLS) come f
         +rom my.env/.env;                                               
      38 +# the admin Basic-auth credentials come from test_script/tenant
         +_vault_secret.env                                              
      39 +# (fallback root tenant_vault_secret.env). Override detection w
         +ith                                                            
      40 +# --target real|mock.                                          
      41 +                                                               
      42 +# Extract KEY=value from a dotenv file. Handles an optional `ex
         +port` prefix and                                               
      43 +# surrounding single/double quotes; ignores comments and blank 
         +lines. Prints the                                              
      44 +# value only (empty + nonzero exit when absent).               
      45 +_get_env() {                                                   
      46 +  local file="$1" key="$2"                                     
      47 +  grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2
         +>/dev/null \                                                   
      48 +    | head -n1 \                                               
      49 +    | sed -E 's/^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Z
         +a-z0-9_]*=//' \                                                
      50 +    | sed -E 's/^["'"'"']//; s/["'"'"'][[:space:]]*$//'        
      51 +}                                                              
      52 +                                                               
      53 +_load_conn_settings() {                                        
      54 +  local f                                                      
      55 +  for f in "${REPO_ROOT}/my.env" "${REPO_ROOT}/.env"; do       
      56 +    [[ -n "${NUTANIX_HOST:-}" ]]        || NUTANIX_HOST="$(_get
         +_env "$f" NUTANIX_HOST)"                                       
      57 +    [[ -n "${NUTANIX_PORT:-}" ]]        || NUTANIX_PORT="$(_get
         +_env "$f" NUTANIX_PORT)"                                       
      58 +    [[ -n "${NUTANIX_API_VERSION:-}" ]] || NUTANIX_API_VERSION=
         +"$(_get_env "$f" NUTANIX_API_VERSION)"                         
      59 +    [[ -n "${NUTANIX_VERIFY_SSL:-}" ]]  || NUTANIX_VERIFY_SSL="
         +$(_get_env "$f" NUTANIX_VERIFY_SSL)"                           
      60 +  done                                                         
      61 +  for f in "${REPO_ROOT}/test_script/tenant_vault_secret.env" "
         +${REPO_ROOT}/tenant_vault_secret.env"; do                      
      62 +    [[ -n "${LIBCLOUD_NTNX_USER:-}" ]]     || LIBCLOUD_NTNX_USE
         +R="$(_get_env "$f" LIBCLOUD_NTNX_USER)"                        
      63 +    [[ -n "${LIBCLOUD_NTNX_PASSWORD:-}" ]] || LIBCLOUD_NTNX_PAS
         +SWORD="$(_get_env "$f" LIBCLOUD_NTNX_PASSWORD)"                
      64 +  done                                                         
      65 +  NUTANIX_PORT="${NUTANIX_PORT:-9440}"                         
      66 +  NUTANIX_API_VERSION="${NUTANIX_API_VERSION:-v4.0}"           
      67 +  NUTANIX_VERIFY_SSL="${NUTANIX_VERIFY_SSL:-false}"            
      68 +}                                                              
      69 +                                                               
      70 +case "$TARGET_FLAG" in                                         
      71 +  mock) TARGET="mock" ;;                                       
      72 +  real) TARGET="real"; _load_conn_settings ;;                  
      73 +  *)    _load_conn_settings                                    
      74 +        if [[ -n "${NUTANIX_HOST:-}" ]]; then TARGET="real"; el
         +se TARGET="mock"; fi ;;                                        
      75 +esac                                                           
      76 +                                                               
      77 +# In real-host mode the API version is authoritative from my.en
         +v (e.g. v4.2),                                                 
      78 +# unless the caller explicitly passed --version.               
      79 +if [[ "$TARGET" == "real" && "$VERSION_EXPLICIT" != "1" ]]; the
         +n                                                              
      80 +  VERSION="${NUTANIX_API_VERSION:-v4.0}"                       
      81 +fi                                                             
      82 +                                                               
      83  # Normalise the version token and derive the per-version ports.
      84  case "${VERSION#v}" in
      85    4.0) MINOR=0; VERSION="v4.0" ;;
     ...
       89    *) echo "Unsupported version: '$VERSION' (supported: v4.0, v
           4.1, v4.2, v4.3)" >&2; exit 2 ;;
       90  esac
       91  
       38 -PRISM="http://localhost:$((4010 + MINOR))"   # Prism   (schema
          --only mock)                                                   
       39 -EMU="https://localhost:$((9440 + MINOR))"    # Emulator (state
          -ful shim, self-signed)                                        
       92 +# HTTP Basic auth (real-host mode only); the mock Prism/emulat
          +or are unauth'd.                                              
       93 +AUTH_USER=""                                                  
       94 +BASIC_AUTH=""                                                 
       95 +if [[ "$TARGET" == "real" ]]; then                            
       96 +  if [[ -z "${NUTANIX_HOST:-}" || -z "${LIBCLOUD_NTNX_USER:-}"
          + || -z "${LIBCLOUD_NTNX_PASSWORD:-}" ]]; then                 
       97 +    echo "error: real-host mode needs NUTANIX_HOST (my.env/.en
          +v) and" >&2                                                   
       98 +    echo "       LIBCLOUD_NTNX_USER / LIBCLOUD_NTNX_PASSWORD (
          +test_script/tenant_vault_secret.env)" >&2                     
       99 +    exit 2                                                    
      100 +  fi                                                          
      101 +  AUTH_USER="$LIBCLOUD_NTNX_USER"                             
      102 +  BASIC_AUTH="$(printf '%s:%s' "$LIBCLOUD_NTNX_USER" "$LIBCLOU
          +D_NTNX_PASSWORD" | base64 | tr -d '\n')"                      
      103 +fi                                                            
      104  
      105 +if [[ "$TARGET" == "real" ]]; then                            
      106 +  PRISM="https://${NUTANIX_HOST}:${NUTANIX_PORT}"   # real Pri
          +sm Central (no schema mock)                                   
      107 +  EMU="https://${NUTANIX_HOST}:${NUTANIX_PORT}"     # same hos
          +t; read-only endpoint checks                                  
      108 +else                                                          
      109 +  PRISM="http://localhost:$((4010 + MINOR))"        # Prism   
          +(schema-only mock)                                            
      110 +  EMU="https://localhost:$((9440 + MINOR))"         # Emulator
          + (stateful shim, self-signed)                                 
      111 +fi                                                            
      112 +                                                              
      113  # ─── Per-version resource paths ─────────────────────────────
           ─────────────────
      114  VM_LIST="/api/vmm/${VERSION}/ahv/config/vms"
      115  TASKS="/api/prism/${VERSION}/config/tasks"

● Now the req function — add conditional TLS skip and the Basic auth header:

● Update(scripts/lib.sh)
  ⎿  Added 10 lines, removed 1 line
      163    # Optional 3rd positional is the request body; anything afte
           r that (or any
      164    # leading '-flag') is passed straight through to curl.
      165    if [[ $# -gt 0 && "${1:-}" != -* ]]; then body="$1"; shift; 
           fi
      166 -  local args=(-sk -o "$TMP/body" -w '%{http_code}' -X "$method
          -")                                                            
      166 +  local args=(-s -o "$TMP/body" -w '%{http_code}' -X "$method"
          +)                                                             
      167 +  # -k (skip TLS verify): always for the self-signed mock emul
          +ator; for a real                                              
      168 +  # host only when NUTANIX_VERIFY_SSL is not truthy.          
      169 +  if [[ "$TARGET" == "mock" ]] || [[ "$NUTANIX_VERIFY_SSL" != 
          +"true" && "$NUTANIX_VERIFY_SSL" != "1" && "$NUTANIX_VERIFY_SSL
          +" != "yes" ]]; then                                           
      170 +    args+=(-k)                                                
      171 +  fi                                                          
      172 +  # HTTP Basic auth header for real-host mode (mock services a
          +re unauthenticated).                                          
      173 +  if [[ -n "${BASIC_AUTH:-}" ]]; then                         
      174 +    args+=(-H "Authorization: Basic ${BASIC_AUTH}")           
      175 +  fi                                                          
      176    [[ -n "$body" ]] && args+=(-H 'Content-Type: application/jso
           n' -d "$body")
      177    args+=("$@")
      178  

  Thought for 1s (ctrl+o to expand)

● Now add the auth line to verbose output (no password leak) and a Target line
  to the banner:

● Update(scripts/lib.sh)
  ⎿  Added 1 line
      187        printf '  REQUEST\n'
      188        printf '    method:  %s\n' "$method"
      189        printf '    url:     %s\n' "$url"
      190 +      [[ -n "${AUTH_USER:-}" ]] && printf '    auth:    Basic 
          +(user %s)\n' "$AUTH_USER"                                     
      191        [[ -n "$body" ]] && printf '    body:    %s\n' "$body"
      192        [[ $# -gt 0 ]] && printf '    headers: %s\n' "$*"
      193        printf '  RESPONSE\n'

● Update(scripts/lib.sh)
  ⎿  Added 1 line
      247    printf '╔═══════════════════════════════════════════════════
           ═══════╗\n'
      248    printf '║   Nutanix v4 Mock-Stack Test   %-24s║\n' "$tag"
      249    printf '║   Version:  %-45s║\n' "$VERSION"
      250 +  printf '║   Target:   %-45s║\n' "$([[ "$TARGET" == "real" ]]
          + && echo "real ${NUTANIX_HOST}:${NUTANIX_PORT}" || echo "mock 
          +(localhost)")"                                                
      251    printf '║   Prism:    %-45s║\n' "$PRISM"
      252    printf '║   Emulator: %-45s║\n' "$EMU"
      253    printf '║   Mode:     %-45s║\n' "$([[ $VERBOSE == 1 ]] && ec
           ho verbose || echo quiet)"

● Now the read-only real-host branch in test_read.sh, and the write-suite guard
  in test_write.sh:

● Update(scripts/test_read.sh)  ⎿  Added 16 lines
      26  
      27  banner "READ-ONLY"
      28  
      29 +# ─── 0. Real-host read-only enumeration (--target real / auto)
         + ────────────────                                              
      30 +# When auto-detection (or --target real) points us at a live Pr
         +ism Central, do                                                
      31 +# a credential-checked read-only sweep of the list endpoints an
         +d stop — the                                                   
      32 +# mock-only checks below (Prism schema validation, seed data, u
         +nknown-UUID 404s)                                              
      33 +# and the write suite do not apply to a real cluster.          
      34 +if [[ "$TARGET" == "real" ]]; then                             
      35 +  hdr "0. Real host — read-only enumeration (${VERSION}, user $
         +{AUTH_USER})"                                                  
      36 +  check_body "List VMs"           GET "$EMU$VM_LIST" 200 '"data
         +"'                                                             
      37 +  check_body "List clusters"      GET "$EMU$CLUSTERS" 200 '"dat
         +a"'                                                            
      38 +  check_body "List subnets"       GET "$EMU$SUBNETS" 200 '"data
         +"'                                                             
      39 +  check_body "List VPCs"          GET "$EMU$VPCS" 200 '"data"' 
      40 +  check_body "List images"        GET "$EMU$IMAGES" 200 '"data"
         +'                                                              
      41 +  check_body "List floating IPs"  GET "$EMU$FIPS" 200 '"data"' 
      42 +  summary                                                      
      43 +fi                                                             
      44 +                                                               
      45  # ─── 1. Prism — schema mock reads & path validation ──────────
          ────────────────
      46  hdr "1. Prism — schema mock (GET)"
      47  check_body "List VMs"        GET "$PRISM$VM_LIST"   200 '"data"
          '

● Update(scripts/test_write.sh)
  ⎿  Added 10 lines
      27  
      28  banner "WRITE"
      29  
      30 +# ─── 0. Real-host guard ──────────────────────────────────────
         +─────────────────                                              
      31 +# Real-host mode is read-only by design: never issue create/upd
         +ate/delete                                                     
      32 +# against a live cluster. When auto-detection (or --target real
         +) is active,                                                   
      33 +# bail out before any mutating request.                        
      34 +if [[ "$TARGET" == "real" ]]; then                             
      35 +  dim "real-host mode is read-only (${NUTANIX_HOST}:${NUTANIX_P
         +ORT}) — skipping the mutating write suite."                    
      36 +  echo ""                                                      
      37 +  exit 0                                                       
      38 +fi                                                             
      39 +                                                               
      40  # ─── 1. Prism — mutating-request validation ──────────────────
          ────────────────
      41  hdr "1. Prism — mutation request validation (POST)"
      42  check "Create VM missing NTNX-Request-Id → 422" \

  Thought for 4s (ctrl+o to expand)

● Now document the new --target flag in the headers of all three scripts:

● Update(scripts/test.sh)
  ⎿  Added 9 lines
      27  #     v4.2 → Prism http://localhost:4012  Emulator https://loca
          lhost:9442
      28  #     v4.3 → Prism http://localhost:4013  Emulator https://loca
          lhost:9443
      29  #
      30 +# Target selection (which Nutanix to test against):            
      31 +#   --target auto|real|mock            (default auto)          
      32 +#   auto = the REAL Prism Central host when NUTANIX_HOST is set
         + in my.env                                                     
      33 +#          (fallback .env), otherwise the local mock stack. rea
         +l/mock force one.                                              
      34 +#   real-host mode is READ-ONLY: it enumerates live endpoints o
         +ver HTTP Basic                                                 
      35 +#   auth using LIBCLOUD_NTNX_USER/PASSWORD from test_script/ten
         +ant_vault_secret.env                                           
      36 +#   and NUTANIX_HOST/PORT/API_VERSION/VERIFY_SSL from my.env; t
         +he write suite is                                              
      37 +#   skipped automatically.                                     
      38 +#                                                              
      39  # Usage:
      40  #   ./scripts/test.sh                          # v4.0, quiet
      41  #   ./scripts/test.sh -v                       # v4.0, verbose

● Update(scripts/test_read.sh)
  ⎿  Added 5 lines
      15  # Versions map to ports (see docker-compose.yml):
      16  #   v4.0 → Prism :4010  Emulator :9440   …   v4.3 → Prism :4013
            Emulator :9443
      17  #
      18 +# Target: --target auto|real|mock (default auto). auto targets 
         +the REAL Prism                                                 
      19 +# Central when NUTANIX_HOST is set in my.env (fallback .env); i
         +n that mode this                                               
      20 +# script runs a read-only enumeration over HTTP Basic auth inst
         +ead of the mock                                                
      21 +# checks. Credentials come from test_script/tenant_vault_secret
         +.env.                                                          
      22 +#                                                              
      23  # Exit code: number of failed checks (0 = all passed).
      24  # ─────────────────────────────────────────────────────────────
          ────────────────
      25  

● Update(scripts/test_write.sh)
  ⎿  Added 5 lines
      16  # Versions map to ports (see docker-compose.yml):
      17  #   v4.0 → Prism :4010  Emulator :9440   …   v4.3 → Prism :4013
            Emulator :9443
      18  #
      19 +# Target: --target auto|real|mock (default auto). auto targets 
         +the REAL Prism                                                 
      20 +# Central when NUTANIX_HOST is set in my.env (fallback .env); i
         +n that mode this                                               
      21 +# script exits without issuing any mutating request (real-host 
         +mode is                                                        
      22 +# read-only).                                                  
      23 +#                                                              
      24  # Exit code: number of failed checks (0 = all passed).
      25  # ─────────────────────────────────────────────────────────────
          ────────────────
      26  

  Thought for 12s (ctrl+o to expand)

● Let me syntax-check all files and verify the target-resolution/auth logic
  resolves correctly against the real env files (without hitting the host):

  Thought for 3s, ran 2 shell commands (ctrl+o to expand)

● The classifier blocked printing the base64 credential — fair, I shouldn't
  materialize it. Let me re-verify without echoing the secret (length only):

  Thought for 8s, ran 1 shell command (ctrl+o to expand)

● Real-mode resolution is correct (v4.2, https://rocky96:9442, user admin, Basic
  token set — 16 chars = base64 of admin:admin). Now confirm mock mode still
  works (no regression):

  Thought for 19s, ran 1 shell command (ctrl+o to expand)

● Both mock mode and the explicit-version override behave correctly. As a final
  non-network check, let me confirm req actually assembles the curl args (Basic
  header + -k) by stubbing curl:

  Thought for 39s, ran 4 shell commands (ctrl+o to expand)

● Done. The modification is complete and verified (without touching your live
  host). Here's what changed and why.

  What I changed

  stoplight_mock/scripts/lib.sh (the shared harness) now:
  1. Loads connection settings from $REPO_ROOT/my.env (fallback .env):
  NUTANIX_HOST, NUTANIX_PORT, NUTANIX_API_VERSION, NUTANIX_VERIFY_SSL.
  2. Loads the admin credentials from
  $REPO_ROOT/test_script/tenant_vault_secret.env (fallback root
  tenant_vault_secret.env): LIBCLOUD_NTNX_USER / LIBCLOUD_NTNX_PASSWORD.
  3. Adds a --target auto|real|mock flag (default auto): real when NUTANIX_HOST
  is present, otherwise mock.
  4. In real mode, computes https://${NUTANIX_HOST}:${NUTANIX_PORT} and attaches
  an HTTP Basic Authorization header to every request via req(); adds -k only
  when NUTANIX_VERIFY_SSL isn't truthy. The API version defaults to
  NUTANIX_API_VERSION (still overridable with --version).

  test_read.sh — added a real-host section that does a read-only sweep (List 
  VMs/clusters/subnets/VPCs/images/floating-IPs) and stops. test_write.sh —
  exits immediately in real mode (no mutations against a live cluster).

  Verification (dry-run, no host contact)

  - bash -n passes on all four files.
  - --target real resolves to TARGET=real, VERSION=v4.2,
  EMU=https://rocky96:9442, user admin, Basic token present.
  - --target mock unchanged (localhost:4010/9440, no auth).
  - --target real --version v4.1 overrides the version correctly.
  - req() was confirmed to assemble -k + Authorization: Basic <token> (checked
  via a stubbed curl; the token itself was never printed).

  Two things to know

  1. The variable is NUTANIX_HOST, not NUTANIX_HOSTNAME. There is no
  NUTANIX_HOSTNAME anywhere in the repo; both my.env and .env use
  NUTANIX_HOST=rocky96. I read NUTANIX_HOST accordingly.
  2. Default behavior now flips to the real host. Because my.env always sets
  NUTANIX_HOST=rocky96, auto targets it — so ./scripts/test.sh and
  stoplight_mock/myrun.sh will now hit rocky96 (read-only), and the write suite
  is skipped. To keep exercising the local mock stack, add --target mock.

  To run it live

  I did not call your Nutanix host (outward-facing auth). Run it yourself when
  ready:

  cd stoplight_mock
  ./scripts/test_read.sh --target real            # read-only enumeration vs 
  rocky96
  ./scripts/test_read.sh --target real --version v4.1
  ./scripts/test.sh --target mock                 # original mock-stack behavior

  One heads-up unrelated to this change: test_script/set_admin_vault.sh sources
  ${REPO_ROOT}/tenant_vault_secret.env, but that root file doesn't exist on disk
  (only test_script/tenant_vault_secret.env does) — the same gap the deleted
  query_nutanix_v4.sh had. You may want to reconcile that separately.

✻ Sautéed for 11m 13s