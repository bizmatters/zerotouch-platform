#!/bin/bash
set -e

# ArgoCD Bootstrap Script
# Installs ArgoCD and kicks off GitOps deployment
# Prerequisites: Talos cluster must be running and kubectl configured
# Usage: ./09-install-argocd.sh [MODE]
#   MODE: "production" or "preview" (optional, defaults to auto-detection)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ARGOCD_VERSION="v3.2.0"  # Latest stable as of 2024-11-24
ARGOCD_NAMESPACE="argocd"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Find repository root by looking for .git directory
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR" && while [[ ! -d .git && $(pwd) != "/" ]]; do cd ..; done; pwd))"

# Parse mode parameter (first arg) and environment (second arg)
MODE="${1:-auto}"
ENVIRONMENT="${2:-dev}"

# Root application path - now using environment-specific overlays
if [ "$MODE" = "preview" ]; then
    ROOT_APP_OVERLAY="bootstrap/argocd/overlays/preview"
else
    # Use environment-specific overlay inside main (dev, staging, production)
    ROOT_APP_OVERLAY="bootstrap/argocd/overlays/main/$ENVIRONMENT"
fi

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

# Install ArgoCD CLI
install_argocd_cli() {
    if ! command -v argocd &> /dev/null; then
        log_step "Installing ArgoCD CLI..."
        curl -sSL -o argocd "https://github.com/argoproj/argo-cd/releases/download/$ARGOCD_VERSION/argocd-linux-amd64"
        chmod +x argocd
        sudo mv argocd /usr/local/bin/argocd
        log_info "ArgoCD CLI installed successfully"
    else
        log_info "ArgoCD CLI already available"
    fi
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
log_info "════════════════════════════════════════════════════════"
log_info "ArgoCD Bootstrap Script"
log_info "════════════════════════════════════════════════════════"

log_step "Checking prerequisites..."

if ! command_exists kubectl; then
    log_error "kubectl is not installed"
    exit 1
fi

if ! kubectl cluster-info &>/dev/null; then
    log_error "Cannot connect to Kubernetes cluster. Is kubectl configured?"
    exit 1
fi

log_info "✓ kubectl configured and cluster accessible"

# Display cluster info
CLUSTER_NAME=$(kubectl config current-context)
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')

log_info "Cluster: $CLUSTER_NAME"
log_info "Nodes: $NODE_COUNT"

# Step 1: Install ArgoCD CLI and Server
log_info ""
log_step "Step 1/5: Installing ArgoCD CLI and Server..."

# Install ArgoCD CLI first
install_argocd_cli

if kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
    log_warn "ArgoCD namespace already exists"
else
    log_info "Creating ArgoCD namespace..."
    kubectl create namespace "$ARGOCD_NAMESPACE"
fi

# Determine deployment mode
if [ "$MODE" = "preview" ]; then
    log_info "Applying ArgoCD manifests for preview mode (Kind cluster, version: $ARGOCD_VERSION)..."
    kubectl apply -k "$REPO_ROOT/bootstrap/argocd/install/preview"
elif [ "$MODE" = "production" ]; then
    log_info "Applying ArgoCD manifests for production mode (Talos cluster, version: $ARGOCD_VERSION)..."
    kubectl apply -k "$REPO_ROOT/bootstrap/argocd/install"
else
    # Auto-detection fallback
    log_info "Auto-detecting cluster type..."
    if kubectl get nodes -o jsonpath='{.items[*].spec.taints[?(@.key=="node-role.kubernetes.io/control-plane")]}' | grep -q "control-plane"; then
        log_info "Detected Talos cluster - applying ArgoCD manifests with control-plane tolerations (version: $ARGOCD_VERSION)..."
        kubectl apply -k "$REPO_ROOT/bootstrap/argocd/install"
    else
        log_info "Detected Kind cluster - applying ArgoCD manifests for preview mode (version: $ARGOCD_VERSION)..."
        kubectl apply -k "$REPO_ROOT/bootstrap/argocd/install/preview"
    fi
fi

log_info "✓ ArgoCD manifests applied successfully"

# Step 2: Wait for ArgoCD to be ready
log_info ""
log_step "Step 2/5: Waiting for ArgoCD to be ready..."

# Step 2a: Wait for ArgoCD pods
if ! "$REPO_ROOT/scripts/bootstrap/wait/09a-wait-argocd-pods.sh" --timeout 300 --namespace "$ARGOCD_NAMESPACE"; then
    log_error "ArgoCD pods failed to become ready"
    exit 1
fi

# Step 2b: Wait for repo server to be responsive
if ! "$REPO_ROOT/scripts/bootstrap/wait/09b-wait-argocd-repo-server.sh" --timeout 120 --namespace "$ARGOCD_NAMESPACE"; then
    log_error "ArgoCD repo server failed to become responsive"
    exit 1
fi

log_info "✓ ArgoCD is ready"

# Step 2.5: Grant ArgoCD cluster-admin permissions
log_info ""
log_step "Step 2.5/6: Granting ArgoCD cluster-admin permissions..."

log_info "Applying cluster-admin RBAC patch..."
kubectl apply -f "$REPO_ROOT/bootstrap/argocd/bootstrap-files/argocd-admin-patch.yaml"

log_info "✓ ArgoCD has cluster-admin permissions (required for namespace creation)"

# Step 3: Configure repository credentials
log_info ""
log_step "Step 3/7: Configuring repository credentials..."

# GitHub credentials - use BOT_GITHUB_* environment variables
# Extract username from GITHUB_REPOSITORY or default to current repo owner
GITHUB_USERNAME="${BOT_GITHUB_USERNAME:-${GITHUB_REPOSITORY_OWNER:-bizmatters}}"
GITHUB_REPO_URL="https://github.com/${GITHUB_USERNAME}/zerotouch-platform.git"
GITHUB_TOKEN="${BOT_GITHUB_TOKEN:-}"

if kubectl get secret repo-credentials -n "$ARGOCD_NAMESPACE" &>/dev/null; then
    log_warn "Repository credentials already exist, skipping..."
else
    log_info "Creating repository credentials secret..."
    kubectl create secret generic repo-credentials -n "$ARGOCD_NAMESPACE" \
        --from-literal=url="$GITHUB_REPO_URL" \
        --from-literal=username="$GITHUB_USERNAME" \
        --from-literal=password="$GITHUB_TOKEN" \
        --from-literal=type=git \
        --from-literal=project=default

    kubectl label secret repo-credentials -n "$ARGOCD_NAMESPACE" \
        argocd.argoproj.io/secret-type=repository

    log_info "✓ Repository credentials configured"
fi

# Tenant repository credentials are now managed via KSOPS-encrypted secrets
# (repo-zerotouch-tenants.secret.yaml with GitHub App authentication)
# No need to create them here

log_info ""
log_info "✓ ArgoCD installation complete"
log_info ""
log_info "Next: Deploy KSOPS package before deploying root application"

