#!/bin/bash
set -euo pipefail

# ==============================================================================
# Run Tests in Environment Script
# ==============================================================================
# Purpose: Execute integration tests in existing cluster (dev/staging/prod)
# Usage: ./run-tests-in-env.sh <service-name> <environment> [test-file]
# Example: ./run-tests-in-env.sh identity-service dev
#          ./run-tests-in-env.sh identity-service dev tests/integration/test_api_token_flow.ts
# ==============================================================================

SERVICE_NAME="${1:-}"
ENVIRONMENT="${2:-dev}"
TEST_FILE="${3:-}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[RUN-TESTS-IN-ENV]${NC} $*"; }
log_success() { echo -e "${GREEN}[RUN-TESTS-IN-ENV]${NC} $*"; }
log_error() { echo -e "${RED}[RUN-TESTS-IN-ENV]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[RUN-TESTS-IN-ENV]${NC} $*"; }

# Validate arguments
if [[ -z "$SERVICE_NAME" ]]; then
    log_error "Service name is required"
    echo "Usage: $0 <service-name> <environment>"
    echo "Example: $0 identity-service dev"
    exit 1
fi

# Determine paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Find service directory
SERVICE_ROOT=""
if [[ -d "../${SERVICE_NAME}" ]]; then
    SERVICE_ROOT="$(cd ../${SERVICE_NAME} && pwd)"
elif [[ -d "../../${SERVICE_NAME}" ]]; then
    SERVICE_ROOT="$(cd ../../${SERVICE_NAME} && pwd)"
else
    log_error "Service directory not found: ${SERVICE_NAME}"
    log_error "Searched in: ../${SERVICE_NAME} and ../../${SERVICE_NAME}"
    exit 1
fi

log_info "Service root: $SERVICE_ROOT"
log_info "Platform root: $PLATFORM_ROOT"

# Load service configuration
CONFIG_FILE="${SERVICE_ROOT}/ci/config.yaml"
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Config file not found: $CONFIG_FILE"
    exit 1
fi

NAMESPACE=$(yq eval '.service.namespace' "$CONFIG_FILE")
TIMEOUT=$(yq eval '.test.timeout // 600' "$CONFIG_FILE")

if [[ -z "$NAMESPACE" || "$NAMESPACE" == "null" ]]; then
    log_error "service.namespace not found in ci/config.yaml"
    exit 1
fi

log_info "Namespace: $NAMESPACE"
log_info "Environment: $ENVIRONMENT"

# Run pre-flight checks
PRE_FLIGHT_SCRIPT="${PLATFORM_ROOT}/scripts/bootstrap/helpers/cluster-pre-flight-checks.sh"
if [[ -f "$PRE_FLIGHT_SCRIPT" ]]; then
    chmod +x "$PRE_FLIGHT_SCRIPT"
    if ! "$PRE_FLIGHT_SCRIPT" "$ENVIRONMENT" "$NAMESPACE"; then
        log_error "Pre-flight checks failed"
        exit 1
    fi
else
    log_warn "Pre-flight checks script not found: $PRE_FLIGHT_SCRIPT"
fi

# Get deployed image tag from cluster
log_info "Detecting deployed image tag..."
DEPLOYED_IMAGE=$(kubectl get deployment -n "$NAMESPACE" "$SERVICE_NAME" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")

if [[ -z "$DEPLOYED_IMAGE" ]]; then
    log_error "Service deployment not found in cluster"
    log_error "Ensure ${SERVICE_NAME} is deployed in namespace ${NAMESPACE}"
    exit 1
fi

log_success "Deployed image: $DEPLOYED_IMAGE"

# Check if specific test file provided
if [[ -n "$TEST_FILE" ]]; then
    log_info "Running single test: $TEST_FILE"
    
    # Validate test file exists
    cd "$SERVICE_ROOT"
    if [[ ! -f "$TEST_FILE" ]]; then
        log_error "Test file not found: $TEST_FILE"
        exit 1
    fi
    
    TEST_FILES=("$TEST_FILE")
else
    # Discover test files from config
    log_info "Discovering test files..."
    TEST_PATTERNS=$(yq eval '.test.test_patterns[]' "$CONFIG_FILE" 2>/dev/null || echo "")
    
    if [[ -z "$TEST_PATTERNS" ]]; then
        log_warn "No test patterns found in ci/config.yaml, using default"
        TEST_PATTERNS="tests/integration/test_*.py"
    fi
    
    # Find test files
    cd "$SERVICE_ROOT"
    TEST_FILES=()
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        
        DIR=$(echo "$pattern" | sed 's|/\*\*.*||')
        NAME_PATTERN=$(echo "$pattern" | sed 's|.*/||')
        
        if [[ -d "$DIR" ]]; then
            while IFS= read -r file; do
                [[ -z "$file" ]] && continue
                TEST_FILES+=("$file")
            done < <(find "$DIR" -name "$NAME_PATTERN" -type f | grep -v __pycache__ | grep -v conftest | sort)
        fi
    done <<< "$TEST_PATTERNS"
    
    if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
        log_error "No test files found matching patterns in ci/config.yaml"
        exit 1
    fi
    
    log_success "Found ${#TEST_FILES[@]} test file(s)"
fi

# Export environment variables for test script
export SERVICE_ROOT
export PLATFORM_ROOT
export SERVICE_NAME
export NAMESPACE
export TIMEOUT

# Run each test
FAILED_TESTS=()
PASSED_TESTS=()

echo ""
echo "================================================================================"
echo "Running Integration Tests in ${ENVIRONMENT} Environment"
echo "================================================================================"
echo "  Service:    ${SERVICE_NAME}"
echo "  Namespace:  ${NAMESPACE}"
echo "  Image:      ${DEPLOYED_IMAGE}"
echo "  Tests:      ${#TEST_FILES[@]}"
echo "================================================================================"
echo ""

for TEST_FILE in "${TEST_FILES[@]}"; do
    # Extract test name
    TEST_NAME=$(echo "$TEST_FILE" | sed 's|tests/integration/||' | sed 's|\.[^.]*$||' | sed 's|[/_]|-|g')
    
    log_info "Running test: $TEST_NAME ($TEST_FILE)"
    
    # Run test using new test-runner pattern
    TEST_SCRIPT="${PLATFORM_ROOT}/scripts/bootstrap/helpers/test-runner/run-test-job.sh"
    
    if [[ ! -f "$TEST_SCRIPT" ]]; then
        log_error "Test script not found: $TEST_SCRIPT"
        exit 1
    fi
    
    chmod +x "$TEST_SCRIPT"
    
    if "$TEST_SCRIPT" "$TEST_FILE" "$TEST_NAME" "$TIMEOUT" "$DEPLOYED_IMAGE"; then
        log_success "✅ Test passed: $TEST_NAME"
        PASSED_TESTS+=("$TEST_NAME")
    else
        log_error "❌ Test failed: $TEST_NAME"
        FAILED_TESTS+=("$TEST_NAME")
    fi
    
    echo ""
done

# Summary
echo "================================================================================"
echo "Test Execution Summary"
echo "================================================================================"
echo "  Total:   ${#TEST_FILES[@]}"
echo "  Passed:  ${#PASSED_TESTS[@]}"
echo "  Failed:  ${#FAILED_TESTS[@]}"
echo "================================================================================"

if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
    echo ""
    log_error "Failed tests:"
    for test in "${FAILED_TESTS[@]}"; do
        echo "  - $test"
    done
    echo ""
    exit 1
fi

log_success "✅ All tests passed!"
