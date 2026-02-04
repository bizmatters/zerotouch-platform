#!/bin/bash
# Bootstrap Configuration Helper
# Manages centralized bootstrap configuration in .zerotouch-cache/bootstrap-config.json
#
# Usage:
#   source "$SCRIPT_DIR/helpers/bootstrap-config.sh"
#   write_bootstrap_config "dev"
#   ENV=$(read_bootstrap_env)

set -e

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ZEROTOUCH_CACHE_DIR="$REPO_ROOT/.zerotouch-cache"
BOOTSTRAP_CONFIG_FILE="$ZEROTOUCH_CACHE_DIR/bootstrap-config.json"

# Ensure cache directory exists
ensure_cache_dir() {
    mkdir -p "$ZEROTOUCH_CACHE_DIR"
}

# Write bootstrap configuration
write_bootstrap_config() {
    local env="$1"
    local skip_cache="${SKIP_CACHE:-false}"
    
    if [[ -z "$env" ]]; then
        echo "Error: Environment parameter required" >&2
        return 1
    fi
    
    ensure_cache_dir
    
    # If config exists and skip_cache is true, reuse it
    if [[ -f "$BOOTSTRAP_CONFIG_FILE" ]] && [[ "$skip_cache" == "true" ]]; then
        echo "Reusing existing bootstrap config" >&2
        return 0
    fi
    
    # Create new config
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    cat > "$BOOTSTRAP_CONFIG_FILE" <<EOF
{
  "environment": "$env",
  "timestamp": "$timestamp"
}
EOF
    
    echo "Bootstrap config created: $env" >&2
}

# Read environment from bootstrap configuration
read_bootstrap_env() {
    if [[ ! -f "$BOOTSTRAP_CONFIG_FILE" ]]; then
        echo "Error: Bootstrap config not found at $BOOTSTRAP_CONFIG_FILE" >&2
        echo "Run master bootstrap script first to initialize configuration" >&2
        return 1
    fi
    
    if command -v jq &> /dev/null; then
        local env=$(jq -r '.environment // empty' "$BOOTSTRAP_CONFIG_FILE")
        if [[ -z "$env" ]]; then
            echo "Error: Environment not found in bootstrap config" >&2
            return 1
        fi
        echo "$env"
    else
        echo "Error: jq not available to read bootstrap config" >&2
        return 1
    fi
}

# Get bootstrap config file path
get_bootstrap_config_path() {
    echo "$BOOTSTRAP_CONFIG_FILE"
}

# Get zerotouch cache directory
get_zerotouch_cache_dir() {
    echo "$ZEROTOUCH_CACHE_DIR"
}
