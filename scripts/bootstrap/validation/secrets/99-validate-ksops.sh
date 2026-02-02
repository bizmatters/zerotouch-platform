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
TEST_NAMESPACE="ksops-validation-test"
TEST_REPO_PATH="/tmp/ksops-validation-repo"

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

# Function to cleanup test resources
cleanup() {
    echo ""
    echo "Cleaning up test resources..."
    kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found=true &>/dev/null || true
    rm -rf "$TEST_REPO_PATH" || true
    echo "Cleanup complete"
}

# NO trap - cleanup called explicitly at end

# ============================================================================
# 1. Verify KSOPS init container completed and tools available
# ============================================================================
echo "1. Verifying KSOPS init container and tools..."

POD_NAME=$(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -z "$POD_NAME" ]]; then
    log_check "FAIL" "Could not find argocd-repo-server pod"
    echo ""
    echo "Diagnostic: ArgoCD repo-server pod not found"
else
    # Check init container completed
    INIT_STATUS=$(kubectl get pod -n argocd "$POD_NAME" -o jsonpath='{.status.initContainerStatuses[?(@.name=="install-ksops")].state.terminated.reason}' 2>/dev/null || echo "")
    if [[ "$INIT_STATUS" == "Completed" ]]; then
        # Check KSOPS binary exists
        if kubectl exec -n argocd "$POD_NAME" -c argocd-repo-server -- test -f /usr/local/bin/ksops 2>/dev/null; then
            log_check "PASS" "KSOPS init container completed and tools available"
        else
            log_check "FAIL" "Init container completed but KSOPS tools not found"
        fi
    else
        log_check "FAIL" "KSOPS init container not completed (status: $INIT_STATUS)"
    fi
fi
    exit 1
fi

# Check for CMP server running
if kubectl logs -n argocd "$POD_NAME" -c ksops --tail=100 2>/dev/null | tr -d '\n' | grep -q "serving on.*ksops.*\.sock\|argocd-cmp-server.*serving"; then
    log_check "PASS" "KSOPS plugin loaded - CMP server running"
else
    log_check "FAIL" "KSOPS plugin not loaded - CMP server not found in logs"
    echo ""
    echo "Diagnostic: Recent KSOPS sidecar logs:"
    kubectl logs -n argocd "$POD_NAME" -c ksops --tail=50 2>/dev/null || echo "Could not retrieve logs"
fi

# ============================================================================
# 2. Verify sops-age secret exists with correct format
# ============================================================================
echo ""
echo "2. Verifying sops-age secret exists with correct format..."

if ! kubectl get secret sops-age -n argocd &>/dev/null; then
    log_check "FAIL" "sops-age secret does not exist in argocd namespace"
    echo ""
    echo "Diagnostic: Run 08c-inject-age-key.sh to create the secret"
    exit 1
fi

# Verify secret has keys.txt field
AGE_KEY=$(kubectl get secret sops-age -n argocd -o jsonpath='{.data.keys\.txt}' 2>/dev/null | base64 -d || echo "")
if [[ -z "$AGE_KEY" ]]; then
    log_check "FAIL" "sops-age secret missing keys.txt field"
    exit 1
fi

# Verify key format (starts with AGE-SECRET-KEY-1)
if echo "$AGE_KEY" | grep -q "^AGE-SECRET-KEY-1"; then
    log_check "PASS" "sops-age secret exists with correct format"
else
    log_check "FAIL" "Age private key has incorrect format (should start with AGE-SECRET-KEY-1)"
    echo ""
    echo "Diagnostic: Key format: $(echo "$AGE_KEY" | head -c 20)..."
fi

# ============================================================================
# 3. Detect KSOPS binary location for later use
# ============================================================================
echo ""
echo "3. Detecting KSOPS binary location..."

# Determine ksops binary path
if command -v ksops &>/dev/null; then
    KSOPS_BIN="ksops"
elif command -v kustomize-sops &>/dev/null; then
    KSOPS_BIN="kustomize-sops"
elif command -v go &>/dev/null; then
    KSOPS_BIN="$(go env GOPATH)/bin/kustomize-sops"
    if [[ ! -f "$KSOPS_BIN" ]]; then
        log_check "FAIL" "ksops binary not found at $KSOPS_BIN"
        echo ""
        echo "Diagnostic: Install ksops with: go install github.com/viaduct-ai/kustomize-sops@latest"
        exit 1
    fi
else
    log_check "FAIL" "ksops binary not available (Go not found)"
    echo ""
    echo "Diagnostic: Install Go and ksops"
    exit 1
fi

log_check "PASS" "KSOPS binary found: $KSOPS_BIN"

# ============================================================================
# 4. Create test encrypted secret
# ============================================================================
echo ""
echo "4. Creating test encrypted secret..."

# Create test namespace
kubectl create namespace "$TEST_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - &>/dev/null

# Generate Age keypair for testing using platform script
echo "Generating test Age keypair..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGE_KEYGEN_SCRIPT="$SCRIPT_DIR/../../../bootstrap/infra/secrets/ksops/08b-generate-age-keys.sh"

if [[ ! -f "$AGE_KEYGEN_SCRIPT" ]]; then
    log_check "FAIL" "generate-age-keys.sh script not found"
    echo ""
    echo "Diagnostic: Expected at $AGE_KEYGEN_SCRIPT"
    exit 1
fi

# Run the script and capture output
KEYGEN_OUTPUT=$("$AGE_KEYGEN_SCRIPT" 2>&1)

# Extract keys from output
TEST_AGE_PUBLIC_KEY=$(echo "$KEYGEN_OUTPUT" | grep "Public Key:" -A 1 | tail -1 | xargs)
TEST_AGE_PRIVATE_KEY=$(echo "$KEYGEN_OUTPUT" | grep "Private Key:" -A 1 | tail -1 | xargs)

if [[ -z "$TEST_AGE_PUBLIC_KEY" ]] || [[ -z "$TEST_AGE_PRIVATE_KEY" ]]; then
    log_check "FAIL" "Failed to generate Age keypair"
    echo ""
    echo "Diagnostic: Install age with: brew install age (macOS) or apt-get install age (Linux)"
    exit 1
fi

echo "Test Age public key: $TEST_AGE_PUBLIC_KEY"

# Add test private key to sops-age secret temporarily
ORIGINAL_KEYS=$(kubectl get secret sops-age -n argocd -o jsonpath='{.data.keys\.txt}' | base64 -d)
COMBINED_KEYS=$(printf "%s\n%s" "$ORIGINAL_KEYS" "$TEST_AGE_PRIVATE_KEY")
kubectl create secret generic sops-age -n argocd \
    --from-literal=keys.txt="$COMBINED_KEYS" \
    --dry-run=client -o yaml | kubectl apply -f - &>/dev/null

echo "Added test Age key to sops-age secret"

# Wait for repo-server to reload
sleep 5

# Create test repository structure
mkdir -p "$TEST_REPO_PATH"
cd "$TEST_REPO_PATH"

# Create .sops.yaml
cat > .sops.yaml << 'SOPSEOF'
creation_rules:
  - path_regex: .*\.yaml
    age: AGE_PUBLIC_KEY_PLACEHOLDER
    encrypted_regex: '^(data|stringData)$'
SOPSEOF

# Replace placeholder with actual key
sed -i.bak "s/AGE_PUBLIC_KEY_PLACEHOLDER/$TEST_AGE_PUBLIC_KEY/" .sops.yaml
rm -f .sops.yaml.bak

# Create test secret
cat > test-secret.yaml << 'SECRETEOF'
apiVersion: v1
kind: Secret
metadata:
  name: test-ksops-secret
  namespace: NAMESPACE_PLACEHOLDER
type: Opaque
stringData:
  username: testuser
  password: testpassword123
SECRETEOF

# Replace placeholder with actual namespace
sed -i.bak "s/NAMESPACE_PLACEHOLDER/$TEST_NAMESPACE/" test-secret.yaml
rm -f test-secret.yaml.bak

# Encrypt with SOPS
if ! command -v sops &>/dev/null; then
    log_check "FAIL" "sops not available - cannot encrypt test secret"
    echo ""
    echo "Diagnostic: Install sops with: brew install sops (macOS) or download from GitHub"
    exit 1
fi

sops -e -i test-secret.yaml 2>/dev/null || {
    log_check "FAIL" "Failed to encrypt test secret with SOPS"
    exit 1
}

echo "Created and encrypted test secret"

# Create kustomization.yaml with KSOPS generator
cat > kustomization.yaml << 'KUSTOMEOF'
generators:
  - ./secret-generator.yaml
KUSTOMEOF

# Create KSOPS generator file with absolute path to binary
cat > secret-generator.yaml << GENEOF
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: ksops-validation-generator
  annotations:
    config.kubernetes.io/function: |
        exec:
          path: $KSOPS_BIN
files:
  - ./test-secret.yaml
GENEOF

# Initialize git repo (ArgoCD requires git)
git init &>/dev/null
git config user.email "test@example.com"
git config user.name "Test User"
git add .
git commit -m "Initial commit" &>/dev/null

log_check "PASS" "Test encrypted secret created successfully"

# ============================================================================
# 5. Simulate local KSOPS decryption to verify key validity
# ============================================================================
echo ""
echo "5. Simulating local KSOPS decryption..."

# Check if kustomize is available
if ! command -v kustomize &>/dev/null; then
    log_check "FAIL" "kustomize binary not available for local simulation"
    echo ""
    echo "Diagnostic: Install kustomize with: brew install kustomize (macOS)"
    exit 1
fi

# Set SOPS_AGE_KEY_FILE for decryption
TEMP_KEY_FILE=$(mktemp)
echo "$COMBINED_KEYS" > "$TEMP_KEY_FILE"
export SOPS_AGE_KEY_FILE="$TEMP_KEY_FILE"

# Run ksops to decrypt the test secret locally
echo "Running local ksops decryption..."
cd "$TEST_REPO_PATH"
echo "DEBUG: Running kustomize build in $(pwd)"
timeout 30 kustomize build --enable-alpha-plugins --enable-exec . > /tmp/ksops-output.txt 2>&1
KSOPS_EXIT_CODE=$?
KSOPS_OUTPUT=$(cat /tmp/ksops-output.txt)
rm -f /tmp/ksops-output.txt
echo "DEBUG: Exit code: $KSOPS_EXIT_CODE"
cd - > /dev/null

if [[ $KSOPS_EXIT_CODE -eq 124 ]]; then
    log_check "FAIL" "Kustomize build timed out after 30 seconds"
    echo ""
    echo "Diagnostic: Check KSOPS configuration and Age key"
    exit 1
fi

# Clean up temp key file
rm -f "$TEMP_KEY_FILE"
unset SOPS_AGE_KEY_FILE

if [[ $KSOPS_EXIT_CODE -ne 0 ]]; then
    log_check "FAIL" "Local KSOPS decryption failed (exit code: $KSOPS_EXIT_CODE)"
    echo ""
    echo "Diagnostic: KSOPS output:"
    echo "$KSOPS_OUTPUT"
    echo ""
    echo "Diagnostic: Check if ksops binary is in PATH and Age key is valid"
    exit 1
fi

# Verify decrypted output contains expected plaintext values
if echo "$KSOPS_OUTPUT" | grep -q "username: testuser" && echo "$KSOPS_OUTPUT" | grep -q "password: testpassword123"; then
    log_check "PASS" "Local KSOPS decryption successful - Age key valid"
else
    log_check "FAIL" "Decrypted output missing expected plaintext values"
    echo ""
    echo "Diagnostic: KSOPS output:"
    echo "$KSOPS_OUTPUT"
fi

# ============================================================================
# 6. Restore original sops-age secret
# ============================================================================
echo ""
echo "6. Restoring original sops-age secret..."

kubectl create secret generic sops-age -n argocd \
    --from-literal=keys.txt="$ORIGINAL_KEYS" \
    --dry-run=client -o yaml | kubectl apply -f - &>/dev/null

log_check "PASS" "Original sops-age secret restored"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=== Validation Summary ==="
if [[ $VALIDATION_FAILED -eq 0 ]]; then
    echo "✅ CHECKPOINT 6 PASSED: All KSOPS validations successful"
    echo ""
    echo "Verified functionality:"
    echo "  ✓ KSOPS plugin loaded and running"
    echo "  ✓ Age key secret properly configured"
    echo "  ✓ SOPS encryption working"
    echo "  ✓ Local KSOPS decryption successful"
    echo "  ✓ Infrastructure ready for ArgoCD sync"
    cleanup
    exit 0
else
    echo "❌ CHECKPOINT 6 FAILED: Some validations failed"
    echo ""
    echo "Diagnostic Information:"
    echo "----------------------"
    
    if [[ -n "$POD_NAME" ]]; then
        echo ""
        echo "KSOPS Sidecar Status:"
        kubectl get pod -n argocd "$POD_NAME" -o jsonpath='{.status.containerStatuses[?(@.name=="ksops")]}' 2>/dev/null | jq '.' || echo "Could not retrieve status"
        
        echo ""
        echo "Recent KSOPS Sidecar Logs:"
        kubectl logs -n argocd "$POD_NAME" -c ksops --tail=50 2>/dev/null || echo "Could not retrieve logs"
    fi
    
    exit 1
fi
