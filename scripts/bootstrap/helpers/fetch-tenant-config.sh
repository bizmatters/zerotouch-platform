#!/bin/bash
# Fetch tenant configuration from private zerotouch-tenants repository
#
# Usage:
#   source ./helpers/fetch-tenant-config.sh <ENV> [--use-cache]
#   # Sets: TENANT_CONFIG_FILE

set -e

ENV="$1"
USE_CACHE=false

if [[ "$2" == "--use-cache" ]]; then
    USE_CACHE=true
fi

# If ENV not provided, read from bootstrap config
if [[ -z "$ENV" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR" && while [[ ! -d .git && $(pwd) != "/" ]]; do cd ..; done; pwd))"
    source "$REPO_ROOT/scripts/bootstrap/helpers/bootstrap-config.sh"
    ENV=$(read_bootstrap_env)
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to read environment from bootstrap config" >&2
        exit 1
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Find repository root by looking for .git directory
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR" && while [[ ! -d .git && $(pwd) != "/" ]]; do cd ..; done; pwd))"
CACHE_DIR="$REPO_ROOT/.zerotouch-cache/tenants-cache"
ENV_FILE="$CACHE_DIR/environments/$ENV/talos-values.yaml"

# Get tenant repo credentials from environment variables
GITHUB_USERNAME="${BOT_GITHUB_USERNAME:-${GITHUB_REPOSITORY_OWNER:-${ORG_NAME:-arun4infra}}}"

# Try GitHub App authentication first, fallback to PAT
if [[ -n "$GIT_APP_ID" && -n "$GIT_APP_INSTALLATION_ID" && -n "$GIT_APP_PRIVATE_KEY" && -n "$TENANTS_REPO_NAME" ]]; then
    echo "✓ Generating GitHub App token..." >&2
    
    # Decode private key if it's base64-encoded (multi-line values are encoded in .env)
    if echo "$GIT_APP_PRIVATE_KEY" | base64 -d &>/dev/null && ! echo "$GIT_APP_PRIVATE_KEY" | grep -q "BEGIN"; then
        GIT_APP_PRIVATE_KEY=$(echo "$GIT_APP_PRIVATE_KEY" | base64 -d)
    fi
    
    # Generate JWT for GitHub App
    NOW=$(date +%s)
    IAT=$((NOW - 60))
    EXP=$((NOW + 600))
    
    HEADER='{"alg":"RS256","typ":"JWT"}'
    PAYLOAD="{\"iat\":${IAT},\"exp\":${EXP},\"iss\":\"${GIT_APP_ID}\"}"
    
    HEADER_B64=$(echo -n "$HEADER" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
    PAYLOAD_B64=$(echo -n "$PAYLOAD" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
    
    SIGNATURE=$(echo -n "${HEADER_B64}.${PAYLOAD_B64}" | openssl dgst -sha256 -sign <(echo "$GIT_APP_PRIVATE_KEY") | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
    JWT="${HEADER_B64}.${PAYLOAD_B64}.${SIGNATURE}"
    
    # Get installation access token
    TOKEN_RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bearer $JWT" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/${GIT_APP_INSTALLATION_ID}/access_tokens")
    
    GITHUB_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token // empty')
    
    if [[ -z "$GITHUB_TOKEN" ]]; then
        echo "Error: Failed to generate GitHub App token" >&2
        echo "API Response: $TOKEN_RESPONSE" >&2
        exit 1
    fi
    
    TENANT_USERNAME="x-access-token"
    TENANT_PASSWORD="$GITHUB_TOKEN"
    TENANT_REPO_URL="https://github.com/${ORG_NAME:-${GITHUB_USERNAME}}/${TENANTS_REPO_NAME}.git"
    echo "✓ Using GitHub App authentication" >&2
else
    echo "Error: Tenant repository credentials not available" >&2
    echo "Set: GIT_APP_ID, GIT_APP_INSTALLATION_ID, GIT_APP_PRIVATE_KEY, TENANTS_REPO_NAME, ORG_NAME" >&2
    exit 1
fi

# Convert HTTPS URL to include credentials
TENANT_REPO_AUTH_URL=$(echo "$TENANT_REPO_URL" | sed "s|https://|https://${TENANT_USERNAME}:${TENANT_PASSWORD}@|")

# Use cache if requested and exists
if [[ "$USE_CACHE" == "true" ]] && [[ -f "$ENV_FILE" ]]; then
    echo "✓ Using cached tenant config" >&2
    export TENANT_CONFIG_FILE="$ENV_FILE"
    export TENANT_CACHE_DIR="$CACHE_DIR"
    return 0
fi

# Clone or update cache
if [[ -d "$CACHE_DIR/.git" ]]; then
    echo "Updating tenant config cache..." >&2
    cd "$CACHE_DIR"
    git fetch origin main --quiet 2>/dev/null || {
        echo "Error: Failed to fetch from tenant repository" >&2
        exit 1
    }
    git reset --hard origin/main --quiet
else
    echo "Cloning tenant config repository..." >&2
    rm -rf "$CACHE_DIR"
    
    # Sparse checkout - only environments folder
    git clone --filter=blob:none --no-checkout --depth 1 --branch main \
        "$TENANT_REPO_AUTH_URL" "$CACHE_DIR" --quiet 2>/dev/null || {
        echo "Error: Failed to clone tenant repository" >&2
        echo "Check credentials: BOT_GITHUB_TOKEN, TENANTS_REPO_NAME" >&2
        exit 1
    }
    
    cd "$CACHE_DIR"
    git sparse-checkout init --cone 2>/dev/null
    git sparse-checkout set environments 2>/dev/null
    git checkout main --quiet 2>/dev/null
    git pull origin main --quiet 2>/dev/null
fi

# Verify environment file exists
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: Environment config not found: $ENV" >&2
    echo "Path: $ENV_FILE" >&2
    exit 1
fi

echo "✓ Tenant config fetched: $ENV" >&2

export TENANT_CONFIG_FILE="$ENV_FILE"
export TENANT_CACHE_DIR="$CACHE_DIR"
