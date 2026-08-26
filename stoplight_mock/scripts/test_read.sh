#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# READ-ONLY test suite — enumeration + GET operations only.
#
# Covers the Prism schema mock (list/get + request-path validation) and the
# emulator's seed/reference data, without ever mutating backend state.
# No POST/PUT/DELETE is issued here.
#
# Usage:
#   ./scripts/test_read.sh                          # v4.0, quiet
#   ./scripts/test_read.sh -v                       # v4.0, verbose
#   ./scripts/test_read.sh --version v4.3 --verbose
#   ./scripts/test_read.sh -V 4.1
#
# Versions map to ports (see docker-compose.yml):
#   v4.0 → Prism :4010  Emulator :9440   …   v4.3 → Prism :4013  Emulator :9443
#
# Target: --target auto|real|mock (default auto). auto targets the REAL Prism
# Central when NUTANIX_HOST is set in my.env (fallback .env); in that mode this
# script runs a read-only enumeration over HTTP Basic auth instead of the mock
# checks. Credentials come from test_script/tenant_vault_secret.env.
#
# Exit code: number of failed checks (0 = all passed).
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  awk 'NR==1 {next} { if (substr($0,1,1)=="#") { sub(/^# ?/, ""); print } else exit }' "$0"
}

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

banner "READ-ONLY"

# Full Nutanix v4 endpoints this suite exercises (emulator base URL + path).
print_endpoints vms clusters subnets images storage tasks

# ─── 0. Real-host read-only enumeration (--target real / auto) ────────────────
# When auto-detection (or --target real) points us at a live Prism Central, do
# a credential-checked read-only sweep of the list endpoints and stop — the
# mock-only checks below (Prism schema validation, seed data, unknown-UUID 404s)
# and the write suite do not apply to a real cluster.
if [[ "$TARGET" == "real" ]]; then
  hdr "0. Real host — read-only enumeration (${VERSION}, user ${AUTH_USER})"
  check_body "List VMs"           GET "$EMU$VM_LIST" 200 '"data"'
  check_body "List clusters"      GET "$EMU$CLUSTERS" 200 '"data"'
  check_body "List subnets"       GET "$EMU$SUBNETS" 200 '"data"'
  check_body "List VPCs"          GET "$EMU$VPCS" 200 '"data"'
  check_body "List images"        GET "$EMU$IMAGES" 200 '"data"'
  check_body "List floating IPs"  GET "$EMU$FIPS" 200 '"data"'
  summary
fi

# ─── 1. Prism — schema mock reads & path validation ──────────────────────────
hdr "1. Prism — schema mock (GET)"
check_body "List VMs"        GET "$PRISM$VM_LIST"   200 '"data"'
check_body "List subnets"    GET "$PRISM$SUBNETS"   200 '"data"'
check_body "List clusters"   GET "$PRISM$CLUSTERS"  200 '"data"'
check_body "List images"     GET "$PRISM$IMAGES"    200 '"data"'
check_body "Get VM (valid UUID)"  GET "$PRISM$VM_LIST/$VALID_UUID" 200 '"extId"'
check      "Get VM (invalid UUID → 422)" GET "$PRISM$VM_LIST/not-a-uuid" 422
check_body "Unknown path → 404"  GET "$PRISM/api/does/not/exist" 404 'NO_PATH_MATCHED'

# v4.0-only legacy path variants (the emulator answers a1 / bare / ahv).
if [[ "$VERSION" == "v4.0" ]]; then
  hdr "1b. v4.0 legacy path variants"
  check "List VMs via v4.0.a1" GET "$EMU/api/vmm/v4.0.a1/config/vms" 200
  check "List VMs via v4.0 (bare)" GET "$EMU/api/vmm/v4.0/config/vms" 200
fi

# ─── 2. Emulator — health & seed reference data ──────────────────────────────
hdr "2. Emulator — health & seed reference data"
check "GET /health" GET "$EMU/health" 200
check "List clusters" GET "$EMU$CLUSTERS" 200
check "List subnets"  GET "$EMU$SUBNETS" 200
check "List images"   GET "$EMU$IMAGES"  200
check "List storage containers" GET "$EMU$SCS" 200

N="$(req GET "$EMU$SUBNETS"; echo "$RESP_BODY" | jget metadata.totalAvailableResults)"
[[ "$N" -ge 1 ]] && green "seed subnet present ($N)" || red "seed subnet missing ($N)"
N="$(req GET "$EMU$IMAGES"; echo "$RESP_BODY" | jget metadata.totalAvailableResults)"
[[ "$N" -ge 2 ]] && green "seed images present ($N)" || red "seed images missing ($N)"

# ─── 3. Emulator — unknown-resource reads (404) ──────────────────────────────
hdr "3. Emulator — unknown resources (GET → 404)"
check "GET unknown VM → 404"   GET "$EMU$VM_LIST/00000000-dead-beef-0000-000000000000" 404
check "GET unknown task → 404" GET "$EMU$TASKS/00000000-dead-beef-0000-000000000000" 404

# ─── 4. Emulator — catch-all proxy to Prism ──────────────────────────────────
hdr "4. Proxy to Prism (spec-covered, not emulated)"
# iam only ships a v4.0 spec; for v4.1+ pick a namespace that exists per version.
if [[ "$VERSION" == "v4.0" ]]; then
  check "GET /api/iam/v4.0/authz/roles via proxy" GET "$EMU/api/iam/v4.0/authz/roles" 200
else
  check "GET prism tasks list via proxy" GET "$EMU$TASKS" 200
fi

summary
