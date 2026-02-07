#!/bin/bash
# Validation script for CHECKPOINT 2: Secret Injection
# Usage: ./validate-secret-injection.sh
#
# This script validates that secrets exist in Git and are properly injected into cluster

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
echo -e "${BLUE}║   CHECKPOINT 2: Secret Injection Validation                 ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Get environment from ENV variable or default to dev
ENV="${ENV:-dev}"
echo -e "${BLUE}Environment: $ENV${NC}"
echo ""

# Validation 1: Check encrypted secrets exist in Git
cd "$REPO_ROOT"
validate "Encrypted secrets exist in Git repository" \
    "find bootstrap/argocd/overlays -name '*.secret.yaml' 2>/dev/null | grep -q '.'"

# Validation 2: Check sops-age secret exists in cluster
validate "sops-age secret exists in argocd namespace" \
    "kubectl get secret sops-age -n argocd &>/dev/null"

# Validation 3: Check sops-age secret has correct format
validate "sops-age secret has keys.txt field" \
    "kubectl get secret sops-age -n argocd -o jsonpath='{.data.keys\.txt}' | base64 -d | grep -q '^AGE-SECRET-KEY-1'"

# Validation 4: Check GitHub App secret exists
validate "argocd-github-app-creds secret exists in argocd namespace" \
    "kubectl get secret argocd-github-app-creds -n argocd &>/dev/null"

# Validation 5: Check GitHub App secret has required fields
validate "argocd-github-app-creds has all required fields" \
    "kubectl get secret argocd-github-app-creds -n argocd -o jsonpath='{.data.githubAppID}' | base64 -d | grep -q '.' && \
     kubectl get secret argocd-github-app-creds -n argocd -o jsonpath='{.data.githubAppInstallationID}' | base64 -d | grep -q '.' && \
     kubectl get secret argocd-github-app-creds -n argocd -o jsonpath='{.data.githubAppPrivateKey}' | base64 -d | grep -q 'BEGIN'"

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
    echo -e "${GREEN}✓ CHECKPOINT 2 VALIDATION PASSED${NC}"
    echo ""
    echo -e "${YELLOW}Success Criteria Met:${NC}"
    echo -e "  ✓ Encrypted secrets exist in Git"
    echo -e "  ✓ Required secrets injected to cluster"
    echo -e "  ✓ Secrets have correct format"
    echo -e "  ✓ Ready for ArgoCD sync"
    echo ""
    exit 0
else
    echo -e "${RED}✗ CHECKPOINT 2 VALIDATION FAILED${NC}"
    echo ""
    exit 1
fi
