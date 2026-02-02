#!/bin/bash
# Wait for KSOPS sidecar to be ready in ArgoCD repo server
# Usage: ./09c-wait-ksops-sidecar.sh [--timeout seconds] [--namespace namespace]

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default values
TIMEOUT=60
CHECK_INTERVAL=10
ARGOCD_NAMESPACE="argocd"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --namespace)
            ARGOCD_NAMESPACE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--timeout seconds] [--namespace namespace]"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Waiting for KSOPS to be Ready                             ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${BLUE}⏳ Waiting for KSOPS to be ready (timeout: ${TIMEOUT}s)...${NC}"
echo -e "${BLUE}Namespace: $ARGOCD_NAMESPACE${NC}"
echo ""

ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    echo -e "${BLUE}=== Checking KSOPS sidecar status (${ELAPSED}s / ${TIMEOUT}s) ===${NC}"
    
    # Check if repo server deployment exists
    if ! kubectl get deployment argocd-repo-server -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
        echo -e "${YELLOW}⏳ ArgoCD repo server deployment not found${NC}"
        sleep $CHECK_INTERVAL
        ELAPSED=$((ELAPSED + CHECK_INTERVAL))
        continue
    fi
    
    # Check if repo server pod exists
    REPO_POD=$(kubectl get pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "$REPO_POD" ]]; then
        echo -e "${YELLOW}⏳ ArgoCD repo server pod not found${NC}"
        sleep $CHECK_INTERVAL
        ELAPSED=$((ELAPSED + CHECK_INTERVAL))
        continue
    fi
    
    echo -e "${BLUE}Found repo server pod: $REPO_POD${NC}"
    
    # Check if init container completed successfully
    INIT_STATUS=$(kubectl get pod "$REPO_POD" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.initContainerStatuses[?(@.name=="install-ksops")].state.terminated.reason}' 2>/dev/null || echo "")
    
    if [[ "$INIT_STATUS" != "Completed" ]]; then
        echo -e "${YELLOW}⏳ Init container install-ksops not completed yet (status: $INIT_STATUS)${NC}"
        sleep $CHECK_INTERVAL
        ELAPSED=$((ELAPSED + CHECK_INTERVAL))
        continue
    fi
    
    echo -e "${GREEN}✓ Init container install-ksops completed${NC}"
    
    # Check if main repo-server container is ready
    REPO_READY=$(kubectl get pod "$REPO_POD" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.containerStatuses[?(@.name=="argocd-repo-server")].ready}' 2>/dev/null || echo "false")
    
    if [[ "$REPO_READY" != "true" ]]; then
        echo -e "${YELLOW}⏳ Repo server container not ready yet${NC}"
        sleep $CHECK_INTERVAL
        ELAPSED=$((ELAPSED + CHECK_INTERVAL))
        continue
    fi
    
    echo -e "${GREEN}✓ Repo server container is ready${NC}"
    
    # Check if KSOPS tools are available
    echo -e "${BLUE}Checking KSOPS tools...${NC}"
    if kubectl exec "$REPO_POD" -n "$ARGOCD_NAMESPACE" -c argocd-repo-server -- test -f /usr/local/bin/ksops 2>/dev/null; then
        echo -e "${GREEN}✓ KSOPS binary exists${NC}"
    else
        echo -e "${YELLOW}⏳ KSOPS binary not found${NC}"
        sleep $CHECK_INTERVAL
        ELAPSED=$((ELAPSED + CHECK_INTERVAL))
        continue
    fi
    
    # Check if Age key file exists (optional check)
    echo -e "${BLUE}Checking Age key file...${NC}"
    if kubectl get secret sops-age -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Age key secret exists${NC}"
    else
        echo -e "${YELLOW}⚠️  Age key secret not found (but sidecar is ready)${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}✓ KSOPS is ready and operational!${NC}"
    echo ""
    exit 0
done

# Timeout reached
echo ""
echo -e "${RED}✗ Timeout waiting for KSOPS sidecar to be ready${NC}"
echo ""

echo -e "${YELLOW}Troubleshooting information:${NC}"
echo ""

# Show repo server pod status
echo -e "${BLUE}Repo Server Pod Status:${NC}"
kubectl get pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-repo-server 2>/dev/null || echo "Failed to get repo server pods"

echo ""
echo -e "${BLUE}Pod Description:${NC}"
kubectl describe pod -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-repo-server 2>/dev/null || echo "Failed to describe repo server pod"

echo ""
echo -e "${YELLOW}Troubleshooting commands:${NC}"
echo "  kubectl logs -n $ARGOCD_NAMESPACE -l app.kubernetes.io/name=argocd-repo-server -c ksops"
echo "  kubectl logs -n $ARGOCD_NAMESPACE -l app.kubernetes.io/name=argocd-repo-server -c argocd-repo-server"
echo "  kubectl describe pod -n $ARGOCD_NAMESPACE -l app.kubernetes.io/name=argocd-repo-server"
echo ""

exit 1