#!/bin/bash
set -euo pipefail

# ==============================================================================
# Cleanup Failed Pods Script
# ==============================================================================
# Purpose: Investigate and capture logs from failed pods for debugging
# Usage: ./cleanup-failed-pods.sh <service-name> <namespace> [test-name]
# ==============================================================================

SERVICE_NAME="${1:?Service name required}"
NAMESPACE="${2:?Namespace required}"
TEST_NAME="${3:-}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[CLEANUP]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[CLEANUP]${NC} $*"; }

# Function to capture logs from failed pods
capture_failed_pod_logs() {
    log_info "Investigating failed pods for service: ${SERVICE_NAME}"
    
    # Find the pod that is failing (using modern label selector)
    FAILED_POD=$(kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=${SERVICE_NAME}" -o name 2>/dev/null | head -n 1 || true)
    
    if [[ -n "$FAILED_POD" ]]; then
        echo "=== RECENT LOGS FOR $FAILED_POD ==="
        # --previous gets the logs from the container that just crashed
        kubectl logs "$FAILED_POD" -n "${NAMESPACE}" --previous --tail=50 2>/dev/null || \
        kubectl logs "$FAILED_POD" -n "${NAMESPACE}" --tail=50 2>/dev/null || true
        echo "================================="
        
        # Also show pod description for container creation issues
        echo "=== POD DESCRIPTION ==="
        kubectl describe "$FAILED_POD" -n "${NAMESPACE}" 2>/dev/null || true
        echo "================================="
    fi
    
    # Also check for any CrashLoopBackOff pods with legacy label selector
    CRASH_PODS=$(kubectl get pods -n "${NAMESPACE}" -l "app=${SERVICE_NAME}" -o name 2>/dev/null || true)
    
    if [[ -n "$CRASH_PODS" ]]; then
        echo "$CRASH_PODS" | while read -r pod; do
            if [[ -n "$pod" ]]; then
                echo "=== CRASH LOG FOR $pod ==="
                kubectl logs "$pod" -n "${NAMESPACE}" --previous --tail=50 2>/dev/null || \
                kubectl logs "$pod" -n "${NAMESPACE}" --tail=50 2>/dev/null || true
                echo "================================="
            fi
        done
    fi
    
    # Check for test-related failed pods if test name provided
    if [[ -n "$TEST_NAME" ]]; then
        log_info "Checking for failed test pods..."
        if kubectl get pods -n "${NAMESPACE}" -l test-suite="${TEST_NAME}" --field-selector=status.phase=Failed -o name 2>/dev/null | grep -q .; then
            echo "=== Failed Test Pod Logs ==="
            kubectl get pods -n "${NAMESPACE}" -l test-suite="${TEST_NAME}" --field-selector=status.phase=Failed -o name | while read pod; do
                echo "--- Logs for $pod ---"
                kubectl logs "$pod" -n "${NAMESPACE}" 2>/dev/null || true
            done
        fi
    fi
}

# Function to cleanup test resources
cleanup_test_resources() {
    if [[ -n "$TEST_NAME" ]]; then
        log_info "Cleaning up test jobs..."
        kubectl delete jobs -n "${NAMESPACE}" -l test-suite="${TEST_NAME}" --ignore-not-found=true || true
    fi
}

# Function to cleanup cluster
cleanup_cluster() {
    local cleanup_cluster="${CLEANUP_CLUSTER:-true}"
    
    if [[ "${cleanup_cluster}" == "true" ]]; then
        log_info "Cleaning up Kind cluster..."
        kind delete cluster --name zerotouch-preview || true
    else
        log_info "Keeping cluster for debugging (set CLEANUP_CLUSTER=true to auto-cleanup)"
        log_info "Manual cleanup: kind delete cluster --name zerotouch-preview"
    fi
}

# Main cleanup function
main() {
    capture_failed_pod_logs
    cleanup_test_resources
    cleanup_cluster
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi