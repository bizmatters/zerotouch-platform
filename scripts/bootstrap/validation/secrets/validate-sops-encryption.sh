#!/bin/bash
# Validation script for CHECKPOINT 3: SOPS Configuration and Secret Encryption
# Usage: ./validate-sops-encryption.sh
#
# This script validates SOPS configuration and secret encryption using platform Age keys

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Validation counters
PASSED=0
FAILED=0
TOTAL=0

# Function to run validation check
validate() {
    local test_name=$1
    local test_command=$2
    
    TOTAL=$((TOTAL + 1))
    echo -e "${BLUE}[${TOTAL}] Testing: $test_name${NC}"
    
    if eval "$test_command"; then
        echo -e "${GREEN}✓ PASSED: $test_name${NC}"
        PASSED=$((PASSED + 1))
        echo ""
        return 0
    else
        echo -e "${RED}✗ FAILED: $test_name${NC}"
        FAILED=$((FAILED + 1))
        echo ""
        return 1
    fi
}

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   CHECKPOINT 3: SOPS Configuration and Secret Encryption     ║${NC}"
echo -e "${BLUE}║   Validation Script                                          ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if .sops.yaml exists in current repository
if [[ -f "$REPO_ROOT/.sops.yaml" ]]; then
    echo -e "${GREEN}✓ Found .sops.yaml in repository${NC}"
    SOPS_CONFIG="$REPO_ROOT/.sops.yaml"
    cd "$REPO_ROOT"
else
    echo -e "${RED}✗ No .sops.yaml found in repository${NC}"
    echo -e "${YELLOW}.sops.yaml is mandatory - it is the source of truth for Age public key${NC}"
    exit 1
fi

# Extract Age public key from .sops.yaml
AGE_PUBLIC_KEY=$(grep "age:" "$SOPS_CONFIG" | sed -E 's/.*age:[[:space:]]*(age1[a-z0-9]+).*/\1/' | head -1)
if [[ -z "$AGE_PUBLIC_KEY" ]]; then
    echo -e "${RED}✗ No Age public key found in .sops.yaml${NC}"
    exit 1
fi

# Retrieve Age private key from S3 (not from cluster)
echo -e "${BLUE}Retrieving Age key from S3 backup...${NC}"

ENV="${ENV:-dev}"
ENV_UPPER=$(echo "$ENV" | tr '[:lower:]' '[:upper:]')

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

if [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ]; then
    echo -e "${RED}✗ S3 credentials not available${NC}"
    exit 1
fi

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
export AWS_DEFAULT_REGION="$S3_REGION"

if ! aws s3 cp "s3://${BUCKET_NAME}/age-keys/ACTIVE-age-key-encrypted.txt" \
    "$TEMP_DIR/encrypted.txt" \
    --endpoint-url "$S3_ENDPOINT" \
    --cli-connect-timeout 10 2>/dev/null || \
   ! aws s3 cp "s3://${BUCKET_NAME}/age-keys/ACTIVE-recovery-key.txt" \
    "$TEMP_DIR/recovery.key" \
    --endpoint-url "$S3_ENDPOINT" \
    --cli-connect-timeout 10 2>/dev/null; then
    echo -e "${RED}✗ Failed to retrieve Age key from S3${NC}"
    exit 1
fi

AGE_PRIVATE_KEY=$(age -d -i "$TEMP_DIR/recovery.key" "$TEMP_DIR/encrypted.txt" 2>&1)
if [[ -z "$AGE_PRIVATE_KEY" ]]; then
    echo -e "${RED}✗ Failed to decrypt Age key${NC}"
    exit 1
fi

export SOPS_AGE_KEY="$AGE_PRIVATE_KEY"
echo -e "${GREEN}✓ Age key retrieved from S3${NC}"
echo -e "${GREEN}  Public Key: $AGE_PUBLIC_KEY${NC}"

# Check required tools
if ! command -v sops &> /dev/null; then
    echo -e "${RED}✗ Error: sops not found${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Required tools found${NC}"
echo ""

# Validation 1: Repository has .sops.yaml or can create test config
validate "Repository SOPS configuration available" \
    "test -f .sops.yaml || test -n '$AGE_PUBLIC_KEY'"

# Validation 2: Test secret encryption
echo -e "${BLUE}[${TOTAL}] Testing: Secret encryption with correct Age key${NC}"
TEST_DIR="./test-secrets"
mkdir -p "$TEST_DIR"

cat > "$TEST_DIR/test.secret.yaml" << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: test-secret
  namespace: test-service
type: Opaque
stringData:
  test-key: test-value
EOF

# Run sops encryption
if sops -e "$TEST_DIR/test.secret.yaml" > "$TEST_DIR/test.secret.enc.yaml" 2>/dev/null; then
    echo -e "${GREEN}✓ PASSED: Secret encryption successful${NC}"
    PASSED=$((PASSED + 1))
    
    # Validation 3: Encrypted secret contains sops metadata
    if grep -q "sops:" "$TEST_DIR/test.secret.enc.yaml"; then
        echo -e "${GREEN}✓ PASSED: Encrypted secret contains sops metadata${NC}"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}✗ FAILED: No sops metadata found${NC}"
        FAILED=$((FAILED + 1))
    fi
    
    # Validation 4: Only data fields encrypted
    if grep -q "apiVersion: v1" "$TEST_DIR/test.secret.enc.yaml" && \
       grep -q "kind: Secret" "$TEST_DIR/test.secret.enc.yaml" && \
       grep -q "metadata:" "$TEST_DIR/test.secret.enc.yaml"; then
        echo -e "${GREEN}✓ PASSED: metadata, kind, apiVersion remain unencrypted${NC}"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}✗ FAILED: Metadata fields encrypted${NC}"
        FAILED=$((FAILED + 1))
    fi
    
    # Cleanup
    rm -rf "$TEST_DIR"
else
    echo -e "${RED}✗ FAILED: Secret encryption failed${NC}"
    FAILED=$((FAILED + 3))
    rm -rf "$TEST_DIR"
fi

TOTAL=$((TOTAL + 3))
echo ""

# Summary
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Validation Summary                                         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Passed: $PASSED / $TOTAL${NC}"
if [ $FAILED -gt 0 ]; then
    echo -e "${RED}Failed: $FAILED / $TOTAL${NC}"
fi
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ CHECKPOINT 3 VALIDATION PASSED${NC}"
    echo ""
    echo -e "${YELLOW}Success Criteria Met:${NC}"
    echo -e "  ✓ Secrets properly encrypted with correct keys"
    echo -e "  ✓ Platform SOPS capability validated"
    echo -e "  ✓ Ready for ArgoCD sync"
    echo ""
    exit 0
else
    echo -e "${RED}✗ CHECKPOINT 3 VALIDATION FAILED${NC}"
    echo ""
    exit 1
fi
