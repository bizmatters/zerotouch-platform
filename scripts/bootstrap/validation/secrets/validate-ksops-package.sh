#!/bin/bash
set -euo pipefail

# ==============================================================================
# KSOPS Package Deployment Validation Script
# ==============================================================================
# Purpose: Validate KSOPS package deployment to ArgoCD
# Validates: Checkpoint 1 - KSOPS Package Deployment
# ==============================================================================

echo "=== CHECKPOINT 1: KSOPS Package Deployment Validation ==="
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

# 1. Verify KSOPS init container completed and tools available
echo "1. Checking KSOPS init container and tools in argocd-repo-server pod..."
POD_NAME=$(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$POD_NAME" ]]; then
    # Check init container completed
    INIT_STATUS=$(kubectl get pod -n argocd "$POD_NAME" -o jsonpath='{.status.initContainerStatuses[?(@.name=="install-ksops")].state.terminated.reason}' 2>/dev/null || echo "")
    if [[ "$INIT_STATUS" == "Completed" ]]; then
        # Check KSOPS binary exists
        if kubectl exec -n argocd "$POD_NAME" -c argocd-repo-server -- test -f /usr/local/bin/ksops 2>/dev/null; then
            log_check "PASS" "KSOPS init container completed and tools installed"
        else
            log_check "FAIL" "Init container completed but KSOPS binary not found"
        fi
    else
        log_check "FAIL" "KSOPS init container not completed (status: $INIT_STATUS)"
    fi
else
    log_check "FAIL" "argocd-repo-server pod not found"
fi

# 2. Verify kustomize can use KSOPS plugin
echo "2. Checking KSOPS plugin availability..."
if [[ -n "$POD_NAME" ]]; then
    if kubectl exec -n argocd "$POD_NAME" -c argocd-repo-server -- test -f /usr/local/bin/kustomize 2>/dev/null; then
        log_check "PASS" "Kustomize binary available for KSOPS plugin"
    else
        log_check "FAIL" "Kustomize binary not found"
    fi
else
    log_check "FAIL" "Could not find argocd-repo-server pod"
fi

# 3. Verify environment variables set correctly
echo "3. Checking environment variables..."
if [[ -n "$POD_NAME" ]]; then
    SOPS_KEY=$(kubectl exec -n argocd "$POD_NAME" -c argocd-repo-server -- env 2>/dev/null | grep SOPS_AGE_KEY_FILE || echo "")
    XDG_CONFIG=$(kubectl exec -n argocd "$POD_NAME" -c argocd-repo-server -- env 2>/dev/null | grep XDG_CONFIG_HOME || echo "")
    if [[ -n "$SOPS_KEY" ]] && [[ -n "$XDG_CONFIG" ]]; then
        log_check "PASS" "Environment variables configured correctly"
    else
        log_check "FAIL" "Environment variables not set (SOPS_AGE_KEY_FILE or XDG_CONFIG_HOME missing)"
    fi
else
    log_check "FAIL" "Could not verify environment variables (pod not found)"
fi

# 4. Verify Age key mount exists
echo "4. Checking Age key mount..."
if [[ -n "$POD_NAME" ]]; then
    if kubectl exec -n argocd "$POD_NAME" -c argocd-repo-server -- test -f /.config/sops/age/keys.txt 2>/dev/null; then
        log_check "PASS" "Age key file mounted correctly"
    else
        log_check "FAIL" "Age key file not found at expected path"
    fi
else
    log_check "FAIL" "Could not verify Age key mount (pod not found)"
fi

# 5. Verify KSOPS package deployed (init container pattern)
echo "5. Checking package deployment..."
KSOPS_INIT=$(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].spec.initContainers[?(@.name=="install-ksops")].name}' 2>/dev/null || echo "")

if [[ "$KSOPS_INIT" == "install-ksops" ]]; then
    log_check "PASS" "KSOPS package deployed with init container pattern"
else
    log_check "FAIL" "KSOPS init container not found in deployment"
fi

echo ""
echo "=== Validation Summary ==="
if [[ $VALIDATION_FAILED -eq 0 ]]; then
    echo "✅ CHECKPOINT 1 PASSED: KSOPS package deployed successfully"
    exit 0
else
    echo "❌ CHECKPOINT 1 FAILED: Some validation checks failed"
    echo ""
    echo "Diagnostic Information:"
    echo "----------------------"
    if [[ -n "$POD_NAME" ]]; then
        echo "Pod Status:"
        kubectl get pod -n argocd "$POD_NAME" -o wide
        echo ""
        echo "Init Container Status:"
        kubectl get pod -n argocd "$POD_NAME" -o jsonpath='{.status.initContainerStatuses[?(@.name=="install-ksops")]}' | jq '.' 2>/dev/null || echo "Could not retrieve init container status"
    fi
    exit 1
fi
