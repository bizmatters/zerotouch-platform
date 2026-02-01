#!/bin/bash
set -e

# KSOPS Installation Script
# Installs SOPS, Age, and sets up KSOPS for ArgoCD secret decryption
# Prerequisites: kubectl and cluster access
# Usage: ./08a-install-ksops.sh

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration from versions.yaml
SOPS_VERSION="v3.8.1"
AGE_VERSION="v1.1.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR" && while [[ ! -d .git && $(pwd) != "/" ]]; do cd ..; done; pwd))"

# Function to print colored messages
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}==>${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Install SOPS
install_sops() {
    if ! command_exists sops; then
        log_step "Installing SOPS $SOPS_VERSION..."
        curl -LO "https://github.com/getsops/sops/releases/download/$SOPS_VERSION/sops-$SOPS_VERSION.linux.amd64"
        chmod +x "sops-$SOPS_VERSION.linux.amd64"
        sudo mv "sops-$SOPS_VERSION.linux.amd64" /usr/local/bin/sops
        log_info "SOPS installed successfully"
    else
        log_info "SOPS already available: $(sops --version)"
    fi
}

# Install Age
install_age() {
    if ! command_exists age || ! command_exists age-keygen; then
        log_step "Installing Age $AGE_VERSION..."
        curl -LO "https://github.com/FiloSottile/age/releases/download/$AGE_VERSION/age-$AGE_VERSION-linux-amd64.tar.gz"
        tar xzf "age-$AGE_VERSION-linux-amd64.tar.gz"
        sudo mv age/age /usr/local/bin/
        sudo mv age/age-keygen /usr/local/bin/
        rm -rf age "age-$AGE_VERSION-linux-amd64.tar.gz"
        log_info "Age installed successfully"
    else
        log_info "Age already available: $(age --version)"
    fi
}

# Generate Age keypair
generate_age_keys() {
    log_step "Generating Age keypair..."
    
    # Generate Age keypair
    AGE_KEYGEN_OUTPUT=$(age-keygen 2>&1)
    
    # Extract public key
    AGE_PUBLIC_KEY=$(echo "$AGE_KEYGEN_OUTPUT" | grep "^age1" | awk '{print $NF}')
    
    # Extract private key
    AGE_PRIVATE_KEY=$(echo "$AGE_KEYGEN_OUTPUT" | grep "^AGE-SECRET-KEY-1")
    
    if [[ -z "$AGE_PUBLIC_KEY" || -z "$AGE_PRIVATE_KEY" ]]; then
        log_error "Failed to generate Age keypair"
        exit 1
    fi
    
    log_info "Age keypair generated successfully"
    log_info "Public Key: $AGE_PUBLIC_KEY"
    log_info "Private Key: ${AGE_PRIVATE_KEY:0:20}..."
    
    # Export for use by other scripts
    export AGE_PUBLIC_KEY
    export AGE_PRIVATE_KEY
}

# Inject Age key into cluster
inject_age_key() {
    log_step "Injecting Age private key into cluster..."
    
    # Ensure argocd namespace exists
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    
    # Create sops-age secret
    kubectl create secret generic sops-age \
        --namespace=argocd \
        --from-literal=keys.txt="$AGE_PRIVATE_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_info "Age private key injected successfully"
    
    # Verify secret
    if kubectl get secret sops-age -n argocd -o jsonpath='{.data.keys\.txt}' | base64 -d | grep -q "AGE-SECRET-KEY-1"; then
        log_info "✓ Age key secret verified"
    else
        log_error "Failed to verify Age key secret"
        exit 1
    fi
}

# Create Age key backup
create_age_backup() {
    log_step "Creating Age key backup..."
    
    # Generate recovery master key
    RECOVERY_KEYGEN_OUTPUT=$(age-keygen 2>&1)
    RECOVERY_MASTER_KEY=$(echo "$RECOVERY_KEYGEN_OUTPUT" | grep "^AGE-SECRET-KEY-1")
    
    # Encrypt Age private key with recovery master key
    RECOVERY_PUBLIC_KEY=$(echo "$RECOVERY_KEYGEN_OUTPUT" | grep "^age1" | awk '{print $NF}')
    ENCRYPTED_AGE_KEY=$(echo "$AGE_PRIVATE_KEY" | age -r "$RECOVERY_PUBLIC_KEY")
    
    # Create backup secrets
    kubectl create secret generic age-backup-encrypted \
        --namespace=argocd \
        --from-literal=keys.txt.enc="$ENCRYPTED_AGE_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    kubectl create secret generic recovery-master-key \
        --namespace=argocd \
        --from-literal=key="$RECOVERY_MASTER_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_info "Age key backup created successfully"
}

# Main execution
main() {
    log_info "════════════════════════════════════════════════════════"
    log_info "KSOPS Installation Script"
    log_info "════════════════════════════════════════════════════════"
    
    # Check prerequisites
    log_step "Checking prerequisites..."
    
    if ! command_exists kubectl; then
        log_error "kubectl is not installed"
        exit 1
    fi
    
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    
    log_info "✓ Prerequisites satisfied"
    
    # Install tools
    install_sops
    install_age
    
    # Generate and inject keys
    generate_age_keys
    inject_age_key
    create_age_backup
    
    log_info ""
    log_info "════════════════════════════════════════════════════════"
    log_info "✅ KSOPS Installation Complete"
    log_info "════════════════════════════════════════════════════════"
    log_info ""
    log_info "Next Steps:"
    log_info "  1. Deploy KSOPS package via ArgoCD"
    log_info "  2. Configure .sops.yaml in tenant repository"
    log_info "  3. Encrypt secrets with: sops -e secret.yaml"
    log_info ""
    log_info "Age Public Key (for .sops.yaml):"
    log_info "  $AGE_PUBLIC_KEY"
    log_info ""
}

# Execute main function
main "$@"