#!/bin/bash
set -euo pipefail

# ==============================================================================
# Pre-Deploy Diagnostics Script
# ==============================================================================
# Purpose: Run pre-deployment diagnostics based on service config
# Usage: ./pre-deploy-diagnostics.sh
# ==============================================================================

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[PRE-DEPLOY]${NC} $*"; }
log_success() { echo -e "${GREEN}[PRE-DEPLOY]${NC} $*"; }
log_error() { echo -e "${RED}[PRE-DEPLOY]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[PRE-DEPLOY]${NC} $*"; }

# Helper function to check if a config flag is enabled
config_enabled() {
    local config_path="$1"
    if command -v yq &> /dev/null; then
        local value=$(yq eval ".$config_path // false" "${SERVICE_ROOT:-$(pwd)}/ci/config.yaml" 2>/dev/null)
        [[ "$value" == "true" ]]
    else
        # Fallback: assume enabled if not specified
        return 0
    fi
}

# Load service configuration from ci/config.yaml
load_service_config() {
    local config_file="${SERVICE_ROOT:-$(pwd)}/ci/config.yaml"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "ci/config.yaml not found - cannot run diagnostics"
        log_error "Looked for: $config_file"
        log_error "Current directory: $(pwd)"
        exit 1
    fi
    
    log_info "Using config file: $config_file"
    
    if command -v yq &> /dev/null; then
        SERVICE_NAME=$(yq eval '.service.name' "$config_file")
        NAMESPACE=$(yq eval '.service.namespace' "$config_file")
    else
        log_error "yq is required but not installed"
        exit 1
    fi
    
    log_info "Service config loaded: ${SERVICE_NAME} in ${NAMESPACE}"
}

# Check platform dependencies from config
check_platform_dependencies() {
    log_info "Checking platform dependencies from config..."
    
    local config_file="${SERVICE_ROOT:-$(pwd)}/ci/config.yaml"
    
    # Get platform dependencies from config
    local platform_deps=$(yq eval '.dependencies.platform[]?' "$config_file" 2>/dev/null | tr '\n' ' ')
    
    if [[ -z "$platform_deps" ]]; then
        log_info "No platform dependencies specified in config"
        return 0
    fi
    
    log_info "Platform dependencies from config: $platform_deps"
    
    for dep in $platform_deps; do
        log_info "Checking platform dependency: $dep"
        
        # Check if ArgoCD application exists and is synced/healthy
        if kubectl get application "$dep" -n argocd >/dev/null 2>&1; then
            local sync_status=$(kubectl get application "$dep" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
            local health_status=$(kubectl get application "$dep" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
            
            if [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" ]]; then
                log_success "✓ Platform dependency '$dep' is ready (ArgoCD: $sync_status/$health_status)"
            else
                log_error "✗ Platform dependency '$dep' is not ready (ArgoCD: $sync_status/$health_status)"
                log_error "Platform dependencies must be Synced & Healthy before service deployment"
                exit 1
            fi
        else
            log_error "✗ Platform dependency '$dep' not found as ArgoCD application"
            log_error "Service declared '$dep' as a platform dependency in ci/config.yaml"
            log_error "This dependency must be deployed and running for the service to function correctly"
            exit 1
        fi
    done
}

# Check external dependencies from config
check_external_dependencies() {
    log_info "Checking external dependencies from config..."
    
    local config_file="${SERVICE_ROOT:-$(pwd)}/ci/config.yaml"
    
    # Get external dependencies from config
    local external_deps=$(yq eval '.dependencies.external[]?' "$config_file" 2>/dev/null | tr '\n' ' ')
    
    if [[ -z "$external_deps" ]]; then
        log_info "No external dependencies specified in config"
        return 0
    fi
    
    log_info "External dependencies from config: $external_deps"
    log_warn "External dependencies are expected to be mocked in the in-cluster test environment."
    log_warn "Skipping cluster existence check for: $external_deps"
    return 0
}

# Check platform APIs based on dependencies
check_platform_apis() {
    log_info "Checking required platform APIs based on dependencies..."
    
    local config_file="${SERVICE_ROOT:-$(pwd)}/ci/config.yaml"
    
    # Get all available XRDs in the cluster
    local available_xrds=$(kubectl get xrd -o name 2>/dev/null | sed 's|customresourcedefinition.apiextensions.k8s.io/||' || echo "")
    
    if [[ -z "$available_xrds" ]]; then
        log_warn "⚠ No XRDs found in cluster - Crossplane may not be installed"
        return 0
    fi
    
    log_info "Found $(echo "$available_xrds" | wc -w) XRDs in cluster"
    
    # Get internal dependencies to check for relevant XRDs
    local internal_deps=$(yq eval '.dependencies.internal[]?' "$config_file" 2>/dev/null | tr '\n' ' ')
    
    if [[ -z "$internal_deps" ]]; then
        log_info "No internal dependencies specified - checking for any platform XRDs"
        local xrd_count=$(echo "$available_xrds" | wc -w)
        if [[ $xrd_count -gt 0 ]]; then
            log_success "✓ Found $xrd_count platform XRDs available"
        else
            log_warn "⚠ No platform XRDs found"
        fi
        return 0
    fi
    
    log_info "Internal dependencies from config: $internal_deps"
    
    # For each internal dependency, try to find a matching XRD
    for dep in $internal_deps; do
        log_info "Looking for XRDs related to internal dependency: $dep"
        
        # Look for XRDs that might be related to this dependency
        local matching_xrds=$(echo "$available_xrds" | grep -i "$dep" || echo "")
        
        if [[ -n "$matching_xrds" ]]; then
            log_success "✓ Found XRDs related to '$dep': $(echo $matching_xrds | tr '\n' ' ')"
        else
            log_info "No specific XRDs found for '$dep' - may be handled by generic platform resources"
        fi
    done
    
    # General platform readiness check
    local total_xrds=$(echo "$available_xrds" | wc -w)
    if [[ $total_xrds -gt 0 ]]; then
        log_success "✓ Platform APIs ready - $total_xrds XRDs available for resource provisioning"
    else
        log_error "✗ No platform XRDs available - infrastructure provisioning may not work"
        exit 1
    fi
}

# Main execution
main() {
    log_info "Running pre-deploy diagnostics based on ci/config.yaml"
    
    # Load service configuration
    load_service_config
    
    echo "================================================================================"
    echo "Platform Pre-Deploy Diagnostics"
    echo "================================================================================"
    echo "  Service:    ${SERVICE_NAME}"
    echo "  Namespace:  ${NAMESPACE}"
    echo "================================================================================"
    
    # Check dependencies if enabled in config
    if config_enabled "diagnostics.pre_deploy.check_dependencies"; then
        log_info "Checking dependencies (enabled in config)..."
        check_platform_dependencies
        check_external_dependencies
    else
        log_info "Dependencies check disabled in config"
    fi
    
    # Check platform APIs if enabled in config
    if config_enabled "diagnostics.pre_deploy.check_platform_apis"; then
        log_info "Checking platform APIs (enabled in config)..."
        check_platform_apis
    else
        log_info "Platform API checks disabled in config"
    fi
    
    log_success "✅ Pre-deploy diagnostics completed successfully"
    log_info "Platform infrastructure is ready for ${SERVICE_NAME} deployment"
}

main "$@"