#!/bin/bash
# Environment Variable Helpers
# Shared functions for handling .env files with multi-line values

# Encode multi-line value to base64 for .env storage
# Usage: encoded=$(encode_multiline_value "$value")
encode_multiline_value() {
    local value="$1"
    echo "$value" | base64 | tr -d '\n'
}

# Decode base64 value back to multi-line
# Usage: decoded=$(decode_multiline_value "$encoded_value")
decode_multiline_value() {
    local encoded="$1"
    echo "$encoded" | base64 -d
}

# Write variable to .env file
# Handles multi-line values by base64 encoding them
# Usage: write_env_var "VAR_NAME" "value" "/path/to/.env"
write_env_var() {
    local var_name="$1"
    local value="$2"
    local env_file="$3"
    
    # Check if value is multi-line
    if echo "$value" | grep -q $'\n'; then
        # Multi-line: base64 encode and mark with _B64 suffix
        local encoded=$(encode_multiline_value "$value")
        printf '%s_B64=%s\n' "$var_name" "$encoded" >> "$env_file"
    else
        # Single line: write as-is
        printf '%s=%s\n' "$var_name" "$value" >> "$env_file"
    fi
}

# Get variable value from environment
# Automatically decodes if it has _B64 suffix
# Usage: value=$(get_env_var "VAR_NAME")
get_env_var() {
    local var_name="$1"
    local b64_var_name="${var_name}_B64"
    
    # Check if base64 encoded version exists
    if [ -n "${!b64_var_name:-}" ]; then
        decode_multiline_value "${!b64_var_name}"
    elif [ -n "${!var_name:-}" ]; then
        echo "${!var_name}"
    fi
}
