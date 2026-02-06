#!/bin/bash
# Wait for ArgoCD pods to be ready
# Usage: ./09a-wait-argocd-pods.sh [--timeout seconds] [--namespace namespace]

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default values
TIMEOUT=300
CHECK_INTERVAL=5
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
echo -e "${BLUE}║   Waiting for ArgoCD Pods to be Ready                       ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${BLUE}⏳ Waiting for ArgoCD pods to be ready (timeout: ${TIMEOUT}s)...${NC}"
echo -e "${BLUE}Namespace: $ARGOCD_NAMESPACE${NC}"
echo ""

ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    echo -e "${BLUE}=== Checking ArgoCD pods (${ELAPSED}s / ${TIMEOUT}s) ===${NC}"
    
    # Check if namespace exists
    if ! kubectl get namespace "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
        echo -e "${YELLOW}⏳ Namespace '$ARGOCD_NAMESPACE' not found${NC}"
        sleep $CHECK_INTERVAL
        ELAPSED=$((ELAPSED + CHECK_INTERVAL))
        continue
    fi
    
    # Count running workload pods (Deployments/StatefulSets)
    RUNNING_PODS=$(kubectl get pods -n "$ARGOCD_NAMESPACE" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    
    if [[ "$RUNNING_PODS" -eq 0 ]]; then
        echo -e "${YELLOW}⏳ No running ArgoCD pods found yet${NC}"
        sleep $CHECK_INTERVAL
        ELAPSED=$((ELAPSED + CHECK_INTERVAL))
        continue
    fi
    
    # Check ready pods (only Running phase)
    READY_PODS=$(kubectl get pods -n "$ARGOCD_NAMESPACE" -o json 2>/dev/null | jq '[.items[] | select(.status.phase=="Running") | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length' 2>/dev/null || echo "0")
    
    # Check Job/CronJob pods
    COMPLETED_JOBS=$(kubectl get pods -n "$ARGOCD_NAMESPACE" -o json 2>/dev/null | jq '[.items[] | select(.metadata.ownerReferences[]?.kind=="Job" and .status.phase=="Succeeded")] | length' 2>/dev/null || echo "0")
    FAILED_JOBS=$(kubectl get pods -n "$ARGOCD_NAMESPACE" -o json 2>/dev/null | jq '[.items[] | select(.metadata.ownerReferences[]?.kind=="Job" and (.status.phase=="Failed" or .status.phase=="Error"))] | length' 2>/dev/null || echo "0")
    
    echo -e "${BLUE}Running pods: $READY_PODS/$RUNNING_PODS ready${NC}"
    echo -e "${BLUE}Job pods: $COMPLETED_JOBS completed, $FAILED_JOBS failed${NC}"
    
    # Fail immediately if any Job failed
    if [[ "$FAILED_JOBS" -gt 0 ]]; then
        echo ""
        echo -e "${RED}✗ Job/CronJob pods failed:${NC}"
        kubectl get pods -n "$ARGOCD_NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.ownerReferences[]?.kind=="Job" and (.status.phase=="Failed" or .status.phase=="Error")) | "  - \(.metadata.name) (\(.status.phase))"'
        echo ""
        echo -e "${RED}✗ ArgoCD deployment failed due to job failures${NC}"
        exit 1
    fi
    
    if [[ "$READY_PODS" -eq "$RUNNING_PODS" ]]; then
        echo ""
        echo -e "${GREEN}✓ All ArgoCD running pods are ready!${NC}"
        if [[ "$COMPLETED_JOBS" -gt 0 ]]; then
            echo -e "${GREEN}✓ $COMPLETED_JOBS job(s) completed successfully${NC}"
        fi
        echo ""
        
        # Show final status
        echo -e "${BLUE}Pod Status:${NC}"
        kubectl get pods -n "$ARGOCD_NAMESPACE" -o wide
        echo ""
        exit 0
    fi
    
    # Show which pods are not ready (exclude completed Jobs)
    echo -e "${YELLOW}Not ready pods:${NC}"
    kubectl get pods -n "$ARGOCD_NAMESPACE" --no-headers 2>/dev/null | while read pod_name ready_count pod_status restarts age; do
        if [[ "$pod_status" != "Completed" && "$pod_status" != "Succeeded" ]]; then
            if [[ "$pod_status" != "Running" ]] || [[ "$ready_count" != *"/"* ]] || [[ "${ready_count%/*}" != "${ready_count#*/}" ]]; then
                echo "  - $pod_name: $pod_status (Ready: $ready_count)"
            fi
        fi
    done | head -10
    # Show "None" if no output
    if ! kubectl get pods -n "$ARGOCD_NAMESPACE" --no-headers 2>/dev/null | while read pod_name ready_count pod_status restarts age; do
        if [[ "$pod_status" != "Completed" && "$pod_status" != "Succeeded" ]]; then
            if [[ "$pod_status" != "Running" ]] || [[ "$ready_count" != *"/"* ]] || [[ "${ready_count%/*}" != "${ready_count#*/}" ]]; then
                exit 0
            fi
        fi
    done; then
        echo "  (all pods ready or completed)"
    fi
    
    echo ""
    sleep $CHECK_INTERVAL
    ELAPSED=$((ELAPSED + CHECK_INTERVAL))
done

# Timeout reached
echo ""
echo -e "${RED}✗ Timeout waiting for ArgoCD pods to be ready${NC}"
echo ""
echo -e "${YELLOW}Final pod status:${NC}"
kubectl get pods -n "$ARGOCD_NAMESPACE" 2>/dev/null || echo "Failed to get pods"

echo ""
echo -e "${YELLOW}Troubleshooting commands:${NC}"
echo "  kubectl get pods -n $ARGOCD_NAMESPACE"
echo "  kubectl describe pods -n $ARGOCD_NAMESPACE"
echo "  kubectl logs -n $ARGOCD_NAMESPACE -l app.kubernetes.io/name=argocd-server"
echo ""

exit 1