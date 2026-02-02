#!/bin/bash
# SOPS Configuration Validation Script
# Usage: ./validate-sops-config.sh
#
# This script validates SOPS configuration dynamically for any repository

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   SOPS Configuration Validation                              ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"

cd "$REPO_ROOT"

# Check if .sops.yaml exists in current repository
if [[ -f "$REPO_ROOT/.sops.yaml" ]]; then
    echo -e "${GREEN}✓ Found .sops.yaml in repository${NC}"
    
    # Validate existing configuration
    if ! python3 -c "import yaml; yaml.safe_load(open('.sops.yaml'))" 2>/dev/null; then
        echo -e "${RED}✗ Error: Invalid YAML format in .sops.yaml${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ .sops.yaml format valid${NC}"
    
    # Test encryption with existing config
    cat > test-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: test-secret
type: Opaque
stringData:
  test: value
EOF
    
    if sops -e -i test-secret.yaml 2>/dev/null; then
        echo -e "${GREEN}✓ SOPS encryption successful with repository config${NC}"
        rm -f test-secret.yaml
    else
        echo -e "${RED}✗ Error: SOPS encryption failed${NC}"
        rm -f test-secret.yaml
        exit 1
    fi
    
else
    echo -e "${YELLOW}⚠ No .sops.yaml found in repository${NC}"
    echo -e "${BLUE}Retrieving platform Age key...${NC}"
    AGE_PRIVATE_KEY=$(kubectl get secret sops-age -n argocd -o jsonpath='{.data.keys\.txt}' | base64 -d | head -1)
    AGE_PUBLIC_KEY=$(echo "$AGE_PRIVATE_KEY" | age-keygen -y)

    if [[ -z "$AGE_PUBLIC_KEY" ]]; then
        echo -e "${RED}✗ Error: Could not retrieve platform Age key${NC}"
        exit 1
    fi
    
    # Create temporary test configuration
    cat > .sops.yaml.test <<EOF
creation_rules:
  - path_regex: .*\.yaml$
    age: $AGE_PUBLIC_KEY
    encrypted_regex: '^(data|stringData)$'
EOF
    
    # Test with temporary config
    cat > test-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: test-secret
type: Opaque
stringData:
  test: value
EOF
    
    if SOPS_FILE=.sops.yaml.test sops -e -i test-secret.yaml 2>/dev/null; then
        echo -e "${GREEN}✓ SOPS encryption successful with platform keys${NC}"
    else
        echo -e "${RED}✗ Error: SOPS encryption failed${NC}"
        rm -f .sops.yaml.test test-secret.yaml
        exit 1
    fi
    
    # Cleanup
    rm -f .sops.yaml.test test-secret.yaml
fi

echo -e "${GREEN}✓ SOPS configuration validation complete${NC}"
echo ""

SOPS_CONFIG="$TENANTS_REPO_PATH/.sops.yaml"

# Check if .sops.yaml exists
if [ ! -f "$SOPS_CONFIG" ]; then
    echo -e "${RED}✗ Error: .sops.yaml not found at $SOPS_CONFIG${NC}"
    exit 1
fi

echo -e "${GREEN}✓ .sops.yaml found${NC}"
echo ""

# Validation 1: YAML syntax
echo -e "${BLUE}[1] Validating YAML syntax...${NC}"
if command -v yq &> /dev/null; then
    if yq eval '.' "$SOPS_CONFIG" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ YAML syntax valid${NC}"
    else
        echo -e "${RED}✗ YAML syntax invalid${NC}"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo -e "${YELLOW}⚠️  yq not found, skipping YAML syntax validation${NC}"
    WARNINGS=$((WARNINGS + 1))
fi
echo ""

# Validation 2: creation_rules structure
echo -e "${BLUE}[2] Validating creation_rules structure...${NC}"
if grep -q "creation_rules:" "$SOPS_CONFIG"; then
    echo -e "${GREEN}✓ creation_rules found${NC}"
    
    # Check for path_regex
    if grep -q "path_regex:" "$SOPS_CONFIG"; then
        echo -e "${GREEN}✓ path_regex configured${NC}"
    else
        echo -e "${RED}✗ path_regex not found${NC}"
        ERRORS=$((ERRORS + 1))
    fi
    
    # Check for age keys
    if grep -q "age:" "$SOPS_CONFIG"; then
        echo -e "${GREEN}✓ age keys configured${NC}"
    else
        echo -e "${RED}✗ age keys not found${NC}"
        ERRORS=$((ERRORS + 1))
    fi
    
    # Check for encrypted_regex
    if grep -q "encrypted_regex:" "$SOPS_CONFIG"; then
        echo -e "${GREEN}✓ encrypted_regex configured${NC}"
    else
        echo -e "${RED}✗ encrypted_regex not found${NC}"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo -e "${RED}✗ creation_rules not found${NC}"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# Validation 3: Age key format
echo -e "${BLUE}[3] Validating Age key format...${NC}"
AGE_KEYS=$(grep "age:" "$SOPS_CONFIG" | awk '{print $2}')
if [ -z "$AGE_KEYS" ]; then
    echo -e "${RED}✗ No Age keys found${NC}"
    ERRORS=$((ERRORS + 1))
else
    while IFS= read -r key; do
        if [[ "$key" =~ ^age1[a-z0-9]{58}$ ]]; then
            echo -e "${GREEN}✓ Age key format valid: ${key:0:20}...${NC}"
        else
            echo -e "${RED}✗ Invalid Age key format: $key${NC}"
            ERRORS=$((ERRORS + 1))
        fi
    done <<< "$AGE_KEYS"
fi
echo ""

# Validation 4: Path pattern matching
echo -e "${BLUE}[4] Testing path pattern matching...${NC}"
if [ -d "$TENANTS_REPO_PATH/tenants" ]; then
    SECRET_FILES=$(find "$TENANTS_REPO_PATH/tenants" -type f -path "*/secrets/*.yaml" 2>/dev/null || true)
    
    if [ -z "$SECRET_FILES" ]; then
        echo -e "${YELLOW}⚠️  No secret files found in tenants directory${NC}"
        WARNINGS=$((WARNINGS + 1))
    else
        FILE_COUNT=$(echo "$SECRET_FILES" | wc -l | tr -d ' ')
        echo -e "${BLUE}Found $FILE_COUNT secret files${NC}"
        
        # Check if files match patterns
        MATCHED=0
        while IFS= read -r file; do
            REL_PATH="${file#$TENANTS_REPO_PATH/}"
            if [[ "$REL_PATH" =~ tenants/.*/base/secrets/.*\.yaml ]] || \
               [[ "$REL_PATH" =~ tenants/.*/overlays/dev/secrets/.*\.yaml ]] || \
               [[ "$REL_PATH" =~ tenants/.*/overlays/staging/secrets/.*\.yaml ]] || \
               [[ "$REL_PATH" =~ tenants/.*/overlays/production/secrets/.*\.yaml ]]; then
                MATCHED=$((MATCHED + 1))
            fi
        done <<< "$SECRET_FILES"
        
        echo -e "${GREEN}✓ $MATCHED/$FILE_COUNT files match SOPS patterns${NC}"
        
        if [ $MATCHED -lt $FILE_COUNT ]; then
            echo -e "${YELLOW}⚠️  $((FILE_COUNT - MATCHED)) files don't match any pattern${NC}"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
else
    echo -e "${YELLOW}⚠️  Tenants directory not found${NC}"
    WARNINGS=$((WARNINGS + 1))
fi
echo ""

# Validation 5: Test encryption (optional)
echo -e "${BLUE}[5] Testing encryption capability...${NC}"
if command -v sops &> /dev/null; then
    # Create temporary test secret
    TEST_SECRET=$(mktemp)
    cat > "$TEST_SECRET" << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: test-secret
  namespace: default
type: Opaque
stringData:
  test-key: test-value
EOF
    
    # Try to encrypt
    TEST_DIR="$TENANTS_REPO_PATH/tenants/test/base/secrets"
    mkdir -p "$TEST_DIR"
    TEST_FILE="$TEST_DIR/test.yaml"
    cp "$TEST_SECRET" "$TEST_FILE"
    
    if sops -e "$TEST_FILE" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Encryption test successful${NC}"
        rm -f "$TEST_FILE"
        rmdir -p "$TEST_DIR" 2>/dev/null || true
    else
        echo -e "${YELLOW}⚠️  Encryption test failed (Age key may not be available locally)${NC}"
        WARNINGS=$((WARNINGS + 1))
        rm -f "$TEST_FILE"
        rmdir -p "$TEST_DIR" 2>/dev/null || true
    fi
    
    rm -f "$TEST_SECRET"
else
    echo -e "${YELLOW}⚠️  sops not found, skipping encryption test${NC}"
    WARNINGS=$((WARNINGS + 1))
fi
echo ""

# Summary
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Validation Summary                                         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}✓ All validations passed${NC}"
elif [ $ERRORS -eq 0 ]; then
    echo -e "${YELLOW}⚠️  Validations passed with $WARNINGS warnings${NC}"
else
    echo -e "${RED}✗ Validation failed with $ERRORS errors and $WARNINGS warnings${NC}"
fi

echo ""
echo -e "${BLUE}Pre-commit hook integration:${NC}"
echo -e "  Add to .git/hooks/pre-commit:"
echo -e "  ${GREEN}#!/bin/bash${NC}"
echo -e "  ${GREEN}./scripts/validate-sops-config.sh${NC}"
echo -e "  ${GREEN}exit \$?${NC}"
echo ""

if [ $ERRORS -gt 0 ]; then
    exit 1
fi

exit 0
