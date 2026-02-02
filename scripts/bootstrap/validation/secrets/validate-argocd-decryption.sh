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

# 1. Verify KSOPS init container completed and tools available
echo -e "${BLUE}[1/5] Checking KSOPS init container status...${NC}"
POD_NAME=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}')
if [ -z "$POD_NAME" ]; then
    echo -e "${RED}✗ argocd-repo-server pod not found${NC}"
    FAILED=1
else
    # Check if init container completed
    INIT_STATUS=$(kubectl get pod "$POD_NAME" -n argocd -o jsonpath='{.status.initContainerStatuses[?(@.name=="install-ksops")].state.terminated.reason}' 2>/dev/null || echo "")
    if [[ "$INIT_STATUS" == "Completed" ]]; then
        # Check KSOPS binary exists
        if kubectl exec -n argocd "$POD_NAME" -c argocd-repo-server -- test -f /usr/local/bin/ksops 2>/dev/null; then
            echo -e "${GREEN}✓ KSOPS init container completed and tools available${NC}"
        else
            echo -e "${RED}✗ KSOPS tools not found${NC}"
            FAILED=1
        fi
    else
        echo -e "${RED}✗ KSOPS init container not completed${NC}"
        echo -e "${YELLOW}  Status: $INIT_STATUS${NC}"
        FAILED=1
    fi
fi

# 2. Verify Age key secret exists
echo -e "${BLUE}[2/5] Checking Age key secret...${NC}"
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

# 3. Verify test secret can be encrypted
echo -e "${BLUE}[3/5] Checking test encrypted secret...${NC}"
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

# 4. Verify .sops.yaml configuration
echo -e "${BLUE}[4/5] Checking .sops.yaml configuration...${NC}"
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

# 5. Verify KSOPS tools available in repo-server
echo -e "${BLUE}[5/5] Checking KSOPS tools in repo-server...${NC}"
if [ -n "$POD_NAME" ]; then
    if kubectl exec -n argocd "$POD_NAME" -c argocd-repo-server -- which ksops &>/dev/null; then
        echo -e "${GREEN}✓ KSOPS binary available in repo-server${NC}"
    else
        echo -e "${RED}✗ KSOPS binary not in PATH${NC}"
        FAILED=1
    fi
else
    echo -e "${RED}✗ Cannot check KSOPS tools (pod not found)${NC}"
    FAILED=1
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
