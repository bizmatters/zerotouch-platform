#!/bin/bash

# ==============================================================================
# Config Parser Library
# ==============================================================================

parse_config() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        return 1
    fi
    
    if ! command -v yq &> /dev/null; then
        log_error "yq is required but not installed"
        return 1
    fi
    
    # Export config values
    export TEST_COMMAND=$(yq eval '.test.command // ""' "$config_file")
    export TEST_PATTERNS=$(yq eval '.test.test_patterns[0] // ""' "$config_file")
    export SERVICE_NAME=$(yq eval '.service.name' "$config_file")
    export NAMESPACE=$(yq eval '.service.namespace' "$config_file")
    
    log_info "Config loaded: service=$SERVICE_NAME, namespace=$NAMESPACE"
    if [[ -n "$TEST_COMMAND" ]]; then
        log_info "Test command: $TEST_COMMAND"
    fi
    if [[ -n "$TEST_PATTERNS" ]]; then
        log_info "Test patterns: $TEST_PATTERNS"
    fi
    
    return 0
}
