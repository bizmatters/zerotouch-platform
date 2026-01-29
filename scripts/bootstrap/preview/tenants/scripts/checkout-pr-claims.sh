#!/bin/bash
set -euo pipefail

# ==============================================================================
# PR Claims Checkout Script
# ==============================================================================
# Purpose: Checkout PR claims from tenants repository
# Usage: ./checkout-pr-claims.sh <environment> <namespace> <service_root>
# ==============================================================================

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[PR-CLAIMS]${NC} $*"; }
log_success() { echo -e "${GREEN}[PR-CLAIMS]${NC} $*"; }
log_error() { echo -e "${RED}[PR-CLAIMS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[PR-CLAIMS]${NC} $*"; }

checkout_pr_claims() {
    local environment="$1"
    local namespace="$2"
    local service_root="$3"
    
    log_info "=== PR CLAIMS CHECKOUT DEBUG ==="
    log_info "Environment parameter: '$environment'"
    log_info "Namespace: '$namespace'"
    log_info "Service root: '$service_root'"
    log_info "Current working directory: $(pwd)"
    
    # Extract service name from config first, fallback to basename for compatibility
    local service_name
    if [[ -f "${service_root}/ci/config.yaml" ]]; then
        if command -v yq &> /dev/null; then
            service_name=$(yq eval '.service.name' "${service_root}/ci/config.yaml" 2>/dev/null || echo "")
            log_info "Service name from config: '$service_name'"
        else
            log_warn "yq not available, using basename fallback"
            service_name=""
        fi
    else
        log_warn "Config file not found: ${service_root}/ci/config.yaml"
    fi
    
    # Fallback to basename if config fails (preserves local behavior)
    if [[ -z "$service_name" ]]; then
        service_name=$(basename "$service_root")
        log_info "Service name from basename fallback: '$service_name'"
    fi
    
    log_info "Final service name: '$service_name'"
    
    if [[ "$environment" == "pr" || "$environment" == "preview" ]]; then
        log_info "Checking out PR claims for service: $service_name, namespace: $namespace"
        
        # Checkout zerotouch-tenants repository
        # Use environment variable or default to SSH URL
        local tenants_repo="${TENANTS_REPO_URL:-git@github.com:bizmatters/zerotouch-tenants.git}"
        local tenants_dir="platform/tenants-temp"
        
        # Detect current branch for checkout
        local current_branch=$(git branch --show-current 2>/dev/null || echo "main")
        log_info "Current branch detected: $current_branch"
        
        log_info "Cloning tenants repository: $tenants_repo"
        log_info "Target directory: $tenants_dir"
        
        # Remove existing temp directory if it exists
        if [[ -d "$tenants_dir" ]]; then
            log_info "Removing existing temp directory: $tenants_dir"
            rm -rf "$tenants_dir"
        fi
        
        # Create platform directory if it doesn't exist
        mkdir -p platform
        log_info "Created platform directory"
        
        # Clone the repository using GitHub token
        local github_token="${GITHUB_TOKEN:-${BOT_GITHUB_TOKEN:-}}"
        
        if [[ -z "$github_token" ]]; then
            log_error "GitHub token required but not found"
            log_error "Set GITHUB_TOKEN or BOT_GITHUB_TOKEN environment variable"
            exit 1
        fi
        
        log_info "GitHub token available (length: ${#github_token})"
        
        # Extract org/repo from SSH URL and construct HTTPS URL
        local repo_path=$(echo "$tenants_repo" | sed 's|git@github.com:||' | sed 's|\.git$||')
        local https_repo="https://x-access-token:${github_token}@github.com/${repo_path}.git"
        
        log_info "Cloning ${repo_path} branch: $current_branch"
        if ! git clone -b "$current_branch" "$https_repo" "$tenants_dir"; then
            log_error "Failed to clone tenants repository"
            exit 1
        fi
        
        log_success "Clone successful, checked out branch: $current_branch"
        
        # Path to service directory
        local service_path="$tenants_dir/tenants/$service_name"
        local target_path="${service_root}/platform/${service_name}"
        
        log_info "Looking for service directory at: $service_path"
        
        if [[ -d "$service_path" ]]; then
            log_success "Found service directory at: $service_path"
            
            # Create platform directory if it doesn't exist
            mkdir -p "${service_root}/platform"
            log_info "Created service platform directory: ${service_root}/platform"
            
            # Copy only the service directory to platform/ (ensure we're in service root)
            cd "$service_root"
            if [[ -d "platform/${service_name}" ]]; then
                log_info "Removing existing target directory: platform/${service_name}"
                rm -rf "platform/${service_name}"
            fi
            
            cp -r "$service_path" "platform/${service_name}"
            log_success "Service directory copied to: ${service_root}/platform/${service_name}"
            
            # Remove the temp directory
            rm -rf "$tenants_dir"
            log_info "Cleaned up temp directory: $tenants_dir"
            
            # Path to PR claims
            local claims_path="$target_path/overlays/pr"
            
            log_info "Looking for PR claims at: $claims_path"
            
            if [[ -d "$claims_path" ]]; then
                log_success "Found PR claims at: $claims_path"
                
                # Post-checkout verification
                log_info "=== POST-CHECKOUT VERIFICATION ==="
                log_info "Service platform directory exists: $target_path"
                
                local manifest_count=0
                while IFS= read -r -d '' file; do
                    log_info "Found manifest: $(basename "$file")"
                    ((manifest_count++))
                done < <(find "$target_path" -name "*.yaml" -o -name "*.yml" -print0 2>/dev/null | head -z -10)
                
                log_info "Total manifests found: $manifest_count"
                log_success "PR claims checked out successfully"
            else
                log_error "PR claims directory not found: $claims_path"
                log_error "Available directories in $target_path:"
                if [[ -d "$target_path" ]]; then
                    find "$target_path" -type d | head -10 | while read -r dir; do
                        log_error "  - $dir"
                    done
                fi
                exit 1
            fi
        else
            log_error "Service directory not found: $service_path"
            log_error "Available services in tenants directory:"
            if [[ -d "$tenants_dir/tenants" ]]; then
                find "$tenants_dir/tenants" -maxdepth 1 -type d | head -10 | while read -r dir; do
                    log_error "  - $(basename "$dir")"
                done
            fi
            rm -rf "$tenants_dir"
            exit 1
        fi
    else
        log_info "Environment is '$environment' - skipping PR claims checkout"
    fi
    
    log_info "=== PR CLAIMS CHECKOUT DEBUG END ==="
}

# Main execution
if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <environment> <namespace> <service_root>"
    echo "Example: $0 pr intelligence-orchestrator /path/to/service"
    exit 1
fi

ENVIRONMENT="$1"
NAMESPACE="$2"
SERVICE_ROOT="$3"

checkout_pr_claims "$ENVIRONMENT" "$NAMESPACE" "$SERVICE_ROOT"
