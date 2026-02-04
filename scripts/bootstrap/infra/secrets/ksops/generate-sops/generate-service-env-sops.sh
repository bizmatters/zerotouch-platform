#!/bin/bash
# Generate SOPS-encrypted *.secret.yaml from .env file
# Usage: ./generate-env-sops.sh [TENANT_NAME] [OUTPUT_BASE_DIR] [SOPS_CONFIG]
#
# Arguments:
#   TENANT_NAME: Optional tenant name to filter env vars (e.g., deepagents-runtime)
#   OUTPUT_BASE_DIR: Base directory for output (default: $REPO_ROOT/secrets)
#   SOPS_CONFIG: Path to .sops.yaml (default: auto-detect)
#
# Supported prefixes: PR_, DEV_, STAGING_, PROD_

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
TENANT_NAME="${1:-}"
OUTPUT_BASE_DIR="${2:-}"
SOPS_CONFIG="${3:-}"

# Detect current repo root
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ENV_FILE="$REPO_ROOT/.env"

# Set default output directory if not provided
if [ -z "$OUTPUT_BASE_DIR" ]; then
    SECRETS_DIR="$REPO_ROOT/secrets"
else
    SECRETS_DIR="$OUTPUT_BASE_DIR"
fi

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Generate SOPS-Encrypted Secrets                           ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ -n "$TENANT_NAME" ]; then
    echo -e "${GREEN}✓ Tenant: $TENANT_NAME${NC}"
fi
echo -e "${GREEN}✓ Repository: $REPO_ROOT${NC}"
echo -e "${GREEN}✓ Output directory: $SECRETS_DIR${NC}"

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

# Set SOPS config if provided
if [ -n "$SOPS_CONFIG" ] && [ -f "$SOPS_CONFIG" ]; then
    export SOPS_CONFIG_PATH="$SOPS_CONFIG"
    echo -e "${GREEN}✓ Using SOPS config: $SOPS_CONFIG${NC}"
fi

echo -e "${GREEN}✓ Reading from: $ENV_FILE${NC}"
echo ""

# Create secrets directory structure for each environment
mkdir -p "$SECRETS_DIR"

# Environment mapping: prefix -> overlay directory
# Using case statement for bash 3.x compatibility
get_env_dir() {
    case "$1" in
        PR) echo "pr" ;;
        DEV) echo "dev" ;;
        STAGING) echo "staging" ;;
        PROD) echo "production" ;;
        *) echo "" ;;
    esac
}

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
    # PR_DATABASE_URL -> env=PR, secret=database-url
    if [[ "$name" =~ ^(PR|DEV|STAGING|PROD)_(.+)$ ]]; then
        env_prefix="${BASH_REMATCH[1]}"
        env=$(get_env_dir "$env_prefix")
        secret_name=$(echo "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    else
        continue
    fi
    
    # Create environment-specific directory
    ENV_SECRETS_DIR="$SECRETS_DIR/$env"
    mkdir -p "$ENV_SECRETS_DIR"
    
    # Create secret YAML file
    SECRET_FILE="$ENV_SECRETS_DIR/${secret_name}.secret.yaml"
    
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
    SOPS_CMD="sops -e -i"
    if [ -n "$SOPS_CONFIG" ] && [ -f "$SOPS_CONFIG" ]; then
        SOPS_CMD="sops --config $SOPS_CONFIG -e -i"
    fi
    
    if $SOPS_CMD "$SECRET_FILE" 2>/dev/null; then
        echo -e "${GREEN}✓ Created: $env/${secret_name}.secret.yaml${NC}"
        ((SECRET_COUNT++))
    else
        echo -e "${RED}✗ Failed to encrypt: $env/${secret_name}.secret.yaml${NC}"
        rm -f "$SECRET_FILE"
    fi
    
done < "$ENV_FILE"

if [ $SECRET_COUNT -eq 0 ]; then
    echo -e "${YELLOW}⚠️  No secrets found with supported prefixes${NC}"
    echo -e "${YELLOW}⚠️  Supported prefixes: PR_, DEV_, STAGING_, PROD_${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}✓ Created $SECRET_COUNT encrypted secret files${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
if [ -n "$TENANT_NAME" ]; then
    echo -e "  1. Review: ${GREEN}ls -la tenants/$TENANT_NAME/overlays/*/secrets/${NC}"
    echo -e "  2. Commit: ${GREEN}git add tenants/$TENANT_NAME/ && git commit -m 'chore: update $TENANT_NAME secrets'${NC}"
else
    echo -e "  1. Review: ${GREEN}ls -la $SECRETS_DIR${NC}"
    echo -e "  2. Commit: ${GREEN}git add secrets/ && git commit -m 'chore: update secrets'${NC}"
fi
echo -e "  3. Push: ${GREEN}git push${NC}"
echo ""
echo -e "${GREEN}✅ Encryption complete${NC}"

exit 0
