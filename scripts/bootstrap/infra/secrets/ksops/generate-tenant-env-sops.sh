#!/bin/bash
# Generate SOPS-encrypted *.secret.yaml from .env file
# Usage: ./generate-env-sops.sh
#
# This script is repo-agnostic - run it in any repo to encrypt secrets
# Supported prefixes: PR_, DEV_, STAGING_, PROD_

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Detect current repo root
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ENV_FILE="$REPO_ROOT/.env"
SECRETS_DIR="$REPO_ROOT/secrets"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Generate SOPS-Encrypted Secrets                           ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if .env file exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}✗ Error: $ENV_FILE not found${NC}"
    echo -e "${YELLOW}Create .env file with secrets using supported prefixes:${NC}"
    echo -e "  ${GREEN}PR_DATABASE_URL=...${NC}"
    echo -e "  ${GREEN}DEV_API_KEY=...${NC}"
    echo -e "  ${GREEN}STAGING_DATABASE_URL=...${NC}"
    echo -e "  ${GREEN}PROD_API_KEY=...${NC}"
    exit 1
fi

# Check if sops is installed
if ! command -v sops &> /dev/null; then
    echo -e "${RED}✗ Error: sops not found${NC}"
    echo -e "${YELLOW}Install sops: https://github.com/getsops/sops${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Repository: $REPO_ROOT${NC}"
echo -e "${GREEN}✓ Reading from: $ENV_FILE${NC}"
echo ""

# Create secrets directory
mkdir -p "$SECRETS_DIR"

# Supported environment prefixes
SUPPORTED_PREFIXES="^(PR_|DEV_|STAGING_|PROD_)"

# Read and process secrets
echo -e "${BLUE}Processing secrets with supported prefixes (PR_, DEV_, STAGING_, PROD_)...${NC}"

SECRET_COUNT=0
while IFS='=' read -r name value || [ -n "$name" ]; do
    # Skip empty lines and comments
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    
    # Check if matches supported prefix
    if [[ ! "$name" =~ $SUPPORTED_PREFIXES ]]; then
        continue
    fi
    
    # Extract environment and secret name
    # PR_DATABASE_URL -> env=pr, secret=database-url
    if [[ "$name" =~ ^(PR|DEV|STAGING|PROD)_(.+)$ ]]; then
        env=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
        secret_name=$(echo "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    else
        continue
    fi
    
    # Create secret YAML file
    SECRET_FILE="$SECRETS_DIR/${secret_name}.${env}.secret.yaml"
    
    cat > "$SECRET_FILE" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
type: Opaque
stringData:
  value: ${value}
EOF
    
    # Encrypt with SOPS
    if sops -e -i "$SECRET_FILE" 2>/dev/null; then
        echo -e "${GREEN}✓ Created: ${secret_name}.${env}.secret.yaml${NC}"
        ((SECRET_COUNT++))
    else
        echo -e "${RED}✗ Failed to encrypt: ${secret_name}.${env}.secret.yaml${NC}"
        rm -f "$SECRET_FILE"
    fi
    
done < "$ENV_FILE"

if [ $SECRET_COUNT -eq 0 ]; then
    echo -e "${YELLOW}⚠️  No secrets found with supported prefixes${NC}"
    echo -e "${YELLOW}⚠️  Supported prefixes: PR_, DEV_, STAGING_, PROD_${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}✓ Created $SECRET_COUNT encrypted secret files in: $SECRETS_DIR${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Review: ${GREEN}ls -la $SECRETS_DIR${NC}"
echo -e "  2. Commit: ${GREEN}git add secrets/ && git commit -m 'chore: update secrets'${NC}"
echo -e "  3. Push: ${GREEN}git push${NC}"
echo ""
echo -e "${GREEN}✅ Encryption complete${NC}"

exit 0
