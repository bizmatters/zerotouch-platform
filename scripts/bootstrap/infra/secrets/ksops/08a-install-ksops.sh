#!/bin/bash
set -e

# KSOPS Tools Installation Script
# Installs SOPS and Age binaries only
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

# Function to print colored messages
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_step() {
    echo -e "${BLUE}==>${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Install SOPS
install_sops() {
    if ! command_exists sops; then
        log_step "Installing SOPS $SOPS_VERSION..."
        local OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        curl -LO "https://github.com/getsops/sops/releases/download/$SOPS_VERSION/sops-$SOPS_VERSION.${OS}.amd64"
        chmod +x "sops-$SOPS_VERSION.${OS}.amd64"
        sudo mv "sops-$SOPS_VERSION.${OS}.amd64" /usr/local/bin/sops
        log_info "SOPS installed successfully"
    else
        log_info "SOPS already available: $(sops --version)"
    fi
}

# Install Age
install_age() {
    if ! command_exists age || ! command_exists age-keygen; then
        log_step "Installing Age $AGE_VERSION..."
        local OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        curl -LO "https://github.com/FiloSottile/age/releases/download/$AGE_VERSION/age-$AGE_VERSION-${OS}-amd64.tar.gz"
        tar xzf "age-$AGE_VERSION-${OS}-amd64.tar.gz"
        sudo mv age/age /usr/local/bin/
        sudo mv age/age-keygen /usr/local/bin/
        rm -rf age "age-$AGE_VERSION-${OS}-amd64.tar.gz"
        log_info "Age installed successfully"
    else
        log_info "Age already available: $(age --version)"
    fi
}

# Install KSOPS kustomize plugin
install_ksops_plugin() {
    local PLUGIN_DIR="$HOME/.config/kustomize/plugin/viaduct.ai/v1/ksops"
    
    if [ -f "$PLUGIN_DIR/ksops" ]; then
        log_info "KSOPS plugin already installed"
        return
    fi
    
    log_step "Installing KSOPS kustomize plugin..."
    
    # Create plugin directory
    mkdir -p "$PLUGIN_DIR"
    
    # Detect OS and architecture
    local OS=$(uname -s)
    local ARCH=$(uname -m)
    
    case "$OS" in
        Darwin)
            OS="Darwin"
            ;;
        Linux)
            OS="Linux"
            ;;
        *)
            log_error "Unsupported OS: $OS"
            return 1
            ;;
    esac
    
    case "$ARCH" in
        x86_64)
            ARCH="x86_64"
            ;;
        arm64|aarch64)
            ARCH="arm64"
            ;;
        *)
            log_error "Unsupported architecture: $ARCH"
            return 1
            ;;
    esac
    
    # Download and extract KSOPS archive
    local TEMP_DIR=$(mktemp -d)
    curl -Lo "$TEMP_DIR/ksops.tar.gz" "https://github.com/viaduct-ai/kustomize-sops/releases/latest/download/ksops_latest_${OS}_${ARCH}.tar.gz"
    tar -xzf "$TEMP_DIR/ksops.tar.gz" -C "$TEMP_DIR"
    mv "$TEMP_DIR/ksops" "$PLUGIN_DIR/ksops"
    chmod +x "$PLUGIN_DIR/ksops"
    rm -rf "$TEMP_DIR"
    
    log_info "KSOPS plugin installed successfully"
}

# Main execution
main() {
    log_info "════════════════════════════════════════════════════════"
    log_info "KSOPS Tools Installation"
    log_info "════════════════════════════════════════════════════════"
    
    # Check prerequisites
    log_step "Checking prerequisites..."
    
    if ! command_exists kubectl; then
        log_error "kubectl is not installed"
        exit 1
    fi
    
    log_info "✓ Prerequisites satisfied"
    
    # Install tools
    install_sops
    install_age
    install_ksops_plugin
    
    log_info "✅ KSOPS tools installation complete"
}

# Execute main function
main "$@"