#!/bin/bash
set -euo pipefail

# ==============================================================================
# CHECKPOINT 5: Age Key Guardian Validation Script
# ==============================================================================
# Purpose: Validate Age Key Guardian automated recovery functionality
# ==============================================================================

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   CHECKPOINT 5: Age Key Guardian Validation                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

FAILED=0

# 1. Verify CronJob exists
echo "[1/7] Checking CronJob age-key-guardian..."
if kubectl get cronjob age-key-guardian -n argocd &>/dev/null; then
    SCHEDULE=$(kubectl get cronjob age-key-guardian -n argocd -o jsonpath='{.spec.schedule}')
    if [[ "$SCHEDULE" == "*/5 * * * *" ]]; then
        echo "✓ CronJob exists with correct schedule: $SCHEDULE"
    else
        echo "✗ CronJob schedule incorrect: $SCHEDULE (expected: */5 * * * *)"
        FAILED=1
    fi
else
    echo "✗ CronJob age-key-guardian not found"
    FAILED=1
fi

# 2. Verify ServiceAccount exists
echo "[2/7] Checking ServiceAccount..."
if kubectl get serviceaccount age-key-guardian -n argocd &>/dev/null; then
    echo "✓ ServiceAccount age-key-guardian exists"
else
    echo "✗ ServiceAccount age-key-guardian not found"
    FAILED=1
fi

# 3. Verify RBAC configured
echo "[3/7] Checking RBAC..."
if kubectl get role age-key-guardian -n argocd &>/dev/null; then
    echo "✓ Role age-key-guardian exists"
else
    echo "✗ Role age-key-guardian not found"
    FAILED=1
fi

if kubectl get rolebinding age-key-guardian -n argocd &>/dev/null; then
    echo "✓ RoleBinding age-key-guardian exists"
else
    echo "✗ RoleBinding age-key-guardian not found"
    FAILED=1
fi

# 4. Verify backup secrets exist
echo "[4/7] Checking backup secrets..."
if kubectl get secret age-backup-encrypted -n argocd &>/dev/null; then
    echo "✓ Secret age-backup-encrypted exists"
else
    echo "✗ Secret age-backup-encrypted not found"
    FAILED=1
fi

if kubectl get secret recovery-master-key -n argocd &>/dev/null; then
    echo "✓ Secret recovery-master-key exists"
else
    echo "✗ Secret recovery-master-key not found"
    FAILED=1
fi

# 5. Test automated recovery
echo "[5/7] Testing automated recovery..."
echo "  Backing up current sops-age secret..."
kubectl get secret sops-age -n argocd -o yaml > /tmp/sops-age-backup.yaml 2>/dev/null || true

echo "  Deleting sops-age secret..."
kubectl delete secret sops-age -n argocd &>/dev/null || true

echo "  Creating test job from CronJob..."
kubectl create job --from=cronjob/age-key-guardian test-recovery-validation -n argocd

echo "  Waiting for job to complete (max 120s)..."
kubectl wait --for=condition=complete job/test-recovery-validation -n argocd --timeout=120s &>/dev/null || true

# 6. Verify recovery succeeded
echo "[6/7] Verifying recovery..."
if kubectl get secret sops-age -n argocd &>/dev/null; then
    echo "✓ sops-age secret restored successfully"
    
    # Verify key format
    AGE_KEY=$(kubectl get secret sops-age -n argocd -o jsonpath='{.data.keys\.txt}' | base64 -d | head -c 20)
    if [[ "$AGE_KEY" == "AGE-SECRET-KEY-1"* ]]; then
        echo "✓ Restored key has correct format"
    else
        echo "✗ Restored key format incorrect"
        FAILED=1
    fi
else
    echo "✗ sops-age secret not restored"
    FAILED=1
fi

# 7. Check guardian logs
echo "[7/7] Checking guardian logs..."
LOGS=$(kubectl logs -n argocd job/test-recovery-validation 2>/dev/null || echo "")
if echo "$LOGS" | grep -q "Age Key Guardian starting"; then
    echo "✓ Guardian executed"
else
    echo "✗ Guardian did not execute"
    FAILED=1
fi

if echo "$LOGS" | grep -q "sops-age secret restored successfully"; then
    echo "✓ Guardian logs show successful recovery"
else
    echo "⚠ Guardian logs do not show successful recovery"
fi

# Cleanup
echo ""
echo "Cleaning up test resources..."
kubectl delete job test-recovery-validation -n argocd &>/dev/null || true

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Validation Summary                                         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

if [ $FAILED -eq 0 ]; then
    echo "✓ CHECKPOINT 5 PASSED: Age Key Guardian functional"
    exit 0
else
    echo "✗ CHECKPOINT 5 FAILED: Some validation checks failed"
    exit 1
fi
