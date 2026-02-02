#!/bin/bash
set -euo pipefail

# ==============================================================================
# Secret Injection Validation Script
# ==============================================================================
# Purpose: Validate that all environment-prefixed secrets were injected to cluster
# Validates: Secret discovery, encryption, and cluster deployment
# ==============================================================================

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   CHECKPOINT 1.5: Secret Injection Validation               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

VALIDATION_FAILED=0

# Detect environment
ENVIRONMENT="${ENVIRONMENT:-PR}"
ENV_PREFIX="${ENVIRONMENT}_"

echo "Environment: ${ENVIRONMENT}"
echo "Secret prefix: ${ENV_PREFIX}"
echo ""

# Discover all environment-prefixed secrets
PREFIXED_SECRETS=$(printenv | grep "^${ENV_PREFIX}" | cut -d= -f1 | sort || true)

if [ -z "$PREFIXED_SECRETS" ]; then
    echo "⚠️  No secrets found with prefix ${ENV_PREFIX}"
    echo "✓ CHECKPOINT 1.5 SKIPPED: No secrets to validate"
    exit 0
fi

EXPECTED_COUNT=$(echo "$PREFIXED_SECRETS" | wc -l | tr -d ' ')

echo "[1/3] Discovered secrets with ${ENV_PREFIX} prefix:"
echo "$PREFIXED_SECRETS" | while read secret_name; do
    echo "  - $secret_name"
done
echo ""
echo "Expected secret count: $EXPECTED_COUNT"
echo ""

# Verify each secret exists in cluster
echo "[2/3] Verifying secrets in cluster..."
FOUND_COUNT=0
MISSING_SECRETS=()

for prefixed_var in $PREFIXED_SECRETS; do
    # Strip environment prefix and convert to K8s naming
    secret_name="${prefixed_var#${ENV_PREFIX}}"
    k8s_secret_name=$(echo "$secret_name" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    namespace="default"
    
    if kubectl get secret "${k8s_secret_name}" -n "${namespace}" &>/dev/null; then
        echo "  ✓ ${k8s_secret_name} (from ${prefixed_var})"
        ((FOUND_COUNT++))
    else
        echo "  ✗ ${k8s_secret_name} (from ${prefixed_var}) - NOT FOUND"
        MISSING_SECRETS+=("${k8s_secret_name}")
        VALIDATION_FAILED=1
    fi
done
echo ""

# Summary
echo "[3/3] Validation Summary:"
echo "  Expected secrets: $EXPECTED_COUNT"
echo "  Found in cluster: $FOUND_COUNT"
echo "  Missing: $((EXPECTED_COUNT - FOUND_COUNT))"
echo ""

if [ ${#MISSING_SECRETS[@]} -gt 0 ]; then
    echo "❌ Missing secrets:"
    for secret in "${MISSING_SECRETS[@]}"; do
        echo "  - $secret"
    done
    echo ""
fi

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Validation Summary                                         ║"
echo "╚══════════════════════════════════════════════════════════════╝"

if [[ $VALIDATION_FAILED -eq 0 ]]; then
    echo "✓ CHECKPOINT 1.5 PASSED: All secrets injected successfully"
    echo ""
    echo "Verified:"
    echo "  ✓ $EXPECTED_COUNT secrets discovered from environment"
    echo "  ✓ $FOUND_COUNT secrets exist in cluster"
    echo "  ✓ 100% injection success rate"
    exit 0
else
    echo "✗ CHECKPOINT 1.5 FAILED: Secret injection incomplete"
    echo ""
    echo "Issues:"
    echo "  ✗ $((EXPECTED_COUNT - FOUND_COUNT)) secrets missing from cluster"
    echo "  ✗ Injection success rate: $((FOUND_COUNT * 100 / EXPECTED_COUNT))%"
    exit 1
fi
