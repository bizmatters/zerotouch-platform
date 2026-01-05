#!/bin/bash
set -euo pipefail

# 07-verify-secrets.sh - Live cluster secret injection validation for AgentSandboxService
# Validates that secret management follows exact EventDrivenService pattern

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default values
TENANT_NAME="deepagents-runtime"
NAMESPACE="intelligence-deepagents"
VERBOSE=false
CLEANUP=false
TEST_CLAIM_NAME="test-secrets-$(date +%s)"

# Logging functions
log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --tenant)
      TENANT_NAME="$2"
      shift 2
      ;;
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --cleanup)
      CLEANUP=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--tenant <name>] [--namespace <name>] [--verbose] [--cleanup]"
      echo "Validates AgentSandboxService secret injection parity with EventDrivenService"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

log_info "Starting AgentSandboxService secret injection validation"
log_info "Tenant: $TENANT_NAME, Namespace: $NAMESPACE"

# Cleanup function
cleanup_test_resources() {
  if [[ "$CLEANUP" == "true" ]]; then
    log_info "Cleaning up test resources..."
    kubectl delete agentsandboxservice "$TEST_CLAIM_NAME" -n "$NAMESPACE" --ignore-not-found=true
    kubectl delete secret test-secret-1 test-secret-2 test-secret-3 test-secret-4 test-secret-5 -n "$NAMESPACE" --ignore-not-found=true
    log_info "Cleanup completed"
  fi
}

# Set up cleanup trap
trap cleanup_test_resources EXIT

# Validation functions
validate_prerequisites() {
  log_info "Validating prerequisites..."
  
  # Check namespace exists
  if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    log_error "Namespace $NAMESPACE does not exist"
    return 1
  fi
  
  # Check AgentSandboxService XRD exists
  if ! kubectl get xrd xagentsandboxservices.platform.bizmatters.io >/dev/null 2>&1; then
    log_error "AgentSandboxService XRD not found"
    return 1
  fi
  
  # Check aws-access-token secret exists
  if ! kubectl get secret aws-access-token -n "$NAMESPACE" >/dev/null 2>&1; then
    log_error "aws-access-token secret not found in namespace $NAMESPACE"
    return 1
  fi
  
  log_info "Prerequisites validated successfully"
}

create_test_secrets() {
  log_info "Creating test secrets..."
  
  # Create test secrets with known values
  for i in {1..5}; do
    kubectl create secret generic "test-secret-$i" \
      --from-literal="TEST_VAR_$i=test-value-$i" \
      --from-literal="COMMON_VAR=from-secret-$i" \
      -n "$NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f -
  done
  
  log_info "Test secrets created successfully"
}

create_test_claim() {
  log_info "Creating AgentSandboxService test claim with all secrets..."
  
  # Create the claim and capture any errors
  if ! cat <<EOF | kubectl apply -f -
apiVersion: platform.bizmatters.io/v1alpha1
kind: AgentSandboxService
metadata:
  name: $TEST_CLAIM_NAME
  namespace: $NAMESPACE
spec:
  image: busybox:latest
  command: ["sleep", "3600"]
  size: micro
  secret1Name: test-secret-1
  secret2Name: test-secret-2
  secret3Name: test-secret-3
  secret4Name: test-secret-4
  secret5Name: test-secret-5
  nats:
    url: nats://nats-headless.nats.svc.cluster.local:4222
    stream: TEST_STREAM
    consumer: test-consumer
  storageGB: 5
EOF
  then
    log_error "Failed to create AgentSandboxService claim"
    return 1
  fi
  
  log_info "Test claim created successfully"
}

wait_for_resources() {
  log_info "Waiting for resources to be ready..."
  
  # First verify the claim actually exists
  if ! kubectl get agentsandboxservice "$TEST_CLAIM_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    log_error "AgentSandboxService claim '$TEST_CLAIM_NAME' does not exist"
    return 1
  fi
  
  # Wait for claim to be ready
  local timeout=180
  local elapsed=0
  
  while [[ $elapsed -lt $timeout ]]; do
    local ready_status
    ready_status=$(kubectl get agentsandboxservice "$TEST_CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    
    if [[ "$ready_status" == "True" ]]; then
      log_info "AgentSandboxService claim is ready"
      break
    fi
    
    # Check for error conditions
    local synced_status
    synced_status=$(kubectl get agentsandboxservice "$TEST_CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Synced")].status}' 2>/dev/null || echo "")
    
    if [[ "$synced_status" == "False" ]]; then
      log_error "AgentSandboxService claim failed to sync"
      kubectl describe agentsandboxservice "$TEST_CLAIM_NAME" -n "$NAMESPACE"
      return 1
    fi
    
    if [[ $elapsed -gt 0 && $((elapsed % 30)) -eq 0 ]]; then
      log_info "Still waiting for claim to be ready... (${elapsed}s elapsed)"
    fi
    
    sleep 5
    elapsed=$((elapsed + 5))
  done
  
  if [[ $elapsed -ge $timeout ]]; then
    log_error "Timeout waiting for AgentSandboxService to be ready"
    kubectl describe agentsandboxservice "$TEST_CLAIM_NAME" -n "$NAMESPACE"
    return 1
  fi
  
  # Wait for SandboxWarmPool to exist and have replicas (skip readiness check for this test)
  log_info "Waiting for sandbox instances to be created..."
  elapsed=0
  
  while [[ $elapsed -lt $timeout ]]; do
    local replicas
    replicas=$(kubectl get sandboxwarmpool "$TEST_CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
    
    if [[ "$replicas" -gt 0 ]]; then
      log_info "Sandbox instances created (replicas: $replicas)"
      break
    fi
    
    if [[ $elapsed -gt 0 && $((elapsed % 30)) -eq 0 ]]; then
      log_info "Still waiting for sandbox instances... (${elapsed}s elapsed)"
    fi
    
    sleep 5
    elapsed=$((elapsed + 5))
  done
  
  if [[ $elapsed -ge $timeout ]]; then
    log_error "Timeout waiting for sandbox instances to be created"
    kubectl describe sandboxwarmpool "$TEST_CLAIM_NAME" -n "$NAMESPACE"
    return 1
  fi
}

validate_secret_patching() {
  log_info "Validating secret patching in SandboxTemplate..."
  
  # Get the SandboxTemplate and check envFrom configuration
  local template_yaml
  template_yaml=$(kubectl get sandboxtemplate "$TEST_CLAIM_NAME" -n "$NAMESPACE" -o yaml)
  
  # Check that all 6 envFrom entries exist (aws-access-token + 5 user secrets)
  local envfrom_count
  envfrom_count=$(echo "$template_yaml" | yq '.spec.podTemplate.spec.containers[0].envFrom | length')
  
  if [[ "$envfrom_count" != "6" ]]; then
    log_error "Expected 6 envFrom entries, found $envfrom_count"
    return 1
  fi
  
  # Validate specific secret names are patched correctly
  local secrets=("test-secret-1" "test-secret-2" "test-secret-3" "test-secret-4" "test-secret-5" "aws-access-token")
  
  for i in "${!secrets[@]}"; do
    local expected_secret="${secrets[$i]}"
    local actual_secret
    actual_secret=$(echo "$template_yaml" | yq ".spec.podTemplate.spec.containers[0].envFrom[$i].secretRef.name")
    
    if [[ "$actual_secret" != "$expected_secret" ]]; then
      log_error "envFrom[$i] expected '$expected_secret', got '$actual_secret'"
      return 1
    fi
  done
  
  log_info "Secret patching validated successfully"
}

validate_environment_variables() {
  log_info "Validating environment variables in sandbox containers..."
  
  # Get a running pod from the SandboxWarmPool
  local pod_name
  pod_name=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=$TEST_CLAIM_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  
  if [[ -z "$pod_name" ]]; then
    log_error "No running sandbox pods found"
    return 1
  fi
  
  log_info "Testing environment variables in pod: $pod_name"
  
  # Test that variables from all secrets are available
  for i in {1..5}; do
    local expected_value="test-value-$i"
    local actual_value
    actual_value=$(kubectl exec "$pod_name" -n "$NAMESPACE" -c main -- printenv "TEST_VAR_$i" 2>/dev/null || echo "")
    
    if [[ "$actual_value" != "$expected_value" ]]; then
      log_error "TEST_VAR_$i expected '$expected_value', got '$actual_value'"
      return 1
    fi
  done
  
  # Test that AWS credentials are available
  if ! kubectl exec "$pod_name" -n "$NAMESPACE" -c main -- printenv AWS_ACCESS_KEY_ID >/dev/null 2>&1; then
    log_error "AWS_ACCESS_KEY_ID not found in container environment"
    return 1
  fi
  
  log_info "Environment variables validated successfully"
}

validate_connection_secret() {
  log_info "Validating connection secret generation..."
  
  # Check that connection secret exists with correct naming pattern
  local conn_secret_name="${TEST_CLAIM_NAME}-conn"
  
  if ! kubectl get secret "$conn_secret_name" -n "$NAMESPACE" >/dev/null 2>&1; then
    log_error "Connection secret '$conn_secret_name' not found"
    return 1
  fi
  
  # Validate connection secret contains expected keys
  local secret_keys
  secret_keys=$(kubectl get secret "$conn_secret_name" -n "$NAMESPACE" -o jsonpath='{.data}' | jq -r 'keys[]')
  
  local expected_keys=("SANDBOX_SERVICE_NAME" "SANDBOX_HTTP_ENDPOINT" "SANDBOX_NAMESPACE")
  
  for key in "${expected_keys[@]}"; do
    if ! echo "$secret_keys" | grep -q "^$key$"; then
      log_error "Connection secret missing key: $key"
      return 1
    fi
  done
  
  # Validate connection secret values
  local service_name
  service_name=$(kubectl get secret "$conn_secret_name" -n "$NAMESPACE" -o jsonpath='{.data.SANDBOX_SERVICE_NAME}' | base64 -d)
  
  if [[ "$service_name" != "$TEST_CLAIM_NAME" ]]; then
    log_error "Connection secret SANDBOX_SERVICE_NAME expected '$TEST_CLAIM_NAME', got '$service_name'"
    return 1
  fi
  
  log_info "Connection secret validated successfully"
}

validate_platform_standards() {
  log_info "Validating platform standards compliance..."
  
  # Check that secret mounting follows platform patterns
  local template_yaml
  template_yaml=$(kubectl get sandboxtemplate "$TEST_CLAIM_NAME" -n "$NAMESPACE" -o yaml)
  
  # Validate that all user secrets are marked as optional
  for i in {0..4}; do
    local optional
    optional=$(echo "$template_yaml" | yq ".spec.podTemplate.spec.containers[0].envFrom[$i].secretRef.optional")
    
    if [[ "$optional" != "true" ]]; then
      log_error "User secret at envFrom[$i] should be optional=true, got '$optional'"
      return 1
    fi
  done
  
  # Validate that aws-access-token is not optional (required for S3 operations)
  local aws_optional
  aws_optional=$(echo "$template_yaml" | yq ".spec.podTemplate.spec.containers[0].envFrom[5].secretRef.optional // \"false\"")
  
  if [[ "$aws_optional" == "true" ]]; then
    log_error "aws-access-token should not be optional"
    return 1
  fi
  
  log_info "Platform standards validated successfully"
}

# Main validation flow
main() {
  validate_prerequisites || return 1
  create_test_secrets || return 1
  create_test_claim || return 1
  wait_for_resources || return 1
  validate_secret_patching || return 1
  validate_environment_variables || return 1
  validate_connection_secret || return 1
  validate_platform_standards || return 1
  
  log_success "✅ All secret injection validations passed!"
  log_success "AgentSandboxService maintains complete API parity with EventDrivenService"
  
  return 0
}

# Run main function
if ! main; then
  log_error "❌ Secret injection validation failed"
  exit 1
fi