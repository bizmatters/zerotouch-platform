#!/bin/bash
# Bootstrap script to inject platform secrets using SOPS
# Usage: ./08-inject-sops-secrets.sh
#
# This script reads .env.sops and creates SOPS-encrypted secrets for all services

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ENV_FILE="$REPO_ROOT/.env.sops"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Platform Secrets Injection - SOPS                         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if .env.sops exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}✗ Error: $ENV_FILE not found${NC}"
    echo -e "${YELLOW}Create .env.sops with all platform secrets${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Found $ENV_FILE${NC}"
echo ""

# Load environment variables from .env.sops
set -a
source "$ENV_FILE"
set +a

# Determine tenants repo path
TENANTS_REPO="${TENANTS_REPO_PATH:-$REPO_ROOT/../zerotouch-tenants}"
if [ ! -d "$TENANTS_REPO" ]; then
    echo -e "${RED}✗ Error: Tenants repository not found at $TENANTS_REPO${NC}"
    exit 1
fi

export TENANTS_REPO_PATH="$TENANTS_REPO"

# Get list of services from tenants directory
SERVICES=$(ls -d "$TENANTS_REPO/tenants"/*/ 2>/dev/null | xargs -n 1 basename)

if [ -z "$SERVICES" ]; then
    echo -e "${YELLOW}⚠️  No services found in tenants directory${NC}"
    exit 0
fi

echo -e "${BLUE}Found services:${NC}"
echo "$SERVICES" | while read service; do
    echo -e "  - $service"
done
echo ""

# Process each service for each environment
TOTAL_SECRETS=0
FAILED_SERVICES=0

for service in $SERVICES; do
    echo -e "${BLUE}Processing service: $service${NC}"
    
    for env in dev staging production; do
        echo -e "${YELLOW}  Environment: $env${NC}"
        
        # Call sync-secrets-to-sops.sh
        if "$REPO_ROOT/scripts/release/template/sync-secrets-to-sops.sh" "$service" "$env" 2>&1 | grep -q "Created.*encrypted secrets"; then
            COUNT=$(echo "$output" | grep -o "Created [0-9]* encrypted secrets" | grep -o "[0-9]*")
            TOTAL_SECRETS=$((TOTAL_SECRETS + COUNT))
            echo -e "${GREEN}  ✓ $env: $COUNT secrets${NC}"
        else
            echo -e "${YELLOW}  ⚠️  $env: No secrets or failed${NC}"
        fi
    done
    echo ""
done

# Commit all changes in one commit
cd "$TENANTS_REPO"
if git diff --cached --quiet; then
    echo -e "${YELLOW}⚠️  No changes to commit${NC}"
else
    git commit -m "chore: inject platform secrets for all services" || {
        echo -e "${RED}✗ Failed to commit changes${NC}"
        echo -e "${YELLOW}Rolling back...${NC}"
        git reset HEAD
        exit 1
    }
    echo -e "${GREEN}✓ All secrets committed to Git${NC}"
fi

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Summary                                                    ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✓ Total secrets created: $TOTAL_SECRETS${NC}"
if [ $FAILED_SERVICES -gt 0 ]; then
    echo -e "${YELLOW}⚠️  Failed services: $FAILED_SERVICES${NC}"
fi
echo ""

exit 0
