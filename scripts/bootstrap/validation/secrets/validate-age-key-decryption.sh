#!/bin/bash
# Validation script: Verify ACTIVE Age keys can decrypt cluster secrets
# Usage: ./validate-age-key-decryption.sh
#
# This script validates that the ACTIVE Age key from S3 can decrypt
# all encrypted secrets committed to Git repository

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
echo -e "${BLUE}║   Validate ACTIVE Age Key Can Decrypt Cluster Secrets       ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

FAILED=0

# Get ENV from environment or default to dev
ENV="${ENV:-dev}"
ENV_UPPER=$(echo "$ENV" | tr '[:lower:]' '[:upper:]')

# Check required tools
if ! command -v sops &> /dev/null; then
    echo -e "${RED}✗ sops not found${NC}"
    exit 1
fi

if ! command -v age &> /dev/null; then
    echo -e "${RED}✗ age not found${NC}"
    exit 1
fi

if ! command -v aws &> /dev/null; then
    echo -e "${RED}✗ aws CLI not found${NC}"
    exit 1
fi

# Validate S3 credentials
S3_ACCESS_KEY_VAR="${ENV_UPPER}_HETZNER_S3_ACCESS_KEY"
S3_SECRET_KEY_VAR="${ENV_UPPER}_HETZNER_S3_SECRET_KEY"
S3_ENDPOINT_VAR="${ENV_UPPER}_HETZNER_S3_ENDPOINT"
S3_REGION_VAR="${ENV_UPPER}_HETZNER_S3_REGION"
BUCKET_NAME_VAR="${ENV_UPPER}_HETZNER_S3_BUCKET_NAME"

S3_ACCESS_KEY="${!S3_ACCESS_KEY_VAR:-${HETZNER_S3_ACCESS_KEY:-}}"
S3_SECRET_KEY="${!S3_SECRET_KEY_VAR:-${HETZNER_S3_SECRET_KEY:-}}"
S3_ENDPOINT="${!S3_ENDPOINT_VAR:-${HETZNER_S3_ENDPOINT:-}}"
S3_REGION="${!S3_REGION_VAR:-${HETZNER_S3_REGION:-}}"
BUCKET_NAME="${!BUCKET_NAME_VAR:-${HETZNER_S3_BUCKET_NAME:-}}"

if [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ] || [ -z "$S3_ENDPOINT" ] || [ -z "$BUCKET_NAME" ]; then
    echo -e "${RED}✗ Missing S3 credentials${NC}"
    echo -e "${YELLOW}Required: ${S3_ACCESS_KEY_VAR}, ${S3_SECRET_KEY_VAR}, ${S3_ENDPOINT_VAR}, ${BUCKET_NAME_VAR}${NC}"
    exit 1
fi

# Step 1: Retrieve ACTIVE Age key from S3
echo -e "${BLUE}[1/4] Retrieving ACTIVE Age key from S3...${NC}"

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
export AWS_DEFAULT_REGION="$S3_REGION"

if ! aws s3 cp "s3://${BUCKET_NAME}/age-keys/ACTIVE-age-key-encrypted.txt" \
    "$TEMP_DIR/encrypted.txt" \
    --endpoint-url "$S3_ENDPOINT" \
    --cli-connect-timeout 10 2>/dev/null; then
    echo -e "${RED}✗ Failed to download ACTIVE Age key from S3${NC}"
    FAILED=1
fi

if ! aws s3 cp "s3://${BUCKET_NAME}/age-keys/ACTIVE-recovery-key.txt" \
    "$TEMP_DIR/recovery.key" \
    --endpoint-url "$S3_ENDPOINT" \
    --cli-connect-timeout 10 2>/dev/null; then
    echo -e "${RED}✗ Failed to download ACTIVE recovery key from S3${NC}"
    FAILED=1
fi

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ ACTIVE keys downloaded from S3${NC}"
fi
echo ""

# Step 2: Decrypt Age private key
echo -e "${BLUE}[2/4] Decrypting Age private key...${NC}"

if [ $FAILED -eq 0 ]; then
    if AGE_PRIVATE_KEY=$(age -d -i "$TEMP_DIR/recovery.key" "$TEMP_DIR/encrypted.txt" 2>&1); then
        if AGE_PUBLIC_KEY=$(echo "$AGE_PRIVATE_KEY" | age-keygen -y 2>&1); then
            echo -e "${GREEN}✓ Age key decrypted successfully${NC}"
            echo -e "${GREEN}  Public Key: $AGE_PUBLIC_KEY${NC}"
            export SOPS_AGE_KEY="$AGE_PRIVATE_KEY"
        else
            echo -e "${RED}✗ Failed to derive public key${NC}"
            FAILED=1
        fi
    else
        echo -e "${RED}✗ Failed to decrypt Age key${NC}"
        echo -e "${RED}Error: $AGE_PRIVATE_KEY${NC}"
        FAILED=1
    fi
fi
echo ""

# Step 3: Verify public key matches .sops.yaml
echo -e "${BLUE}[3/4] Verifying public key matches .sops.yaml...${NC}"

if [ $FAILED -eq 0 ]; then
    SOPS_YAML="$REPO_ROOT/.sops.yaml"
    if [ ! -f "$SOPS_YAML" ]; then
        echo -e "${RED}✗ .sops.yaml not found${NC}"
        FAILED=1
    else
        EXPECTED_PUBLIC_KEY=$(grep "age:" "$SOPS_YAML" | sed -E 's/.*age:[[:space:]]*(age1[a-z0-9]+).*/\1/' | head -1)
        if [ -z "$EXPECTED_PUBLIC_KEY" ]; then
            echo -e "${RED}✗ No Age public key found in .sops.yaml${NC}"
            FAILED=1
        elif [ "$AGE_PUBLIC_KEY" = "$EXPECTED_PUBLIC_KEY" ]; then
            echo -e "${GREEN}✓ Public key matches .sops.yaml${NC}"
            echo -e "${GREEN}  Expected: $EXPECTED_PUBLIC_KEY${NC}"
            echo -e "${GREEN}  Got:      $AGE_PUBLIC_KEY${NC}"
        else
            echo -e "${RED}✗ Public key mismatch${NC}"
            echo -e "${RED}  Expected: $EXPECTED_PUBLIC_KEY${NC}"
            echo -e "${RED}  Got:      $AGE_PUBLIC_KEY${NC}"
            FAILED=1
        fi
    fi
fi
echo ""

# Step 4: Test decryption of encrypted secrets in Git
echo -e "${BLUE}[4/4] Testing decryption of encrypted secrets...${NC}"

if [ $FAILED -eq 0 ]; then
    cd "$REPO_ROOT"
    
    # Find all encrypted secret files
    SECRET_FILES=$(find bootstrap/argocd/overlays/main -name "*.secret.yaml" 2>/dev/null || echo "")
    
    if [ -z "$SECRET_FILES" ]; then
        echo -e "${YELLOW}⚠ No encrypted secrets found in Git${NC}"
        echo -e "${YELLOW}  Run: ./scripts/bootstrap/infra/secrets/ksops/generate-sops/generate-platform-sops.sh${NC}"
    else
        TOTAL=0
        SUCCESS=0
        
        while IFS= read -r secret_file; do
            TOTAL=$((TOTAL + 1))
            if sops -d "$secret_file" >/dev/null 2>&1; then
                echo -e "${GREEN}  ✓ $(basename "$secret_file")${NC}"
                SUCCESS=$((SUCCESS + 1))
            else
                echo -e "${RED}  ✗ $(basename "$secret_file")${NC}"
                FAILED=1
            fi
        done <<< "$SECRET_FILES"
        
        echo ""
        if [ $SUCCESS -eq $TOTAL ]; then
            echo -e "${GREEN}✓ All $TOTAL secrets decrypted successfully${NC}"
        else
            echo -e "${RED}✗ Failed to decrypt $((TOTAL - SUCCESS)) of $TOTAL secrets${NC}"
        fi
    fi
fi
echo ""

# Summary
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Validation Summary                                         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ VALIDATION PASSED${NC}"
    echo ""
    echo -e "${YELLOW}Success Criteria Met:${NC}"
    echo -e "  ✓ ACTIVE Age key retrieved from S3"
    echo -e "  ✓ Age key decrypted successfully"
    echo -e "  ✓ Public key matches .sops.yaml"
    echo -e "  ✓ All encrypted secrets can be decrypted"
    echo ""
    exit 0
else
    echo -e "${RED}✗ VALIDATION FAILED${NC}"
    echo ""
    echo -e "${YELLOW}Troubleshooting:${NC}"
    echo -e "  1. Verify S3 credentials are correct"
    echo -e "  2. Check ACTIVE-* files exist in S3 bucket"
    echo -e "  3. Verify .sops.yaml has correct Age public key"
    echo -e "  4. Re-encrypt secrets if Age key was rotated"
    echo ""
    exit 1
fi
