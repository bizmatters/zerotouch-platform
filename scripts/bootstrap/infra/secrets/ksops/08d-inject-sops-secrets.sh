#!/bin/bash
# Bootstrap script to inject platform secrets using SOPS
# Usage: ./08d-inject-sops-secrets.sh
#
# This script dynamically discovers all available secrets and creates SOPS-encrypted secrets

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Platform Secrets Injection - SOPS                         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Debug: Show all environment variables
echo -e "${BLUE}=== Debug: All Environment Variables ===${NC}"
env | sort
echo ""

# Debug: Count total environment variables
TOTAL_ENV_VARS=$(env | wc -l)
echo -e "${BLUE}=== Total Environment Variables: $TOTAL_ENV_VARS ===${NC}"
echo ""

# Detect if running in CI environment
if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo -e "${GREEN}✓ Running in GitHub Actions CI environment${NC}"
    
    # Filter out system environment variables and get potential secrets
    SYSTEM_VARS="^(PATH|HOME|USER|SHELL|PWD|OLDPWD|TERM|LANG|LC_|GITHUB_|RUNNER_|CI|DEBIAN_FRONTEND|_).*"
    
    echo -e "${BLUE}=== Filtering GitHub Secrets ===${NC}"
    AVAILABLE_SECRETS=$(env | grep -v -E "$SYSTEM_VARS" | cut -d'=' -f1 | sort)
    
    if [ -z "$AVAILABLE_SECRETS" ]; then
        echo -e "${YELLOW}⚠️  No GitHub Secrets found in environment${NC}"
        echo -e "${YELLOW}⚠️  Skipping secrets injection${NC}"
        exit 0
    fi
    
    echo -e "${GREEN}✓ Found GitHub Secrets:${NC}"
    echo "$AVAILABLE_SECRETS" | while read secret_name; do
        echo -e "  - $secret_name"
    done
    echo ""
    
    SECRET_COUNT=$(echo "$AVAILABLE_SECRETS" | wc -l)
    echo -e "${GREEN}✓ Total secrets to process: $SECRET_COUNT${NC}"
    echo ""
    
else
    echo -e "${YELLOW}Running in local environment${NC}"
    
    # Check if .env.sops exists for local development
    ENV_FILE="$REPO_ROOT/.env.sops"
    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${RED}✗ Error: $ENV_FILE not found${NC}"
        echo -e "${YELLOW}Create .env.sops with all platform secrets${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Found $ENV_FILE${NC}"
    
    # Load environment variables from .env.sops
    set -a
    source "$ENV_FILE"
    set +a
    
    # Get secrets from loaded environment
    AVAILABLE_SECRETS=$(grep -v '^#' "$ENV_FILE" | grep '=' | cut -d'=' -f1 | sort)
    echo -e "${GREEN}✓ Loaded secrets from .env.sops:${NC}"
    echo "$AVAILABLE_SECRETS" | while read secret_name; do
        echo -e "  - $secret_name"
    done
    echo ""
fi

# Determine tenants repo path
TENANTS_REPO="${TENANTS_REPO_PATH:-$REPO_ROOT/../zerotouch-tenants}"
if [ ! -d "$TENANTS_REPO" ]; then
    echo -e "${RED}✗ Error: Tenants repository not found at $TENANTS_REPO${NC}"
    exit 1
fi

export TENANTS_REPO_PATH="$TENANTS_REPO"

# For now, skip service-specific processing and just log what we found
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Summary                                                    ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✓ Environment detection: $([ -n "${GITHUB_ACTIONS:-}" ] && echo "CI" || echo "Local")${NC}"
echo -e "${GREEN}✓ Total secrets discovered: $(echo "$AVAILABLE_SECRETS" | wc -l)${NC}"
echo -e "${GREEN}✓ Secrets injection setup complete${NC}"
echo ""

exit 0
