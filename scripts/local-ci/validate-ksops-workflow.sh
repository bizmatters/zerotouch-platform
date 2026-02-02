#!/bin/bash
# Local CI script to replicate the exact KSOPS validation workflow
# Usage: ./validate-ksops-workflow.sh

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$REPO_ROOT"

# Source .env file if it exists
if [ -f .env ]; then
    echo -e "${BLUE}Loading environment variables from .env...${NC}"
    set -a
    source .env
    set +a
    echo -e "${GREEN}✓ Environment variables loaded${NC}"
    echo ""
fi

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Local KSOPS Validation Workflow                           ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Step 3: Setup KSOPS Tools
echo -e "${BLUE}==> Step 3: Setup KSOPS Tools${NC}"
./scripts/bootstrap/infra/secrets/ksops/08a-install-ksops.sh
echo -e "${GREEN}✓ KSOPS tools ready${NC}"
echo ""

# Step 4: Generate Age Keys, Inject, and Deploy KSOPS (all in one step to preserve env vars)
echo -e "${BLUE}==> Step 4: Generate Age Keys, Inject, and Deploy KSOPS${NC}"

# Generate keys and capture output
echo -e "${BLUE}==> Step 4.1: Generating Age keys...${NC}"
KEY_OUTPUT=$(./scripts/bootstrap/infra/secrets/ksops/08b-generate-age-keys.sh)
echo "$KEY_OUTPUT"

# Extract keys from output
AGE_PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep "Public Key:" -A 1 | tail -1 | xargs)
AGE_PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "Private Key:" -A 1 | tail -1 | xargs)

export AGE_PUBLIC_KEY AGE_PRIVATE_KEY

echo -e "${BLUE}==> Step 4.2: Injecting Age keys...${NC}"
./scripts/bootstrap/infra/secrets/ksops/08c-inject-age-key.sh

echo -e "${BLUE}==> Step 4.3: Creating Age key backup...${NC}"
./scripts/bootstrap/infra/secrets/ksops/08d-create-age-backup.sh

echo -e "${BLUE}==> Step 4.4: Deploying KSOPS package...${NC}"
./scripts/bootstrap/infra/secrets/ksops/08e-deploy-ksops-package.sh

echo -e "${GREEN}✓ KSOPS integration complete${NC}"
echo ""

# Step 5: Run Master KSOPS Validation
echo -e "${BLUE}==> Step 5: Run Master KSOPS Validation${NC}"
./scripts/bootstrap/validation/11-verify-ksops.sh
echo -e "${GREEN}✓ Master KSOPS validation complete${NC}"
echo ""

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ KSOPS Integration Validation Complete${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${GREEN}All KSOPS validations passed successfully using orchestrated scripts!${NC}"
echo ""