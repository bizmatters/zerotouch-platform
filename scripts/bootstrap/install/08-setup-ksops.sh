#!/bin/bash
# Master KSOPS Setup Script
# Usage: ./08-setup-ksops.sh
#
# Orchestrates complete KSOPS setup

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$SCRIPT_DIR/../infra/secrets"

# Get ENV from bootstrap context (exported by master bootstrap script)
if [ -z "${ENV:-}" ]; then
    echo "Error: ENV environment variable is required"
    exit 1
fi
ENV_UPPER=$(echo "$ENV" | tr '[:lower:]' '[:upper:]')

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   KSOPS Setup - Master Script                               ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Validate critical environment variables upfront
echo -e "${BLUE}Validating environment variables...${NC}"
MISSING_VARS=()

if [ -z "${GITHUB_APP_ID:-}" ]; then MISSING_VARS+=("GITHUB_APP_ID"); fi
if [ -z "${GITHUB_APP_INSTALLATION_ID:-}" ]; then MISSING_VARS+=("GITHUB_APP_INSTALLATION_ID"); fi
if [ -z "${GITHUB_APP_PRIVATE_KEY:-}" ]; then MISSING_VARS+=("GITHUB_APP_PRIVATE_KEY"); fi

# Check for environment-specific S3 credentials dynamically
S3_ACCESS_KEY_VAR="${ENV_UPPER}_HETZNER_S3_ACCESS_KEY"
S3_SECRET_KEY_VAR="${ENV_UPPER}_HETZNER_S3_SECRET_KEY"
S3_ACCESS_KEY="${!S3_ACCESS_KEY_VAR:-${HETZNER_S3_ACCESS_KEY:-}}"
S3_SECRET_KEY="${!S3_SECRET_KEY_VAR:-${HETZNER_S3_SECRET_KEY:-}}"

if [ -z "$S3_ACCESS_KEY" ]; then 
    MISSING_VARS+=("${S3_ACCESS_KEY_VAR} or HETZNER_S3_ACCESS_KEY"); 
fi
if [ -z "$S3_SECRET_KEY" ]; then 
    MISSING_VARS+=("${S3_SECRET_KEY_VAR} or HETZNER_S3_SECRET_KEY"); 
fi

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    echo -e "${RED}✗ Error: Missing required environment variables:${NC}"
    for var in "${MISSING_VARS[@]}"; do
        echo -e "${RED}  - $var${NC}"
    done
    echo ""
    echo -e "${YELLOW}Please set these variables in .env file${NC}"
    exit 1
fi

echo -e "${GREEN}✓ All required environment variables present${NC}"
echo ""

# Step 1: Install KSOPS tools (SOPS + Age)
echo -e "${BLUE}[1/8] Installing KSOPS tools...${NC}"
"$SECRETS_DIR/ksops/08a-install-ksops.sh"
echo -e "${GREEN}✓ KSOPS tools installed${NC}"
echo ""

# Step 2: Inject GitHub App Authentication
echo -e "${BLUE}[2/8] Injecting GitHub App authentication...${NC}"
if [ -n "${GITHUB_APP_ID:-}" ] && [ -n "${GITHUB_APP_INSTALLATION_ID:-}" ] && [ -n "${GITHUB_APP_PRIVATE_KEY:-}" ]; then
    TEMP_KEY=$(mktemp)
    echo "$GITHUB_APP_PRIVATE_KEY" > "$TEMP_KEY"
    trap "rm -f $TEMP_KEY" EXIT
    "$SECRETS_DIR/00-inject-identities.sh" "$GITHUB_APP_ID" "$GITHUB_APP_INSTALLATION_ID" "$TEMP_KEY"
    echo -e "${GREEN}✓ GitHub App authentication injected${NC}"
else
    echo -e "${YELLOW}⚠️  Skipping: GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, or GITHUB_APP_PRIVATE_KEY not set${NC}"
fi
echo ""

# Step 3: Bootstrap Hetzner Object Storage
echo -e "${BLUE}[3/8] Bootstrapping Hetzner Object Storage...${NC}"
# Export environment-specific S3 credentials for the bootstrap script
S3_ENDPOINT_VAR="${ENV_UPPER}_HETZNER_S3_ENDPOINT"
S3_REGION_VAR="${ENV_UPPER}_HETZNER_S3_REGION"
export HETZNER_S3_ACCESS_KEY="$S3_ACCESS_KEY"
export HETZNER_S3_SECRET_KEY="$S3_SECRET_KEY"
export HETZNER_S3_ENDPOINT="${!S3_ENDPOINT_VAR}"
export HETZNER_S3_REGION="${!S3_REGION_VAR}"
"$SECRETS_DIR/03-bootstrap-storage.sh"
echo -e "${GREEN}✓ Hetzner Object Storage bootstrapped${NC}"
echo ""

# Step 4: Generate or retrieve Age keypair
echo -e "${BLUE}[4/8] Generating Age keypair...${NC}"

# Check if age key already exists in cluster
if kubectl get secret sops-age -n argocd &>/dev/null; then
    echo -e "${YELLOW}Age key already exists in cluster, reusing...${NC}"
    AGE_PRIVATE_KEY=$(kubectl get secret sops-age -n argocd -o jsonpath='{.data.keys\.txt}' | base64 -d)
    AGE_PUBLIC_KEY=$(echo "$AGE_PRIVATE_KEY" | age-keygen -y)
    export AGE_PUBLIC_KEY
    export AGE_PRIVATE_KEY
    export SOPS_AGE_KEY="$AGE_PRIVATE_KEY"
    echo -e "${GREEN}✓ Age keypair retrieved from cluster${NC}"
else
    source "$SECRETS_DIR/ksops/08b-generate-age-keys.sh"
    export SOPS_AGE_KEY="$AGE_PRIVATE_KEY"
    echo -e "${GREEN}✓ Age keypair generated${NC}"
fi
echo -e "${GREEN}  Public Key: $AGE_PUBLIC_KEY${NC}"
echo ""

# Step 4.5: Generate platform secrets with Age key
echo -e "${BLUE}[4.5/8] Generating platform secrets...${NC}"
"$SECRETS_DIR/ksops/generate-sops/generate-platform-sops.sh"
echo -e "${GREEN}✓ Platform secrets generated and encrypted${NC}"
echo ""

# Step 5: Backup Age key to Hetzner S3
echo -e "${BLUE}[5/8] Backing up Age key to Hetzner Object Storage...${NC}"
# S3 credentials already exported in step 3
source "$SECRETS_DIR/ksops/08b-backup-age-to-s3.sh"
echo -e "${GREEN}✓ Age key backed up to S3${NC}"
echo ""

# Step 6: Inject Age key into cluster
echo -e "${BLUE}[6/8] Injecting Age key into cluster...${NC}"
"$SECRETS_DIR/ksops/08c-inject-age-key.sh"
echo -e "${GREEN}✓ Age key injected${NC}"
echo ""

# Step 7: Create in-cluster Age key backup
echo -e "${BLUE}[7/8] Creating in-cluster Age key backup...${NC}"
"$SECRETS_DIR/ksops/08d-create-age-backup.sh"
echo -e "${GREEN}✓ In-cluster Age key backup created${NC}"
echo ""

# Summary
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   KSOPS Setup Complete (Pre-ArgoCD)                         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✓ GitHub App authentication configured${NC}"
echo -e "${GREEN}✓ Hetzner Object Storage provisioned${NC}"
echo -e "${GREEN}✓ Age keypair generated and backed up to S3${NC}"
echo -e "${GREEN}✓ Age key injected to cluster${NC}"
echo -e "${GREEN}✓ In-cluster Age key backup created${NC}"
echo -e "${YELLOW}⚠ KSOPS package deployment deferred until after ArgoCD installation${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Install ArgoCD"
echo -e "  2. Deploy KSOPS package to ArgoCD"
echo -e "  3. Generate platform secrets: ${GREEN}./scripts/bootstrap/infra/secrets/ksops/generate-platform-secrets.sh${NC}"
echo -e "  4. Commit encrypted *.secret.yaml files to Git"
echo -e "  5. ArgoCD will automatically sync and decrypt secrets"
echo ""
echo -e "${BLUE}Emergency Recovery:${NC}"
echo -e "  Break-glass script: ${GREEN}./scripts/bootstrap/infra/secrets/ksops/inject-offline-key.sh${NC}"
echo ""

exit 0
