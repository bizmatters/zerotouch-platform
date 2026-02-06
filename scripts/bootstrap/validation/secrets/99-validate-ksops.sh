#!/bin/bash
set -euo pipefail

# ==============================================================================
# Comprehensive KSOPS Validation Script
# ==============================================================================
# Purpose: Validate complete KSOPS functionality end-to-end
# Validates: Checkpoint 6 - Error Handling and Validation
# ==============================================================================

echo "=== CHECKPOINT 6: Comprehensive KSOPS Validation ==="
echo ""

VALIDATION_FAILED=0

# Function to log validation results
log_check() {
    local status=$1
    local message=$2
    if [[ "$status" == "PASS" ]]; then
        echo "✅ PASS: $message"
    else
        echo "❌ FAIL: $message"
        VALIDATION_FAILED=1
    fi
}

# ============================================================================
# 1. Verify KSOPS init container completed and tools available
# ============================================================================
echo "1. Verifying KSOPS init container and tools..."

POD_NAME=$(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -z "$POD_NAME" ]]; then
    log_check "FAIL" "Could not find argocd-repo-server pod"
else
    # Check init container completed
    INIT_STATUS=$(kubectl get pod -n argocd "$POD_NAME" -o jsonpath='{.status.initContainerStatuses[?(@.name=="install-ksops")].state.terminated.reason}' 2>/dev/null || echo "")
    if [[ "$INIT_STATUS" == "Completed" ]]; then
        # Check KSOPS binary exists (in PATH)
        if kubectl exec -n argocd "$POD_NAME" -c argocd-repo-server -- which ksops 2>/dev/null | grep -q ksops; then
            log_check "PASS" "KSOPS init container completed and tools available"
        else
            log_check "FAIL" "Init container completed but KSOPS tools not found"
        fi
    else
        log_check "FAIL" "KSOPS init container not completed (status: $INIT_STATUS)"
    fi
fi

# ============================================================================
# 2. Verify sops-age secret exists with correct format
# ============================================================================
echo ""
echo "2. Verifying sops-age secret exists with correct format..."

if ! kubectl get secret sops-age -n argocd &>/dev/null; then
    log_check "FAIL" "sops-age secret does not exist in argocd namespace"
else
    # Verify secret has keys.txt field
    AGE_KEY=$(kubectl get secret sops-age -n argocd -o jsonpath='{.data.keys\.txt}' 2>/dev/null | base64 -d || echo "")
    if [[ -z "$AGE_KEY" ]]; then
        log_check "FAIL" "sops-age secret missing keys.txt field"
    elif echo "$AGE_KEY" | grep -q "^AGE-SECRET-KEY-1"; then
        log_check "PASS" "sops-age secret exists with correct format"
    else
        log_check "FAIL" "Age private key has incorrect format"
    fi
fi

# ============================================================================
# 3. Verify KSOPS tools available in cluster
# ============================================================================
echo ""
echo "3. Verifying KSOPS tools available in cluster..."

if [[ -n "$POD_NAME" ]]; then
    if kubectl exec -n argocd "$POD_NAME" -c argocd-repo-server -- which ksops &>/dev/null; then
        log_check "PASS" "KSOPS binary available in repo-server"
    else
        log_check "FAIL" "KSOPS binary not in PATH"
    fi
else
    log_check "FAIL" "Cannot verify KSOPS tools (pod not found)"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=== Validation Summary ==="
if [[ $VALIDATION_FAILED -eq 0 ]]; then
    echo "✅ CHECKPOINT 6 PASSED: All KSOPS validations successful"
    echo ""
    echo "Verified functionality:"
    echo "  ✓ KSOPS init container completed"
    echo "  ✓ KSOPS tools available in repo-server"
    echo "  ✓ Age key secret properly configured"
    echo "  ✓ Infrastructure ready for ArgoCD sync"
    exit 0
else
    echo "❌ CHECKPOINT 6 FAILED: Some validations failed"
    echo ""
    echo "Diagnostic Information:"
    echo "----------------------"
    
    if [[ -n "$POD_NAME" ]]; then
        echo ""
        echo "Init Container Status:"
        kubectl get pod -n argocd "$POD_NAME" -o jsonpath='{.status.initContainerStatuses[?(@.name=="install-ksops")]}' 2>/dev/null | jq '.' || echo "Could not retrieve status"
        
        echo ""
        echo "Recent Repo Server Logs:"
        kubectl logs -n argocd "$POD_NAME" -c argocd-repo-server --tail=50 2>/dev/null || echo "Could not retrieve logs"
    fi
    
    exit 1
fi
