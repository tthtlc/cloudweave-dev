

 ✨ write down some test in a script which I can used to test that the  stoplight_mock-prism-1 docker is working using curl mainly.                                                                          
 … thinking 7 times, call 9 tools, 10 messages
 
 ● Ran a command                                                                                                                                                                                             
   $ python3 - <<'EOF'                                                                                                                                                                                       
     import json                                                                                                                                                                                             
     spec = json.load(open('stoplight_mock/spec/openapi.json'))                                                                                                                                              
     sch = spec['components']['schemas']['vmm.v4.0.ahv.config.Vm']                                                                                                                                           
     print('keys:', list(sch.keys()))                                                                                                                                                                        
     print('required:', sch.get('required'))                                                                                                                                                                 
     if 'allOf' in sch:                                                                                                                                                                                      
         for i, sub in enumerate(sch['allOf']):                                                                                                                                                              
             print(f'allOf[{i}]:', json.dumps(sub)[:200])                                                                                                                                                    
     print('properties:', list(sch.get('properties', {}).keys())[:40])                                                                                                                                       
   keys: ['description', 'allOf']                                                                                                                                                                            
   required: None                                                                                                                                                                                            
   allOf[0]: {"$ref": "#/components/schemas/common.v1.0.response.ExternalizableAbstractModel"}                                                                                                               
   ... (3 more lines, ctrl+o to expand)
 
 ● Ran a command                                                                                                                                                                                             
   $ UUID="00000000-0000-0000-0000-000000000001"                                                                                                                                                             
     echo "== power-on no body =="                                                                                                                                                                           
     curl -s -o /dev/null -w '%{http_code}\n' -X POST "http://localhost:4010/api/vmm/v4.0/ahv/config/vms/$UUID/\$actions/power-on"                                                                           
     echo "== power-on empty json =="                                                                                                                                                                        
     curl -s -o /dev/null -w '%{http_code}\n' -X POST "http://localhost:4010/api/vmm/v4.0/ahv/config/vms/$UUID/\$actions/power-on" -H 'Content-Type: application/json' -d '{}'                               
     echo "== list with query params =="                                                                                                                                                                     
     curl -s -o /dev/null -w '%{http_code}\n' "http://localhost:4010/api/vmm/v4.0/ahv/config/vms?\$page=0&\$limit=10"                                                                                        
     echo "== networking subnets =="                                                                                                                                                                         
     curl -s -o /dev/null -w '%{http_code}\n' http://localhost:4010/api/networking/v4.0/config/subnets                                                                                                       
     echo "== images =="                                                                                                                                                                                     
   == power-on no body ==                                                                                                                                                                                    
   422                                                                                                                                                                                                       
   == power-on empty json ==                                                                                                                                                                                 
   ... (9 more lines, ctrl+o to expand)
 
   Approved: Running: python3 - <<'EOF'                                                                                                                                                                      
 import json                                                                                                                                                                                                 
 spec = json.load(ope…                                                                                                                                                                                       
 
   Approved: Running: UUID="00000000-0000-0000-0000-000000000001"                                                                                                                                            
 echo "…                                                                                                                                                                                                     
 
 ● Interesting results:                                                                                                                                                                                      
   - power-on with no body → 422 (request validation fails — probably missing required header like NTNX-Request-Id, or a required body)                                                                      
   ... (10 more lines, ctrl+o to expand)
 
 ● Ran a command                                                                                                                                                                                             
   $ python3 - <<'EOF'                                                                                                                                                                                       
     import json                                                                                                                                                                                             
     spec = json.load(open('stoplight_mock/spec/openapi.json'))                                                                                                                                              
     op = spec['paths']['/api/vmm/v4.0/ahv/config/vms/{extId}/$actions/power-on']['post']                                                                                                                    
     print('params:', json.dumps(op.get('parameters', []), indent=1)[:800])                                                                                                                                  
     # check top-level parameters too                                                                                                                                                                        
     print('path-level params:', json.dumps(spec['paths']['/api/vmm/v4.0/ahv/config/vms/{extId}/$actions/power-on'].get('parameters', []))[:300])                                                            
     EOF                                                                                                                                                                                                     
   params: [                                                                                                                                                                                                 
    {                                                                                                                                                                                                        
     "name": "extId",                                                                                                                                                                                        
   ... (17 more lines, ctrl+o to expand)
 
 ● Ran a command                                                                                                                                                                                             
   $ echo "== full response headers for POST create =="                                                                                                                                                      
     curl -s -D - -o /dev/null -X POST http://localhost:4010/api/vmm/v4.0/ahv/config/vms -H 'Content-Type: application/json' -d '{"name":"x","cluster":{"extId":"00000000-0000-0000-0000-000000000001"}}' |  
   head -15                                                                                                                                                                                                  
     echo "== does spec have a 422 anywhere for listVms? =="                                                                                                                                                 
     python3 - <<'EOF'                                                                                                                                                                                       
     import json                                                                                                                                                                                             
     spec = json.load(open('stoplight_mock/spec/openapi.json'))                                                                                                                                              
     op = spec['paths']['/api/vmm/v4.0/ahv/config/vms']['post']                                                                                                                                              
     r = op['responses']                                                                                                                                                                                     
     print(json.dumps({k: (v if isinstance(v,str) else {kk:str(vv)[:80] for kk,vv in v.items()}) for k,v in r.items()}, indent=1)[:1500])                                                                    
     EOF                                                                                                                                                                                                     
   == full response headers for POST create ==                                                                                                                                                               
                                                                                                                                                                         
                                                                                                                                                                            
   ... (26 more lines, ctrl+o to expand)
 
   Approved: Running: python3 - <<'EOF'                                                                                                                                                                      
 import json                                                                                                                                                                                                 
 spec = json.load(ope…                                                                                                                                                                                       
 
   Approved: Running: echo "== full response headers for POST create =="…                                                                                                                                    
 
 ● Found it. The 422 is Prism's request validation: `Request header must have required property 'ntnx-request-id'`. The `sl-violations` header reveals it. So mutating operations require the                
   `Ntnx-Request-Id` header.                                                                                                                                                                                 
   ... (27 more lines, ctrl+o to expand)
 
 ● Ran a command                                                                                                                                                                                             
   $ UUID="00000000-0000-0000-0000-000000000001"                                                                                                                                                             
     RID="11111111-2222-3333-4444-555555555555"                                                                                                                                                              
     echo "== POST create with Ntnx-Request-Id =="                                                                                                                                                           
     curl -s -o /tmp/c.json -w '%{http_code}\n' -X POST http://localhost:4010/api/vmm/v4.0/ahv/config/vms -H "Ntnx-Request-Id: $RID" -H 'Content-Type: application/json' -d                                  
   '{"name":"x","cluster":{"extId":"00000000-0000-0000-0000-000000000001"}}'                                                                                                                                 
     echo "== power-on with Ntnx-Request-Id =="                                                                                                                                                              
     curl -s -o /dev/null -w '%{http_code}\n' -X POST "http://localhost:4010/api/vmm/v4.0/ahv/config/vms/$UUID/\$actions/power-on" -H "Ntnx-Request-Id: $RID"                                                
     echo "== DELETE with Ntnx-Request-Id =="                                                                                                                                                                
     curl -s -o /dev/null -w '%{http_code}\n' -X DELETE "http://localhost:4010/api/vmm/v4.0/ahv/config/vms/$UUID" -H "Ntnx-Request-Id: $RID"                                                                 
     echo "== GET invalid uuid =="                                                                                                                                                                           
     curl -s -o /dev/null -w '%{http_code}\n' "http://localhost:4010/api/vmm/v4.0/ahv/config/vms/not-a-uuid"                                                                                                 
   == POST create with Ntnx-Request-Id ==                                                                                                                                                                    
   202                                                                                                                                                                                                       
   == power-on with Ntnx-Request-Id ==                                                                                                                                                                       
   ... (5 more lines, ctrl+o to expand)
 
   Approved: Running: UUID="00000000-0000-0000-0000-000000000001"                                                                                                                                            
 RID="1…                                                                                                                                                                                                     
 
 ● POST create → 202 ✓. But power-on and DELETE still 422 even with the header. Let me see the sl-violations for those.                                                                                      
 
 ● Ran a command                                                                                                                                                                                             
   $ UUID="00000000-0000-0000-0000-000000000001"                                                                                                                                                             
     RID="11111111-2222-3333-4444-555555555555"                                                                                                                                                              
     echo "== power-on violations =="                                                                                                                                                                        
     curl -s -D - -o /dev/null -X POST "http://localhost:4010/api/vmm/v4.0/ahv/config/vms/$UUID/\$actions/power-on" -H "Ntnx-Request-Id: $RID" | grep -i 'sl-violations'                                     
     echo "== DELETE violations =="                                                                                                                                                                          
     curl -s -D - -o /dev/null -X DELETE "http://localhost:4010/api/vmm/v4.0/ahv/config/vms/$UUID" -H "Ntnx-Request-Id: $RID" | grep -i 'sl-violations'                                                      
   == power-on violations ==                                                                                                                                                                                 
                                                 "],"severity":"Error","code":"required","message":"Request header must have required property 'if-match'"}]
   == DELETE violations ==                                                                                                                                                                                   
   ... (1 more lines, ctrl+o to expand)
 
   Approved: Running: UUID="00000000-0000-0000-0000-000000000001"                                                                                                                                            
 RID="1…                                                                                                                                                                                                     
 
 ● Power-on and DELETE need the `If-Match` header too. Let me test with If-Match, then write the script. The task is small enough that I don't need a TodoList — I'm mid-verification, one more probe then   
   write the script.                                                                                                                                                                                         
 
 ● Ran a command                                                                                                                                                                                             
   $ UUID="00000000-0000-0000-0000-000000000001"                                                                                                                                                             
     RID="11111111-2222-3333-4444-555555555555"                                                                                                                                                              
     echo "== power-on with both headers =="                                                                                                                                                                 
     curl -s -o /tmp/po.json -w '%{http_code}\n' -X POST "http://localhost:4010/api/vmm/v4.0/ahv/config/vms/$UUID/\$actions/power-on" -H "Ntnx-Request-Id: $RID" -H 'If-Match: *'                            
     echo "== DELETE with both headers =="                                                                                                                                                                   
     curl -s -o /dev/null -w '%{http_code}\n' -X DELETE "http://localhost:4010/api/vmm/v4.0/ahv/config/vms/$UUID" -H "Ntnx-Request-Id: $RID" -H 'If-Match: *'                                                
     python3 -m json.tool /tmp/po.json | head -20                                                                                                                                                            
   == power-on with both headers ==                                                                                                                                                                          
   202                                                                                                                                                                                                       
   == DELETE with both headers ==                                                                                                                                                                            
   ... (21 more lines, ctrl+o to expand)
 
   Approved: Running: UUID="00000000-0000-0000-0000-000000000001"                                                                                                                                            
 RID="1…                                                                                                                                                                                                     
 
 ● All status codes confirmed:                                                                                                                                                                               
                                                                                                                                                                                                             
   ... (52 more lines, ctrl+o to expand)
 
 ● Used Write (stoplight_mock/scripts/prism-test.sh) · 146 lines                                                                                                                                             
      1  #!/usr/bin/env bash                                                                                                                                                                                 
      2  # ─── Prism Mock Server Test (stoplight_mock-prism-1) ──────────────────────────                                                                                                                    
      3  # Verifies the Stoplight Prism container is up and serving schema-valid mock                                                                                                                        
      4  # responses on http://localhost:4010.                                                                                                                                                               
      5  #                                                                                                                                                                                                   
      6  # Usage:                                                                                                                                                                                            
      7  #   chmod +x scripts/prism-test.sh                                                                                                                                                                  
      8  #   ./scripts/prism-test.sh [prism_url] [container_name]                                                                                                                                            
      9  #                                                                                                                                                                                                   
     10  # Defaults: URL http://localhost:4010, container stoplight_mock-prism-1                                                                                                                             
   ... (137 more lines, 147 total, ctrl+o to expand)                                                                                                                                                         
 
 ✗ Ran a command                                                                                                                                                                                             
   $ chmod +x stoplight_mock/scripts/prism-test.sh && stoplight_mock/scripts/prism-test.sh                                                                                                                   
   ╔══════════════════════════════════════════════════════╗                                                                                                                                                  
   ║   Prism Mock Server Test                            ║                                                                                                                                                   
   ║   Target: http://localhost:4010                      ║                                                                                                                                                  
   ... (38 more lines, ctrl+o to expand)
 
   Approved: Running: chmod +x stoplight_mock/scripts/prism-test.sh && s…                                                                                                                                    
 
 ● One failure: "List ESXi VM stats" → 422. Probably that endpoint has required query params. Let me check the violations.                                                                                   
 
 ● Ran a command                                                                                                                                                                                             
   $ curl -s -D - -o /dev/null http://localhost:4010/api/vmm/v4.0/esxi/stats/vms | grep -i 'sl-violations'                                                                                                   
     python3 - <<'EOF'                                                                                                                                                                                       
     import json                                                                                                                                                                                             
     spec = json.load(open('stoplight_mock/spec/openapi.json'))                                                                                                                                              
     op = spec['paths']['/api/vmm/v4.0/esxi/stats/vms']['get']                                                                                                                                               
     for p in op.get('parameters', []):                                                                                                                                                                      
         print(p.get('name'), p.get('in'), 'required=', p.get('required'))                                                                                                                                   
     EOF                                                                                                                                                                                                     
   sl-violations: [{"location":["request","query"],"severity":"Error","code":"required","message":"Request query must have required property                                                                 
   '$starttime'"},{"location":["request","query"],"severity":"Error","code":"required","message":"Request query must have required property '$endtime'"}]                                                    
   $startTime query required= True                                                                                                                                                                           
   ... (8 more lines, ctrl+o to expand)
 
   Approved: Running: curl -s -D - -o /dev/null http://localhost:4010/ap…                                                                                                                                    
 
 ● The ESXi stats endpoint requires `$startTime` and `$endTime` query params. Fix the test to pass them. URL-encode `$` is not needed in curl as long as shell-quoted; earlier `$page/$limit` worked         
   unencoded (single-quoted string in script via "\$page"). I'll add the time params.                                                                                                                        
 
 ● It needs $startTime/$endTime query params. Fixing that test line.                                                                                                                                         
 
 ● Used Edit (stoplight_mock/scripts/prism-test.sh) · +2 -1                                                                                                                                                  
   +2 -1 stoplight_mock/scripts/prism-test.sh                                                                                                                                                                
      1 - check_body "List ESXi VM stats"  200 '"data"' "$PRISM/api/vmm/v4.0/esxi/stats/vms"                                                                                                                 
      1 + check_body "List ESXi VM stats (\$startTime/\$endTime required)" 200 '"data"' \                                                                                                                    
      2 +   "$PRISM/api/vmm/v4.0/esxi/stats/vms?\$startTime=2026-07-01T00:00:00Z&\$endTime=2026-07-02T00:00:00Z"                                                                                             
 
 ● Ran a command                                                                                                                                                                                             
   $ stoplight_mock/scripts/prism-test.sh                                                                                                                                                                    
   ╔══════════════════════════════════════════════════════╗                                                                                                                                                  
   ║   Prism Mock Server Test                            ║                                                                                                                                                   
   ║   Target: http://localhost:4010                      ║                                                                                                                                                  
   ... (37 more lines, ctrl+o to expand)
 
   Approved: Running: stoplight_mock/scripts/prism-test.sh                                                                                                                                                   
 
 ● All 20 pass. Done. Summarize concisely.                                                                                                                                                                   
 
 ● Done. The script is at stoplight_mock/scripts/prism-test.sh — all 20 checks pass against the live stoplight_mock-prism-1 container.                                                                       
                                                                                                                                                                                                             
   Run it with:                                                                                                                                                                                              
                                                                                                                                                                                                             
   ```bash                                                                                                                                                                                                   
     stoplight_mock/scripts/prism-test.sh                      # defaults: http://localhost:4010                                                                                                             
     stoplight_mock/scripts/prism-test.sh http://host:4010     # custom URL                                                                                                                                  
   ```                                                                                                                                                                                                       
                                                                                                                                                                                                             
   What it covers, via curl:                                                                                                                                                                                 
                                                                                                                                                                                                             
   • Container check — confirms stoplight_mock-prism-1 is running via docker ps                                                                                                                              
   • List endpoints — AHV VMs, ESXi stats, images, templates, subnets, VPCs, clusters → all expect HTTP 200 with a "data" body                                                                               
   • Validation behavior — valid UUID → 200, invalid UUID → 422, unknown path → 404 with Prism's NO_PATH_MATCHED_ERROR                                                                                       
   • Mutations — POST create → 202, power-on/power-off → 202, DELETE → 202, plus negative cases expecting 422                                                                                                
   • Response format — Content-Type: application/json and parseable JSON                                                                                                                                     
                                                                                                                                                                                                             
   Two spec quirks I discovered while probing, which the script encodes:                                                                                                                                     
                                                                                                                                                                                                             
   • Mutating calls (POST/PUT/DELETE) require the Ntnx-Request-Id header; $actions and DELETE additionally require If-Match — otherwise Prism returns 422.                                                   
   • The ESXi stats endpoint requires $startTime and $endTime query params.                                                                                                                                  
                                                                                                                                                                                                             
   The script exits with the number of failed checks, so exit code 0 means everything passed — usable in CI. Note it's complementary to the existing scripts/smoke-test.sh, which tests the emulator shim on 
   port 9440, not Prism directly.                                                                                                                                                                            
 

