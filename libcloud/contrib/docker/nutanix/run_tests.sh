#!/usr/bin/env bash
# Run Nutanix libcloud driver tests inside Docker.
#
# Usage:
#   ./run_tests.sh              # unit tests only
#   ./run_tests.sh integration  # unit + emulator integration tests
#
# Prerequisites for integration:
#   cd ../../../stoplight_mock && docker compose up -d

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

MODE="${1:-unit}"

if [[ "${MODE}" == "integration" ]]; then
  export NUTANIX_INTEGRATION_TESTS=1
  TEST_MODULES=(
    "libcloud.test.compute.test_nutanix"
    "libcloud.test.compute.test_nutanix_emulator"
  )
else
  export NUTANIX_INTEGRATION_TESTS=0
  TEST_MODULES=("libcloud.test.compute.test_nutanix")
fi

docker compose run --rm --build nutanix-driver-test \
  python -m unittest -v "${TEST_MODULES[@]}"
