#!/bin/bash
# Sync Service Secrets to AWS SSM - Production Grade
# Usage: ./sync-secrets-to-ssm.sh <service-name> <env> <secrets-block>

set -euo pipefail

SERVICE_NAME="$1"
ENV="$2"
SECRETS_BLOCK="$3"

# Validate Inputs
if [[ -z "$SERVICE_NAME" || -z "$ENV" ]]; then
    echo "❌ Usage: $0 <service-name> <env> <secrets-block>"
    exit 1
fi

if [[ -z "$SECRETS_BLOCK" ]]; then
    echo "ℹ️  No secrets provided for $ENV. Skipping sync."
    exit 0
fi

# Validate AWS CLI is available
if ! command -v aws &> /dev/null; then
    echo "❌ AWS CLI not found. Please install AWS CLI."
    exit 1
fi

# Validate AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo "❌ AWS credentials not configured or invalid."
    exit 1
fi

echo "🔐 Syncing secrets for $SERVICE_NAME [$ENV]..."

# Process Secrets
# Note: Secrets are passed directly via environment variables, no decoding needed
while IFS='=' read -r key value; do
    # 1. Skip empty/comment lines
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    
    # 2. Guardrail: Enforce Underscore Convention
    if [[ "$key" =~ [-] ]]; then
        echo "❌ ERROR: Hyphens not allowed in secret keys: '$key'. Use underscores (e.g., DATABASE_URL)."
        exit 1
    fi
    
    # 3. Normalization: DATABASE_URL -> database_url
    # Keep underscores to match platform standard
    PARAM_KEY=$(echo "$key" | tr '[:upper:]' '[:lower:]')
    
    # 4. Construct Path: /zerotouch/staging/identity-service/database_url
    SSM_PATH="/zerotouch/${ENV}/${SERVICE_NAME}/${PARAM_KEY}"
    
    echo "   -> Pushing $key to $SSM_PATH"
    
    # 5. Push to AWS (Quietly)
    aws ssm put-parameter \
        --name "$SSM_PATH" \
        --value "$value" \
        --type "SecureString" \
        --overwrite \
        --no-cli-pager > /dev/null
done <<< "$SECRETS_BLOCK"

echo "✅ Secrets synced successfully."
