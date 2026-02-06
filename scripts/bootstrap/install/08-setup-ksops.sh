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
BUCKET_NAME_VAR="${ENV_UPPER}_HETZNER_S3_BUCKET_NAME"
export HETZNER_S3_ACCESS_KEY="$S3_ACCESS_KEY"
export HETZNER_S3_SECRET_KEY="$S3_SECRET_KEY"
export HETZNER_S3_ENDPOINT="${!S3_ENDPOINT_VAR}"
export HETZNER_S3_REGION="${!S3_REGION_VAR}"
export HETZNER_S3_BUCKET_NAME="${!BUCKET_NAME_VAR:-${HETZNER_S3_BUCKET_NAME:-}}"
"$SECRETS_DIR/03-bootstrap-storage.sh"
echo -e "${GREEN}✓ Hetzner Object Storage bootstrapped${NC}"
echo ""

# Step 4: Retrieve or generate Age keypair
echo -e "${BLUE}[4/8] Retrieving Age keypair...${NC}"

# Extract expected public key from .sops.yaml
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SOPS_YAML="$REPO_ROOT/.sops.yaml"
EXPECTED_PUBLIC_KEY=""

if [ -f "$SOPS_YAML" ]; then
    EXPECTED_PUBLIC_KEY=$(grep "age:" "$SOPS_YAML" | sed -E 's/.*age:[[:space:]]*(age1[a-z0-9]+).*/\1/' | head -1)
    if [ -n "$EXPECTED_PUBLIC_KEY" ]; then
        echo -e "${BLUE}Expected public key from .sops.yaml: $EXPECTED_PUBLIC_KEY${NC}"
    fi
fi

# Try to retrieve from S3 backup first
AGE_PRIVATE_KEY=""
AGE_PUBLIC_KEY=""

if [ -n "$EXPECTED_PUBLIC_KEY" ]; then
    echo -e "${BLUE}Attempting to retrieve Age key from S3 backup...${NC}"
    
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT
    
    # Configure AWS CLI for S3 access (reuse credentials from step 3)
    export AWS_ACCESS_KEY_ID="$HETZNER_S3_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$HETZNER_S3_SECRET_KEY"
    export AWS_DEFAULT_REGION="$HETZNER_S3_REGION"
    
    # Download ACTIVE backup files
    if aws s3 cp "s3://${HETZNER_S3_BUCKET_NAME}/age-keys/ACTIVE-age-key-encrypted.txt" \
        "$TEMP_DIR/encrypted.txt" \
        --endpoint-url "$HETZNER_S3_ENDPOINT" \
        --cli-connect-timeout 10 2>/dev/null && \
       aws s3 cp "s3://${HETZNER_S3_BUCKET_NAME}/age-keys/ACTIVE-recovery-key.txt" \
        "$TEMP_DIR/recovery.key" \
        --endpoint-url "$HETZNER_S3_ENDPOINT" \
        --cli-connect-timeout 10 2>/dev/null; then
        
        # Decrypt Age key
        if ! AGE_PRIVATE_KEY=$(age -d -i "$TEMP_DIR/recovery.key" "$TEMP_DIR/encrypted.txt" 2>&1); then
            echo -e "${RED}✗ Failed to decrypt S3 backup${NC}"
            echo -e "${RED}Error: $AGE_PRIVATE_KEY${NC}"
            exit 1
        fi
        
        if [ -n "$AGE_PRIVATE_KEY" ]; then
            if ! AGE_PUBLIC_KEY=$(echo "$AGE_PRIVATE_KEY" | age-keygen -y 2>&1); then
                echo -e "${RED}✗ Failed to derive public key from S3 backup${NC}"
                echo -e "${RED}Error: $AGE_PUBLIC_KEY${NC}"
                exit 1
            fi
            
            # Verify public key matches .sops.yaml
            if [ "$AGE_PUBLIC_KEY" = "$EXPECTED_PUBLIC_KEY" ]; then
                echo -e "${GREEN}✓ Age key retrieved from S3 backup${NC}"
                echo -e "${GREEN}✓ Public key matches .sops.yaml${NC}"
            else
                echo -e "${RED}✗ S3 backup public key mismatch${NC}"
                echo -e "${RED}Expected: $EXPECTED_PUBLIC_KEY${NC}"
                echo -e "${RED}Got: $AGE_PUBLIC_KEY${NC}"
                exit 1
            fi
        fi
    else
        echo -e "${YELLOW}⚠ S3 backup not found, will generate new key${NC}"
    fi
fi

# If S3 retrieval failed, generate new key (but skip cluster check in 08b script)
if [ -z "$AGE_PRIVATE_KEY" ]; then
    echo -e "${BLUE}Generating new Age keypair...${NC}"
    
    # Generate keypair directly without sourcing 08b script to avoid cluster check
    KEYGEN_OUTPUT=$(age-keygen 2>&1)
    AGE_PUBLIC_KEY=$(echo "$KEYGEN_OUTPUT" | grep "# public key:" | sed 's/# public key: //')
    AGE_PRIVATE_KEY=$(echo "$KEYGEN_OUTPUT" | grep "^AGE-SECRET-KEY-1" | head -n 1)
    
    if [ -z "$AGE_PUBLIC_KEY" ] || [ -z "$AGE_PRIVATE_KEY" ]; then
        echo -e "${RED}✗ Failed to generate Age keypair${NC}"
        exit 1
    fi
    
    # Update .sops.yaml with new public key
    if [ -f "$SOPS_YAML" ]; then
        if grep -q "$AGE_PUBLIC_KEY" "$SOPS_YAML"; then
            echo -e "${GREEN}✓ .sops.yaml already contains current public key${NC}"
        else
            sed -i.bak "s/age: age1[a-z0-9]*/age: $AGE_PUBLIC_KEY/" "$SOPS_YAML"
            rm -f "$SOPS_YAML.bak"
            echo -e "${GREEN}✓ .sops.yaml updated with new public key${NC}"
        fi
    fi
    
    echo -e "${GREEN}✓ New Age keypair generated${NC}"
fi

export AGE_PUBLIC_KEY
export AGE_PRIVATE_KEY
export SOPS_AGE_KEY="$AGE_PRIVATE_KEY"
echo -e "${GREEN}  Public Key: $AGE_PUBLIC_KEY${NC}"
echo ""

# Validate: Age key matches .sops.yaml
if [ -n "$EXPECTED_PUBLIC_KEY" ] && [ "$AGE_PUBLIC_KEY" != "$EXPECTED_PUBLIC_KEY" ]; then
    echo -e "${RED}✗ Age key mismatch detected${NC}"
    echo -e "${RED}Expected (from .sops.yaml): $EXPECTED_PUBLIC_KEY${NC}"
    echo -e "${RED}Got (from S3/generated): $AGE_PUBLIC_KEY${NC}"
    echo -e "${YELLOW}Fix: Update .sops.yaml or re-encrypt secrets with current key${NC}"
    exit 1
fi

# Validate: Encrypted secrets exist and can be decrypted
echo -e "${BLUE}Validating encrypted secrets in Git...${NC}"
TEST_SECRET="$REPO_ROOT/bootstrap/argocd/overlays/main/core/secrets/org-name.secret.yaml"
if [ ! -f "$TEST_SECRET" ]; then
    echo -e "${RED}✗ Encrypted secrets not found in Git${NC}"
    echo -e "${YELLOW}Run: ./scripts/bootstrap/infra/secrets/ksops/generate-sops/generate-platform-sops.sh${NC}"
    echo -e "${YELLOW}Then commit and push to Git before cluster creation${NC}"
    exit 1
fi

if ! sops -d "$TEST_SECRET" >/dev/null 2>&1; then
    echo -e "${RED}✗ Cannot decrypt secrets in Git with current Age key${NC}"
    echo -e "${YELLOW}Secrets were encrypted with a different Age key${NC}"
    echo -e "${YELLOW}Fix: Re-generate secrets or retrieve correct Age key from S3${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Encrypted secrets validated${NC}"
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
echo -e "${GREEN}✓ Age keypair retrieved/generated and validated${NC}"
echo -e "${GREEN}✓ Encrypted secrets in Git validated${NC}"
echo -e "${GREEN}✓ Age key backed up to S3${NC}"
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
