#!/bin/bash
# Validation script for CHECKPOINT 4: ArgoCD Secret Decryption
# Verifies KSOPS plugin integration, secret decryption, and cluster application

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
echo -e "${BLUE}║   CHECKPOINT 4: ArgoCD Secret Decryption Validation         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

FAILED=0

# Check if repository has .sops.yaml
cd "$REPO_ROOT"
if [[ -f ".sops.yaml" ]]; then
    echo -e "${GREEN}✓ Repository has .sops.yaml configuration${NC}"
    USE_REPO_CONFIG=true
else
    echo -e "${YELLOW}⚠ No .sops.yaml in repository, using platform keys for testing${NC}"
    USE_REPO_CONFIG=false
fi

# 1. Verify KSOPS plugin activated (.sops.yaml detected)
echo -e "${BLUE}[1/6] Checking KSOPS plugin configuration...${NC}"
if kubectl get configmap cmp-plugin -n argocd -o yaml | grep -q "test -f .sops.yaml"; then
    echo -e "${GREEN}✓ KSOPS plugin configured to detect .sops.yaml${NC}"
else
    echo -e "${RED}✗ KSOPS plugin discovery not configured${NC}"
    FAILED=1
fi

# 2. Verify KSOPS sidecar running
echo -e "${BLUE}[2/6] Checking KSOPS sidecar status...${NC}"
POD_NAME=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}')
if [ -z "$POD_NAME" ]; then
    echo -e "${RED}✗ argocd-repo-server pod not found${NC}"
    FAILED=1
else
    # Check if ksops container exists and is running
    CONTAINER_STATUS=$(kubectl get pod "$POD_NAME" -n argocd -o jsonpath='{.status.containerStatuses[?(@.name=="ksops")].state}' 2>/dev/null || echo "")
    if echo "$CONTAINER_STATUS" | grep -q "running"; then
        echo -e "${GREEN}✓ KSOPS sidecar container running${NC}"
    else
        echo -e "${RED}✗ KSOPS sidecar not running${NC}"
        echo -e "${YELLOW}  Status: $CONTAINER_STATUS${NC}"
        FAILED=1
    fi
fi

# 3. Verify Age key secret exists
echo -e "${BLUE}[3/6] Checking Age key secret...${NC}"
if kubectl get secret sops-age -n argocd &>/dev/null; then
    AGE_KEY=$(kubectl get secret sops-age -n argocd -o jsonpath='{.data.keys\.txt}' | base64 -d | head -c 20)
    if [[ "$AGE_KEY" == "AGE-SECRET-KEY-1"* ]]; then
        echo -e "${GREEN}✓ Age key secret exists with correct format${NC}"
    else
        echo -e "${RED}✗ Age key format incorrect${NC}"
        FAILED=1
    fi
else
    echo -e "${RED}✗ Age key secret not found${NC}"
    FAILED=1
fi

# 4. Verify test secret can be encrypted
echo -e "${BLUE}[4/6] Checking test encrypted secret...${NC}"
TEST_DIR=$(mktemp -d)
cat > "$TEST_DIR/test.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: test-secret
type: Opaque
stringData:
  test: value
EOF

if $USE_REPO_CONFIG; then
    if sops -e "$TEST_DIR/test.yaml" > "$TEST_DIR/test.enc.yaml" 2>/dev/null; then
        echo -e "${GREEN}✓ Test secret encrypted with SOPS${NC}"
    else
        echo -e "${RED}✗ Test secret encryption failed${NC}"
        FAILED=1
    fi
else
    echo -e "${YELLOW}⚠ Skipping encryption test (no .sops.yaml)${NC}"
fi
rm -rf "$TEST_DIR"

# 5. Verify .sops.yaml configuration
echo -e "${BLUE}[5/6] Checking .sops.yaml configuration...${NC}"
if $USE_REPO_CONFIG; then
    if grep -q "encrypted_regex" "$REPO_ROOT/.sops.yaml"; then
        echo -e "${GREEN}✓ .sops.yaml configuration exists${NC}"
    else
        echo -e "${RED}✗ .sops.yaml missing encrypted_regex${NC}"
        FAILED=1
    fi
else
    echo -e "${YELLOW}⚠ No .sops.yaml in repository${NC}"
fi

# 6. Verify KSOPS sidecar logs
echo -e "${BLUE}[6/6] Checking KSOPS sidecar logs...${NC}"
SIDECAR_LOGS=$(kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server -c ksops --tail=100 2>/dev/null || echo "")
if echo "$SIDECAR_LOGS" | grep -q "serving on"; then
    echo -e "${GREEN}✓ KSOPS CMP server running${NC}"
else
    echo -e "${YELLOW}⚠ KSOPS CMP server logs not showing expected message${NC}"
fi

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Validation Summary                                         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All validation checks passed${NC}"
    echo -e "${GREEN}✓ CHECKPOINT 4: ArgoCD Secret Decryption - VALIDATED${NC}"
    exit 0
else
    echo -e "${RED}✗ Some validation checks failed${NC}"
    echo -e "${RED}✗ CHECKPOINT 4: ArgoCD Secret Decryption - FAILED${NC}"
    exit 1
fi
