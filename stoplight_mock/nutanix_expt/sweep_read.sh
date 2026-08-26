#!/usr/bin/env bash
# =============================================================================
# sweep_read.sh — READ-ONLY sweep of the Nutanix v4 collection endpoints.
#
# Issues nothing but GET: it lists each of the eight collections below, for
# every API version from v4.0 through v4.3, and reports the HTTP response.
# Nothing on the target cluster is modified. The mutating counterpart is
# ./sweep_write.sh.
#
# Endpoints (see build_urls in sweep_lib.sh):
#   vms             /api/vmm/${api_version}/ahv/config/vms
#   subnets         /api/networking/${api_version}/config/subnets
#   tasks           /api/prism/${api_version}/config/tasks
#   securitygroups  /api/microseg/${api_version}/config/policies
#   vpcs            /api/networking/${api_version}/config/vpcs
#   floatingips     /api/networking/${api_version}/config/floating-ips
#   volumegroups    /api/volumes/${api_version}/config/volume-groups
#   recoverypoints  /api/dataprotection/${api_version}/config/recovery-points
#
# Two auth input modes:
#   auth=basic   USERNAME/PASSWORD are turned into a Basic header that is sent
#                on ALL URLs.
#   auth=cookie  USERNAME/PASSWORD are turned into a Basic header used only for
#                the first authentication; the session cookie it returns is
#                then reused as the header for every URL, and the Basic header
#                is never sent again.
#
# Two output modes:
#   verbose      full request and response headers + bodies for every call
#   non-verbose  the URL and the HTTP response only  (default)
#
# Usage:
#   ./sweep_read.sh auth=cookie
#   ./sweep_read.sh auth=basic verbose=1
#   ./sweep_read.sh auth=cookie api_version=v4.2 --ip 166.6.100.1 --port 9440
#   ./sweep_read.sh auth=basic --username admin --password secret --dry-run
#
# Exit code: number of failed checks (0 = all passed).
# =============================================================================

# ─── Configuration ───────────────────────────────────────────────────────────
# Override any of these on the command line or from the environment.
NUTANIX_HOST="${NUTANIX_HOST:-166.6.100.1}"
NUTANIX_PORT="${NUTANIX_PORT:-9440}"
api_version="${api_version:-}"        # empty = sweep every version, v4.0 → v4.3

USERNAME="${USERNAME:-admin}"
PASSWORD="${PASSWORD:-}"

auth="${auth:-cookie}"                # cookie | basic
verbose="${verbose:-0}"               # 1 = full headers + bodies
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  awk 'NR==1 {next} { if (substr($0,1,1)=="#") { sub(/^# ?/, ""); print } else exit }' "$0"
}

SCRIPT_TITLE="Nutanix v4 READ-ONLY sweep"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sweep_lib.sh"

banner

# One login for the whole run: in auth=cookie the cookie minted here is reused
# across every version below; in auth=basic this only verifies the credentials.
authenticate || exit 1

for v in "${VERSIONS[@]}"; do
  build_urls "$v"
  hdr "api_version=${v} — read-only sweep (auth in force: ${AUTH_MODE})"

  get_list "vms"            "$vms"
  get_list "subnets"        "$subnets"
  get_list "tasks"          "$tasks"
  get_list "securitygroups" "$securitygroups"
  get_list "vpcs"           "$vpcs"
  get_list "floatingips"    "$floatingips"
  get_list "volumegroups"   "$volumegroups"
  get_list "recoverypoints" "$recoverypoints"
done

summary
