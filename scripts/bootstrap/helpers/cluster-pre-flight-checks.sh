#!/bin/bash
set -euo pipefail

# ==============================================================================
# Cluster Pre-Flight Checks Script
# ==============================================================================
# Purpose: Validate cluster connectivity and prevent operations on wrong cluster
# Usage: source ./cluster-pre-flight-checks.sh <expected-cluster-name> <namespace>
# Example: source ./cluster-pre-flight-checks.sh dev platform-identity
# ==============================================================================

EXPECTED_CLUSTER="${1:-}"
NAMESPACE="${2:-}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[PRE-FLIGHT]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[PRE-FLIGHT]${NC} $*" >&2; }
log_error() { echo -e "${RED}[PRE-FLIGHT]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[PRE-FLIGHT]${NC} $*" >&2; }

pre_flight_checks() {
    log_info "Running cluster pre-flight checks..."
    
    # Check 1: kubectl installed
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed or not in PATH"
        return 1
    fi
    log_success "✓ kubectl found"
    
    # Check 2: kubeconfig exists
    if [[ ! -f "${KUBECONFIG:-$HOME/.kube/config}" ]]; then
        log_error "kubeconfig not found at ${KUBECONFIG:-$HOME/.kube/config}"
        return 1
    fi
    log_success "✓ kubeconfig found"
    
    # Check 3: Current context set
    CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "")
    if [[ -z "$CURRENT_CONTEXT" ]]; then
        log_error "No kubectl context is currently set"
        log_error "Run: kubectl config use-context <context-name>"
        return 1
    fi
    log_success "✓ Current context: $CURRENT_CONTEXT"
    
    # Check 4: Cluster connectivity
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to cluster"
        log_error "Current context: $CURRENT_CONTEXT"
        return 1
    fi
    log_success "✓ Cluster is reachable"
    
    # Check 5: Get actual cluster name/identifier
    ACTUAL_CLUSTER=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null || echo "")
    if [[ -z "$ACTUAL_CLUSTER" ]]; then
        log_error "Cannot determine cluster name from kubeconfig"
        return 1
    fi
    log_info "Connected cluster: $ACTUAL_CLUSTER"
    
    # Check 6: Verify expected cluster matches (if provided)
    if [[ -n "$EXPECTED_CLUSTER" ]]; then
        # Flexible matching: check if expected cluster name is contained in actual cluster name
        # This handles cases like "dev" matching "talos-dev-cluster" or "admin@dev"
        if [[ "$ACTUAL_CLUSTER" != *"$EXPECTED_CLUSTER"* ]]; then
            log_error "Cluster mismatch detected!"
            log_error "  Expected: $EXPECTED_CLUSTER"
            log_error "  Actual:   $ACTUAL_CLUSTER"
            log_error ""
            log_error "You are about to run operations on the WRONG cluster!"
            log_error "Please switch to the correct context:"
            log_error "  kubectl config get-contexts"
            log_error "  kubectl config use-context <correct-context>"
            return 1
        fi
        log_success "✓ Cluster name verified: $EXPECTED_CLUSTER"
    fi
    
    # Check 7: Namespace exists (if provided)
    if [[ -n "$NAMESPACE" ]]; then
        if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
            log_error "Namespace does not exist: $NAMESPACE"
            log_error "Available namespaces:"
            kubectl get namespaces -o name | sed 's|namespace/|  - |' >&2
            return 1
        fi
        log_success "✓ Namespace exists: $NAMESPACE"
    fi
    
    # Check 8: User permissions
    if [[ -n "$NAMESPACE" ]]; then
        if ! kubectl auth can-i get pods -n "$NAMESPACE" &>/dev/null; then
            log_warn "⚠ Limited permissions in namespace: $NAMESPACE"
            log_warn "Some operations may fail"
        else
            log_success "✓ User has access to namespace: $NAMESPACE"
        fi
    fi
    
    log_success "✅ All pre-flight checks passed"
    echo ""
    return 0
}

# Run checks if arguments provided
if [[ -n "$EXPECTED_CLUSTER" ]]; then
    if ! pre_flight_checks; then
        exit 1
    fi
fi
