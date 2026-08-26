#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Consolidated Nutanix v4 mock-stack test runner.
#
# Thin wrapper that runs the READ-ONLY suite (test_read.sh) then the WRITE
# suite (test_write.sh) back-to-back. For isolated runs, invoke either script
# directly:
#   ./scripts/test_read.sh   — enumeration + GET operations only (no mutations)
#   ./scripts/test_write.sh  — create/update/delete (mutating) operations
#
# Supersedes the three older, overlapping scripts:
#   * prism-test.sh      — Prism schema-mock + request-validation checks
#   * smoke-test.sh      — basic emulator health/seed/VM-CRUD checks
#   * test-emulator.sh   — full emulator lifecycle (VM, networking, VG, RP, proxy)
# (merge-specs.js / merge_specs.py are build tools, not tests.)
#
# Two output modes:
#   non-verbose (default)  — one ✓/✗ line per check, plus a summary.
#   --verbose / -v         — additionally prints EVERY HTTP request in detail
#                            (method, full URL, headers, body, status, response).
#
# Version selection (which minor of v4 to test):
#   --version v4.0|v4.1|v4.2|v4.3   (default v4.0; also accepts 4.1, v4.1.0, …)
#   Each version maps to its own Prism + emulator pair from docker-compose.yml:
#     v4.0 → Prism http://localhost:4010  Emulator https://localhost:9440
#     v4.1 → Prism http://localhost:4011  Emulator https://localhost:9441
#     v4.2 → Prism http://localhost:4012  Emulator https://localhost:9442
#     v4.3 → Prism http://localhost:4013  Emulator https://localhost:9443
#
# Target selection (which Nutanix to test against):
#   --target auto|real|mock            (default auto)
#   auto = the REAL Prism Central host when NUTANIX_HOST is set in my.env
#          (fallback .env), otherwise the local mock stack. real/mock force one.
#   real-host mode is READ-ONLY: it enumerates live endpoints over HTTP Basic
#   auth using LIBCLOUD_NTNX_USER/PASSWORD from test_script/tenant_vault_secret.env
#   and NUTANIX_HOST/PORT/API_VERSION/VERIFY_SSL from my.env; the write suite is
#   skipped automatically.
#
# Usage:
#   ./scripts/test.sh                          # v4.0, quiet
#   ./scripts/test.sh -v                       # v4.0, verbose
#   ./scripts/test.sh --version v4.3 --verbose
#   ./scripts/test.sh -V 4.1
#
# Exit code: total number of failed checks (0 = all passed).
# ─────────────────────────────────────────────────────────────────────────────

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$DIR/test_read.sh"  "$@"
R=$?
"$DIR/test_write.sh" "$@"
W=$?

exit $(( R + W ))
