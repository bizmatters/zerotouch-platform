#!/bin/bash
set -euo pipefail

# ==============================================================================
# Wait for Platform Readiness Script
# ==============================================================================
# Purpose: Wait for declared platform dependencies to become ready with detailed diagnostics
# Usage: ./wait-for-platform-readiness.sh [--timeout <seconds>]
# ==============================================================================

# Get script directory for sourcing helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[PLATFORM-WAIT]${NC} $*"; }
log_success() { echo -e "${GREEN}[PLATFORM-WAIT]${NC} $*"; }
log_error() { echo -e "${RED}[PLATFORM-WAIT]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[PLATFORM-WAIT]${NC} $*"; }

# Configuration
TIMEOUT=600  # 10 minutes default
POLL_INTERVAL=15

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Kubectl retry function
kubectl_retry() {
    local max_attempts=3
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if timeout 10 kubectl "$@" 2>/dev/null; then
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    return 1
}

# Get platform dependencies from service config
get_platform_dependencies() {
    local config_file="${SERVICE_ROOT:-$(pwd)}/ci/config.yaml"
    
    if [[ ! -f "$config_file" ]]; then
        echo ""
        return
    fi
    
    if command -v yq &> /dev/null; then
        yq eval '.dependencies.platform[]' "$config_file" 2>/dev/null | tr '\n' ' ' || echo ""
    else
        log_error "yq is required but not installed"
        exit 1
    fi
}

# Detailed ArgoCD application diagnostics during wait
diagnose_argocd_app_wait() {
    local app_name="$1"
    local namespace="${2:-argocd}"
    
    local APP_JSON=$(kubectl_retry get application "$app_name" -n "$namespace" -o json 2>/dev/null)
    if [ -z "$APP_JSON" ] || [ "$APP_JSON" = "null" ]; then
        echo -e "         ${RED}Application not found${NC}"
        return 1
    fi
    
    local sync_status=$(echo "$APP_JSON" | jq -r '.status.sync.status // "Unknown"')
    local health_status=$(echo "$APP_JSON" | jq -r '.status.health.status // "Unknown"')
    
    echo -e "         Status: $sync_status / $health_status"
    
    # Show operation state if active
    local op_phase=$(echo "$APP_JSON" | jq -r '.status.operationState.phase // "none"')
    if [ "$op_phase" != "none" ] && [ "$op_phase" != "Succeeded" ]; then
        local op_msg=$(echo "$APP_JSON" | jq -r '.status.operationState.message // empty')
        echo -e "         ${BLUE}Operation: $op_phase${NC}"
        [ -n "$op_msg" ] && echo -e "         ${BLUE}Message: ${op_msg:0:100}${NC}"
    fi
    
    # Show progressing resources
    if [[ "$health_status" == *"Progressing"* ]]; then
        local progressing=$(echo "$APP_JSON" | jq -r '.status.resources[]? | select(.health.status == "Progressing") | "           - \(.kind)/\(.name): \(.health.message // "waiting")"' 2>/dev/null | head -3)
        if [ -n "$progressing" ]; then
            echo -e "         ${BLUE}Progressing:${NC}"
            echo "$progressing"
        fi
        
        # Show waiting pods in app's namespace
        local app_namespace=$(echo "$APP_JSON" | jq -r '.spec.destination.namespace // empty')
        if [ -n "$app_namespace" ]; then
            local waiting_pods=$(kubectl_retry get pods -n "$app_namespace" -o json 2>/dev/null | \
                jq -r '.items[]? | select(.status.phase != "Running" or (.status.containerStatuses[]?.ready == false)) | 
                "           - \(.metadata.name): \(.status.phase) - \(.status.containerStatuses[]? | select(.ready == false) | .state | to_entries[0] | "\(.key): \(.value.reason // .value.message // "waiting")")"' 2>/dev/null | head -2)
            [ -n "$waiting_pods" ] && echo -e "         ${BLUE}Waiting pods:${NC}" && echo "$waiting_pods"
            
            # Show pending PVCs
            local pending_pvcs=$(kubectl_retry get pvc -n "$app_namespace" -o json 2>/dev/null | \
                jq -r '.items[]? | select(.status.phase != "Bound") | "           - \(.metadata.name): \(.status.phase)"' 2>/dev/null | head -2)
            [ -n "$pending_pvcs" ] && echo -e "         ${BLUE}Pending PVCs:${NC}" && echo "$pending_pvcs"
        fi
    fi
    
    # Show OutOfSync resources
    if [[ "$sync_status" == *"OutOfSync"* ]]; then
        local outofsync=$(echo "$APP_JSON" | jq -r '.status.resources[]? | select(.status == "OutOfSync") | "           - \(.kind)/\(.name): \(.message // "needs sync")"' 2>/dev/null | head -3)
        if [ -n "$outofsync" ]; then
            echo -e "         ${RED}OutOfSync:${NC}"
            echo "$outofsync"
        fi
    fi
    
    # Show Degraded resources
    if [[ "$health_status" == *"Degraded"* ]]; then
        local degraded=$(echo "$APP_JSON" | jq -r '.status.resources[]? | select(.health.status == "Degraded") | "           - \(.kind)/\(.name): \(.health.message // "degraded")"' 2>/dev/null | head -3)
        if [ -n "$degraded" ]; then
            echo -e "         ${RED}Degraded:${NC}"
            echo "$degraded"
        fi
    fi
}

# Check if a platform dependency is ready
check_platform_dependency_status() {
    local dep="$1"
    
    # Check if ArgoCD application exists
    if ! kubectl_retry get application "$dep" -n argocd >/dev/null 2>&1; then
        echo "NotFound"
        return
    fi
    
    local sync_status=$(kubectl_retry get application "$dep" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    local health_status=$(kubectl_retry get application "$dep" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    
    if [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" ]]; then
        echo "Ready"
    else
        echo "$sync_status/$health_status"
    fi
}

# Main execution
main() {
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   Waiting for Platform Dependencies to be Ready             ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    local platform_deps=$(get_platform_dependencies)
    
    if [[ -z "$platform_deps" ]]; then
        log_info "No platform dependencies specified - nothing to wait for"
        exit 0
    fi
    
    # Convert to array
    local deps_array=($platform_deps)
    local total_deps=${#deps_array[@]}
    
    log_info "Waiting for $total_deps platform dependencies: $platform_deps"
    log_info "Timeout: $((TIMEOUT/60)) minutes, Poll interval: ${POLL_INTERVAL}s"
    echo ""
    
    local elapsed=0
    
    while [ $elapsed -lt $TIMEOUT ]; do
        local ready_count=0
        local not_ready_deps=()
        
        echo -e "${YELLOW}⏳ Checking platform dependencies ($((elapsed/60))m $((elapsed%60))s elapsed)${NC}"
        
        # Check each dependency
        for dep in "${deps_array[@]}"; do
            if [[ -n "$dep" ]]; then
                local status=$(check_platform_dependency_status "$dep")
                
                if [[ "$status" == "Ready" ]]; then
                    echo -e "     ✅ $dep: Ready"
                    ready_count=$((ready_count + 1))
                else
                    echo -e "     ❌ $dep: $status"
                    not_ready_deps+=("$dep")
                    
                    # Show detailed diagnostics for not ready apps
                    diagnose_argocd_app_wait "$dep"
                fi
            fi
        done
        
        echo ""
        
        # Check if all dependencies are ready
        if [ $ready_count -eq $total_deps ]; then
            log_success "All $total_deps platform dependencies are ready!"
            echo ""
            exit 0
        fi
        
        # Show summary
        echo -e "   ${CYAN}Progress: $ready_count/$total_deps dependencies ready${NC}"
        if [ ${#not_ready_deps[@]} -gt 0 ]; then
            echo -e "   ${YELLOW}Still waiting for: ${not_ready_deps[*]}${NC}"
        fi
        echo ""
        
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
    done
    
    # Timeout - show final status
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║   TIMEOUT: Platform dependencies not ready after $((TIMEOUT/60)) minutes   ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    log_error "Timeout waiting for platform dependencies after $((TIMEOUT/60)) minutes"
    echo ""
    
    # Show final status for all dependencies
    echo -e "${YELLOW}Final Status:${NC}"
    for dep in "${deps_array[@]}"; do
        if [[ -n "$dep" ]]; then
            local status=$(check_platform_dependency_status "$dep")
            if [[ "$status" == "Ready" ]]; then
                echo -e "  ✅ $dep: Ready"
            else
                echo -e "  ❌ $dep: $status"
                
                # Show detailed diagnostics for failed dependencies
                if kubectl_retry get application "$dep" -n argocd >/dev/null 2>&1; then
                    echo -e "     ${CYAN}Detailed diagnostics:${NC}"
                    diagnose_argocd_app_wait "$dep"
                    echo ""
                fi
            fi
        fi
    done
    
    echo ""
    echo -e "${CYAN}Debug Commands:${NC}"
    echo "  kubectl get applications -n argocd"
    echo "  kubectl describe application <app-name> -n argocd"
    echo "  kubectl get events -A --sort-by='.lastTimestamp' | tail -20"
    echo ""
    
    exit 1
}

main "$@"