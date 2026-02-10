#!/bin/bash
set -euo pipefail

# ==============================================================================
# Python Test Adapter
# ==============================================================================

TEST_PATH="$1"
TEST_COMMAND="${2:-}"
ARTIFACTS_DIR="${3:-./artifacts}"

source "$(dirname "${BASH_SOURCE[0]}")/lib.logger.sh"

log_info "Python adapter: Running test $TEST_PATH"

# Use test command from config
if [[ -z "$TEST_COMMAND" ]]; then
    log_error "test.command not specified in ci/config.yaml"
    exit 1
fi

log_info "Running: $TEST_COMMAND $TEST_PATH"
exec $TEST_COMMAND "$TEST_PATH"
