#!/bin/bash
set -euo pipefail

# ==============================================================================
# Test Runner CLI
# ==============================================================================
# Purpose: Unified test execution for all languages
# Usage: ./test-runner.sh exec --config ci/config.yaml --test <path> --artifacts <dir>
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load libraries
source "$SCRIPT_DIR/lib.logger.sh"
source "$SCRIPT_DIR/lib.config-parser.sh"
source "$SCRIPT_DIR/lib.language-detector.sh"

# Parse arguments
ACTION=""
CONFIG_FILE=""
TEST_PATH=""
ARTIFACTS_DIR="./artifacts"

while [[ $# -gt 0 ]]; do
    case $1 in
        exec)
            ACTION="exec"
            shift
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --test)
            TEST_PATH="$2"
            shift 2
            ;;
        --artifacts)
            ARTIFACTS_DIR="$2"
            shift 2
            ;;
        *)
            log_error "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# Validate arguments
if [[ "$ACTION" != "exec" ]]; then
    log_error "Usage: $0 exec --config <file> --test <path> [--artifacts <dir>]"
    exit 1
fi

if [[ -z "$CONFIG_FILE" ]] || [[ -z "$TEST_PATH" ]]; then
    log_error "Missing required arguments: --config and --test"
    exit 1
fi

log_info "=============================================="
log_info "Test Runner v1.0.0"
log_info "=============================================="
log_info "Config: $CONFIG_FILE"
log_info "Test: $TEST_PATH"
log_info "Artifacts: $ARTIFACTS_DIR"
log_info "=============================================="

# Create artifacts directory
mkdir -p "$ARTIFACTS_DIR"

# Parse config
if ! parse_config "$CONFIG_FILE"; then
    exit 1
fi

# Detect language from test_patterns
if [[ -z "$TEST_PATTERNS" ]]; then
    log_error "test.test_patterns not found in config"
    exit 1
fi

LANGUAGE=$(detect_language "$TEST_PATTERNS")
log_info "Detected language from patterns: $LANGUAGE"

# Select adapter
ADAPTER=""
case "$LANGUAGE" in
    node)
        ADAPTER="$SCRIPT_DIR/adapters.node-adapter.sh"
        ;;
    python)
        ADAPTER="$SCRIPT_DIR/adapters.python-adapter.sh"
        ;;
    go)
        ADAPTER="$SCRIPT_DIR/adapters.go-adapter.sh"
        ;;
    *)
        log_error "Unsupported language: $LANGUAGE"
        exit 1
        ;;
esac

# Execute adapter (already executable from ConfigMap defaultMode)
log_info "Executing adapter: $ADAPTER"
exec "$ADAPTER" "$TEST_PATH" "$TEST_COMMAND" "$ARTIFACTS_DIR"
