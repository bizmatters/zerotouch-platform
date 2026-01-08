#!/bin/bash
# Verify AgentSandboxService Platform API
# Usage: ./18-verify-agentsandbox-api.sh
#
# This script verifies:
# 1. platform-apis Application exists and is synced
# 2. AgentSandboxService XRDs (CRDs) are installed
# 3. agent-sandbox-service-main Composition exists
# 4. Component XRDs and Compositions exist

# Print output immediately for CI visibility
echo "Starting AgentSandboxService API verification..."

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "ERROR: Failed to determine script directory" >&2
    exit 1
}

# Navigate to repo root from script location (4 levels up from scripts/bootstrap/validation/apis/)
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)" || {
    echo "ERROR: Failed to navigate to repo root from $SCRIPT_DIR" >&2
    # Fallback: assume we're in the repo root already
    REPO_ROOT="$(pwd)"
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Kubectl wrapper function with optional timeout
kubectl_cmd() {
    # Use timeout if available, otherwise run directly
    if command -v timeout >/dev/null 2>&1; then
        timeout 15 kubectl "$@"
    else
        kubectl "$@"
    fi
}

# Kubectl retry function
kubectl_retry() {
    local max_attempts=5
    local attempt=1
    local exitCode=0

    while [ $attempt -le $max_attempts ]; do
        if kubectl_cmd "$@" 2>/dev/null; then
            return 0
        fi

        exitCode=$?

        if [ $attempt -lt $max_attempts ]; then
            local delay=$((attempt * 2))
            echo -e "${YELLOW}⚠️  kubectl command failed (attempt $attempt/$max_attempts). Retrying in ${delay}s...${NC}" >&2
            sleep $delay
        fi

        attempt=$((attempt + 1))
    done

    echo -e "${RED}✗ kubectl command failed after $max_attempts attempts${NC}" >&2
    return $exitCode
}

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Verifying AgentSandboxService Platform API                ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Track overall status
ERRORS=0
WARNINGS=0

# 1. Verify platform-apis Application exists and is synced
echo -e "${BLUE}Verifying platform-apis Application...${NC}"

if kubectl_retry get application apis -n argocd &>/dev/null; then
    echo -e "${GREEN}✓ Application 'apis' exists${NC}"
    
    SYNC_STATUS=$(kubectl_retry get application apis -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null)
    if [ "$SYNC_STATUS" = "Synced" ]; then
        echo -e "${GREEN}✓ Application sync status: Synced${NC}"
    else
        echo -e "${YELLOW}⚠️  Application sync status: $SYNC_STATUS (expected: Synced)${NC}"
        WARNINGS=$((WARNINGS + 1))
    fi
    
    HEALTH_STATUS=$(kubectl_retry get application apis -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null)
    if [ "$HEALTH_STATUS" = "Healthy" ]; then
        echo -e "${GREEN}✓ Application health status: Healthy${NC}"
    else
        echo -e "${YELLOW}⚠️  Application health status: $HEALTH_STATUS (expected: Healthy)${NC}"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo -e "${RED}✗ Application 'apis' not found${NC}"
    echo -e "${BLUE}ℹ  Check if platform/apis.yaml exists and is applied${NC}"
    ERRORS=$((ERRORS + 1))
fi

echo ""

# 2. Verify AgentSandboxService Main XRD is installed
echo -e "${BLUE}Verifying AgentSandboxService Main XRD...${NC}"

if kubectl_retry get crd xagentsandboxservices.platform.bizmatters.io &>/dev/null; then
    echo -e "${GREEN}✓ Main XRD 'xagentsandboxservices.platform.bizmatters.io' is installed${NC}"
    
    # Verify claim CRD also exists
    if kubectl_retry get crd agentsandboxservices.platform.bizmatters.io &>/dev/null; then
        echo -e "${GREEN}✓ Claim CRD 'agentsandboxservices.platform.bizmatters.io' is installed${NC}"
    else
        echo -e "${RED}✗ Claim CRD 'agentsandboxservices.platform.bizmatters.io' not found${NC}"
        ERRORS=$((ERRORS + 1))
    fi
    
    # Verify XRD has correct API version
    API_VERSION=$(kubectl_retry get crd xagentsandboxservices.platform.bizmatters.io -o jsonpath='{.spec.versions[0].name}' 2>/dev/null)
    if [ "$API_VERSION" = "v1alpha1" ]; then
        echo -e "${GREEN}✓ Main XRD API version: v1alpha1${NC}"
    else
        echo -e "${YELLOW}⚠️  Main XRD API version: $API_VERSION (expected: v1alpha1)${NC}"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo -e "${RED}✗ Main XRD 'xagentsandboxservices.platform.bizmatters.io' not found${NC}"
    echo -e "${BLUE}ℹ  Check if platform/apis/agentsandbox/xrds/components/xagentsandboxservices.yaml is applied${NC}"
    ERRORS=$((ERRORS + 1))
fi

echo ""

# 3. Verify Component XRDs are installed
echo -e "${BLUE}Verifying Component XRDs...${NC}"

COMPONENT_XRDS=(
    "xagentsandboxconnections.platform.bizmatters.io"
    "xagentsandboxcores.platform.bizmatters.io"
    "xagentsandboxnetworkings.platform.bizmatters.io"
    "xagentsandboxscalings.platform.bizmatters.io"
    "xagentsandboxserviceaccounts.platform.bizmatters.io"
    "xagentsandboxstorages.platform.bizmatters.io"
)

COMPONENT_XRD_ERRORS=0
for xrd in "${COMPONENT_XRDS[@]}"; do
    if kubectl_retry get crd "$xrd" &>/dev/null; then
        echo -e "${GREEN}✓ Component XRD '$xrd' is installed${NC}"
    else
        echo -e "${RED}✗ Component XRD '$xrd' not found${NC}"
        COMPONENT_XRD_ERRORS=$((COMPONENT_XRD_ERRORS + 1))
    fi
done

if [ $COMPONENT_XRD_ERRORS -eq 0 ]; then
    echo -e "${GREEN}✓ All ${#COMPONENT_XRDS[@]} component XRDs are installed${NC}"
else
    echo -e "${RED}✗ $COMPONENT_XRD_ERRORS out of ${#COMPONENT_XRDS[@]} component XRDs are missing${NC}"
    ERRORS=$((ERRORS + COMPONENT_XRD_ERRORS))
fi

echo ""

# 4. Verify Main Composition exists
echo -e "${BLUE}Verifying Main Composition...${NC}"

if kubectl_retry get composition agent-sandbox-service-main &>/dev/null; then
    echo -e "${GREEN}✓ Main Composition 'agent-sandbox-service-main' exists${NC}"
    
    # Verify Composition references correct XRD
    COMPOSITE_TYPE=$(kubectl_retry get composition agent-sandbox-service-main -o jsonpath='{.spec.compositeTypeRef.kind}' 2>/dev/null)
    if [ "$COMPOSITE_TYPE" = "XAgentSandboxService" ]; then
        echo -e "${GREEN}✓ Main Composition references correct XRD: XAgentSandboxService${NC}"
    else
        echo -e "${YELLOW}⚠️  Main Composition references: $COMPOSITE_TYPE (expected: XAgentSandboxService)${NC}"
        WARNINGS=$((WARNINGS + 1))
    fi
    
    # Count resource templates in Main Composition
    RESOURCE_COUNT=$(kubectl_retry get composition agent-sandbox-service-main -o json 2>/dev/null | jq '.spec.resources | length' 2>/dev/null)
    if [ "$RESOURCE_COUNT" = "6" ]; then
        echo -e "${GREEN}✓ Main Composition has 6 component resources${NC}"
    else
        echo -e "${YELLOW}⚠️  Main Composition has $RESOURCE_COUNT component resources (expected: 6)${NC}"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo -e "${RED}✗ Main Composition 'agent-sandbox-service-main' not found${NC}"
    echo -e "${BLUE}ℹ  Check if platform/apis/agentsandbox/compositions/agentsandbox-composition.yaml is applied${NC}"
    ERRORS=$((ERRORS + 1))
fi

echo ""

# 5. Verify Component Compositions exist
echo -e "${BLUE}Verifying Component Compositions...${NC}"

COMPONENT_COMPOSITIONS=(
    "agent-sandbox-connection"
    "agentsandbox-core"
    "agent-sandbox-networking"
    "agent-sandbox-scaling"
    "agent-sandbox-serviceaccount"
    "agent-sandbox-storage"
)

COMPONENT_COMP_ERRORS=0
for comp in "${COMPONENT_COMPOSITIONS[@]}"; do
    if kubectl_retry get composition "$comp" &>/dev/null; then
        echo -e "${GREEN}✓ Component Composition '$comp' exists${NC}"
    else
        echo -e "${RED}✗ Component Composition '$comp' not found${NC}"
        COMPONENT_COMP_ERRORS=$((COMPONENT_COMP_ERRORS + 1))
    fi
done

if [ $COMPONENT_COMP_ERRORS -eq 0 ]; then
    echo -e "${GREEN}✓ All ${#COMPONENT_COMPOSITIONS[@]} component compositions are installed${NC}"
else
    echo -e "${RED}✗ $COMPONENT_COMP_ERRORS out of ${#COMPONENT_COMPOSITIONS[@]} component compositions are missing${NC}"
    ERRORS=$((ERRORS + COMPONENT_COMP_ERRORS))
fi

echo ""

echo ""

# Summary
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Verification Summary                                       ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}✓ All checks passed! AgentSandboxService API is ready.${NC}"
    echo ""
    echo -e "${BLUE}ℹ  Next steps:${NC}"
    echo "  - Run Python tests: cd $REPO_ROOT/platform/apis/agentsandbox/tests && pytest -v"
    echo "  - Test deployment: kubectl apply -f $REPO_ROOT/platform/apis/agentsandbox/examples/"
    echo "  - Monitor hibernation: $REPO_ROOT/platform/apis/agentsandbox/tests/hibernation/"
    exit 0
elif [ $ERRORS -eq 0 ]; then
    echo -e "${YELLOW}⚠️  AgentSandboxService API has $WARNINGS warning(s) but no errors${NC}"
    echo ""
    echo -e "${BLUE}ℹ  Review warnings above and monitor the deployment${NC}"
    exit 0
else
    echo -e "${RED}✗ AgentSandboxService API has $ERRORS error(s) and $WARNINGS warning(s)${NC}"
    echo ""
    echo -e "${BLUE}ℹ  Troubleshooting steps:${NC}"
    echo "  1. Check ArgoCD Application: kubectl describe application apis -n argocd"
    echo "  2. Check Main XRD: kubectl get xrd xagentsandboxservices.platform.bizmatters.io"
    echo "  3. Check Component XRDs: kubectl get xrd | grep agentsandbox"
    echo "  4. Check Main Composition: kubectl describe composition agent-sandbox-service-main"
    echo "  5. Check Component Compositions: kubectl get composition | grep agent-sandbox"
    echo "  6. Review platform/apis/agentsandbox/README.md for setup instructions"
    exit 1
fi