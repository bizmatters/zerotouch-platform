#!/bin/bash
# Environment Variable Helpers
# Shared functions for handling .env files with multi-line values

# Write variable to .env file
# Handles multi-line values by base64 encoding them
# Usage: write_env_var "VAR_NAME" "value" "/path/to/.env"
write_env_var() {
    local var_name="$1"
    local value="$2"
    local env_file="$3"
    
    # Trim trailing newline (yq adds one)
    value="${value%$'\n'}"
    
    # Check if value is multi-line (has internal newlines)
    if [[ "$value" == *$'\n'* ]]; then
        # Multi-line: base64 encode
        local encoded=$(echo "$value" | base64 | tr -d '\n')
        printf '%s=%s\n' "$var_name" "$encoded" >> "$env_file"
    else
        # Single line: write as-is
        printf '%s=%s\n' "$var_name" "$value" >> "$env_file"
    fi
}

# Get variable value from environment
# Automatically decodes base64 if needed (detects by trying to decode)
# Usage: value=$(get_env_var "VAR_NAME")
get_env_var() {
    local var_name="$1"
    local value="${!var_name:-}"
    
    [ -z "$value" ] && return 1
    
    # Try to base64 decode - if it works and contains newlines, it was encoded
    local decoded
    if decoded=$(echo "$value" | base64 -d 2>/dev/null) && echo "$decoded" | grep -q $'\n'; then
        echo "$decoded"
    else
        echo "$value"
    fi
}
