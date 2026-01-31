#!/bin/bash
# Sync GitHub Secrets to SOPS-encrypted YAML files
# Usage: ./sync-secrets-to-sops.sh <service-name> <environment>
#
# This script reads GitHub Secrets and creates SOPS-encrypted YAML files

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
if [ "$#" -ne 2 ]; then
    echo -e "${RED}Usage:${NC} $0 <service-name> <environment>"
    echo ""
    echo "Arguments:"
    echo "  <service-name>  Service name (e.g., identity-service)"
    echo "  <environment>   Environment (dev, staging, production)"
    exit 1
fi

SERVICE_NAME="$1"
ENVIRONMENT="$2"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Sync Secrets to SOPS                                       ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Service: $SERVICE_NAME${NC}"
echo -e "${GREEN}Environment: $ENVIRONMENT${NC}"
echo ""

# Check required tools
if ! command -v sops &> /dev/null; then
    echo -e "${RED}✗ Error: sops not found${NC}"
    exit 1
fi

# Determine tenants repo path
TENANTS_REPO="${TENANTS_REPO_PATH:-../zerotouch-tenants}"
if [ ! -d "$TENANTS_REPO" ]; then
    echo -e "${RED}✗ Error: Tenants repository not found at $TENANTS_REPO${NC}"
    exit 1
fi

# Create secrets directory
SECRETS_DIR="$TENANTS_REPO/tenants/$SERVICE_NAME/overlays/$ENVIRONMENT/secrets"
mkdir -p "$SECRETS_DIR"

echo -e "${GREEN}✓ Secrets directory: $SECRETS_DIR${NC}"
echo ""

# Change to tenants repo for SOPS to find .sops.yaml
cd "$TENANTS_REPO"

# Read GitHub Secrets with pattern {ENVIRONMENT}_{SECRET_NAME}
ENV_PREFIX=$(echo "$ENVIRONMENT" | tr '[:lower:]' '[:upper:]')
ENV_PREFIX="${ENV_PREFIX}_"
SECRET_COUNT=0

# Get all environment variables matching the pattern
for var in $(compgen -e | grep "^${ENV_PREFIX}"); do
    SECRET_NAME="${var#$ENV_PREFIX}"
    SECRET_VALUE="${!var}"
    
    if [ -z "$SECRET_VALUE" ]; then
        echo -e "${YELLOW}⚠️  Skipping empty secret: $SECRET_NAME${NC}"
        continue
    fi
    
    # Convert secret name to lowercase for file name
    FILE_NAME=$(echo "$SECRET_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    SECRET_FILE="tenants/$SERVICE_NAME/overlays/$ENVIRONMENT/secrets/${FILE_NAME}.secret.yaml"
    
    echo -e "${BLUE}Creating secret: $SECRET_NAME${NC}"
    
    # Create secret YAML
    cat > "$SECRET_FILE" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${FILE_NAME}
  namespace: ${SERVICE_NAME}
type: Opaque
stringData:
  value: ${SECRET_VALUE}
EOF
    
    # Encrypt with SOPS
    sops -e -i "$SECRET_FILE"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Encrypted: $FILE_NAME.secret.yaml${NC}"
        SECRET_COUNT=$((SECRET_COUNT + 1))
    else
        echo -e "${RED}✗ Failed to encrypt: $FILE_NAME.secret.yaml${NC}"
        exit 1
    fi
done

echo ""
echo -e "${GREEN}✓ Created $SECRET_COUNT encrypted secrets${NC}"
echo ""

# Commit changes
git add "tenants/$SERVICE_NAME/overlays/$ENVIRONMENT/secrets/"
git commit -m "chore: update secrets for $SERVICE_NAME [$ENVIRONMENT]" || echo -e "${YELLOW}⚠️  No changes to commit${NC}"

echo -e "${GREEN}✓ Changes committed to Git${NC}"
echo ""

exit 0
