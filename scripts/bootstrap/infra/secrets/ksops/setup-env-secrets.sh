#!/bin/bash
# E2E script to setup environment-specific secrets
# Usage: ./setup-env-secrets.sh ENV
#
# This script orchestrates:
# 1. Generate Age keypair (or retrieve from S3)
# 2. Backup Age key to S3
# 3. Generate all encrypted secrets for the environment
#
# Prerequisites:
# - .env.local file with all secrets
# - S3 credentials in environment ({ENV}_HETZNER_S3_*)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Validate argument
if [ $# -ne 1 ]; then
    echo -e "${RED}Usage: $0 ENV${NC}"
    echo -e "${YELLOW}Valid values: pr, dev, staging, prod${NC}"
    echo ""
    echo -e "${YELLOW}Example:${NC}"
    echo -e "  ${GREEN}$0 dev${NC}"
    exit 1
fi

ENV="$1"
ENV_UPPER=$(echo "$ENV" | tr '[:lower:]' '[:upper:]')

# Validate ENV value
case "$ENV" in
    pr|dev|staging|prod) ;;
    *)
        echo -e "${RED}✗ Invalid ENV: $ENV${NC}"
        echo -e "${YELLOW}Valid values: pr, dev, staging, prod${NC}"
        exit 1
        ;;
esac

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   E2E Environment Secrets Setup                              ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Environment: $ENV_UPPER${NC}"
echo ""

# Check prerequisites
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env.local"

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}✗ Error: $ENV_FILE not found${NC}"
    echo -e "${YELLOW}Create .env.local with all secrets first${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Prerequisites checked${NC}"
echo ""

# Source .env.local for S3 credentials
set -a
source "$ENV_FILE"
set +a

# Step 1: Generate Age keypair
echo -e "${BLUE}[1/3] Generating Age keypair...${NC}"
export ENV="$ENV"
source "$SCRIPT_DIR/08b-generate-age-keys.sh"

if [ -z "${AGE_PRIVATE_KEY:-}" ]; then
    echo -e "${RED}✗ Failed to generate/retrieve Age key${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Age keypair ready${NC}"
echo ""

# Step 2: Backup to S3
echo -e "${BLUE}[2/3] Backing up Age key to S3...${NC}"
"$SCRIPT_DIR/08b-backup-age-to-s3.sh"

echo -e "${GREEN}✓ Age key backed up to S3${NC}"
echo ""

# Step 3: Generate encrypted secrets
echo -e "${BLUE}[3/3] Generating encrypted secrets...${NC}"

"$SCRIPT_DIR/generate-sops/generate-platform-sops.sh"

echo -e "${GREEN}✓ Encrypted secrets generated${NC}"
echo ""

# Summary
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Setup Complete                                             ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✅ Environment secrets setup complete for $ENV_UPPER${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Add Age private key to GitHub org secrets:"
echo -e "     ${GREEN}Name: SOPS_AGE_KEY_${ENV_UPPER}${NC}"
echo -e "     ${GREEN}Value: $AGE_PRIVATE_KEY${NC}"
echo ""
echo -e "  2. Commit encrypted secrets:"
echo -e "     ${GREEN}git add bootstrap/argocd/overlays/${NC}"
echo -e "     ${GREEN}git commit -m 'chore: setup $ENV secrets'${NC}"
echo -e "     ${GREEN}git push${NC}"
echo ""
echo -e "${YELLOW}To setup another environment:${NC}"
echo -e "  ${GREEN}$0 staging${NC}"
echo ""
