#!/usr/bin/env bash
# Thin runner for the authenticated REST API test suite.
# REPO_ROOT is the system root (/home/ubuntu/libcloud_nutanix), not "ROOT".
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source  "${REPO_ROOT}/libcloud.rest/.venv/bin/activate"
python3 "${REPO_ROOT}/test_script/test_all_rest_api_authenticated.py"
