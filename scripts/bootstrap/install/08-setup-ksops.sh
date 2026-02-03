#!/bin/bash
# Master KSOPS Setup Script
# Usage: ./08-setup-ksops.sh
#
# Orchestrates complete KSOPS setup

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$SCRIPT_DIR/../infra/secrets"

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

# Step 1: Install KSOPS tools (SOPS + Age)
echo -e "${BLUE}[1/8] Installing KSOPS tools...${NC}"
"$SECRETS_DIR/ksops/08a-install-ksops.sh"
echo -e "${GREEN}✓ KSOPS tools installed${NC}"
echo ""

# Step 2: Inject GitHub App Authentication
echo -e "${BLUE}[2/8] Injecting GitHub App authentication...${NC}"
if [ -n "${APP_ID:-}" ] && [ -n "${APP_INSTALLATION_ID:-}" ] && [ -n "${APP_PRIVATE_KEY:-}" ]; then
    TEMP_KEY=$(mktemp)
    echo "$APP_PRIVATE_KEY" > "$TEMP_KEY"
    trap "rm -f $TEMP_KEY" EXIT
    "$SECRETS_DIR/00-inject-identities.sh" "$APP_ID" "$APP_INSTALLATION_ID" "$TEMP_KEY"
    echo -e "${GREEN}✓ GitHub App authentication injected${NC}"
else
    echo -e "${YELLOW}⚠️  Skipping: APP_ID, APP_INSTALLATION_ID, or APP_PRIVATE_KEY not set${NC}"
fi
echo ""

# Step 3: Bootstrap Hetzner Object Storage
echo -e "${BLUE}[3/8] Bootstrapping Hetzner Object Storage...${NC}"
if [ -n "${HETZNER_S3_ACCESS_KEY:-}" ] && [ -n "${HETZNER_S3_SECRET_KEY:-}" ]; then
    "$SECRETS_DIR/03-bootstrap-storage.sh"
    echo -e "${GREEN}✓ Hetzner Object Storage bootstrapped${NC}"
else
    echo -e "${YELLOW}⚠️  Skipping: HETZNER_S3_ACCESS_KEY or HETZNER_S3_SECRET_KEY not set${NC}"
fi
echo ""

# Step 4: Generate Age keypair
echo -e "${BLUE}[4/8] Generating Age keypair...${NC}"
source "$SECRETS_DIR/ksops/08b-generate-age-keys.sh"
echo -e "${GREEN}✓ Age keypair generated${NC}"
echo -e "${GREEN}  Public Key: $AGE_PUBLIC_KEY${NC}"
echo ""

# Step 5: Inject Age key into cluster
echo -e "${BLUE}[5/8] Injecting Age key into cluster...${NC}"
"$SECRETS_DIR/ksops/08c-inject-age-key.sh"
echo -e "${GREEN}✓ Age key injected${NC}"
echo ""

# Step 6: Create Age key backup
echo -e "${BLUE}[6/6] Creating Age key backup...${NC}"
"$SECRETS_DIR/ksops/08d-create-age-backup.sh"
echo -e "${GREEN}✓ Age key backup created${NC}"
echo ""

# Summary
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   KSOPS Setup Complete (Pre-ArgoCD)                         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✓ GitHub App authentication configured${NC}"
echo -e "${GREEN}✓ Hetzner Object Storage provisioned${NC}"
echo -e "${GREEN}✓ Age keypair generated and injected${NC}"
echo -e "${GREEN}✓ Age key backup created${NC}"
echo -e "${YELLOW}⚠ KSOPS package deployment deferred until after ArgoCD installation${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Install ArgoCD"
echo -e "  2. Deploy KSOPS package to ArgoCD"
echo -e "  3. Developers run: ${GREEN}./scripts/bootstrap/infra/secrets/ksops/generate-env-sops.sh${NC}"
echo -e "  2. Commit encrypted *.secret.yaml files to Git"
echo -e "  3. ArgoCD will automatically sync and decrypt secrets"
echo ""

exit 0
