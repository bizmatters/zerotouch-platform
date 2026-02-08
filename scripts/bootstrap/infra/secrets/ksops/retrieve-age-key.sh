#!/bin/bash
# Retrieve and decrypt Age private key from S3
# Usage: ENV=dev ./retrieve-age-key.sh
#
# Output: Age private key for GitHub org secrets

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="$SCRIPT_DIR/../../../helpers"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Validate ENV
if [ -z "${ENV:-}" ]; then
    echo -e "${RED}✗ Error: ENV environment variable not set${NC}"
    echo -e "${YELLOW}Usage: ENV=dev $0${NC}"
    echo -e "${YELLOW}Valid values: pr, dev, staging, prod${NC}"
    exit 1
fi

ENV_UPPER=$(echo "$ENV" | tr '[:lower:]' '[:upper:]')

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Retrieve Age Private Key from S3                          ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Environment: $ENV_UPPER${NC}"
echo ""

# Check for .env.local
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env.local"

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}✗ Error: $ENV_FILE not found${NC}"
    echo -e "${YELLOW}Create .env.local with ${ENV_UPPER}_HETZNER_S3_* variables${NC}"
    exit 1
fi

# Source .env.local
set -a
source "$ENV_FILE"
set +a

# Source S3 helpers
if [ ! -f "$HELPERS_DIR/s3-helpers.sh" ]; then
    echo -e "${RED}✗ Error: S3 helpers not found at $HELPERS_DIR/s3-helpers.sh${NC}"
    exit 1
fi

source "$HELPERS_DIR/s3-helpers.sh"

# Configure S3
echo -e "${BLUE}Configuring S3 credentials...${NC}"
if ! configure_s3_credentials "$ENV"; then
    echo -e "${RED}✗ Error: Failed to configure S3 credentials${NC}"
    echo -e "${YELLOW}Required variables: ${ENV_UPPER}_HETZNER_S3_*${NC}"
    exit 1
fi
echo -e "${GREEN}✓ S3 credentials configured${NC}"
echo ""

# Check if age is installed
if ! command -v age &> /dev/null; then
    echo -e "${RED}✗ Error: age not found${NC}"
    echo -e "${YELLOW}Install age: https://github.com/FiloSottile/age${NC}"
    exit 1
fi

# Retrieve Age key from S3
echo -e "${BLUE}Retrieving Age private key from S3...${NC}"
if ! AGE_PRIVATE_KEY=$(s3_retrieve_age_key); then
    echo -e "${RED}✗ Error: Failed to retrieve Age key from S3${NC}"
    echo -e "${YELLOW}Run setup-env-secrets.sh for $ENV environment first${NC}"
    exit 1
fi

# Trim whitespace and validate
AGE_PRIVATE_KEY=$(echo "$AGE_PRIVATE_KEY" | tr -d '[:space:]' | grep -o 'AGE-SECRET-KEY-1[A-Z0-9]*')

if [ -z "$AGE_PRIVATE_KEY" ]; then
    echo -e "${RED}✗ Error: Invalid Age private key format${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Age private key retrieved${NC}"
echo ""

# Display result
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Age Private Key for GitHub Org Secrets                    ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Secret Name:${NC} ${GREEN}SOPS_AGE_KEY_${ENV_UPPER}${NC}"
echo -e "${YELLOW}Secret Value:${NC}"
echo ""
echo "$AGE_PRIVATE_KEY"
echo ""
echo -e "${YELLOW}Add to GitHub:${NC}"
echo -e "  1. Go to: ${GREEN}https://github.com/organizations/{ORG}/settings/secrets/actions${NC}"
echo -e "  2. Click: ${GREEN}New organization secret${NC}"
echo -e "  3. Name: ${GREEN}SOPS_AGE_KEY_${ENV_UPPER}${NC}"
echo -e "  4. Value: ${GREEN}Copy the key above${NC}"
echo -e "  5. Visibility: ${GREEN}All repositories${NC}"
echo ""
