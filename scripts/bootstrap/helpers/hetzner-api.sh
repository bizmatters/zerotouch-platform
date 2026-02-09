#!/bin/bash
# Hetzner API Helper Functions
# Shared functions for interacting with Hetzner Cloud API
#
# Usage: source this file in scripts that need Hetzner API access
#   source "$SCRIPT_DIR/helpers/hetzner-api.sh"

HETZNER_API_URL="https://api.hetzner.cloud/v1"

# Auto-detect environment from bootstrap config
if [[ -z "$HETZNER_API_TOKEN" ]]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    BOOTSTRAP_CONFIG="$REPO_ROOT/.zerotouch-cache/bootstrap-config.json"
    
    if [[ -f "$BOOTSTRAP_CONFIG" ]] && command -v jq &> /dev/null; then
        ENV=$(jq -r '.environment // empty' "$BOOTSTRAP_CONFIG")
        if [[ -n "$ENV" ]]; then
            ENV_UPPER=$(echo "$ENV" | tr '[:lower:]' '[:upper:]')
            TOKEN_VAR="${ENV_UPPER}_HCLOUD_TOKEN"
            HETZNER_API_TOKEN="${!TOKEN_VAR}"
        fi
    fi
fi

# Function to make Hetzner API call
hetzner_api() {
    local method="$1"
    local endpoint="$2"
    local data="$3"

    if [[ -n "$data" ]]; then
        curl -s -X "$method" \
            -H "Authorization: Bearer $HETZNER_API_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$data" \
            "$HETZNER_API_URL$endpoint"
    else
        curl -s -X "$method" \
            -H "Authorization: Bearer $HETZNER_API_TOKEN" \
            "$HETZNER_API_URL$endpoint"
    fi
}

# Function to get server ID by IP address
get_server_id_by_ip() {
    local ip="$1"

    if [[ -z "$HETZNER_API_TOKEN" ]]; then
        echo "Error: HETZNER_API_TOKEN not set" >&2
        return 1
    fi

    local servers=$(hetzner_api "GET" "/servers")
    local server_id=$(echo "$servers" | jq -r ".servers[] | select(.public_net.ipv4.ip == \"$ip\") | .id")

    if [[ -z "$server_id" || "$server_id" == "null" ]]; then
        echo "Error: Could not find server with IP: $ip" >&2
        return 1
    fi

    echo "$server_id"
}
