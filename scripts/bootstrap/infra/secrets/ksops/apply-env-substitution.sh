#!/bin/bash
# Apply environment variable substitution to ArgoCD applications and secrets
# Usage: ./apply-env-substitution.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ENV_FILE="$REPO_ROOT/.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Apply Environment Variable Substitution                   ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if .env exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}✗ Error: $ENV_FILE not found${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Found .env file${NC}"
echo ""

# Load environment variables
set -a
source "$ENV_FILE"
set +a

# Build TENANTS_REPO_URL from components
if [ -n "$ORG_NAME" ] && [ -n "$TENANTS_REPO_NAME" ]; then
    TENANTS_REPO_URL="https://github.com/${ORG_NAME}/${TENANTS_REPO_NAME}.git"
    export TENANTS_REPO_URL
    echo -e "${GREEN}✓ Built TENANTS_REPO_URL: $TENANTS_REPO_URL${NC}"
else
    echo -e "${RED}✗ Error: ORG_NAME or TENANTS_REPO_NAME not set in .env${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}Applying substitutions to ArgoCD applications...${NC}"

# Function to replace tenant repo URL in files
replace_tenant_url() {
    local file="$1"
    if [ -f "$file" ]; then
        # Replace any github.com/*/zerotouch-tenants.git with the correct URL
        sed -i.bak "s|repoURL: https://github.com/.*/zerotouch-tenants\.git|repoURL: ${TENANTS_REPO_URL}|g" "$file"
        rm -f "${file}.bak"
        echo -e "${GREEN}  ✓ $(basename $file)${NC}"
    else
        echo -e "${YELLOW}  ⚠️  $(basename $file) not found${NC}"
    fi
}

# Process all files with tenant repo URLs
replace_tenant_url "$REPO_ROOT/bootstrap/argocd/overlays/main/core/argocd-repo-configs.yaml"
replace_tenant_url "$REPO_ROOT/bootstrap/argocd/overlays/main/core/tenant-infrastructure.yaml"
replace_tenant_url "$REPO_ROOT/bootstrap/argocd/overlays/main/dev/99-tenants.yaml"
replace_tenant_url "$REPO_ROOT/bootstrap/argocd/overlays/main/staging/99-tenants.yaml"
replace_tenant_url "$REPO_ROOT/bootstrap/argocd/overlays/main/prod/99-tenants.yaml"

echo ""
echo -e "${GREEN}✅ Environment substitution complete${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Review changes: ${GREEN}git diff${NC}"
echo -e "  2. Commit: ${GREEN}git add bootstrap/ && git commit -m 'chore: apply env substitution'${NC}"
echo -e "  3. Push: ${GREEN}git push${NC}"
