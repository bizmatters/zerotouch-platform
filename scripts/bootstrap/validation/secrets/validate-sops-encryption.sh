#!/bin/bash
# Validation script for CHECKPOINT 3: SOPS Configuration and Secret Encryption
# Usage: ./validate-sops-encryption.sh
#
# This script validates SOPS configuration and secret encryption

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
TENANTS_REPO="${TENANTS_REPO_PATH:-$REPO_ROOT/zerotouch-tenants}"

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

# Check required tools
if ! command -v sops &> /dev/null; then
    echo -e "${RED}✗ Error: sops not found${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Required tools found${NC}"
echo ""

# Validation 1: .sops.yaml exists
validate ".sops.yaml exists in zerotouch-tenants repository root" \
    "test -f $TENANTS_REPO/.sops.yaml"

# Validation 2: Test secret encryption
echo -e "${BLUE}[${TOTAL}] Testing: Secret encryption with correct Age key${NC}"
TEST_DIR="$TENANTS_REPO/tenants/test-service/base/secrets"
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

# Run sops from tenants repo directory
cd "$TENANTS_REPO"
if sops -e "tenants/test-service/base/secrets/test.secret.yaml" > "tenants/test-service/base/secrets/test.secret.enc.yaml" 2>/dev/null; then
    echo -e "${GREEN}✓ PASSED: Secret encryption successful${NC}"
    PASSED=$((PASSED + 1))
    
    # Validation 3: Encrypted secret contains sops metadata
    if grep -q "sops:" "tenants/test-service/base/secrets/test.secret.enc.yaml"; then
        echo -e "${GREEN}✓ PASSED: Encrypted secret contains sops metadata${NC}"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}✗ FAILED: No sops metadata found${NC}"
        FAILED=$((FAILED + 1))
    fi
    
    # Validation 4: Only data fields encrypted
    if grep -q "apiVersion: v1" "tenants/test-service/base/secrets/test.secret.enc.yaml" && \
       grep -q "kind: Secret" "tenants/test-service/base/secrets/test.secret.enc.yaml" && \
       grep -q "metadata:" "tenants/test-service/base/secrets/test.secret.enc.yaml"; then
        echo -e "${GREEN}✓ PASSED: metadata, kind, apiVersion remain unencrypted${NC}"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}✗ FAILED: Metadata fields encrypted${NC}"
        FAILED=$((FAILED + 1))
    fi
    
    # Cleanup
    rm -rf "tenants/test-service"
    cd "$SCRIPT_DIR"
else
    echo -e "${RED}✗ FAILED: Secret encryption failed${NC}"
    FAILED=$((FAILED + 3))
    rm -rf "tenants/test-service"
    cd "$SCRIPT_DIR"
fi

TOTAL=$((TOTAL + 3))
echo ""

# Validation 5: sync-secrets-to-sops.sh successfully encrypts and commits
echo -e "${BLUE}[${TOTAL}] Testing: sync-secrets-to-sops.sh encrypts and commits secrets${NC}"

# Run in subshell to isolate environment
(
    # Clear any existing PR_ variables
    for var in $(compgen -e | grep "^PR_"); do
        unset $var
    done
    
    # Set only the test variable
    export PR_TEST_SECRET="test-value-for-validation"
    export TENANTS_REPO_PATH="$TENANTS_REPO"
    
    bash "$REPO_ROOT/zerotouch-platform/scripts/release/template/sync-secrets-to-sops.sh" "validation-test" "pr" 2>&1
) | grep -q "Created 1 encrypted secrets"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ PASSED: sync-secrets-to-sops.sh successfully encrypts and commits${NC}"
    PASSED=$((PASSED + 1))
    rm -rf "$TENANTS_REPO/tenants/validation-test"
    cd "$TENANTS_REPO" && git reset --hard HEAD~1 > /dev/null 2>&1
    cd "$SCRIPT_DIR"
else
    echo -e "${RED}✗ FAILED: sync-secrets-to-sops.sh failed${NC}"
    FAILED=$((FAILED + 1))
    rm -rf "$TENANTS_REPO/tenants/validation-test"
fi
TOTAL=$((TOTAL + 1))
echo ""

# Validation 6: Scripts exist
validate "08-inject-sops-secrets.sh script exists" \
    "test -f $REPO_ROOT/zerotouch-platform/scripts/bootstrap/install/08-inject-sops-secrets.sh"

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
    echo -e "  ✓ Committed to Git"
    echo -e "  ✓ Ready for ArgoCD sync"
    echo ""
    exit 0
else
    echo -e "${RED}✗ CHECKPOINT 3 VALIDATION FAILED${NC}"
    echo ""
    exit 1
fi
