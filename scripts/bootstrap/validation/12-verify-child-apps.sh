#!/bin/bash
# Verify Child Applications Created
# Usage: ./12-verify-child-apps.sh
#
# This script verifies that all expected child applications
# were created by the platform-bootstrap ApplicationSet

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Kubectl retry function
kubectl_retry() {
    local max_attempts=20
    local timeout=15
    local attempt=1
    local exitCode=0

    while [ $attempt -le $max_attempts ]; do
        if timeout $timeout kubectl "$@"; then
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
echo -e "${BLUE}║   Verifying Child Applications                               ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${BLUE}Verifying child Applications...${NC}"
echo -e "${BLUE}Waiting 10s for ApplicationSet to generate apps...${NC}"
sleep 10

# Check if running in preview mode (Kind cluster)
IS_PREVIEW_MODE=false
if kubectl get nodes -o name 2>/dev/null | grep -q "zerotouch-preview"; then
    IS_PREVIEW_MODE=true
fi

if [ "$IS_PREVIEW_MODE" = true ]; then
    # Preview mode: Only core components
    EXPECTED_APPS=("crossplane-operator" "secrets" "keda" "foundation-config" "dragonfly" "nats")
    echo -e "${BLUE}Preview mode detected - checking core applications only${NC}"
else
    # Production mode: All components including infrastructure and gateway stack
    EXPECTED_APPS=(
        "crossplane-operator" "secrets" "keda" "apis" "foundation-config" "dragonfly" "tenant-infrastructure"
        "cert-manager" "nats" "cnpg"
        "gateway-api-crds" "gateway-class" "gateway-config" "gateway-foundation"
        "hcloud-ccm" "external-dns" "cert-manager-webhook-hetzner"
        "local-path-provisioner"
        "agentgateway" "agentgateway-httproute"
    )
fi

echo -e "${BLUE}Checking ${#EXPECTED_APPS[@]} applications...${NC}"
echo ""

MISSING_APPS=()
FOUND_COUNT=0

for app in "${EXPECTED_APPS[@]}"; do
    echo -e "${BLUE}  Checking: $app${NC}"
    if kubectl_retry get application "$app" -n argocd &>/dev/null; then
        echo -e "${GREEN}    ✓ Found${NC}"
        ((++FOUND_COUNT))
    else
        echo -e "${RED}    ✗ Missing${NC}"
        MISSING_APPS+=("$app")
    fi
done

echo ""
echo -e "${BLUE}Summary: $FOUND_COUNT/${#EXPECTED_APPS[@]} applications found${NC}"

if [ ${#MISSING_APPS[@]} -gt 0 ]; then
    echo -e "${RED}✗ Missing Applications: ${MISSING_APPS[*]}${NC}"
    echo -e "${YELLOW}Check platform-bootstrap status: kubectl describe application platform-bootstrap -n argocd${NC}"
    echo ""
    exit 1
fi

echo -e "${GREEN}✓ All child Applications created${NC}"
echo ""
