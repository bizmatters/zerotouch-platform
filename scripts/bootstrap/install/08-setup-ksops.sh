#!/bin/bash
set -e

# KSOPS Setup Orchestrator Script
# Orchestrates complete KSOPS setup: tools, keys, injection, secrets
# Usage: ./08-setup-ksops.sh

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Function to print colored messages
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_step() {
    echo -e "${BLUE}==>${NC} $1"
}

# Main execution
main() {
    log_info "════════════════════════════════════════════════════════"
    log_info "KSOPS Setup Orchestrator"
    log_info "════════════════════════════════════════════════════════"
    
    # Step 1: Install KSOPS tools (SOPS + Age)
    log_step "Step 1/4: Installing KSOPS tools..."
    "$SCRIPT_DIR/../infra/secrets/ksops/08a-install-ksops.sh"
    
    # Step 2: Generate Age keypair
    log_step "Step 2/4: Generating Age keypair..."
    source "$SCRIPT_DIR/../infra/secrets/ksops/08b-generate-age-keys.sh"
    
    # Step 3: Inject Age key into cluster
    log_step "Step 3/4: Injecting Age key into cluster..."
    "$SCRIPT_DIR/../infra/secrets/ksops/08c-inject-age-key.sh"
    
    # Step 4: Inject SOPS secrets
    log_step "Step 4/4: Injecting SOPS secrets..."
    "$SCRIPT_DIR/../infra/secrets/ksops/08d-inject-sops-secrets.sh"
    
    log_info ""
    log_info "════════════════════════════════════════════════════════"
    log_info "✅ KSOPS Setup Complete"
    log_info "════════════════════════════════════════════════════════"
}

# Execute main function
main "$@"