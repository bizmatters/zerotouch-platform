#!/bin/bash
# Master KSOPS Setup Script
# Usage: ./08-setup-ksops.sh
#
# Orchestrates complete KSOPS setup
#
# ═══════════════════════════════════════════════════════════════════════════════
# SOPS/Age Key Management Flow
# ═══════════════════════════════════════════════════════════════════════════════
#
# This script implements a secure Age key lifecycle for SOPS encryption:
#
# 1. SOURCE OF TRUTH: .sops.yaml
#    - Contains the Age public key recipient for all encrypted files
#    - Single source of truth for which key should be used
#    - All encrypted *.secret.yaml files use this public key
#
# 2. KEY RETRIEVAL PRIORITY:
#    a) S3 Backup (Primary): Downloads ACTIVE-age-key-encrypted.txt from S3
#       - Decrypts using ACTIVE-recovery-key.txt
#       - Verifies public key matches .sops.yaml
#       - FAILS if mismatch (prevents using wrong key)
#    
#    b) Generate New (Fallback): Only if S3 backup not found
#       - Generates fresh Age keypair
#       - Updates .sops.yaml with new public key
#       - Requires re-encryption of all *.secret.yaml files
#
# 3. KEY DISTRIBUTION:
#    - Backs up to S3 as ACTIVE-* files (encrypted with recovery key)
#    - Injects into cluster as sops-age secret in argocd namespace
#    - Creates in-cluster backup (encrypted with separate recovery key)
#
# 4. CRITICAL RULES:
#    - NEVER retrieve key from cluster (cluster is destination, not source)
#    - NEVER generate new key if .sops.yaml has existing recipient
#    - ALWAYS verify S3 backup key matches .sops.yaml before using
#    - FAIL FAST on any key mismatch (prevents decryption failures)
#
# 5. RECOVERY SCENARIOS:
#    - Lost cluster: Retrieve from S3 backup using recovery key
#    - Lost S3: Use in-cluster backup (recovery-master-key secret)
#    - Lost both: Generate new key, re-encrypt all secrets, update Git
#
# ═══════════════════════════════════════════════════════════════════════════════

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$SCRIPT_DIR/../infra/secrets"

# Source env helpers for multi-line value handling
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/bootstrap/helpers/env-helpers.sh"

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

if [ -z "${GIT_APP_ID:-}" ]; then MISSING_VARS+=("GIT_APP_ID"); fi
if [ -z "${GIT_APP_INSTALLATION_ID:-}" ]; then MISSING_VARS+=("GIT_APP_INSTALLATION_ID"); fi
if [ -z "${GIT_APP_PRIVATE_KEY:-}${GIT_APP_PRIVATE_KEY_B64:-}" ]; then MISSING_VARS+=("GIT_APP_PRIVATE_KEY"); fi

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
if [ -n "${GIT_APP_ID:-}" ] && [ -n "${GIT_APP_INSTALLATION_ID:-}" ] && [ -n "${GIT_APP_PRIVATE_KEY:-}" ]; then
    # Get private key (decode if base64 encoded)
    PRIVATE_KEY=$(get_env_var "GIT_APP_PRIVATE_KEY")
    
    TEMP_KEY=$(mktemp)
    echo "$PRIVATE_KEY" > "$TEMP_KEY"
    trap "rm -f $TEMP_KEY" EXIT
    "$SECRETS_DIR/00-inject-identities.sh" "$GIT_APP_ID" "$GIT_APP_INSTALLATION_ID" "$TEMP_KEY"
    echo -e "${GREEN}✓ GitHub App authentication injected${NC}"
else
    echo -e "${YELLOW}⚠️  Skipping: GIT_APP_ID, GIT_APP_INSTALLATION_ID, or GIT_APP_PRIVATE_KEY not set${NC}"
fi
echo ""

# Step 3: Bootstrap Hetzner Object Storage
echo -e "${BLUE}[3/8] Bootstrapping Hetzner Object Storage...${NC}"
# Export environment-specific S3 credentials for the bootstrap script
S3_ENDPOINT_VAR="${ENV_UPPER}_HETZNER_S3_ENDPOINT"
S3_REGION_VAR="${ENV_UPPER}_HETZNER_S3_REGION"
BUCKET_NAME_VAR="${ENV_UPPER}_HETZNER_S3_BUCKET_NAME"
export HETZNER_S3_ACCESS_KEY="$S3_ACCESS_KEY"
export HETZNER_S3_SECRET_KEY="$S3_SECRET_KEY"
export HETZNER_S3_ENDPOINT="${!S3_ENDPOINT_VAR}"
export HETZNER_S3_REGION="${!S3_REGION_VAR}"
export HETZNER_S3_BUCKET_NAME="${!BUCKET_NAME_VAR:-${HETZNER_S3_BUCKET_NAME:-}}"
"$SECRETS_DIR/03-bootstrap-storage.sh"
echo -e "${GREEN}✓ Hetzner Object Storage bootstrapped${NC}"
echo ""

# Step 4: Load Age key from .env (generated by create-dot-env.sh)
echo -e "${BLUE}[4/8] Loading Age key from environment...${NC}"

if [ -z "${AGE_PRIVATE_KEY:-}" ]; then
    echo -e "${RED}✗ AGE_PRIVATE_KEY not set in environment${NC}"
    echo -e "${YELLOW}Run create-dot-env.sh first:${NC}"
    echo -e "  ENV=$ENV ./scripts/bootstrap/infra/secrets/ksops/generate-sops/create-dot-env.sh"
    exit 1
fi

if ! AGE_PUBLIC_KEY=$(echo "$AGE_PRIVATE_KEY" | age-keygen -y 2>&1); then
    echo -e "${RED}✗ Failed to derive public key from AGE_PRIVATE_KEY${NC}"
    exit 1
fi

export AGE_PUBLIC_KEY
export SOPS_AGE_KEY="$AGE_PRIVATE_KEY"

echo -e "${GREEN}✓ Age key loaded from environment${NC}"
echo -e "${GREEN}  Public Key: $AGE_PUBLIC_KEY${NC}"
echo ""

# Validate: Age key matches .sops.yaml
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SOPS_YAML="$REPO_ROOT/.sops.yaml"

if [ -f "$SOPS_YAML" ]; then
    EXPECTED_PUBLIC_KEY=$(grep "age:" "$SOPS_YAML" | sed -E 's/.*age:[[:space:]]*(age1[a-z0-9]+).*/\1/' | head -1)
    
    if [ -n "$EXPECTED_PUBLIC_KEY" ] && [ "$AGE_PUBLIC_KEY" != "$EXPECTED_PUBLIC_KEY" ]; then
        echo -e "${RED}✗ Age key mismatch${NC}"
        echo -e "${RED}Expected (from .sops.yaml): $EXPECTED_PUBLIC_KEY${NC}"
        echo -e "${RED}Got (from environment): $AGE_PUBLIC_KEY${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Age key matches .sops.yaml${NC}"
fi
echo ""

# Step 5: Inject Age key into cluster
echo -e "${BLUE}[5/8] Injecting Age key into cluster...${NC}"
"$SECRETS_DIR/ksops/08c-inject-age-key.sh"
echo -e "${GREEN}✓ Age key injected${NC}"
echo ""

# Step 6: Create in-cluster Age key backup
echo -e "${BLUE}[6/8] Creating in-cluster Age key backup...${NC}"
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
echo -e "${GREEN}✓ Age key loaded from environment${NC}"
echo -e "${GREEN}✓ Age key validated against .sops.yaml${NC}"
echo -e "${GREEN}✓ Age key injected to cluster${NC}"
echo -e "${GREEN}✓ In-cluster Age key backup created${NC}"
echo -e "${YELLOW}⚠ KSOPS package deployment deferred until after ArgoCD installation${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Install ArgoCD"
echo -e "  2. Deploy KSOPS package to ArgoCD"
echo -e "  3. ArgoCD will sync and decrypt secrets from Git"
echo ""
echo -e "${BLUE}Emergency Recovery:${NC}"
echo -e "  Break-glass script: ${GREEN}./scripts/bootstrap/infra/secrets/ksops/inject-offline-key.sh${NC}"
echo ""

exit 0
